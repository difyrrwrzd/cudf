/*
 * Copyright (c) 2022-2023, NVIDIA CORPORATION.
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

#include <cudf/lists/reverse.hpp>

namespace cudf::lists::detail {

/**
 * @copydoc cudf::lists::reverse
 * @param stream CUDA stream used for device memory operations and kernel launches
 */
std::unique_ptr<column> reverse(lists_column_view const& input,
                                rmm::cuda_stream_view stream,
                                rmm::mr::device_memory_resource* mr);

}  // namespace cudf::lists::detail
