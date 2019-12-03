/*
 * Copyright (c) 2019, NVIDIA CORPORATION.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
#include <thrust/execution_policy.h>
#include <thrust/for_each.h>
#include <thrust/iterator/constant_iterator.h>
#include <thrust/iterator/counting_iterator.h>
#include <thrust/tuple.h>
#include <thrust/device_vector.h>
#include <thrust/merge.h>

#include <algorithm>
#include <utility>
#include <vector>
#include <memory>
#include <type_traits>

#include <cudf/cudf.h>
#include <cudf/types.hpp>
#include <cudf/table/table.hpp>
#include <cudf/table/table_device_view.cuh>
#include <cudf/table/row_operators.cuh>
#include <cudf/utilities/type_dispatcher.hpp>
#include <rmm/thrust_rmm_allocator.h>
#include <utilities/legacy/cuda_utils.hpp>
#include <cudf/utilities/bit.hpp>
#include <cudf/null_mask.hpp>
#include <cudf/copying.hpp>
#include <cudf/detail/utilities/cuda.cuh>
//#include <cudf/strings/detail/merge.cuh> // <- TODO: separate PR for strings support

#include <cudf/merge.hpp>

namespace { // anonym.

/**
 * @brief Merges the bits of two validity bitmasks.
 *
 * Merges the bits from two column_device_views into the destination column_device_view
 * according to `merged_indices` map such that bit `i` in `out_col`
 * will be equal to bit `thrust::get<1>(merged_indices[i])` from `left_dcol`
 * if `thrust::get<0>(merged_indices[i])` equals `side::LEFT`; otherwise,
 * from `right_dcol`.
 *
 * `left_dcol`, `right_dcol` and `out_dcol` must not
 * overlap.
 *
 * @tparam left_have_valids Indicates whether left_dcol mask is unallocated (hence, ALL_VALID)
 * @tparam right_have_valids Indicates whether right_dcol mask is unallocated (hence ALL_VALID)
 * @param[in] left_dcol The left column_device_view whose bits will be merged
 * @param[in] right_dcol The right column_device_view whose bits will be merged
 * @param[out] out_dcol The output mutable_column_device_view after merging the left and right
 * @param[in] num_destination_rows The number of rows in the out_dcol
 * @param[in] merged_indices The map that indicates the source of the input and index
 * to be copied to the output. Length must be equal to `num_destination_rows`
 */
template <bool left_have_valids, bool right_have_valids>
__global__ void materialize_merged_bitmask_kernel(cudf::column_device_view left_dcol,
                                                  cudf::column_device_view right_dcol,
                                                  cudf::mutable_column_device_view out_dcol,
                                                  cudf::size_type const num_destination_rows,
                                                  index_type const* const __restrict__ merged_indices) {
  cudf::size_type destination_row = threadIdx.x + blockIdx.x * blockDim.x;

  cudf::bitmask_type const* const __restrict__ source_left_mask = left_dcol.null_mask();
  cudf::bitmask_type const* const __restrict__ source_right_mask= right_dcol.null_mask();
  cudf::bitmask_type* const __restrict__ destination_mask = out_dcol.null_mask();
  
  auto active_threads =
    __ballot_sync(0xffffffff, destination_row < num_destination_rows);

  while (destination_row < num_destination_rows) {
    index_type const& merged_idx = merged_indices[destination_row];
    side const src_side = thrust::get<0>(merged_idx);
    cudf::size_type const src_row  = thrust::get<1>(merged_idx);
    bool const from_left{src_side == side::LEFT};
    bool source_bit_is_valid{true};
    if (left_have_valids && from_left) {
      source_bit_is_valid = left_dcol.is_valid_nocheck(src_row);
    }
    else if (right_have_valids && !from_left) {
      source_bit_is_valid = right_dcol.is_valid_nocheck(src_row);
    }

    // Use ballot to find all valid bits in this warp and create the output
    // bitmask element
    cudf::bitmask_type const result_mask{
      __ballot_sync(active_threads, source_bit_is_valid)};

    cudf::size_type const output_element = cudf::word_index(destination_row);

    // Only one thread writes output
    if (0 == threadIdx.x % warpSize) {
      destination_mask[output_element] = result_mask;
    }

    destination_row += blockDim.x * gridDim.x;
    active_threads =
      __ballot_sync(active_threads, destination_row < num_destination_rows);
  }
}

