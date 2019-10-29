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
#include <cudf/column/column_device_view.cuh>
#include <cudf/strings/strings_column_view.hpp>
#include <cudf/strings/string_view.cuh>
#include <cudf/strings/case.hpp>
#include <cudf/utilities/error.hpp>
#include "char_types/is_flags.h"
#include "./utilities.hpp"
#include "./utilities.cuh"

#include <rmm/thrust_rmm_allocator.h>
#include <thrust/transform.h>
#include <thrust/transform_scan.h>

namespace cudf
{
namespace strings
{
namespace
{

/**
 * @brief Used as template parameter to divide size calculation from
 * the actual string operation within a function.
 * Useful when most of the logic is identical for both passes.
 */
enum TwoPass
{
    SizeOnly = 0, ///< calculate the size only
    ExecuteOp     ///< run the string operation
};

/**
 * @brief Function logic for the substring API.
 * This will perform a substring operation on each string
 * using the provided start, stop, and step parameters.
 */
template <TwoPass Pass=SizeOnly>
struct upper_lower_fn
{
    const column_device_view d_column;
    detail::character_flags_table_type case_flag; // flag to check with on each character
    const detail::character_flags_table_type* d_flags;
    const detail::character_cases_table_type* d_case_table;
    const int32_t* d_offsets{};
    char* d_chars{};

    __device__ int32_t operator()(size_type idx)
    {
        if( d_column.is_null(idx) )
            return 0; // null string
        string_view d_str = d_column.template element<string_view>(idx);
        int32_t bytes = 0;
        char* d_buffer = nullptr;
        if( Pass==ExecuteOp )
            d_buffer = d_chars + d_offsets[idx];
        for( auto itr = d_str.begin(); itr != d_str.end(); ++itr )
        {
            uint32_t code_point = detail::utf8_to_codepoint(*itr);
            detail::character_flags_table_type flag = code_point <= 0x00FFFF ? d_flags[code_point] : 0;
            if( flag & case_flag )
            {
                if( Pass==SizeOnly )
                    bytes += detail::bytes_in_char_utf8(detail::codepoint_to_utf8(d_case_table[code_point]));
                else
                    d_buffer += detail::from_char_utf8(detail::codepoint_to_utf8(d_case_table[code_point]),d_buffer);
            }
            else
            {
                if( Pass==SizeOnly )
                    bytes += detail::bytes_in_char_utf8(*itr);
                else
                    d_buffer += detail::from_char_utf8(*itr, d_buffer);
            }
        }
        return bytes;
    }
};

/**
 * @brief Utility method for converting upper and lower case characters
 * in a strings column.
 *
 * @param strings Strings to convert.
 * @param case_flag The character type to convert (upper, lower, or both)
 * @param mr Memory resource to use for allocation.
 * @param stream Stream to use for any kernels launched.
 * @return New strings column with characters converted.
 */
std::unique_ptr<cudf::column> convert_case( strings_column_view strings,
                                            detail::character_flags_table_type case_flag,
                                            rmm::mr::device_memory_resource* mr,
                                            cudaStream_t stream)
{
    auto strings_count = strings.size();
    if( strings_count == 0 )
        return detail::make_empty_strings_column(mr,stream);

    auto execpol = rmm::exec_policy(0);
    auto strings_column = column_device_view::create(strings.parent(),stream);
    auto d_column = *strings_column;

    rmm::device_buffer null_mask;
    cudf::size_type null_count = d_column.null_count();
    if( d_column.nullable() ) // copy null_mask
        null_mask = rmm::device_buffer( d_column.null_mask(),
                                        bitmask_allocation_size_bytes(strings_count),
                                        stream, mr);

    // get the lookup tables used for case conversion
    auto d_flags = detail::get_character_flags_table();
    auto d_case_table = detail::get_character_case_table();

    // build offsets column
    // calculate the size of each output string
    auto offsets_transformer_itr = thrust::make_transform_iterator( thrust::make_counting_iterator<size_type>(0),
        upper_lower_fn<SizeOnly>{d_column, case_flag, d_flags, d_case_table} );
    auto offsets_column = detail::make_offsets_child_column(offsets_transformer_itr,
                                               offsets_transformer_itr+strings_count,
                                               mr, stream);
    auto offsets_view = offsets_column->view();
    auto d_new_offsets = offsets_view.data<int32_t>();

    // build the chars column -- convert uppercase characters to lowercase
    size_type bytes = thrust::device_pointer_cast(d_new_offsets)[strings_count];
    auto chars_column = strings::detail::create_chars_child_column( strings_count, null_count, bytes, mr, stream );
    auto chars_view = chars_column->mutable_view();
    auto d_chars = chars_view.data<char>();
    thrust::for_each_n(execpol->on(stream),
        thrust::make_counting_iterator<size_type>(0), strings_count,
        upper_lower_fn<ExecuteOp>{d_column, case_flag, d_flags, d_case_table, d_new_offsets, d_chars} );
    //
    return make_strings_column(strings_count, std::move(offsets_column), std::move(chars_column),
                               null_count, std::move(null_mask), stream, mr);
}

} // namespace

// APIS
//
std::unique_ptr<cudf::column> to_lower( strings_column_view strings,
                                        rmm::mr::device_memory_resource* mr,
                                        cudaStream_t stream )
{
    detail::character_flags_table_type case_flag = IS_UPPER(0xFF); // convert only uppercase characters
    return convert_case(strings,case_flag,mr,stream);
}

//
std::unique_ptr<cudf::column> to_upper( strings_column_view strings,
                                        rmm::mr::device_memory_resource* mr,
                                        cudaStream_t stream )
{
    detail::character_flags_table_type case_flag = IS_LOWER(0xFF); // convert only lowercase characters
    return convert_case(strings,case_flag,mr,stream);
}

//
std::unique_ptr<cudf::column> swapcase( strings_column_view strings,
                                        rmm::mr::device_memory_resource* mr,
                                        cudaStream_t stream )
{
    // convert only upper or lower case characters
    detail::character_flags_table_type case_flag = IS_LOWER(0xFF) | IS_UPPER(0xFF);
    return convert_case(strings,case_flag,mr,stream);
}

} // namespace strings
} // namespace cudf

