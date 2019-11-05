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

#pragma once

#include <cudf/cudf.h>
#include <cudf/types.hpp>
#include <cudf/utilities/traits.hpp>
#include <cudf/table/table.hpp>
#include <cudf/table/table_view.hpp>
#include <cudf/detail/copy.hpp>
#include <utilities/device_atomics.cuh>
#include <utilities/cudf_utils.h>
#include <cudf/utilities/error.hpp>
#include <utilities/cuda_utils.hpp>
#include <cudf/utilities/type_dispatcher.hpp>
#include <cudf/null_mask.hpp>
#include <cudf/column/column_device_view.cuh>

#include <utilities/column_utils.hpp>
#include <rmm/thrust_rmm_allocator.h>

#include <cub/cub.cuh>
#include <algorithm>

namespace {

static constexpr int warp_size = 32;

// Compute the count of elements that pass the mask within each block
template <typename Filter, int block_size>
__global__ void compute_block_counts(cudf::size_type  * __restrict__ block_counts,
                                     cudf::size_type size,
                                     cudf::size_type per_thread,
                                     Filter filter)
{
  int tid = threadIdx.x + per_thread * block_size * blockIdx.x;
  int count = 0;

  for (int i = 0; i < per_thread; i++) {
    bool mask_true = (tid < size) && filter(tid);
    count += __syncthreads_count(mask_true);
    tid += block_size;
  }

  if (threadIdx.x == 0) block_counts[blockIdx.x] = count;
}

// Compute the exclusive prefix sum of each thread's mask value within each block
template <int block_size>
__device__ cudf::size_type block_scan_mask(bool mask_true,
                                          cudf::size_type &block_sum)
{
  int offset = 0;

  using BlockScan = cub::BlockScan<cudf::size_type, block_size>;
  __shared__ typename BlockScan::TempStorage temp_storage;
  BlockScan(temp_storage).ExclusiveSum(mask_true, offset, block_sum);

  return offset;
}

template <typename Kernel>
int elements_per_thread(Kernel kernel,
                        cudf::size_type total_size,
                        cudf::size_type block_size)
{
  // calculate theoretical occupancy
  int max_blocks = 0;
  CUDA_TRY(cudaOccupancyMaxActiveBlocksPerMultiprocessor(&max_blocks, kernel,
                                                         block_size, 0));

  int device = 0;
  CUDA_TRY(cudaGetDevice(&device));
  int num_sms = 0;
  CUDA_TRY(cudaDeviceGetAttribute(&num_sms, cudaDevAttrMultiProcessorCount, device));
  int per_thread = total_size / (max_blocks * num_sms * block_size);
  return std::max(1, std::min(per_thread, 32)); // switch to std::clamp with C++17
}

// Computes the output size of apply_boolean_mask, which is the sum of the
// last block's offset and the last block's pass count
cudf::size_type get_output_size(cudf::size_type * block_counts,
                              cudf::size_type * block_offsets,
                              cudf::size_type num_blocks,
                              cudaStream_t stream = 0)
{
  cudf::size_type last_block_count = 0;
  CUDA_TRY(cudaMemcpyAsync(&last_block_count, &block_counts[num_blocks - 1],
                  sizeof(cudf::size_type), cudaMemcpyDefault, stream));
  cudf::size_type last_block_offset = 0;
  if (num_blocks > 1)
    CUDA_TRY(cudaMemcpyAsync(&last_block_offset, &block_offsets[num_blocks - 1],
                    sizeof(cudf::size_type), cudaMemcpyDefault, stream));
  cudaStreamSynchronize(stream);
  return last_block_count + last_block_offset;
}

// This kernel scatters data and validity mask of a column based on the
// scan of the boolean mask. The block offsets for the scan are already computed.
// Just compute the scan of the mask in each block and add it to the block's
// output offset. This is the output index of each element. Scattering
// the valid mask is not as easy, because each thread is only responsible for
// one bit. Warp-level processing (ballot) makes this simpler.
// To make scattering efficient, we "coalesce" the block's scattered data and
// valids in shared memory, and then write from shared memory to global memory
// in a contiguous manner.
// The has_validity template parameter specializes this kernel for the
// non-nullable case for performance without writing another kernel.
//
// Note: `filter` is not run on indices larger than the input column size
template <typename T, typename Filter,
          int block_size, bool has_validity>
__launch_bounds__(block_size, 2048/block_size)
__global__ void scatter_kernel(T* __restrict__ output_data,
                               cudf::bitmask_type * __restrict__ output_valid,
                               cudf::size_type * output_null_count,
                               cudf::column_device_view input_view,
                               cudf::size_type  * __restrict__ block_offsets,
                               cudf::size_type size,
                               cudf::size_type per_thread,
                               Filter filter)
{
  static_assert(block_size <= 1024, "Maximum thread block size exceeded");

  int tid = threadIdx.x + per_thread * block_size * blockIdx.x;
  cudf::size_type block_offset = block_offsets[blockIdx.x];

  // one extra warp worth in case the block is not aligned
  __shared__ bool temp_valids[has_validity ? block_size+warp_size : 1];
  __shared__ T    temp_data[block_size];

  // Note that since the maximum gridDim.x on all supported GPUs is as big as
  // cudf::size_type, this loop is sufficient to cover our maximum column size
  // regardless of the value of block_size and per_thread.
  for (int i = 0; i < per_thread; i++) {
    bool mask_true = (tid < size) && filter(tid);

    // get output location using a scan of the mask result
    cudf::size_type block_sum = 0;
    const cudf::size_type local_index = block_scan_mask<block_size>(mask_true,
                                                                   block_sum);

    if (has_validity) { 
      temp_valids[threadIdx.x] = false; // init shared memory
      if (threadIdx.x < warp_size) temp_valids[block_size + threadIdx.x] = false;
      __syncthreads(); // wait for init
    }

    if (mask_true) {
      temp_data[local_index] = input_view.data<T>()[tid]; // scatter data to shared

      // scatter validity mask to shared memory
      if (input_view.is_valid(tid)) {
        // determine aligned offset for this warp's output
        const cudf::size_type aligned_offset = block_offset % warp_size;
        temp_valids[local_index + aligned_offset] = true;
      }
    }

    // each warp shares its total valid count to shared memory to ease
    // computing the total number of valid / non-null elements written out.
    // note maximum block size is limited to 1024 by this, but that's OK
    __shared__ uint32_t warp_valid_counts[has_validity ? warp_size : 1];
    if (has_validity && threadIdx.x < warp_size) warp_valid_counts[threadIdx.x] = 0;

    __syncthreads(); // wait for shared data and validity mask to be complete

    // Copy output data coalesced from shared to global
    if (threadIdx.x < block_sum)
      output_data[block_offset + threadIdx.x] = temp_data[threadIdx.x];

    if (has_validity) {
      // Since the valid bools are contiguous in shared memory now, we can use
      // __popc to combine them into a single mask element.
      // Then, most mask elements can be directly copied from shared to global
      // memory. Only the first and last 32-bit mask elements of each block must
      // use an atomicOr, because these are where other blocks may overlap.

      constexpr int num_warps = block_size / warp_size;
      // account for partial blocks with non-warp-aligned offsets
      const int last_index = block_sum + (block_offset % warp_size) - 1;
      const int last_warp = min(num_warps, last_index / warp_size);
      const int wid = threadIdx.x / warp_size;
      const int lane = threadIdx.x % warp_size;

      if (block_sum > 0 && wid <= last_warp) {
        int valid_index = (block_offset / warp_size) + wid;

        // compute the valid mask for this warp
        uint32_t valid_warp = __ballot_sync(0xffffffff, temp_valids[threadIdx.x]);

        // Note the atomicOr's below assume that output_valid has been set to 
        // all zero before the kernel

        if (lane == 0 && valid_warp != 0) {
          warp_valid_counts[wid] = __popc(valid_warp);
          if (wid > 0 && wid < last_warp)
            output_valid[valid_index] = valid_warp;
          else {
            atomicOr(&output_valid[valid_index], valid_warp);
          }
        }

        // if the block is full and not aligned then we have one more warp to cover
        if ((wid == 0) && (last_warp == num_warps)) {
          uint32_t valid_warp =
            __ballot_sync(0xffffffff, temp_valids[block_size + threadIdx.x]);
          if (lane == 0 && valid_warp != 0) {
            warp_valid_counts[wid] += __popc(valid_warp);
            atomicOr(&output_valid[valid_index + num_warps], valid_warp);
          }
        }
      }

      __syncthreads(); // wait for warp_valid_counts to be ready

      // Compute total null_count for this block and add it to global count
      if (threadIdx.x < warp_size) {
        uint32_t my_valid_count = warp_valid_counts[threadIdx.x];

        __shared__ typename cub::WarpReduce<uint32_t>::TempStorage temp_storage;

        uint32_t block_valid_count =
          cub::WarpReduce<uint32_t>(temp_storage).Sum(my_valid_count);

        if (lane == 0) { // one thread computes and adds to null count
          atomicAdd(output_null_count, block_sum - block_valid_count);
        }
      }
    }

    block_offset += block_sum;
    tid += block_size;
  }
}

// Dispatch functor which performs the scatter
template <typename Filter, int block_size>
struct scatter_functor
{
  template <typename T>
  std::enable_if_t<not cudf::is_fixed_width<T>(), std::unique_ptr<cudf::column>>
  operator()(cudf::column_view const& input,
             cudf::size_type const& output_size,
                  cudf::size_type  *block_offsets,
                  Filter filter,
                  rmm::mr::device_memory_resource *mr =
                      rmm::mr::get_default_resource(),
                  cudaStream_t stream = 0) {
      CUDF_FAIL("Expects only fixed-width type column");

      return std::make_unique<cudf::column>();
  }

