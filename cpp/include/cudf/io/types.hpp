/*
 * Copyright (c) 2019-2023, NVIDIA CORPORATION.
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

/**
 * @file types.hpp
 * @brief cuDF-IO API type definitions
 */

#pragma once

#include <cudf/table/table.hpp>
#include <cudf/types.hpp>
#include <cudf/utilities/span.hpp>

#include <map>
#include <memory>
#include <optional>
#include <string>
#include <unordered_map>
#include <vector>

namespace cudf {
//! IO interfaces
namespace io {
class data_sink;
class datasource;
}  // namespace io
}  // namespace cudf

//! cuDF interfaces
namespace cudf {
//! IO interfaces
namespace io {
/**
 * @brief Compression algorithms
 */
enum class compression_type {
  NONE,    ///< No compression
  AUTO,    ///< Automatically detect or select compression format
  SNAPPY,  ///< Snappy format, using byte-oriented LZ77
  GZIP,    ///< GZIP format, using DEFLATE algorithm
  BZIP2,   ///< BZIP2 format, using Burrows-Wheeler transform
  BROTLI,  ///< BROTLI format, using LZ77 + Huffman + 2nd order context modeling
  ZIP,     ///< ZIP format, using DEFLATE algorithm
  XZ,      ///< XZ format, using LZMA(2) algorithm
  ZLIB,    ///< ZLIB format, using DEFLATE algorithm
  LZ4,     ///< LZ4 format, using LZ77
  LZO,     ///< Lempel–Ziv–Oberhumer format
  ZSTD     ///< Zstandard format
};

/**
 * @brief Data source or destination types
 */
enum class io_type {
  FILEPATH,          ///< Input/output is a file path
  HOST_BUFFER,       ///< Input/output is a buffer in host memory
  DEVICE_BUFFER,     ///< Input/output is a buffer in device memory
  VOID,              ///< Input/output is nothing. No work is done. Useful for benchmarking
  USER_IMPLEMENTED,  ///< Input/output is handled by a custom user class
};

/**
 * @brief Behavior when handling quotations in field data
 */
enum class quote_style {
  MINIMAL,     ///< Quote only fields which contain special characters
  ALL,         ///< Quote all fields
  NONNUMERIC,  ///< Quote all non-numeric fields
  NONE         ///< Never quote fields; disable quotation parsing
};

/**
 * @brief Column statistics granularity type for parquet/orc writers
 */
enum statistics_freq {
  STATISTICS_NONE     = 0,  ///< No column statistics
  STATISTICS_ROWGROUP = 1,  ///< Per-Rowgroup column statistics
  STATISTICS_PAGE     = 2,  ///< Per-page column statistics
  STATISTICS_COLUMN   = 3,  ///< Full column and offset indices. Implies STATISTICS_ROWGROUP
};

/**
 * @brief Statistics about compression performed by a writer.
 */
class writer_compression_statistics {
 public:
  /**
   * @brief Default constructor
   */
  writer_compression_statistics() = default;

  /**
   * @brief Constructor with initial values.
   *
   * @param num_compressed_bytes The number of bytes that were successfully compressed
   * @param num_failed_bytes The number of bytes that failed to compress
   * @param num_skipped_bytes The number of bytes that were skipped during compression
   * @param num_compressed_output_bytes The number of bytes in the compressed output
   */
  writer_compression_statistics(size_t num_compressed_bytes,
                                size_t num_failed_bytes,
                                size_t num_skipped_bytes,
                                size_t num_compressed_output_bytes)
    : _num_compressed_bytes(num_compressed_bytes),
      _num_failed_bytes(num_failed_bytes),
      _num_skipped_bytes(num_skipped_bytes),
      _num_compressed_output_bytes(num_compressed_output_bytes)
  {
  }

