#pragma once

#include <map>

#include <cudf/table/table.hpp>
#include <cudf/utilities/traits.hpp>

enum class type_group_id : int32_t {
  INTEGRAL = static_cast<int32_t>(cudf::type_id::NUM_TYPE_IDS),
  FLOATING_POINT,
  NUMERIC,
  TIMESTAMP,
  DURATION,
  FIXED_POINT,
  COMPOUND,
  NESTED,
};

enum class distribution_id : int8_t {
  UNIFORM,
  NORMAL,
  GEOMETRIC,
};
namespace {
template <typename T, std::enable_if_t<cudf::is_chrono<T>()>* = nullptr>
distribution_id default_distribution_id()
{
  return distribution_id::GEOMETRIC;
}

template <typename T,
          std::enable_if_t<!std::is_unsigned<T>::value && cudf::is_numeric<T>()>* = nullptr>
distribution_id default_distribution_id()
{
  return distribution_id::NORMAL;
}

template <typename T,
          std::enable_if_t<!std::is_same<T, bool>::value && std::is_unsigned<T>::value &&
                           cudf::is_numeric<T>()>* = nullptr>
distribution_id default_distribution_id()
{
  return distribution_id::GEOMETRIC;
}

template <typename T>
constexpr int64_t from_days(int64_t t)
{
  using ratio = std::ratio_divide<typename cudf::timestamp_D::period, typename T::period>;
  return t * ratio::num / ratio::den;
}

template <typename T, std::enable_if_t<cudf::is_timestamp<T>()>* = nullptr>
std::pair<int64_t, int64_t> default_range()
{
  static constexpr int64_t year = from_days<T>(365l);
  return {50 * year, 0};
}

template <typename T, std::enable_if_t<cudf::is_duration<T>()>* = nullptr>
std::pair<int64_t, int64_t> default_range()
{
  static constexpr int64_t year = from_days<T>(365l);
  return {0, 2 * year};
}

template <typename T, std::enable_if_t<cudf::is_numeric<T>()>* = nullptr>
std::pair<T, T> default_range()
{
  return {std::numeric_limits<T>::lowest(), std::numeric_limits<T>::max()};
}
}  // namespace

template <typename T, typename Enable = void>
struct distribution_desc;

template <typename T>
struct distribution_desc<
  T,
  typename std::enable_if_t<!std::is_same<T, bool>::value && cudf::is_numeric<T>()>> {
  distribution_id id;
  T lower_bound;
  T upper_bound;
};

template <typename T>
struct distribution_desc<T, typename std::enable_if_t<std::is_same<T, bool>::value>> {
  double probability_true;
};

template <typename T>
struct distribution_desc<T, typename std::enable_if_t<cudf::is_chrono<T>()>> {
  distribution_id id;
  int64_t lower_bound;
  int64_t upper_bound;
};

template <typename T>
struct distribution_desc<T, typename std::enable_if_t<std::is_same<T, cudf::string_view>::value>> {
  distribution_desc<uint32_t> length_params;
};

template <typename T>
struct distribution_desc<T, typename std::enable_if_t<cudf::is_fixed_point<T>()>> {
};

class data_profile {
  std::map<cudf::type_id, distribution_desc<uint64_t>> int_params;
  std::map<cudf::type_id, distribution_desc<double>> float_params;
  double bool_probability        = 0.5;
  double null_frequency          = 0.01;
  cudf::size_type cardinality    = 2000;  // TODO: maybe sqrt(num_rows)?
  cudf::size_type avg_run_length = 4;

 public:
  template <typename T,
            typename std::enable_if_t<!std::is_same<T, bool>::value && std::is_integral<T>::value,
                                      T>* = nullptr>
  distribution_desc<T> get_params() const
  {
    auto it = int_params.find(cudf::type_to_id<T>());
    if (it == int_params.end()) {
      auto const range = default_range<T>();
      return distribution_desc<T>{default_distribution_id<T>(), range.first, range.second};
    } else {
      auto& desc = it->second;
      return {desc.id, static_cast<T>(desc.lower_bound), static_cast<T>(desc.upper_bound)};
    }
  }

  template <typename T, typename std::enable_if_t<std::is_floating_point<T>::value, T>* = nullptr>
  distribution_desc<T> get_params() const
  {
    auto it = float_params.find(cudf::type_to_id<T>());
    if (it == float_params.end()) {
      auto const range = default_range<T>();
      return distribution_desc<T>{default_distribution_id<T>(), range.first, range.second};
    } else {
      auto& desc = it->second;
      return {desc.id, static_cast<T>(desc.lower_bound), static_cast<T>(desc.upper_bound)};
    }
  }

  template <typename T, std::enable_if_t<std::is_same<T, bool>::value>* = nullptr>
  distribution_desc<T> get_params() const
  {
    return distribution_desc<T>{bool_probability};
  }

  template <typename T, typename std::enable_if_t<cudf::is_chrono<T>()>* = nullptr>
  distribution_desc<T> get_params() const
  {
    auto it = int_params.find(cudf::type_to_id<T>());
    if (it == int_params.end()) {
      auto const range = default_range<T>();
      return distribution_desc<T>{default_distribution_id<T>(), range.first, range.second};
    } else {
      auto& desc = it->second;
      return {
        desc.id, static_cast<int64_t>(desc.lower_bound), static_cast<int64_t>(desc.upper_bound)};
    }
  }

  template <typename T, std::enable_if_t<std::is_same<T, cudf::string_view>::value>* = nullptr>
  distribution_desc<T> get_params() const
  {
    auto it = int_params.find(cudf::type_to_id<T>());
    if (it == int_params.end()) {
      return distribution_desc<T>{{distribution_id::NORMAL, 0, 32}};
    } else {
      auto& desc = it->second;
      return {{desc.id,
               static_cast<uint32_t>(desc.lower_bound),
               static_cast<uint32_t>(desc.upper_bound)}};
    }
  }

  template <typename T, typename std::enable_if_t<cudf::is_fixed_point<T>()>* = nullptr>
  distribution_desc<T> get_params() const
  {
    return {};
  }

  void set_bool_probability(double p) { bool_probability = p; }
  void set_null_frequency(double f) { null_frequency = f; }
  void set_cardinality(cudf::size_type c) { cardinality = c; }
  void set_avg_run_length(cudf::size_type avg_rl) { avg_run_length = avg_rl; }

  auto get_bool_probability() const { return bool_probability; }
  auto get_null_frequency() const { return null_frequency; };
  auto get_cardinality() const { return cardinality; };
  auto get_avg_run_length() const { return avg_run_length; };
};

std::vector<cudf::type_id> get_type_or_group(int32_t id);

/**
 * @file generate_benchmark_input.hpp
 * @brief Contains functions that generate columns filled with random data.
 *
 * Also includes utilies that generate random tables.
 *
 * The distribution of random data is meant to simulate real-world data. For example, numerical
 * values are generated using a normal distribution with a zero mean. Therefore, different column
 * types are filled using different distributions. The distributions are documented in the
 * functions where they are used.
 *
 * Currently, the data generation is done on the CPU and the data is then copied to the device
 * memory.
 */

std::unique_ptr<cudf::table> create_random_table(std::vector<cudf::type_id> dtype_ids,
                                                 cudf::size_type num_cols,
                                                 size_t table_bytes,
                                                 data_profile const& data_params = data_profile{});
