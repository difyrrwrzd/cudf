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

#include "json_reader.hpp"

#include <cuda_runtime.h>

#include <algorithm>
#include <iostream>
#include <map>
#include <memory>
#include <numeric>
#include <string>
#include <vector>

#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

#include <thrust/device_ptr.h>
#include <thrust/execution_policy.h>

#include <thrust/host_vector.h>

#include <nvstrings/NVStrings.h>

#include "cudf.h"
#include "utilities/cudf_utils.h"
#include "utilities/error_utils.hpp"
#include "utilities/type_dispatcher.hpp"

#include "io/comp/io_uncomp.h"
#include "rmm/rmm.h"
#include "rmm/thrust_rmm_allocator.h"

#include "io/cuio_common.hpp"
#include "io/utilities/parsing_utils.cuh"
#include "io/utilities/wrapper_utils.hpp"

using string_pair = std::pair<const char *, size_t>;

gdf_error read_json(json_read_arg *args) {
  // Check if the passed arguments are valid
  CUDF_EXPECTS(args != nullptr, "The args parameter cannot be null.\n");
  CUDF_EXPECTS(args->source != nullptr, "Input source cannot be null.\n");

  JsonReader reader(args);

  reader.parse();

  reader.setOutputArguments(args);

  return GDF_SUCCESS;
}

JsonReader::JsonReader(json_read_arg *args) : args_(args) {
  // Check if the passed arguments are supported
  CUDF_EXPECTS(args_->lines, "Only Json Lines format is currently supported.\n");
}

/**---------------------------------------------------------------------------*
 * @brief Estimates the maximum expected length or a row, based on the number
 * of columns
 *
 * If the number of columns is not available, it will return a value large
 * enough for most use cases
 *
 * @param[in] num_columns Number of columns in the JSON file (optional)
 *
 * @return Estimated maximum size of a row, in bytes
 *---------------------------------------------------------------------------**/
constexpr size_t calculateMaxRowSize(int num_columns = 0) noexcept {
  constexpr size_t max_row_bytes = 16 * 1024; // 16KB
  constexpr size_t column_bytes = 64;
  constexpr size_t base_padding = 1024; // 1KB
  if (num_columns == 0) {
    // Use flat size if the number of columns is not known
    return max_row_bytes;
  } else {
    // Expand the size based on the number of columns, if available
    return base_padding + num_columns * column_bytes;
  }
}

void JsonReader::parse() {
  ingestRawInput();
  CUDF_EXPECTS(input_data_ != nullptr, "Ingest failed: input data is null.\n");
  CUDF_EXPECTS(input_size_ != 0, "Ingest failed: input data has zero size.\n");

  decompressInput();
  CUDF_EXPECTS(uncomp_data_ != nullptr, "Ingest failed: uncompressed input data is null.\n");
  CUDF_EXPECTS(uncomp_size_ != 0, "Ingest failed: uncompressed input data has zero size.\n");

  setRecordStarts();
  CUDF_EXPECTS(!rec_starts_.empty(), "Error enumerating records.\n");

  uploadDataToDevice();
  CUDF_EXPECTS(!d_data_.empty(), "Error uploading input data to the GPU.\n");

  setColumnNames();
  CUDF_EXPECTS(!column_names_.empty(), "Error determining column names.\n");

  setDataTypes();
  CUDF_EXPECTS(!dtypes_.empty(), "Error in data type detection.\n");

  convertDataToColumns();
  CUDF_EXPECTS(!columns_.empty(), "Error converting json input into gdf columns.\n");
}

/**---------------------------------------------------------------------------*
 * @brief Infer the compression type from the compression parameter and
 * the input file name
 *
 * Returns "none" if the input is not compressed.
 * Throws if the input is not not valid.
 *
 * @param[in] compression_arg Input string that is potentially describing
 * the compression type. Can also be nullptr, "none", or "infer"
 * @param[in] filepath path + name of the input file
 *
 * @return string representing the compression type
 *---------------------------------------------------------------------------**/
