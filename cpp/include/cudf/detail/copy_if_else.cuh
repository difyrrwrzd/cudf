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
#include <cudf/column/column.hpp>
#include <cudf/column/column_device_view.cuh>
#include <cudf/column/column_view.hpp>
#include <cudf/detail/utilities/cuda.cuh>
#include <cudf/detail/utilities/integer_utils.hpp>
#include <cudf/scalar/scalar.hpp>
#include <cudf/scalar/scalar_device_view.cuh>
#include <cudf/strings/detail/copy_if_else.cuh>
#include <cudf/utilities/traits.hpp>
#include <cudf/utilities/type_dispatcher.hpp>
#include <iterator/legacy/iterator.cuh>

#include <cub/cub.cuh>
#include <rmm/device_scalar.hpp>

namespace cudf {
namespace experimental {
namespace detail {
namespace {  // anonymous

template <size_type block_size,
          typename T,
          typename LeftIter,
          typename RightIter,
          typename Filter,
          bool has_validity>
__launch_bounds__(block_size) __global__
  void copy_if_else_kernel(LeftIter lhs,
                           RightIter rhs,
                           Filter filter,
                           mutable_column_device_view out,
                           size_type *__restrict__ const valid_count)
{
  const size_type tid            = threadIdx.x + blockIdx.x * block_size;
  const int warp_id              = tid / warp_size;
  const size_type warps_per_grid = gridDim.x * block_size / warp_size;

  // begin/end indices for the column data
  size_type begin = 0;
  size_type end   = out.size();
  // warp indices.  since 1 warp == 32 threads == sizeof(bit_mask_t) * 8,
  // each warp will process one (32 bit) of the validity mask via
  // __ballot_sync()
  size_type warp_begin = cudf::word_index(begin);
  size_type warp_end   = cudf::word_index(end - 1);

  // lane id within the current warp
  constexpr size_type leader_lane{0};
  const int lane_id = threadIdx.x % warp_size;

  size_type warp_valid_count{0};

  // current warp.
  size_type warp_cur = warp_begin + warp_id;
  size_type index    = tid;
  while (warp_cur <= warp_end) {
    bool in_range = (index >= begin && index < end);

    bool valid = true;
    if (has_validity) {
      valid = in_range && (filter(index) ? thrust::get<1>(lhs[index]) : thrust::get<1>(rhs[index]));
    }

    // do the copy if-else
    if (in_range) {
      out.element<T>(index) = filter(index) ? static_cast<T>(thrust::get<0>(lhs[index]))
                                            : static_cast<T>(thrust::get<0>(rhs[index]));
    }

    // update validity
    if (has_validity) {
      // the final validity mask for this warp
      int warp_mask = __ballot_sync(0xFFFF'FFFF, valid && in_range);
      // only one guy in the warp needs to update the mask and count
      if (lane_id == 0) {
        out.set_mask_word(warp_cur, warp_mask);
        warp_valid_count += __popc(warp_mask);
      }
    }

    // next grid
    warp_cur += warps_per_grid;
    index += block_size * gridDim.x;
  }

  if (has_validity) {
    // sum all null counts across all warps
    size_type block_valid_count =
      single_lane_block_sum_reduce<block_size, leader_lane>(warp_valid_count);
    // block_valid_count will only be valid on thread 0
    if (threadIdx.x == 0) {
      // using an atomic here because there are multiple blocks doing this work
      atomicAdd(valid_count, block_valid_count);
    }
  }
}

}  // anonymous namespace

template <typename Element, typename FilterFn, typename LeftIter, typename RightIter>
std::unique_ptr<column> copy_if_else(
  data_type type,
  bool nullable,
  LeftIter lhs_begin,
  LeftIter lhs_end,
  RightIter rhs,
  FilterFn filter,
  rmm::mr::device_memory_resource *mr = rmm::mr::get_default_resource(),
  cudaStream_t stream                 = 0)
{
  size_type size           = std::distance(lhs_begin, lhs_end);
  size_type num_els        = cudf::util::round_up_safe(size, warp_size);
  constexpr int block_size = 256;
  cudf::experimental::detail::grid_1d grid{num_els, block_size, 1};

  std::unique_ptr<column> out = make_fixed_width_column(
    type, size, nullable ? mask_state::UNINITIALIZED : mask_state::UNALLOCATED, stream, mr);

  auto out_v = mutable_column_device_view::create(*out);

  // if we have validity in the output
  if (nullable) {
    rmm::device_scalar<size_type> valid_count{0, stream, mr};

    // call the kernel
    copy_if_else_kernel<block_size, Element, LeftIter, RightIter, FilterFn, true>
      <<<grid.num_blocks, block_size, 0, stream>>>(
        lhs_begin, rhs, filter, *out_v, valid_count.data());

    out->set_null_count(size - valid_count.value());
  } else {
    // call the kernel
    copy_if_else_kernel<block_size, Element, LeftIter, RightIter, FilterFn, false>
      <<<grid.num_blocks, block_size, 0, stream>>>(lhs_begin, rhs, filter, *out_v, nullptr);
  }

  return out;
}

}  // namespace detail

}  // namespace experimental

}  // namespace cudf