  /**
   * @brief Adds the values from another `writer_compression_statistics` object.
   *
   * @param other The other writer_compression_statistics object
   * @return writer_compression_statistics& Reference to this object
   */
  writer_compression_statistics& operator+=(writer_compression_statistics const& other) noexcept
  {
    _num_compressed_bytes += other._num_compressed_bytes;
    _num_failed_bytes += other._num_failed_bytes;
    _num_skipped_bytes += other._num_skipped_bytes;
    _num_compressed_output_bytes += other._num_compressed_output_bytes;
    return *this;
  }

  /**
   * @brief Returns the number of bytes in blocks that were successfully compressed.
   *
   * This is the number of bytes that were actually compressed, not the size of the compressed
   * output.
   *
   * @return size_t The number of bytes that were successfully compressed
   */
  [[nodiscard]] auto num_compressed_bytes() const noexcept { return _num_compressed_bytes; }

  /**
   * @brief Returns the number of bytes in blocks that failed to compress.
   *
   * @return size_t The number of bytes that failed to compress
   */
  [[nodiscard]] auto num_failed_bytes() const noexcept { return _num_failed_bytes; }

  /**
   * @brief Returns the number of bytes in blocks that were skipped during compression.
   *
   * @return size_t The number of bytes that were skipped during compression
   */
  [[nodiscard]] auto num_skipped_bytes() const noexcept { return _num_skipped_bytes; }

  /**
   * @brief Returns the total size of compression inputs.
   *
   * @return size_t The total size of compression inputs
   */
  [[nodiscard]] auto num_total_input_bytes() const noexcept
  {
    return num_compressed_bytes() + num_failed_bytes() + num_skipped_bytes();
  }

  /**
   * @brief Returns the compression ratio for the successfully compressed blocks.
   *
   * Returns nan if there were no successfully compressed blocks.
   *
   * @return double The ratio between the size of the compression inputs and the size of the
   * compressed output.
   */
  [[nodiscard]] auto compression_ratio() const noexcept
  {
    return static_cast<double>(num_compressed_bytes()) / _num_compressed_output_bytes;
  }

 private:
  std::size_t _num_compressed_bytes = 0;  ///< The number of bytes that were successfully compressed
  std::size_t _num_failed_bytes     = 0;  ///< The number of bytes that failed to compress
  std::size_t _num_skipped_bytes = 0;  ///< The number of bytes that were skipped during compression
  std::size_t _num_compressed_output_bytes = 0;  ///< The number of bytes in the compressed output
};

/**
 * @brief Control use of dictionary encoding for parquet writer
 */
enum dictionary_policy {
  NEVER,     ///< Never use dictionary encoding
  ADAPTIVE,  ///< Use dictionary when it will not impact compression
  ALWAYS     ///< Use dictionary reqardless of impact on compression
};

/**
 * @brief Detailed name information for output columns.
 *
 * The hierarchy of children matches the hierarchy of children in the output
 * cudf columns.
 */
struct column_name_info {
  std::string name;                        ///< Column name
  std::vector<column_name_info> children;  ///< Child column names
  /**
   * @brief Construct a column name info with a name and no children
   *
   * @param _name Column name
   */
  column_name_info(std::string const& _name) : name(_name) {}
  column_name_info() = default;
};

/**
 * @brief Table metadata returned by IO readers.
 */
struct table_metadata {
  std::vector<column_name_info>
    schema_info;  //!< Detailed name information for the entire output hierarchy
  std::map<std::string, std::string> user_data;  //!< Format-dependent metadata of the first input
                                                 //!< file as key-values pairs (deprecated)
  std::vector<std::unordered_map<std::string, std::string>>
    per_file_user_data;  //!< Per file format-dependent metadata as key-values pairs
};

/**
 * @brief Table with table metadata used by io readers to return the metadata by value
 */
struct table_with_metadata {
  std::unique_ptr<table> tbl;  //!< Table
  table_metadata metadata;     //!< Table metadata
};

/**
 * @brief Non-owning view of a host memory buffer
 *
 * @deprecated Since 23.04
 *
 * Used to describe buffer input in `source_info` objects.
 */
struct host_buffer {
  // TODO: to be replaced by `host_span`
  char const* data = nullptr;  //!< Pointer to the buffer
  size_t size      = 0;        //!< Size of the buffer
  host_buffer()    = default;
  /**
   * @brief Construct a new host buffer object
   *
   * @param data Pointer to the buffer
   * @param size Size of the buffer
   */
  host_buffer(char const* data, size_t size) : data(data), size(size) {}
};

/**
 * @brief Returns `true` if the type is byte-like, meaning it is reasonable to pass as a pointer to
 * bytes.
 *
 * @tparam T The representation type
 * @return `true` if the type is considered a byte-like type
 */
template <typename T>
constexpr inline auto is_byte_like_type()
{
  using non_cv_T = std::remove_cv_t<T>;
  return std::is_same_v<non_cv_T, int8_t> || std::is_same_v<non_cv_T, char> ||
         std::is_same_v<non_cv_T, uint8_t> || std::is_same_v<non_cv_T, unsigned char> ||
         std::is_same_v<non_cv_T, std::byte>;
}

/**
 * @brief Source information for read interfaces
 */
struct source_info {
  source_info() = default;

