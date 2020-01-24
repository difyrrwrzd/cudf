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
#include "orc_common.h"
#include "orc_gpu.h"
#include <io/utilities/block_utils.cuh>

namespace cudf {
namespace io {
namespace orc {
namespace gpu {

/**
 * @brief Initializes statistics groups
 *
 * @param[out] groups Statistics groups
 * @param[in] cols Column descriptors
 * @param[in] num_columns Number of columns
 * @param[in] num_rowgroups Number of rowgroups
 * @param[in] row_index_stride Rowgroup size in rows
 *
 **/
// blockDim {128,1,1}
__global__ void __launch_bounds__(128)
gpuInitStatisticsGroups(statistics_group *groups, const stats_column_desc *cols,
                        uint32_t num_columns, uint32_t num_rowgroups, uint32_t row_index_stride) {
  __shared__ __align__(4) volatile statistics_group grp_g[4];
  uint32_t col_id = blockIdx.y;
  uint32_t ck_id = (blockIdx.x * 4) + (threadIdx.x >> 5);
  uint32_t t = threadIdx.x & 0x1f;
  volatile statistics_group *grp = &grp_g[threadIdx.x >> 5];
  if (ck_id < num_rowgroups) {
    if (!t) {
      uint32_t num_rows = cols[col_id].num_rows;
      grp->col = &cols[col_id];
      grp->start_row = ck_id * row_index_stride;
      grp->num_rows = min(num_rows - min(ck_id * row_index_stride, num_rows), row_index_stride);
      __threadfence_block();
    }
    SYNCWARP();
    if (t < sizeof(statistics_group) / sizeof(uint32_t)) {
      reinterpret_cast<uint32_t *>(&groups[col_id * num_rowgroups + ck_id])[t] = reinterpret_cast<volatile uint32_t *>(grp)[t];
    }
  } 
}


/**
 * @brief Get the buffer size and offsets of encoded statistics
 *
 * @param[in,out] groups Statistics merge groups
 * @param[in] statistics_count Number of statistics buffers
 *
 **/
// blockDim {1024,1,1}
__global__ void __launch_bounds__(1024, 1)
gpuInitStatisticsBufferSize(statistics_merge_group *groups, const statistics_chunk *chunks, uint32_t statistics_count) {
  __shared__ volatile uint32_t scratch_red[32];
  __shared__ volatile uint32_t stats_size;
  uint32_t t = threadIdx.x;
  if (!t) {
    stats_size = 0;
  }
  __syncthreads();
  for (uint32_t start = 0; start < statistics_count; start += 1024) {
    uint32_t stats_len = 0, stats_pos;
    uint32_t idx = start + t;
    if (idx < statistics_count) {
      const stats_column_desc *col = groups[idx].col;
      statistics_dtype dtype = col->stats_dtype;
      switch(dtype) {
      case dtype_bool8:
        stats_len = 2 + 2 * 5;
        break;
      case dtype_int8:
      case dtype_int16:
      case dtype_int32:
      case dtype_date32:
      case dtype_int64:
      case dtype_timestamp64:
        stats_len = 2 + 3 * (2 + 10);
        break;
      case dtype_float32:
      case dtype_float64:
        stats_len = 2 + 3 * (2 + 8);
        break;
      case dtype_decimal64:
      case dtype_decimal128:
        stats_len = 2 + 3 * (2 + 40);
        break;
      case dtype_string:
        stats_len = 5 + 10 + chunks[idx].min_value.str_val.length + chunks[idx].max_value.str_val.length;
        break;
      default: break;
      }
    }
    stats_pos = WarpReducePos32(stats_len, t);
    if ((t & 0x1f) == 0x1f) {
      scratch_red[t >> 5] = stats_pos;
    }
    __syncthreads();
    if (t < 32) {
      scratch_red[t] = WarpReducePos32(scratch_red[t], t);
    }
    __syncthreads();
    if (t >= 32) {
      stats_pos += scratch_red[(t >> 5) - 1];
    }
    stats_pos += stats_size;
    if (idx < statistics_count) {
      groups[idx].start_chunk = stats_pos - stats_len;
      groups[idx].num_chunks = stats_len;
    }
    __syncthreads();
    if (t == 1023) {
      stats_size = stats_pos;
    }
  }
}



/**
 * @brief Launches kernels to initialize statistics collection
 *
 * @param[out] groups Statistics groups (rowgroup-level)
 * @param[in] cols Column descriptors
 * @param[in] num_columns Number of columns
 * @param[in] num_rowgroups Number of rowgroups
 * @param[in] row_index_stride Rowgroup size in rows
 * @param[in] stream CUDA stream to use, default 0
 *
 * @return cudaSuccess if successful, a CUDA error code otherwise
 **/
cudaError_t OrcInitStatisticsGroups(statistics_group *groups, const stats_column_desc *cols, uint32_t num_columns,
                                    uint32_t num_rowgroups, uint32_t row_index_stride, cudaStream_t stream)
{
    dim3 dim_groups((num_rowgroups+3) >> 2, num_columns);
    gpuInitStatisticsGroups <<< dim_groups, 128, 0, stream >>>(groups, cols, num_columns, num_rowgroups, row_index_stride);

    return cudaSuccess;
}


/**
 * @brief Launches kernels to return statistics buffer offsets and sizes
 *
 * @param[in,out] groups Statistics merge groups
 * @param[in] chunks Satistics chunks
 * @param[in] statistics_count Number of statistics buffers to encode
 * @param[in] stream CUDA stream to use, default 0
 *
 * @return cudaSuccess if successful, a CUDA error code otherwise
 **/
cudaError_t OrcInitStatisticsBufferSize(statistics_merge_group *groups, const statistics_chunk *chunks,
                                        uint32_t statistics_count, cudaStream_t stream)
{
    gpuInitStatisticsBufferSize <<< 1, 1024, 0, stream >>>(groups, chunks, statistics_count);

    return cudaSuccess;
}



} // namespace gpu
} // namespace orc
} // namespace io
} // namespace cudf
