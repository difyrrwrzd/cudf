#include "json_reader.hpp"

#include <cuda_runtime.h>

#include <algorithm>
#include <iostream>
#include <numeric>
#include <string>
#include <vector>
#include <memory>

#include <stdio.h>
#include <stdlib.h>

#include <unistd.h>
#include <fcntl.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <sys/mman.h>

#include <thrust/scan.h>
#include <thrust/reduce.h>
#include <thrust/device_ptr.h>
#include <thrust/execution_policy.h>

#include <thrust/host_vector.h>

#include "../csv/type_conversion.cuh"

#include "cudf.h"
#include "utilities/error_utils.hpp"
#include "utilities/trie.cuh"
#include "utilities/type_dispatcher.hpp"
#include "utilities/cudf_utils.h" 

#include "rmm/rmm.h"
#include "rmm/thrust_rmm_allocator.h"
#include "io/comp/io_uncomp.h"

#include "io/utilities/parsing_utils.cuh"
#include "io/utilities/wrapper_utils.hpp"

using string_pair = std::pair<const char*,size_t>;

gdf_error read_json(json_read_arg *args) {
  JsonReader reader(args);

  reader.parse();

  reader.storeColumns(args);

  return GDF_SUCCESS;
}

/*
 * Convert dtype strings into gdf_dtype enum
 */
gdf_dtype convertStringToDtype(const std::string &dtype) {
  if (dtype.compare( "str") == 0) return GDF_STRING;
  if (dtype.compare( "date") == 0) return GDF_DATE64;
  if (dtype.compare( "date32") == 0) return GDF_DATE32;
  if (dtype.compare( "date64") == 0) return GDF_DATE64;
  if (dtype.compare( "timestamp") == 0) return GDF_TIMESTAMP;
  if (dtype.compare( "category") == 0) return GDF_CATEGORY;
  if (dtype.compare( "float") == 0) return GDF_FLOAT32;
  if (dtype.compare( "float32") == 0) return GDF_FLOAT32;
  if (dtype.compare( "float64") == 0) return GDF_FLOAT64;
  if (dtype.compare( "double") == 0) return GDF_FLOAT64;
  if (dtype.compare( "short") == 0) return GDF_INT16;
  if (dtype.compare( "int") == 0) return GDF_INT32;
  if (dtype.compare( "int32") == 0) return GDF_INT32;
  if (dtype.compare( "int64") == 0) return GDF_INT64;
  if (dtype.compare( "long") == 0) return GDF_INT64;
  return GDF_invalid;
}

void JsonReader::parse(){
  // no file input and compression support for now
  h_uncomp_data_ = args_->source;
  h_uncomp_size_ = strlen(h_uncomp_data_);

  // Currently, ignoring lineterminations within quotes is handled by recording
  // the records of both, and then filtering out the records that is a quotechar
  // or a linetermination within a quotechar pair.
  rec_starts_ = filterNewlines(enumerateNewlinesAndQuotes());

  uploadDataToDevice();
  
  // Determine column names - only when lines are objects
  // TODO

  // Determine data types - require dtype for now
  CUDF_EXPECTS(args_->dtype != nullptr, "Data type inference is not supported!");

  // Allocate columns
  for (int col = 0; col < args_->num_cols; ++col) {
    columns_.emplace_back(rec_starts_.size(), convertStringToDtype(args_->dtype[col]), gdf_dtype_extra_info{TIME_UNIT_NONE}, std::to_string(col));
    CUDF_EXPECTS(columns_.back().allocate() == GDF_SUCCESS, "Cannot allocate columns");
  }

  convertDataToColumns();
}

device_buffer<uint64_t> JsonReader::enumerateNewlinesAndQuotes() {
  std::vector<char> chars_to_count{'\n'};
  if (allow_newlines_in_strings_) {
    chars_to_count.push_back('\"');
  }
  auto count = countAllFromSet(h_uncomp_data_, h_uncomp_size_, chars_to_count);
  // If not starting at an offset, add an extra row to account for the first row in the file
  if (byte_range_offset_ == 0) {
    ++count;
  }

  // Allocate space to hold the record starting points
  device_buffer<uint64_t> rec_starts(count); 
  auto* find_result_ptr = rec_starts.data();
  if (byte_range_offset_ == 0) {
    find_result_ptr++;
    CUDA_TRY(cudaMemsetAsync(rec_starts.data(), 0ull, sizeof(uint64_t)));
  }

  std::vector<char> chars_to_find{'\n'};
  if (allow_newlines_in_strings_) {
    chars_to_find.push_back('\"');
  }
  // Passing offset = 1 to return positions AFTER the found character
  findAllFromSet(h_uncomp_data_, h_uncomp_size_, chars_to_find, 1, find_result_ptr);

  // Previous call stores the record pinput_file.typeositions as encountered by all threads
  // Sort the record positions as subsequent processing may require filtering
  // certain rows or other processing on specific records
  thrust::sort(rmm::exec_policy()->on(0), rec_starts.data(), rec_starts.data() + count);

  return std::move(rec_starts);
}

