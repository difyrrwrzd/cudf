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

#include <cudf/lists/lists_column_view.hpp>

#include <tests/utilities/base_fixture.hpp>
#include <tests/utilities/column_utilities.hpp>
#include <tests/utilities/column_wrapper.hpp>
#include <tests/utilities/cudf_gtest.hpp>
#include <tests/utilities/type_lists.hpp>

struct ListColumnWrapperTest : public cudf::test::BaseFixture {
};
template <typename T>
struct ListColumnWrapperTestTyped : public cudf::test::BaseFixture {
  ListColumnWrapperTestTyped() {}

  auto data_type() { return cudf::data_type{cudf::experimental::type_to_id<T>()}; }
};

using FixedWidthTypesNoBool = cudf::test::
  Concat<cudf::test::IntegralTypes, cudf::test::FloatingPointTypes, cudf::test::TimestampTypes>;
TYPED_TEST_CASE(ListColumnWrapperTestTyped, FixedWidthTypesNoBool);

TEST_F(ListColumnWrapperTest, ListOfInts)
{
  using namespace cudf;

  // List<int>, 1 row
  //
  // List<int32_t>:
  // Length : 1
  // Offsets : 0, 2
  // Children :
  //    2, 3
  //
  {
    test::lists_column_wrapper list{2, 3};

    lists_column_view lcv(list);
    EXPECT_EQ(lcv.size(), 1);

    auto offsets = lcv.offsets();
    EXPECT_EQ(offsets.size(), 2);
    test::fixed_width_column_wrapper<size_type> e_offsets({0, 2});
    test::expect_columns_equal(e_offsets, offsets);

    auto data = lcv.child();
    EXPECT_EQ(data.size(), 2);
    test::fixed_width_column_wrapper<int> e_data({2, 3});
    test::expect_columns_equal(e_data, data);
  }

  // List<int>, 1 row
  //
  // List<int32_t>:
  // Length : 1
  // Offsets : 0, 2
  // Children :
  //    2, 3
  //
  {
    test::lists_column_wrapper list{{2, 3}};

    lists_column_view lcv(list);
    EXPECT_EQ(lcv.size(), 1);

    auto offsets = lcv.offsets();
    EXPECT_EQ(offsets.size(), 2);
    test::fixed_width_column_wrapper<size_type> e_offsets({0, 2});
    test::expect_columns_equal(e_offsets, offsets);

    auto data = lcv.child();
    EXPECT_EQ(data.size(), 2);
    test::fixed_width_column_wrapper<int> e_data({2, 3});
    test::expect_columns_equal(e_data, data);
  }
}

TEST_F(ListColumnWrapperTest, ListOfIntsWithValidity)
{
  using namespace cudf;

  auto valids = cudf::test::make_counting_transform_iterator(
    0, [](auto i) { return i % 2 == 0 ? true : false; });

  // List<int>, 1 row
  //
  // List<int32_t>:
  // Length : 1
  // Offsets : 0, 2
  // Children :
  //    2, NULL
  //
  {
    test::lists_column_wrapper list{{{2, 3}, valids}};

    lists_column_view lcv(list);
    EXPECT_EQ(lcv.size(), 1);

    auto offsets = lcv.offsets();
    EXPECT_EQ(offsets.size(), 2);
    test::fixed_width_column_wrapper<size_type> e_offsets({0, 2});
    test::expect_columns_equal(e_offsets, offsets);

    auto data = lcv.child();
    EXPECT_EQ(data.size(), 2);
    test::fixed_width_column_wrapper<int> e_data({2, 3}, valids);
    test::expect_columns_equal(e_data, data);
  }

  // List<int>, 3 rows
  //
  // List<int32_t>:
  // Length : 3
  // Offsets : 0, 2, 4, 7
  // Children :
  //    2, NULL, 4, NULL, 6, NULL, 8
  {
    test::lists_column_wrapper list{{{2, 3}, valids}, {{4, 5}, valids}, {{6, 7, 8}, valids}};

    lists_column_view lcv(list);
    EXPECT_EQ(lcv.size(), 3);

    auto offsets = lcv.offsets();
    EXPECT_EQ(offsets.size(), 4);
    test::fixed_width_column_wrapper<size_type> e_offsets({0, 2, 4, 7});
    test::expect_columns_equal(e_offsets, offsets);

    auto data = lcv.child();
    EXPECT_EQ(data.size(), 7);
    test::fixed_width_column_wrapper<int> e_data({2, 3, 4, 5, 6, 7, 8}, valids);
    test::expect_columns_equal(e_data, data);
  }
}

