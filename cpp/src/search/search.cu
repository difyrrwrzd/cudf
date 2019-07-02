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

#include <iterator/iterator.cuh>
#include <utilities/wrapper_types.hpp>
#include <utilities/column_utils.hpp>
#include <cudf/search.hpp>
#include <cudf/copying.hpp>
#include <rmm/thrust_rmm_allocator.h>

#include <thrust/binary_search.h>

#include <iostream>

namespace cudf {

namespace {

struct search_functor {
private:
  template <typename T>
  static constexpr bool is_supported() {
    // TODO: allow for all types which can be compared and have std::numeric_limits defined for
    return std::is_arithmetic<T>::value;
  }

public:
  template <typename T,
            typename std::enable_if_t<is_supported<T>()>* = nullptr>
  void operator()(gdf_column const& column,
                  gdf_column const& values,
                  bool find_first,
                  bool nulls_as_largest,
                  cudaStream_t stream,
                  gdf_column& result)
  {
    // TODO: handle nulls
    if ( is_nullable(column) ) {
      if (nulls_as_largest) {
        auto it_col = cudf::make_iterator<true, T>(column,
          std::numeric_limits<T>::max());
        auto it_val = cudf::make_iterator<true, T>(values,
          std::numeric_limits<T>::max());

        if (find_first) {
          thrust::lower_bound(rmm::exec_policy(stream)->on(stream),
                              it_col, it_col + column.size,
                              it_val, it_val + values.size,
                              static_cast<gdf_index_type*>(result.data));
        }
        else {
          thrust::upper_bound(rmm::exec_policy(stream)->on(stream),
                              it_col, it_col + column.size,
                              it_val, it_val + values.size,
                              static_cast<gdf_index_type*>(result.data));
        }
      }
      else {
        auto it_col = cudf::make_iterator<true, T>(column,
          std::numeric_limits<T>::lowest());
        auto it_val = cudf::make_iterator<true, T>(values,
          std::numeric_limits<T>::lowest());

        if (find_first) {
          thrust::lower_bound(rmm::exec_policy(stream)->on(stream),
                              it_col, it_col + column.size,
                              it_val, it_val + values.size,
                              static_cast<gdf_index_type*>(result.data));
        }
        else {
          thrust::upper_bound(rmm::exec_policy(stream)->on(stream),
                              it_col, it_col + column.size,
                              it_val, it_val + values.size,
                              static_cast<gdf_index_type*>(result.data));
        }
      }
    }
    else {
      auto it_col = cudf::make_iterator<false, T>(column);
      auto it_val = cudf::make_iterator<false, T>(values);

      if (find_first) {
        thrust::lower_bound(rmm::exec_policy(stream)->on(stream),
                            it_col, it_col + column.size,
                            it_val, it_val + values.size,
                            static_cast<gdf_index_type*>(result.data));
      }
      else {
        thrust::upper_bound(rmm::exec_policy(stream)->on(stream),
                            it_col, it_col + column.size,
                            it_val, it_val + values.size,
                            static_cast<gdf_index_type*>(result.data));
      }
    }

  }

  // TODO: clean up args here
  template <typename T,
            typename std::enable_if_t<!is_supported<T>()>* = nullptr>
  void operator()(gdf_column const& column,
                  gdf_column const& values,
                  bool find_first,
                  bool nulls_as_largest,
                  cudaStream_t stream,
                  gdf_column& result)
  {
    CUDF_FAIL("Unsupported datatype for search_ordered");
  }

};

} // namespace

namespace detail {

gdf_column search_ordered(gdf_column const& column,
                          gdf_column const& values,
                          bool find_first,
                          bool nulls_as_largest,
                          cudaStream_t stream = 0)
{
  validate(column);

  // Allocate result column
  gdf_column result_like{};
  result_like.dtype = GDF_INT32;
  result_like.size = values.size;
  result_like.data = values.data;
  // TODO: let result have nulls? this could be used for records not found
  auto result = allocate_like(result_like);

  type_dispatcher(column.dtype,
                  search_functor{},
                  column, values, find_first, nulls_as_largest, stream, result);

  return result;
}

} // namespace detail

gdf_column search_ordered(gdf_column const& column,
                          gdf_column const& values,
                          bool find_first,
                          bool nulls_as_largest)
{
  return detail::search_ordered(column, values, find_first, nulls_as_largest);
}

} // namespace cudf
