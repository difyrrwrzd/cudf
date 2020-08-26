#include "generate_benchmark_input.hpp"

#include <cudf/column/column.hpp>
#include <cudf/table/table.hpp>

#include <tests/utilities/column_utilities.hpp>
#include <tests/utilities/column_wrapper.hpp>

#include <rmm/device_buffer.hpp>

#include <future>
#include <memory>
#include <random>
#include <thread>
#include <vector>

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

/**
 * @brief Mersenne Twister engine with static seed.
 *
 * Produces the same random sequence on each run.
 */
auto deterministic_engine(unsigned seed = 13377331) { return std::mt19937{seed}; }

template <typename T>
std::enable_if_t<cudf::is_fixed_width<T>(), size_t> avg_element_size()
{
  return sizeof(T);
}

template <typename T>
std::enable_if_t<!cudf::is_fixed_width<T>(), size_t> avg_element_size()
{
  CUDF_FAIL("not implemented!");
}

template <>
size_t avg_element_size<cudf::string_view>()
{
  return 4 + 4 + 6;  // offset + length + hardcoded avg len
}

struct avg_element_size_fn {
  template <typename T>
  size_t operator()()
  {
    return avg_element_size<T>();
  }
};

size_t avg_element_bytes(cudf::type_id tid)
{
  return cudf::type_dispatcher(cudf::data_type(tid), avg_element_size_fn{});
}

/**
 * @brief nanosecond count in the unit of @ref T.
 *
 * @tparam T Timestamp type
 */
template <typename T>
constexpr int64_t nanoseconds()
{
  using ratio = std::ratio_divide<typename T::period, typename cudf::timestamp_ns::period>;
  return ratio::num / ratio::den;
}

/**
 * @brief Creates an random timestamp
 *
 * Generates 'recent' timestamps. All timstamps are earlier that June 2020. The period between the
 * timestamps and June 2020 has a geometric distribution. Most timestamps are within a few years
 * before 2020.
 *
 * @return The random timestamp
 * @tparam T Timestamp type
 */
template <typename T, std::enable_if_t<cudf::is_timestamp<T>()>* = nullptr>
T random_element(std::mt19937& engine)
{
  // Timestamp for June 2020
  static constexpr int64_t current_ns    = 1591053936l * nanoseconds<cudf::timestamp_s>();
  static constexpr auto timestamp_spread = 1. / (2 * 365 * 24 * 60 * 60);  // one in two years

  // Generate a number of seconds that is 50% likely to be shorter than two years
  std::geometric_distribution<int64_t> seconds_gen{timestamp_spread};
  // Generate a random value for the nanoseconds within a second
  std::uniform_int_distribution<int64_t> nanoseconds_gen{0, nanoseconds<cudf::timestamp_s>()};

  // Subtract the seconds from the 2020 timestamp to generate a reccent timestamp
  auto const timestamp_ns =
    current_ns - seconds_gen(engine) * nanoseconds<cudf::timestamp_s>() - nanoseconds_gen(engine);
  // Return value in the type's precision
  return T(typename T::duration{timestamp_ns / nanoseconds<T>()});
}

template <typename T, std::enable_if_t<cudf::is_duration<T>()>* = nullptr>
T random_element(std::mt19937& engine)
{
  static constexpr auto duration_spread = 1. / (365 * 24 * 60 * 60);  // one in a year

  // Generate a number of seconds that is 50% likely to be shorter than a year
  std::geometric_distribution<int64_t> seconds_gen{duration_spread};
  // Generate a random value for the nanoseconds within a second
  std::uniform_int_distribution<int64_t> nanoseconds_gen{0, nanoseconds<cudf::timestamp_s>()};

  // Subtract the seconds from the 2020 timestamp to generate a reccent timestamp
  auto const duration_ns =
    seconds_gen(engine) * nanoseconds<cudf::timestamp_s>() + nanoseconds_gen(engine);
  // Return value in the type's precision
  return T(typename T::duration{duration_ns / nanoseconds<T>()});
}

template <typename T, std::enable_if_t<cudf::is_fixed_point<T>()>* = nullptr>
T random_element(std::mt19937& engine)
{
  return T{};
}

/**
 * @brief Standard deviation for the Normal distribution used to generate numeric elements.
 *
 * Deviation depends on the type width; wider types -> larger value range.
 */
template <typename T>
constexpr auto stddev()
{
  return 1l << (sizeof(T) * 4);
}

