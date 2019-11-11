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

#include <tests/utilities/column_wrapper.hpp>
#include <tests/utilities/cudf_gtest.hpp>
#include <tests/utilities/base_fixture.hpp>
#include <tests/utilities/column_utilities.hpp>
#include <tests/utilities/type_lists.hpp>

#include <cudf/filling.hpp>
#include <cudf/types.hpp>
#include <cudf/utilities/traits.hpp>
#include <cudf/scalar/scalar.hpp>
#include <cudf/scalar/scalar_factories.hpp>

#include <thrust/iterator/constant_iterator.h>
#include <thrust/iterator/counting_iterator.h>

auto all_valid = [](cudf::size_type row) { return true; };
auto odd_valid = [](cudf::size_type row) { return row % 2 != 0; };
auto all_invalid = [](cudf::size_type row) { return false; };

template <typename T>
class FillTypedTestFixture : public cudf::test::BaseFixture {
public:
  static constexpr cudf::size_type column_size{1000};

  template <typename BitInitializerType = decltype(all_valid)>
  void test(cudf::size_type begin,
           cudf::size_type end,
           T value,
           bool value_is_valid = true,
           BitInitializerType destination_validity = all_valid) {
    static_assert(cudf::is_fixed_width<T>() == true,
                  "this code assumes fixed-width types.");

    auto size = cudf::size_type{FillTypedTestFixture<T>::column_size};

    auto destination = cudf::test::fixed_width_column_wrapper<T>(
                         thrust::make_counting_iterator(0),
                         thrust::make_counting_iterator(0) + size,
                         cudf::test::make_counting_transform_iterator(
                           0, destination_validity));

    auto p_val = std::unique_ptr<cudf::scalar>{nullptr};
    auto type = cudf::data_type{cudf::experimental::type_to_id<T>()};
    if (cudf::is_numeric<T>()) {
      p_val = cudf::make_numeric_scalar(type);
    }
    else if (cudf::is_timestamp<T>()) {
      p_val = cudf::make_timestamp_scalar(type);
    }
    else {
      EXPECT_TRUE(false);  // should not be reached
    }
    using ScalarType = cudf::experimental::scalar_type_t<T>;
    static_cast<ScalarType*>(p_val.get())->set_value(value);
    static_cast<ScalarType*>(p_val.get())->set_valid(value_is_valid);

    auto expected_elements =
      cudf::test::make_counting_transform_iterator(
        0,
        [begin, end, value](auto i) {
          return (i >= begin && i < end) ? value : static_cast<T>(i);
        });
    auto expected =
      cudf::test::fixed_width_column_wrapper<T>(
        expected_elements, expected_elements + size,
        cudf::test::make_counting_transform_iterator(
        0,
        [begin, end, value_is_valid, destination_validity](auto i) {
          return (i >= begin && i < end) ?
            value_is_valid : destination_validity(i);
        }));

    // test out-of-place version first

    auto p_ret = cudf::experimental::fill(destination, begin, end, *p_val);
    cudf::test::expect_columns_equal(*p_ret, expected);

    // test in-place version second

    auto mutable_view = cudf::mutable_column_view{destination};
    EXPECT_NO_THROW(cudf::experimental::fill(mutable_view, begin, end, *p_val));
    cudf::test::expect_columns_equal(mutable_view, expected);
  }
};

TYPED_TEST_CASE(FillTypedTestFixture, cudf::test::FixedWidthTypes);

TYPED_TEST(FillTypedTestFixture, SetSingle)
{
  using T = TypeParam;

  auto index = cudf::size_type{9};
  auto val = T{1};

  // First set it as valid
  this->test(index, index+1, val, true);

  // next set it as invalid
  this->test(index, index+1, val, false);
}

TYPED_TEST(FillTypedTestFixture, SetAll)
{
  using T = TypeParam;

  auto size = cudf::size_type{FillTypedTestFixture<T>::column_size};

  auto val = T{1};

  // First set it as valid
  this->test(0, size, val, true);

  // next set it as invalid
  this->test(0, size, val, false);
}

TYPED_TEST(FillTypedTestFixture, SetRange)
{
  using T = TypeParam;

  auto begin = cudf::size_type{99};
  auto end = cudf::size_type{299};
  auto val = T{1};

  // First set it as valid
  this->test(begin, end, val, true);

  // Next set it as invalid
  this->test(begin, end, val, false);
}

TYPED_TEST(FillTypedTestFixture, SetRangeNullCount)
{
  using T = TypeParam;

  auto size = cudf::size_type{FillTypedTestFixture<T>::column_size};

  auto begin = cudf::size_type{10};
  auto end = cudf::size_type{50};
  auto val = T{1};

  // First set it as valid value
  this->test(begin, end, val, true, odd_valid);

  // Next set it as invalid
  this->test(begin, end, val, false, odd_valid);

  // All invalid column should have some valid
  this->test(begin, end, val, true, all_invalid);

  // All should be invalid
  this->test(begin, end, val, false, all_invalid);

  // All should be valid
  this->test(0, size, val, true, odd_valid);
}

