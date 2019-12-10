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

#include "sort_helper.hpp"
#include <cudf/column/column.hpp>
#include <cudf/column/column_view.hpp>
#include <cudf/detail/groupby.hpp>
#include <cudf/groupby.hpp>
#include <cudf/table/table.hpp>
#include <cudf/table/table_view.hpp>
#include <cudf/types.hpp>

#include <memory>
#include <utility>

namespace cudf {
namespace experimental {
namespace groupby {
namespace detail {
namespace sort {
// Sort-based groupby
std::pair<std::unique_ptr<table>, std::vector<aggregation_result>> groupby(
    table_view const& keys, std::vector<aggregation_request> const& requests,
    bool ignore_null_keys, bool keys_are_sorted,
    std::vector<order> const& column_order,
    std::vector<null_order> const& null_precedence,
    cudaStream_t stream, rmm::mr::device_memory_resource* mr)
{

  // Sort keys using sort_helper
  // TODO (dm): sort helper should be stored in groupby object
  // TODO (dm): convert sort helper's include_nulls to ignore_nulls
  helper sorter(keys, not ignore_null_keys, null_precedence, keys_are_sorted);

  return std::make_pair(std::make_unique<table>(),
                        std::vector<aggregation_result>{});
}
}  // namespace sort
}  // namespace detail
}  // namespace groupby
}  // namespace experimental
}  // namespace cudf
