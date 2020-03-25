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

#include <cudf/types.hpp>
#include <cudf/datetime.hpp>
#include <cudf/null_mask.hpp>
#include <cudf/utilities/traits.hpp>
#include <cudf/column/column.hpp>
#include <cudf/column/column_view.hpp>
#include <cudf/detail/nvtx/ranges.hpp>

#include <rmm/thrust_rmm_allocator.h>

namespace cudf {
namespace datetime {
namespace detail {

template <datetime_component Component>
struct extract_component_operator {
  template <typename Timestamp>
  CUDA_DEVICE_CALLABLE int16_t operator()(Timestamp const ts) const {
    using namespace simt::std::chrono;

    auto days_since_epoch = floor<days>(ts);

    auto time_since_midnight = ts - days_since_epoch;

    if (time_since_midnight.count() < 0) {
      time_since_midnight += days(1);
    }

    auto hrs_ = duration_cast<hours>(time_since_midnight);
    auto mins_ = duration_cast<minutes>(time_since_midnight - hrs_);
    auto secs_ = duration_cast<seconds>(time_since_midnight - hrs_ - mins_);

    switch (Component) {
      case datetime_component::YEAR:
        return static_cast<int>(year_month_day(days_since_epoch).year());
      case datetime_component::MONTH:
        return static_cast<unsigned>(year_month_day(days_since_epoch).month());
      case datetime_component::DAY:
        return static_cast<unsigned>(year_month_day(days_since_epoch).day());
      case datetime_component::WEEKDAY:
        return year_month_weekday(days_since_epoch).weekday().iso_encoding();
      case datetime_component::HOUR:
        return hrs_.count();
      case datetime_component::MINUTE:
        return mins_.count();
      case datetime_component::SECOND:
        return secs_.count();
      default:
        return 0;
    }
  }
};

// Round up the date to the last day of the mont and return the
// date only (without the time component)
struct extract_last_day {
  template <typename Timestamp>
  CUDA_DEVICE_CALLABLE timestamp_D operator()(Timestamp const ts) const {
    using namespace simt::std::chrono;
    // IDEAL: does not work with CUDA10.0 due to nvcc compiler bug
    // cannot invoke ym_last_day.day()
    //const year_month_day orig_ymd(floor<days>(ts));
    //const year_month_day_last ym_last_day(orig_ymd.year(), month_day_last(orig_ymd.month()));
    //return timestamp_D(sys_days(ym_last_day));

    // Only has the days - time component is chopped off, which is what we want
    auto days_since_epoch = floor<days>(ts);

    const auto chrono_year = year_month_day(days_since_epoch).year();

    const auto chrono_month = year_month_day(days_since_epoch).month();
    const unsigned month_val = static_cast<unsigned>(chrono_month);

    static const uint8_t days_in_month[] = {31, 28, 31, 30, 31, 30,
                                            31, 31, 30, 31, 30, 31};
    day chrono_day(days_in_month[month_val - 1]);
    // Handle leap years
    if (chrono_month == month(February) && chrono_year.is_leap()) {
      chrono_day++;
    }
    unsigned orig_day(year_month_day(days_since_epoch).day());
    unsigned new_day(chrono_day);
    days_since_epoch += days(new_day - orig_day);

    return timestamp_D(days_since_epoch);
  }
};

// Apply the functor for every element/row in the input column to create the output column
template <typename TransformFunctor, typename OutputColT>
struct launch_functor {
  column_view input;
  mutable_column_view output;

  launch_functor(column_view inp, mutable_column_view out)
      : input(inp), output(out) {}

  template <typename Element>
  typename std::enable_if_t<!cudf::is_timestamp_t<Element>::value, void>
  operator()(cudaStream_t stream) const {
    CUDF_FAIL("Cannot extract datetime component from non-timestamp column.");
  }