  /**
   * @brief Construct a new source info object for multiple files
   *
   * @param file_paths Input files paths
   */
  explicit source_info(std::vector<std::string> const& file_paths) : _filepaths(file_paths) {}

  /**
   * @brief Construct a new source info object for a single file
   *
   * @param file_path Single input file
   */
  explicit source_info(std::string const& file_path) : _filepaths({file_path}) {}

  /**
   * @brief Construct a new source info object for multiple buffers in host memory
   *
   * @deprecated Since 23.04
   *
   * @param host_buffers Input buffers in host memory
   */
  explicit source_info(std::vector<host_buffer> const& host_buffers) : _type(io_type::HOST_BUFFER)
  {
    _host_buffers.reserve(host_buffers.size());
    std::transform(host_buffers.begin(),
                   host_buffers.end(),
                   std::back_inserter(_host_buffers),
                   [](auto const hb) {
                     return cudf::host_span<std::byte const>{
                       reinterpret_cast<std::byte const*>(hb.data), hb.size};
                   });
  }

  /**
   * @brief Construct a new source info object for a single buffer
   *
   * @deprecated Since 23.04
   *
   * @param host_data Input buffer in host memory
   * @param size Size of the buffer
   */
  explicit source_info(char const* host_data, size_t size)
    : _type(io_type::HOST_BUFFER),
      _host_buffers(
        {cudf::host_span<std::byte const>(reinterpret_cast<std::byte const*>(host_data), size)})
  {
  }

  /**
   * @brief Construct a new source info object for multiple buffers in host memory
   *
   * @param host_buffers Input buffers in host memory
   */
  template <typename T, CUDF_ENABLE_IF(is_byte_like_type<std::remove_cv_t<T>>())>
  explicit source_info(cudf::host_span<cudf::host_span<T>> const host_buffers)
    : _type(io_type::HOST_BUFFER)
  {
    if constexpr (not std::is_same_v<std::remove_cv_t<T>, std::byte>) {
      _host_buffers.reserve(host_buffers.size());
      std::transform(host_buffers.begin(),
                     host_buffers.end(),
                     std::back_inserter(_host_buffers),
                     [](auto const s) {
                       return cudf::host_span<std::byte const>{
                         reinterpret_cast<std::byte const*>(s.data()), s.size()};
                     });
    } else {
      _host_buffers.assign(host_buffers.begin(), host_buffers.end());
    }
  }