std::string inferCompressionType(const char *compression_arg, const char *filepath) {
  if (compression_arg == nullptr || 0 == strcasecmp(compression_arg, "none")) {
    return "none";
  }
  if (0 != strcasecmp(compression_arg, "infer")) {
    return std::string(compression_arg);
  } else {
    const char *const file_ext = strrchr(filepath, '.');
    if (file_ext) {
      if (!strcasecmp(file_ext, ".gz"))
        return "gzip";
      else if (!strcasecmp(file_ext, ".zip"))
        return "zip";
      else if (!strcasecmp(file_ext, ".bz2"))
        return "bz2";
      else if (!strcasecmp(file_ext, ".xz"))
        return "xz";
    }
    CUDF_FAIL("Invalid compression argument");
  }
}

void JsonReader::ingestRawInput() {
  if (args_->source_type == gdf_csv_input_form::FILE_PATH) {
    map_file_ = std::make_unique<MappedFile>(args_->source, O_RDONLY);
    CUDF_EXPECTS(map_file_->size() > 0, "Input file is empty.\n");
    CUDF_EXPECTS(args_->byte_range_offset < map_file_->size(), "byte_range offset is too big for the input size.\n");

    // Have to align map offset to page size
    const auto page_size = sysconf(_SC_PAGESIZE);
    size_t map_offset = (args_->byte_range_offset / page_size) * page_size;

    // Set to rest-of-the-file size, will reduce based on the byte range size
    size_t map_size = map_file_->size() - map_offset;

    // Include the page padding in the mapped size
    const size_t page_padding = args_->byte_range_offset - map_offset;
    const size_t padded_byte_range_size = args_->byte_range_size + page_padding;

    if (args_->byte_range_size != 0 && padded_byte_range_size < map_size) {
      // Need to make sure that w/ padding we don't overshoot the end of file
      map_size = min(padded_byte_range_size + calculateMaxRowSize(args_->num_cols), map_size);
    }

    map_file_->map(map_size, map_offset);
    input_data_ = static_cast<const char *>(map_file_->data()) + page_padding;
    // Ignore page padding for parsing purposes
    input_size_ = map_size - page_padding;
  } else if (args_->source_type == gdf_csv_input_form::HOST_BUFFER) {
    input_data_ = args_->source;
    input_size_ = args_->buffer_size;
  } else {
    CUDF_FAIL("Invalid input type");
  }
}

void JsonReader::decompressInput() {
  const std::string compression_type = inferCompressionType(args_->compression, args_->source);
  if (compression_type == "none") {
    // Do not use the owner vector here to avoid copying the whole file to the heap
    uncomp_data_ = input_data_;
    uncomp_size_ = input_size_;
  } else {
    CUDF_EXPECTS(getUncompressedHostData(input_data_, input_size_, compression_type, uncomp_data_owner_) == GDF_SUCCESS,
                 "Input data decompression failed.\n");
    uncomp_data_ = uncomp_data_owner_.data();
    uncomp_size_ = uncomp_data_owner_.size();
  }
}

