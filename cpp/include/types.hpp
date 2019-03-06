/*
 * Copyright (c) 2018-2019, NVIDIA CORPORATION.
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
#ifndef TYPES_HPP
#define TYPES_HPP

#include <algorithm>
#include <cassert>
#include "cudf.h"

namespace cudf {

/**
 * @brief A wrapper for a set of gdf_columns of equal number of rows.
 *
 */
struct table {
  /**---------------------------------------------------------------------------*
   * @brief Constructs a table object from an array of `gdf_column`s
   *
   * @param cols The array of columns wrapped by the table
   * @param num_cols  The number of columns in the array
   *---------------------------------------------------------------------------**/
  table(gdf_column* cols[], gdf_size_type num_cols)
      : columns{cols}, _num_columns{num_cols} {
    assert(nullptr != cols[0]);

    gdf_size_type const num_rows{cols[0]->size};

    std::for_each(columns, columns + _num_columns, [num_rows](gdf_column* col) {
      assert(nullptr != col);
      assert(num_rows == col->size);
    });
  }

  /**---------------------------------------------------------------------------*
   * @brief Returns pointer to the first `gdf_column` in the table.
   *
   *---------------------------------------------------------------------------**/
  gdf_column const* const* begin() const { return columns; }
  gdf_column** begin() { return columns; }

  /**---------------------------------------------------------------------------*
   * @brief Returns pointer to one past the last `gdf_column` in the table
   *
   *---------------------------------------------------------------------------**/
  gdf_column const* const* end() const { return columns + _num_columns; }
  gdf_column** end() { return columns + _num_columns; }

  /**---------------------------------------------------------------------------*
   * @brief Returns pointer to the column specified by an index.
   *
   * @param index The index of the desired column
   * @return gdf_column* Pointer to the column at `index`
   *---------------------------------------------------------------------------**/
  gdf_column* get_column(gdf_index_type index) {
    assert(index < _num_columns);
    return columns[index];
  }
  gdf_column const* get_column(gdf_index_type index) const {
    return columns[index];
  }

  /**---------------------------------------------------------------------------*
   * @brief Returns the number of columns in the table
   *
   *---------------------------------------------------------------------------**/
  gdf_size_type num_columns() const { return _num_columns; }

 private:
  gdf_column** columns;            /**< The set of gdf_columns*/
  gdf_size_type const _num_columns; /**< The number of columns in the set */
};

}  // namespace cudf

#endif
