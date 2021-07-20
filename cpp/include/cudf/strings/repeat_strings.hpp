/*
 * Copyright (c) 2021, NVIDIA CORPORATION.
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

#include <cudf/scalar/scalar.hpp>
#include <cudf/strings/strings_column_view.hpp>

namespace cudf {
namespace strings {
/**
 * @addtogroup strings_copy
 * @{
 * @file
 * @brief Strings APIs for copying strings.
 */

/**
 * @brief Repeat the given string scalar by a given number of times.
 *
 * An output string scalar is generated by repeating the input string by a number of times given by
 * the @p `repeat_times` parameter.
 *
 * In special cases:
 *  - If @p `repeat_times` is not a positive value, an empty (valid) string scalar will be returned.
 *  - An invalid input scalar will always result in an invalid output scalar regardless of the
 *    value of @p `repeat_times` parameter.
 *
 * @code{.pseudo}
 * Example:
 * s   = '123XYZ-'
 * out = repeat_strings(s, 3)
 * out is '123XYZ-123XYZ-123XYZ-'
 * @endcode
 *
 * @throw cudf::logic_error if the size of the output string scalar exceeds the maximum value that
 *        can be stored by the index type
 *        (i.e., `input.size() * repeat_times > numeric_limits<size_type>::max()`).
 *
 * @param input The scalar containing the string to repeat.
 * @param repeat_times The number of times the input string is repeated.
 * @param mr Device memory resource used to allocate the returned string scalar.
 * @return New string scalar in which the input string is repeated.
 */
std::unique_ptr<string_scalar> repeat_string(
  string_scalar const& input,
  size_type repeat_times,
  rmm::mr::device_memory_resource* mr = rmm::mr::get_current_device_resource());

/**
 * @brief Repeat each string in the given strings column by a given number of times.
 *
 * An output strings column is generated by repeating each string from the input strings column by a
 * number of times given by the @p `repeat_times` parameter.
 *
 * In special cases:
 *  - If @p `repeat_times` is not a positive number, a non-null input string will always result in
 *    an empty output string.
 *  - A null input string will always result in a null output string regardless of the value of the
 *    @p `repeat_times` parameter.
 *
 * The caller is responsible for checking the output column size will not exceed the maximum size of
 * a strings column (number of total characters is less than the max size_type value).
 *
 * @code{.pseudo}
 * Example:
 * strs = ['aa', null, '', 'bbc']
 * out  = repeat_strings(strs, 3)
 * out is ['aaaaaa', null, '', 'bbcbbcbbc']
 * @endcode
 *
 * @param input The column containing strings to repeat.
 * @param repeat_times The number of times each input string is repeated.
 * @param mr Device memory resource used to allocate the returned strings column.
 * @return New column containing the repeated strings.
 */
std::unique_ptr<column> repeat_strings(
  strings_column_view const& input,
  size_type repeat_times,
  rmm::mr::device_memory_resource* mr = rmm::mr::get_current_device_resource());

/**
 * @brief Repeat each string in the given strings column by the numbers of times given in another
 * numeric column.
 *
 * An output strings column is generated by repeating each of the input string by a number of times
 * given by the corresponding row in a @p `repeat_times` numeric column. The computational time can
 * be reduced if sizes of the output strings are known and provided.
 *
 * In special cases:
 *  - Any null row (from either the input strings column or the `repeat_times` column) will always
 *    result in a null output string.
 *  - If any value in the `repeat_times` column is not a positive number and its corresponding input
 *    string is not null, the output string will be an empty string.
 *
 * The caller is responsible for checking the output column size will not exceed the maximum size of
 * a strings column (number of total characters is less than the max size_type value).
 *
 * @code{.pseudo}
 * Example:
 * strs         = ['aa', null, '', 'bbc-']
 * repeat_times = [ 1,   2,     3,  4   ]
 * out          = repeat_strings(strs, repeat_times)
 * out is ['aa', null, '', 'bbc-bbc-bbc-bbc-']
 * @endcode
 *
 * @throw cudf::logic_error if the input `repeat_times` column has data type other than integer.
 * @throw cudf::logic_error if the input columns have different sizes.
 *
 * @param input The column containing strings to repeat.
 * @param repeat_times The column containing numbers of times that the corresponding input strings
 *        are repeated.
 * @param output_strings_sizes The optional column containing pre-computed sizes of the output
 *        strings.
 * @param mr Device memory resource used to allocate the returned strings column.
 * @return New column containing the repeated strings.
 */
std::unique_ptr<column> repeat_strings(
  strings_column_view const& input,
  column_view const& repeat_times,
  std::optional<column_view> output_strings_sizes = std::nullopt,
  rmm::mr::device_memory_resource* mr             = rmm::mr::get_current_device_resource());

/**
 * @brief Compute sizes of the output strings if each string in the input strings column
 * is repeated by the numbers of times given in another numeric column.
 *
 * The output column storing string output sizes is not nullable. These string sizes are
 * also summed up and returned (in an `int64_t` value), which can be used to detect if the input
 * strings column can be safely repeated without data corruption due to overflow in string indexing.
 *
 * @code{.pseudo}
 * Example:
 * strs         = ['aa', null, '', 'bbc-']
 * repeat_times = [ 1,   2,     3,  4   ]
 * [output_sizes, total_size] = repeat_strings_output_sizes(strs, repeat_times)
 * out is [2, 0, 0, 16], and total_size = 18
 * @endcode
 *
 * @throw cudf::logic_error if the input `repeat_times` column has data type other than integer.
 * @throw cudf::logic_error if the input columns have different sizes.
 *
 * @param input The column containing strings to repeat.
 * @param repeat_times The column containing numbers of times that the corresponding input strings
 *        are repeated.
 * @param mr Device memory resource used to allocate the returned strings column.
 * @return A pair with the first item is an int32_t column containing sizes of the output strings,
 *         and the second item is an int64_t number containing the total sizes (in bytes) of the
 *         output strings column.
 */
std::pair<std::unique_ptr<column>, int64_t> repeat_strings_output_sizes(
  strings_column_view const& input,
  column_view const& repeat_times,
  rmm::mr::device_memory_resource* mr = rmm::mr::get_current_device_resource());

/** @} */  // end of doxygen group
}  // namespace strings
}  // namespace cudf
