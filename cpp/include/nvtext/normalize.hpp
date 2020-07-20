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
#include <cudf/strings/strings_column_view.hpp>

//! NVText APIs
namespace nvtext {
/**
 * @addtogroup nvtext_normalize
 * @{
 */

/**
 * @brief Returns a new strings column by normalizing the whitespace in each
 * string in the input column.
 *
 * Normalizing a string replaces any number of whitespace character
 * (character code-point <= ' ') runs with a single space ' ' and
 * trims whitespace from the beginning and end of the string.
 *
 * @code{.pseudo}
 * Example:
 * s = ["a b", "  c  d\n", "e \t f "]
 * t = normalize_spaces(s)
 * t is now ["a b","c d","e f"]
 * @endcode
 *
 * A null input element at row `i` produces a corresponding null entry
 * for row `i` in the output column.
 *
 * @param strings Strings column to normalize.
 * @param mr Device memory resource used to allocate the returned column's device memory.
 * @return New strings columns of normalized strings.
 */
std::unique_ptr<cudf::column> normalize_spaces(
  cudf::strings_column_view const& strings,
  rmm::mr::device_memory_resource* mr = rmm::mr::get_default_resource());

/**
 * @brief Normalizes strings characters for tokenizing.
 *
 * The strings are normalized by adding spaces around punctuation,
 * converting whitespace characters to spaces and optionally converting
 * to lower-case and removing accents from characters.
 *
 * Also, padding (spaces) are added around characters in the CJK Unicode
 * block: https://en.wikipedia.org/wiki/CJK_Unified_Ideographs_(Unicode_block)
 *
 * This function requires 8x the number of bytes in the input strings
 * column as working memory.
 *
 * @param strings The input strings to tokenize.
 * @param do_lower_case If true, upper-case characters are converted to
 *        lower-case and accents are stripped from those characters.
 *        If false, accented and upper-case characters are not transformed.
 * @param mr Memory resource to allocate any returned objects.
 * @return Normalized strings column
 */
std::unique_ptr<cudf::column> normalize_characters(
  cudf::strings_column_view const& strings,
  bool do_lower_case,
  rmm::mr::device_memory_resource* mr = rmm::mr::get_default_resource());

/** @} */  // end of group
}  // namespace nvtext
