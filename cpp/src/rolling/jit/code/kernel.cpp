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

namespace cudf {
namespace experimental {
namespace rolling {
namespace jit {
namespace code {



const char* kernel_headers = 
R"***(
#include <cudf/types.hpp>
)***";

const char* kernel =
R"***(
#include "operation.h"

template <typename WindowType>
cudf::size_type get_window(WindowType window, cudf::size_type index) { return 0; }

template <>
cudf::size_type get_window(cudf::size_type window, cudf::size_type index) { return window; }

template <>
cudf::size_type get_window(cudf::size_type* window, cudf::size_type index) {
  return window[index];
}

template <typename InType, typename OutType, class agg_op, typename WindowType>
__global__
void gpu_rolling_new(cudf::size_type nrows,
                 InType const* const __restrict__ in_col, 
                 cudf::bitmask_type const* const __restrict__ in_col_valid,
                 OutType* __restrict__ out_col, 
                 cudf::bitmask_type* __restrict__ out_col_valid,
                 cudf::size_type * __restrict__ output_valid_count,
                 WindowType preceding_window_begin,
                 WindowType following_window_begin,
                 cudf::size_type min_periods)
{
  constexpr int warp_size{32};
  cudf::size_type i = blockIdx.x * blockDim.x + threadIdx.x;
  cudf::size_type stride = blockDim.x * gridDim.x;

  cudf::size_type warp_valid_count{0};

  auto active_threads = __ballot_sync(0xffffffff, i < nrows);
  while(i < nrows)
  {
    // declare this as volatile to avoid some compiler optimizations that lead to incorrect results
    // for CUDA 10.0 and below (fixed in CUDA 10.1)
    volatile cudf::size_type count = 0;

    cudf::size_type preceding_window = get_window(preceding_window_begin, i);
    cudf::size_type following_window = get_window(following_window_begin, i);

    // compute bounds
    cudf::size_type start_index = max(0, i - preceding_window);
    cudf::size_type end_index = min(nrows, i + following_window + 1);

    // aggregate
    // TODO: We should explore using shared memory to avoid redundant loads.
    //       This might require separating the kernel into a special version
    //       for dynamic and static sizes.
    count = end_index - start_index;
    OutType val = agg_op::template operate<OutType, InType>(in_col, start_index, count);

    // check if we have enough input samples
    bool output_is_valid = (count >= min_periods);

    // store the output value, one per thread
    if (output_is_valid) {
      out_col[i] = val;
    }

    // set the mask
    const unsigned int result_mask = __ballot_sync(active_threads, output_is_valid);
   
    // only one thread writes the mask
    if (0 == threadIdx.x % warp_size) {
      out_col_valid[i / warp_size] = result_mask;
      warp_valid_count += __popc(result_mask);
    }

    // process next element 
    i += stride;
    active_threads = __ballot_sync(active_threads, i < nrows);
  }

  // TODO: likely faster to do a single_lane_block_reduce and a single
  // atomic per block but that requires jitifying single_lane_block_reduce...
  if(0 == threadIdx.x % warp_size) {
    atomicAdd(output_valid_count, warp_valid_count);
  }
}
)***";

} // namespace code
} // namespace jit
} // namespace rolling
} // namespace experimental
} // namespace cudf