device_buffer<uint64_t> JsonReader::filterNewlines(device_buffer<uint64_t> newlines_and_quotes) {
  const int prefilter_count = newlines_and_quotes.size();
  auto filtered_count = prefilter_count;

  if (allow_newlines_in_strings_) {
    std::vector<uint64_t> h_rec_starts(prefilter_count);
    const size_t prefilter_size = sizeof(uint64_t) * (prefilter_count);
    CUDA_TRY(cudaMemcpy(h_rec_starts.data(), newlines_and_quotes.data(), prefilter_size, cudaMemcpyDeviceToHost));
    for (auto elem: h_rec_starts)
      std::cout << elem << ' ';
    std::cout << '\n';

    bool quotation = false;
    for (gdf_size_type i = 1; i < prefilter_count; ++i) {
      if (h_uncomp_data_[h_rec_starts[i] - 1] == '\"') {
        quotation = !quotation;
        h_rec_starts[i] = h_uncomp_size_;
        filtered_count--;
      }
      else if (quotation) {
        h_rec_starts[i] = h_uncomp_size_;
        filtered_count--;
      }
    }

    CUDA_TRY(cudaMemcpy(newlines_and_quotes.data(), h_rec_starts.data(), prefilter_count, cudaMemcpyHostToDevice));
    thrust::sort(rmm::exec_policy()->on(0), newlines_and_quotes.data(), newlines_and_quotes.data() + prefilter_count);
  }
  if (h_uncomp_data_[h_uncomp_size_ - 1] == '\n') {
    filtered_count--;
  }

  newlines_and_quotes.resize(filtered_count);
  
  return newlines_and_quotes;
}

void JsonReader::uploadDataToDevice() {
  CUDF_EXPECTS(rec_starts_.size() > 0, "No data to process");
  size_t start_offset = 0;
  size_t bytes_to_upload = h_uncomp_size_;

  // Trim lines that are outside range
  if (byte_range_size_ != 0) {
    std::vector<uint64_t> h_rec_starts(rec_starts_.size());
    CUDA_TRY(cudaMemcpy(h_rec_starts.data(), rec_starts_.data(),
                        sizeof(uint64_t) * h_rec_starts.size(),
                        cudaMemcpyDefault));

    auto it = h_rec_starts.end() - 1;
    while (it >= h_rec_starts.begin() && *it > byte_range_size_) {
      --it;
    }
    const auto end_offset = *(it + 1);
    h_rec_starts.erase(it + 1, h_rec_starts.end());

    start_offset = h_rec_starts.front();
    bytes_to_upload = end_offset - start_offset;
    CUDF_EXPECTS(bytes_to_upload <= h_uncomp_size_,
      "Error finding the record within the specified byte range.");

    // Resize to exclude rows outside of the range; adjust row start positions to account for the data subcopy
    rec_starts_.resize(h_rec_starts.size());
    thrust::transform(rmm::exec_policy()->on(0), rec_starts_.data(),
                      rec_starts_.data() + rec_starts_.size(),
                      thrust::make_constant_iterator(start_offset),
                      rec_starts_.data(), thrust::minus<uint64_t>());
  }

  // Upload the raw data that is within the rows of interest
  d_uncomp_data_ = device_buffer<char>(bytes_to_upload);
  CUDA_TRY(cudaMemcpy(d_uncomp_data_.data(), h_uncomp_data_ + start_offset,
                      bytes_to_upload, cudaMemcpyHostToDevice));
}

