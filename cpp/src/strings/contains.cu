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

#include <cudf/null_mask.hpp>
#include <cudf/column/column.hpp>
#include <cudf/column/column_factories.hpp>
#include <cudf/column/column_device_view.cuh>
#include <cudf/strings/strings_column_view.hpp>
#include <cudf/strings/string_view.cuh>
#include <cudf/strings/char_types/char_types.hpp>
#include <cudf/wrappers/bool.hpp>
#include "./utilities.hpp"
#include "regex/regex.cuh"


namespace cudf
{
namespace strings
{
namespace detail
{
namespace
{

// This functor handles both contains() and match() to minimize the number
// of regex calls to find() to be inlined greatly reducing compile time.
template<size_t stack_size>
struct contains_fn
{
    Reprog_device prog;
    column_device_view d_strings;
    bool bmatch{false}; // do not make this a template parameter to keep compile times down

    __device__ cudf::experimental::bool8 operator()(size_type idx)
    {
        u_char data1[stack_size], data2[stack_size];
        prog.set_stack_mem(data1,data2);
        if( d_strings.is_null(idx) )
            return 0;
        string_view d_str = d_strings.element<string_view>(idx);
        int32_t begin = 0;
        int32_t end = bmatch ? 1 : d_str.length(); // 1=match only the beginning of the string
        return static_cast<experimental::bool8>(prog.find(idx,d_str,begin,end));
    }
};

//
std::unique_ptr<column> contains_util( strings_column_view const& strings,
                                       std::string const& pattern,
                                       bool beginning_only = false,
                                       rmm::mr::device_memory_resource* mr = rmm::mr::get_default_resource(),
                                       cudaStream_t stream = 0)
{
    auto strings_count = strings.size();
    auto strings_column = column_device_view::create(strings.parent(),stream);
    auto d_column = *strings_column;

    auto d_flags = detail::get_character_flags_table();
    // compile regex into device object
    std::vector<char32_t> pattern32 = string_to_char32_vector(pattern);
    auto prog = Reprog_device::create(pattern32.data(),d_flags);
    auto d_prog = *prog;

    // allocate regex working memory if necessary
    int regex_insts = d_prog.inst_counts();
    if( regex_insts > MAX_STACK_INSTS )
    {
        if( !d_prog.alloc_relists(strings_count) )
        {
            std::ostringstream message;
            message << "cuDF failure at: " __FILE__ ":" << __LINE__ << ": ";
            message << "number of instructions (" << d_prog.inst_counts() << ") ";
            message << "and number of strings (" << strings_count << ") ";
            message << "exceeds available memory";
            // throw std::invalid_argument(message.str());
            //CUDF_FAIL(message.str());
            throw cudf::logic_error(message.str());
        }
    }

    // create the output column
    auto results = make_numeric_column( data_type{BOOL8}, strings_count,
        copy_bitmask( strings.parent(), stream, mr), strings.null_count(), stream, mr);
    auto results_view = results->mutable_view();
    auto d_results = results_view.data<cudf::experimental::bool8>();

    // do the thing
    auto execpol = rmm::exec_policy(stream);
    if( (regex_insts > MAX_STACK_INSTS) || (regex_insts <= RX_SMALL_INSTS) )
        thrust::transform(execpol->on(stream),
            thrust::make_counting_iterator<size_type>(0),
            thrust::make_counting_iterator<size_type>(strings_count),
            d_results, contains_fn<RX_STACK_SMALL>{d_prog, d_column, beginning_only} );
    else if( regex_insts <= RX_MEDIUM_INSTS )
        thrust::transform(execpol->on(stream),
            thrust::make_counting_iterator<size_type>(0),
            thrust::make_counting_iterator<size_type>(strings_count),
            d_results, contains_fn<RX_STACK_MEDIUM>{d_prog, d_column, beginning_only} );
    else
        thrust::transform(execpol->on(stream),
            thrust::make_counting_iterator<size_type>(0),
            thrust::make_counting_iterator<size_type>(strings_count),
            d_results, contains_fn<RX_STACK_LARGE>{d_prog, d_column, beginning_only} );

    results->set_null_count(strings.null_count());
    return results;
}

} // namespace

std::unique_ptr<column> contains_re( strings_column_view const& strings,
                                     std::string const& pattern,
                                     rmm::mr::device_memory_resource* mr = rmm::mr::get_default_resource(),
                                     cudaStream_t stream = 0)
{
    return contains_util(strings, pattern, false, mr, stream);
}

std::unique_ptr<column> matches_re( strings_column_view const& strings,
                                    std::string const& pattern,
                                    rmm::mr::device_memory_resource* mr = rmm::mr::get_default_resource(),
                                    cudaStream_t stream = 0)
{
    return contains_util(strings, pattern, true, mr, stream);
}

} // namespace detail

// external APIs

std::unique_ptr<column> contains_re( strings_column_view const& strings,
                                     std::string const& pattern,
                                     rmm::mr::device_memory_resource* mr)
{
    return detail::contains_re(strings, pattern, mr);
}

std::unique_ptr<column> matches_re( strings_column_view const& strings,
                                     std::string const& pattern,
                                     rmm::mr::device_memory_resource* mr)
{
    return detail::matches_re(strings, pattern, mr);
}

namespace detail
{

namespace
{
template<size_t stack_size>
struct count_fn
{
    Reprog_device prog;
    column_device_view d_strings;

