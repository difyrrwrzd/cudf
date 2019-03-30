#include "gtest/gtest.h"
#include "copying.hpp"
#include "tests/utilities/cudf_test_fixtures.h"
#include "tests/copying/copying_test_helper.hpp"

struct SliceInputTest : GdfTest {};

TEST_F(SliceInputTest, IndexesNull) {
  const int SIZE = 32;
  using ColumnType = std::int32_t;

  // Create input column
  auto input_column = create_random_column<ColumnType>(SIZE);

  // Create indexes
  std::vector<gdf_index_type> indexes_host{SIZE / 4, SIZE / 2};

  // Create output
  std::vector<std::shared_ptr<cudf::test::column_wrapper<ColumnType>>> output_columns;
  auto source_columns =
      allocate_slice_output_columns<ColumnType>(output_columns, indexes_host);
  cudf::column_array column_array(source_columns.data(), source_columns.size());

  // Perform test
  ASSERT_ANY_THROW(cudf::slice(input_column.get(), nullptr, &column_array));
}

TEST_F(SliceInputTest, InputColumnNull) {
  const int SIZE = 32;
  using ColumnType = std::int32_t;

  // Create indexes
  std::vector<gdf_index_type> indexes_host{SIZE / 4, SIZE / 2};
  cudf::test::column_wrapper<gdf_index_type> indexes(indexes_host);

  // Create output
  std::vector<std::shared_ptr<cudf::test::column_wrapper<ColumnType>>> output_columns;
  auto source_columns =
      allocate_slice_output_columns<ColumnType>(output_columns, indexes_host);
  cudf::column_array column_array(source_columns.data(), source_columns.size());

  // Perform test
  ASSERT_ANY_THROW(cudf::slice(nullptr, indexes.get(), &column_array));
}

TEST_F(SliceInputTest, OutputColumnNull) {
  const int SIZE = 32;
  using ColumnType = std::int32_t;

  // Create input column
  auto input_column = create_random_column<ColumnType>(SIZE);

  // Create indexes
  std::vector<gdf_index_type> indexes_host{SIZE / 4, SIZE / 2};
  cudf::test::column_wrapper<gdf_index_type> indexes(indexes_host);

  // Perform test
  ASSERT_ANY_THROW(cudf::slice(input_column.get(), indexes.get(), nullptr));
}

TEST_F(SliceInputTest, IndexesSizeNull) {
  const int SIZE = 32;
  using ColumnType = std::int32_t;

  // Create input column
  auto input_column = create_random_column<ColumnType>(SIZE);

  // Create indexes
  gdf_column indexes;
  indexes.size = 0;

  // Create output
  gdf_column column;
  gdf_column* source_columns[1] = { &column };
  cudf::column_array column_array(source_columns, 1);

  // Perform test
  ASSERT_NO_THROW(cudf::slice(input_column.get(), &indexes, &column_array));
}

TEST_F(SliceInputTest, InputColumnSizeNull) {
  const int SIZE = 32;
  using ColumnType = std::int32_t;

  // Create input column
  gdf_column input_column;
  input_column.size = 0;

  // Create indexes
  std::vector<gdf_index_type> indexes_host{SIZE / 4, SIZE / 2};
  cudf::test::column_wrapper<gdf_index_type> indexes(indexes_host);

  // Create output
  gdf_column column;
  gdf_column* source_columns[1] = { &column };
  cudf::column_array column_array(source_columns, 1);

  // Perform test
  ASSERT_NO_THROW(cudf::slice(&input_column, indexes.get(), &column_array));
}

TEST_F(SliceInputTest, IndexesDataNull) {
  const int SIZE = 32;
  using ColumnType = std::int32_t;

  // Create input column
  auto input_column = create_random_column<ColumnType>(SIZE);

  // Create indexes
  std::vector<gdf_index_type> indexes_host{SIZE / 4, SIZE / 2};
  cudf::test::column_wrapper<gdf_index_type> indexes(indexes_host);
  gdf_column* indexes_test = indexes.get();
  indexes_test->data = nullptr;

  // Create output
  std::vector<std::shared_ptr<cudf::test::column_wrapper<ColumnType>>> output_columns;
  auto source_columns =
      allocate_slice_output_columns<ColumnType>(output_columns, indexes_host);
  cudf::column_array column_array(source_columns.data(), source_columns.size());

  // Perform test
  ASSERT_ANY_THROW(cudf::slice(input_column.get(), indexes_test, &column_array));
}

TEST_F(SliceInputTest, InputColumnDataNull) {
  const int SIZE = 32;
  using ColumnType = std::int32_t;

  // Create input column
  auto input_column = create_random_column<ColumnType>(SIZE);
  gdf_column* input_column_test = input_column.get();
  input_column_test->data = nullptr;

  // Create indexes
  std::vector<gdf_index_type> indexes_host{SIZE / 4, SIZE / 2};
  cudf::test::column_wrapper<gdf_index_type> indexes(indexes_host);

  // Create output
  std::vector<std::shared_ptr<cudf::test::column_wrapper<ColumnType>>> output_columns;
  auto source_columns =
      allocate_slice_output_columns<ColumnType>(output_columns, indexes_host);
  cudf::column_array column_array(source_columns.data(), source_columns.size());

  // Perform test
  ASSERT_ANY_THROW(cudf::slice(input_column_test, indexes.get(), &column_array));
}