TEST_F(ListColumnWrapperTest, ListOfIntsFromIterator)
{
  using namespace cudf;

  // List<int>, 1 row
  //
  // List<int32_t>:
  // Length : 1
  // Offsets : 0, 5
  // Children :
  //    0, 1, 2, 3, 4
  //
  auto sequence =
    cudf::test::make_counting_transform_iterator(0, [](auto i) { return static_cast<int>(i); });

  test::lists_column_wrapper list{sequence, sequence + 5};

  lists_column_view lcv(list);
  EXPECT_EQ(lcv.size(), 1);

  auto offsets = lcv.offsets();
  EXPECT_EQ(offsets.size(), 2);
  test::fixed_width_column_wrapper<size_type> e_offsets({0, 5});
  test::expect_columns_equal(e_offsets, offsets);

  auto data = lcv.child();
  EXPECT_EQ(data.size(), 5);
  test::fixed_width_column_wrapper<int> e_data({0, 1, 2, 3, 4});
  test::expect_columns_equal(e_data, data);
}

TEST_F(ListColumnWrapperTest, ListOfIntsFromIteratorWithValidity)
{
  using namespace cudf;

  auto valids = cudf::test::make_counting_transform_iterator(
    0, [](auto i) { return i % 2 == 0 ? true : false; });

  // List<int>, 1 row
  //
  // List<int32_t>:
  // Length : 1
  // Offsets : 0, 5
  // Children :
  //    0, NULL, 2, NULL, 4
  //
  auto sequence =
    cudf::test::make_counting_transform_iterator(0, [](auto i) { return static_cast<int>(i); });

  test::lists_column_wrapper list{sequence, sequence + 5, valids};

  lists_column_view lcv(list);
  EXPECT_EQ(lcv.size(), 1);

  auto offsets = lcv.offsets();
  EXPECT_EQ(offsets.size(), 2);
  test::fixed_width_column_wrapper<size_type> e_offsets({0, 5});
  test::expect_columns_equal(e_offsets, offsets);

  auto data = lcv.child();
  EXPECT_EQ(data.size(), 5);
  test::fixed_width_column_wrapper<int> e_data({0, 0, 2, 0, 4}, valids);
  test::expect_columns_equal(e_data, data);
}

TEST_F(ListColumnWrapperTest, ListOfListOfInts)
{
  using namespace cudf;

  // List<List<int>>, 1 row
  //
  // List<List<int32_t>>:
  // Length : 1
  // Offsets : 0, 2
  // Children :
  //    List<int32_t>:
  //    Length : 2
  //    Offsets : 0, 2, 4
  //    Children :
  //      2, 3, 4, 5
  {
    test::lists_column_wrapper list{{{2, 3}, {4, 5}}};

    lists_column_view lcv(list);
    EXPECT_EQ(lcv.size(), 1);

    auto offsets = lcv.offsets();
    EXPECT_EQ(offsets.size(), 2);
    test::fixed_width_column_wrapper<size_type> e_offsets({0, 2});
    test::expect_columns_equal(e_offsets, offsets);

    auto child = lcv.child();
    lists_column_view childv(child);
    EXPECT_EQ(childv.size(), 2);

    auto child_offsets = childv.offsets();
    EXPECT_EQ(child_offsets.size(), 3);
    test::fixed_width_column_wrapper<size_type> e_child_offsets({0, 2, 4});
    test::expect_columns_equal(e_child_offsets, child_offsets);

    auto child_data = childv.child();
    EXPECT_EQ(child_data.size(), 4);
    test::fixed_width_column_wrapper<int> e_child_data({2, 3, 4, 5});
    test::expect_columns_equal(e_child_data, child_data);
  }

  // List<List<int32>> 3 rows
  //
  // List<List<int32_t>>:
  // Length : 3
  // Offsets : 0, 2, 5, 6
  // Children :
  //    List<int32_t>:
  //    Length : 6
  //    Offsets : 0, 2, 4, 7, 8, 9, 11
  //    Children :
  //      1, 2, 3, 4, 5, 6, 7, 0, 8, 9, 10
  {
    test::lists_column_wrapper list{{{1, 2}, {3, 4}}, {{5, 6, 7}, {0}, {8}}, {{9, 10}}};

    lists_column_view lcv(list);
    EXPECT_EQ(lcv.size(), 3);

    auto offsets = lcv.offsets();
    EXPECT_EQ(offsets.size(), 4);
    test::fixed_width_column_wrapper<size_type> e_offsets({0, 2, 5, 6});
    test::expect_columns_equal(e_offsets, offsets);

    auto child = lcv.child();
    lists_column_view childv(child);
    EXPECT_EQ(childv.size(), 6);

    auto child_offsets = childv.offsets();
    EXPECT_EQ(child_offsets.size(), 7);
    test::fixed_width_column_wrapper<size_type> e_child_offsets({0, 2, 4, 7, 8, 9, 11});
    test::expect_columns_equal(e_child_offsets, child_offsets);

    auto child_data = childv.child();
    EXPECT_EQ(child_data.size(), 11);
    test::fixed_width_column_wrapper<int> e_child_data({1, 2, 3, 4, 5, 6, 7, 0, 8, 9, 10});
    test::expect_columns_equal(e_child_data, child_data);
  }
}

