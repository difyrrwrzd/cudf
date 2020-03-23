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
#include <cudf/filling.hpp>
#include <cudf/scalar/scalar.hpp>
#include <tests/utilities/base_fixture.hpp>
#include <tests/utilities/column_utilities.hpp>
#include <tests/utilities/column_wrapper.hpp>

#include <vector>

struct DictionaryFillTest : public cudf::test::BaseFixture {};

TEST_F(DictionaryFillTest, StringsColumn)
{
    std::vector<const char*> h_strings{ "fff", "aaa", "", "bbb", "ccc", "ccc", "ccc", "fff", "aaa", "" };
    cudf::test::strings_column_wrapper strings( h_strings.begin(), h_strings.end() );
    auto dictionary = cudf::dictionary::encode( strings );

    cudf::string_scalar fv("___");
    auto results = cudf::experimental::fill( dictionary->view(), 1,4, fv );
    auto decoded = cudf::dictionary::decode( results->view() );
    std::vector<const char*> h_expected{ "fff", "___", "___", "___", "ccc", "ccc", "ccc", "fff", "aaa", "" };
    cudf::test::strings_column_wrapper expected( h_expected.begin(), h_expected.end() );
    cudf::test::expect_columns_equal(decoded->view(),expected);
}