void JsonReader::setRecordStarts() {
  std::vector<char> chars_to_count{'\n'};
  // Currently, ignoring lineterminations within quotes is handled by recording the records of both,
  // and then filtering out the records that is a quotechar or a linetermination within a quotechar pair.
  if (allow_newlines_in_strings_) {
    chars_to_count.push_back('\"');
  }
  // If not starting at an offset, add an extra row to account for the first row in the file
  const auto prefilter_count =
      countAllFromSet(uncomp_data_, uncomp_size_, chars_to_count) + ((args_->byte_range_offset == 0) ? 1 : 0);

  rec_starts_ = device_buffer<uint64_t>(prefilter_count);

  auto *find_result_ptr = rec_starts_.data();
  // Manually adding an extra row to account for the first row in the file
  if (args_->byte_range_offset == 0) {
    find_result_ptr++;
    CUDA_TRY(cudaMemsetAsync(rec_starts_.data(), 0ull, sizeof(uint64_t)));
  }

  std::vector<char> chars_to_find{'\n'};
  if (allow_newlines_in_strings_) {
    chars_to_find.push_back('\"');
  }
  // Passing offset = 1 to return positions AFTER the found character
  findAllFromSet(uncomp_data_, uncomp_size_, chars_to_find, 1, find_result_ptr);

  // Previous call stores the record pinput_file.typeositions as encountered by all threads
  // Sort the record positions as subsequent processing may require filtering
  // certain rows or other processing on specific records
  thrust::sort(rmm::exec_policy()->on(0), rec_starts_.data(), rec_starts_.data() + prefilter_count);

  auto filtered_count = prefilter_count;
  if (allow_newlines_in_strings_) {
    std::vector<uint64_t> h_rec_starts(prefilter_count);
    CUDA_TRY(
        cudaMemcpy(h_rec_starts.data(), rec_starts_.data(), sizeof(uint64_t) * prefilter_count, cudaMemcpyDefault));

    bool quotation = false;
    for (gdf_size_type i = 1; i < prefilter_count; ++i) {
      if (uncomp_data_[h_rec_starts[i] - 1] == '\"') {
        quotation = !quotation;
        h_rec_starts[i] = uncomp_size_;
        filtered_count--;
      } else if (quotation) {
        h_rec_starts[i] = uncomp_size_;
        filtered_count--;
      }
    }

    CUDA_TRY(cudaMemcpy(rec_starts_.data(), h_rec_starts.data(), prefilter_count, cudaMemcpyHostToDevice));
    thrust::sort(rmm::exec_policy()->on(0), rec_starts_.data(), rec_starts_.data() + prefilter_count);
  }

  // Exclude the ending newline as it does not precede a record start
  if (uncomp_data_[uncomp_size_ - 1] == '\n') {
    filtered_count--;
  }

  rec_starts_.resize(filtered_count);
}

void JsonReader::uploadDataToDevice() {
  size_t start_offset = 0;
  size_t bytes_to_upload = uncomp_size_;

  // Trim lines that are outside range
  if (args_->byte_range_size != 0) {
    std::vector<uint64_t> h_rec_starts(rec_starts_.size());
    CUDA_TRY(
        cudaMemcpy(h_rec_starts.data(), rec_starts_.data(), sizeof(uint64_t) * h_rec_starts.size(), cudaMemcpyDefault));

    auto it = h_rec_starts.end() - 1;
    while (it >= h_rec_starts.begin() && *it > args_->byte_range_size) {
      --it;
    }
    const auto end_offset = *(it + 1);
    h_rec_starts.erase(it + 1, h_rec_starts.end());

    start_offset = h_rec_starts.front();
    bytes_to_upload = end_offset - start_offset;
    CUDF_EXPECTS(bytes_to_upload <= uncomp_size_, "Error finding the record within the specified byte range.\n");

    // Resize to exclude rows outside of the range; adjust row start positions to account for the data subcopy
    rec_starts_.resize(h_rec_starts.size());
    thrust::transform(rmm::exec_policy()->on(0), rec_starts_.data(), rec_starts_.data() + rec_starts_.size(),
                      thrust::make_constant_iterator(start_offset), rec_starts_.data(), thrust::minus<uint64_t>());
  }

  // Upload the raw data that is within the rows of interest
  d_data_ = device_buffer<char>(bytes_to_upload);
  CUDA_TRY(cudaMemcpy(d_data_.data(), uncomp_data_ + start_offset, bytes_to_upload, cudaMemcpyHostToDevice));
}