  /**
   * @brief Construct a new source info object for a single buffer
   *
   * @param host_data Input buffer in host memory
   */
  template <typename T, CUDF_ENABLE_IF(is_byte_like_type<std::remove_cv_t<T>>())>
  explicit source_info(cudf::host_span<T> host_data)
    : _type(io_type::HOST_BUFFER),
      _host_buffers{cudf::host_span<std::byte const>(
        reinterpret_cast<std::byte const*>(host_data.data()), host_data.size())}
  {
  }

  /**
   * @brief Construct a new source info object for multiple buffers in device memory
   *
   * @param device_buffers Input buffers in device memory
   */
  explicit source_info(cudf::host_span<cudf::device_span<std::byte const>> device_buffers)
    : _type(io_type::DEVICE_BUFFER), _device_buffers(device_buffers.begin(), device_buffers.end())
  {
  }

  /**
   * @brief Construct a new source info object from a device buffer
   *
   * @param d_buffer Input buffer in device memory
   */
  explicit source_info(cudf::device_span<std::byte const> d_buffer)
    : _type(io_type::DEVICE_BUFFER), _device_buffers({{d_buffer}})
  {
  }

  /**
   * @brief Construct a new source info object for multiple user-implemented sources
   *
   * @param sources  User-implemented input sources
   */
  explicit source_info(std::vector<cudf::io::datasource*> const& sources)
    : _type(io_type::USER_IMPLEMENTED), _user_sources(sources)
  {
  }

  /**
   * @brief Construct a new source info object for a single user-implemented source
   *
   * @param source Single user-implemented Input source
   */
  explicit source_info(cudf::io::datasource* source)
    : _type(io_type::USER_IMPLEMENTED), _user_sources({source})
  {
  }

  /**
   * @brief Get the type of the input
   *
   * @return The type of the input
   */
  [[nodiscard]] auto type() const { return _type; }
  /**
   * @brief Get the filepaths of the input
   *
   * @return The filepaths of the input
   */
  [[nodiscard]] auto const& filepaths() const { return _filepaths; }
  /**
   * @brief Get the host buffers of the input
   *
   * @return The host buffers of the input
   */
  [[nodiscard]] auto const& host_buffers() const { return _host_buffers; }
  /**
   * @brief Get the device buffers of the input
   *
   * @return The device buffers of the input
   */
  [[nodiscard]] auto const& device_buffers() const { return _device_buffers; }
  /**
   * @brief Get the user sources of the input
   *
   * @return The user sources of the input
   */
  [[nodiscard]] auto const& user_sources() const { return _user_sources; }

 private:
  io_type _type = io_type::FILEPATH;
  std::vector<std::string> _filepaths;
  std::vector<cudf::host_span<std::byte const>> _host_buffers;
  std::vector<cudf::device_span<std::byte const>> _device_buffers;
  std::vector<cudf::io::datasource*> _user_sources;
};

/**
 * @brief Destination information for write interfaces
 */
struct sink_info {
  sink_info() = default;
  /**
   * @brief Construct a new sink info object
   *
   * @param num_sinks Number of sinks
   */
  sink_info(size_t num_sinks) : _num_sinks(num_sinks) {}

  /**
   * @brief Construct a new sink info object for multiple files
   *
   * @param file_paths Output files paths
   */
  explicit sink_info(std::vector<std::string> const& file_paths)
    : _type(io_type::FILEPATH), _num_sinks(file_paths.size()), _filepaths(file_paths)
  {
  }

  /**
   * @brief Construct a new sink info object for a single file
   *
   * @param file_path Single output file path
   */
  explicit sink_info(std::string const& file_path)
    : _type(io_type::FILEPATH), _filepaths({file_path})
  {
  }

  /**
   * @brief Construct a new sink info object for multiple host buffers
   *
   * @param buffers Output host buffers
   */
  explicit sink_info(std::vector<std::vector<char>*> const& buffers)
    : _type(io_type::HOST_BUFFER), _num_sinks(buffers.size()), _buffers(buffers)
  {
  }
  /**
   * @brief Construct a new sink info object for a single host buffer
   *
   * @param buffer Single output host buffer
   */
  explicit sink_info(std::vector<char>* buffer) : _type(io_type::HOST_BUFFER), _buffers({buffer}) {}

