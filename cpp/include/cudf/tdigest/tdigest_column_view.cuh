/*
 * Copyright (c) 2021, NVIDIA CORPORATION.
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

#include <cudf/column/column_view.hpp>
#include <cudf/detail/iterator.cuh>
#include <cudf/lists/lists_column_view.hpp>

namespace cudf {
namespace tdigest {

struct tdigest_size {
  size_type const* offsets;
  __device__ size_type operator()(size_type tdigest_index)
  {
    return offsets[tdigest_index + 1] - offsets[tdigest_index];
  }
};

/**
 * @brief Given a column_view containing tdigest data, an instance of this class
 * provides a wrapper on the compound column for tdigest operations.
 *
 * A tdigest is a "compressed" set of input scalars represented as a sorted
 * set of centroids (https://arxiv.org/pdf/1902.04023.pdf).
 * This data can be queried for quantile information. Each row in a tdigest
 * column represents an entire tdigest.
 *
 * The column has the following structure:
 *
 * struct {
 *   // centroids for the digest
 *   list {
 *    struct {
 *      double    // mean
 *      double    // weight
 *    }
 *   }
 *   // these are from the input stream, not the centroids. they are used
 *   // during the percentile_approx computation near the beginning or
 *   // end of the quantiles
 *   double       // min
 *   double       // max
 * }
 */
class tdigest_column_view : private column_view {
 public:
  tdigest_column_view(column_view const& col);
  tdigest_column_view(tdigest_column_view&& tdigest_view)      = default;
  tdigest_column_view(const tdigest_column_view& tdigest_view) = default;
  ~tdigest_column_view()                                       = default;
  tdigest_column_view& operator=(tdigest_column_view const&) = default;
  tdigest_column_view& operator=(tdigest_column_view&&) = default;

  using column_view::size;
  static_assert(std::is_same_v<offset_type, size_type>,
                "offset_type is expected to be the same as size_type.");
  using offset_iterator = offset_type const*;

  // mean and weight column indices within tdigest inner struct columns
  static constexpr size_type mean_column_index{0};
  static constexpr size_type weight_column_index{1};

  // min and max column indices within tdigest outer struct columns
  static constexpr size_type centroid_column_index{0};
  static constexpr size_type min_column_index{1};
  static constexpr size_type max_column_index{2};

  /**
   * @brief Returns the parent column.
   */
  column_view parent() const;

  /**
   * @brief Returns the column of centroids
   */
  lists_column_view centroids() const;

  /**
   * @brief Returns the internal column of mean values
   */
  column_view means() const;

  /**
   * @brief Returns the internal column of weight values
   */
  column_view weights() const;

  /**
   * @brief Returns an iterator that returns the size of each tdigest
   * in the column (each row is 1 digest)
   */
  auto size_begin() const
  {
    return cudf::detail::make_counting_transform_iterator(
      0, tdigest_size{centroids().offsets_begin()});
  }

  /**
   * @brief Returns the first min value for the column. Each row corresponds
   * to the minimum value for the accompanying digest.
   */
  double const* min_begin() const;

  /**
   * @brief Returns the first max value for the column. Each row corresponds
   * to the maximum value for the accompanying digest.
   */
  double const* max_begin() const;
};

}  // namespace tdigest
}  // namespace cudf