/**---------------------------------------------------------------------------*
 * @brief Extract value names from a JSON object
 *
 * @param[in] json_obj Host vector containing the JSON object
 * @param[in] opts Parsing options (e.g. delimiter and quotation character)
 *
 * @return std::vector<std::string> names of JSON object values
 *---------------------------------------------------------------------------**/
std::vector<std::string> getNamesFromJsonObject(const std::vector<char> &json_obj, const ParseOptions &opts) {
  enum class ParseState { preColName, colName, postColName };
  std::vector<std::string> names;
  bool quotation = false;
  auto state = ParseState::preColName;
  int name_start = 0;
  for (size_t pos = 0; pos < json_obj.size(); ++pos) {
    if (state == ParseState::preColName) {
      if (json_obj[pos] == opts.quotechar) {
        name_start = pos + 1;
        state = ParseState::colName;
        continue;
      }
    } else if (state == ParseState::colName) {
      if (json_obj[pos] == opts.quotechar && json_obj[pos - 1] != '\\') {
        // if found a non-escaped quote character, it's the end of the column name
        names.emplace_back(&json_obj[name_start], &json_obj[pos]);
        state = ParseState::postColName;
        continue;
      }
    } else if (state == ParseState::postColName) {
      // TODO handle complex data types that might include unquoted commas
      if (!quotation && json_obj[pos] == opts.delimiter) {
        state = ParseState::preColName;
        continue;
      } else if (json_obj[pos] == opts.quotechar) {
        quotation = !quotation;
      }
    }
  }
  return names;
}

void JsonReader::setColumnNames() {
  // If file only contains one row, use the file size for the row size
  uint64_t first_row_len = d_data_.size() / sizeof(char);
  if (rec_starts_.size() > 1) {
    // Set first_row_len to the offset of the second row, if it exists
    CUDA_TRY(cudaMemcpy(&first_row_len, rec_starts_.data() + 1, sizeof(uint64_t), cudaMemcpyDefault));
  }
  std::vector<char> first_row(first_row_len);
  CUDA_TRY(cudaMemcpy(first_row.data(), d_data_.data(), first_row_len * sizeof(char), cudaMemcpyDefault));

  // Determine the row format between:
  //   JSON array - [val1, val2, ...] and
  //   JSON object - {"col1":val1, "col2":val2, ...}
  // based on the top level opening bracket
  const auto first_square_bracket = std::find(first_row.begin(), first_row.end(), '[');
  const auto first_curly_bracket = std::find(first_row.begin(), first_row.end(), '{');
  // If the first opening bracket is '{', assume object format
  const bool is_object = first_curly_bracket < first_square_bracket;
  if (is_object) {
    column_names_ = getNamesFromJsonObject(first_row, opts_);
  } else {
    int cols_found = 0;
    bool quotation = false;
    for (size_t pos = 0; pos < first_row.size(); ++pos) {
      // Flip the quotation flag if current character is a quotechar
      if (first_row[pos] == opts_.quotechar) {
        quotation = !quotation;
      }
      // Check if end of a column/row
      else if (pos == first_row.size() - 1 || (!quotation && first_row[pos] == opts_.delimiter)) {
        column_names_.emplace_back(std::to_string(cols_found++));
      }
    }
  }
}

