/*
 * Copyright (c) 2020, NVIDIA CORPORATION.
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
#pragma once

#include <cudf/column/column.hpp>
#include <cudf/column/column_view.hpp>

namespace cudf {

/**
 * @brief Given a column-view of lists type, an instance of this class
 * provides a wrapper on this compound column for list operations.
 */
class lists_column_view : private column_view {
 public:
  lists_column_view(column_view const& lists_column);
  lists_column_view(lists_column_view&& lists_view)      = default;
  lists_column_view(const lists_column_view& lists_view) = default;
  ~lists_column_view()                                   = default;
  lists_column_view& operator=(lists_column_view const&) = default;
  lists_column_view& operator=(lists_column_view&&) = default;

  using column_view::has_nulls;
  using column_view::null_count;
  using column_view::null_mask;
  using column_view::offset;
  using column_view::size;

  /**
   * @brief Returns the parent column.
   */
  column_view parent() const;

  /**
   * @brief Returns the internal column of offsets
   *
   * @throw cudf::logic error if this is an empty column
   */
  column_view offsets() const;

  /**
   * @brief Returns the internal child column
   *
   * @throw cudf::logic error if this is an empty column
   */
  column_view child() const;
};

}  // namespace cudf
