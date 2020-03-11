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

#include <cudf/cudf.h>
#include <cudf/types.hpp>
#include <tests/utilities/base_fixture.hpp>
#include <cudf/table/table_view.hpp>
#include <cudf/sorting.hpp>
#include <cudf/copying.hpp>
#include <cudf/column/column_factories.hpp>
#include <tests/utilities/column_utilities.hpp>
#include <cudf/utilities/type_dispatcher.hpp>
#include <tests/utilities/type_lists.hpp>
#include <tests/utilities/column_wrapper.hpp>
#include <tests/utilities/legacy/cudf_test_utils.cuh>
#include <tests/utilities/table_utilities.hpp>
#include <vector>
#include <tuple>


namespace cudf {
namespace test {

void run_rank_test (table_view input,
                    table_view expected,
                    rank_method method,
                    order column_order,
                    include_nulls _include_nulls,
                    null_order null_precedence,
                    bool debug=false
                    ) {
    // Rank
    auto got_rank_table = cudf::experimental::rank( input,
                                                    method,
                                                    column_order, 
                                                    _include_nulls, 
                                                    null_precedence,
                                                    false);
    if(debug) {
        cudf::test::print(got_rank_table->view().column(0)); std::cout<<"\n";
    }
    expect_tables_equal(expected, got_rank_table->view());
}

using input_arg_t = std::tuple<order, include_nulls, null_order>;
input_arg_t asce_keep{order::ASCENDING, include_nulls::NO,  null_order::AFTER};
input_arg_t asce_top{order::ASCENDING, include_nulls::YES, null_order::BEFORE};
input_arg_t asce_bottom{order::ASCENDING, include_nulls::YES, null_order::AFTER};

input_arg_t desc_keep{order::DESCENDING, include_nulls::NO,  null_order::BEFORE};
input_arg_t desc_top{order::DESCENDING, include_nulls::YES, null_order::AFTER};
input_arg_t desc_bottom{order::DESCENDING, include_nulls::YES, null_order::BEFORE};
using test_case_t = std::tuple<table_view, table_view>;

template <typename T>
struct Rank : public BaseFixture {
    
    fixed_width_column_wrapper<T>   col1{{  5,   4,   3,   5,   8,   5}};
    fixed_width_column_wrapper<T>   col2{{  5,   4,   3,   5,   8,   5}, {1, 1, 0, 1, 1, 1}};
    strings_column_wrapper          col3{{"d", "e", "a", "d", "k", "d"}, {1, 1, 1, 1, 1, 1}};

