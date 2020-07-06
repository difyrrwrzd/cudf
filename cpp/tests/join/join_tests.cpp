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
#include <cudf/copying.hpp>
#include <cudf/join.hpp>
#include <cudf/sorting.hpp>
#include <cudf/table/table.hpp>
#include <cudf/table/table_view.hpp>

#include <tests/utilities/base_fixture.hpp>
#include <tests/utilities/column_utilities.hpp>
#include <tests/utilities/column_wrapper.hpp>
#include <tests/utilities/table_utilities.hpp>
#include <tests/utilities/type_lists.hpp>

#include <future>

template <typename T>
using column_wrapper  = cudf::test::fixed_width_column_wrapper<T>;
using strcol_wrapper  = cudf::test::strings_column_wrapper;
using CVector         = std::vector<std::unique_ptr<cudf::column>>;
using Table           = cudf::table;
using ProbeOutputSide = cudf::hash_join::probe_output_side;

struct JoinTest : public cudf::test::BaseFixture {
};

enum class join_kind { INNER, LEFT, FULL };

//template <
//  join_kind JoinKind,
//  typename std::enable_if_t<JoinKind == join_kind::INNER, ProbeOutputSide> probe_output_side = ProbeOutputSide::LEFT>
//auto probe(cudf::hash_join const& hash_join,
//                  Table const& probe,
//                  std::vector<cudf::size_type> const& probe_on,
//                  std::vector<std::pair<cudf::size_type, cudf::size_type>> const& columns_in_common)
//{
//  return hash_join->inner_join(probe, probe_on, columns_in_common, probe_output_side);
//}
//
//template <join_kind JoinKind, typename = std::enable_if_t<JoinKind != join_kind::INNER, void>>
//auto probe(cudf::hash_join const& hash_join,
//                  Table const& probe,
//                  std::vector<cudf::size_type> const& probe_on,
//                  std::vector<std::pair<cudf::size_type, cudf::size_type>> const& columns_in_common)
//{
//  if (JoinKind == LEFT) {
//    return hash_join->left_join(probe, probe_on, columns_in_common);
//  } else {
//    return hash_join->full_join(probe, probe_on, columns_in_common);
//  }
//}

template <join_kind JoinKind,
          bool sort_result                  = true,
          ProbeOutputSide probe_output_side = ProbeOutputSide::LEFT,
          size_t parallelism                = 8>
void build_once_probe_parallel(
  Table const& left,
  Table const& right,
  std::vector<cudf::size_type> const& left_on,
  std::vector<cudf::size_type> const& right_on,
  std::vector<std::pair<cudf::size_type, cudf::size_type>> const& columns_in_common,
  Table const& gold)
{
  auto hash_join = cudf::hash_join::create(right, right_on);

  std::vector<std::future<void>> probe_threads(parallelism);
  std::vector<std::unique_ptr<Table>> results(parallelism);
  for (size_t i = 0; i < parallelism; i++) {
    probe_threads.push_back(std::async(
      std::launch::async,
      [&](size_t idx) {
        if (JoinKind == join_kind::INNER) {
          results[idx] = hash_join->inner_join(left, left_on, columns_in_common, probe_output_side);
        } else if (JoinKind == join_kind::LEFT) {
          results[idx] = hash_join->left_join(left, left_on, columns_in_common);
        } else if (JoinKind == join_kind::FULL) {
          results[idx] = hash_join->full_join(left, left_on, columns_in_common);
        }
      },
      i));
  }
  for (auto& t : probe_threads) { t.wait(); }

  for (const auto& result : results) {
    if (sort_result) {
      auto result_sorted_order = cudf::sorted_order(result->view());
      auto sorted_result       = cudf::gather(result->view(), *result_sorted_order);
      cudf::test::expect_tables_equal(gold, *sorted_result);
    } else {
      cudf::test::expect_tables_equal(gold, *result);
    }
  }
}

TEST_F(JoinTest, InvalidCommonColumnIndices)
{
  column_wrapper<int32_t> col0_0{{3, 1, 2, 0, 3}};
  column_wrapper<int32_t> col0_1{{0, 1, 2, 4, 1}};

  column_wrapper<int32_t> col1_0{{2, 2, 0, 4, 3}};
  column_wrapper<int32_t> col1_1{{1, 0, 1, 2, 1}};

  CVector cols0, cols1;
  cols0.push_back(col0_0.release());
  cols0.push_back(col0_1.release());
  cols1.push_back(col1_0.release());
  cols1.push_back(col1_1.release());

  Table t0(std::move(cols0));
  Table t1(std::move(cols1));

  EXPECT_THROW(cudf::inner_join(t0, t1, {0, 1}, {0, 1}, {{0, 1}, {1, 0}}), cudf::logic_error);

  auto build_probe_inner_1 = [&] {
    build_once_probe_parallel<join_kind::INNER, false>(t0, t1, {0, 1}, {0, 1}, {{0, 1}, {1, 0}}, {});
  };
auto build_probe_inner_2 = [&] {
  build_once_probe_parallel<join_kind::INNER, false, ProbeOutputSide::RIGHT>(t1, t0, {0, 1}, {0, 1}, {{1, 0}, {0, 1}}, {});
};

  EXPECT_THROW(build_probe_inner_1(), cudf::logic_error);
  EXPECT_THROW(build_probe_inner_2(), cudf::logic_error);
}

