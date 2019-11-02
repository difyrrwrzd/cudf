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
#pragma once

#include <cudf/table/table.hpp>
#include <cudf/table/table_view.hpp>

namespace cudf {

struct hash_func {
  enum Type {
    MURMUR3 = 0, ///< Murmur3 hash function
    IDENTITY,    ///< Identity hash function that simply returns the key to be hashed
  };
};

/** --------------------------------------------------------------------------*
 * @brief Computes the hash values of the rows in the specified columns of the 
 * input columns and bins the hash values into the desired number of partitions. 
 * Rearranges the input columns such that rows with hash values in the same bin 
 * are contiguous.
 * 
 * @param input The table to partition
 * @param columns_to_hash Indices of input columns to hash
 * @param num_partitions The number of partitions to use
 * @param hash The hash function to use
 * @param mr Optional resource to use for device memory allocation
 * 
 * @returns A vector of tables partitioned from the input
 * ----------------------------------------------------------------------------**/
std::vector<std::unique_ptr<experimental::table>>
hash_partition(table_view const& input,
               std::vector<size_type> const& columns_to_hash,
               int num_partitions,
               hash_func::Type hash,
               rmm::mr::device_memory_resource* mr = rmm::mr::get_default_resource());

/** --------------------------------------------------------------------------*
 * @brief Computes the hash value of each row in the input set of columns.
 *
 * @param input The table of columns to hash
 * @param hash The hash function to use
 * @param initial_hash_values Optional vector of initial hash values for each
 * column. If this vector is empty then each element will be hashed as-is.
 * @param mr Optional resource to use for device memory allocation
 *
 * @returns A column where each row is the hash of a column from the input
 * ----------------------------------------------------------------------------**/
std::unique_ptr<column> hash(table_view const& input,
                             hash_func::Type hash,
                             std::vector<size_type> const& initial_hash_values,
                             rmm::mr::device_memory_resource* mr = rmm::mr::get_default_resource());

}  // namespace cudf
