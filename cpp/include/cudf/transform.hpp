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

#include "cudf.h"
#include "types.h"
#include "types.hpp"

namespace cudf {

/**
 * @brief Creates a new column by applying a unary function against every
 * element of an input column.
 *
 * Computes:
 * `out[i] = F(in[i])`
 * 
 * The output null mask is the same is the input null mask so if input[i] is 
 * null then output[i] is also null
 *
 * @param input               An immutable view of the input column to transform
 * @param unary_udf           The PTX/CUDA string of the unary function to apply
 * @param outout_type         The output type that is compatible with the output type in the PTX code
 * @param is_ptx              If true the UDF is treated as a piece of PTX code; if fasle the UDF is treated as a piece of CUDA code
 * @return cudf::column       The column resulting from applying the unary function to
 *                            every element of the input
 **/
std::unique_ptr<column> transform(column_view const& input,
                                  const std::string &unary_udf,
                                  data_type output_type, bool is_ptx);

}  // namespace cudf
