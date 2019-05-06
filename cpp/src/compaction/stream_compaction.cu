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

#include <cudf.h>
#include <types.hpp>
#include <rmm/thrust_rmm_allocator.h>
#include <stream_compaction.hpp>
#include <bitmask/bit_mask.cuh>
#include <utilities/device_atomics.cuh>
#include <utilities/cudf_utils.h>
#include <utilities/error_utils.hpp>
#include <utilities/type_dispatcher.hpp>
#include <utilities/wrapper_types.hpp>
#include <utilities/cuda_utils.hpp>
#include <cub/cub.cuh>

using bit_mask::bit_mask_t;

namespace {

static constexpr int warp_size = 32;

// Returns true if the mask is true and valid (non-null) for index i
__device__ inline 
bool valid_and_true(cudf::bool8 const * __restrict__ data,
                    bit_mask_t const * __restrict__ bitmask,
                    gdf_index_type i)
{
  bool valid = bit_mask::is_valid(bitmask, i);
  return (cudf::true_v == data[i]) && valid;
}

}  // namespace

namespace cudf {

// Compute the count of elements that pass the mask within each block
template <int block_size, int per_thread>
__global__ void compute_block_counts(gdf_size_type  * __restrict__ block_counts,
                                     cudf::bool8 const* __restrict__ mask_data,
                                     bit_mask_t const* __restrict__ mask_valid,
                                     gdf_size_type mask_size)
{
  int tid = threadIdx.x + per_thread * block_size * blockIdx.x;
  int count = 0;

  for (int i = 0; i < per_thread; i++) {
    bool pass = (tid < mask_size) && valid_and_true(mask_data, mask_valid, tid);
    count += __syncthreads_count(pass);
    tid += block_size;
  }

  if (threadIdx.x == 0) block_counts[blockIdx.x] = count;
}

// Compute the exclusive prefix sum of each thread's mask value within each block
template <int block_size>
__device__ gdf_index_type block_scan_mask(bool mask_true, 
                                          gdf_index_type &block_sum)
{
  int offset = 0;

  using BlockScan = cub::BlockScan<gdf_size_type, block_size>;
  __shared__ typename BlockScan::TempStorage temp_storage;
  BlockScan(temp_storage).ExclusiveSum(mask_true, offset, block_sum);
  
  return offset;
}

// This kernel scatters for columns with no validity mask.
// Just compute the scan of the mask in each block and add it to the block's
// output offset. This is the output index of each element.
// Note the valid params are still here so we can dispatch either this 
// kernel or the following one.
template <typename T, int block_size, int per_thread>
__launch_bounds__(block_size, 2048/block_size)
__global__ void scatter_no_valid(T* __restrict__ output_data,
                                 bit_mask_t * __restrict__, // output_valid,
                                 gdf_size_type * output_null_count,
                                 T const * __restrict__ input_data,
                                 bit_mask_t const * __restrict__, //input_valid,
                                 gdf_size_type  * __restrict__ block_offsets,
                                 cudf::bool8 const * __restrict__ mask_data,
                                 bit_mask_t const * __restrict__ mask_valid,
                                 gdf_size_type mask_size)
{
  int tid = threadIdx.x + per_thread * block_size * blockIdx.x;
  gdf_size_type block_offset = block_offsets[blockIdx.x];
  
  #pragma unroll 2
  for (int i = 0; i < per_thread; i++) {

    bool mask_true = (tid < mask_size) && 
                     valid_and_true(mask_data, mask_valid, tid);

    // get output location using a scan of the mask result
    gdf_index_type block_sum = 0;
    const gdf_index_type local_index = block_scan_mask<block_size>(mask_true,
                                                                   block_sum);
    if (mask_true) // scatter input to output
      output_data[local_index + block_offset] = input_data[tid];

    block_offset += block_sum;
    tid += block_size;
  }
}

// This kernel scatters for columns with validity mask. It computes the 
// output index in the same way as the previous kernel, but scattering 
// the valid mask is not as easy, because each thread is only responsible for 
// one bit. See comments inline for more detail.
template <typename T, int block_size, int per_thread>
__launch_bounds__(block_size, 2048/block_size)
__global__ void scatter_with_valid(T* __restrict__ output_data,
                                   bit_mask_t * __restrict__ output_valid,
                                   gdf_size_type * output_null_count,
                                   T const * __restrict__ input_data,
                                   bit_mask_t const * __restrict__ input_valid,
                                   gdf_size_type  * __restrict__ block_offsets,
                                   cudf::bool8 const * __restrict__ mask_data,
                                   bit_mask_t const * __restrict__ mask_valid,
                                   gdf_size_type mask_size)
{
  int tid = threadIdx.x + per_thread * block_size * blockIdx.x;
  gdf_size_type block_offset = block_offsets[blockIdx.x];
  
  // one extra warp worth in case the block is not aligned
  __shared__ bool temp_valids[block_size+warp_size];
  __shared__ T    temp_data[block_size];
  
  for (int i = 0; i < per_thread; i++) {

    bool mask_true = (tid < mask_size) && 
                     valid_and_true(mask_data, mask_valid, tid);

    // get output location using a scan of the mask result
    gdf_index_type block_sum = 0;
    const gdf_index_type local_index = block_scan_mask<block_size>(mask_true,
                                                                   block_sum);

    // determine if this warp's output offset is aligned to a warp size
    const gdf_size_type block_offset_aligned =
      warp_size * (block_offset / warp_size);
    const gdf_size_type aligned_offset = block_offset - block_offset_aligned;

    // To make this efficient, "coalesce" the block's scattered values
    // in shared memory, and then write from shared memory to global memory in a 
    // contiguous manner.

    // zero the shared memory 
    temp_valids[threadIdx.x] = false;
    if (threadIdx.x < warp_size) temp_valids[block_size + threadIdx.x] = false;
    __syncthreads();

    if (mask_true) {
      temp_data[local_index] = input_data[tid]; // scatter data to shared

      // scatter validity mask to shared memory
      if (bit_mask::is_valid(input_valid, tid)) {
        temp_valids[local_index + aligned_offset] = true;
      }
    }

    // each warp shares its total valid count to shared memory to ease
    // computing the total number of valid / non-null elements written out
    // note maximum block size is limited to 1024 by this, but that's OK
    __shared__ uint32_t warp_valid_counts[warp_size];
    if (threadIdx.x < warp_size) warp_valid_counts[threadIdx.x] = 0;

    __syncthreads(); // wait for shared data and validity mask to be complete

    // Just write the output data coalesced from shared to global
    if (threadIdx.x < block_sum)
      output_data[block_offset + threadIdx.x] = temp_data[threadIdx.x];

    // Since the valid bools are contiguous in shared memory now, we can use
    // __popc to combine them into a single mask element.
    // Then, most mask elements can be directly copied from shared to global
    // memory. Only the first and last 32-bit mask elements of each block must
    // use an atomicOr, because these are where other blocks may overlap.

    constexpr int num_warps = block_size / warp_size;
    const int last_warp = block_sum / warp_size;
    const int wid = threadIdx.x / warp_size;
    const int lane = threadIdx.x % warp_size;

    if (block_sum > 0 && wid <= last_warp) {
      int valid_index = (block_offset / warp_size) + wid;

      // compute the valid mask for this warp
      int32_t valid_warp = __ballot_sync(0xffffffff, temp_valids[threadIdx.x]);

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
        int32_t valid_warp =
          __ballot_sync(0xffffffff, temp_valids[block_size + threadIdx.x]);
        if (lane == 0 && valid_warp != 0) {
          warp_valid_counts[wid] += __popc(valid_warp);
          atomicOr(&output_valid[valid_index + num_warps], valid_warp);
        }
      }
    }

    __syncthreads();

    // finally we just need to compute the total number of null elements for 
    // this block and add it to the null
    if (threadIdx.x < warp_size) {
      uint32_t my_valid_count = warp_valid_counts[threadIdx.x];

      __shared__ typename cub::WarpReduce<uint32_t>::TempStorage temp_storage;
      
      uint32_t block_valid_count =
        cub::WarpReduce<uint32_t>(temp_storage).Sum(my_valid_count);
      
      if (lane == 0) { // one thread computes and adds to null count
        atomicAdd(output_null_count, block_sum - block_valid_count);
      }
    }

    block_offset += block_sum;
    tid += block_size;
  }
}

