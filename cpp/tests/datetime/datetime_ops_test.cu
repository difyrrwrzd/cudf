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

#include <cudf/datetime.hpp>
#include <cudf/utilities/chrono.hpp>
#include <cudf/column/column_view.hpp>
#include <cudf/column/column_factories.hpp>

#include <tests/utilities/type_lists.hpp>
#include <tests/utilities/base_fixture.hpp>
#include <tests/utilities/column_wrapper.hpp>
#include <tests/utilities/column_utilities.hpp>
#include <tests/utilities/timestamp_utilities.cuh>

#include <tests/utilities/legacy/cudf_test_utils.cuh>

#include <gmock/gmock.h>

template <typename T>
struct DatetimeOpsTest : public cudf::test::BaseFixture {
  cudaStream_t stream() { return cudaStream_t(0); }
  cudf::size_type size() { return cudf::size_type(10); }
  cudf::data_type type() { return cudf::data_type{cudf::experimental::type_to_id<T>()}; }
};

template <typename Element>
void print_column(cudf::column_view col) {
  print_typed_column<Element>(
    col.data<Element>(),
    (gdf_valid_type*) col.null_mask(),
    col.size(),
    1);
}

TYPED_TEST_CASE(DatetimeOpsTest, cudf::test::TimestampTypes);

TYPED_TEST(DatetimeOpsTest, TestExtractingDatetimeComponents) {

  using namespace cudf::test;
  using namespace simt::std::chrono;

  auto test_timestamps_D = fixed_width_column_wrapper<cudf::timestamp_D>{
    cudf::timestamp_D{-1528}, // 1965-10-26
    cudf::timestamp_D{17716}, // 2018-07-04
    cudf::timestamp_D{19382}, // 2023-01-25
  };

  auto test_timestamps_s = fixed_width_column_wrapper<cudf::timestamp_s>{
		cudf::timestamp_s{-131968728}, // 1965-10-26 14:01:12
		cudf::timestamp_s{1530705600}, // 2018-07-04 12:00:00
		cudf::timestamp_s{1674631932}, // 2023-01-25 07:32:12
	};

  auto test_timestamps_ms = fixed_width_column_wrapper<cudf::timestamp_ms>{
		cudf::timestamp_ms{-131968727238}, // 1965-10-26 14:01:12.762
		cudf::timestamp_ms{1530705600000}, // 2018-07-04 12:00:00.000
		cudf::timestamp_ms{1674631932929}, // 2023-01-25 07:32:12.929
	};

  auto test_timestamps_D_view = static_cast<cudf::column_view>(test_timestamps_D);
  auto test_timestamps_s_view = static_cast<cudf::column_view>(test_timestamps_s);
  auto test_timestamps_ms_view = static_cast<cudf::column_view>(test_timestamps_ms);

  expect_columns_equal(*cudf::datetime::extract_year(test_timestamps_D_view), fixed_width_column_wrapper<int16_t>{1965, 2018, 2023});
  expect_columns_equal(*cudf::datetime::extract_year(test_timestamps_s_view), fixed_width_column_wrapper<int16_t>{1965, 2018, 2023});
  expect_columns_equal(*cudf::datetime::extract_year(test_timestamps_ms_view), fixed_width_column_wrapper<int16_t>{1965, 2018, 2023});

  expect_columns_equal(*cudf::datetime::extract_month(test_timestamps_D_view), fixed_width_column_wrapper<int16_t>{10, 7, 1});
  expect_columns_equal(*cudf::datetime::extract_month(test_timestamps_s_view), fixed_width_column_wrapper<int16_t>{10, 7, 1});
  expect_columns_equal(*cudf::datetime::extract_month(test_timestamps_ms_view), fixed_width_column_wrapper<int16_t>{10, 7, 1});

  expect_columns_equal(*cudf::datetime::extract_day(test_timestamps_D_view), fixed_width_column_wrapper<int16_t>{26, 4, 25});
  expect_columns_equal(*cudf::datetime::extract_day(test_timestamps_s_view), fixed_width_column_wrapper<int16_t>{26, 4, 25});
  expect_columns_equal(*cudf::datetime::extract_day(test_timestamps_ms_view), fixed_width_column_wrapper<int16_t>{26, 4, 25});

  expect_columns_equal(*cudf::datetime::extract_weekday(test_timestamps_D_view), fixed_width_column_wrapper<int16_t>{2, 3, 3});
  expect_columns_equal(*cudf::datetime::extract_weekday(test_timestamps_s_view), fixed_width_column_wrapper<int16_t>{2, 3, 3});
  expect_columns_equal(*cudf::datetime::extract_weekday(test_timestamps_ms_view), fixed_width_column_wrapper<int16_t>{2, 3, 3});

  expect_columns_equal(*cudf::datetime::extract_hour(test_timestamps_D_view), fixed_width_column_wrapper<int16_t>{0, 0, 0});
  expect_columns_equal(*cudf::datetime::extract_hour(test_timestamps_s_view), fixed_width_column_wrapper<int16_t>{14, 12, 7});
  expect_columns_equal(*cudf::datetime::extract_hour(test_timestamps_ms_view), fixed_width_column_wrapper<int16_t>{14, 12, 7});

  expect_columns_equal(*cudf::datetime::extract_minute(test_timestamps_D_view), fixed_width_column_wrapper<int16_t>{0, 0, 0});
  expect_columns_equal(*cudf::datetime::extract_minute(test_timestamps_s_view), fixed_width_column_wrapper<int16_t>{1, 0, 32});
  expect_columns_equal(*cudf::datetime::extract_minute(test_timestamps_ms_view), fixed_width_column_wrapper<int16_t>{1, 0, 32});

  expect_columns_equal(*cudf::datetime::extract_second(test_timestamps_D_view), fixed_width_column_wrapper<int16_t>{0, 0, 0});
  expect_columns_equal(*cudf::datetime::extract_second(test_timestamps_s_view), fixed_width_column_wrapper<int16_t>{12, 0, 12});
  expect_columns_equal(*cudf::datetime::extract_second(test_timestamps_ms_view), fixed_width_column_wrapper<int16_t>{12, 0, 12});

}

