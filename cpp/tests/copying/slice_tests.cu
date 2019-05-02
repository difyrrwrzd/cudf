/*
 * Copyright 2019 BlazingDB, Inc.
 *     Copyright 2019 Christian Noboa Mardini <christian@blazingdb.com>
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

#include "gtest/gtest.h"
#include "copying.hpp"
#include "tests/utilities/cudf_test_fixtures.h"
#include "tests/copying/copying_test_helper.hpp"

struct SliceInputTest : GdfTest {};

// TEST_F(SliceInputTest, IndexesNull) {
//   const int SIZE = 32;
//   using ColumnType = std::int32_t;

//   // Create input column
//   auto input_column = create_random_column<ColumnType>(SIZE);

//   // Create indexes
//   std::vector<gdf_index_type> indexes_host{SIZE / 4, SIZE / 2};

//   // Create output
//   std::vector<std::shared_ptr<cudf::test::column_wrapper<ColumnType>>> output_columns;
//   auto source_columns =
//       allocate_slice_output_columns<ColumnType>(output_columns, indexes_host);
  
//   // Perform test
//   ASSERT_ANY_THROW(cudf::slice(input_column.get(), nullptr, 0, source_columns));
// }

// TEST_F(SliceInputTest, InputColumnNull) {
//   const int SIZE = 32;
//   using ColumnType = std::int32_t;

//   // Create indexes
//   std::vector<gdf_index_type> indexes_host{SIZE / 4, SIZE / 2};
//   cudf::test::column_wrapper<gdf_index_type> indexes(indexes_host);

//   // Create output
//   std::vector<std::shared_ptr<cudf::test::column_wrapper<ColumnType>>> output_columns;
//   auto source_columns =
//       allocate_slice_output_columns<ColumnType>(output_columns, indexes_host);
  
//   // Perform test
//   ASSERT_ANY_THROW(cudf::slice(nullptr, static_cast<gdf_index_type*>(indexes.get()->data), indexes.get()->size, source_columns));
// }

// TEST_F(SliceInputTest, OutputColumnNull) {
//   const int SIZE = 32;
//   using ColumnType = std::int32_t;

//   // Create input column
//   auto input_column = create_random_column<ColumnType>(SIZE);

//   // Create indexes
//   std::vector<gdf_index_type> indexes_host{SIZE / 4, SIZE / 2};
//   cudf::test::column_wrapper<gdf_index_type> indexes(indexes_host);

//   std::vector<gdf_column*> source_columns;

//   // Perform test
//   ASSERT_ANY_THROW(cudf::slice(input_column.get(), static_cast<gdf_index_type*>(indexes.get()->data), indexes.get()->size, source_columns));
// }

// TEST_F(SliceInputTest, InputColumnSizeNull) {
//   const int SIZE = 32;
//   using ColumnType = std::int32_t;

//   // Create input column
//   gdf_column input_column;
//   input_column.size = 0;

//   // Create indexes
//   std::vector<gdf_index_type> indexes_host{SIZE / 4, SIZE / 2};
//   cudf::test::column_wrapper<gdf_index_type> indexes(indexes_host);

//   // Create output
//   gdf_column column;
//   gdf_column* source_columns[1] = { &column };
//   cudf::column_array column_array(source_columns, 1);

//   // Perform test
//   ASSERT_NO_THROW(cudf::slice(&input_column, indexes.get(), &column_array));
// }

// TEST_F(SliceInputTest, IndexesDataNull) {
//   const int SIZE = 32;
//   using ColumnType = std::int32_t;

//   // Create input column
//   auto input_column = create_random_column<ColumnType>(SIZE);

//   // Create indexes
//   std::vector<gdf_index_type> indexes_host{SIZE / 4, SIZE / 2};
//   cudf::test::column_wrapper<gdf_index_type> indexes(indexes_host);
//   gdf_column* indexes_test = indexes.get();
//   indexes_test->data = nullptr;

//   // Create output
//   std::vector<std::shared_ptr<cudf::test::column_wrapper<ColumnType>>> output_columns;
//   auto source_columns =
//       allocate_slice_output_columns<ColumnType>(output_columns, indexes_host);
//   cudf::column_array column_array(source_columns.data(), source_columns.size());

//   // Perform test
//   ASSERT_ANY_THROW(cudf::slice(input_column.get(), indexes_test, &column_array));
// }

// TEST_F(SliceInputTest, InputColumnDataNull) {
//   const int SIZE = 32;
//   using ColumnType = std::int32_t;

//   // Create input column
//   auto input_column = create_random_column<ColumnType>(SIZE);
//   gdf_column* input_column_test = input_column.get();
//   input_column_test->data = nullptr;

//   // Create indexes
//   std::vector<gdf_index_type> indexes_host{SIZE / 4, SIZE / 2};
//   cudf::test::column_wrapper<gdf_index_type> indexes(indexes_host);

//   // Create output
//   std::vector<std::shared_ptr<cudf::test::column_wrapper<ColumnType>>> output_columns;
//   auto source_columns =
//       allocate_slice_output_columns<ColumnType>(output_columns, indexes_host);
//   cudf::column_array column_array(source_columns.data(), source_columns.size());

//   // Perform test
//   ASSERT_ANY_THROW(cudf::slice(input_column_test, indexes.get(), &column_array));
// }

// TEST_F(SliceInputTest, InputColumnBitmaskNull) {
//   const int SIZE = 32;
//   using ColumnType = std::int32_t;

//   // Create input column
//   auto input_column = create_random_column<ColumnType>(SIZE);
//   gdf_column* input_column_test = input_column.get();
//   input_column_test->valid = nullptr;

//   // Create indexes
//   std::vector<gdf_index_type> indexes_host{SIZE / 4, SIZE / 2};
//   cudf::test::column_wrapper<gdf_index_type> indexes(indexes_host);

//   // Create output
//   std::vector<std::shared_ptr<cudf::test::column_wrapper<ColumnType>>> output_columns;
//   auto source_columns =
//       allocate_slice_output_columns<ColumnType>(output_columns, indexes_host);
//   cudf::column_array column_array(source_columns.data(), source_columns.size());

//   // Perform test
//   ASSERT_ANY_THROW(cudf::slice(input_column_test, indexes.get(), &column_array));
// }

// TEST_F(SliceInputTest, IndexesSizeNotEven) {
//   const int SIZE = 32;
//   using ColumnType = std::int32_t;

//   // Create input column
//   auto input_column = create_random_column<ColumnType>(SIZE);

//   // Create indexes
//   std::vector<gdf_index_type> indexes_host{SIZE / 4, SIZE / 2};

//   // Create indexes for test
//   std::vector<gdf_index_type> indexes_host_test{SIZE / 4, SIZE / 3, SIZE / 2};
//   cudf::test::column_wrapper<gdf_index_type> indexes_test(indexes_host_test);

//   // Create output
//   std::vector<std::shared_ptr<cudf::test::column_wrapper<ColumnType>>> output_columns;
//   auto source_columns =
//       allocate_slice_output_columns<ColumnType>(output_columns, indexes_host);
//   cudf::column_array column_array(source_columns.data(), source_columns.size());

//   // Perform test
//   ASSERT_ANY_THROW(cudf::slice(input_column.get(), indexes_test.get(), &column_array));
// }

// TEST_F(SliceInputTest, OutputColumnsAndIndexesSizeMismatch) {
//   const int SIZE = 32;
//   using ColumnType = std::int32_t;

//   // Create input column
//   auto input_column = create_random_column<ColumnType>(SIZE);

//   // Create indexes
//   std::vector<gdf_index_type> indexes_host{SIZE / 4, SIZE / 2};
//   cudf::test::column_wrapper<gdf_index_type> indexes(indexes_host);

//   // Create indexes for test
//   std::vector<gdf_index_type> indexes_host_test{SIZE / 5, SIZE / 4, SIZE / 3, SIZE / 2};
//   cudf::test::column_wrapper<gdf_index_type> indexes_test(indexes_host_test);

//   // Create output
//   std::vector<std::shared_ptr<cudf::test::column_wrapper<ColumnType>>> output_columns;
//   auto source_columns =
//       allocate_slice_output_columns<ColumnType>(output_columns, indexes_host);
//   cudf::column_array column_array(source_columns.data(), source_columns.size());

//   // Perform test
//   ASSERT_ANY_THROW(cudf::slice(input_column.get(), indexes_test.get(), &column_array));
// }


template <typename ColumnType>
struct SliceTest : GdfTest {};

using test_types =
    ::testing::Types<int8_t, int16_t, int32_t, int64_t, float, double>;
TYPED_TEST_CASE(SliceTest, test_types);

/**
 * It performs a parameterized type test, where the array of indices contains
 * multiple values.
 *
 * It tests:
 * when the indices are the same.
 * when is less than 16, less than 64 or greater than 64.
 */