  /**
   * @brief Construct a new sink info object for multiple user-implemented sinks
   *
   * @param user_sinks Output user-implemented sinks
   */
  explicit sink_info(std::vector<cudf::io::data_sink*> const& user_sinks)
    : _type(io_type::USER_IMPLEMENTED), _num_sinks(user_sinks.size()), _user_sinks(user_sinks)
  {
  }

  /**
   * @brief Construct a new sink info object for a single user-implemented sink
   *
   * @param user_sink Single output user-implemented sink
   */
  explicit sink_info(class cudf::io::data_sink* user_sink)
    : _type(io_type::USER_IMPLEMENTED), _user_sinks({user_sink})
  {
  }

  /**
   * @brief Get the type of the input
   *
   * @return The type of the input
   */
  [[nodiscard]] auto type() const { return _type; }
  /**
   * @brief Get the number of sinks
   *
   * @return The number of sinks
   */
  [[nodiscard]] auto num_sinks() const { return _num_sinks; }
  /**
   * @brief Get the filepaths of the input
   *
   *  @return The filepaths of the input
   */
  [[nodiscard]] auto const& filepaths() const { return _filepaths; }
  /**
   * @brief Get the host buffers of the input
   *
   *  @return The host buffers of the input
   */
  [[nodiscard]] auto const& buffers() const { return _buffers; }
  /**
   * @brief Get the user sinks of the input
   *
   *  @return The user sinks of the input
   */
  [[nodiscard]] auto const& user_sinks() const { return _user_sinks; }

 private:
  io_type _type     = io_type::VOID;
  size_t _num_sinks = 1;
  std::vector<std::string> _filepaths;
  std::vector<std::vector<char>*> _buffers;
  std::vector<cudf::io::data_sink*> _user_sinks;
};

class table_input_metadata;

/**
 * @brief Metadata for a column
 */
class column_in_metadata {
  friend table_input_metadata;
  std::string _name = "";
  std::optional<bool> _nullable;
  bool _list_column_is_map  = false;
  bool _use_int96_timestamp = false;
  bool _output_as_binary    = false;
  std::optional<uint8_t> _decimal_precision;
  std::optional<int32_t> _parquet_field_id;
  std::vector<column_in_metadata> children;

 public:
  column_in_metadata() = default;
  /**
   * @brief Construct a new column in metadata object
   *
   * @param name Column name
   */
  column_in_metadata(std::string_view name) : _name{name} {}
  /**
   * @brief Add the children metadata of this column
   *
   * @param child The children metadata of this column to add
   * @return this for chaining
   */
  column_in_metadata& add_child(column_in_metadata const& child)
  {
    children.push_back(child);
    return *this;
  }

  /**
   * @brief Set the name of this column
   *
   * @param name Name of the column
   * @return this for chaining
   */
  column_in_metadata& set_name(std::string const& name) noexcept
  {
    _name = name;
    return *this;
  }

  /**
   * @brief Set the nullability of this column
   *
   * @param nullable Whether this column is nullable
   * @return this for chaining
   */
  column_in_metadata& set_nullability(bool nullable) noexcept
  {
    _nullable = nullable;
    return *this;
  }

  /**
   * @brief Specify that this list column should be encoded as a map in the written file
   *
   * The column must have the structure list<struct<key, value>>. This option is invalid otherwise
   *
   * @return this for chaining
   */
  column_in_metadata& set_list_column_as_map() noexcept
  {
    _list_column_is_map = true;
    return *this;
  }

  /**
   * @brief Specifies whether this timestamp column should be encoded using the deprecated int96
   * physical type. Only valid for the following column types:
   * timestamp_s, timestamp_ms, timestamp_us, timestamp_ns
   *
   * @param req True = use int96 physical type. False = use int64 physical type
   * @return this for chaining
   */
  column_in_metadata& set_int96_timestamps(bool req) noexcept
  {
    _use_int96_timestamp = req;
    return *this;
  }

