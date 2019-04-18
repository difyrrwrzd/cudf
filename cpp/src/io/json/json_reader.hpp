# pragma once

#include <vector>

#include <cudf.h>

#include "io/utilities/wrapper_utils.hpp"

// DOXY
class JsonReader {
  const json_read_arg* args_ = nullptr;

  const char *h_uncomp_data_ = nullptr;
  size_t h_uncomp_size_ = 0;
  std::vector<gdf_column_wrapper> columns_;

  device_buffer<char> d_uncomp_data_;

  // tweaks/corner cases
  const bool allow_newlines_in_strings_ = false;

  const size_t byte_range_offset_ = 0;
  const size_t byte_range_size_ = 0;

  device_buffer<uint64_t> rec_starts_;

  device_buffer<uint64_t> enumerateNewlinesAndQuotes();
  device_buffer<uint64_t> filterNewlines(device_buffer<uint64_t> newlines_and_quotes);
  void uploadDataToDevice();
  void convertDataToColumns();
  void convertJsonToColumns(gdf_dtype * const dtypes, void **gdf_columns,
                            gdf_valid_type **valid, gdf_size_type *num_valid);
public:
  JsonReader(json_read_arg* args): args_(args){}

  void parse();

  void storeColumns(json_read_arg *out_args);
};