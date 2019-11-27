/*
  * Copyright 2019, NVIDIA CORPORATION.
  *
  * Copyright 2018 BlazingDB, Inc.
 *     Copyright 2018 Alexander Ocsa <cristhian@blazingdb.com>
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

#include <cudf/replace.hpp>

#include <cudf/utilities/error.hpp>
#include <tests/utilities/column_wrapper.hpp>
#include <tests/utilities/base_fixture.hpp>
#include <tests/utilities/cudf_gtest.hpp>
#include <tests/utilities/type_lists.hpp>
#include <tests/utilities/column_utilities.hpp>
#include <cudf/cudf.h>
#include <gtest/gtest.h>
#include <cudf/scalar/scalar.hpp>

struct ReplaceErrorTest : public cudf::test::BaseFixture{};

// Error: old-values and new-values size mismatch
TEST_F(ReplaceErrorTest, SizeMismatch)
{
  std::vector<int32_t> input_column{7, 5, 6, 3, 1, 2, 8, 4};
  std::vector<cudf::valid_type> input_valid{0, 0, 1, 1, 1, 1, 1, 1};
  cudf::test::fixed_width_column_wrapper<int32_t> gdf_input_column{input_column.begin(),
                                                                   input_column.end(),
                                                                   input_valid.begin()};
  cudf::test::fixed_width_column_wrapper<int32_t> gdf_values_to_replace_column{{10, 11, 12, 13}};

  ASSERT_THROW(cudf::experimental::replace_nulls(gdf_input_column,
                                                 gdf_values_to_replace_column,
                                                 mr()),
               cudf::logic_error);
}

// Error: column type mismatch
TEST_F(ReplaceErrorTest, TypeMismatch)
{
  std::vector<int32_t> input_column{7, 5, 6, 3, 1, 2, 8, 4};
  std::vector<cudf::valid_type> input_valid{0, 0, 1, 1, 1, 1, 1, 1};
  cudf::test::fixed_width_column_wrapper<int32_t> gdf_input_column{input_column.begin(),
                                                                   input_column.end(),
                                                                   input_valid.begin()};
  cudf::test::fixed_width_column_wrapper<float> gdf_values_to_replace_column{{10, 11, 12, 13, 14, 15, 16, 17}};

  EXPECT_THROW(cudf::experimental::replace_nulls(gdf_input_column,
                                                 gdf_values_to_replace_column,
                                                 mr()),
               cudf::logic_error);
}

// Error: column type mismatch
TEST_F(ReplaceErrorTest, TypeMismatchScalar)
{
  std::vector<int32_t> input_column{7, 5, 6, 3, 1, 2, 8, 4};
  std::vector<cudf::valid_type> input_valid{0, 0, 1, 1, 1, 1, 1, 1};
  cudf::test::fixed_width_column_wrapper<int32_t> gdf_input_column{input_column.begin(),
                                                                   input_column.end(),
                                                                   input_valid.begin()};
  cudf::numeric_scalar<float> replacement(1);

  EXPECT_THROW(cudf::experimental::replace_nulls(gdf_input_column,
                                                 replacement,
                                                 mr()),
               cudf::logic_error);
}

template <typename T>
struct ReplaceNullsTest : public cudf::test::BaseFixture {};

using test_types = cudf::test::NumericTypes;

TYPED_TEST_CASE(ReplaceNullsTest, test_types);

template <typename T>
void ReplaceNullsColumn(cudf::test::fixed_width_column_wrapper<T> input,
                        cudf::test::fixed_width_column_wrapper<T> replacement_values,
                        cudf::test::fixed_width_column_wrapper<T> expected)
{
  std::unique_ptr<cudf::column> result;
  ASSERT_NO_THROW(result = cudf::experimental::replace_nulls(input, replacement_values));
  expect_columns_equal(expected, *result);
}

template <typename T>
void ReplaceNullsScalar(cudf::test::fixed_width_column_wrapper<T> input,
                        cudf::scalar const& replacement_value,
                        cudf::test::fixed_width_column_wrapper<T> expected)
{
  std::unique_ptr<cudf::column> result;
  ASSERT_NO_THROW(result = cudf::experimental::replace_nulls(input, replacement_value));
  expect_columns_equal(expected, *result);
}

TYPED_TEST(ReplaceNullsTest, ReplaceColumn)
{
  std::vector<TypeParam> inputColumn{0,1,2,3,4,5,6,7,8,9};
  std::vector<cudf::valid_type> inputValid{0,0,0,0,0,1,1,1,1,1};
  std::vector<TypeParam> replacementColumn{0,1,2,3,4,5,6,7,8,9};

  ReplaceNullsColumn<TypeParam>(
    cudf::test::fixed_width_column_wrapper<TypeParam> {inputColumn.begin(), inputColumn.end(), inputValid.begin()},
    cudf::test::fixed_width_column_wrapper<TypeParam> {replacementColumn.begin(), replacementColumn.end()},
    cudf::test::fixed_width_column_wrapper<TypeParam> {replacementColumn.begin(), replacementColumn.end()});
}

TYPED_TEST(ReplaceNullsTest, ReplaceColumn_Empty) {
  ReplaceNullsColumn<TypeParam>(
    cudf::test::fixed_width_column_wrapper<TypeParam> {},
    cudf::test::fixed_width_column_wrapper<TypeParam> {},
    cudf::test::fixed_width_column_wrapper<TypeParam> {});
}

TYPED_TEST(ReplaceNullsTest, ReplaceScalar)
{
  std::vector<TypeParam> inputColumn {0,1,2,3,4,5,6,7,8,9};
  std::vector<cudf::valid_type> inputValid {0,0,0,0,0,1,1,1,1,1};
  std::vector<TypeParam> expectedColumn{1,1,1,1,1,5,6,7,8,9};
  cudf::numeric_scalar<TypeParam> replacement(1);

  ReplaceNullsScalar<TypeParam>(
    cudf::test::fixed_width_column_wrapper<TypeParam> {inputColumn.begin(), inputColumn.end(), inputValid.begin()},
    replacement,
    cudf::test::fixed_width_column_wrapper<TypeParam> {expectedColumn.begin(), expectedColumn.end()});
}

TYPED_TEST(ReplaceNullsTest, ReplacementHasNulls) {
  std::vector<TypeParam> input_column{7, 5, 6, 3, 1, 2, 8, 4};
  std::vector<cudf::valid_type> input_valid{0, 0, 1, 1, 1, 1, 1, 1};

  std::vector<TypeParam> replace_column{4, 5, 6, 7, 8, 9, 0, 1};
  std::vector<cudf::valid_type> replace_valid{1, 0, 1, 1, 1, 1, 1, 1};

  std::vector<TypeParam> result_column{4, 5, 6, 3, 1, 2, 8, 4};
  std::vector<cudf::valid_type> result_valid{1, 0, 1, 1, 1, 1, 1, 1};

  ReplaceNullsColumn<TypeParam> (cudf::test::fixed_width_column_wrapper<TypeParam>{input_column.begin(), input_column.end(), input_valid.begin()},
                                 cudf::test::fixed_width_column_wrapper<TypeParam>{replace_column.begin(), replace_column.end(), replace_valid.begin()},
                                 cudf::test::fixed_width_column_wrapper<TypeParam>{result_column.begin(), result_column.end(), result_valid.begin()});
}

TYPED_TEST(ReplaceNullsTest, LargeScale) {
  std::vector<TypeParam> inputColumn(10000);
  for (size_t i = 0; i < inputColumn.size(); i++)
    inputColumn[i] = i % 2;
  std::vector<cudf::valid_type> inputValid(10000);
  for (size_t i = 0; i < inputValid.size(); i++)
    inputValid[i] = i % 2;
  std::vector<TypeParam>expectedColumn(10000);
  for (size_t i = 0; i < expectedColumn.size(); i++)
    expectedColumn[i] = 1;

  ReplaceNullsColumn<TypeParam>(
      cudf::test::fixed_width_column_wrapper<TypeParam>{inputColumn.begin(), inputColumn.end(), inputValid.begin()},
      cudf::test::fixed_width_column_wrapper<TypeParam>{expectedColumn.begin(), expectedColumn.end()},
      cudf::test::fixed_width_column_wrapper<TypeParam>{expectedColumn.begin(), expectedColumn.end()});
}

TYPED_TEST(ReplaceNullsTest, LargeScaleScalar) {
  std::vector<TypeParam> inputColumn(10000);
  for (size_t i = 0; i < inputColumn.size(); i++)
    inputColumn[i] = i % 2;
  std::vector<cudf::valid_type> inputValid(10000);
  for (size_t i = 0; i < inputValid.size(); i++)
    inputValid[i] = i % 2;
  std::vector<TypeParam>expectedColumn(10000);
  for (size_t i = 0; i < expectedColumn.size(); i++)
    expectedColumn[i] = 1;
  cudf::numeric_scalar<TypeParam> replacement(1);

  ReplaceNullsScalar<TypeParam>(
      cudf::test::fixed_width_column_wrapper<TypeParam>{inputColumn.begin(), inputColumn.end(), inputValid.begin()},
      replacement,
      cudf::test::fixed_width_column_wrapper<TypeParam>{expectedColumn.begin(), expectedColumn.end()});
}