TEST_F(JoinTest, FullJoinNoCommon)
{
  column_wrapper<int32_t> col0_0{{0, 1}};
  column_wrapper<int32_t> col1_0{{0, 2}};
  CVector cols0, cols1;
  cols0.push_back(col0_0.release());
  cols1.push_back(col1_0.release());

  Table t0(std::move(cols0));
  Table t1(std::move(cols1));

  column_wrapper<int32_t> exp_col0_0{{0, 1, -1}, {1, 1, 0}};
  column_wrapper<int32_t> exp_col0_1{{0, -1, 2}, {1, 0, 1}};
  CVector exp_cols;
  exp_cols.push_back(exp_col0_0.release());
  exp_cols.push_back(exp_col0_1.release());
  Table gold(std::move(exp_cols));

  auto result            = cudf::full_join(t0, t1, {0}, {0}, {});
  auto result_sort_order = cudf::sorted_order(result->view());
  auto sorted_result     = cudf::gather(result->view(), *result_sort_order);

  auto gold_sort_order = cudf::sorted_order(gold.view());
  auto sorted_gold     = cudf::gather(gold.view(), *gold_sort_order);
  cudf::test::expect_tables_equal(*sorted_gold, *sorted_result);

  build_once_probe_parallel<join_kind::FULL>(t0, t1, {0}, {0}, {}, *sorted_gold);
}

TEST_F(JoinTest, LeftJoinNoNullsWithNoCommon)
{
  column_wrapper<int32_t> col0_0{{3, 1, 2, 0, 3}};
  strcol_wrapper col0_1({"s0", "s1", "s2", "s4", "s1"});
  column_wrapper<int32_t> col0_2{{0, 1, 2, 4, 1}};

  column_wrapper<int32_t> col1_0{{2, 2, 0, 4, 3}};
  strcol_wrapper col1_1{{"s1", "s0", "s1", "s2", "s1"}};
  column_wrapper<int32_t> col1_2{{1, 0, 1, 2, 1}};

  CVector cols0, cols1;
  cols0.push_back(col0_0.release());
  cols0.push_back(col0_1.release());
  cols0.push_back(col0_2.release());
  cols1.push_back(col1_0.release());
  cols1.push_back(col1_1.release());
  cols1.push_back(col1_2.release());

  Table t0(std::move(cols0));
  Table t1(std::move(cols1));

  auto result            = cudf::left_join(t0, t1, {0}, {0}, {});
  auto result_sort_order = cudf::sorted_order(result->view());
  auto sorted_result     = cudf::gather(result->view(), *result_sort_order);

  column_wrapper<int32_t> col_gold_0{{3, 1, 2, 2, 0, 3}, {1, 1, 1, 1, 1, 1}};
  strcol_wrapper col_gold_1({"s0", "s1", "s2", "s2", "s4", "s1"}, {1, 1, 1, 1, 1, 1});
  column_wrapper<int32_t> col_gold_2{{0, 1, 2, 2, 4, 1}, {1, 1, 1, 1, 1, 1}};
  column_wrapper<int32_t> col_gold_3{{3, -1, 2, 2, 0, 3}, {1, 0, 1, 1, 1, 1}};
  strcol_wrapper col_gold_4({"s1", "", "s1", "s0", "s1", "s1"}, {1, 0, 1, 1, 1, 1});
  column_wrapper<int32_t> col_gold_5{{1, -1, 1, 0, 1, 1}, {1, 0, 1, 1, 1, 1}};
  CVector cols_gold;
  cols_gold.push_back(col_gold_0.release());
  cols_gold.push_back(col_gold_1.release());
  cols_gold.push_back(col_gold_2.release());
  cols_gold.push_back(col_gold_3.release());
  cols_gold.push_back(col_gold_4.release());
  cols_gold.push_back(col_gold_5.release());
  Table gold(std::move(cols_gold));

  auto gold_sort_order = cudf::sorted_order(gold.view());
  auto sorted_gold     = cudf::gather(gold.view(), *gold_sort_order);

  cudf::test::expect_tables_equal(*sorted_gold, *sorted_result);

  build_once_probe_parallel<join_kind::LEFT>(t0, t1, {0}, {0}, {}, *sorted_gold);
}

