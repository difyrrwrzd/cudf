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

#ifndef _TYPE_INFO_HPP
#define _TYPE_INFO_HPP

#include <groupby.hpp>
#include <utilities/device_atomics.cuh>
#include <utilities/device_operators.cuh>

#include <algorithm>

/**---------------------------------------------------------------------------*
 * @file type_info.hpp
 * @brief Type info traits used in hash-based groupby.
*---------------------------------------------------------------------------**/

namespace cudf {
namespace groupby {
namespace hash {
/**---------------------------------------------------------------------------*
 * @brief Maps a operators enum value to it's corresponding binary
 * operator functor.
 *
 * @tparam op The enum to map to its corresponding functor
 *---------------------------------------------------------------------------**/
template <operators op> struct corresponding_functor { using type = void; };
template <> struct corresponding_functor<MIN> { using type = DeviceMin; };
template <> struct corresponding_functor<MAX> { using type = DeviceMax; };
template <> struct corresponding_functor<SUM> { using type = DeviceSum; };
template <> struct corresponding_functor<COUNT> { using type = DeviceSum; };
template <operators op>
using corresponding_functor_t = typename corresponding_functor<op>::type;

/**---------------------------------------------------------------------------*
 * @brief Determines accumulator type based on input type and operation.
 *
 * @tparam InputType The type of the input to the aggregation operation
 * @tparam op The aggregation operation performed
 * @tparam dummy Dummy for SFINAE
 *---------------------------------------------------------------------------**/
template <typename SourceType, operators op, typename dummy = void>
struct target_type { using type = void; };

// Computing MIN of SourceType, use SourceType accumulator
template <typename SourceType>
struct target_type<SourceType, MIN> { using type = SourceType; };

// Computing MAX of SourceType, use SourceType accumulator
template <typename SourceType>
struct target_type<SourceType, MAX> { using type = SourceType; };

// Always use int64_t accumulator for COUNT
// TODO Use `gdf_size_type`
template <typename SourceType>
struct target_type<SourceType, COUNT> { using type = gdf_size_type; };

// Summing integers of any type, always use int64_t accumulator
template <typename SourceType>
struct target_type<SourceType, SUM,
                   std::enable_if_t<std::is_integral<SourceType>::value>> {
  using type = int64_t;
};

// Summing float/doubles, use same type accumulator
template <typename SourceType>
struct target_type<
    SourceType, SUM,
    std::enable_if_t<std::is_floating_point<SourceType>::value>> {
  using type = SourceType;
};

template <typename SourceType, operators op>
using target_type_t = typename target_type<SourceType, op>::type;

/**---------------------------------------------------------------------------*
 * @brief Functor that uses the target_type trait to map the combination of a
 * dispatched SourceType and aggregation operation to required target gdf_dtype.
 *---------------------------------------------------------------------------**/
struct target_type_mapper {
  template <typename SourceType>
  gdf_dtype operator()(operators op) const noexcept {
    switch (op) {
      case MIN:
        return gdf_dtype_of<target_type_t<SourceType, MIN>>();
      case MAX:
        return gdf_dtype_of<target_type_t<SourceType, MAX>>();
      case SUM:
        return gdf_dtype_of<target_type_t<SourceType, SUM>>();
      case COUNT:
        return gdf_dtype_of<target_type_t<SourceType, COUNT>>();
      default:
        return GDF_invalid;
    }
  }
};


}  // namespace hash
}  // namespace groupby
}  // namespace cudf

#endif