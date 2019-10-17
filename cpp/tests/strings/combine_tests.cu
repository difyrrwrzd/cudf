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

#include <cudf/column/column_factories.hpp>
#include <cudf/strings/strings_column_view.hpp>
#include <cudf/strings/combine.hpp>
#include <cudf/types.hpp>

#include <tests/utilities/base_fixture.hpp>
#include <tests/utilities/column_wrapper.hpp>
#include <tests/utilities/column_utilities.cuh>
#include "./utilities.h"

#include <vector>
#include <gmock/gmock.h>


struct StringsCombineTest : public cudf::test::BaseFixture {};

TEST_F(StringsCombineTest, Concatenate)
{
    std::vector<const char*> h_strings1{ "eee", "bb", nullptr, "", "aa", "bbb", "ééé" };
    cudf::test::strings_column_wrapper strings1( h_strings1.begin(), h_strings1.end(),
        thrust::make_transform_iterator( h_strings1.begin(), [] (auto str) { return str!=nullptr; }));
    std::vector<const char*> h_strings2{ "xyz", "abc", "d", "éa", "", nullptr, "f" };
    cudf::test::strings_column_wrapper strings2( h_strings2.begin(), h_strings2.end(),
        thrust::make_transform_iterator( h_strings2.begin(), [] (auto str) { return str!=nullptr; }));

    auto view1 = cudf::strings_column_view(strings1);
    auto view2 = cudf::strings_column_view(strings2);

    std::vector<cudf::strings_column_view> strings_columns;
    strings_columns.push_back(view1);
    strings_columns.push_back(view2);

    {
        std::vector<const char*> h_expected{ "eeexyz", "bbabc", nullptr, "éa", "aa", nullptr, "éééf" };
        cudf::test::strings_column_wrapper expected( h_expected.begin(), h_expected.end(),
            thrust::make_transform_iterator( h_expected.begin(), [] (auto str) { return str!=nullptr; }));

        auto results = cudf::strings::concatenate(strings_columns);
        cudf::test::expect_columns_equal(*results,expected);
    }
    {
        std::vector<const char*> h_expected{ "eee:xyz", "bb:abc", nullptr, ":éa", "aa:", nullptr, "ééé:f" };
        cudf::test::strings_column_wrapper expected( h_expected.begin(), h_expected.end(),
            thrust::make_transform_iterator( h_expected.begin(), [] (auto str) { return str!=nullptr; }));

        auto results = cudf::strings::concatenate(strings_columns,":");
        cudf::test::expect_columns_equal(*results,expected);
    }
    {
        std::vector<const char*> h_expected{ "eee:xyz", "bb:abc", "_:d", ":éa", "aa:", "bbb:_", "ééé:f" };
        cudf::test::strings_column_wrapper expected( h_expected.begin(), h_expected.end() );
            //thrust::make_transform_iterator( h_expected.begin(), [] (auto str) { return str!=nullptr; }));

        auto results = cudf::strings::concatenate(strings_columns,":","_");
        cudf::test::expect_columns_equal(*results,expected);
    }
}

TEST_F(StringsCombineTest, ConcatZeroSizeStringsColumns)
{
    cudf::column_view zero_size_strings_column( cudf::data_type{cudf::STRING}, 0, nullptr, nullptr, 0);
    auto strings_view = cudf::strings_column_view(zero_size_strings_column);
    std::vector<cudf::strings_column_view> strings_columns;
    strings_columns.push_back(strings_view);
    strings_columns.push_back(strings_view);
    auto results = cudf::strings::concatenate(strings_columns);
    cudf::test::expect_strings_empty(results->view());
}

TEST_F(StringsCombineTest, ConcatInvalidStringsColumns)
{
    cudf::column_view zero_size_strings_column( cudf::data_type{cudf::STRING}, 0, nullptr, nullptr, 0);
    auto strings_view = cudf::strings_column_view(zero_size_strings_column);
    std::vector<cudf::strings_column_view> strings_columns;
    strings_columns.push_back(strings_view); // not enough columns
    EXPECT_THROW( cudf::strings::concatenate(strings_columns), cudf::logic_error );
}

TEST_F(StringsCombineTest, Join)
{
    std::vector<const char*> h_strings{ "eee", "bb", nullptr, "zzzz", "", "aaa", "ééé" };
    cudf::test::strings_column_wrapper strings( h_strings.begin(), h_strings.end(),
        thrust::make_transform_iterator( h_strings.begin(), [] (auto str) { return str!=nullptr; }));
    auto view1 = cudf::strings_column_view(strings);

    {
        auto results = cudf::strings::join_strings(view1);

        cudf::test::strings_column_wrapper expected{"eeebbzzzzaaaééé"};
        cudf::test::expect_columns_equal(*results,expected);
    }
    {
        auto results = cudf::strings::join_strings(view1,"+");

        cudf::test::strings_column_wrapper expected{"eee+bb+zzzz++aaa+ééé"};
        cudf::test::expect_columns_equal(*results,expected);
    }
    {
        auto results = cudf::strings::join_strings(view1,"+","___");

        cudf::test::strings_column_wrapper expected{"eee+bb+___+zzzz++aaa+ééé"};
        cudf::test::expect_columns_equal(*results,expected);
    }
}

TEST_F(StringsCombineTest, JoinZeroSizeStringsColumn)
{
    cudf::column_view zero_size_strings_column( cudf::data_type{cudf::STRING}, 0, nullptr, nullptr, 0);
    auto strings_view = cudf::strings_column_view(zero_size_strings_column);
    auto results = cudf::strings::join_strings(strings_view);
    cudf::test::expect_strings_empty(results->view());
}
