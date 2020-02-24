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

#include <tests/groupby/common/groupby_test_util.hpp>

#include <tests/utilities/base_fixture.hpp>
#include <tests/utilities/column_wrapper.hpp>
#include <tests/utilities/type_lists.hpp>

#include <cudf/types.hpp>

namespace cudf {
namespace test {

template <typename V>
struct groupby_group_keys_test : public cudf::test::BaseFixture {};

using KeyTypes = cudf::test::Types<int8_t, int16_t, int32_t, int64_t, float, double>;

TYPED_TEST_CASE(groupby_group_keys_test, KeyTypes);

TYPED_TEST(groupby_group_keys_test, basic)
{
  using K = TypeParam;

  fixed_width_column_wrapper<K> keys {1, 1, 2, 1, 2, 3};
  fixed_width_column_wrapper<K> expect_group_keys {1, 1, 1, 2, 2, 3};
  std::vector<size_type> expect_group_offsets = {0, 3, 5, 6};
  test_grouping_keys(keys, expect_group_keys, expect_group_offsets);
}

TYPED_TEST(groupby_group_keys_test, empty_keys)
{
  using K = TypeParam;

  fixed_width_column_wrapper<K> keys {};
  fixed_width_column_wrapper<K> expect_group_keys {};
  std::vector<size_type> expect_group_offsets = {0};
  test_grouping_keys(keys, expect_group_keys, expect_group_offsets);
}


TYPED_TEST(groupby_group_keys_test, all_null_keys)
{
  using K = TypeParam;

  fixed_width_column_wrapper<K> keys ({1, 1, 2, 3, 1, 2}, all_null() );
  fixed_width_column_wrapper<K> expect_group_keys {};
  std::vector<size_type> expect_group_offsets = {0};
  test_grouping_keys(keys, expect_group_keys, expect_group_offsets);
}

} //namespace test
} //namespace cudf
