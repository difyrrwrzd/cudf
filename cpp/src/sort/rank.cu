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

#include <cudf/column/column.hpp>
#include <cudf/column/column_factories.hpp>
#include <cudf/sorting.hpp>
#include <cudf/detail/sorting.hpp>
#include <cudf/table/row_operators.cuh>
#include <cudf/table/table_device_view.cuh>
#include <cudf/table/table_view.hpp>
#include <cudf/utilities/error.hpp>
#include <cudf/detail/gather.hpp>

#include <rmm/thrust_rmm_allocator.h>
#include <thrust/sequence.h>

namespace cudf {
namespace experimental {
namespace detail {

template<bool has_nulls, typename ReturnType = bool>
struct unique_comparator {
  unique_comparator(table_device_view device_table,
                    size_type const *sorted_order)
      : comp(device_table, device_table, true), perm(sorted_order) {}
  __device__ ReturnType operator()(size_type index) const noexcept{
    return index == 0 || not comp(perm[index], perm[index - 1]);
  };
  private:
  row_equality_comparator<has_nulls> comp;
  size_type const* perm;
};

std::unique_ptr<table> rank(
    table_view const& input,
    rank_method method,
    order column_order,
    include_nulls _include_nulls,
    null_order null_precedence,
    rmm::mr::device_memory_resource* mr,
    cudaStream_t stream=0) {
  //na_option=keep assign NA to NA values
  if(_include_nulls == include_nulls::NO)
    null_precedence = null_order::AFTER;
  auto const size = input.num_rows();
  
  std::vector<std::unique_ptr<column>> rank_columns;
  for (auto const& input_col : input) {
    std::unique_ptr<column> sorted_order =
        (method == rank_method::FIRST)
            ? detail::stable_sorted_order(
                table_view{{input_col}}, {column_order}, {null_precedence}, mr, stream)
            : detail::sorted_order(
                table_view{{input_col}}, {column_order}, {null_precedence}, mr, stream);
    column_view sorted_order_view = sorted_order->view();

    if(_include_nulls == include_nulls::NO)
      rank_columns.push_back(
          make_numeric_column(data_type(FLOAT64), size,
                              copy_bitmask(input_col, stream, mr),
                              input_col.null_count(), stream, mr));
    else
      rank_columns.push_back(make_numeric_column(
          data_type(FLOAT64), size, mask_state::UNALLOCATED, stream, mr));

    auto rank_mutable_view = rank_columns.back()->mutable_view();
    auto rank_data = rank_mutable_view.data<double>();
    auto device_table = table_device_view::create(table_view{{input_col}}, stream);

    switch (method) {
    case rank_method::FIRST:
      thrust::scatter(
          rmm::exec_policy(stream)->on(stream),
          thrust::make_counting_iterator<double>(1),
          thrust::make_counting_iterator<double>(input_col.size() + 1),
          sorted_order_view.begin<size_type>(), rank_data);
      break;
    case rank_method::DENSE: {
      rmm::device_vector<double> rank_sorted(input_col.size());
      if (input_col.has_nulls()) {
        auto conv = unique_comparator<true, double>(
            *device_table, sorted_order_view.data<size_type>());
        auto it = thrust::make_transform_iterator(
            thrust::make_counting_iterator<size_type>(0), conv);
        thrust::inclusive_scan(rmm::exec_policy(stream)->on(stream), it,
                               it + input_col.size(), rank_sorted.data().get());
      } else {
        auto conv = unique_comparator<false, double>(
            *device_table, sorted_order_view.data<size_type>());
        auto it = thrust::make_transform_iterator(
            thrust::make_counting_iterator<size_type>(0), conv);
        thrust::inclusive_scan(rmm::exec_policy(stream)->on(stream), it,
                               it + input_col.size(), rank_sorted.data().get());
      }
      thrust::scatter(rmm::exec_policy(stream)->on(stream), rank_sorted.begin(),
                      rank_sorted.end(), sorted_order_view.begin<size_type>(),
                      rank_data);
      break;
    }
    default:
      CUDF_FAIL("Unexpected rank_method for rank()");
    }
  }
  return std::make_unique<table>(std::move(rank_columns));
}
}  // namespace detail

std::unique_ptr<table> rank(table_view input,
                             rank_method method,
                             order column_order,
                             include_nulls _include_nulls,
                             null_order null_precedence,
                             rmm::mr::device_memory_resource* mr) {
    return detail::rank(input, method, column_order, _include_nulls, null_precedence, mr);
}
}  // namespace experimental
}  // namespace cudf