  /**
   * @brief Set the decimal precision of this column. Only valid if this column is a decimal
   * (fixed-point) type
   *
   * @param precision The integer precision to set for this decimal column
   * @return this for chaining
   */
  column_in_metadata& set_decimal_precision(uint8_t precision) noexcept
  {
    _decimal_precision = precision;
    return *this;
  }

  /**
   * @brief Set the parquet field id of this column.
   *
   * @param field_id The parquet field id to set
   * @return this for chaining
   */
  column_in_metadata& set_parquet_field_id(int32_t field_id) noexcept
  {
    _parquet_field_id = field_id;
    return *this;
  }

  /**
   * @brief Specifies whether this column should be written as binary or string data
   * Only valid for the following column types:
   * string
   *
   * @param binary True = use binary data type. False = use string data type
   * @return this for chaining
   */
  column_in_metadata& set_output_as_binary(bool binary) noexcept
  {
    _output_as_binary = binary;
    return *this;
  }

  /**
   * @brief Get reference to a child of this column
   *
   * @param i Index of the child to get
   * @return this for chaining
   */
  column_in_metadata& child(size_type i) noexcept { return children[i]; }

  /**
   * @brief Get const reference to a child of this column
   *
   * @param i Index of the child to get
   * @return this for chaining
   */
  [[nodiscard]] column_in_metadata const& child(size_type i) const noexcept { return children[i]; }

  /**
   * @brief Get the name of this column
   *
   * @return The name of this column
   */
  [[nodiscard]] std::string get_name() const noexcept { return _name; }

  /**
   * @brief Get whether nullability has been explicitly set for this column.
   *
   * @return Boolean indicating whether nullability has been explicitly set for this column
   */
  [[nodiscard]] bool is_nullability_defined() const noexcept { return _nullable.has_value(); }

  /**
   * @brief Gets the explicitly set nullability for this column.
   *
   * @throws If nullability is not explicitly defined for this column.
   *         Check using `is_nullability_defined()` first.
   * @return Boolean indicating whether this column is nullable
   */
  [[nodiscard]] bool nullable() const { return _nullable.value(); }

  /**
   * @brief If this is the metadata of a list column, returns whether it is to be encoded as a map.
   *
   * @return Boolean indicating whether this column is to be encoded as a map
   */
  [[nodiscard]] bool is_map() const noexcept { return _list_column_is_map; }

  /**
   * @brief Get whether to encode this timestamp column using deprecated int96 physical type
   *
   * @return Boolean indicating whether to encode this timestamp column using deprecated int96
   *         physical type
   */
  [[nodiscard]] bool is_enabled_int96_timestamps() const noexcept { return _use_int96_timestamp; }

  /**
   * @brief Get whether precision has been set for this decimal column
   *
   * @return Boolean indicating whether precision has been set for this decimal column
   */
  [[nodiscard]] bool is_decimal_precision_set() const noexcept
  {
    return _decimal_precision.has_value();
  }

  /**
   * @brief Get the decimal precision that was set for this column.
   *
   * @throws If decimal precision was not set for this column.
   *         Check using `is_decimal_precision_set()` first.
   * @return The decimal precision that was set for this column
   */
  [[nodiscard]] uint8_t get_decimal_precision() const { return _decimal_precision.value(); }

  /**
   * @brief Get whether parquet field id has been set for this column.
   *
   * @return Boolean indicating whether parquet field id has been set for this column
   */
  [[nodiscard]] bool is_parquet_field_id_set() const noexcept
  {
    return _parquet_field_id.has_value();
  }

  /**
   * @brief Get the parquet field id that was set for this column.
   *
   * @throws If parquet field id was not set for this column.
   *         Check using `is_parquet_field_id_set()` first.
   * @return The parquet field id that was set for this column
   */
  [[nodiscard]] int32_t get_parquet_field_id() const { return _parquet_field_id.value(); }