TEST_F(JoinTest, FullJoinNoNulls)
{
  column_wrapper<int32_t> col0_0{{3, 1, 2, 0, 3}};
  strcol_wrapper col0_1({"s0", "s1", "s2", "s4", "s1"});
  column_wrapper<int32_t> col0_2{{0, 1, 2, 4, 1}};

  column_wrapper<int32_t> col1_0{{2, 2, 0, 4, 3}};
  strcol_wrapper col1_1{{"s1", "s0", "s1", "s2", "s1"}};
  column_wrapper<int32_t> col1_2{{1, 0, 1, 2, 1}};

  CVector cols0, cols1;
  cols0.push_back(col0_0.release());
  cols0.push_back(col0_1.release());
  cols0.push_back(col0_2.release());
  cols1.push_back(col1_0.release());
  cols1.push_back(col1_1.release());
  cols1.push_back(col1_2.release());

  Table t0(std::move(cols0));
  Table t1(std::move(cols1));

  auto result            = cudf::full_join(t0, t1, {0, 1}, {0, 1}, {{0, 0}, {1, 1}});
  auto result_sort_order = cudf::sorted_order(result->view());
  auto sorted_result     = cudf::gather(result->view(), *result_sort_order);

  column_wrapper<int32_t> col_gold_0{{2, 2, 0, 4, 3, 3, 1, 2, 0}};
  strcol_wrapper col_gold_1({"s1", "s0", "s1", "s2", "s1", "s0", "s1", "s2", "s4"});
  column_wrapper<int32_t> col_gold_2{{-1, -1, -1, -1, 1, 0, 1, 2, 4}, {0, 0, 0, 0, 1, 1, 1, 1, 1}};
  column_wrapper<int32_t> col_gold_3{{1, 0, 1, 2, 1, -1, -1, -1, -1}, {1, 1, 1, 1, 1, 0, 0, 0, 0}};
  CVector cols_gold;
  cols_gold.push_back(col_gold_0.release());
  cols_gold.push_back(col_gold_1.release());
  cols_gold.push_back(col_gold_2.release());
  cols_gold.push_back(col_gold_3.release());
  Table gold(std::move(cols_gold));

  auto gold_sort_order = cudf::sorted_order(gold.view());
  auto sorted_gold     = cudf::gather(gold.view(), *gold_sort_order);
  cudf::test::expect_tables_equal(*sorted_gold, *sorted_result);

  build_once_probe_parallel<join_kind::FULL>(
    t0, t1, {0, 1}, {0, 1}, {{0, 0}, {1, 1}}, *sorted_gold);
}

TEST_F(JoinTest, FullJoinWithNulls)
{
  column_wrapper<int32_t> col0_0{{3, 1, 2, 0, 3}};
  strcol_wrapper col0_1({"s0", "s1", "s2", "s4", "s1"});
  column_wrapper<int32_t> col0_2{{0, 1, 2, 4, 1}};

  column_wrapper<int32_t> col1_0{{2, 2, 0, 4, 3}, {1, 1, 1, 0, 1}};
  strcol_wrapper col1_1{{"s1", "s0", "s1", "s2", "s1"}};
  column_wrapper<int32_t> col1_2{{1, 0, 1, 2, 1}};

  CVector cols0, cols1;
  cols0.push_back(col0_0.release());
  cols0.push_back(col0_1.release());
  cols0.push_back(col0_2.release());
  cols1.push_back(col1_0.release());
  cols1.push_back(col1_1.release());
  cols1.push_back(col1_2.release());

  Table t0(std::move(cols0));
  Table t1(std::move(cols1));

  auto result            = cudf::full_join(t0, t1, {0, 1}, {0, 1}, {{0, 0}, {1, 1}});
  auto result_sort_order = cudf::sorted_order(result->view());
  auto sorted_result     = cudf::gather(result->view(), *result_sort_order);

  column_wrapper<int32_t> col_gold_0{{2, 2, 0, -1, 3, 3, 1, 2, 0}, {1, 1, 1, 0, 1, 1, 1, 1, 1}};
  strcol_wrapper col_gold_1({"s1", "s0", "s1", "s2", "s1", "s0", "s1", "s2", "s4"});
  column_wrapper<int32_t> col_gold_2{{-1, -1, -1, -1, 1, 0, 1, 2, 4}, {0, 0, 0, 0, 1, 1, 1, 1, 1}};
  column_wrapper<int32_t> col_gold_3{{1, 0, 1, 2, 1, -1, -1, -1, -1}, {1, 1, 1, 1, 1, 0, 0, 0, 0}};
  CVector cols_gold;
  cols_gold.push_back(col_gold_0.release());
  cols_gold.push_back(col_gold_1.release());
  cols_gold.push_back(col_gold_2.release());
  cols_gold.push_back(col_gold_3.release());
  Table gold(std::move(cols_gold));

  auto gold_sort_order = cudf::sorted_order(gold.view());
  auto sorted_gold     = cudf::gather(gold.view(), *gold_sort_order);
  cudf::test::expect_tables_equal(*sorted_gold, *sorted_result);

  build_once_probe_parallel<join_kind::FULL>(
    t0, t1, {0, 1}, {0, 1}, {{0, 0}, {1, 1}}, *sorted_gold);
}

