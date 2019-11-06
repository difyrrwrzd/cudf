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
#include <cudf/column/column_view.hpp>
#include <cudf/detail/groupby.hpp>
#include <cudf/groupby.hpp>
#include <cudf/table/table.hpp>
#include <cudf/table/table_view.hpp>
#include <cudf/types.hpp>
#include <cudf/utilities/error.hpp>

#include <memory>
#include <utility>

namespace cudf {
namespace experimental {
namespace groupby {
namespace detail {
// Dispatch to hash vs. sort groupby
std::pair<std::unique_ptr<table>, std::vector<std::unique_ptr<column>>>
dispatch_groupby(table_view const& keys,
                 std::vector<aggregation_request> const& requests,
                 cudaStream_t stream, rmm::mr::device_memory_resource* mr) {
  CUDF_EXPECTS(std::all_of(requests.begin(), requests.end(),
                           [keys](auto const& request) {
                             return request.values.size() == keys.num_rows();
                           }),
               "Size mismatch between request values and groupby keys.");

  if (keys.num_rows() == 0) {
    // TODO Return appropriately typed empty table/columns.
  }

  if (hash::use_hash_groupby(keys, requests)) {
    return hash::groupby(keys, requests, stream, mr);
  } else {
    return sort::groupby(keys, requests, stream, mr);
  }
}
}  // namespace detail

/// Factory to create a SUM aggregation
std::unique_ptr<aggregation> make_sum_aggregation() {
  return std::make_unique<aggregation>(aggregation::SUM);
}
/// Factory to create a MIN aggregation
std::unique_ptr<aggregation> make_min_aggregation() {
  return std::make_unique<aggregation>(aggregation::MIN);
}
/// Factory to create a MAX aggregation
std::unique_ptr<aggregation> make_max_aggregation() {
  return std::make_unique<aggregation>(aggregation::MAX);
}
/// Factory to create a COUNT aggregation
std::unique_ptr<aggregation> make_count_aggregation() {
  return std::make_unique<aggregation>(aggregation::COUNT);
}
/// Factory to create a MEAN aggregation
std::unique_ptr<aggregation> make_mean_aggregation() {
  return std::make_unique<aggregation>(aggregation::MEAN);
}
/// Factory to create a MEDIAN aggregation
std::unique_ptr<aggregation> make_median_aggregation() {
  // TODO I think this should just return a quantile_aggregation?
  return std::make_unique<aggregation>(aggregation::MEDIAN);
}
/// Factory to create a QUANTILE aggregation
std::unique_ptr<aggregation> make_quantile_aggregation(
    std::vector<double> const& quantiles, interpolation::type interpolation) {
  aggregation* a = new quantile_aggregation{quantiles, interpolation};
  return std::unique_ptr<aggregation>(a);
}

groupby::groupby(table_view const& keys, bool ignore_null_keys,
                 bool keys_are_sorted, std::vector<order> const& column_order,
                 std::vector<null_order> const& null_precedence)
    : _keys{keys},
      _ignore_null_keys{ignore_null_keys},
      _keys_are_sorted{keys_are_sorted},
      _column_order{column_order},
      _null_precedence{null_precedence} {}

std::pair<std::unique_ptr<table>, std::vector<std::unique_ptr<column>>>
groupby::aggregate(std::vector<aggregation_request> const& requests,
                   rmm::mr::device_memory_resource* mr) {

  return detail::dispatch_groupby(_keys, requests, 0, mr);
}
}  // namespace groupby
}  // namespace experimental
}  // namespace cudf