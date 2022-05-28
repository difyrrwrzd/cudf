/*
 * Copyright (c) 2019-2022, NVIDIA CORPORATION.
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

#include <cudf/aggregation.hpp>
#include <cudf/scalar/scalar.hpp>

namespace cudf {
/**
 * @addtogroup aggregation_reduction
 * @{
 * @file
 */

/**
 *  @brief Enum to describe scan operation type
 */
enum class scan_type : bool { INCLUSIVE, EXCLUSIVE };

/**
 * @brief  Computes the reduction of the values in all rows of a column.
 *
 * This function does not detect overflows in reductions.
 * Using a higher precision `data_type` may prevent overflow.
 * Only `min` and `max` ops are supported for reduction of non-arithmetic
 * types (timestamp, string...).
 * The null values are skipped for the operation.
 * If the column is empty, the member `is_valid()` of the output scalar
 * will contain `false`.
 *
 * @throw cudf::logic_error if reduction is called for non-arithmetic output
 * type and operator other than `min` and `max`.
 * @throw cudf::logic_error if input column data type is not convertible to
 * output data type.
 * @throw cudf::logic_error if `min` or `max` reduction is called and the
 * output type does not match the input column data type.
 * @throw cudf::logic_error if `any` or `all` reduction is called and the
 * output type is not bool8.
 * @throw cudf::logic_error if `mean`, `var`, or `std` reduction is called and
 * the output type is not floating point.
 *
 * If the input column has arithmetic type, output_dtype can be any arithmetic
 * type. If the input column has non-arithmetic type, e.g. timestamp or string,
 * the same output type must be specified.
 *
 * If the reduction fails, the member is_valid of the output scalar
 * will contain `false`.
 *
 * @param col Input column view
 * @param agg Aggregation operator applied by the reduction
 * @param output_dtype The computation and output precision.
 * @param mr Device memory resource used to allocate the returned scalar's device memory
 * @returns Output scalar with reduce result.
 */
std::unique_ptr<scalar> reduce(
  column_view const& col,
  std::unique_ptr<reduce_aggregation> const& agg,
  data_type output_dtype,
  rmm::mr::device_memory_resource* mr = rmm::mr::get_current_device_resource());

/**
 * @brief  Compute reduction of each segment in the input column
 *
 * This function does not detect overflows in reductions. When given integral and
 * floating point inputs, their values are promoted to `int64_t` and `double`
 * respectively to compute, and casted to @p output_dtype before returning.
 *
 * Null values are treated as identities during reduction.
 *
 * If the segment is empty, the row corresponding to the result of the
 * segment is null.
 *
 * If any index in @p offsets is out of bound of @p segmented_values , the behavior
 * is undefined.
 *
 * @note If the input column has arithmetic type, output_dtype can be any arithmetic
 * type. If the input column has non-arithmetic type, e.g. timestamp, the same
 * output type must be specified.
 *
 * @note If input is not empty, the result is always nullable.
 *
 * @throw cudf::logic_error if reduction is called for non-arithmetic output
 * type and operator other than `min` and `max`.
 * @throw cudf::logic_error if input column data type is not convertible to
 * output data type.
 * @throw cudf::logic_error if `min` or `max` reduction is called and the
 * output type does not match the input column data type.
 * @throw cudf::logic_error if `any` or `all` reduction is called and the
 * output type is not bool8.
 *
 * @param segmented_values Column view of segmented inputs.
 * @param offsets Each segment's offset of @p segmented_values. A list of offsets
 * with size `num_segments + 1`. The size of `i`th segment is `offsets[i+1] -
 * offsets[i]`.
 * @param agg Aggregation operator applied by the reduction.
 * @param output_dtype  The output precision.
 * @param null_handling If `INCLUDE`, the reduction is valid if all elements in
 * a segment are valid, otherwise null. If `EXCLUDE`, the reduction is valid if
 * any element in the segment is valid, otherwise null.
 * @param mr Device memory resource used to allocate the returned scalar's device memory
 * @returns Output column with results of segmented reduction.
 */
std::unique_ptr<column> segmented_reduce(
  column_view const& segmented_values,
  device_span<size_type const> offsets,
  segmented_reduce_aggregation const& agg,
  data_type output_dtype,
  null_policy null_handling,
  rmm::mr::device_memory_resource* mr = rmm::mr::get_current_device_resource());

/**
 * @brief  Computes the scan of a column.
 *
 * The null values are skipped for the operation, and if an input element
 * at `i` is null, then the output element at `i` will also be null.
 *
 * @throws cudf::logic_error if column datatype is not numeric type.
 *
 * @param[in] input The input column view for the scan
 * @param[in] agg unique_ptr to aggregation operator applied by the scan
 * @param[in] inclusive The flag for applying an inclusive scan if
 *            scan_type::INCLUSIVE, an exclusive scan if scan_type::EXCLUSIVE.
 * @param[in] null_handling Exclude null values when computing the result if
 * null_policy::EXCLUDE. Include nulls if null_policy::INCLUDE.
 * Any operation with a null results in a null.
 * @param[in] mr Device memory resource used to allocate the returned scalar's device memory
 * @returns Scanned output column
 */
std::unique_ptr<column> scan(
  const column_view& input,
  std::unique_ptr<scan_aggregation> const& agg,
  scan_type inclusive,
  null_policy null_handling           = null_policy::EXCLUDE,
  rmm::mr::device_memory_resource* mr = rmm::mr::get_current_device_resource());

/**
 * @brief Determines the minimum and maximum values of a column.
 *
 *
 * @param col column to compute minmax
 * @param mr Device memory resource used to allocate the returned column's device memory
 * @return A std::pair of scalars with the first scalar being the minimum value
 *         and the second scalar being the maximum value of the input column.
 */
std::pair<std::unique_ptr<scalar>, std::unique_ptr<scalar>> minmax(
  column_view const& col,
  rmm::mr::device_memory_resource* mr = rmm::mr::get_current_device_resource());

/** @} */  // end of group

}  // namespace cudf