TEST_F(JoinTest, LeftJoinNoNulls)
{
  column_wrapper<int32_t> col0_0{{3, 1, 2, 0, 3}};
  strcol_wrapper col0_1({"s0", "s1", "s2", "s4", "s1"});
  column_wrapper<int32_t> col0_2{{0, 1, 2, 4, 1}};

  column_wrapper<int32_t> col1_0{{2, 2, 0, 4, 3}};
  strcol_wrapper col1_1({"s1", "s0", "s1", "s2", "s1"});
  column_wrapper<int32_t> col1_2{{1, 0, 1, 2, 1}};

  CVector cols0, cols1;
  cols0.push_back(col0_0.release());
  cols0.push_back(col0_1.release());
  cols0.push_back(col0_2.release());
  cols1.push_back(col1_0.release());
  cols1.push_back(col1_1.release());
  cols1.push_back(col1_2.release());

  Table t0(std::move(cols0));
  Table t1(std::move(cols1));

  auto result            = cudf::left_join(t0, t1, {0, 1}, {0, 1}, {{0, 0}, {1, 1}});
  auto result_sort_order = cudf::sorted_order(result->view());
  auto sorted_result     = cudf::gather(result->view(), *result_sort_order);

  column_wrapper<int32_t> col_gold_0{{3, 3, 1, 2, 0}, {1, 1, 1, 1, 1}};
  strcol_wrapper col_gold_1({"s1", "s0", "s1", "s2", "s4"}, {1, 1, 1, 1, 1, 1});
  column_wrapper<int32_t> col_gold_2{{1, 0, 1, 2, 4}, {1, 1, 1, 1, 1}};
  column_wrapper<int32_t> col_gold_3{{1, -1, -1, -1, -1}, {1, 0, 0, 0, 0}};
  CVector cols_gold;
  cols_gold.push_back(col_gold_0.release());
  cols_gold.push_back(col_gold_1.release());
  cols_gold.push_back(col_gold_2.release());
  cols_gold.push_back(col_gold_3.release());
  Table gold(std::move(cols_gold));

  auto gold_sort_order = cudf::sorted_order(gold.view());
  auto sorted_gold     = cudf::gather(gold.view(), *gold_sort_order);
  cudf::test::expect_tables_equal(*sorted_gold, *sorted_result);

  build_once_probe_parallel<join_kind::LEFT>(
    t0, t1, {0, 1}, {0, 1}, {{0, 0}, {1, 1}}, *sorted_gold);
}

TEST_F(JoinTest, LeftJoinWithNulls)
{
  column_wrapper<int32_t> col0_0{{3, 1, 2, 0, 2}};
  strcol_wrapper col0_1({"s1", "s1", "s0", "s4", "s0"}, {1, 1, 0, 1, 1});
  column_wrapper<int32_t> col0_2{{0, 1, 2, 4, 1}};

  column_wrapper<int32_t> col1_0{{2, 2, 0, 4, 3}};
  strcol_wrapper col1_1({"s1", "s0", "s1", "s2", "s1"});
  column_wrapper<int32_t> col1_2{{1, 0, 1, 2, 1}, {1, 0, 1, 1, 1}};

  CVector cols0, cols1;
  cols0.push_back(col0_0.release());
  cols0.push_back(col0_1.release());
  cols0.push_back(col0_2.release());
  cols1.push_back(col1_0.release());
  cols1.push_back(col1_1.release());
  cols1.push_back(col1_2.release());

  Table t0(std::move(cols0));
  Table t1(std::move(cols1));

  auto result            = cudf::left_join(t0, t1, {0, 1}, {0, 1}, {{0, 0}, {1, 1}});
  auto result_sort_order = cudf::sorted_order(result->view());
  auto sorted_result     = cudf::gather(result->view(), *result_sort_order);

  column_wrapper<int32_t> col_gold_0{{3, 2, 1, 2, 0}, {1, 1, 1, 1, 1}};
  strcol_wrapper col_gold_1({"s1", "s0", "s1", "", "s4"}, {1, 1, 1, 0, 1});
  column_wrapper<int32_t> col_gold_2{{0, 1, 1, 2, 4}, {1, 1, 1, 1, 1}};
  column_wrapper<int32_t> col_gold_3{{1, -1, -1, -1, -1}, {1, 0, 0, 0, 0}};
  CVector cols_gold;
  cols_gold.push_back(col_gold_0.release());
  cols_gold.push_back(col_gold_1.release());
  cols_gold.push_back(col_gold_2.release());
  cols_gold.push_back(col_gold_3.release());
  Table gold(std::move(cols_gold));

  auto gold_sort_order = cudf::sorted_order(gold.view());
  auto sorted_gold     = cudf::gather(gold.view(), *gold_sort_order);
  cudf::test::expect_tables_equal(*sorted_gold, *sorted_result);

  build_once_probe_parallel<join_kind::LEFT>(
    t0, t1, {0, 1}, {0, 1}, {{0, 0}, {1, 1}}, *sorted_gold);
}

