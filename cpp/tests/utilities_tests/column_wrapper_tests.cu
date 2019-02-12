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


#include "tests/utilities/column_wrapper.cuh"
#include "tests/utilities/cudf_test_fixtures.h"

#include "gtest/gtest.h"
#include "gmock/gmock.h"

template <typename T>
struct ColumnWrapperTest : public GdfTest
{

};

using TestingTypes = ::testing::Types<int8_t, int16_t, int32_t, int64_t, float, double, cudf::date32, cudf::date64, cudf::timestamp>;

TYPED_TEST_CASE(ColumnWrapperTest, TestingTypes);