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

#include <cudf/strings/strings_column_view.hpp>
#include <cudf/column/column.hpp>

namespace cudf
{
namespace strings
{

/**
 * @brief Returns a new integer numeric column parsing integer values from the
 * provided strings column.
 *
 * Any null entries will result in corresponding null entries in the output column.
 *
 * Only characters [0-9] plus a prefix '-' and '+' are recognized.
 * When any other character is encountered, the parsing ends for that string
 * and the current digits are converted into an integer.
 *
 * @throw cudf::logic_error if output_type is not integral type.
 *
 * @param strings Strings instance for this operation.
 * @param output_type Type of integer numeric column to return.
 * @param mr Resource for allocating device memory.
 * @param stream Stream to use for any kernels in this function.
 * @return New column with integers converted from strings.
 */
std::unique_ptr<cudf::column> to_integers( strings_column_view const& strings,
                                           cudf::data_type output_type,
                                           rmm::mr::device_memory_resource* mr = rmm::mr::get_default_resource(),
                                           cudaStream_t stream = 0);

/**
 * @brief Returns a new strings column converting the integer values from the
 * provided column into strings.
 *
 * Any null entries will result in corresponding null entries in the output column.
 *
 * For each integer, a string is created in base-10 decimal.
 * Negative numbers will include a '-' prefix.
 *
 * @throw cudf::logic_error if integers column is not integral type.
 *
 * @param column Numeric column to convert.
 * @param mr Resource for allocating device memory.
 * @param stream Stream to use for any kernels in this function.
 * @return New strings column with integers as strings.
 */
std::unique_ptr<cudf::column> from_integers( column_view const& integers,
                                             rmm::mr::device_memory_resource* mr = rmm::mr::get_default_resource(),
                                             cudaStream_t stream = 0);

} // namespace strings
} // namespace cudf
