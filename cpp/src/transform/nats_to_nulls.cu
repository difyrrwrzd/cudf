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

#include <bitmask/valid_if.cuh>

namespace cudf {

namespace detail {

template <typename T>
struct predicate_not_nat{

  CUDA_HOST_DEVICE_CALLABLE
  bool operator()(gdf_index_type index) const {
      return !(static_cast<T*>(input.data)[index] == LLONG_MIN);
  }

  gdf_column input;

  predicate_not_nat() = delete;

  predicate_not_nat(gdf_column const& input_): input(input_) {}

};

} // namespace detail

std::pair<bit_mask_t*, gdf_size_type> nats_to_nulls(gdf_column const& input){
  
  if(input.size == 0){
    return std::pair<bit_mask_t*, gdf_size_type>(nullptr, 0);
  }

  const bit_mask_t* source_mask = reinterpret_cast<bit_mask_t*>(input.valid);
  
  switch (input.dtype){
    case GDF_DATE64:
      return cudf::valid_if(source_mask, cudf::detail::predicate_not_nat<int64_t>(input), input.size);
    case GDF_TIMESTAMP:
      return cudf::valid_if(source_mask, cudf::detail::predicate_not_nat<int64_t>(input), input.size);
    default:
      CUDF_FAIL("Unsupported data type for NaT");
  }
}
//
} // namespace cudf
