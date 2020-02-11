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

#include <cudf/column/column_device_view.cuh>
#include <cudf/strings/string_view.cuh>

#include <thrust/logical.h>

namespace nvtext
{
namespace detail
{

using string_index_pair = thrust::pair<const char*,cudf::size_type>;

/**
 * @brief Base class for tokenize functions that use multi-character
 * delimiters.
 *
 * This is common code for tokenize, token-counters, normalize functions.
 * If an empty delimiter string is specified, then whitespace
 * (code-point <= ' ') is used to identify tokens.
 */
struct base_tokenator
{
    cudf::string_view const d_delimiter{}; // zero or more delimiter characters

    /**
     * @brief Return true if the given character is a delimiter.
     *
     * For empty delimiter, whitespace code-point is checked.
     *
     * @param chr The character to test.
     * @return true if the character is a delimiter
     */
    __device__ bool is_delimiter(cudf::char_utf8 chr)
    {
        return d_delimiter.empty() ? (chr <= ' ') : // whitespace check
               thrust::any_of( thrust::seq, d_delimiter.begin(), d_delimiter.end(),
                               [chr] __device__ (cudf::char_utf8 c) {return c==chr;});
    }

    /**
     * @brief Identifies the bounds of the next token in the given
     * string at the specified iterator position.
     *
     * For empty delimiter, whitespace code-point is checked.
     * Starting at the given iterator (itr) position, a token
     * start position (spos) is identified when a delimiter is
     * not found. Once found, the end position (epos) is identified
     * when a delimiter or the end of the string is found.
     *
     * @param d_str String to tokenize.
     * @param[in,out] spaces Identifies current character position
     *                is a delimiter or not.
     * @param[in,out] itr Current position in d_str to search for tokens.
     * @param[in,out] spos Start character position of the token found.
     * @param[in,out] epos End character position of the token found.
     * @return true if a token was found, false if no more tokens
     */
    __device__ bool next_token( cudf::string_view const& d_str, bool& spaces,
                                cudf::string_view::const_iterator& itr,
                                cudf::size_type& spos, cudf::size_type& epos )
    {
        if( spos >= d_str.length() )
            return false;
        epos = d_str.length(); // init to the end
        for( ; itr != d_str.end(); ++itr )
        {
            char_utf8 ch = *itr;
            if( spaces == is_delimiter(ch) )
            {
                if( spaces )
                    spos = itr.position()+1;
                else
                    epos = itr.position()+1;
                continue;
            }
            spaces = !spaces;
            if( spaces )
            {
                epos = itr.position();
                break;
            }
        }
        return spos < epos;
    }
};

/**
 * @brief Tokenizing function for multi-character delimiter.
 *
 * The first pass simply counts the tokens so the size of the output
 * vector can be calculated. The second pass places the token
 * positions into the d_tokens vector.
 */
struct tokenator_fn : base_tokenator
{
    cudf::column_device_view const d_strings;  // strings to tokenize
    cudf::size_type* d_offsets{};              // offsets into the d_tokens vector for each string
    string_index_pair* d_tokens{};             // token positions in device memory

    tokenator_fn( cudf::column_device_view const& d_strings, cudf::string_view const& d_delimiter,
                  cudf::size_type* d_offsets=nullptr,
                  string_index_pair* d_tokens=nullptr )
    : base_tokenator{d_delimiter},
      d_strings(d_strings), d_offsets(d_offsets), d_tokens(d_tokens) {}

