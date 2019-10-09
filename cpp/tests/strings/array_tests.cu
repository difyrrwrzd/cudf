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
#include <cudf/column/column_factories.hpp>
#include <cudf/strings/strings_column_view.hpp>
#include <cudf/strings/sorting.hpp>
#include <cudf/strings/copying.hpp>
#include <utilities/error_utils.hpp>

#include <tests/utilities/base_fixture.hpp>
#include "./utilities.h"

#include <vector>
#include <gmock/gmock.h>


struct StringsColumnTest : public cudf::test::BaseFixture {};

TEST_F(StringsColumnTest, Sort)
{
    std::vector<const char*> h_strings{ "eee", "bb", nullptr, "", "aa", "bbb", "ééé" };
    std::vector<const char*> h_expected{ nullptr, "", "aa", "bb", "bbb", "eee", "ééé" };

    auto d_strings = cudf::test::create_strings_column(h_strings);
    auto strings_view = cudf::strings_column_view(d_strings->view());

    auto results = cudf::strings::detail::sort(strings_view, cudf::strings::detail::name);
    cudf::test::expect_strings_equal(*results, h_expected);
}

TEST_F(StringsColumnTest, SortZeroSizeStringsColumn)
{
    cudf::column_view zero_size_strings_column( cudf::data_type{cudf::STRING}, 0, nullptr, nullptr, 0);
    auto strings_view = cudf::strings_column_view(zero_size_strings_column);
    EXPECT_THROW( cudf::strings::detail::sort(strings_view, cudf::strings::detail::name), cudf::logic_error );
}

class SliceParmsTest : public StringsColumnTest,
                       public testing::WithParamInterface<cudf::size_type> {};

TEST_P(SliceParmsTest, Slice)
{
    std::vector<const char*> h_strings{ "eee", "bb", nullptr, "", "aa", "bbb", "ééé" };
    cudf::size_type start = 3;
    cudf::size_type end = GetParam();
    std::vector<const char*> h_expected;
    if( end > start )
    {
        for( cudf::size_type idx=start; (idx < end) && (idx < (cudf::size_type)h_strings.size()); ++idx )
            h_expected.push_back( h_strings[idx] );
    }
    auto d_strings = cudf::test::create_strings_column(h_strings);
    auto strings_view = cudf::strings_column_view(d_strings->view());
    auto results = cudf::strings::detail::slice(strings_view,start,end);
    cudf::test::expect_strings_equal(*results, h_expected);
}

TEST_P(SliceParmsTest, SliceAllNulls)
{
    std::vector<const char*> h_strings{ nullptr, nullptr, nullptr, nullptr, nullptr, nullptr, nullptr };
    cudf::size_type start = 3;
    cudf::size_type end = GetParam();
    std::vector<const char*> h_expected;
    if( end > start )
    {
        for( cudf::size_type idx=start; (idx < end) && (idx < (cudf::size_type)h_strings.size()); ++idx )
            h_expected.push_back( h_strings[idx] );
    }
    auto d_strings = cudf::test::create_strings_column(h_strings);
    auto strings_view = cudf::strings_column_view(d_strings->view());
    auto results = cudf::strings::detail::slice(strings_view,start,end);
    cudf::test::expect_strings_equal(*results, h_expected);
}

TEST_P(SliceParmsTest, SliceAllEmpty)
{
    std::vector<const char*> h_strings{ "", "", "", "", "", "", "" };
    cudf::size_type start = 3;
    cudf::size_type end = GetParam();
    std::vector<const char*> h_expected;
    if( end > start )
    {
        for( cudf::size_type idx=start; (idx < end) && (idx < (cudf::size_type)h_strings.size()); ++idx )
            h_expected.push_back( h_strings[idx] );
    }
    auto d_strings = cudf::test::create_strings_column(h_strings);
    auto strings_view = cudf::strings_column_view(d_strings->view());
    auto results = cudf::strings::detail::slice(strings_view,start,end);
    cudf::test::expect_strings_equal(*results, h_expected);
}

INSTANTIATE_TEST_CASE_P(SliceParms, SliceParmsTest,
                        testing::ValuesIn(std::array<cudf::size_type,3>{5,6,7}));

TEST_F(StringsColumnTest, SliceZeroSizeStringsColumn)
{
    cudf::column_view zero_size_strings_column( cudf::data_type{cudf::STRING}, 0, nullptr, nullptr, 0);
    auto strings_view = cudf::strings_column_view(zero_size_strings_column);
    EXPECT_THROW( cudf::strings::detail::slice(strings_view,1,2), cudf::logic_error );
}

