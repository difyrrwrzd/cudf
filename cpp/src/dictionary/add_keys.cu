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
#include <cudf/copying.hpp>
#include <cudf/stream_compaction.hpp>
#include <cudf/detail/stream_compaction.hpp>
#include <cudf/detail/gather.hpp>
#include <cudf/search.hpp>
#include <cudf/table/table.hpp>
#include <cudf/table/table_view.hpp>
#include <cudf/dictionary/update_keys.hpp>

#include <rmm/thrust_rmm_allocator.h>
#include <thrust/tabulate.h>

namespace cudf
{
namespace dictionary
{
namespace detail
{

/**
 * @brief Create a new dictionary column by adding the new keys elements
 * to the existing dictionary_column.
 *
 * ```
 * Example:
 * d1 = {[a,b,c,d,f],{4,0,3,1,2,2,2,4,0}}
 * d2 = add_keys(d1,[d,b,e])
 * d2 is now {[a,b,c,d,e,f],[5,0,3,1,2,2,2,5,0]}
 * ```
 *
 */
std::unique_ptr<column> add_keys( dictionary_column_view const& dictionary_column,
                                  column_view const& new_keys,
                                  rmm::mr::device_memory_resource* mr = rmm::mr::get_default_resource(),
                                  cudaStream_t stream = 0)
{
    CUDF_EXPECTS( !new_keys.has_nulls(), "Keys must not have nulls" );

    auto old_keys = dictionary_column.dictionary_keys(); // [a,b,c,d,f]
    // first, concatenate the keys together                 [a,b,c,d,f] + [d,b,e] = [a,b,c,d,f,d,b,e]
    auto combined_keys = cudf::concatenate( std::vector<column_view>{old_keys, new_keys}, mr, stream);
    // drop_duplicates will sort and remove any duplicate keys we may been given
    // the keys_indices values will also be sorted according to the keys      [a,b,c,d,e,f]
    auto table_keys = experimental::detail::drop_duplicates( table_view{{*combined_keys}},
                            std::vector<size_type>{0},
                            experimental::duplicate_keep_option::KEEP_FIRST,
                            true, mr, stream )->release();
    // create map for indices          lower_bound([a,b,c,d,e,f],[a,b,c,d,f]) = [0,1,2,3,5]
    auto map_indices = cudf::experimental::lower_bound( table_view{{table_keys[0]->view()}},
                    table_view{{old_keys}},
                    std::vector<order>{order::ASCENDING},
                    std::vector<null_order>{null_order::AFTER}, // should be no nulls here
                    mr ); // TODO: use the detail version after next merge with the branch-0.13
    std::shared_ptr<const column> keys_column(std::move(table_keys[0]));

    // now create the indices column -- map old values to the new ones
    // gather([4,0,3,1,2,2,2,4,0],[0,1,2,3,5]) = [5,0,3,1,2,2,2,5,0]
    auto table_indices = cudf::experimental::detail::gather( table_view{{map_indices->view()}},
                                                             dictionary_column.indices(),
                                                             false, false, false,
                                                             mr, stream )->release();
    std::unique_ptr<column> indices_column(std::move(table_indices[0]));

    // create new dictionary column with keys_column and indices_column
    // make this into a factory function
    std::vector<std::unique_ptr<column>> children;
    children.emplace_back(std::move(indices_column));
    return std::make_unique<column>(
        data_type{DICTIONARY32}, dictionary_column.size(),
        rmm::device_buffer{0,stream,mr}, // no data in the parent
        copy_bitmask( dictionary_column.parent(), stream, mr), // nulls have
        dictionary_column.null_count(),                        // not changed
        std::move(children),
        std::move(keys_column));
}

} // namespace detail

std::unique_ptr<column> add_keys( dictionary_column_view const& dictionary_column,
                                  column_view const& keys,
                                  rmm::mr::device_memory_resource* mr)
{
    return detail::add_keys(dictionary_column, keys,mr);
}

} // namespace dictionary
} // namespace cudf
