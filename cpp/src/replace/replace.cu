/*
 * Copyright 2018 BlazingDB, Inc.

 *     Copyright 2018 Cristhian Alberto Gonzales Castillo <cristhian@blazingdb.com>
 *     Copyright 2018 Alexander Ocsa <alexander@blazingdb.com>
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
#include <thrust/device_ptr.h>
#include <thrust/find.h>
#include <thrust/execution_policy.h>
#include <cub/cub.cuh>
#include <cudf/legacy/interop.hpp>
#include <cudf/copying.hpp>
#include <cudf/replace.hpp>
#include <cudf/detail/replace.hpp>
#include <cudf/cudf.h>
#include <rmm/rmm.h>
#include <cudf/types.hpp>
#include <utilities/error_utils.hpp>
#include <cudf/utilities/type_dispatcher.hpp>
#include <utilities/cudf_utils.h>
#include <utilities/cuda_utils.hpp>
#include <utilities/column_utils.hpp>
#include <cudf/column/column_factories.hpp>
#include <cudf/column/column_view.hpp>
#include <cudf/column/column.hpp>
#include <bitmask/legacy/legacy_bitmask.hpp>
#include <bitmask/legacy/bit_mask.cuh>

using bit_mask::bit_mask_t;

namespace{ //anonymous

static constexpr int warp_size = 32;
static constexpr int BLOCK_SIZE = 256;

// returns the block_sum using the given shared array of warp sums.
template <typename T>
__device__ T sum_warps(T* warp_smem)
{
  T block_sum = 0;

   if (threadIdx.x < warp_size) {
    T my_warp_sum = warp_smem[threadIdx.x];
    __shared__ typename cub::WarpReduce<T>::TempStorage temp_storage;
    block_sum = cub::WarpReduce<T>(temp_storage).Sum(my_warp_sum);
  }
  return block_sum;
}

// return the new_value for output column at index `idx`
template<class T, bool replacement_has_nulls>
__device__ auto get_new_value(gdf_size_type         idx,
                           const T* __restrict__ input_data,
                           const T* __restrict__ values_to_replace_begin,
                           const T* __restrict__ values_to_replace_end,
                           const T* __restrict__       d_replacement_values,
                           bit_mask_t const * __restrict__ replacement_valid)
   {
     auto found_ptr = thrust::find(thrust::seq, values_to_replace_begin,
                                      values_to_replace_end, input_data[idx]);
     T new_value{0};
     bool output_is_valid{true};

     if (found_ptr != values_to_replace_end) {
       auto d = thrust::distance(values_to_replace_begin, found_ptr);
       new_value = d_replacement_values[d];
       if (replacement_has_nulls) {
         output_is_valid = bit_mask::is_valid(replacement_valid, d);
       }
     } else {
       new_value = input_data[idx];
     }
     return thrust::make_pair(new_value, output_is_valid);
   }

  /* --------------------------------------------------------------------------*/
  /**
   * @brief Kernel that replaces elements from `output_data` given the following
   *        rule: replace all `values_to_replace[i]` in [values_to_replace_begin`,
   *        `values_to_replace_end`) present in `output_data` with `d_replacement_values[i]`.
   *
   * @tparam input_has_nulls `true` if output column has valid mask, `false` otherwise
   * @tparam replacement_has_nulls `true` if replacement_values column has valid mask, `false` otherwise
   * The input_has_nulls and replacement_has_nulls template parameters allows us to specialize
   * this kernel for the different scenario for performance without writing different kernel.
   *
   * @param[in] input_data Device array with the data to be modified
   * @param[in] input_valid Valid mask associated with input_data
   * @param[out] output_data Device array to store the data from input_data
   * @param[out] output_valid Valid mask associated with output_data
   * @param[out] output_valid_count #valid in output column
   * @param[in] nrows # rows in `output_data`
   * @param[in] values_to_replace_begin Device pointer to the beginning of the sequence
   * of old values to be replaced
   * @param[in] values_to_replace_end  Device pointer to the end of the sequence
   * of old values to be replaced
   * @param[in] d_replacement_values Device array with the new values
   * @param[in] replacement_valid Valid mask associated with d_replacement_values
   *
   * @returns
   */
  /* ----------------------------------------------------------------------------*/
  template <class T,
            bool input_has_nulls, bool replacement_has_nulls>
  __global__
  void replace_kernel(const T* __restrict__           input_data,
                      bit_mask_t const * __restrict__ input_valid,
                      T * __restrict__          output_data,
                      bit_mask_t * __restrict__ output_valid,
                      gdf_size_type * __restrict__    output_valid_count,
                      gdf_size_type                   nrows,
                      const T* __restrict__ values_to_replace_begin,
                      const T* __restrict__ values_to_replace_end,
                      const T* __restrict__           d_replacement_values,
                      bit_mask_t const * __restrict__ replacement_valid)
  {
  gdf_size_type i = blockIdx.x * blockDim.x + threadIdx.x;

  uint32_t active_mask = 0xffffffff;
  active_mask = __ballot_sync(active_mask, i < nrows);
  __shared__ uint32_t valid_sum[warp_size];

  // init shared memory for block valid counts
  if (input_has_nulls or replacement_has_nulls){
    if(threadIdx.x < warp_size) valid_sum[threadIdx.x] = 0;
    __syncthreads();
  }

  while (i < nrows) {
    bool output_is_valid = true;
    uint32_t bitmask = 0xffffffff;

    if (input_has_nulls) {
      bool const input_is_valid{bit_mask::is_valid(input_valid, i)};
      output_is_valid = input_is_valid;

      bitmask = __ballot_sync(active_mask, input_is_valid);

      if (input_is_valid) {
        thrust::tie(output_data[i], output_is_valid)  =
            get_new_value<T, replacement_has_nulls>(i, input_data,
                                      values_to_replace_begin,
                                      values_to_replace_end,
                                      d_replacement_values,
                                      replacement_valid);
      }

    } else {
       thrust::tie(output_data[i], output_is_valid) =
            get_new_value<T, replacement_has_nulls>(i, input_data,
                                      values_to_replace_begin,
                                      values_to_replace_end,
                                      d_replacement_values,
                                      replacement_valid);
    }

    /* output valid counts calculations*/
    if (input_has_nulls or replacement_has_nulls){

      bitmask &= __ballot_sync(active_mask, output_is_valid);

      if(0 == (threadIdx.x % warp_size)){
        output_valid[(int)(i/warp_size)] = bitmask;
        valid_sum[(int)(threadIdx.x / warp_size)] += __popc(bitmask);
      }
    }

    i += blockDim.x * gridDim.x;
    active_mask = __ballot_sync(active_mask, i < nrows);
  }
  if(input_has_nulls or replacement_has_nulls){
    __syncthreads(); // waiting for the valid counts of each warp to be ready

    // Compute total valid count for this block and add it to global count
    uint32_t block_valid_count = sum_warps<uint32_t>(valid_sum);

    // one thread computes and adds to output_valid_count
    if (threadIdx.x < warp_size && 0 == (threadIdx.x % warp_size)) {
      atomicAdd(output_valid_count, block_valid_count);
    }
  }
}

  /* --------------------------------------------------------------------------*/
  /**
   * @brief Functor called by the `type_dispatcher` in order to invoke and instantiate
   *        `replace_kernel` with the appropriate data types.
   */
  /* ----------------------------------------------------------------------------*/
  struct replace_kernel_forwarder {
    template <typename col_type>
    void operator()(cudf::column_view const& input_col,
                    cudf::column_view const& values_to_replace,
                    cudf::column_view const& replacement_values,
                    cudf::mutable_column_view& output,
                    cudaStream_t stream = 0,
                    rmm::mr::device_memory_resource* mr = rmm::mr::get_default_resource())
    {
      const bool input_has_nulls = input_col.has_nulls();
      const bool replacement_has_nulls = replacement_values.has_nulls();

      cudf::size_type *valid_count = nullptr;
      if (output.nullable()) {
        valid_count = reinterpret_cast<gdf_size_type*>(mr->allocate(sizeof(gdf_size_type), stream));
        CUDA_TRY(cudaMemsetAsync(valid_count, 0, sizeof(gdf_size_type), stream));
      }

      cudf::util::cuda::grid_config_1d grid{output.size(), BLOCK_SIZE, 1};

      auto replace = replace_kernel<col_type, true, true>;

      if (input_has_nulls){
        if (replacement_has_nulls){
          replace = replace_kernel<col_type, true, true>;
        }else{
          replace = replace_kernel<col_type, true, false>;
        }
      }else{
        if (replacement_has_nulls){
          replace = replace_kernel<col_type, false, true>;
        }else{
          replace = replace_kernel<col_type, false, false>;
        }
      }
      replace<<<grid.num_blocks, BLOCK_SIZE, 0, stream>>>(
                                             input_col.data<col_type>(),
                                             input_col.null_mask(),
                                             output.data<col_type>(),
                                             output.null_mask(),
                                             valid_count,
                                             output.size(),
                                             values_to_replace.data<col_type>(),
                                             values_to_replace.data<col_type>() + replacement_values.size(),
                                             replacement_values.data<col_type>(),
                                             replacement_values.null_mask());

      if(valid_count != nullptr){
        cudf::size_type valids {0};
        CUDA_TRY(cudaMemcpyAsync(&valids,
                                 valid_count,
                                 sizeof(cudf::size_type),
                                 cudaMemcpyDefault,
                                 stream));
        output.set_null_count(output.size() - valids);
        mr->deallocate(valid_count, sizeof(cudf::size_type), stream);
      }
    }
  };

  template<>
  void replace_kernel_forwarder::operator()<cudf::string_view> (cudf::column_view const& input_col,
                                                                cudf::column_view const& values_to_replace,
                                                                cudf::column_view const& replacement_values,
                                                                cudf::mutable_column_view& output,
                                                                cudaStream_t stream,
                                                                rmm::mr::device_memory_resource* mr) {
    CUDF_FAIL("Strings are not supported yet for replacement.");
  }

 } //end anonymous namespace

