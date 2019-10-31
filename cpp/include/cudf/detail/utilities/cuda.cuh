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

#include <cudf/types.hpp>
#include <cudf/detail/utilities/integer_utils.hpp>

#include <type_traits>

namespace cudf {
namespace detail {
/**
 * @brief Size of a warp in a CUDA kernel.
 */
//static constexpr size_type warp_size{32};

/**
 * @brief A kernel grid configuration construction gadget for simple
 * one-dimensional, with protection against integer overflow.
 */
class grid_1d {
 public:
  const int num_threads_per_block;
  const int num_blocks;
  /**
   * @param overall_num_elements The number of elements the kernel needs to
   * handle/process, in its main, one-dimensional/linear input (e.g. one or more
   * cuDF columns)
   * @param num_threads_per_block The grid block size, determined according to
   * the kernel's specific features (amount of shared memory necessary, SM
   * functional units use pattern etc.); this can't be determined
   * generically/automatically (as opposed to the number of blocks)
   * @param elements_per_thread Typically, a single kernel thread processes more
   * than a single element; this affects the number of threads the grid must
   * contain
   */
  grid_1d(cudf::size_type overall_num_elements,
          cudf::size_type num_threads_per_block_,
          cudf::size_type elements_per_thread = 1)
      : num_threads_per_block(num_threads_per_block_),
        num_blocks(util::div_rounding_up_safe(
            overall_num_elements,
            elements_per_thread * num_threads_per_block)) {}
};

/**
 * @brief Performs a sum reduction of values from the same lane across all
 * warps in a thread block and returns the result on thread 0 of the block.
 *
 * All threads in a block must call this function, but only values from the
 * threads indicated by `leader_lane` will contribute to the result. Similarly,
 * the returned result is only defined on `threadIdx.x==0`.
 *
 * @tparam block_size The number of threads in the thread block (must be less
 * than or equal to 1024)
 * @tparam leader_lane The id of the lane in the warp whose value contributes to
 * the reduction
 * @tparam T Arithmetic type
 * @param lane_value The value from the lane that contributes to the reduction
 * @return The sum reduction of the values from each lane. Only valid on
 * `threadIdx.x == 0`. The returned value on all other threads is undefined.
 */
template <std::size_t block_size, std::size_t leader_lane = 0, typename T>
__device__ T single_lane_block_sum_reduce(T lane_value) {
  static_assert(block_size <= 1024, "Invalid block size.");
  static_assert(std::is_arithmetic<T>::value, "Invalid non-arithmetic type.");
  constexpr auto warps_per_block{block_size / warp_size};
  auto const lane_id{threadIdx.x % warp_size};
  auto const warp_id{threadIdx.x / warp_size};
  __shared__ T lane_values[warp_size];

  // Load each lane's value into a shared memory array
  // If there are fewer than 32 warps, initialize with the identity of addition,
  // i.e., a default constructed T
  if (lane_id == leader_lane) {
    lane_values[warp_id] = (warp_id < warps_per_block) ? lane_value : T{};
  }
  __syncthreads();

  // Use a single warp to do the reduction, result is only defined on
  // threadId.x == 0
  T result{0};
  if (warp_id == 0) {
    __shared__ typename cub::WarpReduce<T>::TempStorage temp;
    result = cub::WarpReduce<T>(temp).sum(lane_values[lane_id]);
  }
  return result;
}

}  // namespace detail
}  // namespace cudf