void materialize_bitmask(cudf::column_view const& left_col,
                         cudf::column_view const& right_col,
                         cudf::mutable_column_view& out_col,
                         index_type const* merged_indices,
                         cudaStream_t stream) {
  constexpr cudf::size_type BLOCK_SIZE{256};
  cudf::experimental::detail::grid_1d grid_config {out_col.size(), BLOCK_SIZE };

  auto p_left_dcol  = cudf::column_device_view::create(left_col);
  auto p_right_dcol = cudf::column_device_view::create(right_col);
  auto p_out_dcol   = cudf::mutable_column_device_view::create(out_col);

  auto left_valid  = *p_left_dcol;
  auto right_valid = *p_right_dcol;
  auto out_valid   = *p_out_dcol;

  //these tests in the legacy code
  //tested the null_mask buffer against nullptr,
  //not if there were nulls, which may not be
  //equivalent with semantics below...
  //
  //in fact, the null_mask being nullptr is
  //equivalent to ALL_VALID (see types.hpp comment on
  //UNALLOCATED);
  //this is not the meaning of
  //left_have_valids and right_have_valids non-template
  //bool params (which indicate whether the corresponding
  //null_maks buffers are non-nullptr<true> or not<false>);
  //
  //
  if (p_left_dcol->has_nulls()) {
    if (p_right_dcol->has_nulls()) {
      materialize_merged_bitmask_kernel<true, true>
        <<<grid_config.num_blocks, grid_config.num_threads_per_block, 0, stream>>>
        (left_valid, right_valid, out_valid, out_col.size(), merged_indices);
    } else {
      materialize_merged_bitmask_kernel<true, false>
        <<<grid_config.num_blocks, grid_config.num_threads_per_block, 0, stream>>>
        (left_valid, right_valid, out_valid, out_col.size(), merged_indices);
    }
  } else {
    if (p_right_dcol->has_nulls()) {
      materialize_merged_bitmask_kernel<false, true>
        <<<grid_config.num_blocks, grid_config.num_threads_per_block, 0, stream>>>
        (left_valid, right_valid, out_valid, out_col.size(), merged_indices);
    } else {
      //TODO: just memset all the bits to ALL_VALID
      //
      materialize_merged_bitmask_kernel<false, false>
        <<<grid_config.num_blocks, grid_config.num_threads_per_block, 0, stream>>>
        (left_valid, right_valid, out_valid, out_col.size(), merged_indices);
    }
  }

  CHECK_STREAM(stream);
}
  
/**
 * @brief Generates the row indices and source side (left or right) in accordance with the index columns.
 *
 *
 * @tparam index_type Indicates the type to be used to collect index and side information;
 * @param[in] left_table The left table_view to be merged
 * @param[in] right_tbale The right table_view to be merged
 * @param[in] column_order Sort order types of index columns
 * @param[in] null_precedence Array indicating the order of nulls with respect to non-nulls for the index columns
 * @param[in] nullable Flag indicating if at least one of the table_view arguments has nulls (defaults to true)
 * @param[in] stream CUDA stream (defaults to nullptr)
 *
 * @Returns A table containing sorted data from left_table and right_table 
 */

  //BUG: it reverses left-right results
  //
rmm::device_vector<index_type>
generate_merged_indices(cudf::table_view const& left_table,
                        cudf::table_view const& right_table,
                        std::vector<cudf::order> const& column_order,
                        std::vector<cudf::null_order> const& null_precedence,
                        bool nullable = true,
                        cudaStream_t stream = nullptr) {

    const cudf::size_type left_size  = left_table.num_rows();
    const cudf::size_type right_size = right_table.num_rows();
    const cudf::size_type total_size = left_size + right_size;

    thrust::constant_iterator<side> left_side(side::LEFT);
    thrust::constant_iterator<side> right_side(side::RIGHT);

    auto left_indices = thrust::make_counting_iterator(static_cast<cudf::size_type>(0));
    auto right_indices = thrust::make_counting_iterator(static_cast<cudf::size_type>(0));

    auto left_begin_zip_iterator = thrust::make_zip_iterator(thrust::make_tuple(left_side, left_indices));
    auto right_begin_zip_iterator = thrust::make_zip_iterator(thrust::make_tuple(right_side, right_indices));

    auto left_end_zip_iterator = thrust::make_zip_iterator(thrust::make_tuple(left_side + left_size, left_indices + left_size));
    auto right_end_zip_iterator = thrust::make_zip_iterator(thrust::make_tuple(right_side + right_size, right_indices + right_size));

    rmm::device_vector<index_type> merged_indices(total_size);
    
    auto lhs_device_view = cudf::table_device_view::create(left_table, stream);
    auto rhs_device_view = cudf::table_device_view::create(right_table, stream);

    rmm::device_vector<cudf::order> d_column_order(column_order); 
    
    auto exec_pol = rmm::exec_policy(stream);
    if (nullable){
      rmm::device_vector<cudf::null_order> d_null_precedence(null_precedence);
      
      auto ineq_op =
        cudf::experimental::row_lexicographic_tagged_comparator<true>(*lhs_device_view,
                                                                      *rhs_device_view,
                                                                      d_column_order.data().get(),
                                                                      d_null_precedence.data().get());
      
        thrust::merge(exec_pol->on(stream),
                    left_begin_zip_iterator,
                    left_end_zip_iterator,
                    right_begin_zip_iterator,
                    right_end_zip_iterator,
                    merged_indices.begin(),
                      [ineq_op] __device__ (index_type const & left_tuple,
                                            index_type const & right_tuple) {
                        return ineq_op(left_tuple, right_tuple);
                    });			        
    } else {
      auto ineq_op =
        cudf::experimental::row_lexicographic_tagged_comparator<false>(*lhs_device_view,
                                                                       *rhs_device_view,
                                                                       d_column_order.data().get()); 
        thrust::merge(exec_pol->on(stream),
                    left_begin_zip_iterator,
                    left_end_zip_iterator,
                    right_begin_zip_iterator,
                    right_end_zip_iterator,
                    merged_indices.begin(),
                      [ineq_op] __device__ (index_type const & left_tuple,
                                            index_type const & right_tuple) {
                        return ineq_op(left_tuple, right_tuple);
                          
                    });					        
    }

    CHECK_STREAM(stream);

    return merged_indices;
}

} // namespace