namespace cudf{
namespace detail {
  std::unique_ptr<cudf::column> find_and_replace_all(cudf::column_view const& input_col,
                                                     cudf::column_view const& values_to_replace,
                                                     cudf::column_view const& replacement_values,
                                                     cudaStream_t stream,
                                                     rmm::mr::device_memory_resource* mr) {
    if (0 == input_col.size() )
    {
      return std::unique_ptr<cudf::column>(new cudf::column(input_col));
    }

    if (0 == values_to_replace.size() || 0 == replacement_values.size())
    {
      return std::unique_ptr<cudf::column>(new cudf::column(input_col));
    }

    CUDF_EXPECTS(values_to_replace.size() == replacement_values.size(),
                 "values_to_replace and replacement_values size mismatch.");
    CUDF_EXPECTS(input_col.type() == values_to_replace.type() &&
                 input_col.type() == replacement_values.type(),
                 "Columns type mismatch.");
    CUDF_EXPECTS(input_col.data<int32_t>() != nullptr, "Null input data.");
    CUDF_EXPECTS(values_to_replace.data<int32_t>() != nullptr && replacement_values.data<int32_t>() != nullptr,
                 "Null replace data.");
    CUDF_EXPECTS(values_to_replace.nullable() == false,
                 "Nulls are in values_to_replace column.");

    std::unique_ptr<column> output;
    if (input_col.nullable() || replacement_values.nullable()) {
      output = make_numeric_column(input_col.type(), input_col.size(), UNINITIALIZED, stream, mr);
    }
    else
      output = make_numeric_column(input_col.type(), input_col.size(), UNALLOCATED, stream, mr);

    cudf::mutable_column_view outputView = (*output).mutable_view();
    cudf::experimental::type_dispatcher(input_col.type(),
                                        replace_kernel_forwarder { },
                                        input_col,
                                        values_to_replace,
                                        replacement_values,
                                        outputView,
                                        stream,
                                        mr);

    CHECK_STREAM(stream);
    return output;
  }

} //end details
namespace experimental {
/* --------------------------------------------------------------------------*/
/**
 * @brief Replace elements from `input_col` according to the mapping `values_to_replace` to
 *        `replacement_values`, that is, replace all `values_to_replace[i]` present in `input_col`
 *        with `replacement_values[i]`.
 *
 * @param[in] col gdf_column with the data to be modified
 * @param[in] values_to_replace gdf_column with the old values to be replaced
 * @param[in] replacement_values gdf_column with the new values
 *
 * @returns output gdf_column with the modified data
 */
/* ----------------------------------------------------------------------------*/
  std::unique_ptr<cudf::column> find_and_replace_all(cudf::column_view const& input_col,
                                                     cudf::column_view const& values_to_replace,
                                                     cudf::column_view const& replacement_values,
                                                     rmm::mr::device_memory_resource* mr){
    return detail::find_and_replace_all(input_col, values_to_replace, replacement_values, 0, mr);
  }
} //end experimental
} //end cudf