TEST_F(ListColumnWrapperTest, ListOfListOfIntsWithValidity)
{
  using namespace cudf;

  auto valids = cudf::test::make_counting_transform_iterator(
    0, [](auto i) { return i % 2 == 0 ? true : false; });

  // List<List<int>>, 1 row
  //
  // List<List<int32_t>>:
  // Length : 1
  // Offsets : 0, 2
  // Children :
  //    List<int32_t>:
  //    Length : 2
  //    Offsets : 0, 2, 4
  //    Children :
  //      2, NULL, 4, NULL
  {
    // equivalent to { {2, NULL}, {4, NULL} }
    test::lists_column_wrapper list{{{{2, 3}, valids}, {{4, 5}, valids}}};

    lists_column_view lcv(list);
    EXPECT_EQ(lcv.size(), 1);

    auto offsets = lcv.offsets();
    EXPECT_EQ(offsets.size(), 2);
    test::fixed_width_column_wrapper<size_type> e_offsets({0, 2});
    test::expect_columns_equal(e_offsets, offsets);

    auto child = lcv.child();
    lists_column_view childv(child);
    EXPECT_EQ(childv.size(), 2);

    auto child_offsets = childv.offsets();
    EXPECT_EQ(child_offsets.size(), 3);
    test::fixed_width_column_wrapper<size_type> e_child_offsets({0, 2, 4});
    test::expect_columns_equal(e_child_offsets, child_offsets);

    auto child_data = childv.child();
    EXPECT_EQ(child_data.size(), 4);
    test::fixed_width_column_wrapper<int> e_child_data({2, 3, 4, 5}, valids);
    test::expect_columns_equal(e_child_data, child_data);
  }

  // List<List<int32>> 3 rows
  //
  // List<List<int32_t>>:
  // Length : 3
  // Offsets : 0, 2, 5, 6
  // Children :
  //    List<int32_t>:
  //    Length : 6
  //    Offsets : 0, 2, 2, 5, 5, 6, 8
  //    Null count: 2
  //    110101
  //    Children :
  //      1, 2, 5, 6, 7, 8, 9, 10
  {
    // equivalent to  { {{1, 2}, NULL}, {{5, 6, 7}, NULL, {8}}, {{9, 10}} }
    test::lists_column_wrapper list{
      {{{1, 2}, {3, 4}}, valids}, {{{5, 6, 7}, {0}, {8}}, valids}, {{{9, 10}}, valids}};

    lists_column_view lcv(list);
    EXPECT_EQ(lcv.size(), 3);

    auto offsets = lcv.offsets();
    EXPECT_EQ(offsets.size(), 4);
    test::fixed_width_column_wrapper<size_type> e_offsets({0, 2, 5, 6});
    test::expect_columns_equal(e_offsets, offsets);

    auto child = lcv.child();
    lists_column_view childv(child);
    EXPECT_EQ(childv.size(), 6);
    EXPECT_EQ(childv.null_count(), 2);

    auto child_offsets = childv.offsets();
    EXPECT_EQ(child_offsets.size(), 7);
    test::fixed_width_column_wrapper<size_type> e_child_offsets({0, 2, 2, 5, 5, 6, 8});
    test::expect_columns_equal(e_child_offsets, child_offsets);

    auto child_data = childv.child();
    EXPECT_EQ(child_data.size(), 8);
    test::fixed_width_column_wrapper<int> e_child_data({1, 2, 5, 6, 7, 8, 9, 10});
    test::expect_columns_equal(e_child_data, child_data);
  }
}

