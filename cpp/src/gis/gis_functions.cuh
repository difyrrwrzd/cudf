#include <bitmask/BitMask.cuh>
#include <cudf.h>
#include "cudf/functions.h"
#include "bitmask/bitmask_ops.h"

/** 
 * @brief Compute the orientation of p3 from two others points p1 and p2
 *
 * @param[in] p1_x: Longitude of the first point p1
 * @param[in] p1_y: Latitude of the first point p1
 * @param[in] p2_x: Longitude of the second point p2
 * @param[in] p2_y: Latitude of the second point p2
 * @param[in] p3_x: Longitude of the third point p3
 * @param[in] p3_y: Latitude of the third point p3
 *
 * @returns positive if it's clockwise, negative if is counter-clockwise and 0 if is colinear
 */
template <typename T>
__device__ T orientation(T p1_x, T p1_y, T p2_x, T p2_y, T p3_x, T p3_y)
{
	return ((p2_y - p1_y) * (p3_x - p2_x) - (p2_x - p1_x) * (p3_y - p2_y));
}

/** 
 * @brief Find if coordinates (query points) are completely inside or not in a specific polygon
 *
 * @param[in] poly_lats: Pointer to latitudes of a polygon
 * @param[in] poly_lons: Pointer to longitudes of a polygon
 * @param[in] point_lats: Pointer to latitudes of many query points
 * @param[in] point_lons: Pointer to longitudes of many query points
 * @param[in] poly_size: Size of polygon (first coordinate = last coordinate) must be closed
 * @param[in] point_size: Total number of query points
 * @param[out] point_is_in_polygon: Pointer indicating if the i-th query point is inside or not with {1, 0}
 *
 * @returns
 */
template <typename T>
__global__ void point_in_polygon(T* poly_lats, T* poly_lons, T* point_lats, T* point_lons, int poly_size, int point_size, int32_t* point_is_in_polygon)
{
	int start_idx = blockIdx.x * blockDim.x + threadIdx.x;

    for(int idx = start_idx; idx < point_size; idx += blockDim.x * gridDim.x)
	{
        T point_lat = point_lats[start_idx];
        T point_lon = point_lons[start_idx];
		int count = 0;

		for(int poly_idx = 0; poly_idx < poly_size - 1; poly_idx++) 
		{
			if(poly_lons[poly_idx] <= point_lon && point_lon < poly_lons[poly_idx + 1])
			{
				if (orientation(poly_lons[poly_idx], poly_lats[poly_idx], poly_lons[poly_idx + 1], poly_lats[poly_idx + 1], point_lon, point_lat) > 0)
				{
					count++;
				}
			}
			else if (point_lon <= poly_lons[poly_idx] && poly_lons[poly_idx + 1] < point_lon) 
			{
				if (orientation(poly_lons[poly_idx], poly_lats[poly_idx], poly_lons[poly_idx + 1], poly_lats[poly_idx + 1], point_lon, point_lat) > 0)
				{
					count++;
				}
			}
		}
		if ((count > 0) && (count % 2 == 0)) point_is_in_polygon[start_idx] = 1;
		else point_is_in_polygon[start_idx] = 0;
	}
}

void gdf_point_in_polygon_caller(gdf_column* polygon_lats, gdf_column* polygon_lons, gdf_column* point_lats, gdf_column* point_lons, gdf_column* output)
{
	cudaStream_t stream;
	cudaStreamCreate(&stream);
    //TODO: assert that sizes are the same etc.
    //TODO: assert that null_count = 0 on latitudes and longitude in polygon
    //    CUDF_EXPEpoint_in_polygonCTS(polygon_latitudes.null_count == 0, "message about error");
    
    int min_grid_size = 0, block_size = 0;
	cudaOccupancyMaxPotentialBlockSize( &min_grid_size, &block_size, point_in_polygon<double> );
	
    // Launch the kernel with 1024 threads by block
	point_in_polygon<double> <<< min_grid_size, block_size >>> ( static_cast<double*>(polygon_lats->data), static_cast<double*>(polygon_lons->data),
		static_cast<double*>(point_lats->data),static_cast<double*>(point_lons->data), polygon_lats->size, point_lats->size, 
		static_cast<int32_t*>(output->data) );

	if (point_lats->null_count == 0 && point_lons->null_count == 0) output->null_count = 0;
	else {
		auto error_copy_bit_mask = bit_mask::copy_bit_mask( reinterpret_cast<bit_mask::bit_mask_t*>(output->valid),
		reinterpret_cast<bit_mask::bit_mask_t*>(point_lats->valid), 
		point_lats->size, cudaMemcpyDeviceToDevice );

		gdf_size_type null_count;
		auto err = apply_bitmask_to_bitmask( null_count, output->valid, output->valid, point_lons->valid, stream, output->size);
		output->null_count = null_count;
	}

	cudaStreamDestroy(stream);
}



