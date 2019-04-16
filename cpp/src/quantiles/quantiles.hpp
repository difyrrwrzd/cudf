/*
 * Copyright (c) 2018, NVIDIA CORPORATION.
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

//Quantile (percentile) functionality

#include "cudf.h"

namespace cudf {
namespace interpolate {

struct QuantiledIndex {
  size_t lower_bound;
  size_t upper_bound;
  size_t nearest;
  double fraction;
};

QuantiledIndex find_quantile_index(gdf_size_type length, double quant);


template <typename T_out, typename T_in>
void linear(T_out& result, T_in lhs, T_in rhs, double frac)
{
    //TODO: safe operation to avoid overflow/underflow
     result = static_cast<T_out>(static_cast<T_out>(lhs) + frac*static_cast<T_out>(rhs-lhs));
}


template <typename T_out, typename T_in>
void midpoint(T_out& result, T_in lhs, T_in rhs)
{
    // TODO: try std::midpoint (C++20) if available
    double dlhs = static_cast<double>(lhs);
    double drhs = static_cast<double>(rhs);

    result = static_cast<T_out>( dlhs /2 + drhs /2 );
}

// -------------------------------------------------------------------------
// @overloads

template <typename T_out>
void midpoint(T_out& result, int64_t lhs, int64_t rhs)
{
    // caring to avoid integer overflow and underflow between int64_t and T_out( double )
    int64_t half = lhs/2 + rhs/2;
    int64_t rest = (lhs%2 + rhs%2);

    result = static_cast<T_out>(static_cast<T_out>(half) + static_cast<T_out>(rest)*0.5);
}


template <>
void midpoint(int64_t& result, int64_t lhs, int64_t rhs)
{
    // caring to avoid integer overflow
    int64_t half = lhs/2 + rhs/2;
    int64_t rest = (lhs%2 + rhs%2);
    result = half;

    // rounding toward zero
    result += ( half >= 0 && rest != 0 )? rest/2 : 0;
    result += ( half < 0  && rest != 0 )? 1 : 0;
}

} // end of namespace interpolate
} // end of namespace cudf