TEST_F(StringsColumnTest, Gather)
{
    std::vector<const char*> h_strings{ "eee", "bb", nullptr, "", "aa", "bbb", "ééé" };
    std::vector<const char*> h_expected{ "aa", "bb" };

    auto d_strings = cudf::test::create_strings_column(h_strings);
    auto strings_view = cudf::strings_column_view(d_strings->view());

    rmm::device_vector<int32_t> gather_map(2,0);
    gather_map[0] = 4;
    gather_map[1] = 1;
    cudf::column_view gather_map_view( cudf::data_type{cudf::INT32}, gather_map.size(),
                                       gather_map.data().get(), nullptr, 0);

    auto results = cudf::strings::detail::gather(strings_view,gather_map_view);
    cudf::test::expect_strings_equal(*results, h_expected);
}

TEST_F(StringsColumnTest, GatherZeroSizeStringsColumn)
{
    cudf::column_view zero_size_strings_column( cudf::data_type{cudf::STRING}, 0, nullptr, nullptr, 0);
    auto strings_view = cudf::strings_column_view(zero_size_strings_column);
    cudf::column_view map_view( cudf::data_type{cudf::INT32}, 0, nullptr, nullptr, 0);
    EXPECT_THROW( cudf::strings::detail::gather(strings_view,map_view), cudf::logic_error );
}

TEST_F(StringsColumnTest, Scatter)
{
    std::vector<const char*> h_strings1{ "eee", "bb", nullptr, "", "aa", "bbb", "ééé" };
    std::vector<const char*> h_strings2{ "1", "22" };
    std::vector<const char*> h_expected{ "eee", "22", nullptr, "", "1", "bbb", "ééé" };

    auto d_strings1 = cudf::test::create_strings_column(h_strings1);
    auto view1 = cudf::strings_column_view(d_strings1->view());
    auto d_strings2 = cudf::test::create_strings_column(h_strings2);
    auto view2 = cudf::strings_column_view(d_strings2->view());

    rmm::device_vector<int32_t> scatter_map(2,0);
    scatter_map[0] = 4;
    scatter_map[1] = 1;
    cudf::column_view scatter_map_view( cudf::data_type{cudf::INT32}, scatter_map.size(),
                                        scatter_map.data().get(), nullptr, 0);

    printf("%d:%d:%d\n", (int)h_strings1.size(), (int)h_strings2.size(), (int)h_expected.size());

    auto results = cudf::strings::detail::scatter(view1,view2,scatter_map_view);
    printf("%d:%d:%d\n", (int)h_strings1.size(), (int)h_strings2.size(), (int)h_expected.size());
    cudf::test::expect_strings_equal(*results, h_expected);
}

TEST_F(StringsColumnTest, ScatterZeroSizeStringsColumn)
{
    cudf::column_view zero_size_strings_column( cudf::data_type{cudf::STRING}, 0, nullptr, nullptr, 0);
    auto strings_view = cudf::strings_column_view(zero_size_strings_column);
    cudf::column_view map_view( cudf::data_type{cudf::INT32}, 0, nullptr, nullptr, 0);
    cudf::column_view values( cudf::data_type{cudf::STRING}, 0, nullptr, nullptr, 0);
    auto values_view = cudf::strings_column_view(values);
    EXPECT_THROW( cudf::strings::detail::scatter(strings_view,values_view,map_view), cudf::logic_error );
}

TEST_F(StringsColumnTest, ScatterScalar)
{
    std::vector<const char*> h_strings{ "eee", "bb", nullptr, "", "aa", "bbb", "ééé" };
    std::vector<const char*> h_expected{ "eee", "---", nullptr, "", "---", "bbb", "ééé" };

    auto d_strings = cudf::test::create_strings_column(h_strings);
    auto view = cudf::strings_column_view(d_strings->view());

    rmm::device_vector<int32_t> scatter_map(2,0);
    scatter_map[0] = 4;
    scatter_map[1] = 1;
    cudf::column_view scatter_map_view( cudf::data_type{cudf::INT32}, scatter_map.size(),
                                        scatter_map.data().get(), nullptr, 0);

    auto results = cudf::strings::detail::scatter(view,"---",scatter_map_view);
    cudf::test::expect_strings_equal(*results, h_expected);
}

TEST_F(StringsColumnTest, ScatterScalarZeroSizeStringsColumn)
{
    cudf::column_view zero_size_strings_column( cudf::data_type{cudf::STRING}, 0, nullptr, nullptr, 0);
    auto strings_view = cudf::strings_column_view(zero_size_strings_column);
    cudf::column_view map_view( cudf::data_type{cudf::INT32}, 0, nullptr, nullptr, 0);
    EXPECT_THROW( cudf::strings::detail::scatter(strings_view,nullptr,map_view), cudf::logic_error );
}