TYPED_TEST(SliceTest, MultipleSlices) {
  // Create input column
  auto input_column = create_random_column<TypeParam>(INPUT_SIZE);

  // Create indexes
  std::vector<gdf_index_type> indexes_host{7, 13, 17, 37, 43, 43, 17, INPUT_SIZE};
  cudf::test::column_wrapper<gdf_index_type> indexes(indexes_host);

  // Perform operation
  std::vector<gdf_column*> output_column_ptrs = cudf::slice(input_column.get(), static_cast<gdf_index_type*>(indexes.get()->data), indexes.get()->size);

  // Transfer input column to host
  std::vector<TypeParam> input_col_data;
  std::vector<gdf_valid_type> input_col_bitmask;
  std::tie(input_col_data, input_col_bitmask) = input_column.to_host();
  
  // Perform split in cpu
  std::vector<std::vector<TypeParam>> output_cols_data;
  std::vector<std::vector<gdf_valid_type>> output_cols_bitmask;
  std::vector<gdf_size_type> output_cols_null_count;
  std::tie(output_cols_data, output_cols_bitmask, output_cols_null_count) = slice_columns<TypeParam>(input_col_data, 
                                                                              input_col_bitmask, indexes_host);

  // Create Validation output column_wrappers
  std::vector<cudf::test::column_wrapper<TypeParam>> validation_columns;
  for (std::size_t i = 0; i < output_column_ptrs.size(); i++){
    validation_columns.emplace_back(cudf::test::column_wrapper<TypeParam>(output_cols_data[i], output_cols_bitmask[i]));    
    ASSERT_EQ(validation_columns[i].null_count(), output_cols_null_count[i]);
  }

  // Verify the operation
  for (std::size_t i = 0; i < validation_columns.size(); ++i) {
    if (validation_columns[i].size() > 0 && output_column_ptrs[i]->size > 0)
      ASSERT_TRUE(validation_columns[i] == *(output_column_ptrs[i]));
  }

  for (std::size_t i = 0; i < output_column_ptrs.size(); i++){
    gdf_column_free(output_column_ptrs[i]);
    delete output_column_ptrs[i];
  }
}

