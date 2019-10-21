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

#include <cudf/column/column_view.hpp>
#include <cudf/null_mask.hpp>
#include <cudf/types.hpp>
#include <cudf/utilities/traits.hpp>
#include <utilities/error_utils.hpp>

#include <exception>
#include <vector>

namespace cudf {

namespace detail {
column_view_base::column_view_base(data_type type, size_type size,
                                   void const* data,
                                   bitmask_type const* null_mask,
                                   size_type null_count, size_type offset)
    : _type{type},
      _size{size},
      _data{data},
      _null_mask{null_mask},
      _null_count{null_count},
      _offset{offset} {
  CUDF_EXPECTS(size >= 0, "Column size cannot be negative.");

  if (type.id() == EMPTY) {
    _null_count = size;
    CUDF_EXPECTS(nullptr == data, "EMPTY column should have no data.");
    CUDF_EXPECTS(nullptr == null_mask,
                 "EMPTY column should have no null mask.");
  }
  else if ( is_compound(type) ) {
    CUDF_EXPECTS(nullptr == data, "Compound (parent) columns cannot have data");
  } else if( size > 0){
    CUDF_EXPECTS(nullptr != data, "Null data pointer.");	   
  }

  CUDF_EXPECTS(offset >= 0, "Invalid offset.");

  if ((null_count > 0) and (type.id() != EMPTY)) {
    CUDF_EXPECTS(nullptr != null_mask,
                 "Invalid null mask for non-zero null count.");
  }
}

// If null count is known, returns it. Else, compute and return it
size_type column_view_base::null_count() const {
  if (_null_count <= cudf::UNKNOWN_NULL_COUNT) {
    _null_count = cudf::count_unset_bits(null_mask(), offset(), offset()+size());
  }
  return _null_count;
}
}  // namespace detail

// Immutable view constructor
column_view::column_view(data_type type, size_type size, void const* data,
                         bitmask_type const* null_mask, size_type null_count,
                         size_type offset,
                         std::vector<column_view> const& children)
    : detail::column_view_base{type, size, data, null_mask, null_count, offset},
      _children{children} {
  if (type.id() == EMPTY) {
    CUDF_EXPECTS(num_children() == 0, "EMPTY column cannot have children.");
  }
}

// Slicer for immutable view
std::unique_ptr<column_view> column_view::slice(size_type slice_offset, 
                                                size_type slice_size) const {
   size_type expecetd_size = offset() + slice_offset + slice_size;
   CUDF_EXPECTS(slice_size >= 0, "size should be non negative value");
   CUDF_EXPECTS(slice_offset >= 0, "offset should be non negative value");
   CUDF_EXPECTS(expecetd_size <= size(), "Expected slice exceeds the size of the column_view");

   // If an empty `column_view` is created, it will not have null_mask. So this will help in
   // comparing in such situation.
   auto tmp_null_mask = (slice_size > 0)? null_mask() : nullptr;

   return std::make_unique<column_view>(type(), slice_size, 
                                        head(), tmp_null_mask,
                                        cudf::UNKNOWN_NULL_COUNT, 
                                        offset() + slice_offset, _children);
}


// Mutable view constructor
mutable_column_view::mutable_column_view(
    data_type type, size_type size, void* data, bitmask_type* null_mask,
    size_type null_count, size_type offset,
    std::vector<mutable_column_view> const& children)
    : detail::column_view_base{type, size, data, null_mask, null_count, offset},
      mutable_children{children} {
  if (type.id() == EMPTY) {
    CUDF_EXPECTS(num_children() == 0, "EMPTY column cannot have children.");
  }
}

// Update the null count
void mutable_column_view::set_null_count(size_type new_null_count) {
  if (new_null_count > 0) {
    CUDF_EXPECTS(nullable(), "Invalid null count.");
  }
  _null_count = new_null_count;
}

// Conversion from mutable to immutable
mutable_column_view::operator column_view() const {
  // Convert children to immutable views
  std::vector<column_view> child_views(num_children());
  std::copy(std::cbegin(mutable_children), std::cend(mutable_children),
            std::begin(child_views));
  return column_view{_type,
                     _size,
                     _data,
                     _null_mask,
                     _null_count,
                     _offset,
                     std::move(child_views)};
}

size_type count_descendants(column_view parent) {
  size_type count{parent.num_children()};
  for (size_type i = 0; i < parent.num_children(); ++i) {
    count += count_descendants(parent.child(i));
  }
  return count;
}

}  // namespace cudf
