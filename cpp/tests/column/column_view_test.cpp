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

#include <cudf/column/column.hpp>
#include <cudf/column/column_view.hpp>
#include <cudf/types.hpp>
#include <cudf/utilities/type_dispatcher.hpp>
#include <tests/utilities/base_fixture.hpp>
#include <tests/utilities/column_utilities.hpp>
#include <tests/utilities/column_wrapper.hpp>
#include <tests/utilities/cudf_gtest.hpp>
#include <tests/utilities/type_list_utilities.hpp>
#include <tests/utilities/type_lists.hpp>

#include <thrust/sequence.h>
#include <random>

template <typename T, typename T2=void>
struct rep_type_t
{
  using type = void;
};

template <typename T>
struct rep_type_t<T, typename std::enable_if<cudf::is_timestamp<T>()>::type>
{
  using type = typename T::duration::rep;
};

template <typename T>
struct ColumnViewAllTypesTests : public cudf::test::BaseFixture {};

TYPED_TEST_CASE(ColumnViewAllTypesTests, cudf::test::FixedWidthTypes);

template <typename FromType, typename ToType>
void do_logical_cast(cudf::column_view const& input)
{
  if (std::is_same<FromType, ToType>::value)
  {
    // Cast to same type
    auto output = input.logical_cast(input.type());
    cudf::test::expect_columns_equal(output, input);
  }
  else if (std::is_same<typename rep_type_t<FromType>::type, ToType>::value)
  {
    // Cast to integer type and back to timestamp
    cudf::data_type integer_type{cudf::type_to_id<ToType>()};
    auto integer_view = input.logical_cast(integer_type);
    auto output = integer_view.logical_cast(input.type());
    cudf::test::expect_columns_equal(output, input);
  }
  else if (std::is_same<typename rep_type_t<ToType>::type, FromType>::value)
  {
    // Cast to timestamp type and back to integer
    cudf::data_type timestamp_type{cudf::type_to_id<ToType>()};
    auto timestamp_view = input.logical_cast(timestamp_type);
    auto output = timestamp_view.logical_cast(input.type());
    cudf::test::expect_columns_equal(output, input);
  }
  else
  {
    // Other casts not allowed
    cudf::data_type type{cudf::type_to_id<ToType>()};
    EXPECT_THROW(input.logical_cast(type), cudf::logic_error);
  }
}

TYPED_TEST(ColumnViewAllTypesTests, LogicalCast)
{
  cudf::test::fixed_width_column_wrapper<TypeParam> input({1, 2, 3, 4, 5, 6, 7, 8});

  do_logical_cast<TypeParam, int8_t>(input);
  do_logical_cast<TypeParam, int16_t>(input);
  do_logical_cast<TypeParam, int32_t>(input);
  do_logical_cast<TypeParam, int64_t>(input);
  do_logical_cast<TypeParam, float>(input);
  do_logical_cast<TypeParam, double>(input);
  do_logical_cast<TypeParam, bool>(input);
  do_logical_cast<TypeParam, cudf::timestamp_D>(input);
  do_logical_cast<TypeParam, cudf::timestamp_s>(input);
  do_logical_cast<TypeParam, cudf::timestamp_ms>(input);
  do_logical_cast<TypeParam, cudf::timestamp_us>(input);
  do_logical_cast<TypeParam, cudf::timestamp_ns>(input);
}
