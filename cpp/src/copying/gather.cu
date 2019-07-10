/*
 * Copyright (c) 2018-2019, NVIDIA CORPORATION.
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

#include <cudf/cudf.h>
#include <utilities/cudf_utils.h>
#include <cudf/copying.hpp>
#include <utilities/bit_util.cuh>
#include <utilities/type_dispatcher.hpp>

#include <cudf/table.hpp>
#include <string/nvcategory_util.hpp>

#include <algorithm>

#include <thrust/gather.h>
#include <table/device_table.cuh>

#include <cub/cub.cuh>
#include <utilities/column_utils.hpp>
#include <utilities/cuda_utils.hpp>

using bit_mask::bit_mask_t;

namespace cudf {
namespace detail {

constexpr int warp_size = 32;

/**---------------------------------------------------------------------------*
 * @brief Function object to check if an index is within the bounds [begin,
 * end).
 *
 *---------------------------------------------------------------------------**/
struct bounds_checker {
  gdf_index_type const begin;
  gdf_index_type const end;

  __device__ bounds_checker(gdf_index_type begin_, gdf_index_type end_)
      : begin{begin_}, end{end_} {}

  __device__ __forceinline__ bool operator()(gdf_index_type const index) {
    return ((index >= begin) && (index < end));
  }
};

using CountType = gdf_size_type;
template <class BitType, int lane = 0>
__device__ __inline__ CountType single_lane_reduce(BitType f) {
  static __shared__ CountType smem[warp_size];

  int lane_id = (threadIdx.x % warp_size);
  int warp_id = (threadIdx.x / warp_size);

  // Assuming one lane of each warp holds the value that we want to perform
  // reduction
  if (lane_id == lane) {
    smem[warp_id] = __popc(f);
  }
  __syncthreads();

  if (warp_id == 0) {
    // Here I am assuming maximum block size is 1024 and 1024 / 32 = 32
    // so one single warp is enough to do the reduction over different warps
    f = (lane_id < (blockDim.x / warp_size)) ? smem[lane_id] : 0;

    __shared__ typename cub::WarpReduce<CountType>::TempStorage temp_storage;
    f = cub::WarpReduce<CountType>(temp_storage).Sum(f);
  }

  return f;
}

template <bool check_bounds>
__global__ void gather_bitmask_kernel(const bit_mask_t* const* source_valid,
                                      gdf_size_type num_source_rows,
                                      const gdf_index_type* gather_map,
                                      bit_mask_t** destination_valid,
                                      gdf_size_type num_destination_rows,
                                      gdf_size_type* d_count,
                                      gdf_size_type num_columns) {
  for (gdf_index_type i = 0; i < num_columns; i++) {
    const bit_mask_t* source_valid_col = source_valid[i];
    bit_mask_t* destination_valid_col = destination_valid[i];

    const bool src_has_nulls = source_valid_col != nullptr;
    const bool dest_has_nulls = destination_valid_col != nullptr;

    if (dest_has_nulls) {
      gdf_index_type destination_row_base = blockIdx.x * blockDim.x;

      gdf_size_type valid_count_accumulate = 0;

      while (destination_row_base < num_destination_rows) {
        gdf_index_type destination_row = destination_row_base + threadIdx.x;

        const bool thread_active = destination_row < num_destination_rows;
        gdf_index_type source_row =
            thread_active ? gather_map[destination_row] : 0;

        const uint32_t active_threads =
            __ballot_sync(0xffffffff, thread_active);

        bool source_bit_is_valid;
        if (check_bounds) {
          if (0 <= source_row && source_row < num_source_rows) {
            source_bit_is_valid =
                src_has_nulls ? bit_mask::is_valid(source_valid_col, source_row)
                              : true;
          } else {
            // If gather_map does not include this row we should just keep the
            // original value,
            source_bit_is_valid =
                bit_mask::is_valid(destination_valid_col, destination_row);
          }
        } else {
          source_bit_is_valid =
              src_has_nulls ? bit_mask::is_valid(source_valid_col, source_row)
                            : true;
        }

        // Use ballot to find all valid bits in this warp and create the output
        // bitmask element
        const uint32_t valid_warp =
            __ballot_sync(active_threads, source_bit_is_valid);

        const gdf_index_type valid_index =
            cudf::util::detail::bit_container_index<bit_mask_t>(
                destination_row);
        // Only one thread writes output
        if (0 == threadIdx.x % warp_size && thread_active) {
          destination_valid_col[valid_index] = valid_warp;
        }
        valid_count_accumulate += single_lane_reduce(valid_warp);

        destination_row_base += blockDim.x * gridDim.x;
      }
      if (threadIdx.x == 0) {
        atomicAdd(d_count + i, valid_count_accumulate);
      }
    }
  }
}