  template <typename T>
  std::enable_if_t<cudf::is_fixed_width<T>(), std::unique_ptr<cudf::column>>
  operator()(cudf::column_view const& input,
             cudf::size_type const& output_size,
             cudf::size_type  *block_offsets,
             Filter filter,
             rmm::mr::device_memory_resource *mr =
                 rmm::mr::get_default_resource(),
             cudaStream_t stream = 0) {
   
    auto output_column = cudf::experimental::detail::allocate_like(input, output_size, cudf::experimental::mask_allocation_policy::RETAIN, mr, stream);
    auto output = output_column->mutable_view();

    bool has_valid = input.nullable();

    auto scatter = (has_valid) ?
      scatter_kernel<T, Filter, block_size, true> :
      scatter_kernel<T, Filter, block_size, false>;

    cudf::size_type per_thread =
      elements_per_thread(scatter, input.size(), block_size);
    cudf::util::cuda::grid_config_1d grid{input.size(),
                                          block_size, per_thread};

    cudf::size_type *null_count = nullptr;
    if (has_valid) {
      RMM_TRY(RMM_ALLOC(&null_count, sizeof(cudf::size_type), stream));
      CUDA_TRY(cudaMemsetAsync(null_count, 0, sizeof(cudf::size_type), stream));
      // Have to initialize the output mask to all zeros because we may update
      // it with atomicOr().
      CUDA_TRY(cudaMemsetAsync(static_cast<void*>(output.null_mask()), 0,
                               cudf::bitmask_allocation_size_bytes(output.size()),
                               stream));
    }
    
    auto input_device_view  = cudf::column_device_view::create(input, stream);
    scatter<<<grid.num_blocks, block_size, 0, stream>>>
      (output.data<T>(), output.null_mask(), null_count,
       *input_device_view, block_offsets, input.size(), per_thread, filter);

    if (has_valid) {
      cudf::size_type output_null_count = 0;
      CUDA_TRY(cudaMemcpyAsync(&output_null_count, null_count,
                               sizeof(cudf::size_type), cudaMemcpyDefault, stream));
      output.set_null_count(output_null_count);
      RMM_TRY(RMM_FREE(null_count, stream));
    }
    return output_column;
  }

};
} // namespace
namespace cudf {
namespace experimental {
namespace detail {

/**
 * @brief Filters a table using a Filter function object
 * 
 * @p filter must be a functor or lambda with the following signature:
 * __device__ bool operator()(cudf::size_type i);
 * It will return true if element i of @p input should be copied, 
 * false otherwise.
 *
 * @tparam Filter the filter functor type
 * @param[in] input The table to filter
 * @param[in] filter A function object that takes an index and returns a bool
 * @return unique_ptr<table> The table generated from filtered `input`.
 */
template <typename Filter>
std::unique_ptr<experimental::table> copy_if(table_view const& input, Filter filter,
                          rmm::mr::device_memory_resource *mr =
                              rmm::mr::get_default_resource(),
                          cudaStream_t stream = 0) {

    std::vector<std::unique_ptr<column>> out_columns(input.num_columns());
    if (0 == input.num_rows() || 0 == input.num_columns()) {
        std::transform(input.begin(), input.end(), out_columns.begin(), [&stream] (auto col_view){return detail::empty_like(col_view, stream);});

        return std::make_unique<experimental::table>(std::move(out_columns));
    }

    constexpr int block_size = 256;
    cudf::size_type per_thread =
      elements_per_thread(compute_block_counts<Filter, block_size>,
                          input.num_rows(), block_size);
    cudf::util::cuda::grid_config_1d grid{input.num_rows(), block_size, per_thread};

    // allocate temp storage for block counts and offsets
    // TODO: use an uninitialized buffer to avoid the initialization kernel
    rmm::device_vector<cudf::size_type> temp_counts(2 * grid.num_blocks);
    cudf::size_type *block_counts = thrust::raw_pointer_cast(temp_counts.data());
    cudf::size_type *block_offsets = block_counts + grid.num_blocks;

    // 1. Find the count of elements in each block that "pass" the mask
    compute_block_counts<Filter, block_size>
        <<<grid.num_blocks, block_size, 0, stream>>>(block_counts,
                                                     input.num_rows(),
                                                     per_thread,
                                                     filter);

    CHECK_STREAM(stream);

    // 2. Find the offset for each block's output using a scan of block counts
    if (grid.num_blocks > 1) {
        // Determine and allocate temporary device storage
        void *d_temp_storage = nullptr;
        size_t temp_storage_bytes = 0;
        cub::DeviceScan::ExclusiveSum(d_temp_storage, temp_storage_bytes,
                                      block_counts, block_offsets,
                                      grid.num_blocks, stream);
        RMM_TRY(RMM_ALLOC(&d_temp_storage, temp_storage_bytes, stream));

        // Run exclusive prefix sum
        cub::DeviceScan::ExclusiveSum(d_temp_storage, temp_storage_bytes,
                                     block_counts, block_offsets,
                                     grid.num_blocks, stream);
        RMM_TRY(RMM_FREE(d_temp_storage, stream));
    } else {
        CUDA_TRY(cudaMemsetAsync(block_offsets, 0, grid.num_blocks * sizeof(cudf::size_type),
                    stream));
    }

    CHECK_STREAM(stream);

    // 3. compute the output size from the last block's offset + count
    cudf::size_type output_size =
        get_output_size(block_counts, block_offsets, grid.num_blocks, stream);

   if (output_size == input.num_rows()) {
       return std::make_unique<experimental::table>(input);
   } else if (output_size > 0){ 
       // Allocate/initialize output columns

        for(size_type i = 0; i < input.num_columns(); i++) {
            auto input_col_view = input.column(i);

            out_columns[i] = cudf::experimental::type_dispatcher(input_col_view.type(),
                                    scatter_functor<Filter, block_size>{},
                                    input_col_view, output_size, 
                                    block_offsets, filter, mr, stream);
        }

        return std::make_unique<experimental::table>(std::move(out_columns));

   } else {
        std::transform(input.begin(), input.end(), out_columns.begin(), [&stream] (auto col_view){return detail::empty_like(col_view, stream);});

        return std::make_unique<experimental::table>(std::move(out_columns));
   }
}

}// namespace detail
}// namespace experimental
}// namespace cudf