TYPED_TEST(DatetimeOpsTest, TestExtractingGeneratedDatetimeComponents) {

  using namespace cudf::test;
  using namespace simt::std::chrono;
  using Rep = typename TypeParam::rep;
  using Period = typename TypeParam::period;

  auto start = milliseconds(-2500000000000); // Sat, 11 Oct 1890 19:33:20 GMT
  auto stop_ = milliseconds( 2500000000000); // Mon, 22 Mar 2049 04:26:40 GMT
  auto test_timestamps = generate_timestamps<Rep, Period>(this->size(),
                                                          time_point_ms(start),
                                                          time_point_ms(stop_));

  auto timestamp_col = cudf::make_timestamp_column(this->type(), this->size(),
                                                   cudf::mask_state::UNALLOCATED,
                                                   this->stream(), this->mr());

  cudf::mutable_column_view timestamp_view = *timestamp_col;

  CUDA_TRY(cudaMemcpy(timestamp_view.data<Rep>(),
    thrust::raw_pointer_cast(test_timestamps.data()),
    test_timestamps.size() * sizeof(Rep), cudaMemcpyDefault));

  auto expected_years = fixed_width_column_wrapper<int16_t>{1890, 1906, 1922, 1938, 1954, 1970, 1985, 2001, 2017, 2033};
  auto expected_months = fixed_width_column_wrapper<int16_t>{10, 8, 6, 4, 2, 1, 11, 9, 7, 5};
  auto expected_days = fixed_width_column_wrapper<int16_t>{11, 16, 20, 24, 26, 1, 5, 9, 14, 18};
  auto expected_weekdays = fixed_width_column_wrapper<int16_t>{6, 4, 2, 7, 5, 4, 2, 7, 5, 3};
  auto expected_hours = fixed_width_column_wrapper<int16_t>{19, 20, 21, 22, 23, 0, 0, 1, 2, 3};
  auto expected_minutes = fixed_width_column_wrapper<int16_t>{33, 26, 20, 13, 6, 0, 53, 46, 40, 33};
  auto expected_seconds = fixed_width_column_wrapper<int16_t>{20, 40, 0, 20, 40, 0, 20, 40, 0, 20};

  // Special cases for timestamp_D: zero out the hh/mm/ss cols and +1 the expected weekdays
  if (std::is_same<TypeParam, cudf::timestamp_D>::value) {
    expected_days = fixed_width_column_wrapper<int16_t>{12, 17, 21, 25, 27, 1, 5, 9, 14, 18};
    expected_weekdays = fixed_width_column_wrapper<int16_t>{7, 5, 3, 1, 6, 4, 2, 7, 5, 3};
    expected_hours = fixed_width_column_wrapper<int16_t>{0, 0, 0, 0, 0, 0, 0, 0, 0, 0};
    expected_minutes = fixed_width_column_wrapper<int16_t>{0, 0, 0, 0, 0, 0, 0, 0, 0, 0};
    expected_seconds = fixed_width_column_wrapper<int16_t>{0, 0, 0, 0, 0, 0, 0, 0, 0, 0};
  }

  expect_columns_equal(*cudf::datetime::extract_year(timestamp_view), expected_years);
  expect_columns_equal(*cudf::datetime::extract_month(timestamp_view), expected_months);
  expect_columns_equal(*cudf::datetime::extract_day(timestamp_view), expected_days);
  expect_columns_equal(*cudf::datetime::extract_weekday(timestamp_view), expected_weekdays);
  expect_columns_equal(*cudf::datetime::extract_hour(timestamp_view), expected_hours);
  expect_columns_equal(*cudf::datetime::extract_minute(timestamp_view), expected_minutes);
  expect_columns_equal(*cudf::datetime::extract_second(timestamp_view), expected_seconds);
}