TEST_F(JoinTest, InnerJoinNoNulls)
{
  column_wrapper<int32_t> col0_0{{3, 1, 2, 0, 2}};
  strcol_wrapper col0_1({"s1", "s1", "s0", "s4", "s0"});
  column_wrapper<int32_t> col0_2{{0, 1, 2, 4, 1}};

  column_wrapper<int32_t> col1_0{{2, 2, 0, 4, 3}};
  strcol_wrapper col1_1({"s1", "s0", "s1", "s2", "s1"});
  column_wrapper<int32_t> col1_2{{1, 0, 1, 2, 1}};

  CVector cols0, cols1;
  cols0.push_back(col0_0.release());
  cols0.push_back(col0_1.release());
  cols0.push_back(col0_2.release());
  cols1.push_back(col1_0.release());
  cols1.push_back(col1_1.release());
  cols1.push_back(col1_2.release());

  Table t0(std::move(cols0));
  Table t1(std::move(cols1));

  auto result            = cudf::inner_join(t0, t1, {0, 1}, {0, 1}, {{0, 0}, {1, 1}});
  auto result_sort_order = cudf::sorted_order(result->view());
  auto sorted_result     = cudf::gather(result->view(), *result_sort_order);

  column_wrapper<int32_t> col_gold_0{{3, 2, 2}};
  strcol_wrapper col_gold_1({"s1", "s0", "s0"});
  column_wrapper<int32_t> col_gold_2{{0, 2, 1}};
  column_wrapper<int32_t> col_gold_3{{1, 0, 0}};
  CVector cols_gold;
  cols_gold.push_back(col_gold_0.release());
  cols_gold.push_back(col_gold_1.release());
  cols_gold.push_back(col_gold_2.release());
  cols_gold.push_back(col_gold_3.release());
  Table gold(std::move(cols_gold));

  auto gold_sort_order = cudf::sorted_order(gold.view());
  auto sorted_gold     = cudf::gather(gold.view(), *gold_sort_order);
  cudf::test::expect_tables_equal(*sorted_gold, *sorted_result);

  build_once_probe_parallel<join_kind::INNER>(
    t0, t1, {0, 1}, {0, 1}, {{0, 0}, {1, 1}}, *sorted_gold);
  build_once_probe_parallel<join_kind::INNER, true, ProbeOutputSide::RIGHT>(
    t1, t0, {0, 1}, {0, 1}, {{0, 0}, {1, 1}}, *sorted_gold);
}

TEST_F(JoinTest, InnerJoinWithNulls)
{
  column_wrapper<int32_t> col0_0{{3, 1, 2, 0, 2}};
  strcol_wrapper col0_1({"s1", "s1", "s0", "s4", "s0"}, {1, 1, 0, 1, 1});
  column_wrapper<int32_t> col0_2{{0, 1, 2, 4, 1}};

  column_wrapper<int32_t> col1_0{{2, 2, 0, 4, 3}};
  strcol_wrapper col1_1({"s1", "s0", "s1", "s2", "s1"});
  column_wrapper<int32_t> col1_2{{1, 0, 1, 2, 1}, {1, 0, 1, 1, 1}};

  CVector cols0, cols1;
  cols0.push_back(col0_0.release());
  cols0.push_back(col0_1.release());
  cols0.push_back(col0_2.release());
  cols1.push_back(col1_0.release());
  cols1.push_back(col1_1.release());
  cols1.push_back(col1_2.release());

  Table t0(std::move(cols0));
  Table t1(std::move(cols1));

  auto result            = cudf::inner_join(t0, t1, {0, 1}, {0, 1}, {{0, 0}, {1, 1}});
  auto result_sort_order = cudf::sorted_order(result->view());
  auto sorted_result     = cudf::gather(result->view(), *result_sort_order);

  column_wrapper<int32_t> col_gold_0{{3, 2}};
  strcol_wrapper col_gold_1({"s1", "s0"}, {1, 1});
  column_wrapper<int32_t> col_gold_2{{0, 1}};
  column_wrapper<int32_t> col_gold_3{{1, -1}, {1, 0}};
  CVector cols_gold;
  cols_gold.push_back(col_gold_0.release());
  cols_gold.push_back(col_gold_1.release());
  cols_gold.push_back(col_gold_2.release());
  cols_gold.push_back(col_gold_3.release());
  Table gold(std::move(cols_gold));

  auto gold_sort_order = cudf::sorted_order(gold.view());
  auto sorted_gold     = cudf::gather(gold.view(), *gold_sort_order);
  cudf::test::expect_tables_equal(*sorted_gold, *sorted_result);

  build_once_probe_parallel<join_kind::INNER>(
    t0, t1, {0, 1}, {0, 1}, {{0, 0}, {1, 1}}, *sorted_gold);
  build_once_probe_parallel<join_kind::INNER, true, ProbeOutputSide::RIGHT>(
    t1, t0, {0, 1}, {0, 1}, {{0, 0}, {1, 1}}, *sorted_gold);
}