namespace{ //anonymous

using bit_mask::bit_mask_t;

template <typename Type>
__global__
void replace_nulls_with_scalar(gdf_size_type size,
                               const Type* __restrict__ in_data,
                               const bit_mask_t* __restrict__ in_valid,
                               const Type* __restrict__ replacement,
                               Type* __restrict__ out_data)
{
  int tid = threadIdx.x;
  int blkid = blockIdx.x;
  int blksz = blockDim.x;
  int gridsz = gridDim.x;

  int start = tid + blkid * blksz;
  int step = blksz * gridsz;

  for (int i=start; i<size; i+=step) {
    out_data[i] = bit_mask::is_valid(in_valid, i)? in_data[i] : *replacement;
  }
}


template <typename Type>
__global__
void replace_nulls_with_column(gdf_size_type size,
                               Type const* __restrict__ in_data,
                               cudf::bitmask_type const* __restrict__ in_valid,
                               Type const* __restrict__ replacement,
                               Type* __restrict__ out_data)
{
  int tid = threadIdx.x;
  int blkid = blockIdx.x;
  int blksz = blockDim.x;
  int gridsz = gridDim.x;

  int start = tid + blkid * blksz;
  int step = blksz * gridsz;

  for (int i=start; i<size; i+=step) {
    out_data[i] = bit_mask::is_valid(in_valid, i)? in_data[i] : replacement[i];
  }
}


/* --------------------------------------------------------------------------*/
/**
 * @brief Functor called by the `type_dispatcher` in order to invoke and instantiate
 *        `replace_nulls` with the appropriate data types.
 */
/* ----------------------------------------------------------------------------*/
struct replace_nulls_column_kernel_forwarder {
  template <typename col_type>
  void operator()(cudf::column_view const& input,
                  cudf::column_view const& replacement,
                  cudf::mutable_column_view& output,
                  cudaStream_t stream = 0)
  {
    cudf::size_type nrows = input.size();
    cudf::util::cuda::grid_config_1d grid{nrows, BLOCK_SIZE};

    replace_nulls_with_column<<<grid.num_blocks, BLOCK_SIZE, 0, stream>>>(nrows,
                                                                          input.data<col_type>(),
                                                                          input.null_mask(),
                                                                          replacement.data<col_type>(),
                                                                          output.data<col_type>());

  }
};

template<>
void replace_nulls_column_kernel_forwarder::operator ()<cudf::string_view>(cudf::column_view const& input,
                                                                           cudf::column_view const& replacement,
                                                                           cudf::mutable_column_view& output,
                                                                           cudaStream_t stream){
  CUDF_FAIL("Strings not supported for replacement.");
}


/* --------------------------------------------------------------------------*/
/**
 * @brief Functor called by the `type_dispatcher` in order to invoke and instantiate
 *        `replace_nulls` with the appropriate data types.
 */
/* ----------------------------------------------------------------------------*/
struct replace_nulls_scalar_kernel_forwarder {
  template <typename col_type>
  void operator()(cudf::column_view const& input,
                  const void* replacement,
                  cudf::mutable_column_view& output,
                  cudaStream_t stream = 0,
                  rmm::mr::device_memory_resource* mr = rmm::mr::get_default_resource())
  {
    cudf::size_type nrows = input.size();
    cudf::util::cuda::grid_config_1d grid{nrows, BLOCK_SIZE};

    auto t_replacement = static_cast<const col_type*>(replacement);
    col_type* d_replacement = reinterpret_cast<col_type*>(mr->allocate(sizeof(col_type), stream));
    CUDA_TRY(cudaMemcpyAsync(d_replacement, t_replacement, sizeof(col_type), cudaMemcpyHostToDevice, stream));

    replace_nulls_with_scalar<<<grid.num_blocks, BLOCK_SIZE, 0, stream>>>(nrows,
                                                                          input.data<col_type>(),
                                                                          input.null_mask(),
                                                                          static_cast<const col_type*>(d_replacement),
                                                                          output.data<col_type>());
    mr->deallocate(d_replacement, sizeof(col_type), stream);
  }
};

template<>
void replace_nulls_scalar_kernel_forwarder::operator ()<cudf::string_view>(cudf::column_view const& input,
                                                                           const void* replacement,
                                                                           cudf::mutable_column_view& output,
                                                                           cudaStream_t stream,
                                                                           rmm::mr::device_memory_resource* mr) {
  CUDF_FAIL("Strings not supported for replacement");
}


} //end anonymous namespace