TEST_F(ListColumnWrapperTest, ListOfStrings)
{
  using namespace cudf;

  // List<string>, 2 rows
  //
  // List<cudf::string_view>:
  // Length : 2
  // Offsets : 0, 2, 5
  // Children :
  //    one, two, three, four, five
  {
    test::lists_column_wrapper list{{"one", "two"}, {"three", "four", "five"}};

    lists_column_view lcv(list);
    EXPECT_EQ(lcv.size(), 2);

    auto offsets = lcv.offsets();
    EXPECT_EQ(offsets.size(), 3);
    test::fixed_width_column_wrapper<size_type> e_offsets({0, 2, 5});
    test::expect_columns_equal(e_offsets, offsets);

    auto data = lcv.child();
    EXPECT_EQ(data.size(), 5);
    test::strings_column_wrapper e_data({"one", "two", "three", "four", "five"});
    test::expect_columns_equal(e_data, data);
  }
}

TEST_F(ListColumnWrapperTest, ListOfListOfStrings)
{
  using namespace cudf;

  // List<List<string>>, 2 rows
  //
  // List<List<cudf::string_view>>:
  // Length : 2
  // Offsets : 0, 2, 4
  // Children :
  //    List<cudf::string_view>:
  //    Length : 4
  //    Offsets : 0, 2, 5, 6, 8
  //    Children :
  //      one, two, three, four, five, eight, nine, ten
  {
    test::lists_column_wrapper list{{{"one", "two"}, {"three", "four", "five"}},
                                    {{"eight"}, {"nine", "ten"}}};

    lists_column_view lcv(list);
    EXPECT_EQ(lcv.size(), 2);

    auto offsets = lcv.offsets();
    EXPECT_EQ(offsets.size(), 3);
    test::fixed_width_column_wrapper<size_type> e_offsets({0, 2, 4});
    test::expect_columns_equal(e_offsets, offsets);

    auto child = lcv.child();
    lists_column_view childv(child);
    EXPECT_EQ(childv.size(), 4);

    auto child_offsets = childv.offsets();
    EXPECT_EQ(child_offsets.size(), 5);
    test::fixed_width_column_wrapper<size_type> e_child_offsets({0, 2, 5, 6, 8});
    test::expect_columns_equal(e_child_offsets, child_offsets);

    auto child_data = childv.child();
    EXPECT_EQ(child_data.size(), 8);
    test::strings_column_wrapper e_child_data(
      {"one", "two", "three", "four", "five", "eight", "nine", "ten"});
    test::expect_columns_equal(e_child_data, child_data);
  }
}

TEST_F(ListColumnWrapperTest, ListOfListOfListOfIntsWithValidity)
{
  using namespace cudf;

  auto valids = cudf::test::make_counting_transform_iterator(
    0, [](auto i) { return i % 2 == 0 ? true : false; });

  // List<List<List<int>>>, 2 rows
  //
  // List<List<List<int32_t>>>:
  // Length : 2
  // Offsets : 0, 2, 4
  // Children :
  //    List<List<int32_t>>:
  //    Length : 4
  //    Offsets : 0, 2, 2, 4, 6
  //    Null count: 1
  //    1101
  //    Children :
  //      List<int32_t>:
  //      Length : 6
  //      Offsets : 0, 2, 4, 6, 8, 11, 12
  //      Children :
  //        1, 2, 3, 4, -1, -2, -3, -4, -5, -6, -7, 0
  {
    // equivalent to  { {{{1, 2}, {3, 4}}, NULL}, {{{-1, -2}, {-3, -4}}, {{-5, -6, -7}, {0}}} }
    test::lists_column_wrapper list{{{{{1, 2}, {3, 4}}, {{5, 6, 7}, {0}}}, valids},
                                    {{{-1, -2}, {-3, -4}}, {{-5, -6, -7}, {0}}}};

    lists_column_view lcv(list);
    EXPECT_EQ(lcv.size(), 2);

    auto offsets = lcv.offsets();
    EXPECT_EQ(offsets.size(), 3);
    test::fixed_width_column_wrapper<size_type> e_offsets({0, 2, 4});
    test::expect_columns_equal(e_offsets, offsets);

    auto child = lcv.child();
    lists_column_view childv(child);
    EXPECT_EQ(childv.size(), 4);
    EXPECT_EQ(childv.null_count(), 1);

    auto child_offsets = childv.offsets();
    EXPECT_EQ(child_offsets.size(), 5);
    test::fixed_width_column_wrapper<size_type> e_child_offsets({0, 2, 2, 4, 6});
    test::expect_columns_equal(e_child_offsets, child_offsets);

    auto child_child = childv.child();
    lists_column_view child_childv(child_child);
    EXPECT_EQ(child_childv.size(), 6);

    auto child_child_offsets = child_childv.offsets();
    EXPECT_EQ(child_child_offsets.size(), 7);
    test::fixed_width_column_wrapper<size_type> e_child_child_offsets({0, 2, 4, 6, 8, 11, 12});
    test::expect_columns_equal(e_child_child_offsets, child_child_offsets);

    auto child_child_data = child_childv.child();
    EXPECT_EQ(child_child_data.size(), 12);
    test::fixed_width_column_wrapper<int> e_child_child_data(
      {1, 2, 3, 4, -1, -2, -3, -4, -5, -6, -7, 0});
    test::expect_columns_equal(child_child_data, child_child_data);
  }
}