  /**
   * @brief Get the number of children of this column
   *
   * @return The number of children of this column
   */
  [[nodiscard]] size_type num_children() const noexcept { return children.size(); }

  /**
   * @brief Get whether to encode this column as binary or string data
   *
   * @return Boolean indicating whether to encode this column as binary data
   */
  [[nodiscard]] bool is_enabled_output_as_binary() const noexcept { return _output_as_binary; }
};

/**
 * @brief Metadata for a table
 */
class table_input_metadata {
 public:
  table_input_metadata() = default;  // Required by cython

  /**
   * @brief Construct a new table_input_metadata from a table_view.
   *
   * The constructed table_input_metadata has the same structure as the passed table_view
   *
   * @param table The table_view to construct metadata for
   */
  table_input_metadata(table_view const& table);

  std::vector<column_in_metadata> column_metadata;  //!< List of column metadata
};

/**
 * @brief Information used while writing partitioned datasets
 *
 * This information defines the slice of an input table to write to file. In partitioned dataset
 * writing, one partition_info struct defines one partition and corresponds to one output file
 */
struct partition_info {
  size_type start_row;  //!< The start row of the partition
  size_type num_rows;   //!< The number of rows in the partition

  partition_info() = default;
  /**
   * @brief Construct a new partition_info
   *
   * @param start_row The start row of the partition
   * @param num_rows The number of rows in the partition
   */
  partition_info(size_type start_row, size_type num_rows) : start_row(start_row), num_rows(num_rows)
  {
  }
};

/**
 * @brief schema element for reader
 *
 */
class reader_column_schema {
  // Whether to read binary data as a string column
  bool _convert_binary_to_strings{true};

  std::vector<reader_column_schema> children;

 public:
  reader_column_schema() = default;

  /**
   * @brief Construct a new reader column schema object
   *
   * @param number_of_children number of child schema objects to default construct
   */
  reader_column_schema(size_type number_of_children) { children.resize(number_of_children); }

  /**
   * @brief Construct a new reader column schema object with a span defining the children
   *
   * @param child_span span of child schema objects
   */
  reader_column_schema(host_span<reader_column_schema> const& child_span)
  {
    children.assign(child_span.begin(), child_span.end());
  }

  /**
   * @brief Add the children metadata of this column
   *
   * @param child The children metadata of this column to add
   * @return this for chaining
   */
  reader_column_schema& add_child(reader_column_schema const& child)
  {
    children.push_back(child);
    return *this;
  }

  /**
   * @brief Get reference to a child of this column
   *
   * @param i Index of the child to get
   * @return this for chaining
   */
  [[nodiscard]] reader_column_schema& child(size_type i) { return children[i]; }

  /**
   * @brief Get const reference to a child of this column
   *
   * @param i Index of the child to get
   * @return this for chaining
   */
  [[nodiscard]] reader_column_schema const& child(size_type i) const { return children[i]; }

  /**
   * @brief Specifies whether this column should be written as binary or string data
   * Only valid for the following column types:
   * string, list<int8>
   *
   * @param convert_to_string True = convert binary to strings False = return binary
   * @return this for chaining
   */
  reader_column_schema& set_convert_binary_to_strings(bool convert_to_string)
  {
    _convert_binary_to_strings = convert_to_string;
    return *this;
  }

  /**
   * @brief Get whether to encode this column as binary or string data
   *
   * @return Boolean indicating whether to encode this column as binary data
   */
  [[nodiscard]] bool is_enabled_convert_binary_to_strings() const
  {
    return _convert_binary_to_strings;
  }

  /**
   * @brief Get the number of child objects
   *
   * @return number of children
   */
  [[nodiscard]] size_t get_num_children() const { return children.size(); }
};

}  // namespace io
}  // namespace cudf
