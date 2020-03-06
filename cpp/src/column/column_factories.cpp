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

#include <cudf/column/column_factories.hpp>
#include <cudf/null_mask.hpp>
#include <cudf/strings/detail/fill.hpp>
#include <cudf/detail/fill.hpp>
#include <cudf/utilities/error.hpp>
#include <cudf/utilities/traits.hpp>

#include <thrust/iterator/constant_iterator.h>

namespace cudf {
namespace {
struct size_of_helper {
  template <typename T>
  constexpr std::enable_if_t<not is_fixed_width<T>(), int> operator()() const {
    CUDF_FAIL("Invalid, non fixed-width element type.");
  }

  template <typename T>
  constexpr std::enable_if_t<is_fixed_width<T>(), int> operator()() const
      noexcept {
    return sizeof(T);
  }
};
}  // namespace

std::size_t size_of(data_type element_type) {
  CUDF_EXPECTS(is_fixed_width(element_type), "Invalid element type.");
  return cudf::experimental::type_dispatcher(element_type, size_of_helper{});
}

// Empty column of specified type
std::unique_ptr<column> make_empty_column(data_type type) {
  return std::make_unique<column>(type, 0, rmm::device_buffer{});
}

// Allocate storage for a specified number of numeric elements
std::unique_ptr<column> make_numeric_column(
    data_type type, size_type size, mask_state state, cudaStream_t stream,
    rmm::mr::device_memory_resource* mr) {
  CUDF_EXPECTS(is_numeric(type), "Invalid, non-numeric type.");

  return std::make_unique<column>(
      type, size, rmm::device_buffer{size * cudf::size_of(type), stream, mr},
      create_null_mask(size, state, stream, mr), state_null_count(state, size),
      std::vector<std::unique_ptr<column>>{});
}

// Allocate storage for a specified number of timestamp elements
std::unique_ptr<column> make_timestamp_column(
    data_type type, size_type size, mask_state state, cudaStream_t stream,
    rmm::mr::device_memory_resource* mr) {
  CUDF_EXPECTS(is_timestamp(type), "Invalid, non-timestamp type.");

  return std::make_unique<column>(
      type, size, rmm::device_buffer{size * cudf::size_of(type), stream, mr},
      create_null_mask(size, state, stream, mr), state_null_count(state, size),
      std::vector<std::unique_ptr<column>>{});
}

// Allocate storage for a specified number of fixed width elements
std::unique_ptr<column> make_fixed_width_column(
    data_type type, size_type size, mask_state state, cudaStream_t stream,
    rmm::mr::device_memory_resource* mr) {
  CUDF_EXPECTS(is_fixed_width(type), "Invalid, non-fixed-width type.");
      
  if(is_timestamp(type)){
    return make_timestamp_column(type, size, state, stream, mr);
  }
  return make_numeric_column(type, size, state, stream, mr);  
}

struct column_from_scalar_dispatch 
{
  template <typename T>
  std::enable_if_t<cudf::is_fixed_width<T>(), std::unique_ptr<cudf::column>>
  operator()( scalar const& value, size_type size,
              rmm::mr::device_memory_resource* mr, cudaStream_t stream)
  {
    auto output_column = make_fixed_width_column(value.type(),size,mask_state::UNALLOCATED,stream,mr);
    auto view = output_column->mutable_view();
    experimental::detail::fill_in_place(view,0,size,value,stream);
    return output_column;
  }

  template <typename T>
  std::enable_if_t<std::is_same<cudf::string_view, T>::value, std::unique_ptr<cudf::column>>
  operator()( scalar const& value, size_type size,
              rmm::mr::device_memory_resource* mr, cudaStream_t stream)
  {
    auto p_scalar = static_cast<experimental::scalar_type_t<T> const*>(&value);
    auto null_mask = create_null_mask(size, mask_state::ALL_NULL, stream, mr);
    column_view sc{ data_type{STRING}, size, nullptr, 
                    static_cast<bitmask_type*>(null_mask.data()), size };
    auto output = cudf::strings::detail::fill(cudf::strings_column_view(sc),
                                              0, size, *p_scalar, mr, stream);
    output->set_null_mask(rmm::device_buffer{},0);
    return output;
  }
  
  template <typename T>
  std::enable_if_t<std::is_same<cudf::dictionary32, T>::value, std::unique_ptr<cudf::column>>
  operator()( scalar const& value, size_type size,
              rmm::mr::device_memory_resource* mr, cudaStream_t stream)
  {
    CUDF_FAIL("dictionary not supported when creating from scalar");
  }
};

std::unique_ptr<column> make_column_from_scalar(scalar const& s, size_type size,
    rmm::mr::device_memory_resource* mr, cudaStream_t stream )
{
  CUDF_EXPECTS( s.is_valid(), "scalar parameter must be valid");
  CUDF_EXPECTS( size > 0, "size parameter must be greater than zero");
  return experimental::type_dispatcher(s.type(), column_from_scalar_dispatch{}, 
                                       s, size, mr, stream );
}

}  // namespace cudf
