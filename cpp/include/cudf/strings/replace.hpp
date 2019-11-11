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
#include <cudf/scalar/scalar.hpp>

namespace cudf
{
namespace strings
{

/**
 * @brief Replaces target string within each string with the specified
 * replacement string.
 *
 * This function searches each string in the column for the target string.
 * If found, the target string is replaced by the repl string within the
 * input string. If not found, the output entry is just a copy of the
 * corresponding input string.
 *
 * Specifing an empty string for repl will essentially remove the target
 * string if found in each string.
 *
 * Null string entries will return null output string entries.
 *
 * ```
 * s = ["hello", "goodbye"]
 * r = replace(s,"o","O")
 * r is now ["hellO","gOOdbye"]
 * ```
 *
 * @throw cudf::logic_error if target is an empty string.
 *
 * @param strings Strings column for this operation.
 * @param target String to search for within each string.
 * @param repl Replacement string if target is found.
 * @param maxrepl Maximum times to replace if target appears multiple times in the input string.
 *        Default of -1 specifies replace all occurrences of target in each string.
 * @param mr Resource for allocating device memory.
 * @return New strings column.
 */
std::unique_ptr<column> replace( strings_column_view const& strings,
                                 string_scalar const& target,
                                 string_scalar const& repl,
                                 int32_t maxrepl = -1,
                                 rmm::mr::device_memory_resource* mr = rmm::mr::get_default_resource());

/**
 * @brief Replaces the characters within a position range with a specified
 * string.
 *
 * This function replaces each string in the column with the provided
 * repl string within the [start,stop) character position range.
 *
 * Null string entries will return null output string entries.
 *
 * @throw cudf::logic_error if repl is an empty string.
 *
 * @param strings Strings column for this operation.
 * @param repl Replacement string for specified positions found.
 * @param start Start position where repl will be added.
 * @param stop End position (exclusive) to use for replacement.
 *        Default of -1 specifies the end of the string.
 * @param mr Resource for allocating device memory.
 * @return New strings column.
 */
std::unique_ptr<column> replace_slice( strings_column_view const& strings,
                                       string_scalar const& repl,
                                       size_type start, size_type stop = -1,
                                       rmm::mr::device_memory_resource* mr = rmm::mr::get_default_resource());

/**
 * @brief Replaces substrings matching a list of targets with the corresponding
 * replacement strings.
 *
 * For each string in strings, the list of targets is searched within that string.
 * If a target string is found, it is replaced by the corresponding entry in the repls column.
 * All occurrences found in each string are replaced.
 *
 * This does not use regex to match targets in the string.
 *
 * Null string entries will return null output string entries.
 *
 * @throw cudf::logic_error if targets and repls are different sizes.
 *
 * @param strings Strings column for this operation.
 * @param targets Strings to search for in each string.
 * @param repls Corresponding replacement strings for target strings.
 * @param mr Resource for allocating device memory.
 * @return New strings column.
 */
std::unique_ptr<column> replace( strings_column_view const& strings,
                                 strings_column_view const& targets,
                                 strings_column_view const& repls,
                                 rmm::mr::device_memory_resource* mr = rmm::mr::get_default_resource());

/**
 * @brief Replaces any null string entries with the given string.
 *
 * This returns a strings column with no null entries.
 *
 * @param strings Strings column for this operation.
 * @param repl Replacement string for null entries. Default is empty string.
 * @param mr Resource for allocating device memory.
 * @return New strings column.
 */
std::unique_ptr<column> replace_nulls( strings_column_view const& strings,
                                       string_scalar const& repl = string_scalar(""),
                                       rmm::mr::device_memory_resource* mr = rmm::mr::get_default_resource());


} // namespace strings
} // namespace cudf