// Empty Left Table
TEST_F(JoinTest, EmptyLeftTableInnerJoin)
{
  column_wrapper<int32_t> col0_0;
  column_wrapper<int32_t> col0_1;

  column_wrapper<int32_t> col1_0{{2, 2, 0, 4, 3}};
  column_wrapper<int32_t> col1_1{{1, 0, 1, 2, 1}, {1, 0, 1, 1, 1}};

  CVector cols0, cols1;
  cols0.push_back(col0_0.release());
  cols0.push_back(col0_1.release());
  cols1.push_back(col1_0.release());
  cols1.push_back(col1_1.release());

  Table empty0(std::move(cols0));
  Table t1(std::move(cols1));

  auto result = cudf::inner_join(empty0, t1, {0, 1}, {0, 1}, {{0, 0}, {1, 1}});
  cudf::test::expect_tables_equal(empty0, *result);

  build_once_probe_parallel<join_kind::INNER, false>(
    empty0, t1, {0, 1}, {0, 1}, {{0, 0}, {1, 1}}, empty0);
  build_once_probe_parallel<join_kind::INNER, false, ProbeOutputSide::RIGHT>(
    t1, empty0, {0, 1}, {0, 1}, {{0, 0}, {1, 1}}, empty0);
}

TEST_F(JoinTest, EmptyLeftTableLeftJoin)
{
  column_wrapper<int32_t> col0_0;
  column_wrapper<int32_t> col0_1;

  column_wrapper<int32_t> col1_0{{2, 2, 0, 4, 3}};
  column_wrapper<int32_t> col1_1{{1, 0, 1, 2, 1}, {1, 0, 1, 1, 1}};

  CVector cols0, cols1;
  cols0.push_back(col0_0.release());
  cols0.push_back(col0_1.release());
  cols1.push_back(col1_0.release());
  cols1.push_back(col1_1.release());

  Table empty0(std::move(cols0));
  Table t1(std::move(cols1));

  auto result = cudf::left_join(empty0, t1, {0, 1}, {0, 1}, {{0, 0}, {1, 1}});
  cudf::test::expect_tables_equal(empty0, *result);

  build_once_probe_parallel<join_kind::LEFT, false>(
    empty0, t1, {0, 1}, {0, 1}, {{0, 0}, {1, 1}}, empty0);
}

TEST_F(JoinTest, EmptyLeftTableFullJoin)
{
  column_wrapper<int32_t> col0_0;
  column_wrapper<int32_t> col0_1;

  column_wrapper<int32_t> col1_0{{2, 2, 0, 4, 3}};
  column_wrapper<int32_t> col1_1{{1, 0, 1, 2, 1}, {1, 0, 1, 1, 1}};

  CVector cols0, cols1;
  cols0.push_back(col0_0.release());
  cols0.push_back(col0_1.release());
  cols1.push_back(col1_0.release());
  cols1.push_back(col1_1.release());

  Table empty0(std::move(cols0));
  Table t1(std::move(cols1));

  auto result = cudf::full_join(empty0, t1, {0, 1}, {0, 1}, {{0, 0}, {1, 1}});
  cudf::test::expect_tables_equal(t1, *result);

  build_once_probe_parallel<join_kind::FULL, false>(
    empty0, t1, {0, 1}, {0, 1}, {{0, 0}, {1, 1}}, t1);
}

// Empty Right Table
TEST_F(JoinTest, EmptyRightTableInnerJoin)
{
  column_wrapper<int32_t> col0_0{{2, 2, 0, 4, 3}};
  column_wrapper<int32_t> col0_1{{1, 0, 1, 2, 1}, {1, 0, 1, 1, 1}};

  column_wrapper<int32_t> col1_0;
  column_wrapper<int32_t> col1_1;

  CVector cols0, cols1;
  cols0.push_back(col0_0.release());
  cols0.push_back(col0_1.release());
  cols1.push_back(col1_0.release());
  cols1.push_back(col1_1.release());

  Table t0(std::move(cols0));
  Table empty1(std::move(cols1));

  auto result = cudf::inner_join(t0, empty1, {0, 1}, {0, 1}, {{0, 0}, {1, 1}});
  cudf::test::expect_tables_equal(empty1, *result);

  build_once_probe_parallel<join_kind::INNER, false>(
    t0, empty1, {0, 1}, {0, 1}, {{0, 0}, {1, 1}}, empty1);
  build_once_probe_parallel<join_kind::INNER, false, ProbeOutputSide::RIGHT>(
    empty1, t0, {0, 1}, {0, 1}, {{0, 0}, {1, 1}}, empty1);
}

TEST_F(JoinTest, EmptyRightTableLeftJoin)
{
  column_wrapper<int32_t> col0_0{{2, 2, 0, 4, 3}, {1, 1, 1, 1, 1}};
  column_wrapper<int32_t> col0_1{{1, 0, 1, 2, 1}, {1, 0, 1, 1, 1}};

  column_wrapper<int32_t> col1_0;
  column_wrapper<int32_t> col1_1;

  CVector cols0, cols1;
  cols0.push_back(col0_0.release());
  cols0.push_back(col0_1.release());
  cols1.push_back(col1_0.release());
  cols1.push_back(col1_1.release());

  Table t0(std::move(cols0));
  Table empty1(std::move(cols1));

  auto result = cudf::left_join(t0, empty1, {0, 1}, {0, 1}, {{0, 0}, {1, 1}});
  cudf::test::expect_tables_equal(t0, *result);

  build_once_probe_parallel<join_kind::LEFT, false>(
    t0, empty1, {0, 1}, {0, 1}, {{0, 0}, {1, 1}}, t0);
}

