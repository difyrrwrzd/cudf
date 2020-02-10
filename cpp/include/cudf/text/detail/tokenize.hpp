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

#include <cudf/column/column.hpp>
#include <cudf/scalar/scalar.hpp>
#include <cudf/strings/strings_column_view.hpp>

using namespace cudf;

namespace nvtext
{
namespace detail
{

/**
 * @copydoc nvtext::tokenize(strings_column_view const&,string_scalar const&,rmm::mr::device_memory_resource*)
 *
 * @param strings Strings column tokenize.
 * @param delimiter UTF-8 characters used to separate each string into tokens.
 *                  The default of empty string will separate tokens using whitespace.
 * @param mr Resource for allocating device memory.
 * @param stream Stream to use for any CUDA calls.
 * @return New strings columns of tokens.
 */
std::unique_ptr<column> tokenize( strings_column_view const& strings,
                                  string_scalar const& delimiter = string_scalar{""},
                                  rmm::mr::device_memory_resource* mr = rmm::mr::get_default_resource(),
                                  cudaStream_t stream = 0 );

/**
 * @copydoc nvtext::tokenize(strings_column_view const&,strings_column_view const&,rmm::mr::device_memory_resource*)
 *
 * @param strings Strings column to tokenize.
 * @param delimiters Strings used to separate individual strings into tokens.
 * @param mr Resource for allocating device memory.
 * @param stream Stream to use for any CUDA calls.
 * @return New strings columns of tokens.
 */
std::unique_ptr<column> tokenize( strings_column_view const& strings,
                                  strings_column_view const& delimiters,
                                  rmm::mr::device_memory_resource* mr = rmm::mr::get_default_resource(),
                                  cudaStream_t stream = 0 );

/**
 * @copydoc nvtext::count_tokens(strings_column_view const&, string_scalar const&,rmm::mr::device_memory_resource*)
 *
 * @param strings Strings column to use for this operation.
 * @param delimiter Strings used to separate each string into tokens.
 *                  The default of empty string will separate tokens using whitespace.
 * @param mr Resource for allocating device memory.
 * @param stream Stream to use for any CUDA calls.
 * @return New INT32 column of token counts.
 */
std::unique_ptr<column> count_tokens( strings_column_view const& strings,
                                      string_scalar const& delimiter = string_scalar{""},
                                      rmm::mr::device_memory_resource* mr = rmm::mr::get_default_resource(),
                                      cudaStream_t stream = 0 );

/**
 * @copydoc nvtext::count_tokens(strings_column_view const&,strings_column_view const&,rmm::mr::device_memory_resource*)
 *
 * @param strings Strings column to use for this operation.
 * @param delimiters Strings used to separate each string into tokens.
 * @param mr Resource for allocating device memory.
 * @param stream Stream to use for any CUDA calls.
 * @return New INT32 column of token counts.
 */
std::unique_ptr<column> count_tokens( strings_column_view const& strings,
                                      strings_column_view const& delimiters,
                                      rmm::mr::device_memory_resource* mr = rmm::mr::get_default_resource(),
                                      cudaStream_t stream = 0 );

} // namespace detail
} // namespace nvtext
