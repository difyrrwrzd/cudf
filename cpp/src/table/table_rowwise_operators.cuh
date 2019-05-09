/*
 * Copyright 2019 BlazingDB, Inc.
 *     Copyright 2019 William Scott Malpica <william@blazingdb.com>
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

#ifndef TABLE_ROWWISE_OPERATIONS_CUH
#define TABLE_ROWWISE_OPERATIONS_CUH

#include <cudf.h>
#include "table/device_table.cuh"

namespace
{
enum class State
{
  False = 0,
  True = 1,
  Undecided = 2
};

namespace
{
struct elements_are_equal
{
  template <typename ColumnType>
  __device__ __forceinline__ bool operator()(gdf_column const &lhs,
                                             gdf_size_type lhs_index,
                                             gdf_column const &rhs,
                                             gdf_size_type rhs_index,
                                             bool nulls_are_equal = false)
  {
    bool const lhs_is_valid{gdf_is_valid(lhs.valid, lhs_index)};
    bool const rhs_is_valid{gdf_is_valid(rhs.valid, rhs_index)};

    // If both values are non-null, compare them
    if (lhs_is_valid and rhs_is_valid)
    {
      return static_cast<ColumnType const *>(lhs.data)[lhs_index] ==
             static_cast<ColumnType const *>(rhs.data)[rhs_index];
    }

    // If both values are null
    if (not lhs_is_valid and not rhs_is_valid)
    {
      return nulls_are_equal;
    }

    // If only one value is null, they can never be equal
    return false;
  }
};
} // namespace

struct equality_comparator
{

  equality_comparator(device_table const &lhs, bool nulls_are_equal = false) : _lhs(lhs), _rhs(lhs), _nulls_are_equal(nulls_are_equal)
  {
  }
  equality_comparator(device_table const &lhs, device_table const &rhs,
                      bool nulls_are_equal = false) : _lhs(lhs), _rhs(rhs), _nulls_are_equal(nulls_are_equal)
  {
  }

  __device__ inline bool operator()(gdf_index_type lhs_index, gdf_index_type rhs_index)
  {

    bool nulls_are_equal = this->_nulls_are_equal;
    auto equal_elements = [lhs_index, rhs_index, nulls_are_equal](
                              gdf_column const &l, gdf_column const &r) {
      return cudf::type_dispatcher(l.dtype, elements_are_equal{}, l, lhs_index, r,
                                   rhs_index, nulls_are_equal);
    };

    return thrust::equal(thrust::seq, _lhs.begin(), _lhs.end(), _rhs.begin(),
                         equal_elements);
  }

private:
  device_table const _lhs;
  device_table const _rhs;
  bool _nulls_are_equal;
};

/**
 * @brief  Checks for equality between two rows between two tables.
 *
 * @param lhs The left table
 * @param lhs_index The index of the row in the rhs table to compare
 * @param rhs The right table
 * @param rhs_index The index of the row within rhs table to compare
 * @param nulls_are_equal Flag indicating whether two null values are considered
 * equal
 *
 * @returns true If the two rows are element-wise equal
 * @returns false If any element differs between the two rows
 */
__device__ inline bool rows_equal(device_table const &lhs,
                                  const gdf_size_type lhs_index,
                                  device_table const &rhs,
                                  const gdf_size_type rhs_index,
                                  bool nulls_are_equal = false)
{
  auto equal_elements = [lhs_index, rhs_index, nulls_are_equal](
                            gdf_column const &l, gdf_column const &r) {
    return cudf::type_dispatcher(l.dtype, elements_are_equal{}, l, lhs_index, r,
                                 rhs_index, nulls_are_equal);
  };

  return thrust::equal(thrust::seq, lhs.begin(), lhs.end(), rhs.begin(),
                       equal_elements);
}

//     const void *const * _vals;

// };

struct typed_inequality_comparator
{
  template <typename ColType>
  __device__
      State
      operator()(gdf_index_type lhs_row, gdf_index_type rhs_row,
                 gdf_column const *lhs_column, gdf_column const *rhs_column,
                 bool nulls_are_smallest)
  {
    const ColType lhs_data = static_cast<const ColType *>(lhs_column->data)[lhs_row];
    const ColType rhs_data = static_cast<const ColType *>(rhs_column->data)[rhs_row];

    if (lhs_data < rhs_data)
      return State::True;
    else if (lhs_data == rhs_data)
      return State::Undecided;
    else
      return State::False;
  }
};

