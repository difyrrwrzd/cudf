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

#include <cudf/column/column_device_view.cuh>
#include <cudf/strings/strings_column_handler.hpp>
#include <cudf/strings/string_view.cuh>

#include <thrust/transform.h>

namespace cudf 
{
namespace strings
{

std::unique_ptr<cudf::column> characters_counts( strings_column_handler handler,
                                                 cudaStream_t stream )
{
    size_type count = handler.size();
    auto execpol = rmm::exec_policy(stream);
    auto strings_column = column_device_view::create(handler.parent_column(),stream);
    auto d_column = *strings_column;
    // create output column
    auto result = std::make_unique<cudf::column>( data_type{INT32}, count,
        rmm::device_buffer(count * sizeof(int32_t), stream, handler.memory_resource()),
        rmm::device_buffer(d_column.null_mask(), gdf_valid_allocation_size(count),
                           stream, handler.memory_resource()),
        d_column.null_count());
    auto results_view = result->mutable_view();
    auto d_lengths = results_view.data<int32_t>();
    // set lengths
    thrust::transform( execpol->on(stream), 
        thrust::make_counting_iterator<int32_t>(0),
        thrust::make_counting_iterator<int32_t>(count),
        d_lengths,
        [d_column] __device__ (int32_t idx) {
            if( d_column.nullable() && d_column.is_null(idx) )
                return 0;
            return d_column.element<string_view>(idx).characters();
        });
    return result;
}

std::unique_ptr<cudf::column> bytes_counts( strings_column_handler handler,
                                            cudaStream_t stream )
{
    size_type count = handler.size();
    auto execpol = rmm::exec_policy(stream);
    auto strings_column = column_device_view::create(handler.parent_column(),stream);
    auto d_column = *strings_column;
    // create output column
    auto result = std::make_unique<cudf::column>( data_type{INT32}, count,
        rmm::device_buffer(count * sizeof(int32_t), stream, handler.memory_resource()),
        rmm::device_buffer(d_column.null_mask(), gdf_valid_allocation_size(count),
                           stream, handler.memory_resource()),
        d_column.null_count());
    auto results_view = result->mutable_view();
    auto d_lengths = results_view.data<int32_t>();
    // set sizes
    thrust::transform( execpol->on(stream), 
        thrust::make_counting_iterator<int32_t>(0),
        thrust::make_counting_iterator<int32_t>(count),
        d_lengths,
        [d_column] __device__ (int32_t idx) {
            if( d_column.nullable() && d_column.is_null(idx) )
                return 0;
            return d_column.element<string_view>(idx).size();
        });
    return result;
}


} // namespace strings
} // namespace cudf