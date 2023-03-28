/*
 * Copyright (c) 2023, NVIDIA CORPORATION.
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

#include "compound.cuh"

#include <cudf/reduction/detail/segmented_reduction_functions.hpp>

#include <rmm/cuda_stream_view.hpp>

namespace cudf {
namespace reduction {
namespace detail {

std::unique_ptr<cudf::column> segmented_mean(column_view const& col,
                                             device_span<size_type const> offsets,
                                             cudf::data_type const output_dtype,
                                             null_policy null_handling,
                                             rmm::cuda_stream_view stream,
                                             rmm::mr::device_memory_resource* mr)
{
  using reducer            = compound::detail::compound_segmented_dispatcher<op::mean>;
  constexpr size_type ddof = 1;  // ddof for mean calculation
  return cudf::type_dispatcher(
    col.type(), reducer{}, col, offsets, output_dtype, null_handling, ddof, stream, mr);
}

}  // namespace detail
}  // namespace reduction
}  // namespace cudf
