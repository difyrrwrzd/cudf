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

#include <cudf/dictionary/dictionary_column_view.hpp>
#include <cudf/dictionary/encode.hpp>
#include <cudf/copying.hpp>
#include <tests/utilities/base_fixture.hpp>
#include <tests/utilities/column_utilities.hpp>
#include <tests/utilities/column_wrapper.hpp>

#include <vector>

struct DictionarySliceTest : public cudf::test::BaseFixture {};

TEST_F(DictionarySliceTest, SliceColumn)
{
    cudf::test::strings_column_wrapper strings{ {"eee", "aaa", "ddd", "bbb", "ccc", "ccc", "ccc", "eee", "aaa"},
                                                {   1,     1,     1,     1,     1,     0,     1,     1,     1} };
    auto dictionary = cudf::dictionary::encode( strings );

    std::vector<cudf::size_type> splits{ 1,6 };
    auto result = cudf::experimental::slice( dictionary->view(), splits );

    auto output = cudf::dictionary::decode( cudf::dictionary_column_view(result.front()) );
    cudf::test::strings_column_wrapper expected{ {"aaa", "ddd", "bbb", "ccc", ""},
                                                 {   1,     1,     1,     1,   0} };
    cudf::test::expect_column_properties_equal(expected,*output);
}

TEST_F(DictionarySliceTest, SplitColumn)
{
    cudf::test::fixed_width_column_wrapper<float> input{ {4.25, 7.125, 0.5, 0, -11.75, 7.125, 0.5},
                                                         {   1,     1,   1, 0,      1,     1,   1} };
    auto dictionary = cudf::dictionary::encode( input );

    std::vector<cudf::size_type> splits{ 2,6 };
    auto results = cudf::experimental::split( dictionary->view(), splits );

    cudf::test::fixed_width_column_wrapper<float> expected1{ {4.25, 7.125} };
    auto output1 = cudf::dictionary::decode( cudf::dictionary_column_view(results[0]) );
    cudf::test::expect_column_properties_equal(expected1,output1->view());

    cudf::test::fixed_width_column_wrapper<float> expected2{ {0.5, 0, -11.75, 7.125}, {1,0,1,1} };
    auto output2 = cudf::dictionary::decode( cudf::dictionary_column_view(results[1]) );
    cudf::test::expect_column_properties_equal(expected2,output2->view());

    cudf::test::fixed_width_column_wrapper<float> expected3( {0.5} );
    auto output3 = cudf::dictionary::decode( cudf::dictionary_column_view(results[2]) );
    cudf::test::expect_column_properties_equal(expected3,output3->view());
}
