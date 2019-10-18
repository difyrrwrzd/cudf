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

#include <cudf/scalar/scalar.hpp>
#include <cudf/types.hpp>
#include <cudf/utilities/type_dispatcher.hpp>
#include <tests/utilities/base_fixture.hpp>
#include <tests/utilities/cudf_gtest.hpp>
#include <tests/utilities/type_list_utilities.hpp>
#include <tests/utilities/type_lists.hpp>

#include <thrust/sequence.h>
#include <random>

#include <gmock/gmock.h>

template <typename T>
struct TypedScalarTest : public cudf::test::BaseFixture {};

TYPED_TEST_CASE(TypedScalarTest, cudf::test::AllTypes);


TYPED_TEST(TypedScalarTest, DefaultValidity) {
  TypeParam value = 7;
  cudf::experimental::type_to_scalar_type<TypeParam> s(value);
  

  EXPECT_TRUE(s.is_valid());
  EXPECT_EQ(value, s.value());
}

TYPED_TEST(TypedScalarTest, ConstructNull) {
  TypeParam value = 5;
  cudf::experimental::type_to_scalar_type<TypeParam> s(value, false);

  EXPECT_FALSE(s.is_valid());
}

TYPED_TEST(TypedScalarTest, SetValue) {
  TypeParam value = 9;
  cudf::experimental::type_to_scalar_type<TypeParam> s;
  s.set_value(value);

  EXPECT_TRUE(s.is_valid());
  EXPECT_EQ(value, s.value());
}

TYPED_TEST(TypedScalarTest, SetNull) {
  TypeParam value = 6;
  cudf::experimental::type_to_scalar_type<TypeParam> s;
  s.set_value(value);
  s.set_null();

  EXPECT_FALSE(s.is_valid());
}

TYPED_TEST(TypedScalarTest, CopyConstructor) {
  TypeParam value = 8;
  cudf::experimental::type_to_scalar_type<TypeParam> s(value);
  auto s2 = s;

  EXPECT_TRUE(s2.is_valid());
  EXPECT_EQ(value, s2.value());
}

// TYPED_TEST(TypedScalarTest, MoveConstructor) {
//   TypeParam value = 8;
//   cudf::experimental::type_to_scalar_type<TypeParam> s(value);
//   auto s2(std::move(s));

//   EXPECT_TRUE(s2.is_valid());
//   EXPECT_EQ(value, s2.value());
//   EXPECT_FALSE(s.is_valid());
// }

// struct StringScalarTest : public cudf::test::BaseFixture {}

// TEST_F(StringScalarTest, DefaultValidity) {
//   std::string value = "test string";
//   cudf::experimental::type_to_scalar_type<TypeParam> s(value);

//   EXPECT_TRUE(s.is_valid());
//   EXPECT_EQ(value, s.value());
// }

// TYPED_TEST(TypedScalarTest, ConstructNull) {
//   std::string value = "another test string";
//   cudf::experimental::type_to_scalar_type<TypeParam> s(value, false);

//   EXPECT_FALSE(s.is_valid());
// }
