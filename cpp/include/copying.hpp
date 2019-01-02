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

#ifndef COPYING_H
#define COPYING_H

#include "cudf.h"

/** 
 * @brief Scatters the rows of a set of source columns into a set
 * of destination columns.
 * 
 * Scatters the rows of the source columns into the destination columns according
 * to a scatter map such that row "i" from the source columns will be scattered 
 * to row "scatter_map[i]" in the destination columns.
 * 
 * The datatypes between coresponding columns in the source and destination columns
 * must be the same.
 * 
 * The number of elements in the scatter_map must equal the number of rows in the source
 * columns. 
 * 
 * If any index in scatter_map is outside the range of [0, num rows in destination_columns),
 * the result is undefined.
 * 
 * If the same index appears more than once in scatter_map, the result is undefined.
 * 
 * @Param[in] source_columns The columns whose rows will be scattered
 * @Param[in] scatter_map An array that maps rows in the input columns
 * to rows in the output columns.
 * @Param[out] destination_columns A preallocated set of columns with a number of 
 * rows equal in size to the maximum index contained in scatter_map
 * 
 * @Returns GDF_SUCCESS upon successful completion
 */
gdf_error gdf_scatter(gdf_dataframe const * source_columns,
                      gdf_size_type const scatter_map[], 
                      gdf_dataframe * destination_columns);

/**
 * @brief Gathers the rows of a set of source columns into a set of destination 
 * columns.
 * 
 * Gathers the rows of the source columns into the destination columns according 
 * to a gather map such that row "i" in the destination columns will contain
 * row "gather_map[i]" from the source columns.
 * 
 * The datatypes between coresponding columns in the source and destination columns
 * must be the same.
 * 
 * The number of elements in the gather_map must equal the number of rows in the 
 * destination columns. 
 * 
 * If any index in the gather_map is outside the range [0, num rows in source_columns), 
 * the result is undefined.
 * 
 * If the same index appears more than once in gather_map, the result is undefined.
 * 
 * @param[in] source_columns The input columns whose rows will be gathered
 * @param[in] gather_map An array of indices that maps the rows in the source columns
 * to rows in the destination columns. 
 * @param[out] destination_columns A preallocated set of columns with a number of rows 
 * equal in size to the number of elements in the gather_map that will contain the 
 * rearrangement of the source columns based on the mapping determined by the gather_map.
 * 
 * @Returns GDF_SUCCESS upon successful completion
 */
gdf_error gdf_gather(gdf_dataframe const * source_columns, 
                     gdf_size_type const gather_map[], 
                     gdf_dataframe * destination_columns);

#endif // COPYING_H