/**---------------------------------------------------------------------------*
 * @brief Function object for gathering a type-erased
 * gdf_column. To be used with the cudf::type_dispatcher.
 *
 *---------------------------------------------------------------------------**/
struct column_gatherer {
  /**---------------------------------------------------------------------------*
   * @brief Type-dispatched function to gather from one column to another based
   * on a `gather_map`.
   *
   * @tparam ColumnType Dispatched type for the column being gathered
   * @param source_column The column to gather from
   * @param gather_map Array of indices that maps source elements to destination
   * elements
   * @param destination_column The column to gather into
   * @param check_bounds Optionally perform bounds checking on the values of
   * `gather_map`
   * @param stream Optional CUDA stream on which to execute kernels
   *---------------------------------------------------------------------------**/
  template <typename ColumnType>
  void operator()(gdf_column const* source_column,
                  gdf_index_type const gather_map[],
                  gdf_column* destination_column, bool check_bounds = false,
                  cudaStream_t stream = 0) {
    ColumnType const* const source_data{
        static_cast<ColumnType const*>(source_column->data)};
    ColumnType* destination_data{
        static_cast<ColumnType*>(destination_column->data)};

    gdf_size_type const num_destination_rows{destination_column->size};

    // If gathering in-place, allocate temporary buffers to hold intermediate
    // results
    bool const in_place{source_data == destination_data};
    if (in_place) {
      RMM_TRY(RMM_ALLOC(&destination_data,
                        sizeof(ColumnType) * num_destination_rows, stream));
    }

    if (check_bounds) {
      thrust::gather_if(rmm::exec_policy(stream)->on(stream), gather_map,
                        gather_map + num_destination_rows, gather_map,
                        source_data, destination_data,
                        bounds_checker{0, source_column->size});
    } else {
      thrust::gather(rmm::exec_policy(stream)->on(stream), gather_map,
                     gather_map + num_destination_rows, source_data,
                     destination_data);
    }

    // Copy temporary buffers used for in-place gather to destination column
    if (in_place) {
      thrust::copy(rmm::exec_policy(stream)->on(stream), destination_data,
                   destination_data + num_destination_rows,
                   static_cast<ColumnType*>(destination_column->data));
      RMM_TRY(RMM_FREE(destination_data, stream));
    }
    CHECK_STREAM(stream);
  }
};