TEST_F(ListColumnWrapperTest, ListTypesMismatch)
{
  using namespace cudf;

  using L  = std::initializer_list<int>;
  using L2 = std::initializer_list<float>;

  {
    auto should_throw = []() { test::lists_column_wrapper list{L{2, 3}, L2{4, 5}}; };
    EXPECT_THROW(should_throw(), cudf::logic_error);
  }

  {
    auto should_throw = []() {
      test::lists_column_wrapper list{{L{2, 3}, L{4, 5}}, {L2{6, 7}, L2{8, 9}}};
    };
    EXPECT_THROW(should_throw(), cudf::logic_error);
  }
}

TYPED_TEST(ListColumnWrapperTestTyped, ListOfType)
{
  using namespace cudf;

  using T = TypeParam;
  using L = std::initializer_list<T>;

  // List<T>, 1 row
  {
    test::lists_column_wrapper list{L{2, 3}};
    lists_column_view lcv(list);
    EXPECT_EQ(lcv.size(), 1);

    auto offsets = lcv.offsets();
    EXPECT_EQ(offsets.size(), 2);
    test::fixed_width_column_wrapper<size_type> e_offsets({0, 2});
    test::expect_columns_equal(e_offsets, offsets);

    auto data = lcv.child();
    EXPECT_EQ(data.size(), 2);
    test::fixed_width_column_wrapper<T> e_data({2, 3});
    test::expect_columns_equal(e_data, data);
  }

  // List<T>, 3 rows
  {
    test::lists_column_wrapper list{L{2, 3}, L{4, 5}, L{6, 7, 8}};
    lists_column_view lcv(list);
    EXPECT_EQ(lcv.size(), 3);

    auto offsets = lcv.offsets();
    EXPECT_EQ(offsets.size(), 4);
    test::fixed_width_column_wrapper<size_type> e_offsets({0, 2, 4, 7});
    test::expect_columns_equal(e_offsets, offsets);

    auto data = lcv.child();
    EXPECT_EQ(data.size(), 7);
    test::fixed_width_column_wrapper<T> e_data({2, 3, 4, 5, 6, 7, 8});
    test::expect_columns_equal(e_data, data);
  }
}