namespace cudf {
namespace experimental { 
namespace detail {

//work-in-progress:
//
//generate merged column
//given row order of merged tables
//(ordered according to indices of key_cols)
//and the 2 columns to merge
//
struct ColumnMerger
{
  using VectorI = rmm::device_vector<index_type>;
  explicit ColumnMerger(VectorI const& row_order,
                        rmm::mr::device_memory_resource* mr = rmm::mr::get_default_resource(),
                        cudaStream_t stream = nullptr):
    dv_row_order_(row_order),
    mr_(mr),
    stream_(stream)
  {
  }
  
  // column merger operator;
  //
  template<typename ElemenT>//required: column type
  std::enable_if_t<cudf::is_fixed_width<ElemenT>(),
                   std::unique_ptr<cudf::column>>
  operator()(cudf::column_view const& lcol, cudf::column_view const& rcol) const
  {
    auto lsz = lcol.size();
    auto merged_size = lsz + rcol.size();
    auto type = lcol.type();
    
    std::unique_ptr<cudf::column> p_merged_col = cudf::experimental::allocate_like(lcol, merged_size);

    //"gather" data from lcol, rcol according to dv_row_order_ "map"
    //(directly calling gather() won't work because
    // lcol, rcol indices overlap!)
    //
    cudf::mutable_column_view merged_view = p_merged_col->mutable_view();

    //initialize null_mask to all valid:
    //
    //Note: this initialization in conjunction with _conditionally_
    //calling materialze_bitmask() below covers the case
    //materialize_merged_bitmask_kernel<false, false>()
    //which won't be called anymore (because of the _condition_ below)
    //
    cudf::set_null_mask(merged_view.null_mask(),
                        merged_view.size(),
                        ALL_VALID,
                        stream_);

    //to resolve view.data()'s types use: ElemenT
    //
    ElemenT const* p_d_lcol = lcol.data<ElemenT>();
    ElemenT const* p_d_rcol = rcol.data<ElemenT>();
        
    auto exe_pol = rmm::exec_policy(stream_);
    
    //capture lcol, rcol
    //and "gather" into merged_view.data()[indx_merged]
    //from lcol or rcol, depending on side;
    //
    thrust::transform(exe_pol->on(stream_),
                      dv_row_order_.begin(), dv_row_order_.end(),
                      merged_view.begin<ElemenT>(),
                      [p_d_lcol, p_d_rcol] __device__ (index_type const& index_pair){
                       auto side = thrust::get<0>(index_pair);
                       auto index = thrust::get<1>(index_pair);
                       
                       ElemenT val = (side == side::LEFT ? p_d_lcol[index] : p_d_rcol[index]);
                       return val;
                      }
                     );

    //cudaDeviceSynchronize();//? nope...these two could proceed concurrently


    //CAVEAT: conditional call below is erroneous without
    //set_null_mask() call (see TODO above):
    //
    if (lcol.has_nulls() || rcol.has_nulls())
      //resolve null mask:
      //
      materialize_bitmask(lcol,
                          rcol,
                          merged_view,
                          dv_row_order_.data().get(),
                          stream_);
                   
    return p_merged_col;
  }

