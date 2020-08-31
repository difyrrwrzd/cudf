/*
 * Copyright (c) 2020, NVIDIA CORPORATION.
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

#include <cudf/io/types.hpp>
#include <cudf/utilities/traits.hpp>

// used to make CUIO_BENCH_ALL_TYPES calls more readable
constexpr int UNCOMPRESSED = (int)cudf::io::compression_type::NONE;
constexpr int USE_SNAPPY   = (int)cudf::io::compression_type::SNAPPY;

#define CUIO_BENCH_ALL_TYPES(benchmark_define, compression)