// Dispatch functor which performs the scatter
template <int block_size, int per_thread>
struct scatter_functor 
{
  template <typename T>
  void operator()(gdf_column *output_column,
                  gdf_column const * input_column,
                  gdf_size_type  *block_offsets,
                  cudf::bool8 const * __restrict__ mask_data,
                  bit_mask_t const * __restrict__ mask_valid,
                  gdf_size_type mask_size,
                  bool has_valid) {
    cudf::util::cuda::grid_config_1d grid{mask_size, block_size, per_thread};
    
    auto scatter = (has_valid) ?
      scatter_with_valid<T, block_size, per_thread> :
      scatter_no_valid<T, block_size, per_thread>;

    gdf_size_type *null_count = nullptr;
    if (has_valid) {
      RMM_ALLOC(&null_count, sizeof(gdf_size_type), 0);
      CUDA_TRY(cudaMemset(null_count, 0, sizeof(gdf_size_type)));
    }

    bit_mask_t * __restrict__ output_valid =
      reinterpret_cast<bit_mask_t*>(output_column->valid);
    bit_mask_t const * __restrict__ input_valid =
      reinterpret_cast<bit_mask_t*>(input_column->valid);

    scatter<<<grid.num_blocks, block_size>>>(static_cast<T*>(output_column->data),
                                             output_valid,
                                             null_count,
                                             static_cast<T const*>(input_column->data),
                                             input_valid,
                                             block_offsets,
                                             mask_data,
                                             mask_valid,
                                             mask_size);

    if (has_valid) {
      CUDA_TRY(cudaMemcpy(&output_column->null_count, null_count, 
                          sizeof(gdf_size_type), cudaMemcpyDefault));
      RMM_FREE(null_count, 0);
    }
  }
};