void JsonReader::convertDataToColumns(){
  const auto num_columns = columns_.size();

  thrust::host_vector<gdf_dtype> h_dtypes(num_columns);
  thrust::host_vector<void*> h_data(num_columns);
  thrust::host_vector<gdf_valid_type*> h_valid(num_columns);

  for (size_t i = 0; i < num_columns; ++i) {
    h_dtypes[i] = columns_[i]->dtype;
    h_data[i] = columns_[i]->data;
    h_valid[i] = columns_[i]->valid;
  }

  rmm::device_vector<gdf_dtype> d_dtypes = h_dtypes;
  rmm::device_vector<void*> d_data = h_data;
  rmm::device_vector<gdf_valid_type*> d_valid = h_valid;
  rmm::device_vector<gdf_size_type> d_valid_counts(num_columns, 0);

  convertJsonToColumns(d_dtypes.data().get(), d_data.data().get(),
                       d_valid.data().get(), d_valid_counts.data().get());
  CUDA_TRY(cudaDeviceSynchronize());
  CUDA_TRY(cudaGetLastError());

  thrust::host_vector<gdf_size_type> h_valid_counts = d_valid_counts;
  for (size_t i = 0; i < num_columns; ++i) {
    columns_[i]->null_count = columns_[i]->size - h_valid_counts[i];
  }

  // handle string columns
}

void JsonReader::storeColumns(json_read_arg *out_args){

  // Transfer ownership to raw pointer output arguments
  out_args->data = (gdf_column **)malloc(sizeof(gdf_column *) * columns_.size());
  for (size_t i = 0; i < columns_.size(); ++i) {
    out_args->data[i] = columns_[i].release();
  }
  out_args->num_cols_out = columns_.size();
  out_args->num_rows_out = rec_starts_.size();
}

/**---------------------------------------------------------------------------*
 * @brief Functor for converting CSV data to cuDF data type value.
 *---------------------------------------------------------------------------**/
struct ConvertFunctor {
  /**---------------------------------------------------------------------------*
   * @brief Default template operator() dispatch
   *---------------------------------------------------------------------------**/
  template <typename T>
  __host__ __device__ __forceinline__ void operator()(
      const char *csvData, void *gdfColumnData, long rowIndex, long start,
      long end, const ParseOptions &opts) {
    T &value{static_cast<T *>(gdfColumnData)[rowIndex]};
    value = convertStrToValue<T>(csvData, start, end, opts);
  }
};

/**---------------------------------------------------------------------------*
 * @brief CUDA kernel iterates over the data until the end of the current field
 * 
 * Also iterates over (one or more) delimiter characters after the field.
 *
 * @param[in] raw_csv The entire CSV data to read
 * @param[in] opts A set of parsing options
 * @param[in] pos Offset to start the seeking from 
 * @param[in] stop Offset of the end of the row
 *
 * @return long position of the last character in the field, including the 
 *  delimiter(s) folloing the field data
 *---------------------------------------------------------------------------**/
__inline__ __device__ 
long seekFieldEnd(const char *data, const ParseOptions opts, long pos, long stop) {
  bool quotation  = false;
  while(true){
    // Use simple logic to ignore control chars between any quote seq
    // Handles nominal cases including doublequotes within quotes, but
    // may not output exact failures as PANDAS for malformed fields
    if(data[pos] == opts.quotechar){
      quotation = !quotation;
    }
    else if(quotation==false){
      if(data[pos] == opts.delimiter){
        while (opts.multi_delimiter &&
             pos < stop &&
             data[pos + 1] == opts.delimiter) {
          ++pos;
        }
        break;
      }
      else if(data[pos] == opts.terminator){
        break;
      }
      else if(data[pos] == '\r' && (pos + 1 < stop && data[pos + 1] == '\n')){
        stop--;
        break;
      }
    }
    if(pos>=stop)
      break;
    pos++;
  }
  return pos;
}

__inline__ __device__ long whichBitmap(long record) { return (record/8);  }
__inline__ __device__ int whichBit(long record) { return (record % 8);  }

__inline__ __device__ void validAtomicOR(gdf_valid_type* address, gdf_valid_type val)
{
	int32_t *base_address = (int32_t*)((gdf_valid_type*)address - ((size_t)address & 3));
	int32_t int_val = (int32_t)val << (((size_t) address & 3) * 8);

	atomicOr(base_address, int_val);
}

__inline__ __device__ void setBit(gdf_valid_type* address, int bit) {
	gdf_valid_type bitMask[8] 		= {1, 2, 4, 8, 16, 32, 64, 128};
	validAtomicOR(address, bitMask[bit]);
}

