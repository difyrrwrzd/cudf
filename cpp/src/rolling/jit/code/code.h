/*
 * Copyright (c) 2019-2020, NVIDIA CORPORATION.
 *
 * Copyright 2018-2019 BlazingDB, Inc.
 *     Copyright 2018 Christian Noboa Mardini <christian@blazingdb.com>
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

#ifndef GDF_BINARY_OPERATION_JIT_CODE_CODE_H
#define GDF_BINARY_OPERATION_JIT_CODE_CODE_H

namespace cudf
{
namespace experimental
{
namespace rolling
{
namespace jit
{
namespace code
{
extern const char* kernel_headers;
extern const char* kernel;
extern const char* operation_h;

}  // namespace code
}  // namespace jit
}  // namespace rolling
}  // namespace experimental
}  // namespace cudf

#endif
