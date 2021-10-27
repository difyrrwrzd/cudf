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

#include <tests/groupby/groupby_test_util.hpp>

#include <cudf_test/base_fixture.hpp>
#include <cudf_test/column_wrapper.hpp>
#include <cudf_test/type_lists.hpp>

#include <cudf/detail/aggregation/aggregation.hpp>

namespace cudf {
namespace test {

template <typename V>
struct groupby_collect_list_test : public cudf::test::BaseFixture {
};

using FixedWidthTypesNotBool = cudf::test::Concat<cudf::test::IntegralTypesNotBool,
                                                  cudf::test::FloatingPointTypes,
                                                  cudf::test::TimestampTypes>;
TYPED_TEST_CASE(groupby_collect_list_test, FixedWidthTypesNotBool);

TYPED_TEST(groupby_collect_list_test, CollectWithoutNulls)
{
  using K = int32_t;
  using V = TypeParam;

  fixed_width_column_wrapper<K, int32_t> keys{1, 1, 1, 2, 2, 2};
  fixed_width_column_wrapper<V, int32_t> values{1, 2, 3, 4, 5, 6};

  fixed_width_column_wrapper<K, int32_t> expect_keys{1, 2};
  lists_column_wrapper<V, int32_t> expect_vals{{1, 2, 3}, {4, 5, 6}};

  auto agg = cudf::make_collect_list_aggregation<groupby_aggregation>();
  test_single_agg(keys, values, expect_keys, expect_vals, std::move(agg));
}

TYPED_TEST(groupby_collect_list_test, CollectWithNulls)
{
  using K = int32_t;
  using V = TypeParam;

  fixed_width_column_wrapper<K, int32_t> keys{1, 1, 2, 2, 3, 3};
  fixed_width_column_wrapper<V, int32_t> values{{1, 2, 3, 4, 5, 6},
                                                {true, false, true, false, true, false}};

  fixed_width_column_wrapper<K, int32_t> expect_keys{1, 2, 3};

  std::vector<int32_t> validity({true, false});
  lists_column_wrapper<V, int32_t> expect_vals{
    {{1, 2}, validity.begin()}, {{3, 4}, validity.begin()}, {{5, 6}, validity.begin()}};

  auto agg = cudf::make_collect_list_aggregation<groupby_aggregation>();
  test_single_agg(keys, values, expect_keys, expect_vals, std::move(agg));
}

TYPED_TEST(groupby_collect_list_test, CollectWithNullExclusion)
{
  using K = int32_t;
  using V = TypeParam;

  fixed_width_column_wrapper<K, int32_t> keys{1, 1, 1, 2, 2, 3, 3, 4, 4};

  fixed_width_column_wrapper<V, int32_t> values{
    {1, 2, 3, 4, 5, 6, 7, 8, 9}, {false, true, false, true, false, false, false, true, true}};

  fixed_width_column_wrapper<K, int32_t> expect_keys{1, 2, 3, 4};

  lists_column_wrapper<V, int32_t> expect_vals{{2}, {4}, {}, {8, 9}};

  auto agg = cudf::make_collect_list_aggregation<groupby_aggregation>(null_policy::EXCLUDE);
  test_single_agg(keys, values, expect_keys, expect_vals, std::move(agg));
}

TYPED_TEST(groupby_collect_list_test, CollectOnEmptyInput)
{
  using K = int32_t;
  using V = TypeParam;

  fixed_width_column_wrapper<K, int32_t> keys{};
  fixed_width_column_wrapper<V, int32_t> values{};

  fixed_width_column_wrapper<K, int32_t> expect_keys{};
  lists_column_wrapper<V, int32_t> expect_vals{};

  auto agg = cudf::make_collect_list_aggregation<groupby_aggregation>(null_policy::EXCLUDE);
  test_single_agg(keys, values, expect_keys, expect_vals, std::move(agg));
}

TYPED_TEST(groupby_collect_list_test, CollectLists)
{
  using K = int32_t;
  using V = TypeParam;

  using LCW = cudf::test::lists_column_wrapper<TypeParam, int32_t>;

  fixed_width_column_wrapper<K, int32_t> keys{1, 1, 2, 2, 3, 3};
  lists_column_wrapper<V, int32_t> values{{1, 2}, {3, 4}, {5, 6, 7}, LCW{}, {9, 10}, {11}};

  fixed_width_column_wrapper<K, int32_t> expect_keys{1, 2, 3};

  lists_column_wrapper<V, int32_t> expect_vals{
    {{1, 2}, {3, 4}}, {{5, 6, 7}, LCW{}}, {{9, 10}, {11}}};

  auto agg = cudf::make_collect_list_aggregation<groupby_aggregation>();
  test_single_agg(keys, values, expect_keys, expect_vals, std::move(agg));
}

TYPED_TEST(groupby_collect_list_test, CollectListsWithNullExclusion)
{
  using K = int32_t;
  using V = TypeParam;

  using LCW = cudf::test::lists_column_wrapper<V, int32_t>;

  fixed_width_column_wrapper<K, int32_t> keys{1, 1, 2, 2, 3, 3, 4, 4};
  const bool validity_mask[] = {true, false, false, true, true, true, false, false};
  LCW values{{{1, 2}, {3, 4}, {5, 6, 7}, LCW{}, {9, 10}, {11}, {20, 30, 40}, LCW{}}, validity_mask};

  fixed_width_column_wrapper<K, int32_t> expect_keys{1, 2, 3, 4};

  LCW expect_vals{{{1, 2}}, {LCW{}}, {{9, 10}, {11}}, {}};

  auto agg = cudf::make_collect_list_aggregation<groupby_aggregation>(null_policy::EXCLUDE);
  test_single_agg(keys, values, expect_keys, expect_vals, std::move(agg));
}

TYPED_TEST(groupby_collect_list_test, CollectOnEmptyInputLists)
{
  using K = int32_t;
  using V = TypeParam;

  using LCW = cudf::test::lists_column_wrapper<V, int32_t>;

  auto offsets = data_type{type_to_id<offset_type>()};

  fixed_width_column_wrapper<K, int32_t> keys{};
  auto values = cudf::make_lists_column(0, make_empty_column(offsets), LCW{}.release(), 0, {});

  fixed_width_column_wrapper<K, int32_t> expect_keys{};

  auto expect_child =
    cudf::make_lists_column(0, make_empty_column(offsets), LCW{}.release(), 0, {});
  auto expect_values =
    cudf::make_lists_column(0, make_empty_column(offsets), std::move(expect_child), 0, {});

  auto agg = cudf::make_collect_list_aggregation<groupby_aggregation>();
  test_single_agg(keys, values->view(), expect_keys, expect_values->view(), std::move(agg));
}

TYPED_TEST(groupby_collect_list_test, CollectOnEmptyInputListsOfStructs)
{
  using K = int32_t;
  using V = TypeParam;

  using LCW = cudf::test::lists_column_wrapper<V, int32_t>;

  fixed_width_column_wrapper<K, int32_t> keys{};
  auto struct_child  = LCW{};
  auto struct_column = structs_column_wrapper{{struct_child}};

  auto values = cudf::make_lists_column(
    0, make_empty_column(type_to_id<offset_type>()), struct_column.release(), 0, {});

  fixed_width_column_wrapper<K, int32_t> expect_keys{};

  auto expect_struct_child  = LCW{};
  auto expect_struct_column = structs_column_wrapper{{expect_struct_child}};

  auto expect_child = cudf::make_lists_column(
    0, make_empty_column(type_to_id<offset_type>()), expect_struct_column.release(), 0, {});
  auto expect_values = cudf::make_lists_column(
    0, make_empty_column(type_to_id<offset_type>()), std::move(expect_child), 0, {});

  auto agg = cudf::make_collect_list_aggregation<groupby_aggregation>();
  test_single_agg(keys, values->view(), expect_keys, expect_values->view(), std::move(agg));
}

TYPED_TEST(groupby_collect_list_test, dictionary)
{
  using K = int32_t;
  using V = TypeParam;

  fixed_width_column_wrapper<K, int32_t> keys{1, 1, 1, 2, 2, 2};
  dictionary_column_wrapper<V, int32_t> vals{1, 2, 3, 4, 5, 6};

  fixed_width_column_wrapper<K, int32_t> expect_keys{1, 2};
  lists_column_wrapper<V, int32_t> expect_vals_w{{1, 2, 3}, {4, 5, 6}};

  fixed_width_column_wrapper<int32_t> offsets({0, 3, 6});
  auto expect_vals = cudf::make_lists_column(cudf::column_view(offsets).size() - 1,
                                             std::make_unique<cudf::column>(offsets),
                                             std::make_unique<cudf::column>(vals),
                                             0,
                                             rmm::device_buffer{});

  test_single_agg(keys,
                  vals,
                  expect_keys,
                  expect_vals->view(),
                  cudf::make_collect_list_aggregation<groupby_aggregation>());
}

}  // namespace test
}  // namespace cudf
