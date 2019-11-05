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

#include <cudf/cudf.h>
#include <cudf/types.hpp>
#include <tests/utilities/base_fixture.hpp>
#include <cudf/copying.hpp>
#include <cudf/table/table.hpp>
#include <tests/utilities/column_utilities.hpp>
#include <cudf/table/table_view.hpp>
#include <cudf/stream_compaction.hpp>
#include <tests/utilities/column_wrapper.hpp>
#include <tests/utilities/type_lists.hpp>

void expect_table_properties_equal(cudf::table_view lhs, cudf::table_view rhs) {
  EXPECT_EQ(lhs.num_rows(), rhs.num_rows());
  EXPECT_EQ(lhs.num_columns(), rhs.num_columns());
}

void expect_tables_equal(cudf::table_view lhs, cudf::table_view rhs) {
  expect_table_properties_equal(lhs, rhs);
  for (auto i=0; i<lhs.num_columns(); ++i) {
    cudf::test::expect_columns_equal(lhs.column(i), rhs.column(i));
  }
}

struct DropNullsTest : public cudf::test::BaseFixture {};

TEST_F(DropNullsTest, WholeRowIsNull) {
    cudf::test::fixed_width_column_wrapper<int16_t> col1{{true, false, true, false, true, false}, {1, 1, 0, 1, 1, 0}};
    cudf::test::fixed_width_column_wrapper<int32_t> col2{{10, 40, 70, 5, 2, 10}, {1, 1, 0, 1, 1, 0}};
    cudf::test::fixed_width_column_wrapper<double> col3{{10, 40, 70, 5, 2, 10}, {1, 1, 0, 1, 1, 0}};
    cudf::table_view input {{col1, col2, col3}};
    cudf::test::fixed_width_column_wrapper<int16_t> col1_expected{{true, false, false, true}, {1, 1, 1, 1}};
    cudf::test::fixed_width_column_wrapper<int32_t> col2_expected{{10, 40, 5, 2}, {1, 1, 1, 1}};
    cudf::test::fixed_width_column_wrapper<double> col3_expected{{10, 40, 5, 2}, {1, 1, 1, 1}};
    cudf::table_view expected {{col1_expected, col2_expected, col3_expected}};
   
    auto got = cudf::experimental::drop_nulls(input, input);

    expect_tables_equal(expected, got->view());
}

TEST_F(DropNullsTest, NoNull) {
    cudf::test::fixed_width_column_wrapper<int16_t> col1{{true, false, true, false, true, false}, {1, 1, 1, 1, 1, 1}};
    cudf::test::fixed_width_column_wrapper<int32_t> col2{{10, 40, 70, 5, 2, 10}, {1, 1, 1, 1, 1, 1}};
    cudf::test::fixed_width_column_wrapper<double> col3{{10, 40, 70, 5, 2, 10}, {1, 1, 1, 1, 1, 1}};
    cudf::table_view input {{col1, col2, col3}};

    auto got = cudf::experimental::drop_nulls(input, input);

    expect_tables_equal(input, got->view());
}

TEST_F(DropNullsTest, MixedSetOfRows) {
    cudf::test::fixed_width_column_wrapper<int16_t> col1{{true, false, true, false, true, false}, {1, 1, 0, 1, 1, 0}};
    cudf::test::fixed_width_column_wrapper<int32_t> col2{{10, 40, 70, 5, 2, 10}, {1, 1, 0, 1, 1, 0}};
    cudf::test::fixed_width_column_wrapper<double> col3{{10, 40, 70, 5, 2, 10}, {1, 1, 0, 1, 1, 1}};
    cudf::table_view input {{col1, col2, col3}};
    cudf::test::fixed_width_column_wrapper<int16_t> col1_expected{{true, false, false, true}, {1, 1, 1, 1}};
    cudf::test::fixed_width_column_wrapper<int32_t> col2_expected{{10, 40, 5, 2}, {1, 1, 1, 1}};
    cudf::test::fixed_width_column_wrapper<double> col3_expected{{10, 40, 5, 2}, {1, 1, 1, 1}};
    cudf::table_view expected {{col1_expected, col2_expected, col3_expected}};

    auto got = cudf::experimental::drop_nulls(input, input);

    expect_tables_equal(expected, got->view());
}