// Computes the output size of apply_boolean_mask, which is the sum of the 
// last block's offset and the last block's pass count
gdf_size_type get_output_size(gdf_size_type *block_counts,
                              gdf_size_type *block_offsets,
                              gdf_size_type num_blocks)
{
  gdf_size_type last_block_count = 0;
  cudaMemcpy(&last_block_count, &block_counts[num_blocks - 1], 
             sizeof(gdf_size_type), cudaMemcpyDefault);
  gdf_size_type last_block_offset = 0;
  if (num_blocks > 1)
    cudaMemcpy(&last_block_offset, &block_offsets[num_blocks - 1], 
               sizeof(gdf_size_type), cudaMemcpyDefault);
  return last_block_count + last_block_offset;
}

/*
 * Filters a column using a column of boolean values as a mask.
 *
 * 
 * High Level Algorithm: First, compute a `scatter_map` from the boolean_mask 
 * that scatters input[i] if boolean_mask[i] is non-null and "true". This is 
 * simply an exclusive scan of the mask. Second, use the `scatter_map` to
 * scatter elements from the `input` column into the `output` column.
 */
gdf_column apply_boolean_mask(gdf_column const *input,
                              gdf_column const *boolean_mask) {
  CUDF_EXPECTS(nullptr != input, "Null input");
  CUDF_EXPECTS(nullptr != boolean_mask, "Null boolean_mask");
  CUDF_EXPECTS(input->size == boolean_mask->size, "Column size mismatch");
  CUDF_EXPECTS(boolean_mask->dtype == GDF_BOOL8, "Mask must be Boolean type");
  CUDF_EXPECTS(boolean_mask->data != nullptr, "Null boolean_mask data");
  CUDF_EXPECTS(boolean_mask->valid != nullptr, "Null boolean_mask bitmask");

  constexpr int block_size = 256;
  constexpr int per_thread = 32;
  cudf::util::cuda::grid_config_1d grid{boolean_mask->size, block_size, per_thread};

  // allocate temp storage for block counts and offsets
  gdf_size_type *block_counts = nullptr;
  RMM_ALLOC(&block_counts, 2 * grid.num_blocks * sizeof(gdf_size_type), 0);
  gdf_size_type *block_offsets = block_counts + grid.num_blocks;

  // Convert the validity mask to a 32-bit type for higher efficiency
  bit_mask_t const* __restrict__ mask_valid =
    reinterpret_cast<bit_mask_t const *>(boolean_mask->valid);
  cudf::bool8 const* __restrict__ mask_data =
    reinterpret_cast<cudf::bool8 const *>(boolean_mask->data);
  
  // 1. Find the count of elements in each block that "pass" the mask
  compute_block_counts<block_size, per_thread><<<grid.num_blocks, block_size>>>
    (block_counts, mask_data, mask_valid, boolean_mask->size);

  // 2. Find the offset for each block's output using a scan of block counts
  if (grid.num_blocks > 1) {
    // Determine and allocate temporary device storage
    void *d_temp_storage = NULL;
    size_t temp_storage_bytes = 0;
    cub::DeviceScan::ExclusiveSum(d_temp_storage,
                                  temp_storage_bytes,
                                  block_counts,
                                  block_offsets,
                                  grid.num_blocks);
    RMM_ALLOC(&d_temp_storage, temp_storage_bytes, 0);

    // Run exclusive prefix sum
    cub::DeviceScan::ExclusiveSum(d_temp_storage,
                                  temp_storage_bytes,
                                  block_counts,
                                  block_offsets,
                                  grid.num_blocks);
  }
  else {
    cudaMemset(block_offsets, 0, grid.num_blocks * sizeof(gdf_size_type));
  }

  CHECK_STREAM(0);

  // 3. compute the output size from the last block's offset + count
  gdf_size_type output_size = 
    get_output_size(block_counts, block_offsets, grid.num_blocks);

  gdf_column output;
  gdf_column_view(&output, 0, 0, 0, input->dtype);
  output.dtype_info = input->dtype_info;

  if (output_size > 0) {    
    // Allocate/initialize output column
    gdf_size_type column_byte_width{gdf_dtype_size(input->dtype)};

    void *data = nullptr;
    gdf_valid_type *valid = nullptr;
    RMM_ALLOC(&data, output_size * column_byte_width, 0);

    if (input->valid != nullptr) {
      gdf_size_type bytes = gdf_valid_allocation_size(output_size);
      RMM_ALLOC(&valid, bytes, 0);
      CUDA_TRY(cudaMemset(valid, 0, bytes));
    }

    CUDF_EXPECTS(GDF_SUCCESS == gdf_column_view(&output, data, valid,
                                                output_size, input->dtype),
                "cudf::apply_boolean_mask failed to create output column view");

    // 4. Scatter the output data and valid mask
    cudf::type_dispatcher(output.dtype, 
                          scatter_functor<block_size, per_thread>{},
                          &output, 
                          input, 
                          block_offsets,
                          mask_data,
                          mask_valid,
                          boolean_mask->size,
                          input->valid != nullptr);

    CHECK_STREAM(0);
  }
  return output;
}

}  // namespace cudf
