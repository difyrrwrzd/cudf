/*
 * Copyright (c) 2021, NVIDIA CORPORATION.
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

#include <cudf_test/io_metadata_utilities.hpp>

#include <gmock/gmock.h>

namespace cudf::test {

void expect_metadata_equal(cudf::io::table_input_metadata in_meta,
                           cudf::io::table_metadata out_meta)
{
  std::function<void(cudf::io::column_name_info, cudf::io::column_in_metadata)> compare_names =
    [&](cudf::io::column_name_info out_col, cudf::io::column_in_metadata in_col) {
      if (not in_col.get_name().empty()) { EXPECT_EQ(out_col.name, in_col.get_name()); }
      ASSERT_EQ(out_col.children.size(), in_col.num_children());
      for (size_t i = 0; i < out_col.children.size(); ++i) {
        compare_names(out_col.children[i], in_col.child(i));
      }
    };

  ASSERT_EQ(out_meta.schema_info.size(), in_meta.column_metadata.size());

  for (size_t i = 0; i < out_meta.schema_info.size(); ++i) {
    compare_names(out_meta.schema_info[i], in_meta.column_metadata[i]);
  }
}

}  // namespace cudf::test
