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

#include <cudf.h>
#include <bitmask.hpp>
#include <bitmask/bit_mask.cuh>
#include <groupby.hpp>
#include <hash/concurrent_unordered_map.cuh>
#include <table.hpp>
#include <table/device_table.cuh>
#include <utilities/cuda_utils.hpp>
#include <utilities/device_atomics.cuh>
#include <utilities/release_assert.cuh>
#include <utilities/type_dispatcher.hpp>
#include "new_hash_groupby.hpp"

#include <rmm/thrust_rmm_allocator.h>
#include <thrust/fill.h>
#include <algorithm>
#include <type_traits>
#include <vector>

namespace cudf {
namespace detail {

namespace {

using namespace groupby;

/**---------------------------------------------------------------------------*
 * @brief Maps a distributive_operators enum value to it's corresponding binary
 * operator functor.
 *
 * @tparam op The enum to map to its corresponding functor
 *---------------------------------------------------------------------------**/
template <distributive_operators op>
struct corresponding_functor {
  using type = void;
};

template <>
struct corresponding_functor<MIN> {
  using type = DeviceMin;
};

template <>
struct corresponding_functor<MAX> {
  using type = DeviceMax;
};

template <>
struct corresponding_functor<SUM> {
  using type = DeviceSum;
};

template <>
struct corresponding_functor<COUNT> {
  using type = DeviceSum;
};

template <distributive_operators op>
using corresponding_functor_t = typename corresponding_functor<op>::type;

struct identity_initializer {
  template <typename T>
  T get_identity(distributive_operators op) {
    switch (op) {
      case SUM:
        return corresponding_functor_t<SUM>::identity<T>();
      case MIN:
        return corresponding_functor_t<MIN>::identity<T>();
      case MAX:
        return corresponding_functor_t<MAX>::identity<T>();
      case COUNT:
        return corresponding_functor_t<COUNT>::identity<T>();
      default:
        CUDF_FAIL("Invalid aggregation operation.");
    }
  }