TEST_F(DropNullsTest, MixedSetOfRowsWithThreshold) {
    cudf::test::fixed_width_column_wrapper<int16_t> col1{{true, false, true, false, true, false}, {1, 1, 0, 1, 1, 0}};
    cudf::test::fixed_width_column_wrapper<int32_t> col2{{10, 40, 70, 5, 2, 10}, {1, 1, 0, 1, 1, 1}};
    cudf::test::fixed_width_column_wrapper<double> col3{{10, 40, 70, 5, 2, 10}, {1, 1, 1, 1, 1, 1}};
    cudf::table_view input {{col1, col2, col3}};
    cudf::test::fixed_width_column_wrapper<int16_t> col1_expected{{true, false, false, true, false}, {1, 1, 1, 1, 0}};
    cudf::test::fixed_width_column_wrapper<int32_t> col2_expected{{10, 40, 5, 2, 10}, {1, 1, 1, 1, 1}};
    cudf::test::fixed_width_column_wrapper<double> col3_expected{{10, 40, 5, 2, 10}, {1, 1, 1, 1, 1}};
    cudf::table_view expected {{col1_expected, col2_expected, col3_expected}};

    auto got = cudf::experimental::drop_nulls(input, input, input.num_columns()-1);

    expect_tables_equal(expected, got->view());
}

TEST_F(DropNullsTest, EmptyTable) {
    cudf::table_view input{{}};
    cudf::table_view expected{{}};

    auto got = cudf::experimental::drop_nulls(input, input);

    expect_tables_equal(expected, got->view());
}

TEST_F(DropNullsTest, EmptyColumns) {
    cudf::test::fixed_width_column_wrapper<int16_t> col1{};
    cudf::test::fixed_width_column_wrapper<int32_t> col2{};
    cudf::test::fixed_width_column_wrapper<double> col3{};
    std::cout<<"RGSL : Row size is "<<static_cast<cudf::column_view>(col1).size()<<std::endl;
    cudf::table_view input {{col1, col2, col3}};
    cudf::test::fixed_width_column_wrapper<int16_t> col1_expected{};
    cudf::test::fixed_width_column_wrapper<int32_t> col2_expected{};
    cudf::test::fixed_width_column_wrapper<double> col3_expected{};
    cudf::table_view expected {{col1_expected, col2_expected, col3_expected}};

    auto got = cudf::experimental::drop_nulls(input, input);

    expect_tables_equal(expected, got->view());
}

TEST_F(DropNullsTest, MisMatchInKeysAndInputSize) {
    cudf::table_view input{{}};
    cudf::test::fixed_width_column_wrapper<int16_t> col1{{true, false, true, false, true, false}, {1, 1, 0, 1, 1, 0}};
    cudf::table_view keys {{col1}};
    cudf::table_view expected{{}};

    EXPECT_THROW(cudf::experimental::drop_nulls(input, keys), cudf::logic_error);
}

#if 0
TEST_F(DropNullsTest, AllNull) {
    cudf::test::fixed_width_column_wrapper<int16_t> col{{true, false, true, false, true, false}, {1, 1, 1, 1, 1, 1}};
    cudf::table_view input {{col}};
    cudf::test::fixed_width_column_wrapper<int16_t> key_col{{true, false, true, false, true, false}, {0, 0, 0, 0, 0, 0}};
    cudf::table_view keys {{key_col}};
    cudf::test::fixed_width_column_wrapper<int16_t> expected_col{};
    cudf::column_view view = expected_col;
    std::cout<<"RGSL: Num of rows is "<<view.size()<<std::endl;
    cudf::table_view expected {{expected_col}};

    auto got = cudf::experimental::drop_nulls(input, keys);

    expect_tables_equal(expected, got->view());
}
#endif

template <typename T>
struct DropNullsTestAll : public cudf::test::BaseFixture {};

TYPED_TEST_CASE(DropNullsTestAll, cudf::test::NumericTypes);


TYPED_TEST(DropNullsTestAll, AllNull) {
    using T = TypeParam;
    cudf::test::fixed_width_column_wrapper<T> col{{true, false, true, false, true, false}, {1, 1, 1, 1, 1, 1}};
    cudf::table_view input {{col}};
    cudf::test::fixed_width_column_wrapper<T> key_col{{true, false, true, false, true, false}, {0, 0, 0, 0, 0, 0}};
    cudf::table_view keys {{key_col}};
    cudf::test::fixed_width_column_wrapper<T> expected_col{};
    cudf::column_view view = expected_col;
    cudf::table_view expected {{expected_col}};

    auto got = cudf::experimental::drop_nulls(input, keys);

    expect_tables_equal(expected, got->view());
}