TEST_F(JoinTest, EmptyRightTableFullJoin)
{
  column_wrapper<int32_t> col0_0{{2, 2, 0, 4, 3}};
  column_wrapper<int32_t> col0_1{{1, 0, 1, 2, 1}, {1, 0, 1, 1, 1}};

  column_wrapper<int32_t> col1_0;
  column_wrapper<int32_t> col1_1;

  CVector cols0, cols1;
  cols0.push_back(col0_0.release());
  cols0.push_back(col0_1.release());
  cols1.push_back(col1_0.release());
  cols1.push_back(col1_1.release());

  Table t0(std::move(cols0));
  Table empty1(std::move(cols1));

  auto result = cudf::full_join(t0, empty1, {0, 1}, {0, 1}, {{0, 0}, {1, 1}});
  cudf::test::expect_tables_equal(t0, *result);

  build_once_probe_parallel<join_kind::FULL, false>(
    t0, empty1, {0, 1}, {0, 1}, {{0, 0}, {1, 1}}, t0);
}

// Both tables empty
TEST_F(JoinTest, BothEmptyInnerJoin)
{
  column_wrapper<int32_t> col0_0;
  column_wrapper<int32_t> col0_1;

  column_wrapper<int32_t> col1_0;
  column_wrapper<int32_t> col1_1;

  CVector cols0, cols1;
  cols0.push_back(col0_0.release());
  cols0.push_back(col0_1.release());
  cols1.push_back(col1_0.release());
  cols1.push_back(col1_1.release());

  Table t0(std::move(cols0));
  Table empty1(std::move(cols1));

  auto result = cudf::inner_join(t0, empty1, {0, 1}, {0, 1}, {{0, 0}, {1, 1}});
  cudf::test::expect_tables_equal(empty1, *result);

  build_once_probe_parallel<join_kind::INNER, false>(
    t0, empty1, {0, 1}, {0, 1}, {{0, 0}, {1, 1}}, empty1);
  build_once_probe_parallel<join_kind::INNER, false, ProbeOutputSide::RIGHT>(
    empty1, t0, {0, 1}, {0, 1}, {{0, 0}, {1, 1}}, empty1);
}

TEST_F(JoinTest, BothEmptyLeftJoin)
{
  column_wrapper<int32_t> col0_0;
  column_wrapper<int32_t> col0_1;

  column_wrapper<int32_t> col1_0;
  column_wrapper<int32_t> col1_1;

  CVector cols0, cols1;
  cols0.push_back(col0_0.release());
  cols0.push_back(col0_1.release());
  cols1.push_back(col1_0.release());
  cols1.push_back(col1_1.release());

  Table t0(std::move(cols0));
  Table empty1(std::move(cols1));

  auto result = cudf::left_join(t0, empty1, {0, 1}, {0, 1}, {{0, 0}, {1, 1}});
  cudf::test::expect_tables_equal(empty1, *result);

  build_once_probe_parallel<join_kind::LEFT, false>(
    t0, empty1, {0, 1}, {0, 1}, {{0, 0}, {1, 1}}, empty1);
}

TEST_F(JoinTest, BothEmptyFullJoin)
{
  column_wrapper<int32_t> col0_0;
  column_wrapper<int32_t> col0_1;

  column_wrapper<int32_t> col1_0;
  column_wrapper<int32_t> col1_1;

  CVector cols0, cols1;
  cols0.push_back(col0_0.release());
  cols0.push_back(col0_1.release());
  cols1.push_back(col1_0.release());
  cols1.push_back(col1_1.release());

  Table t0(std::move(cols0));
  Table empty1(std::move(cols1));

  auto result = cudf::full_join(t0, empty1, {0, 1}, {0, 1}, {{0, 0}, {1, 1}});
  cudf::test::expect_tables_equal(empty1, *result);

  build_once_probe_parallel<join_kind::FULL, false>(
    t0, empty1, {0, 1}, {0, 1}, {{0, 0}, {1, 1}}, empty1);
}

// EqualValues X Inner,Left,Full