namespace cudf {
namespace detail {

std::unique_ptr<cudf::column> replace_nulls(cudf::column_view const& input,
                                            cudf::column_view const& replacement,
                                            cudaStream_t stream,
                                            rmm::mr::device_memory_resource* mr)
{
  if (input.size() == 0) {
    return std::unique_ptr<cudf::column>(new cudf::column(input));
  }

  CUDF_EXPECTS(nullptr != input.data<int32_t>(), "Null input data");

  if (input.nullable() == false || input.null_count() == 0) {
    return std::unique_ptr<cudf::column>(new cudf::column(input));
  }

  CUDF_EXPECTS(input.type() == replacement.type(), "Data type mismatch");
  CUDF_EXPECTS(replacement.size() == 1 || replacement.size() == input.size(), "Column size mismatch");
  CUDF_EXPECTS(nullptr != replacement.data<int32_t>(), "Null replacement data");
  CUDF_EXPECTS(replacement.nullable() == false || 0 == replacement.null_count(),
               "Invalid replacement data");

  std::unique_ptr<cudf::column> output = make_numeric_column(input.type(),
                                                             input.size(),
                                                             UNALLOCATED,
                                                             stream,
                                                             mr);
  cudf::mutable_column_view outputView = (*output).mutable_view();
  cudf::experimental::type_dispatcher(input.type(),
                                      replace_nulls_column_kernel_forwarder{},
                                      input,
                                      replacement,
                                      outputView,
                                      stream);
  return output;
}


std::unique_ptr<cudf::column> replace_nulls(cudf::column_view const& input,
                                            const gdf_scalar& replacement,
                                            cudaStream_t stream,
                                            rmm::mr::device_memory_resource* mr)
{
  if (input.size() == 0) {
    return std::unique_ptr<cudf::column>(new cudf::column(input));
  }

  CUDF_EXPECTS(nullptr != input.data<int32_t>(), "Null input data");

  if (input.null_count() == 0 || input.nullable() == false) {
    return std::unique_ptr<cudf::column>(new cudf::column(input));
  }

  CUDF_EXPECTS(input.type() == cudf::legacy::gdf_dtype_to_data_type(replacement.dtype), "Data type mismatch");
  CUDF_EXPECTS(true == replacement.is_valid, "Invalid replacement data");

  std::unique_ptr<cudf::column> output = make_numeric_column(input.type(),
                                                             input.size(),
                                                             UNALLOCATED,
                                                             stream,
                                                             mr);
  cudf::mutable_column_view outputView = (*output).mutable_view();
  cudf::experimental::type_dispatcher(input.type(),
                                      replace_nulls_scalar_kernel_forwarder{},
                                      input,
                                      &(replacement.data),
                                      outputView,
                                      stream,
                                      mr);
  return output;
}

}  // namespace detail

namespace experimental {

std::unique_ptr<cudf::column> replace_nulls(cudf::column_view const& input,
                                            cudf::column_view const& replacement,
                                            rmm::mr::device_memory_resource* mr)
{
  return detail::replace_nulls(input, replacement, 0, mr);
}


std::unique_ptr<cudf::column> replace_nulls(cudf::column_view const& input,
                                            const gdf_scalar& replacement,
                                            rmm::mr::device_memory_resource* mr)
{
  return detail::replace_nulls(input, replacement, 0, mr);
}
} //end experimental
}  // namespace cudf
