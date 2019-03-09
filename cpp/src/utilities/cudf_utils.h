#ifndef GDF_UTILS_H
#define GDF_UTILS_H

#include <cuda_runtime_api.h>
#include <vector>
#include "cudf.h"
#include "error_utils.hpp"

#ifdef __CUDACC__
#define CUDA_HOST_DEVICE_CALLABLE __host__ __device__ __forceinline__
#define CUDA_DEVICE_CALLABLE __device__ __forceinline__
#define CUDA_LAUNCHABLE __global__
#else
#define CUDA_HOST_DEVICE_CALLABLE inline
#define CUDA_DEVICE_CALLABLE inline
#define CUDA_LAUNCHABLE
#endif

inline gdf_error set_null_count(gdf_column* col) {
  gdf_size_type valid_count{};
  gdf_error result =
      gdf_count_nonzero_mask(col->valid, col->size, &valid_count);

  GDF_REQUIRE(GDF_SUCCESS == result, result);

  col->null_count = col->size - valid_count;

  return GDF_SUCCESS;
}

CUDA_HOST_DEVICE_CALLABLE 
bool gdf_is_valid(const gdf_valid_type *valid, gdf_index_type pos) {
	if ( valid )
		return (valid[pos / GDF_VALID_BITSIZE] >> (pos % GDF_VALID_BITSIZE)) & 1;
	else
		return true;
}

/**
 * Calculates the number of chars used for a validity indicator pseudo-column
 * for a given column's size.
 *
 * @note Note that this function assumes that `gdf_valid_type` is unsigned char
 * @note This function is different gdf_get_num_bytes_for_valids_allocation
 * because it refers to bytes used as opposed to allocated
 *
 * @param[in] column_size the number of elements
 * @return the number of bytes necessary to make available for the validity
 * indicator pseudo-column
 */
CUDA_HOST_DEVICE_CALLABLE
gdf_size_type gdf_get_num_chars_bitmask(gdf_size_type column_size) {
  return ((column_size + (GDF_VALID_BITSIZE - 1)) / GDF_VALID_BITSIZE);
}

// Buffers are padded to 64-byte boundaries (for SIMD) static
static constexpr int32_t kArrowAlignment = 64;

// Tensors are padded to 64-byte boundaries static
static constexpr int32_t kTensorAlignment = 64;

// Align on 8-byte boundaries in IPC static
static constexpr int32_t kArrowIpcAlignment = 8;

// Align on 4-byte boundaries in CUDF static
static constexpr int32_t kCudfIpcAlignment = 4;

// todo, enable arrow ipc utils, and remove this method
CUDA_HOST_DEVICE_CALLABLE
static gdf_size_type PaddedLength(int64_t nbytes,
                                  int32_t alignment = kArrowAlignment) {
  return ((nbytes + alignment - 1) / alignment) * alignment;
}

/**
 * Calculates the number of bytes to allocate for a validity indicator
 * pseudo-column for a given column's size.
 *
 * @note Note that this function assumes the valids need to be allocated to be
 * aligned with a 4 byte boundary
 *
 * @param[in] column_size the number of elements
 * @return the number of bytes necessary to allocate for the validity indicator
 * pseudo-column
 */
CUDA_HOST_DEVICE_CALLABLE
gdf_size_type gdf_get_num_bytes_for_valids_allocation(
    gdf_size_type column_size) {
  static_assert(sizeof(gdf_valid_type) == 1,
                "gdf_valid_type assumed to be 1 byte");
  return PaddedLength((column_size + (GDF_VALID_BITSIZE - 1)) /
                      GDF_VALID_BITSIZE, kArrowAlignment);
}

/* --------------------------------------------------------------------------*/
/** 
 * @brief Flatten AOS info from gdf_columns into SOA.
 * 
 * @param[in] cols Host-side array of gdf_columns
 * @param[in] ncols # columns
 * @param[out] d_cols Pointer to device array of columns
 * @param[out] d_types Device array of column types
 * 
 * @returns GDF_SUCCESS upon successful completion
 */
/* ----------------------------------------------------------------------------*/
inline gdf_error soa_col_info(gdf_column* cols, size_t ncols, void** d_cols, int* d_types)
{
	std::vector<void*> v_cols(ncols, nullptr);
	std::vector<int>   v_types(ncols, 0);
	for(size_t i=0; i<ncols; ++i)
	{
		v_cols[i] = cols[i].data;
		v_types[i] = cols[i].dtype;
	}

	void** h_cols = v_cols.data();
	int* h_types = v_types.data();
	CUDA_TRY(cudaMemcpy(d_cols, h_cols, ncols*sizeof(void*), cudaMemcpyHostToDevice));//TODO: add streams
	CUDA_TRY(cudaMemcpy(d_types, h_types, ncols*sizeof(int), cudaMemcpyHostToDevice));//TODO: add streams

	return GDF_SUCCESS;
}

/* --------------------------------------------------------------------------*/
/** 
 * @brief Flatten AOS info from gdf_columns into SOA.
 * 
 * @param[in] cols Host-side array of pointers to gdf_columns
 * @param[in] ncols # columns
 * @param[out] d_cols Pointer to device array of columns
 * @param[out] d_valids Pointer to device array of gdf_valid_type for each column
 * @param[out] d_types Device array of column types
 * 
 * @returns GDF_SUCCESS upon successful completion
 */
/* ----------------------------------------------------------------------------*/
inline gdf_error soa_col_info(gdf_column** cols, size_t ncols, void** d_cols, gdf_valid_type** d_valids, int* d_types)
{
	std::vector<void*> v_cols(ncols, nullptr);
	std::vector<gdf_valid_type*> v_valids(ncols, nullptr);
	std::vector<int>  v_types(ncols, 0);
	for(size_t i=0; i<ncols; ++i)
	{
		v_cols[i] = cols[i]->data;
		v_valids[i] = cols[i]->valid;
		v_types[i] = cols[i]->dtype;
	}

	void** h_cols = v_cols.data();
	gdf_valid_type** h_valids = v_valids.data();
	int* h_types = v_types.data();
	CUDA_TRY(cudaMemcpy(d_cols, h_cols, ncols*sizeof(void*), cudaMemcpyHostToDevice));//TODO: add streams
	CUDA_TRY(cudaMemcpy(d_valids, h_valids, ncols*sizeof(gdf_valid_type*), cudaMemcpyHostToDevice));//TODO: add streams
	CUDA_TRY(cudaMemcpy(d_types, h_types, ncols*sizeof(int), cudaMemcpyHostToDevice));//TODO: add streams

	return GDF_SUCCESS;
}

#endif // GDF_UTILS_H