TEST_F(JoinTest, EqualValuesInnerJoin)
{
  column_wrapper<int32_t> col0_0{{0, 0}};
  strcol_wrapper col0_1({"s0", "s0"});

  column_wrapper<int32_t> col1_0{{0, 0}};
  strcol_wrapper col1_1({"s0", "s0"});

  CVector cols0, cols1;
  cols0.push_back(col0_0.release());
  cols0.push_back(col0_1.release());
  cols1.push_back(col1_0.release());
  cols1.push_back(col1_1.release());

  Table t0(std::move(cols0));
  Table t1(std::move(cols1));

  auto result = cudf::inner_join(t0, t1, {0, 1}, {0, 1}, {{0, 0}, {1, 1}});

  column_wrapper<int32_t> col_gold_0{{0, 0, 0, 0}};
  strcol_wrapper col_gold_1({"s0", "s0", "s0", "s0"});
  CVector cols_gold;
  cols_gold.push_back(col_gold_0.release());
  cols_gold.push_back(col_gold_1.release());
  Table gold(std::move(cols_gold));

  cudf::test::expect_tables_equal(gold, *result);

  build_once_probe_parallel<join_kind::INNER, false>(
    t0, t1, {0, 1}, {0, 1}, {{0, 0}, {1, 1}}, gold);
  build_once_probe_parallel<join_kind::INNER, false, ProbeOutputSide::RIGHT>(
    t1, t0, {0, 1}, {0, 1}, {{0, 0}, {1, 1}}, gold);
}

TEST_F(JoinTest, EqualValuesLeftJoin)
{
  column_wrapper<int32_t> col0_0{{0, 0}};
  strcol_wrapper col0_1({"s0", "s0"});

  column_wrapper<int32_t> col1_0{{0, 0}};
  strcol_wrapper col1_1({"s0", "s0"});

  CVector cols0, cols1;
  cols0.push_back(col0_0.release());
  cols0.push_back(col0_1.release());
  cols1.push_back(col1_0.release());
  cols1.push_back(col1_1.release());

  Table t0(std::move(cols0));
  Table t1(std::move(cols1));

  auto result = cudf::left_join(t0, t1, {0, 1}, {0, 1}, {{0, 0}, {1, 1}});

  column_wrapper<int32_t> col_gold_0{{0, 0, 0, 0}, {1, 1, 1, 1}};
  strcol_wrapper col_gold_1({"s0", "s0", "s0", "s0"}, {1, 1, 1, 1});
  CVector cols_gold;
  cols_gold.push_back(col_gold_0.release());
  cols_gold.push_back(col_gold_1.release());
  Table gold(std::move(cols_gold));

  cudf::test::expect_tables_equal(gold, *result);

  build_once_probe_parallel<join_kind::LEFT, false>(t0, t1, {0, 1}, {0, 1}, {{0, 0}, {1, 1}}, gold);
}

TEST_F(JoinTest, EqualValuesFullJoin)
{
  column_wrapper<int32_t> col0_0{{0, 0}};
  strcol_wrapper col0_1({"s0", "s0"});

  column_wrapper<int32_t> col1_0{{0, 0}};
  strcol_wrapper col1_1({"s0", "s0"});

  CVector cols0, cols1;
  cols0.push_back(col0_0.release());
  cols0.push_back(col0_1.release());
  cols1.push_back(col1_0.release());
  cols1.push_back(col1_1.release());

  Table t0(std::move(cols0));
  Table t1(std::move(cols1));

  auto result = cudf::full_join(t0, t1, {0, 1}, {0, 1}, {{0, 0}, {1, 1}});

  column_wrapper<int32_t> col_gold_0{{0, 0, 0, 0}};
  strcol_wrapper col_gold_1({"s0", "s0", "s0", "s0"});
  CVector cols_gold;
  cols_gold.push_back(col_gold_0.release());
  cols_gold.push_back(col_gold_1.release());
  Table gold(std::move(cols_gold));

  cudf::test::expect_tables_equal(gold, *result);

  build_once_probe_parallel<join_kind::FULL, false>(t0, t1, {0, 1}, {0, 1}, {{0, 0}, {1, 1}}, gold);
}

TEST_F(JoinTest, InnerJoinCornerCase)
{
  column_wrapper<int64_t> col0_0{{4, 1, 3, 2, 2, 2, 2}};
  column_wrapper<int64_t> col1_0{{2}};

  CVector cols0, cols1;
  cols0.push_back(col0_0.release());
  cols1.push_back(col1_0.release());

  Table t0(std::move(cols0));
  Table t1(std::move(cols1));

  auto result            = cudf::inner_join(t0, t1, {0}, {0}, {{0, 0}});
  auto result_sort_order = cudf::sorted_order(result->view());
  auto sorted_result     = cudf::gather(result->view(), *result_sort_order);

  column_wrapper<int64_t> col_gold_0{{2, 2, 2, 2}};
  CVector cols_gold;
  cols_gold.push_back(col_gold_0.release());
  Table gold(std::move(cols_gold));

  auto gold_sort_order = cudf::sorted_order(gold.view());
  auto sorted_gold     = cudf::gather(gold.view(), *gold_sort_order);
  cudf::test::expect_tables_equal(*sorted_gold, *sorted_result);

  build_once_probe_parallel<join_kind::INNER>(t0, t1, {0}, {0}, {{0, 0}}, *sorted_gold);
  build_once_probe_parallel<join_kind::INNER, true, ProbeOutputSide::RIGHT>(
    t1, t0, {0}, {0}, {{0, 0}}, *sorted_gold);
}

CUDF_TEST_PROGRAM_MAIN()