struct typed_inequality_with_nulls_comparator
{
  template <typename ColType>
  __device__
      State
      operator()(gdf_index_type lhs_row, gdf_index_type rhs_row,
                 gdf_column const *lhs_column, gdf_column const *rhs_column,
                 bool nulls_are_smallest)
  {
    const ColType lhs_data = static_cast<const ColType *>(lhs_column->data)[lhs_row];
    const ColType rhs_data = static_cast<const ColType *>(rhs_column->data)[rhs_row];
    const bool isValid1 = gdf_is_valid(lhs_column->valid, lhs_row);
    const bool isValid2 = gdf_is_valid(rhs_column->valid, rhs_row);

    if (!isValid2 && !isValid1)
      return State::Undecided;
    else if (isValid1 && isValid2)
    {
      if (lhs_data < rhs_data)
        return State::True;
      else if (lhs_data == rhs_data)
        return State::Undecided;
      else
        return State::False;
    }
    else if (!isValid1 && nulls_are_smallest)
      return State::True;
    else if (!isValid2 && !nulls_are_smallest)
      return State::True;
    else
      return State::False;
  }
};
} // namespace

struct inequality_comparator
{

  inequality_comparator(device_table const &lhs, bool nulls_are_smallest = true, int8_t *const asc_desc_flags = nullptr) : _lhs(lhs), _rhs(lhs), _nulls_are_smallest(nulls_are_smallest), _asc_desc_flags(asc_desc_flags)
  {
    _has_nulls = _lhs.has_nulls();
  }
  inequality_comparator(device_table const &lhs, device_table const &rhs,
                        bool nulls_are_smallest = true, int8_t *const asc_desc_flags = nullptr) : _lhs(lhs), _rhs(rhs), _nulls_are_smallest(nulls_are_smallest), _asc_desc_flags(asc_desc_flags)
  {
    _has_nulls = _lhs.has_nulls() || _rhs.has_nulls();
  }

  __device__ inline bool operator()(gdf_index_type lhs_index, gdf_index_type rhs_index)
  {

    State state = State::Undecided;
    if (_has_nulls)
    {
      for (gdf_size_type col_index = 0; col_index < _lhs.num_columns(); ++col_index)
      {
        gdf_dtype col_type = _lhs.get_column(col_index)->dtype;

        bool asc = _asc_desc_flags == nullptr || _asc_desc_flags[col_index] == GDF_ORDER_ASC;

        if (asc)
        {
          state = cudf::type_dispatcher(col_type, typed_inequality_with_nulls_comparator{},
                                        lhs_index, rhs_index,
                                        _lhs.get_column(col_index), _rhs.get_column(col_index),
                                        _nulls_are_smallest);
        }
        else
        {
          state = cudf::type_dispatcher(col_type, typed_inequality_with_nulls_comparator{},
                                        rhs_index, lhs_index,
                                        _rhs.get_column(col_index), _lhs.get_column(col_index),
                                        _nulls_are_smallest);
        }

        switch (state)
        {
        case State::False:
          return false;
        case State::True:
          return true;
        case State::Undecided:
          break;
        }
      }
    }
    else
    {
      for (gdf_size_type col_index = 0; col_index < _lhs.num_columns(); ++col_index)
      {
        gdf_dtype col_type = _lhs.get_column(col_index)->dtype;

        bool asc = _asc_desc_flags == nullptr || _asc_desc_flags[col_index] == GDF_ORDER_ASC;

        if (asc)
        {
          state = cudf::type_dispatcher(col_type, typed_inequality_comparator{},
                                        lhs_index, rhs_index,
                                        _lhs.get_column(col_index), _rhs.get_column(col_index),
                                        asc);
        }
        else
        {
          state = cudf::type_dispatcher(col_type, typed_inequality_comparator{},
                                        rhs_index, lhs_index,
                                        _rhs.get_column(col_index), _lhs.get_column(col_index),
                                        asc);
        }

        switch (state)
        {
        case State::False:
          return false;
        case State::True:
          return true;
        case State::Undecided:
          break;
        }
      }
    }
    return false;
  }

private:
  device_table const _lhs;
  device_table const _rhs;
  bool _nulls_are_smallest;
  int8_t *const _asc_desc_flags;
  bool _has_nulls;