  template <typename T>
  void operator()(gdf_column const& col, distributive_operators op,
                  cudaStream_t stream = 0) {
    T* typed_data = static_cast<T*>(col.data);
    thrust::fill(rmm::exec_policy(stream)->on(stream), typed_data,
                 typed_data + col.size, get_identity<T>(op));

    // For COUNT operator, initialize column's bitmask to be all valid
    if ((nullptr != col.valid) and (COUNT == op)) {
      CUDA_TRY(cudaMemsetAsync(
          col.valid, 0xff,
          sizeof(gdf_valid_type) * gdf_valid_allocation_size(col.size),
          stream));
    }
  }
};

/**---------------------------------------------------------------------------*
 * @brief Initializes each column in a table with a corresponding identity value
 * of an aggregation operation.
 *
 * The `i`th column will be initialized with the identity value of the `i`th
 * aggregation operation.
 *
 * @note The validity bitmask for the column corresponding to a COUNT operator
 * will be initialized to all valid.
 *
 * @param table The table of columns to initialize.
 * @param operators The aggregation operations whose identity values will be
 *used to initialize the columns.
 *---------------------------------------------------------------------------**/
void initialize_with_identity(
    cudf::table const& table,
    std::vector<distributive_operators> const& operators,
    cudaStream_t stream = 0) {
  // TODO: Initialize all the columns in a single kernel instead of invoking one
  // kernel per column
  for (gdf_size_type i = 0; i < table.num_columns(); ++i) {
    gdf_column const* col = table.get_column(i);
    cudf::type_dispatcher(col->dtype, identity_initializer{}, *col,
                          operators[i]);
  }
}

/**---------------------------------------------------------------------------*
 * @brief Determines accumulator type based on input type and operation.
 *
 * @tparam InputType The type of the input to the aggregation operation
 * @tparam op The aggregation operation performed
 * @tparam dummy Dummy for SFINAE
 *---------------------------------------------------------------------------**/
template <typename SourceType, distributive_operators op, typename dummy = void>
struct target_type {
  using type = void;
};

// Computing MIN of SourceType, use SourceType accumulator
template <typename SourceType>
struct target_type<SourceType, MIN> {
  using type = SourceType;
};

// Computing MAX of SourceType, use SourceType accumulator
template <typename SourceType>
struct target_type<SourceType, MAX> {
  using type = SourceType;
};

// Always use int64_t accumulator for COUNT
template <typename SourceType>
struct target_type<SourceType, COUNT> {
  using type = int64_t;
};

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

template <typename SourceType, distributive_operators op>
using target_type_t = typename target_type<SourceType, op>::type;

/**---------------------------------------------------------------------------*
 * @brief Functor that uses the target_type trait to map the combination of a
 * dispatched SourceType and aggregation operation to required target gdf_dtype.
 *
 *---------------------------------------------------------------------------**/
struct dtype_mapper {
  template <typename SourceType>
  gdf_dtype operator()(distributive_operators op) {
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

/**---------------------------------------------------------------------------*
 * @brief Deteremines target gdf_dtypes to use for combinations of source
 * gdf_dtypes and aggregation operations.
 *
 * Given vectors of source gdf_dtypes and corresponding aggregation operations
 * to be performed on that type, returns a vector the gdf_dtypes to use to store
 * the result of the aggregation operations.
 *
 * @param source_dtypes The source types
 * @param op The aggregation operations
 * @return Target gdf_dtypes to use for the target aggregation columns
 *---------------------------------------------------------------------------**/
std::vector<gdf_dtype> target_dtypes(
    std::vector<gdf_dtype> const& source_dtypes,
    std::vector<distributive_operators> const& operators) {
  std::vector<gdf_dtype> output_dtypes(source_dtypes.size());

  std::transform(
      source_dtypes.begin(), source_dtypes.end(), operators.begin(),
      output_dtypes.begin(),
      [](gdf_dtype source_dtype, distributive_operators op) {
        gdf_dtype t = cudf::type_dispatcher(source_dtype, dtype_mapper{}, op);
        CUDF_EXPECTS(
            t != GDF_invalid,
            "Invalid combination of input type and aggregation operation.");
        return t;
      });

  return output_dtypes;
}

/**---------------------------------------------------------------------------*
 * @brief Base case for invalid SourceType and op combinations.
 *
 * For an invalid combination of SourceType and operator,
 *`target_type_t<SourceType, operator>` yields a `void` TargetType. This
 * specialization will be invoked for any invalid combination and cause a
 * runtime error.
 *
 * @note A struct is used instead of a function to allow for partial
 * specialization.
 *---------------------------------------------------------------------------**/
template <typename SourceType, distributive_operators op,
          typename Enable = void>
struct update_target_element {
  __device__ inline void operator()(gdf_column const& target,
                                    gdf_size_type target_index,
                                    gdf_column const& source,
                                    gdf_size_type source_index) {
    release_assert(false && "Invalid Source type and Aggregation combination.");
  }
};

/**---------------------------------------------------------------------------*
 * @brief Specialization for valid SourceType and op combinations.
 *
 * @tparam SourceType Type of the source element
 * @tparam op The operation to perform
 *---------------------------------------------------------------------------**/
template <typename SourceType, distributive_operators op>
struct update_target_element<
    SourceType, op,
    std::enable_if_t<not std::is_void<target_type_t<SourceType, op>>::value>> {
  /**---------------------------------------------------------------------------*
   * @brief Performs in-place update of a target element via a binary operation
   * with a source element.
   *
   * @note It is assumed the source element is not NULL, i.e., a NULL source
   * element should be detected before calling this function.
   *
   * @note It is assumed the target column is always nullable, i.e., has a valid
   * bitmask allocation.
   *
   * If the target element is NULL, it is assumed that the target element was
   * initialized with the identity of the aggregation operation. The target is
   * updated with the result of the aggregation with the source element, and the
   * target column's bitmask is updated to indicate the target element is no
   * longer NULL.
   *
   * @param target Column containing target element
   * @param target_index Index of target element
   * @param source Column containing source element
   * @param source_index Index of source element
   *---------------------------------------------------------------------------**/
  __device__ inline void operator()(gdf_column const& target,
                                    gdf_size_type target_index,
                                    gdf_column const& source,
                                    gdf_size_type source_index) {
    using TargetType = target_type_t<SourceType, op>;
    assert(gdf_dtype_of<TargetType>() == target.dtype);

    TargetType* const __restrict__ target_data{
        static_cast<TargetType*>(target.data)};
    SourceType const* const __restrict__ source_data{
        static_cast<SourceType const*>(source.data)};

    SourceType const source_element{source_data[source_index]};

    using FunctorType = corresponding_functor_t<op>;

    cudf::genericAtomicOperation(&target_data[target_index],
                                 static_cast<TargetType>(source_element),
                                 FunctorType{});

    bit_mask::bit_mask_t* const __restrict__ target_mask{
        reinterpret_cast<bit_mask::bit_mask_t*>(target.valid)};

    if (not bit_mask::is_valid(target_mask, target_index)) {
      bit_mask::set_bit_safe(target_mask, target_index);
    }
  }
};

/**---------------------------------------------------------------------------*
 * @brief Specialization for COUNT.
 *---------------------------------------------------------------------------**/
template <typename SourceType>
struct update_target_element<SourceType, COUNT,
                             std::enable_if_t<not std::is_void<
                                 target_type_t<SourceType, COUNT>>::value>> {
  /**---------------------------------------------------------------------------*
   * @brief Increments the target_element by 1.
   *
   * @note Assumes the target element is never NULL, and was intialized to 0.
   *
   * @param target Column containing target element
   * @param target_index Index of target element
   *---------------------------------------------------------------------------**/
  __device__ inline void operator()(gdf_column const& target,
                                    gdf_size_type target_index,
                                    gdf_column const&, gdf_size_type) {
    using TargetType = target_type_t<SourceType, COUNT>;
    assert(gdf_dtype_of<TargetType>() == target.dtype);

    TargetType* const __restrict__ target_data{
        static_cast<TargetType*>(target.data)};

    cudf::genericAtomicOperation(&target_data[target_index], TargetType{1},
                                 DeviceSum{});
  }
};

struct elementwise_aggregator {
  template <typename SourceType>
  __device__ inline void operator()(gdf_column const& target,
                                    gdf_size_type target_index,
                                    gdf_column const& source,
                                    gdf_size_type source_index,
                                    distributive_operators op) {
    switch (op) {
      case MIN: {
        update_target_element<SourceType, MIN>{}(target, target_index, source,
                                                 source_index);
        break;
      }
      case MAX: {
        update_target_element<SourceType, MAX>{}(target, target_index, source,
                                                 source_index);
        break;
      }
      case SUM: {
        update_target_element<SourceType, SUM>{}(target, target_index, source,
                                                 source_index);
        break;
      }
      case COUNT: {
        update_target_element<SourceType, COUNT>{}(target, target_index, source,
                                                   source_index);
      }
      default:
        return;
    }
  }
};

/**---------------------------------------------------------------------------*
 * @brief Performs an in-place update by performing elementwise aggregation
 * operations between a target and source row.
 *
 * For `i` in `[0, num_columns)`, each element in the target row is updated as:
 *
 *```
 * target_row[i] = target_row[i] op[i] source_row[i]
 *```
 * @note If a source element is NULL, the aggregation operation for
 * that column is skipped.
 *
 * @note If a target element is NULL, it is assumed that the value of the NULL
 * element is the identity value of the aggregation operation being performed.
 * The aggregation operation is performed between the source element and the
 * identity value, and the target element's bit is set to indicate it is no
 * longer NULL.
 *
 * @note For COUNT, it is assumed the target element can *never* be NULL. As
 * such, it is expected the target element's bit is already set.
 *
 * @param target Table containing the target row
 * @param target_index Index of the target row
 * @param source Table cotaning the source row
 * @param source_index Index of the source row
 * @param ops Array of operators to perform between the elements of the
 * target and source rows
 *---------------------------------------------------------------------------**/
template <bool values_have_nulls = true>
__device__ inline void aggregate_row(device_table const& target,
                                     gdf_size_type target_index,
                                     device_table const& source,
                                     gdf_size_type source_index,
                                     distributive_operators* ops) {
  using namespace bit_mask;
  thrust::for_each(
      thrust::seq, thrust::make_counting_iterator(0),
      thrust::make_counting_iterator(target.num_columns()),
      [target, target_index, source, source_index, ops](gdf_size_type i) {
        bit_mask_t* const __restrict__ source_mask{
            reinterpret_cast<bit_mask_t*>(source.get_column(i)->valid)};

        if (values_have_nulls and nullptr != source_mask and
            not is_valid(source_mask, source_index)) {
          return;
        }

        cudf::type_dispatcher(source.get_column(i)->dtype,
                              elementwise_aggregator{}, *target.get_column(i),
                              target_index, *source.get_column(i), source_index,
                              ops[i]);
      });
}

template <bool nullable = true>
struct row_hasher {
  using result_type = hash_value_type;  // TODO Remove when aggregating
                                        // map::insert function is removed
  device_table table;
  row_hasher(device_table const& t) : table{t} {}

  __device__ auto operator()(gdf_size_type row_index) const {
    return hash_row<nullable>(table, row_index);
  }
};

template <bool skip_rows_with_nulls, bool values_have_nulls, typename Map>
__global__ void build_aggregation_table(
    Map* map, device_table input_keys, device_table input_values,
    device_table output_values, distributive_operators* ops,
    bit_mask::bit_mask_t const* const __restrict__ row_bitmask) {
  gdf_size_type i = threadIdx.x + blockIdx.x * blockDim.x;

  while (i < input_keys.num_rows()) {
    if (skip_rows_with_nulls and not bit_mask::is_valid(row_bitmask, i)) {
      i += blockDim.x * gridDim.x;
      continue;
    }

    auto result = map->insert(thrust::make_pair(i, i));

    aggregate_row<values_have_nulls>(output_values, result.first->second,
                                     input_values, i, ops);
    i += blockDim.x * gridDim.x;
  }
}

template <bool keys_have_nulls, bool values_have_nulls>
auto compute_hash_groupby(
    cudf::table const& keys, cudf::table const& values,
    std::vector<groupby::distributive_operators> const& operators,
    groupby::Options options, cudaStream_t stream) {
  gdf_size_type constexpr unused_key{std::numeric_limits<gdf_size_type>::max()};
  gdf_size_type constexpr unused_value{
      std::numeric_limits<gdf_size_type>::max()};
  CUDF_EXPECTS(keys.num_rows() < unused_key, "Groupby input size too large.");

  // The exact output size is unknown a priori, therefore, use the input size as
  // an upper bound
  gdf_size_type const output_size_estimate{keys.num_rows()};
  cudf::table sparse_output_values{
      output_size_estimate, target_dtypes(column_dtypes(values), operators),
      true, stream};

  initialize_with_identity(sparse_output_values, operators, stream);

  auto d_input_keys = device_table::create(keys);
  auto d_input_values = device_table::create(values);
  auto d_sparse_output_values = device_table::create(sparse_output_values);
  rmm::device_vector<groupby::distributive_operators> d_operators(operators);

  // If we ignore null keys, then nulls are not equivalent
  bool const nulls_are_equal{not options.ignore_null_keys};
  bool const skip_rows_with_nulls{keys_have_nulls and not nulls_are_equal};

  row_hasher<keys_have_nulls> hasher{*d_input_keys};
  row_equality_comparator<keys_have_nulls> rows_equal{
      *d_input_keys, *d_input_keys, nulls_are_equal};

  using map_type =
      concurrent_unordered_map<gdf_size_type, gdf_size_type, decltype(hasher),
                               decltype(rows_equal)>;

  auto map =
      std::make_unique<map_type>(compute_hash_table_size(keys.num_rows()),
                                 unused_key, unused_value, hasher, rows_equal);

  cudf::util::cuda::grid_config_1d grid_params{keys.num_rows(), 256};

  if (skip_rows_with_nulls) {
    auto row_bitmask{cudf::row_bitmask(keys, stream)};
    build_aggregation_table<true, values_have_nulls>
        <<<grid_params.num_blocks, grid_params.num_threads_per_block, 0,
           stream>>>(map.get(), *d_input_keys, *d_input_values,
                     *d_sparse_output_values, d_operators.data().get(),
                     row_bitmask.data().get());
  } else {
    build_aggregation_table<false, values_have_nulls>
        <<<grid_params.num_blocks, grid_params.num_threads_per_block, 0,
           stream>>>(map.get(), *d_input_keys, *d_input_values,
                     *d_sparse_output_values, d_operators.data().get(),
                     nullptr);
  }

  CHECK_STREAM(stream);

  // TODO Set output key/value columns null counts
  cudf::table output_keys;
  cudf::table output_values;

  return std::make_tuple(output_keys, output_values);
}

}  // namespace

std::tuple<cudf::table, cudf::table> hash_groupby(
    cudf::table const& keys, cudf::table const& values,
    std::vector<groupby::distributive_operators> const& operators,
    groupby::Options options, cudaStream_t stream) {
  cudf::table output_keys;
  cudf::table output_values;

  if (cudf::has_nulls(keys)) {
    if (cudf::has_nulls(values)) {
      std::tie(output_keys, output_values) = compute_hash_groupby<true, true>(
          keys, values, operators, options, stream);
    } else {
      std::tie(output_keys, output_values) = compute_hash_groupby<true, false>(
          keys, values, operators, options, stream);
    }
  } else {
    if (cudf::has_nulls(values)) {
      std::tie(output_keys, output_values) = compute_hash_groupby<false, true>(
          keys, values, operators, options, stream);
    } else {
      std::tie(output_keys, output_values) = compute_hash_groupby<false, false>(
          keys, values, operators, options, stream);
    }
  }

  return std::make_tuple(output_keys, output_values);
}  // namespace detail

}  // namespace detail
}  // namespace cudf
