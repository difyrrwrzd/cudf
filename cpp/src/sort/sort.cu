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

#include <cudf/column/column.hpp>
#include <cudf/column/column_factories.hpp>
#include <cudf/sorting.hpp>
#include <cudf/table/table_view.hpp>

namespace cudf {
namespace exp {

// Create permuted row indices that would materialize sorted order
std::unique_ptr<column> sorted_order(table_view input,
                                     std::vector<order> const& column_order,
                                     null_size size_of_nulls) {
  auto sorted_indices =
      cudf::make_numeric_column(data_type{INT32}, input.num_rows());

  return sorted_indices;
}
}  // namespace exp
}  // namespace cudf