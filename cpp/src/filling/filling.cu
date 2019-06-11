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

#include <cudf/filling.hpp>
#include <bitmask/bit_mask.cuh>
#include <utilities/error_utils.hpp>
#include <utilities/type_dispatcher.hpp>
#include <utilities/bit_util.cuh>
#include <utilities/cuda_utils.hpp>
#include <utilities/column_utils.hpp>

#include <rmm/thrust_rmm_allocator.h>
#include <thrust/fill.h>
#include <cub/cub.cuh>

namespace {

using bit_mask::bit_mask_t;
static constexpr gdf_size_type warp_size{32};

template <typename T, typename InputFunctor, bool has_validity>
__global__
void copy_range_kernel(T * __restrict__ const data,
                       bit_mask_t * __restrict__ const bitmask,
                       gdf_size_type * __restrict__ const null_count,
                       gdf_index_type begin,
                       gdf_index_type end,
                       InputFunctor input)
{
  const gdf_index_type tid = threadIdx.x + blockIdx.x * blockDim.x;
  constexpr size_t mask_size = warp_size;

  const gdf_size_type masks_per_grid = gridDim.x * blockDim.x / mask_size;
  const int warp_id = tid / warp_size;
  const int lane_id = threadIdx.x % warp_size;

  const gdf_index_type begin_mask_idx =
      cudf::util::detail::bit_container_index<bit_mask_t>(begin);
  const gdf_index_type end_mask_idx =
      cudf::util::detail::bit_container_index<bit_mask_t>(end);

  gdf_index_type mask_idx = begin_mask_idx + warp_id;
  gdf_index_type input_idx = tid;

  // each warp shares its total change in null count to shared memory to ease
  // computing the total changed to null_count.
  // note maximum block size is limited to 1024 by this, but that's OK
  __shared__ uint32_t warp_null_change[has_validity ? warp_size : 1];
  if (has_validity && threadIdx.x < warp_size) warp_null_change[threadIdx.x] = 0;

  __syncthreads(); // wait for shared data and validity mask to be complete

  while (mask_idx <= end_mask_idx)
  {
    gdf_index_type index = mask_idx * mask_size + lane_id;
    bool in_range = (index >= begin && index < end);

    // write data
    if (in_range) data[index] = input.data(input_idx);

    if (has_validity) { // update bitmask
      int active_mask = __ballot_sync(0xFFFFFFFF, in_range);

      bool valid = (in_range) ? input.valid(input_idx) : false;
      int warp_mask = __ballot_sync(active_mask, valid);

      bit_mask_t old_mask = bitmask[mask_idx];

      if (lane_id == 0) {
        bit_mask_t new_mask = (old_mask & ~active_mask) | 
                              (warp_mask & active_mask);
        bitmask[mask_idx] = new_mask;
        // null_diff = (mask_size - __popc(new_mask)) - (mask_size - __popc(old_mask))
        warp_null_change[warp_id] += __popc(active_mask & old_mask) -
                                     __popc(active_mask & new_mask);
      }
    }

    input_idx += blockDim.x * gridDim.x;
    mask_idx += masks_per_grid;
  }

  __syncthreads(); // wait for shared null counts to be ready
  
  // Compute total null_count change for this block and add it to global count
  if (threadIdx.x < warp_size) {
    uint32_t my_null_change = warp_null_change[threadIdx.x];

    __shared__ typename cub::WarpReduce<uint32_t>::TempStorage temp_storage;
        
    uint32_t block_null_change =
      cub::WarpReduce<uint32_t>(temp_storage).Sum(my_null_change);
        
    if (lane_id == 0) { // one thread computes and adds to null count
      atomicAdd(null_count, block_null_change);
    }
  }
}

template <typename InputFactory>
struct copy_range_dispatch {
  InputFactory make_input;

