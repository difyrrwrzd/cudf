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

/**
 * @file writer_impl.cu
 * @brief cuDF-IO parquet writer class implementation
 */

#include "writer_impl.hpp"

#include <nvstrings/NVStrings.h>
#include <cudf/null_mask.hpp>
#include <cudf/strings/strings_column_view.hpp>

#include <algorithm>
#include <cstring>
#include <utility>

#include <rmm/thrust_rmm_allocator.h>
#include <rmm/device_buffer.hpp>

namespace cudf {
namespace experimental {
namespace io {
namespace detail {
namespace parquet {

using namespace cudf::io::parquet;
using namespace cudf::io;

namespace {

/**
 * @brief Helper for pinned host memory
 **/
template <typename T>
using pinned_buffer = std::unique_ptr<T, decltype(&cudaFreeHost)>;

/**
 * @brief Function that translates GDF compression to parquet compression
 **/
constexpr parquet::Compression to_parquet_compression(
    compression_type compression) {
  switch (compression) {
    case compression_type::SNAPPY:
      return parquet::Compression::SNAPPY;
    case compression_type::NONE:
    default:
      return parquet::Compression::UNCOMPRESSED;
  }
}

}  // namespace

/**
 * @brief Helper class that adds parquet-specific column info
 **/
class parquet_column_view {
  using str_pair = std::pair<const char *, size_t>;

 public:
  /**
   * @brief Constructor that extracts out the string position + length pairs
   * for building dictionaries for string columns
   **/
  explicit parquet_column_view(size_t id, column_view const &col, cudaStream_t stream)
      : _id(id),
        _string_type(col.type().id() == type_id::STRING),
        _type_width(_string_type ? 0 : cudf::size_of(col.type())),
        _data_count(col.size()),
        _null_count(col.null_count()),
        _data(col.data<uint8_t>()),
        _nulls(col.has_nulls() ? col.null_mask() : nullptr) {
    if (_string_type) {
      // FIXME: Use thrust to generate index without creating a NVStrings instance
      strings_column_view view{col};
      _nvstr =
          NVStrings::create_from_offsets(view.chars().data<char>(), view.size(),
                                         view.offsets().data<size_type>());

      _indexes = rmm::device_buffer(_data_count * sizeof(str_pair), stream);
      CUDF_EXPECTS(
          _nvstr->create_index(static_cast<str_pair *>(_indexes.data())) == 0,
          "Cannot retrieve string pairs");
      _data = _indexes.data();
    }
    _name = "_col" + std::to_string(_id);
  }

  auto is_string() const noexcept { return _string_type; }
  size_t type_width() const noexcept { return _type_width; }
  size_t data_count() const noexcept { return _data_count; }
  size_t null_count() const noexcept { return _null_count; }
  void const *data() const noexcept { return _data; }
  uint32_t const *nulls() const noexcept { return _nulls; }

  auto parquet_name() const noexcept { return _name; }

 private:
  // Identifier within set of columns
  size_t _id = 0;
  bool _string_type = false;

  size_t _type_width = 0;
  size_t _data_count = 0;
  size_t _null_count = 0;
  void const *_data = nullptr;
  uint32_t const *_nulls = nullptr;

  // parquet-related members
  std::string _name{};

  // String-related members
  NVStrings *_nvstr = nullptr;
  rmm::device_buffer _indexes;
};


writer::impl::impl(std::string filepath, writer_options const &options,
                   rmm::mr::device_memory_resource *mr)
    : _mr(mr) {
  compression_kind_ = to_parquet_compression(options.compression);

  outfile_.open(filepath, std::ios::out | std::ios::binary | std::ios::trunc);
  CUDF_EXPECTS(outfile_.is_open(), "Cannot open output file");
}

void writer::impl::write(table_view const &table, cudaStream_t stream) {
  size_type num_columns = table.num_columns();
  size_type num_rows = 0;

  // Wrapper around cudf columns to attach parquet-specific type info
  std::vector<parquet_column_view> parquet_columns;
  for (auto it = table.begin(); it < table.end(); ++it) {
    const auto col = *it;
    const auto current_id = parquet_columns.size();

    num_rows = std::max<uint32_t>(num_rows, col.size());
    parquet_columns.emplace_back(current_id, col, stream);
  }

  outfile_.write(reinterpret_cast<char *>(buffer_.data()), buffer_.size());
  outfile_.flush();
}

// Forward to implementation
writer::writer(std::string filepath, writer_options const &options,
               rmm::mr::device_memory_resource *mr)
    : _impl(std::make_unique<impl>(filepath, options, mr)) {}

// Destructor within this translation unit
writer::~writer() = default;

// Forward to implementation
void writer::write_all(table_view const &table, cudaStream_t stream) {
  _impl->write(table, stream);
}

}  // namespace parquet
}  // namespace detail
}  // namespace io
}  // namespace experimental
}  // namespace cudf