void JsonReader::convertDataToColumns() {
  const auto num_columns = dtypes_.size();

  for (size_t col = 0; col < num_columns; ++col) {
    columns_.emplace_back(rec_starts_.size(), dtypes_[col], gdf_dtype_extra_info{TIME_UNIT_NONE}, column_names_[col]);
    CUDF_EXPECTS(columns_.back().allocate() == GDF_SUCCESS, "Cannot allocate columns.\n");
  }

  thrust::host_vector<gdf_dtype> h_dtypes(num_columns);
  thrust::host_vector<void *> h_data(num_columns);
  thrust::host_vector<gdf_valid_type *> h_valid(num_columns);

  for (size_t i = 0; i < num_columns; ++i) {
    h_dtypes[i] = columns_[i]->dtype;
    h_data[i] = columns_[i]->data;
    h_valid[i] = columns_[i]->valid;
  }

  rmm::device_vector<gdf_dtype> d_dtypes = h_dtypes;
  rmm::device_vector<void *> d_data = h_data;
  rmm::device_vector<gdf_valid_type *> d_valid = h_valid;
  rmm::device_vector<gdf_size_type> d_valid_counts(num_columns, 0);

  convertJsonToColumns(d_dtypes.data().get(), d_data.data().get(), d_valid.data().get(), d_valid_counts.data().get());
  CUDA_TRY(cudaDeviceSynchronize());
  CUDA_TRY(cudaGetLastError());

  thrust::host_vector<gdf_size_type> h_valid_counts = d_valid_counts;
  for (size_t i = 0; i < num_columns; ++i) {
    columns_[i]->null_count = columns_[i]->size - h_valid_counts[i];
  }

  // Handle string columns
  for (auto &column : columns_) {
    if (column->dtype == GDF_STRING) {
      auto str_list = static_cast<string_pair *>(column->data);
      auto str_data = NVStrings::create_from_index(str_list, column->size);
      RMM_FREE(std::exchange(column->data, str_data), 0);
    }
  }
}

void JsonReader::setOutputArguments(json_read_arg *out_args) {

  // Transfer ownership to raw pointer output arguments
  out_args->data = (gdf_column **)malloc(sizeof(gdf_column *) * columns_.size());
  for (size_t i = 0; i < columns_.size(); ++i) {
    out_args->data[i] = columns_[i].release();
  }
  out_args->num_cols_out = columns_.size();
  out_args->num_rows_out = rec_starts_.size();
}

/**---------------------------------------------------------------------------*
 * @brief Functor for converting plain text data to cuDF data type value.
 *---------------------------------------------------------------------------**/
struct ConvertFunctor {
  /**---------------------------------------------------------------------------*
   * @brief Default template operator() dispatch
   *---------------------------------------------------------------------------**/
  template <typename T>
  __host__ __device__ __forceinline__ void operator()(const char *data, void *gdf_columns, long row, long start,
                                                      long end, const ParseOptions &opts) {
    T &value{static_cast<T *>(gdf_columns)[row]};
    value = convertStrToValue<T>(data, start, end, opts);
  }
};

/**---------------------------------------------------------------------------*
 * @brief CUDA Kernel that modifies the start and stop offsets to exclude
 * the sections outside of the top level brackets.
 *
 * The top level brackets characters are excluded from the resulting range.
 * Parameter stop has the same semantics as end() in STL containers
 * (one past the last element)
 *
 * @param[in] data Pointer to the device buffer containing the data to process
 * @param[in,out] start Offset of the first character in the range
 * @param[in,out] stop Offset of the first character after the range
 *
 * @return void
 *---------------------------------------------------------------------------**/
__device__ void LimitRangeToBrackets(const char *data, long &start, long &stop) {
  while (data[start] != '[' && data[start] != '{') {
    start++;
  }
  start++;

  while (data[stop - 1] != ']' && data[stop - 1] != '}') {
    stop--;
  }
  stop--;
}

/**---------------------------------------------------------------------------*
 * @brief CUDA kernel that finds the end position of the next field name,
 * including the colon that separates the name from the field value.
 *
 * Returns the position after the colon that preceeds the value token.
 *
 * @param[in] data Pointer to the device buffer containing the data to process
 * @param[in] opts Parsing options (e.g. delimiter and quotation character)
 * @param[in] start Offset of the first character in the range
 * @param[in] stop Offset of the first character after the range
 *
 * @return long Position of the first character after the field name.
 *---------------------------------------------------------------------------**/