  template <typename Timestamp>
  typename std::enable_if_t<cudf::is_timestamp_t<Timestamp>::value, void>
  operator()(cudaStream_t stream) const {
    thrust::transform(rmm::exec_policy(stream)->on(stream),
                      input.begin<Timestamp>(), input.end<Timestamp>(),
                      output.begin<OutputColT>(),
                      TransformFunctor{});
  }
};

// Create an output column by applying the functor to every element from the input column
template <typename TransformFunctor, cudf::type_id OutputColCudfT>
std::unique_ptr<column> apply_datetime_op(column_view const& column,
                                          cudaStream_t stream,
                                          rmm::mr::device_memory_resource* mr) {
  auto size = column.size();
  auto output_col_type = data_type{OutputColCudfT};
  auto null_mask = copy_bitmask(column, stream, mr);
  auto output = std::make_unique<cudf::column>(
      output_col_type, size, rmm::device_buffer{size * cudf::size_of(output_col_type), stream, mr},
      null_mask, column.null_count(),
      std::vector<std::unique_ptr<cudf::column>>{});

  auto launch = launch_functor<TransformFunctor,
                               typename cudf::experimental::id_to_type_impl<OutputColCudfT>::type>
      {column, static_cast<mutable_column_view>(*output)};

  experimental::type_dispatcher(column.type(), launch, stream);

  return output;
}

}  // namespace detail

std::unique_ptr<column> extract_year(column_view const& column,
                                     rmm::mr::device_memory_resource* mr) {
  CUDF_FUNC_RANGE();
  return detail::apply_datetime_op<
      detail::extract_component_operator<detail::datetime_component::YEAR>, cudf::INT16>
      (column, 0, mr);
}

std::unique_ptr<column> extract_month(column_view const& column,
                                      rmm::mr::device_memory_resource* mr) {
  CUDF_FUNC_RANGE();

  return detail::apply_datetime_op<
      detail::extract_component_operator<detail::datetime_component::MONTH>, cudf::INT16>
      (column, 0, mr);
}

std::unique_ptr<column> extract_day(column_view const& column,
                                    rmm::mr::device_memory_resource* mr) {
  CUDF_FUNC_RANGE();
  return detail::apply_datetime_op<
      detail::extract_component_operator<detail::datetime_component::DAY>, cudf::INT16>
      (column, 0, mr);
}

std::unique_ptr<column> extract_weekday(column_view const& column,
                                        rmm::mr::device_memory_resource* mr) {
  CUDF_FUNC_RANGE();
  return detail::apply_datetime_op<
      detail::extract_component_operator<detail::datetime_component::WEEKDAY>, cudf::INT16>
      (column, 0, mr);
}

std::unique_ptr<column> extract_hour(column_view const& column,
                                     rmm::mr::device_memory_resource* mr) {
  CUDF_FUNC_RANGE();
  return detail::apply_datetime_op<
      detail::extract_component_operator<detail::datetime_component::HOUR>, cudf::INT16>
      (column, 0, mr);
}

std::unique_ptr<column> extract_minute(column_view const& column,
                                       rmm::mr::device_memory_resource* mr) {
  CUDF_FUNC_RANGE();
  return detail::apply_datetime_op<
      detail::extract_component_operator<detail::datetime_component::MINUTE>, cudf::INT16>
      (column, 0, mr);
}

std::unique_ptr<column> extract_second(column_view const& column,
                                       rmm::mr::device_memory_resource* mr) {
  CUDF_FUNC_RANGE();
  return detail::apply_datetime_op<
      detail::extract_component_operator<detail::datetime_component::SECOND>, cudf::INT16>
      (column, 0, mr);
}

std::unique_ptr<column> last_day(column_view const& column,
                                 rmm::mr::device_memory_resource* mr) {
  CUDF_FUNC_RANGE();
  return detail::apply_datetime_op<detail::extract_last_day, cudf::TIMESTAMP_DAYS>
      (column, 0, mr);
}

}  // namespace datetime
}  // namespace cudf