  //specialization for string...?
  //or should use `cudf::string_view` instead?
  //
  template<typename ElemenT>//required: column type
  std::enable_if_t<not cudf::is_fixed_width<ElemenT>(),
                   std::unique_ptr<cudf::column>>
  operator()(cudf::column_view const& lcol, cudf::column_view const& rcol) const
  {
    //for now...
    CUDF_FAIL("Non fixed-width types are not supported");

    // TODO: separate PR for strins support:
    //
    // auto column = strings::detail::merge( strings_column_view(lcol),
    //                                       strings_column_view(rcol),
    //                                       dv_row_order_.begin(),
    //                                       dv_row_order_.end(),
    //                                       mr_,
    //                                       stream_);
    
    // if (lcol.has_nulls() || rcol.has_nulls())
    //   {
    //     auto merged_view = column->mutable_view();
    //     materialize_bitmask(lcol,
    //                         rcol,
    //                         merged_view,
    //                         dv_row_order_.data().get(),
    //                         stream_);
    //   }
    // return column;
  }

private:
  VectorI const& dv_row_order_;
  rmm::mr::device_memory_resource* mr_;
  cudaStream_t stream_;
  
  //see `class element_relational_comparator` in `cpp/include/cudf/table/row_operators.cuh` as a model;
};
  

  std::unique_ptr<cudf::experimental::table> merge(cudf::table_view const& left_table,
                                                   cudf::table_view const& right_table,
                                                   std::vector<cudf::size_type> const& key_cols,
                                                   std::vector<cudf::order> const& column_order,
                                                   std::vector<cudf::null_order> const& null_precedence,
                                                   rmm::mr::device_memory_resource* mr,
                                                   cudaStream_t stream = nullptr) {
    auto n_cols = left_table.num_columns();
    CUDF_EXPECTS( n_cols == right_table.num_columns(), "Mismatched number of columns");
    if (left_table.num_columns() == 0) {
      return cudf::experimental::empty_like(left_table);
    }

    CUDF_EXPECTS(cudf::have_same_types(left_table, right_table), "Mismatched column types");

    auto keys_sz = key_cols.size(); 
    CUDF_EXPECTS( keys_sz > 0, "Empty key_cols");
    CUDF_EXPECTS( keys_sz <= static_cast<size_t>(left_table.num_columns()), "Too many values in key_cols");
    CUDF_EXPECTS( keys_sz == column_order.size(), "Mismatched number of index columns and order specifiers");
    
    if (not column_order.empty())
      {
        CUDF_EXPECTS(key_cols.size() == column_order.size(), "Mismatched size between key_cols and column_order");

        CUDF_EXPECTS(column_order.size() <= static_cast<size_t>(left_table.num_columns()), "Too many values in column_order");
      }

    //collect index columns for lhs, rhs, resp.
    //
    std::vector<cudf::column_view> left_index_cols;
    std::vector<cudf::column_view> right_index_cols;
    bool nullable{false};

    //TODO: use `table_view select(std::vector<cudf::size_type> const& column_indices) const;`
    //(when it becomes available; currently in PR# 3144)
    //
    for(auto&& indx: key_cols)
      {
        const cudf::column_view& left_col = left_table.column(indx);
        const cudf::column_view& right_col= right_table.column(indx);

        //for the purpose of generating merged indices, there's
        //no point looking into _all_ table columns for nulls,
        //just the index ones:
        //
        if( left_col.has_nulls() || right_col.has_nulls() )
          nullable = true;
        
        left_index_cols.push_back(left_col);
        right_index_cols.push_back(right_col);
      }
    cudf::table_view index_left_view{left_index_cols};   //table_view move cnstr. would be nice
    cudf::table_view index_right_view{right_index_cols}; //same...

    //extract merged row order according to indices:
    //
    rmm::device_vector<index_type>
      merged_indices = generate_merged_indices(index_left_view,
                                               index_right_view,
                                               column_order,
                                               null_precedence,
                                               nullable);

    //create merged table:
    //
    std::vector<std::unique_ptr<column>> v_merged_cols;
    v_merged_cols.reserve(n_cols);

    ColumnMerger merger{merged_indices, mr, stream};
    
    for(auto i=0;i<n_cols;++i)
      {
        const auto& left_col = left_table.column(i);
        const auto& right_col= right_table.column(i);

        //not clear yet what must be done for STRING:
        //
        //if( left_col.type().id() != STRING )
        //  continue;//?

        auto merged = cudf::experimental::type_dispatcher(left_col.type(),
                                                          merger,
                                                          left_col,
                                                          right_col);
        v_merged_cols.emplace_back(std::move(merged));
      }
    
    return std::make_unique<cudf::experimental::table>(std::move(v_merged_cols));
}

}  // namespace detail

std::unique_ptr<cudf::experimental::table> merge(table_view const& left_table,
                                                 table_view const& right_table,
                                                 std::vector<cudf::size_type> const& key_cols,
                                                 std::vector<cudf::order> const& column_order,
                                                 std::vector<cudf::null_order> const& null_precedence,
                                                 rmm::mr::device_memory_resource* mr){
  return detail::merge(left_table, right_table, key_cols, column_order, null_precedence, mr);
}

}  // namespace experimental
}  // namespace cudf