void gather(table const* source_table, gdf_index_type const gather_map[],
            table* destination_table, bool check_bounds) {
  CUDF_EXPECTS(nullptr != source_table, "source table is null");
  CUDF_EXPECTS(nullptr != destination_table, "destination table is null");

  // If the destination is empty, return immediately as there is nothing to
  // gather
  if (0 == destination_table->num_rows()) {
    return;
  }

  CUDF_EXPECTS(nullptr != gather_map, "gather_map is null");
  CUDF_EXPECTS(source_table->num_columns() == destination_table->num_columns(),
               "Mismatched number of columns");
  const gdf_size_type n_cols = source_table->num_columns();

  // We create (n_cols+1) streams for the (n_cols+1) kernels we are gonna
  // launch.
  std::vector<util::cuda::scoped_stream> v_stream(n_cols + 1);

  for (gdf_size_type i = 0; i < n_cols; i++) {
    // Perform sanity checks
    gdf_column* dest_col = destination_table->get_column(i);
    const gdf_column* src_col = source_table->get_column(i);

    CUDF_EXPECTS(src_col->dtype == dest_col->dtype, "Column type mismatch");

    // If source table has 0 rows it is okay to have null buffers
    CUDF_EXPECTS(src_col->data != nullptr || source_table->num_rows() == 0,
                 "Missing source data buffer.");
    CUDF_EXPECTS(dest_col->data != nullptr, "Missing source data buffer.");

    // The data gather for n columns will be put on the first n streams
    cudf::type_dispatcher(src_col->dtype, column_gatherer{}, src_col,
                          gather_map, dest_col, check_bounds, v_stream[i]);

    const bool src_has_nulls = src_col->valid != nullptr;
    const bool dest_has_nulls = dest_col->valid != nullptr;
    // If the source column has a valid buffer, the destination column must also
    // have one
    CUDF_EXPECTS((src_has_nulls && dest_has_nulls) || (!src_has_nulls),
                 "Missing destination validity buffer");
  }

  // The bitmask operations will be put on the last stream.
  cudaStream_t bit_stream = v_stream[n_cols];

  // Allocate memory for bitmask reduction
  gdf_size_type* d_count_p;
  RMM_TRY(RMM_ALLOC(&d_count_p, sizeof(gdf_size_type) * n_cols, bit_stream));
  CUDA_TRY(cudaMemsetAsync(d_count_p, 0, sizeof(gdf_size_type) * n_cols,
                           bit_stream));

  std::vector<bit_mask_t*> h_bit_src(n_cols);
  std::vector<bit_mask_t*> h_bit_dest(n_cols);

  for (gdf_size_type i = 0; i < n_cols; i++) {
    const gdf_column* dest_col = destination_table->get_column(i);
    h_bit_src[i] =
        reinterpret_cast<bit_mask_t*>(source_table->get_column(i)->valid);
    // Allocate inplace buffer
    if (dest_col->valid != nullptr &&
        dest_col->valid == source_table->get_column(i)->valid) {
      gdf_size_type num_bitmask_elements =
          gdf_num_bitmask_elements(dest_col->size);
      RMM_TRY(RMM_ALLOC(&h_bit_dest[i], num_bitmask_elements, bit_stream));
    } else {
      h_bit_dest[i] = reinterpret_cast<bit_mask_t*>(dest_col->valid);
    }
  }

  // In the following we allocate the device array thats hold the valid
  // bits.
  bit_mask_t** d_bit_src;
  bit_mask_t** d_bit_dest;
  RMM_TRY(RMM_ALLOC(&d_bit_src, sizeof(bit_mask_t*) * n_cols, bit_stream));
  RMM_TRY(RMM_ALLOC(&d_bit_dest, sizeof(bit_mask_t*) * n_cols, bit_stream));

  CUDA_TRY(cudaMemcpyAsync(d_bit_src, h_bit_src.data(),
                           n_cols * sizeof(bit_mask_t*), cudaMemcpyHostToDevice,
                           bit_stream));
  CUDA_TRY(cudaMemcpyAsync(d_bit_dest, h_bit_dest.data(),
                           n_cols * sizeof(bit_mask_t*), cudaMemcpyHostToDevice,
                           bit_stream));

  auto f =
      check_bounds ? gather_bitmask_kernel<true> : gather_bitmask_kernel<false>;

  int gather_grid_size;
  int gather_block_size;
  CUDA_TRY(cudaOccupancyMaxPotentialBlockSize(&gather_grid_size,
                                              &gather_block_size, f));

  f<<<gather_grid_size, gather_block_size, 0, bit_stream>>>(
      d_bit_src, source_table->num_rows(), gather_map, d_bit_dest,
      destination_table->num_rows(), d_count_p, n_cols);

  std::vector<gdf_size_type> h_count(n_cols);
  CUDA_TRY(cudaMemcpyAsync(h_count.data(), d_count_p,
                           sizeof(gdf_size_type) * n_cols,
                           cudaMemcpyDeviceToHost, bit_stream));

  // We want to sync the bit_stream here since the null_count update has be
  // after the above memcpy is finished.
  CUDA_TRY(cudaStreamSynchronize(bit_stream));

  for (gdf_size_type i = 0; i < destination_table->num_columns(); i++) {
    gdf_column* dest_col = destination_table->get_column(i);
    if (dest_col->valid != nullptr) {
      // Free the inplace buffer
      if (dest_col->valid == source_table->get_column(i)->valid) {
        gdf_size_type num_bitmask_elements =
            gdf_num_bitmask_elements(dest_col->size);
        CUDA_TRY(cudaMemcpyAsync(dest_col->valid, h_bit_dest[i],
                                 num_bitmask_elements, cudaMemcpyDeviceToDevice,
                                 bit_stream));
        RMM_TRY(RMM_FREE(h_bit_dest[i], bit_stream));
      }
      dest_col->null_count = dest_col->size - h_count[i];
    } else {
      dest_col->null_count = 0;
    }
  }

  // Free the dynamically allocated buffers
  RMM_TRY(RMM_FREE(d_bit_src, bit_stream));
  RMM_TRY(RMM_FREE(d_bit_dest, bit_stream));

  RMM_TRY(RMM_FREE(d_count_p, bit_stream));
}

}  // namespace detail

void gather(table const* source_table, gdf_index_type const gather_map[],
            table* destination_table) {
  detail::gather(source_table, gather_map, destination_table, false);
  nvcategory_gather_table(*source_table, *destination_table);
}

}  // namespace cudf