    __device__ int32_t operator()(unsigned int idx)
    {
        u_char data1[stack_size], data2[stack_size];
        prog.set_stack_mem(data1,data2);
        if( d_strings.is_null(idx) )
            return 0;
        string_view d_str = d_strings.element<string_view>(idx);
        int32_t find_count = 0;
        size_type nchars = d_str.length();
        size_type begin = 0;
        while( begin <= nchars )
        {
            auto end = nchars;
            if( prog.find(idx,d_str,begin,end) <=0 )
                break;
            ++find_count;
            begin = end > begin ? end : begin + 1;
        }
        return find_count;
    }
};

}

std::unique_ptr<column> count_re( strings_column_view const& strings,
                                  std::string const& pattern,
                                  rmm::mr::device_memory_resource* mr = rmm::mr::get_default_resource(),
                                  cudaStream_t stream = 0)
{
    auto strings_count = strings.size();
    auto strings_column = column_device_view::create(strings.parent(),stream);
    auto d_column = *strings_column;

    auto d_flags = detail::get_character_flags_table();
    // compile regex into device object
    std::vector<char32_t> pattern32 = string_to_char32_vector(pattern);
    auto prog = Reprog_device::create(pattern32.data(),d_flags);
    auto d_prog = *prog;

    // allocate regex working memory if necessary
    int regex_insts = d_prog.inst_counts();
    if( regex_insts > MAX_STACK_INSTS )
    {
        if( !d_prog.alloc_relists(strings_count) )
        {
            std::ostringstream message;
            message << "cuDF failure at: " __FILE__ ":" << __LINE__ << ": ";
            message << "number of instructions (" << d_prog.inst_counts() << ") ";
            message << "and number of strings (" << strings_count << ") ";
            message << "exceeds available memory";
            // throw std::invalid_argument(message.str());
            //CUDF_FAIL(message.str());
            throw cudf::logic_error(message.str());
        }
    }
    // create the output column
    auto results = make_numeric_column( data_type{INT32}, strings_count,
        copy_bitmask( strings.parent(), stream, mr), strings.null_count(), stream, mr);
    auto results_view = results->mutable_view();
    auto d_results = results_view.data<int32_t>();

    // do the thing
    auto execpol = rmm::exec_policy(stream);
    if( (regex_insts > MAX_STACK_INSTS) || (regex_insts <= RX_SMALL_INSTS) )
        thrust::transform(execpol->on(stream),
            thrust::make_counting_iterator<size_type>(0),
            thrust::make_counting_iterator<size_type>(strings_count),
            d_results, count_fn<RX_STACK_SMALL>{d_prog, d_column} );
    else if( regex_insts <= RX_MEDIUM_INSTS )
        thrust::transform(execpol->on(stream),
            thrust::make_counting_iterator<size_type>(0),
            thrust::make_counting_iterator<size_type>(strings_count),
            d_results, count_fn<RX_STACK_MEDIUM>{d_prog, d_column} );
    else
        thrust::transform(execpol->on(stream),
            thrust::make_counting_iterator<size_type>(0),
            thrust::make_counting_iterator<size_type>(strings_count),
            d_results, count_fn<RX_STACK_LARGE>{d_prog, d_column} );

    results->set_null_count(strings.null_count());
    return results;

}

} // namespace detail

// external API

std::unique_ptr<column> count_re( strings_column_view const& strings,
                                  std::string const& pattern,
                                  rmm::mr::device_memory_resource* mr)
{
    return detail::count_re(strings, pattern, mr);
}

} // namespace strings
} // namespace cudf
