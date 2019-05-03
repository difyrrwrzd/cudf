/*
 * Copyright (c) 2018-2019, NVIDIA CORPORATION.
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

#ifndef GIS_HPP
#define GIS_HPP

#include "cudf.h"

namespace cudf {

/** 
 * @brief Find if coordinates (query points) are completely inside or not in a specific polygon
 *
 * @param[in] poly_lats: Pointer to latitudes of a polygon
 * @param[in] poly_lons: Pointer to longitudes of a polygon
 * @param[in] point_lats: Pointer to latitudes of query points
 * @param[in] point_lons: Pointer to longitudes of query points
 *
 * @returns Pointer to gdf_column indicating if the i-th query point is inside or not with {1, 0}
 */
gdf_column* gdf_point_in_polygon(const gdf_column* polygon_latitudes, 
                          const gdf_column* polygon_longitudes,
                          const gdf_column* point_latitudes, 
                          const gdf_column* point_longitudes);

}  // namespace cudf

#endif  // GIS_H
