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

#include <tests/utilities/cudf_test_fixtures.h>
#include <groupby.hpp>
#include <table.hpp>
#include <tests/utilities/column_wrapper.cuh>
#include <utilities/type_dispatcher.hpp>

#include <gmock/gmock.h>
#include <gtest/gtest.h>

#include <random>

template <typename T>
struct GroupbyTest : public GdfTest {
  std::default_random_engine generator;
  std::uniform_int_distribution<int> distribution{1000, 10000};
  int random_size() { return distribution(generator); }
};

using TestingTypes =
    ::testing::Types<int32_t/*int8_t, int16_t, int32_t, int64_t, float, double,
                     cudf::date32, cudf::date64, cudf::category, cudf::bool8*/>;

TYPED_TEST_CASE(GroupbyTest, TestingTypes);

TYPED_TEST(GroupbyTest, OneGroupCount) {
  using namespace cudf::groupby::hash;
  using T = TypeParam;
  cudf::test::column_wrapper<TypeParam> keys{T(1), T(1), T(1), T(1)};
  cudf::test::column_wrapper<TypeParam> values{T(1), T(2), T(3), T(4)};

  cudf::table input_keys{keys.get()};
  cudf::table input_values{values.get()};
  std::vector<operators> ops{MAX};

  cudf::table output_keys;
  cudf::table output_values;
  std::tie(output_keys, output_values) = groupby(input_keys, input_values, ops);

  EXPECT_EQ(1, output_keys.num_rows());
  EXPECT_EQ(1, output_values.num_rows());

  auto input_key_types = cudf::column_dtypes(input_keys);

  EXPECT_TRUE(std::equal(input_key_types.begin(), input_key_types.end(),
                         cudf::column_dtypes(output_keys).begin()));

  cudf::test::column_wrapper<TypeParam> output_keys_column(
      *output_keys.get_column(0));
  cudf::test::column_wrapper<TypeParam> output_values_column(
      *output_values.get_column(0));

  auto output_keys_host = output_keys_column.to_host();
  auto output_values_host = output_values_column.to_host();

  EXPECT_EQ(T(1), std::get<0>(output_keys_host)[0]);
  EXPECT_EQ(T(4), std::get<0>(output_values_host)[0]);
}