__device__ long seekFieldNameEnd(const char *data, const ParseOptions opts, long start, long stop) {
  bool quotation = false;
  for (auto pos = start; pos < stop; ++pos) {
    // Ignore escaped quotes
    if (data[pos] == opts.quotechar && data[pos - 1] != '\\') {
      quotation = !quotation;
    } else if (!quotation && data[pos] == ':') {
      return pos + 1;
    }
  }
  return stop;
}

/**---------------------------------------------------------------------------*
 * @brief CUDA kernel that parses and converts plain text data into cuDF column data.
 *
 * Data is processed one record at a time
 *
 * @param[in] data The entire data to read
 * @param[in] data_size Size of the data buffer, in bytes
 * @param[in] rec_starts The start of each data record
 * @param[in] num_records The number of lines/rows
 * @param[in] dtypes The data type of each column
 * @param[in] opts A set of parsing options
 * @param[out] gdf_columns The output column data
 * @param[in] num_columns The number of columns
 * @param[out] valid_fields The bitmaps indicating whether column fields are valid
 * @param[out] num_valid_fields The numbers of valid fields in columns
 *
 * @return void
 *---------------------------------------------------------------------------**/
__global__ void convertJsonToGdf(const char *data, size_t data_size, const uint64_t *rec_starts,
                                 gdf_size_type num_records, const gdf_dtype *dtypes, ParseOptions opts,
                                 void *const *gdf_columns, int num_columns, gdf_valid_type *const *valid_fields,
                                 gdf_size_type *num_valid_fields) {
  const long rec_id = threadIdx.x + (blockDim.x * blockIdx.x);
  if (rec_id >= num_records)
    return;

  long start = rec_starts[rec_id];
  // has the same semantics as end() in STL containers (one past last element)
  long stop = ((rec_id < num_records - 1) ? rec_starts[rec_id + 1] : data_size);

  LimitRangeToBrackets(data, start, stop);
  const bool is_object = (data[start - 1] == '{');

  for (int col = 0; col < num_columns && start < stop; col++) {
    if (is_object) {
      start = seekFieldNameEnd(data, opts, start, stop);
    }
    // field_end is at the next delimiter/newline
    const long field_end = seekFieldEnd(data, opts, start, stop);
    long field_data_last = field_end - 1;
    // Modify start & end to ignore whitespace and quotechars
    adjustForWhitespaceAndQuotes(data, &start, &field_data_last, opts.quotechar);
    // Empty fields are not legal values
    if (start <= field_data_last) {
      // Type dispatcher does not handle GDF_STRINGS
      if (dtypes[col] == gdf_dtype::GDF_STRING) {
        auto str_list = static_cast<string_pair *>(gdf_columns[col]);
        str_list[rec_id].first = data + start;
        str_list[rec_id].second = field_data_last - start + 1;
      } else {
        cudf::type_dispatcher(dtypes[col], ConvertFunctor{}, data, gdf_columns[col], rec_id, start, field_data_last,
                              opts);
      }

      // set the valid bitmap - all bits were set to 0 to start
      setBitmapBit(valid_fields[col], rec_id);
      atomicAdd(&num_valid_fields[col], 1);
    } else if (dtypes[col] == gdf_dtype::GDF_STRING) {
      auto str_list = static_cast<string_pair *>(gdf_columns[col]);
      str_list[rec_id].first = nullptr;
      str_list[rec_id].second = 0;
    }
    start = field_end + 1;
  }
}

void JsonReader::convertJsonToColumns(gdf_dtype *const dtypes, void *const *gdf_columns,
                                      gdf_valid_type *const *valid_fields, gdf_size_type *num_valid_fields) {
  int block_size;
  int min_grid_size;
  CUDA_TRY(cudaOccupancyMaxPotentialBlockSize(&min_grid_size, &block_size, convertJsonToGdf));

  const int grid_size = (rec_starts_.size() + block_size - 1) / block_size;

  convertJsonToGdf<<<grid_size, block_size>>>(d_data_.data(), d_data_.size(), rec_starts_.data(), rec_starts_.size(),
                                              dtypes, opts_, gdf_columns, columns_.size(), valid_fields,
                                              num_valid_fields);

  CUDA_TRY(cudaGetLastError());
}