/**
 * It performs a parameterized type and a parameterized value test. The
 * indices array contains only two values with a fixed length between them.
 * The interval iterates over all the values in the input column.
 */
TYPED_TEST(SliceTest, RangeIndexPosition) {
  // Test parameters
  constexpr gdf_index_type INIT_INDEX{0};
  constexpr gdf_index_type SLICE_RANGE{37};
  constexpr gdf_index_type FINAL_INDEX{INPUT_SIZE - SLICE_RANGE};

  // Create input column
  auto input_column = create_random_column<TypeParam>(INPUT_SIZE);
  for (gdf_index_type index = INIT_INDEX; index < FINAL_INDEX; ++index) {
    // Create indexes
    std::vector<gdf_index_type> indexes_host{index, index + SLICE_RANGE};
    cudf::test::column_wrapper<gdf_index_type> indexes(indexes_host);
    
    // Perform operation
    std::vector<gdf_column*> output_column_ptrs = cudf::slice(input_column.get(), static_cast<gdf_index_type*>(indexes.get()->data), indexes.get()->size);

    // Transfer input column to host
    std::vector<TypeParam> input_col_data;
    std::vector<gdf_valid_type> input_col_bitmask;
    std::tie(input_col_data, input_col_bitmask) = input_column.to_host();

    // Perform split in cpu
    std::vector<std::vector<TypeParam>> output_cols_data;
    std::vector<std::vector<gdf_valid_type>> output_cols_bitmask;
    std::vector<gdf_size_type> output_cols_null_count;
    std::tie(output_cols_data, output_cols_bitmask, output_cols_null_count) = slice_columns<TypeParam>(input_col_data, 
                                                                                input_col_bitmask, indexes_host);
    
    // Create Validation output column_wrappers
    std::vector<cudf::test::column_wrapper<TypeParam>> validation_columns;
    for (std::size_t i = 0; i < output_column_ptrs.size(); i++){
      validation_columns.emplace_back(cudf::test::column_wrapper<TypeParam>(output_cols_data[i], output_cols_bitmask[i]));    
      ASSERT_EQ(validation_columns[i].null_count(), output_cols_null_count[i]);
    }

    // Verify the operation
    for (std::size_t i = 0; i < validation_columns.size(); ++i) {
      if (validation_columns[i].size() > 0 && output_column_ptrs[i]->size > 0)
        ASSERT_TRUE(validation_columns[i] == *(output_column_ptrs[i]));
    }

    for (std::size_t i = 0; i < output_column_ptrs.size(); i++){
      gdf_column_free(output_column_ptrs[i]);
      delete output_column_ptrs[i];
    }
  }
}