TEST_F(SliceInputTest, InputColumnBitmaskNull) {
  const int SIZE = 32;
  using ColumnType = std::int32_t;

  // Create input column
  auto input_column = create_random_column<ColumnType>(SIZE);
  gdf_column* input_column_test = input_column.get();
  input_column_test->valid = nullptr;

  // Create indexes
  std::vector<gdf_index_type> indexes_host{SIZE / 4, SIZE / 2};
  cudf::test::column_wrapper<gdf_index_type> indexes(indexes_host);

  // Create output
  std::vector<std::shared_ptr<cudf::test::column_wrapper<ColumnType>>> output_columns;
  auto source_columns =
      allocate_slice_output_columns<ColumnType>(output_columns, indexes_host);
  cudf::column_array column_array(source_columns.data(), source_columns.size());

  // Perform test
  ASSERT_ANY_THROW(cudf::slice(input_column_test, indexes.get(), &column_array));
}

TEST_F(SliceInputTest, IndexesSizeNotEven) {
  const int SIZE = 32;
  using ColumnType = std::int32_t;

  // Create input column
  auto input_column = create_random_column<ColumnType>(SIZE);

  // Create indexes
  std::vector<gdf_index_type> indexes_host{SIZE / 4, SIZE / 2};

  // Create indexes for test
  std::vector<gdf_index_type> indexes_host_test{SIZE / 4, SIZE / 3, SIZE / 2};
  cudf::test::column_wrapper<gdf_index_type> indexes_test(indexes_host_test);

  // Create output
  std::vector<std::shared_ptr<cudf::test::column_wrapper<ColumnType>>> output_columns;
  auto source_columns =
      allocate_slice_output_columns<ColumnType>(output_columns, indexes_host);
  cudf::column_array column_array(source_columns.data(), source_columns.size());

  // Perform test
  ASSERT_ANY_THROW(cudf::slice(input_column.get(), indexes_test.get(), &column_array));
}

TEST_F(SliceInputTest, OutputColumnsAndIndexesSizeMismatch) {
  const int SIZE = 32;
  using ColumnType = std::int32_t;

  // Create input column
  auto input_column = create_random_column<ColumnType>(SIZE);

  // Create indexes
  std::vector<gdf_index_type> indexes_host{SIZE / 4, SIZE / 2};
  cudf::test::column_wrapper<gdf_index_type> indexes(indexes_host);

  // Create indexes for test
  std::vector<gdf_index_type> indexes_host_test{SIZE / 5, SIZE / 4, SIZE / 3, SIZE / 2};
  cudf::test::column_wrapper<gdf_index_type> indexes_test(indexes_host_test);

  // Create output
  std::vector<std::shared_ptr<cudf::test::column_wrapper<ColumnType>>> output_columns;
  auto source_columns =
      allocate_slice_output_columns<ColumnType>(output_columns, indexes_host);
  cudf::column_array column_array(source_columns.data(), source_columns.size());

  // Perform test
  ASSERT_ANY_THROW(cudf::slice(input_column.get(), indexes_test.get(), &column_array));
}


template <typename ColumnType>
struct SliceTest : GdfTest {};

using test_types =
    ::testing::Types<int8_t, int16_t, int32_t, int64_t, float, double>;
TYPED_TEST_CASE(SliceTest, test_types);

/**
 *
 */
TYPED_TEST(SliceTest, MultipleSlices) {
  // Create input column
  auto input_column = create_random_column<TypeParam>(INPUT_SIZE);

  // Create indexes
  std::vector<gdf_index_type> indexes_host{7, 13, 17, 37, 43, 43, 17, INPUT_SIZE};
  cudf::test::column_wrapper<gdf_index_type> indexes(indexes_host);

  // Create output
  std::vector<std::shared_ptr<cudf::test::column_wrapper<TypeParam>>> output_columns;
  auto source_columns =
      allocate_slice_output_columns<TypeParam>(output_columns, indexes_host);
  cudf::column_array column_array(source_columns.data(), source_columns.size());

  // Perform operation
  ASSERT_NO_THROW(cudf::slice(input_column.get(), indexes.get(), &column_array));

  // Transfer input column to host
  auto input_column_host = makeHelperColumn<TypeParam>(input_column);

  // Transfer output columns to host
  auto output_column_host = makeHelperColumn<TypeParam>(output_columns);

  // Perform split in cpu
  auto output_column_cpu = slice_columns<TypeParam>(input_column_host,
                                                    indexes_host);

  // Verify the operation
  for (std::size_t i = 0; i < output_column_host.size(); ++i) {
    verify<TypeParam>(output_column_cpu[i], output_column_host[i]);
  }
}

/**
 *
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
    
    // Create output
    std::vector<std::shared_ptr<cudf::test::column_wrapper<TypeParam>>> output_columns;
    auto source_columns =
        allocate_slice_output_columns<TypeParam>(output_columns, indexes_host);
    cudf::column_array column_array(source_columns.data(), source_columns.size());
    
    // Perform operation
    ASSERT_NO_THROW(cudf::slice(input_column.get(), indexes.get(), &column_array));

    // Transfer input column to host
    auto input_column_host = makeHelperColumn<TypeParam>(input_column);

    // Transfer output columns to host
    auto output_column_host = makeHelperColumn<TypeParam>(output_columns);

    // Perform split in cpu
    auto output_column_cpu = slice_columns<TypeParam>(input_column_host,
                                                      indexes_host);

    // Verify columns
    for (std::size_t i = 0; i < output_column_host.size(); ++i) {
      verify<TypeParam>(output_column_cpu[i], output_column_host[i]);
    }
  }
}