/**---------------------------------------------------------------------------*
 * @brief CUDA kernel that parses and converts data into cuDF column data.
 *
 * Data is processed in one row/record at a time, so the number of total
 * threads (tid) is equal to the number of rows.
 *
 * @param[in] data The entire plain text data to read
 * @param[in] data_size Size of the data buffer, in bytes
 * @param[in] opts A set of parsing options
 * @param[in] num_columns The number of columns of input data
 * @param[in] rec_starts The start the input data of interest
 * @param[in] num_records The number of lines/rows of input data
 * @param[out] column_infos The count for each column data type
 *
 * @returns void
 *---------------------------------------------------------------------------**/
__global__ void detectJsonDataTypes(const char *data, size_t data_size, const ParseOptions opts, int num_columns,
                                    const uint64_t *rec_starts, gdf_size_type num_records,
                                    JsonReader::ColumnInfo *column_infos) {
  long rec_id = threadIdx.x + (blockDim.x * blockIdx.x);
  if (rec_id >= num_records)
    return;

  long start = rec_starts[rec_id];
  // has the same semantics as end() in STL containers (one past last element)
  long stop = ((rec_id < num_records - 1) ? rec_starts[rec_id + 1] : data_size);

  LimitRangeToBrackets(data, start, stop);
  const bool is_object = (data[start - 1] == '{');

  for (int col = 0; col < num_columns; col++) {
    if (is_object) {
      start = seekFieldNameEnd(data, opts, start, stop);
    }
    const long field_end = seekFieldEnd(data, opts, start, stop);
    long field_data_last = field_end - 1;
    adjustForWhitespaceAndQuotes(data, &start, &field_data_last);

    // Checking if the field is empty
    if (start > field_data_last) {
      atomicAdd(&column_infos[col].null_count, 1);
      start = field_end + 1;
      continue;
    }

    int digit_count = 0;
    int decimal_count = 0;
    int slash_count = 0;
    int dash_count = 0;
    int colon_count = 0;
    int exponent_count = 0;
    int other_count = 0;

    const int field_len = field_data_last - start + 1;
    const bool maybe_hex = ((field_len > 2 && data[start] == '0' && data[start + 1] == 'x') ||
                            (field_len > 3 && data[start] == '-' && data[start + 1] == '0' && data[start + 2] == 'x'));
    for (long pos = start; pos <= field_data_last; pos++) {
      if (isDigit(data[pos], maybe_hex)) {
        digit_count++;
        continue;
      }
      // Looking for unique characters that will help identify column types
      switch (data[pos]) {
      case '.':
        decimal_count++;
        break;
      case '-':
        dash_count++;
        break;
      case '/':
        slash_count++;
        break;
      case ':':
        colon_count++;
        break;
      case 'e':
      case 'E':
        if (!maybe_hex && pos > start && pos < field_data_last)
          exponent_count++;
        break;
      default:
        other_count++;
        break;
      }
    }

    // Integers have to have the length of the string
    int int_req_number_cnt = field_len;
    // Off by one if they start with a minus sign
    if (data[start] == '-' && field_len > 1) {
      --int_req_number_cnt;
    }
    // Off by one if they are a hexadecimal number
    if (maybe_hex) {
      --int_req_number_cnt;
    }
    if (digit_count == int_req_number_cnt) {
      atomicAdd(&column_infos[col].int_count, 1);
    } else if (isLikeFloat(field_len, digit_count, decimal_count, dash_count, exponent_count)) {
      atomicAdd(&column_infos[col].float_count, 1);
    }
    // A date-time field cannot have more than 3 non-special characters
    // A number field cannot have more than one decimal point
    else if (other_count > 3 || decimal_count > 1) {
      atomicAdd(&column_infos[col].string_count, 1);
    } else {
      // A date field can have either one or two '-' or '\'; A legal combination will only have one of them
      // To simplify the process of auto column detection, we are not covering all the date-time formation permutations
      if ((dash_count > 0 && dash_count <= 2 && slash_count == 0) ||
          (dash_count == 0 && slash_count > 0 && slash_count <= 2)) {
        if (colon_count <= 2) {
          atomicAdd(&column_infos[col].datetime_count, 1);
        } else {
          atomicAdd(&column_infos[col].string_count, 1);
        }
      } else {
        // Default field type is string
        atomicAdd(&column_infos[col].string_count, 1);
      }
    }
    start = field_end + 1;
  }
}