/**---------------------------------------------------------------------------*
 * @brief CUDA kernel that parses and converts CSV data into cuDF column data.
 * 
 * Data is processed one record at a time
 *
 * @param[in] raw_csv The entire CSV data to read
 * @param[in] opts A set of parsing options
 * @param[in] num_records The number of lines/rows of CSV data
 * @param[in] num_columns The number of columns of CSV data
 * @param[in] parseCol Whether to parse or skip a column
 * @param[in] recStart The start the CSV data of interest
 * @param[in] dtype The data type of the column
 * @param[out] gdf_data The output column data
 * @param[out] valid The bitmaps indicating whether column fields are valid
 * @param[out] num_valid The numbers of valid fields in columns
 *
 * @return gdf_error GDF_SUCCESS upon completion
 *---------------------------------------------------------------------------**/
__global__ void convertCsvToGdf(char * const data, size_t data_size,
                                uint64_t * const rec_starts, gdf_size_type num_records,
                                gdf_dtype * const dtypes, ParseOptions opts,
                                void ** gdf_columns, int num_columns, 
                                gdf_valid_type **valid_fields, gdf_size_type *num_valid_fields) {
  const long  rec_id  = threadIdx.x + (blockDim.x * blockIdx.x);
  if ( rec_id >= num_records)
    return;

  
  long start = rec_starts[rec_id];
  // has the same semantics as end() in STL containers (one past last element)
  long stop = ((rec_id < num_records - 1) ? rec_starts[rec_id + 1] : data_size);

  // Adjust for brackets
  while(data[start++] != '[');
  while(data[--stop] != ']');

  for (int col = 0; col < num_columns; col++){

    if(start >= stop)
      return;

    // field_end is at the next delimiter/newline
    const long field_end = seekFieldEnd(data, opts, start, stop);
    long field_data_last = field_end - 1;
    // Modify start & end to ignore whitespace and quotechars
    if(dtypes[col] != gdf_dtype::GDF_CATEGORY && dtypes[col] != gdf_dtype::GDF_STRING){
      adjustForWhitespaceAndQuotes(data, &start, &field_data_last, opts.quotechar);
    }
    // Empty fields are not legal values
    if(start <= field_data_last) {
      // Type dispatcher does not handle GDF_STRINGS
      if (dtypes[col] == gdf_dtype::GDF_STRING) {
        auto str_list = static_cast<string_pair*>(gdf_columns[col]);
        str_list[rec_id].first = data + start;
        str_list[rec_id].second = field_data_last - start + 1;
      } else {
        cudf::type_dispatcher(
          dtypes[col], ConvertFunctor{}, data,
          gdf_columns[col], rec_id, start, field_data_last, opts);
      }

      // set the valid bitmap - all bits were set to 0 to start
      long bitmapIdx = whichBitmap(rec_id);
      long bitIdx = whichBit(rec_id);
      setBit(valid_fields[col] + bitmapIdx, bitIdx);
      atomicAdd(&num_valid_fields[col], 1);
    }
    else if(dtypes[col] == gdf_dtype::GDF_STRING){
      auto str_list = static_cast<string_pair*>(gdf_columns[col]);
      str_list[rec_id].first = nullptr;
      str_list[rec_id].second = 0;
    }
    start = field_end + 1;
  }
}

/**---------------------------------------------------------------------------*
 * @brief Helper function to setup and launch CSV parsing CUDA kernel.
 * 
 * @param[in,out] raw_csv The metadata for the CSV data
 * @param[out] gdf The output column data
 * @param[out] valid The bitmaps indicating whether column fields are valid
 * @param[out] str_cols The start/end offsets for string data types
 * @param[out] num_valid The numbers of valid fields in columns
 *
 * @return gdf_error GDF_SUCCESS upon completion
 *---------------------------------------------------------------------------**/
void JsonReader::convertJsonToColumns(gdf_dtype * const dtypes, void **gdf_columns,
                                      gdf_valid_type **valid, gdf_size_type *num_valid) {
  int block_size;
  int min_grid_size;
  CUDA_TRY(cudaOccupancyMaxPotentialBlockSize(&min_grid_size, &block_size, convertCsvToGdf));

  const int grid_size = (rec_starts_.size() + block_size - 1)/block_size;
  const ParseOptions opts{',', '\n', '\"','.'};

  convertCsvToGdf <<< grid_size, block_size >>> (
    d_uncomp_data_.data(), d_uncomp_data_.size(),
    rec_starts_.data(), rec_starts_.size(),
    dtypes, opts,
    gdf_columns, columns_.size(),
    valid, num_valid);

  CUDA_TRY(cudaGetLastError());
}
