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

#include <cudf/types.hpp>
#include <cudf/groupby.hpp>

#include <memory>
#include <utility>

namespace cudf {
namespace experimental {
namespace groupby {
namespace detail {
namespace hash {
/**
 * @brief Heuristic that determines if a hash based groupby should be used to
 * satisfy the set of aggregation requests on `keys` with the specified
 * `options`.
 *
 * @param keys The table of keys
 * @param requests The set of columns to aggregate and the aggregations to
 * perform
 * @param options Controls behavior of the groupby
 * @return true A hash-based groupby should be used
 * @return false A hash-based groupby should not be used
 */
bool use_hash_groupby(table_view const& keys,
                      std::vector<aggregation_request> const& requests,
                      Options options);

// Hash-based groupby
std::pair<std::unique_ptr<table>, std::vector<std::unique_ptr<column>>> groupby(
    table_view const& keys, std::vector<aggregation_request> const& requests,
    Options options, cudaStream_t stream, rmm::mr::device_memory_resource* mr);
}  // namespace hash

namespace sort {
// Sort-based groupby
std::pair<std::unique_ptr<table>, std::vector<std::unique_ptr<column>>> groupby(
    table_view const& keys, std::vector<aggregation_request> const& requests,
    Options options, cudaStream_t stream, rmm::mr::device_memory_resource* mr);
}  // namespace sort

// Dispatch to hash vs. sort groupby
std::pair<std::unique_ptr<table>, std::vector<std::unique_ptr<column>>> groupby(
    table_view const& keys, std::vector<aggregation_request> const& requests,
    Options options, cudaStream_t stream = 0,
    rmm::mr::device_memory_resource* mr = rmm::mr::get_default_resource());
}  // namespace detail
}  // namespace groupby
}  // namespace experimental
}  // namespace cudf