class FillErrorTestFixture : public cudf::test::BaseFixture {};

TEST_F(FillErrorTestFixture, InvalidInplaceCall)
{
  auto p_val_int = cudf::make_numeric_scalar(cudf::data_type(cudf::INT32));
  using T_int = cudf::experimental::id_to_type<cudf::INT32>;
  using ScalarType = cudf::experimental::scalar_type_t<T_int>;
  static_cast<ScalarType*>(p_val_int.get())->set_value(5);
  static_cast<ScalarType*>(p_val_int.get())->set_valid(false);

  auto destination =
    cudf::test::fixed_width_column_wrapper<int32_t>(
      thrust::make_counting_iterator(0),
      thrust::make_counting_iterator(0) + 100);

  auto destination_view = cudf::mutable_column_view{destination};
  EXPECT_THROW(cudf::experimental::fill(destination_view, 0, 100, *p_val_int),
               cudf::logic_error);

  auto p_val_str = cudf::make_string_scalar("five");

  auto strings =
    std::vector<std::string>{"", "this", "is", "a", "column", "of", "strings"};
  auto destination_string =
    cudf::test::strings_column_wrapper(strings.begin(), strings.end());

  auto destination_view_string = cudf::mutable_column_view{destination_string};
  EXPECT_THROW(cudf::experimental::fill(
                 destination_view_string, 0, 100, *p_val_str),
               cudf::logic_error);
}

TEST_F(FillErrorTestFixture, InvalidRange)
{
  auto p_val = cudf::make_numeric_scalar(cudf::data_type(cudf::INT32));
  using T = cudf::experimental::id_to_type<cudf::INT32>;
  using ScalarType = cudf::experimental::scalar_type_t<T>;
  static_cast<ScalarType*>(p_val.get())->set_value(5);

  auto destination =
    cudf::test::fixed_width_column_wrapper<int32_t>(
      thrust::make_counting_iterator(0),
      thrust::make_counting_iterator(0) + 100,
      thrust::make_constant_iterator(true));

  auto destination_view = cudf::mutable_column_view{destination};

  // empty range == no-op, this is valid
  EXPECT_NO_THROW(cudf::experimental::fill(destination_view, 0, 0, *p_val));
  EXPECT_NO_THROW(auto p_ret =
                    cudf::experimental::fill(destination, 0, 0, *p_val));

  // out_begin is negative
  EXPECT_THROW(cudf::experimental::fill(destination_view, -10, 0, *p_val),
               cudf::logic_error);
  EXPECT_THROW(auto p_ret = cudf::experimental::fill(destination, -10, 0,
                 *p_val),
               cudf::logic_error);

  // out_begin > out_end
  EXPECT_THROW(cudf::experimental::fill(destination_view, 10, 5, *p_val),
               cudf::logic_error);
  EXPECT_THROW(auto p_ret = cudf::experimental::fill(destination, 10, 5,
                 *p_val),
               cudf::logic_error);

  // out_begin >= destination.size()
  EXPECT_THROW(cudf::experimental::fill(destination_view, 100, 100, *p_val),
               cudf::logic_error);
  EXPECT_THROW(auto p_ret = cudf::experimental::fill(destination, 100, 100,
                 *p_val),
               cudf::logic_error);

  // out_end > destination.size()
  EXPECT_THROW(cudf::experimental::fill(destination_view, 99, 101, *p_val),
               cudf::logic_error);
  EXPECT_THROW(auto p_ret = cudf::experimental::fill(destination, 99, 101,
                 *p_val),
               cudf::logic_error);
}

TEST_F(FillErrorTestFixture, DTypeMismatch)
{
  auto size = cudf::size_type{100};

  auto p_val = cudf::make_numeric_scalar(cudf::data_type(cudf::INT32));
  using T = cudf::experimental::id_to_type<cudf::INT32>;
  using ScalarType = cudf::experimental::scalar_type_t<T>;
  static_cast<ScalarType*>(p_val.get())->set_value(5);

  auto destination = cudf::test::fixed_width_column_wrapper<float>(
    thrust::make_counting_iterator(0),
    thrust::make_counting_iterator(0) + size);

  auto destination_view = cudf::mutable_column_view{destination};

  EXPECT_THROW(cudf::experimental::fill(
                 destination_view, 0, 10, *p_val),
               cudf::logic_error);
  EXPECT_THROW(auto p_ret = cudf::experimental::fill(
                 destination, 0, 10, *p_val),
               cudf::logic_error);
}

TEST_F(FillErrorTestFixture, StringCategoryNotSupported)
{
  auto p_val = cudf::make_string_scalar("five");

  auto strings =
    std::vector<std::string>{"", "this", "is", "a", "column", "of", "strings"};
  auto destination_string =
    cudf::test::strings_column_wrapper(strings.begin(), strings.end());

  EXPECT_THROW(auto p_ret = cudf::experimental::fill(
                 destination_string, 0, 1, *p_val),
               cudf::logic_error);
}