    void run_all_tests(
    rank_method method,
    input_arg_t input_arg,
    column_view const col1_rank,
    column_view const col2_rank,
    column_view const col3_rank)
    {
        if (std::is_same<T, cudf::experimental::bool8>::value) return;
        for (auto const &test_case : {
        // Non-null column
        test_case_t{table_view{{col1}}, table_view{{col1_rank}}},
        // Null column
        test_case_t{table_view{{col2}}, table_view{{col2_rank}}},
        // Table
        test_case_t{table_view{{col1,col2}}, table_view{{col1_rank, col2_rank}}},
        // Table with String column
        test_case_t{table_view{{col1, col2, col3}}, table_view{{col1_rank, col2_rank, col3_rank}}},
        }) {
      table_view input, output;
      std::tie(input, output) = test_case;

      run_rank_test(
          input, output, method,
          std::get<0>(input_arg), std::get<1>(input_arg), std::get<2>(input_arg), false);
      }
    }
};

TYPED_TEST_CASE(Rank, NumericTypes);




//fixed_width_column_wrapper<T>   col1{{  5,   4,   3,   5,   8,   5}};
//                                        3,   2,   1,   4,   6,   5
TYPED_TEST(Rank, first_asce_keep)
{
    //ASCENDING
    fixed_width_column_wrapper<double>  col1_rank   {{3, 2, 1, 4, 6, 5}};
    fixed_width_column_wrapper<double>  col2_rank   {{2, 1,-1, 3, 5, 4}, {1, 1, 0, 1, 1, 1}}; //KEEP
    fixed_width_column_wrapper<double>  col3_rank   {{2, 5, 1, 3, 6, 4}, {1, 1, 1, 1, 1, 1}};
    this->run_all_tests(rank_method::FIRST, asce_keep, col1_rank, col2_rank, col3_rank);
}

TYPED_TEST(Rank, first_asce_top)
{
    fixed_width_column_wrapper<double>  col1_rank    {{3, 2, 1, 4, 6, 5}};
    fixed_width_column_wrapper<double>  col2_rank    {{3, 2, 1, 4, 6, 5}}; //BEFORE = TOP
    fixed_width_column_wrapper<double>  col3_rank    {{2, 5, 1, 3, 6, 4}};
    this->run_all_tests(rank_method::FIRST, asce_top, col1_rank, col2_rank, col3_rank);
}

TYPED_TEST(Rank, first_asce_bottom)
{
    fixed_width_column_wrapper<double>  col1_rank {{3, 2, 1, 4, 6, 5}};;
    fixed_width_column_wrapper<double>  col2_rank {{2, 1, 6, 3, 5, 4}}; //AFTER  = BOTTOM
    fixed_width_column_wrapper<double>  col3_rank {{2, 5, 1, 3, 6, 4}};
    this->run_all_tests(rank_method::FIRST, asce_bottom, col1_rank, col2_rank, col3_rank);
}

TYPED_TEST(Rank, first_desc_keep)
{
    //DESCENDING
    fixed_width_column_wrapper<double>  col1_rank   {{2, 5, 6, 3, 1, 4}};
    fixed_width_column_wrapper<double>  col2_rank   {{2, 5,-1, 3, 1, 4}, {1, 1, 0, 1, 1, 1}}; //KEEP
    fixed_width_column_wrapper<double>  col3_rank   {{3, 2, 6, 4, 1, 5}, {1, 1, 1, 1, 1, 1}};
    this->run_all_tests(rank_method::FIRST, desc_keep, col1_rank, col2_rank, col3_rank);
}

TYPED_TEST(Rank, first_desc_top)
{    
    fixed_width_column_wrapper<double>  col1_rank    {{2, 5, 6, 3, 1, 4}};
    fixed_width_column_wrapper<double>  col2_rank    {{3, 6, 1, 4, 2, 5}}; //AFTER  = TOP
    fixed_width_column_wrapper<double>  col3_rank    {{3, 2, 6, 4, 1, 5}};
    this->run_all_tests(rank_method::FIRST, desc_top, col1_rank, col2_rank, col3_rank);
}

TYPED_TEST(Rank, first_desc_bottom)
{    
    fixed_width_column_wrapper<double>  col1_rank {{2, 5, 6, 3, 1, 4}};
    fixed_width_column_wrapper<double>  col2_rank {{2, 5, 6, 3, 1, 4}}; //BEFORE = BOTTOM
    fixed_width_column_wrapper<double>  col3_rank {{3, 2, 6, 4, 1, 5}};
    this->run_all_tests(rank_method::FIRST, desc_bottom, col1_rank, col2_rank, col3_rank);
}

TYPED_TEST(Rank, dense_asce_keep)
{
    cudf::test::fixed_width_column_wrapper<double> col1_rank  {{3, 2, 1, 3, 4, 3} };
    cudf::test::fixed_width_column_wrapper<double> col2_rank  {{2, 1, -1, 2, 3, 2} , {1, 1, 0, 1, 1, 1} };
    cudf::test::fixed_width_column_wrapper<double> col3_rank  {{2, 3, 1, 2, 4, 2} , {1, 1, 1, 1, 1, 1} };
    this->run_all_tests(rank_method::DENSE, asce_keep, col1_rank, col2_rank, col3_rank);
}

TYPED_TEST(Rank, dense_asce_top)
{
    cudf::test::fixed_width_column_wrapper<double> col1_rank  {{3, 2, 1, 3, 4, 3} };
    cudf::test::fixed_width_column_wrapper<double> col2_rank  {{3, 2, 1, 3, 4, 3} };
    cudf::test::fixed_width_column_wrapper<double> col3_rank  {{2, 3, 1, 2, 4, 2} };
    this->run_all_tests(rank_method::DENSE, asce_top, col1_rank, col2_rank, col3_rank);
}

TYPED_TEST(Rank, dense_asce_bottom)
{
    cudf::test::fixed_width_column_wrapper<double> col1_rank  {{3, 2, 1, 3, 4, 3} };
    cudf::test::fixed_width_column_wrapper<double> col2_rank  {{2, 1, 4, 2, 3, 2} };
    cudf::test::fixed_width_column_wrapper<double> col3_rank  {{2, 3, 1, 2, 4, 2} };
    this->run_all_tests(rank_method::DENSE, asce_bottom, col1_rank, col2_rank, col3_rank);
}

TYPED_TEST(Rank, dense_desc_keep)
{
    cudf::test::fixed_width_column_wrapper<double> col1_rank  {{2, 3, 4, 2, 1, 2} };
    cudf::test::fixed_width_column_wrapper<double> col2_rank  {{2, 3, -1, 2, 1, 2} , {1, 1, 0, 1, 1, 1} };
    cudf::test::fixed_width_column_wrapper<double> col3_rank  {{3, 2, 4, 3, 1, 3} , {1, 1, 1, 1, 1, 1} };
    this->run_all_tests(rank_method::DENSE, desc_keep, col1_rank, col2_rank, col3_rank);
}

TYPED_TEST(Rank, dense_desc_top)
{
    cudf::test::fixed_width_column_wrapper<double> col1_rank  {{2, 3, 4, 2, 1, 2} };
    cudf::test::fixed_width_column_wrapper<double> col2_rank  {{3, 4, 1, 3, 2, 3} };
    cudf::test::fixed_width_column_wrapper<double> col3_rank  {{3, 2, 4, 3, 1, 3} };
    this->run_all_tests(rank_method::DENSE, desc_top, col1_rank, col2_rank, col3_rank);
}

TYPED_TEST(Rank, dense_desc_bottom)
{
    cudf::test::fixed_width_column_wrapper<double> col1_rank  {{2, 3, 4, 2, 1, 2} };
    cudf::test::fixed_width_column_wrapper<double> col2_rank  {{2, 3, 4, 2, 1, 2} };
    cudf::test::fixed_width_column_wrapper<double> col3_rank  {{3, 2, 4, 3, 1, 3} };
    this->run_all_tests(rank_method::DENSE, desc_bottom, col1_rank, col2_rank, col3_rank);
}

TYPED_TEST(Rank, min_asce_keep)
{
    cudf::test::fixed_width_column_wrapper<double> col1_rank  {{3, 2, 1, 3, 6, 3} };
    cudf::test::fixed_width_column_wrapper<double> col2_rank  {{2, 1, -1, 2, 5, 2} , {1, 1, 0, 1, 1, 1} };
    cudf::test::fixed_width_column_wrapper<double> col3_rank  {{2, 5, 1, 2, 6, 2} , {1, 1, 1, 1, 1, 1} };
    this->run_all_tests(rank_method::MIN, asce_keep, col1_rank, col2_rank, col3_rank);
}

TYPED_TEST(Rank, min_asce_top)
{
    cudf::test::fixed_width_column_wrapper<double> col1_rank  {{3, 2, 1, 3, 6, 3} };
    cudf::test::fixed_width_column_wrapper<double> col2_rank  {{3, 2, 1, 3, 6, 3} };
    cudf::test::fixed_width_column_wrapper<double> col3_rank  {{2, 5, 1, 2, 6, 2} };
    this->run_all_tests(rank_method::MIN, asce_top, col1_rank, col2_rank, col3_rank);
}

TYPED_TEST(Rank, min_asce_bottom)
{
    cudf::test::fixed_width_column_wrapper<double> col1_rank  {{3, 2, 1, 3, 6, 3} };
    cudf::test::fixed_width_column_wrapper<double> col2_rank  {{2, 1, 6, 2, 5, 2} };
    cudf::test::fixed_width_column_wrapper<double> col3_rank  {{2, 5, 1, 2, 6, 2} };
    this->run_all_tests(rank_method::MIN, asce_bottom, col1_rank, col2_rank, col3_rank);
}

TYPED_TEST(Rank, min_desc_keep)
{
    cudf::test::fixed_width_column_wrapper<double> col1_rank  {{2, 5, 6, 2, 1, 2} };
    cudf::test::fixed_width_column_wrapper<double> col2_rank  {{2, 5, -1, 2, 1, 2} , {1, 1, 0, 1, 1, 1} };
    cudf::test::fixed_width_column_wrapper<double> col3_rank  {{3, 2, 6, 3, 1, 3} , {1, 1, 1, 1, 1, 1} };
    this->run_all_tests(rank_method::MIN, desc_keep, col1_rank, col2_rank, col3_rank);
}

TYPED_TEST(Rank, min_desc_top)
{
    cudf::test::fixed_width_column_wrapper<double> col1_rank  {{2, 5, 6, 2, 1, 2} };
    cudf::test::fixed_width_column_wrapper<double> col2_rank  {{3, 6, 1, 3, 2, 3} };
    cudf::test::fixed_width_column_wrapper<double> col3_rank  {{3, 2, 6, 3, 1, 3} };
    this->run_all_tests(rank_method::MIN, desc_top, col1_rank, col2_rank, col3_rank);
}

TYPED_TEST(Rank, min_desc_bottom)
{
    cudf::test::fixed_width_column_wrapper<double> col1_rank  {{2, 5, 6, 2, 1, 2} };
    cudf::test::fixed_width_column_wrapper<double> col2_rank  {{2, 5, 6, 2, 1, 2} };
    cudf::test::fixed_width_column_wrapper<double> col3_rank  {{3, 2, 6, 3, 1, 3} };
    this->run_all_tests(rank_method::MIN, desc_bottom, col1_rank, col2_rank, col3_rank);
}

TYPED_TEST(Rank, max_asce_keep)
{
    cudf::test::fixed_width_column_wrapper<double> col1_rank  {{5, 2, 1, 5, 6, 5} };
    cudf::test::fixed_width_column_wrapper<double> col2_rank  {{4, 1, -1, 4, 5, 4} , {1, 1, 0, 1, 1, 1} };
    cudf::test::fixed_width_column_wrapper<double> col3_rank  {{4, 5, 1, 4, 6, 4} , {1, 1, 1, 1, 1, 1} };
    this->run_all_tests(rank_method::MAX, asce_keep, col1_rank, col2_rank, col3_rank);
}

TYPED_TEST(Rank, max_asce_top)
{
    cudf::test::fixed_width_column_wrapper<double> col1_rank  {{5, 2, 1, 5, 6, 5} };
    cudf::test::fixed_width_column_wrapper<double> col2_rank  {{5, 2, 1, 5, 6, 5} };
    cudf::test::fixed_width_column_wrapper<double> col3_rank  {{4, 5, 1, 4, 6, 4} };
    this->run_all_tests(rank_method::MAX, asce_top, col1_rank, col2_rank, col3_rank);
}

TYPED_TEST(Rank, max_asce_bottom)
{
    cudf::test::fixed_width_column_wrapper<double> col1_rank  {{5, 2, 1, 5, 6, 5} };
    cudf::test::fixed_width_column_wrapper<double> col2_rank  {{4, 1, 6, 4, 5, 4} };
    cudf::test::fixed_width_column_wrapper<double> col3_rank  {{4, 5, 1, 4, 6, 4} };
    this->run_all_tests(rank_method::MAX, asce_bottom, col1_rank, col2_rank, col3_rank);
}

TYPED_TEST(Rank, max_desc_keep)
{
    cudf::test::fixed_width_column_wrapper<double> col1_rank  {{4, 5, 6, 4, 1, 4} };
    cudf::test::fixed_width_column_wrapper<double> col2_rank  {{4, 5, -1, 4, 1, 4} , {1, 1, 0, 1, 1, 1} };
    cudf::test::fixed_width_column_wrapper<double> col3_rank  {{5, 2, 6, 5, 1, 5} , {1, 1, 1, 1, 1, 1} };
    this->run_all_tests(rank_method::MAX, desc_keep, col1_rank, col2_rank, col3_rank);
}

TYPED_TEST(Rank, max_desc_top)
{
    cudf::test::fixed_width_column_wrapper<double> col1_rank  {{4, 5, 6, 4, 1, 4} };
    cudf::test::fixed_width_column_wrapper<double> col2_rank  {{5, 6, 1, 5, 2, 5} };
    cudf::test::fixed_width_column_wrapper<double> col3_rank  {{5, 2, 6, 5, 1, 5} };
    this->run_all_tests(rank_method::MAX, desc_top, col1_rank, col2_rank, col3_rank);
}

TYPED_TEST(Rank, max_desc_bottom)
{
    cudf::test::fixed_width_column_wrapper<double> col1_rank  {{4, 5, 6, 4, 1, 4} };
    cudf::test::fixed_width_column_wrapper<double> col2_rank  {{4, 5, 6, 4, 1, 4} };
    cudf::test::fixed_width_column_wrapper<double> col3_rank  {{5, 2, 6, 5, 1, 5} };
    this->run_all_tests(rank_method::MAX, desc_bottom, col1_rank, col2_rank, col3_rank);
}

TYPED_TEST(Rank, average_asce_keep)
{
    cudf::test::fixed_width_column_wrapper<double> col1_rank  {{4, 2, 1, 4, 6, 4} };
    cudf::test::fixed_width_column_wrapper<double> col2_rank  {{3, 1, -1, 3, 5, 3} , {1, 1, 0, 1, 1, 1} };
    cudf::test::fixed_width_column_wrapper<double> col3_rank  {{3, 5, 1, 3, 6, 3} , {1, 1, 1, 1, 1, 1} };
    this->run_all_tests(rank_method::AVERAGE, asce_keep, col1_rank, col2_rank, col3_rank);
}

TYPED_TEST(Rank, average_asce_top)
{
    cudf::test::fixed_width_column_wrapper<double> col1_rank  {{4, 2, 1, 4, 6, 4} };
    cudf::test::fixed_width_column_wrapper<double> col2_rank  {{4, 2, 1, 4, 6, 4} };
    cudf::test::fixed_width_column_wrapper<double> col3_rank  {{3, 5, 1, 3, 6, 3} };
    this->run_all_tests(rank_method::AVERAGE, asce_top, col1_rank, col2_rank, col3_rank);
}

TYPED_TEST(Rank, average_asce_bottom)
{
    cudf::test::fixed_width_column_wrapper<double> col1_rank  {{4, 2, 1, 4, 6, 4} };
    cudf::test::fixed_width_column_wrapper<double> col2_rank  {{3, 1, 6, 3, 5, 3} };
    cudf::test::fixed_width_column_wrapper<double> col3_rank  {{3, 5, 1, 3, 6, 3} };
    this->run_all_tests(rank_method::AVERAGE, asce_bottom, col1_rank, col2_rank, col3_rank);
}

TYPED_TEST(Rank, average_desc_keep)
{
    cudf::test::fixed_width_column_wrapper<double> col1_rank  {{3, 5, 6, 3, 1, 3} };
    cudf::test::fixed_width_column_wrapper<double> col2_rank  {{3, 5, -1, 3, 1, 3} , {1, 1, 0, 1, 1, 1} };
    cudf::test::fixed_width_column_wrapper<double> col3_rank  {{4, 2, 6, 4, 1, 4} , {1, 1, 1, 1, 1, 1} };
    this->run_all_tests(rank_method::AVERAGE, desc_keep, col1_rank, col2_rank, col3_rank);
}

TYPED_TEST(Rank, average_desc_top)
{
    cudf::test::fixed_width_column_wrapper<double> col1_rank  {{3, 5, 6, 3, 1, 3} };
    cudf::test::fixed_width_column_wrapper<double> col2_rank  {{4, 6, 1, 4, 2, 4} };
    cudf::test::fixed_width_column_wrapper<double> col3_rank  {{4, 2, 6, 4, 1, 4} };
    this->run_all_tests(rank_method::AVERAGE, desc_top, col1_rank, col2_rank, col3_rank);
}

TYPED_TEST(Rank, average_desc_bottom)
{
    cudf::test::fixed_width_column_wrapper<double> col1_rank  {{3, 5, 6, 3, 1, 3} };
    cudf::test::fixed_width_column_wrapper<double> col2_rank  {{3, 5, 6, 3, 1, 3} };
    cudf::test::fixed_width_column_wrapper<double> col3_rank  {{4, 2, 6, 4, 1, 4} };
    this->run_all_tests(rank_method::AVERAGE, desc_bottom, col1_rank, col2_rank, col3_rank);
}

} // namespace test
} // namespace cudf