/**
 * @brief Creates an random numeric value with a normal distribution
 *
 * Zero is always used as the mean for teh distribution. Unsigned types are generated as the
 * absolute value of the normal distribution output.
 * Different standard deviations are used depending on the type size, in order to generate larger
 * range of values for when the types supports it.
 *
 * @return The random number
 * @tparam T Numeric type
 */
template <typename T, std::enable_if_t<cudf::is_numeric<T>()>* = nullptr>
T random_element(std::mt19937& engine)
{
  static constexpr T lower_bound = std::numeric_limits<T>::lowest();
  static constexpr T upper_bound = std::numeric_limits<T>::max();

  // Use the type dependent standard deviation
  std::normal_distribution<> gaussian{0., stddev<T>()};

  auto elem = gaussian(engine);
  // Use absolute value for unsigned types
  if (lower_bound >= 0) elem = abs(elem);
  elem = std::max(std::min(elem, (double)upper_bound), (double)lower_bound);

  return T(elem);
}

/**
 * @brief Creates an boolean value with 50:50 probability
 *
 * @return The random boolean value
 */
template <>
bool random_element<bool>(std::mt19937& engine)
{
  std::uniform_int_distribution<> uniform{0, 1};
  return uniform(engine) == 1;
}

size_t null_mask_size(cudf::size_type num_rows)
{
  auto const bits_per_word = sizeof(cudf::bitmask_type) * 8;
  return (num_rows + bits_per_word - 1) / bits_per_word;
}

void reset_null_mask_bit(std::vector<cudf::bitmask_type>& null_mask, cudf::size_type row)
{
  auto const bits_per_word = sizeof(cudf::bitmask_type) * 8;
  null_mask[row / bits_per_word] &= ~(cudf::bitmask_type(1) << row % bits_per_word);
}

/**
 * @brief Creates a column with random content of the given type
 *
 * The templated implementation is used for all fixed width types. String columns are generated
 * using the specialization implemented below.
 *
 * @param[in] TODO
 *
 * @return Column filled with random data
 */
template <typename T>
std::unique_ptr<cudf::column> create_random_column(std::mt19937& engine, cudf::size_type num_rows)
{
  // make_fixed_width_column then mutable_view, then get null_mask and data, then fill
  float const null_frequency        = 0.01;
  cudf::size_type const avg_run_len = 4;
  std::gamma_distribution<float> rl_dist(4.f, avg_run_len / 4.f);
  std::uniform_real_distribution<float> null_dist;

  auto const dtype = cudf::data_type{cudf::type_to_id<T>()};
  T* h_data;
  CUDA_TRY(cudaMallocHost(&h_data, num_rows * size_of(dtype)));
  cudf::size_type null_count = 0;
  std::vector<cudf::bitmask_type> null_mask(null_mask_size(num_rows), ~0);
  for (cudf::size_type i = 0; i < num_rows; ++i) {
    auto const is_valid = null_dist(engine) >= null_frequency;
    if (!is_valid) {
      reset_null_mask_bit(null_mask, i);
      ++null_count;
    } else {
      h_data[i] = random_element<T>(engine);
    }
  }
  auto d_data = rmm::device_buffer(h_data, num_rows * size_of(dtype), cudaStream_t(0));
  cudaFree(h_data);
  return std::make_unique<cudf::column>(
    dtype,
    num_rows,
    std::move(d_data),
    rmm::device_buffer(
      null_mask.data(), null_mask.size() * sizeof(cudf::bitmask_type), cudaStream_t(0)),
    null_count);
}

/**
 * @brief Creates a string column with random content
 *
 * Uses a Poisson distribution around the mean string length. The average length of elements is 16
 * and currently there is no way to modify this via parameters.
 *
 * Due to random generation of the length of the columns elements, the resulting column will have a
 * slightly different size from @ref col_bytes.
 *
 * @param[in] TODO
 *
 * @return Column filled with random data
 */
template <>
std::unique_ptr<cudf::column> create_random_column<cudf::string_view>(std::mt19937& engine,
                                                                      cudf::size_type num_rows)
{
  float const null_frequency          = 0.01;
  static constexpr int avg_string_len = 16;

  auto const char_cnt        = avg_string_len * num_rows;
  cudf::size_type null_count = 0;

  std::poisson_distribution<> len_dist(avg_string_len);
  std::uniform_real_distribution<float> null_dist;
  std::uniform_int_distribution<char> char_dist{'!', '~'};

  std::vector<int32_t> offsets{0};
  offsets.reserve(num_rows + 1);
  std::vector<char> chars;
  chars.reserve(char_cnt);
  auto const bits_per_word = sizeof(cudf::bitmask_type) * 8;
  std::vector<cudf::bitmask_type> null_mask(null_mask_size(num_rows), ~0);

  for (int row = 1; row < num_rows; ++row) {
    offsets.push_back(offsets.back() + len_dist(engine));
    std::generate_n(std::back_inserter(chars), offsets.rbegin()[0] - offsets.rbegin()[1], [&]() {
      return char_dist(engine);
    });

    if (null_frequency > 0.f && null_dist(engine) < null_frequency) {
      null_mask[row / bits_per_word] &= ~(cudf::bitmask_type(1) << row % bits_per_word);
      ++null_count;
    }
  }
  return cudf::make_strings_column(chars, offsets, null_mask, null_count);
}

