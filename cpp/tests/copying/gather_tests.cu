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

#include "copying.hpp"
#include "types.hpp"

#include "gmock/gmock.h"
#include "gtest/gtest.h"
#include "tests/utilities/column_wrapper.cuh"
#include "tests/utilities/cudf_test_fixtures.h"
#include "tests/utilities/cudf_test_utils.cuh"
#include "types.hpp"

struct GatherTest : GdfTest {};

TEST_F(GatherTest, IdentityTest) {
  constexpr gdf_size_type source_size{1000};
  constexpr gdf_size_type destination_size{1000};

  cudf::test::column_wrapper<int32_t> source_column{
      source_size, [](gdf_index_type row) { return row; },
      [](gdf_index_type row) { return true; }};

  thrust::device_vector<gdf_index_type> gather_map(destination_size);
  thrust::sequence(gather_map.begin(), gather_map.end());

  cudf::test::column_wrapper<int32_t> destination_column(destination_size);

  gdf_column* raw_source = source_column.get();
  gdf_column* raw_destination = destination_column.get();

  cudf::table source_table{&raw_source, 1};
  cudf::table destination_table{&raw_destination, 1};

  cudf::gather(&source_table, gather_map.data().get(), &destination_table);

  EXPECT_TRUE(source_column == destination_column);
}

TEST_F(GatherTest, ReverseIdentityTest) {
  constexpr gdf_size_type source_size{1000};
  constexpr gdf_size_type destination_size{1000};

  static_assert(source_size == destination_size, "Source and destination columns must be the same size.");

  cudf::test::column_wrapper<int32_t> source_column{
      source_size, [](gdf_index_type row) { return row; },
      [](gdf_index_type row) { return true; }};

  // Create gather_map that reverses order of source_column
  std::vector<gdf_index_type> host_gather_map(source_size);
  std::iota(host_gather_map.begin(), host_gather_map.end(), 0);
  std::reverse(host_gather_map.begin(), host_gather_map.end());
  thrust::device_vector<gdf_index_type> gather_map(host_gather_map);

  cudf::test::column_wrapper<int32_t> destination_column(destination_size);

  gdf_column* raw_source = source_column.get();
  gdf_column* raw_destination = destination_column.get();

  cudf::table source_table{&raw_source, 1};
  cudf::table destination_table{&raw_destination, 1};

  cudf::gather(&source_table, gather_map.data().get(), &destination_table);

  // Expected result is the reversal of the source column
  std::vector<int32_t> expected_data;
  std::vector<gdf_valid_type> expected_bitmask;
  std::tie(expected_data, expected_bitmask) = source_column.to_host();
  std::reverse(expected_data.begin(), expected_data.end());

  // Copy result of destination column to host
  std::vector<int32_t> result_data;
  std::vector<gdf_valid_type> result_bitmask;
  std::tie(result_data, result_bitmask) = destination_column.to_host();

  for (gdf_index_type i = 0; i < destination_size; i++) {
    EXPECT_EQ(expected_data[i], result_data[i])
        << "Data at index " << i << " doesn't match!\n";
    EXPECT_TRUE(gdf_is_valid(result_bitmask.data(), i))
        << "Value at index " << i << " should be non-null!\n";
  }
}

TEST_F(GatherTest, AllNull) {
  constexpr gdf_size_type source_size{1000};
  constexpr gdf_size_type destination_size{1000};

  // source column has all null values
  cudf::test::column_wrapper<int32_t> source_column{
      source_size, [](gdf_index_type row) { return row; },
      [](gdf_index_type row) { return false; }};

  // Create gather_map that gathers to random locations
  std::vector<gdf_index_type> host_gather_map(source_size);
  std::iota(host_gather_map.begin(), host_gather_map.end(), 0);
  std::mt19937 g(0);
  std::shuffle(host_gather_map.begin(), host_gather_map.end(), g);
  thrust::device_vector<gdf_index_type> gather_map(host_gather_map);

  cudf::test::column_wrapper<int32_t> destination_column(destination_size);

  gdf_column* raw_source = source_column.get();
  gdf_column* raw_destination = destination_column.get();

  cudf::table source_table{&raw_source, 1};
  cudf::table destination_table{&raw_destination, 1};

  cudf::gather(&source_table, gather_map.data().get(), &destination_table);

  // Copy result of destination column to host
  std::vector<int32_t> result_data;
  std::vector<gdf_valid_type> result_bitmask;
  std::tie(result_data, result_bitmask) = destination_column.to_host();

  // All values of result should be null
  for (gdf_index_type i = 0; i < destination_size; i++) {
    EXPECT_FALSE(gdf_is_valid(result_bitmask.data(), i))
        << "Value at index " << i << " should be null!\n";
  }
}

TEST_F(GatherTest, EveryOtherNull) {
  constexpr gdf_size_type source_size{1000};
  constexpr gdf_size_type destination_size{1000};

  static_assert(0 == source_size % 2,
                "Size of source data must be a multiple of 2.");
  static_assert(source_size == destination_size,
                "Source and destination columns must be equal size.");

  // elements with even indices are null
  cudf::test::column_wrapper<int32_t> source_column{
      source_size, [](gdf_index_type row) { return row; },
      [](gdf_index_type row) { return row % 2; }};

  // Scatter null values to the last half of the destination column
  std::vector<gdf_index_type> host_gather_map(source_size);
  gdf_size_type counter{0};
  for (gdf_size_type i = 0; i < source_size; ++i) {
    bool const is_even{0 == i % 2};
    host_gather_map[i] =
        is_even ? ((destination_size / 2) + counter) : counter;
    if (i % 2) counter++;
  }
  thrust::device_vector<gdf_index_type> gather_map(host_gather_map);

  cudf::test::column_wrapper<int32_t> destination_column(destination_size);

  gdf_column* raw_source = source_column.get();
  gdf_column* raw_destination = destination_column.get();

  cudf::table source_table{&raw_source, 1};
  cudf::table destination_table{&raw_destination, 1};

  cudf::gather(&source_table, gather_map.data().get(), &destination_table);

  // Copy result of destination column to host
  std::vector<int32_t> result_data;
  std::vector<gdf_valid_type> result_bitmask;
  std::tie(result_data, result_bitmask) = destination_column.to_host();

  // All values of result should be null
  for (gdf_index_type i = 0; i < destination_size; i++) {
    // The first half of the destination column should be all valid 
    // and values should be 1, 3, 5, 7, etc.
    if (i < destination_size / 2) {
      EXPECT_TRUE(gdf_is_valid(result_bitmask.data(), i))
          << "Value at index " << i << " should be non-null!\n";
      EXPECT_EQ(1 + i*2,result_data[i]);
    } else {
      EXPECT_FALSE(gdf_is_valid(result_bitmask.data(), i))
          << "Value at index " << i << " should be null!\n";
    }
  }
}