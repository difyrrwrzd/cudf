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
#include <cudf/types.hpp>

#include <vector>
#include <gtest/gtest.h>
#include <gmock/gmock.h>
#include <tests/utilities/cudf_test_fixtures.h>
#include "./utilities.h"

#include <vector>


struct CombineTest : public GdfTest {};

TEST_F(CombineTest, Concatenate)
{
    std::vector<const char*> h_strings1{ "eee", "bb", nullptr, "", "aa", "bbb", "ééé" };
    std::vector<const char*> h_strings2{ "xyz", "abc", "d", "éa", "", nullptr, "f" };

    auto d_strings1 = cudf::test::create_strings_column(h_strings1);
    auto view1 = cudf::strings_column_view(d_strings1->view());
    auto d_strings2 = cudf::test::create_strings_column(h_strings2);
    auto view2 = cudf::strings_column_view(d_strings2->view());

    std::vector<cudf::strings_column_view> strings_columns;
    strings_columns.push_back(view1);
    strings_columns.push_back(view2);

    {
        std::vector<const char*> h_expected{ "eeexyz", "bbabc", nullptr, "éa", "aa", nullptr, "éééf" };
        auto d_expected = cudf::test::create_strings_column(h_expected);
        auto expected_view = cudf::strings_column_view(d_expected->view());

        auto results = cudf::strings::concatenate(strings_columns);
        auto results_view = cudf::strings_column_view(results->view());
        cudf::test::expect_strings_columns_equal(results_view, expected_view);
    }
    {
        std::vector<const char*> h_expected{ "eee:xyz", "bb:abc", nullptr, ":éa", "aa:", nullptr, "ééé:f" };
        auto d_expected = cudf::test::create_strings_column(h_expected);
        auto expected_view = cudf::strings_column_view(d_expected->view());

        auto results = cudf::strings::concatenate(strings_columns,":");
        auto results_view = cudf::strings_column_view(results->view());
        cudf::test::expect_strings_columns_equal(results_view, expected_view);
    }

    {
        std::vector<const char*> h_expected{ "eee:xyz", "bb:abc", "_:d", ":éa", "aa:", "bbb:_", "ééé:f" };
        auto d_expected = cudf::test::create_strings_column(h_expected);
        auto expected_view = cudf::strings_column_view(d_expected->view());

        auto results = cudf::strings::concatenate(strings_columns,":","_");
        auto results_view = cudf::strings_column_view(results->view());
        cudf::test::expect_strings_columns_equal(results_view, expected_view);
    }
}

TEST_F(CombineTest, Join)
{
    std::vector<const char*> h_strings1{ "eee", "bb", nullptr, "zzzz", "", "aaa", "ééé" };

    auto d_strings1 = cudf::test::create_strings_column(h_strings1);
    auto view1 = cudf::strings_column_view(d_strings1->view());

    {
        std::vector<const char*> h_expected{ "eeebbzzzzaaaééé" };
        auto d_expected = cudf::test::create_strings_column(h_expected);
        auto expected_view = cudf::strings_column_view(d_expected->view());

        auto results = cudf::strings::join_strings(view1);
        auto results_view = cudf::strings_column_view(results->view());
        cudf::test::expect_strings_columns_equal(results_view, expected_view);
    }
    {
        std::vector<const char*> h_expected{ "eee+bb+zzzz++aaa+ééé" };
        auto d_expected = cudf::test::create_strings_column(h_expected);
        auto expected_view = cudf::strings_column_view(d_expected->view());

        auto results = cudf::strings::join_strings(view1,"+");
        auto results_view = cudf::strings_column_view(results->view());
        cudf::test::expect_strings_columns_equal(results_view, expected_view);
    }
    {
        std::vector<const char*> h_expected{ "eee+bb+___+zzzz++aaa+ééé" };
        auto d_expected = cudf::test::create_strings_column(h_expected);
        auto expected_view = cudf::strings_column_view(d_expected->view());

        auto results = cudf::strings::join_strings(view1,"+","___");
        auto results_view = cudf::strings_column_view(results->view());
        cudf::test::expect_strings_columns_equal(results_view, expected_view);
    }
}