TYPED_TEST(ListColumnWrapperTestTyped, ListOfListOfTypes)
{
  using namespace cudf;

  using T = TypeParam;
  using L = std::initializer_list<T>;

  // List<List<T>>, 1 row
  //
  // List<List<T>>:
  // Length : 1
  // Offsets : 0, 2
  // Children :
  //    List<T>:
  //    Length : 2
  //    Offsets : 0, 2, 4
  //    Children :
  //      2, 3, 4, 5
  {
    test::lists_column_wrapper list{{L{2, 3}, L{4, 5}}};

    lists_column_view lcv(list);
    EXPECT_EQ(lcv.size(), 1);

    auto offsets = lcv.offsets();
    EXPECT_EQ(offsets.size(), 2);
    test::fixed_width_column_wrapper<size_type> e_offsets({0, 2});
    test::expect_columns_equal(e_offsets, offsets);

    auto child = lcv.child();
    lists_column_view childv(child);
    EXPECT_EQ(childv.size(), 2);

    auto child_offsets = childv.offsets();
    EXPECT_EQ(child_offsets.size(), 3);
    test::fixed_width_column_wrapper<size_type> e_child_offsets({0, 2, 4});
    test::expect_columns_equal(e_child_offsets, child_offsets);

    auto child_data = childv.child();
    EXPECT_EQ(child_data.size(), 4);
    test::fixed_width_column_wrapper<T> e_child_data({2, 3, 4, 5});
    test::expect_columns_equal(e_child_data, child_data);
  }

  // List<List<T>> 3 rows
  //
  // List<List<T>>:
  // Length : 3
  // Offsets : 0, 2, 5, 6
  // Children :
  //    List<T>:
  //    Length : 6
  //    Offsets : 0, 2, 4, 7, 8, 9, 11
  //    Children :
  //      1, 2, 3, 4, 5, 6, 7, 0, 8, 9, 10
  {
    test::lists_column_wrapper list{{L{1, 2}, L{3, 4}}, {L{5, 6, 7}, L{0}, L{8}}, {L{9, 10}}};

    lists_column_view lcv(list);
    EXPECT_EQ(lcv.size(), 3);

    auto offsets = lcv.offsets();
    EXPECT_EQ(offsets.size(), 4);
    test::fixed_width_column_wrapper<size_type> e_offsets({0, 2, 5, 6});
    test::expect_columns_equal(e_offsets, offsets);

    auto child = lcv.child();
    lists_column_view childv(child);
    EXPECT_EQ(childv.size(), 6);

    auto child_offsets = childv.offsets();
    EXPECT_EQ(child_offsets.size(), 7);
    test::fixed_width_column_wrapper<size_type> e_child_offsets({0, 2, 4, 7, 8, 9, 11});
    test::expect_columns_equal(e_child_offsets, child_offsets);

    auto child_data = childv.child();
    EXPECT_EQ(child_data.size(), 11);
    test::fixed_width_column_wrapper<T> e_child_data({1, 2, 3, 4, 5, 6, 7, 0, 8, 9, 10});
    test::expect_columns_equal(e_child_data, child_data);
  }
}

TYPED_TEST(ListColumnWrapperTestTyped, ListOfListListOfTypes)
{
  using namespace cudf;

  using T = TypeParam;
  using L = std::initializer_list<T>;

  // List<List<List<T>>>, 2 rows
  //
  // List<List<List<T>>>:
  // Length : 2
  // Offsets : 0, 2, 4
  // Children :
  //    List<List<T>>:
  //    Length : 4
  //    Offsets : 0, 2, 4, 6, 8
  //    Children :
  //        List<T>:
  //        Length : 8
  //        Offsets : 0, 2, 4, 7, 8, 10, 12, 15, 16
  //        Children :
  //          1, 2, 3, 4, 5, 6, 7, 0, -1, -2, -3, -4, -5, -6, -7, 0
  {
    test::lists_column_wrapper list{{{L{1, 2}, L{3, 4}}, {L{5, 6, 7}, L{0}}},
                                    {{L{-1, -2}, L{-3, -4}}, {L{-5, -6, -7}, L{0}}}};

    lists_column_view lcv(list);
    EXPECT_EQ(lcv.size(), 2);

    auto offsets = lcv.offsets();
    EXPECT_EQ(offsets.size(), 3);
    test::fixed_width_column_wrapper<size_type> e_offsets({0, 2, 4});
    test::expect_columns_equal(e_offsets, offsets);

    auto child = lcv.child();
    lists_column_view childv(child);
    EXPECT_EQ(childv.size(), 4);

    auto child_offsets = childv.offsets();
    EXPECT_EQ(child_offsets.size(), 5);
    test::fixed_width_column_wrapper<size_type> e_child_offsets({0, 2, 4, 6, 8});
    test::expect_columns_equal(e_child_offsets, child_offsets);

    auto child_child = childv.child();
    lists_column_view child_childv(child_child);
    EXPECT_EQ(child_childv.size(), 8);

    auto child_child_offsets = child_childv.offsets();
    EXPECT_EQ(child_child_offsets.size(), 9);
    test::fixed_width_column_wrapper<size_type> e_child_child_offsets(
      {0, 2, 4, 7, 8, 10, 12, 15, 16});
    test::expect_columns_equal(e_child_child_offsets, child_child_offsets);

    auto child_child_data = child_childv.child();
    EXPECT_EQ(child_child_data.size(), 16);
    test::fixed_width_column_wrapper<T> e_child_child_data(
      {1, 2, 3, 4, 5, 6, 7, 0, -1, -2, -3, -4, -5, -6, -7, 0});
    test::expect_columns_equal(child_child_data, child_child_data);
  }
}