void JsonReader::detectDataTypes(ColumnInfo *column_infos) {
  int block_size;
  int min_grid_size;
  CUDA_TRY(cudaOccupancyMaxPotentialBlockSize(&min_grid_size, &block_size, detectJsonDataTypes));

  // Calculate actual block count to use based on records count
  const int grid_size = (rec_starts_.size() + block_size - 1) / block_size;

  detectJsonDataTypes<<<grid_size, block_size>>>(d_data_.data(), d_data_.size(), opts_, column_names_.size(),
                                                 rec_starts_.data(), rec_starts_.size(), column_infos);

  CUDA_TRY(cudaGetLastError());
}

void JsonReader::setDataTypes() {
  if (args_->dtype != nullptr) {
    CUDF_EXPECTS(args_->num_cols != 0, "Number of columns must be greated than zero.\n");
    CUDF_EXPECTS(args_->num_cols == (int)column_names_.size(), "Need to specify the type of each column.\n");
    std::vector<std::string> typestrings(args_->num_cols);
    for (int col = 0; col < args_->num_cols; ++col) {
      typestrings[col] = std::string(args_->dtype[col]);
    }
    // Assume that the dtype is in dictionary format only if all elements contain a colon
    const bool is_dict = std::all_of(typestrings.begin(), typestrings.end(),
                                     [](std::string &s) { return std::find(s.begin(), s.end(), ':') != s.end(); });
    if (is_dict) {
      std::map<std::string, gdf_dtype> col_type_map;
      for (const auto &ts : typestrings) {
        const size_t colon_idx = ts.find(":");
        const std::string col_name(ts.begin(), ts.begin() + colon_idx);
        const std::string type_str(ts.begin() + colon_idx + 1, ts.end());
        col_type_map[col_name] = convertStringToDtype(type_str);
      }

      // Using the map here allows O(n log n) complexity
      for (int col = 0; col < args_->num_cols; ++col) {
        dtypes_.push_back(col_type_map[column_names_[col]]);
      }
    } else {
      for (int col = 0; col < args_->num_cols; ++col) {
        dtypes_.push_back(convertStringToDtype(args_->dtype[col]));
      }
    }
  } else {
    CUDF_EXPECTS(rec_starts_.size() != 0, "No data available for data type inference.\n");
    const auto num_columns = column_names_.size();

    rmm::device_vector<ColumnInfo> d_column_infos(num_columns, ColumnInfo{});
    detectDataTypes(d_column_infos.data().get());
    thrust::host_vector<ColumnInfo> h_column_infos = d_column_infos;

    for (const auto &cinfo : h_column_infos) {
      CUDF_EXPECTS(cinfo.null_count == 0, "All fields must contain valid objects.\n");

      if (cinfo.string_count > 0) {
        dtypes_.push_back(GDF_STRING);
      } else if (cinfo.datetime_count > 0) {
        dtypes_.push_back(GDF_DATE64);
      } else if (cinfo.float_count > 0) {
        dtypes_.push_back(GDF_FLOAT64);
      } else if (cinfo.int_count > 0) {
        dtypes_.push_back(GDF_INT64);
      } else {
        CUDF_FAIL("Data type detection failed.\n");
      }
    }
  }
}