    /**
     * @brief Identifies the token positions within each string.
     *
     * This counts the tokens in each string and also places the token positions
     * into the d_tokens member.
     *
     * @param idx Index of the string to tokenize in the d_strings column.
     * @return The number of tokens for this string.
     */
    __device__ cudf::size_type operator()(size_type idx)
    {
        if( d_strings.is_null(idx) )
            return 0;
        auto d_str = d_strings.element<cudf::string_view>(idx);
        string_index_pair* d_str_tokens = d_tokens ? d_tokens + d_offsets[idx] : nullptr;
        bool spaces = true;
        cudf::size_type spos = 0;
        cudf::size_type epos = d_str.length();
        cudf::size_type token_idx = 0;
        auto itr = d_str.begin();
        while( next_token(d_str,spaces,itr,spos,epos) )
        {
            if( d_str_tokens )
            {
                auto spos_bo = d_str.byte_offset(spos); // convert char pos
                auto epos_bo = d_str.byte_offset(epos); // to byte offset
                d_str_tokens[token_idx] = string_index_pair{ d_str.data() + spos_bo,
                                                            (epos_bo-spos_bo) };
            }
            spos = epos + 1;
            ++itr;
            ++token_idx;
        }
        return token_idx;
    }
};


// delimiters' iterator = delimiterator
using delimiterator = cudf::column_device_view::const_iterator<cudf::string_view>;

/**
 * @brief Tokenizes strings using multiple string delimiters.
 *
 * One or more strings are used as delimiters to identify tokens inside
 * each string of a given strings column.
 */
struct multi_delimiter_tokenizer_fn
{
    cudf::column_device_view const d_strings;  // strings column to tokenize
    delimiterator delimiters_begin;            // first delimiter
    delimiterator delimiters_end;              // last delimiter
    cudf::size_type* d_offsets{};              // offsets into the d_tokens output vector
    string_index_pair* d_tokens{};             // token positions found for each string

    /**
     * @brief Identifies the token positions within each string.
     *
     * This counts the tokens in each string and also places the token positions
     * into the d_tokens member.
     *
     * @param idx Index of the string to tokenize in the d_strings column.
     * @return The number of tokens for this string.
     */
    __device__ cudf::size_type operator()(size_type idx)
    {
        if( d_strings.is_null(idx) )
            return 0;
        cudf::string_view d_str = d_strings.element<cudf::string_view>(idx);
        auto d_str_tokens = d_tokens ? d_tokens + d_offsets[idx] : nullptr;
        auto data_ptr = d_str.data();
        auto curr_ptr = data_ptr;
        cudf::size_type last_pos = 0, token_idx = 0;
        while( curr_ptr < data_ptr + d_str.size_bytes() )
        {
            cudf::string_view sub_str(curr_ptr,static_cast<cudf::size_type>(data_ptr + d_str.size_bytes() - curr_ptr));
            cudf::size_type increment_bytes = 1;
            // look for delimiter at current position
            auto itr_find = thrust::find_if( thrust::seq, delimiters_begin, delimiters_end,
                [sub_str]__device__(string_view const& d_delim) {
                    return !d_delim.empty() && (d_delim.size_bytes() <= sub_str.size_bytes()) &&
                           d_delim.compare(sub_str.data(),d_delim.size_bytes())==0;
                });
            if( itr_find != delimiters_end )
            {   // found delimiter
                auto token_size = static_cast<cudf::size_type>((curr_ptr - data_ptr) - last_pos);
                if( token_size > 0 ) // we only care about non-zero sized tokens
                {
                    if( d_str_tokens )
                        d_str_tokens[token_idx] = string_index_pair{ data_ptr + last_pos, token_size };
                    ++token_idx;
                }
                increment_bytes = (*itr_find).size_bytes();
                last_pos = (curr_ptr - data_ptr) + increment_bytes; // point past delimiter
            }
            curr_ptr += increment_bytes; // move on to the next byte
        }
        if( last_pos < d_str.size_bytes() ) // left-over tokens
        {
            if( d_str_tokens )
                d_str_tokens[token_idx] = string_index_pair{ data_ptr + last_pos, d_str.size_bytes() - last_pos };
            ++token_idx;
        }
        return token_idx; // this is the number of tokens found for this string
    }
};

} // namespace detail
} // namespace nvtext