template <>
std::unique_ptr<cudf::column> create_random_column<cudf::dictionary32>(std::mt19937& engine,
                                                                       cudf::size_type num_rows)
{
  CUDF_FAIL("not implemented yet");
}

template <>
std::unique_ptr<cudf::column> create_random_column<cudf::list_view>(std::mt19937& engine,
                                                                    cudf::size_type num_rows)
{
  CUDF_FAIL("not implemented yet");
}

template <>
std::unique_ptr<cudf::column> create_random_column<cudf::struct_view>(std::mt19937& engine,
                                                                      cudf::size_type num_rows)
{
  CUDF_FAIL("not implemented yet");
}

struct create_rand_col_fn {
 public:
  template <typename T>
  std::unique_ptr<cudf::column> operator()(std::mt19937& engine, cudf::size_type num_rows)
  {
    return create_random_column<T>(engine, num_rows);
  }
};

using columns_vector = std::vector<std::unique_ptr<cudf::column>>;

columns_vector create_random_columns(std::vector<cudf::type_id> dtype_ids,
                                     std::mt19937 engine,
                                     cudf::size_type num_rows)
{
  columns_vector output_columns;
  std::transform(
    dtype_ids.begin(), dtype_ids.end(), std::back_inserter(output_columns), [&](auto tid) {
      return cudf::type_dispatcher(cudf::data_type(tid), create_rand_col_fn{}, engine, num_rows);
    });
  return output_columns;
}

std::vector<cudf::type_id> repeat_dtypes(std::vector<cudf::type_id> const& dtype_ids,
                                         cudf::size_type num_cols)
{
  std::vector<cudf::type_id> out_dtypes;
  out_dtypes.reserve(num_cols);
  for (cudf::size_type col = 0; col < num_cols; ++col)
    out_dtypes.push_back(dtype_ids[col % dtype_ids.size()]);
  return out_dtypes;
}

std::unique_ptr<cudf::table> create_random_table(std::vector<cudf::type_id> dtype_ids,
                                                 cudf::size_type num_cols,
                                                 size_t table_bytes)
{
  auto const out_dtype_ids = repeat_dtypes(dtype_ids, num_cols);
  size_t const avg_row_bytes =
    std::accumulate(out_dtype_ids.begin(), out_dtype_ids.end(), 0ul, [](size_t sum, auto tid) {
      return sum + avg_element_bytes(tid);
    });
  cudf::size_type const num_rows = table_bytes / avg_row_bytes;

  auto const processor_count            = std::thread::hardware_concurrency();
  cudf::size_type const cols_per_thread = (num_cols + processor_count - 1) / processor_count;
  cudf::size_type next_col              = 0;

  auto seed_engine = deterministic_engine();  // pass the seed param here
  std::vector<std::future<columns_vector>> col_futures;
  for (unsigned int i = 0; i < processor_count && next_col < num_cols; ++i) {
    auto thread_engine         = deterministic_engine(random_element<unsigned>(seed_engine));
    auto const thread_num_cols = std::min(num_cols - next_col, cols_per_thread);
    std::vector<cudf::type_id> thread_types(out_dtype_ids.begin() + next_col,
                                            out_dtype_ids.begin() + next_col + thread_num_cols);
    col_futures.emplace_back(std::async(std::launch::async,
                                        create_random_columns,
                                        std::move(thread_types),
                                        std::move(thread_engine),
                                        num_rows));
    next_col += thread_num_cols;
  }

  columns_vector output_columns;
  for (auto& cf : col_futures) {
    auto partial_table = cf.get();
    output_columns.reserve(output_columns.size() + partial_table.size());
    std::move(
      std::begin(partial_table), std::end(partial_table), std::back_inserter(output_columns));
    partial_table.clear();
  }

  return std::make_unique<cudf::table>(std::move(output_columns));
}