  template <typename T>
  void operator()(gdf_column *column,
                  gdf_index_type begin, gdf_index_type end,
                  cudaStream_t stream = 0)
  {
    static_assert(warp_size == cudf::util::size_in_bits<bit_mask_t>(), 
      "fill_kernel assumes bitmask element size in bits == warp size");

    auto input = make_input.template operator()<T>();
    auto kernel = copy_range_kernel<T, decltype(input), true>;

    gdf_size_type *null_count = nullptr;

    if (cudf::is_nullable(*column)) {
      RMM_ALLOC(&null_count, sizeof(gdf_size_type), stream);
      CUDA_TRY(cudaMemsetAsync(null_count, column->null_count, 
                               sizeof(gdf_size_type), stream));
      kernel = copy_range_kernel<T, decltype(input), true>;
    }

    // This one results in a compiler internal error! TODO: file NVIDIA bug
    // gdf_size_type num_items = cudf::util::round_up_safe(end - begin, warp_size);
    // number threads to cover range, rounded to nearest warp
    gdf_size_type num_items =
      warp_size * cudf::util::div_rounding_up_safe(end - begin, warp_size);

    constexpr int block_size = 256;

    cudf::util::cuda::grid_config_1d grid{num_items, block_size, 1};

    T * __restrict__ data = static_cast<T*>(column->data);
    bit_mask_t * __restrict__ bitmask =
      reinterpret_cast<bit_mask_t*>(column->valid);
  
    kernel<<<grid.num_blocks, block_size, 0, stream>>>
      (data, bitmask, null_count, begin, end, input);

    if (column->valid != nullptr) {
      CUDA_TRY(cudaMemcpyAsync(&column->null_count, null_count,
                               sizeof(gdf_size_type), cudaMemcpyDefault, stream));
      RMM_FREE(null_count, stream);
    }

    CHECK_STREAM(stream);
  }
};

}; // namespace anonymous

namespace cudf {

namespace detail {

template <typename InputFunctor>
void copy_range(gdf_column *out_column, InputFunctor input,
                gdf_index_type begin, gdf_index_type end)
{
  validate(out_column);
  CUDF_EXPECTS(end - begin > 0, "Range is empty or reversed0");
  CUDF_EXPECTS((begin >= 0) and (end <= out_column->size), "Range is out of bounds");
  
  cudf::type_dispatcher(out_column->dtype,
                        copy_range_dispatch<InputFunctor>{input},
                        out_column, begin, end);
}

struct scalar_factory {
  gdf_scalar value;

  template <typename T>
  struct scalar_functor {
    T value;
    bool is_valid;

    __device__
    T data(gdf_index_type index) { return value; }

    __device__
    bool valid(gdf_index_type index) { return is_valid; }
  };

  template <typename T>
  scalar_functor<T> operator()() {
    T val{}; // Safe type pun, compiler should optimize away the memcpy
    memcpy(&val, &value.data, sizeof(T));
    return scalar_functor<T>{val, value.is_valid};
  }
};

struct column_range_factory {
  gdf_column column;
  gdf_index_type begin;

  template <typename T>
  struct column_range_functor {
    T const * column_data;
    bit_mask_t const * bitmask;
    gdf_index_type begin;

    __device__
    T data(gdf_index_type index) { return column_data[begin + index]; }

    __device__
    bool valid(gdf_index_type index) {
      return bit_mask::is_valid(bitmask, index);
    }
  };

  template <typename T>
  column_range_functor<T> operator()() {
    return column_range_functor<T>{
      static_cast<T*>(column.data),
      reinterpret_cast<bit_mask_t*>(column.valid),
      begin
    };
  }
};

}; // namespace detail

void copy_range(gdf_column *out_column, gdf_column const &in_column,
                gdf_index_type out_begin, gdf_index_type out_end, 
                gdf_index_type in_begin)
{
  validate(in_column);
  CUDF_EXPECTS(out_column->dtype == in_column.dtype, "Data type mismatch");
  gdf_size_type num_elements = out_end - out_begin;
  CUDF_EXPECTS( in_begin + num_elements <= in_column.size, "Range is out of bounds");

  detail::copy_range(out_column, detail::column_range_factory{in_column, in_begin},
                     out_begin, out_end);
}

void fill(gdf_column *column, gdf_scalar const& value, 
          gdf_index_type begin, gdf_index_type end)
{ 
  detail::copy_range(column, detail::scalar_factory{value}, begin, end);
}

}; // namespace cudf