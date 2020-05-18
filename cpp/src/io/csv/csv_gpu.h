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

#include <rmm/thrust_rmm_allocator.h>
#include <cudf/types.hpp>
#include <io/utilities/parsing_utils.cuh>

namespace cudf {
namespace io {
namespace csv {
namespace gpu {

/**
 * CSV row parsing context
 * NONE: No special context (normal parsing)
 * QUOTE: Within a quoted field
 * COMMENT: Within a comment line (discard every character until terminator)
 * EOF: End state (EOF reached)
 **/
enum { ROW_CTX_NONE = 0, ROW_CTX_QUOTE = 1, ROW_CTX_COMMENT = 2, ROW_CTX_EOF = 3 };

constexpr uint32_t rowofs_block_dim = 512;
/// Character block size for gather_row_offsets
constexpr uint32_t rowofs_block_bytes = rowofs_block_dim * 32;  // 16KB/threadblock

/**
 * Row parsing context with row count
 * Format: row_count * 4 + id, where `row_count` is the number of rows
 * in a character block, and `id` is the row parser state at the end of the block.
 **/
typedef uint32_t rowctx32_t;
typedef uint64_t rowctx64_t;

/**
 * Packed row context format
 *
 * The 64-bit packed row context format represents the four possible output row context states
 * from each of the four possible input row context states.
 * Each rowctx32_t value is truncated to 20-bit (limiting the max number of rows
 * to 18-bit) and concatenated to form a 80-bit value, whose upper 16 bits are
 * always zero (EOF input state implies a zero row count) and therefore
 * stored as 64-bit.
 **/
typedef uint64_t packed_rowctx_t;

/**
 * @brief return a row context from a {count, id} pair
 *
 * The 32-bit row context consists of the 2-bit parser state stored in the lower 2-bits
 * and a 30-bit row count in the upper 30 bits.
 *
 **/
inline __host__ __device__ rowctx32_t make_row_context(uint32_t row_count, uint32_t out_ctx)
{
  return (row_count << 2) + out_ctx;
}

/**
 * @brief pack multiple row contexts together
 *
 * Pack four rowctx32_t values, where each value represents the output row context
 * for one of four possible input contexts when parsing a character block.
 * Each output state consists of the 2-bit row context state along with a 18-bit row count
 * value (row count is assumed to be a local count that fits in 18-bit)
 * The four 20-bit values are concatenated to form a 80-bit value, truncated to 64-bit
 * since a block starting in a EOF state can only have a zero row count (and the output
 * state corresponding to an EOF input state can only be EOF, so only the first 3 output
 * states are included as parameters, and the EOF->EOF state transition is hardcoded)
 *
 **/
constexpr __host__ __device__ packed_rowctx_t pack_row_contexts(rowctx32_t ctx0,
                                                                rowctx32_t ctx1,
                                                                rowctx32_t ctx2)
{
  return (ctx0) | (static_cast<uint64_t>(ctx1) << 20) | (static_cast<uint64_t>(ctx2) << 40) |
         (static_cast<uint64_t>(ROW_CTX_EOF) << 60);
}

/**
 * @brief Unpack a row context  (select one of the 4 contexts in packed form)
 **/
inline __host__ __device__ rowctx32_t get_row_context(packed_rowctx_t packed_ctx, uint32_t ctxid)
{
  return static_cast<rowctx32_t>((packed_ctx >> (ctxid * 20)) & ((1 << 20) - 1));
}

/**
 * @brief Select the output row context from a given input context and a packed row
 * context corresponding to a block of characters, and return the new output context with
 * updated total row count.
 * The input context is a 64-bit version of the 32-bit single row context as returned
 * by make_row_context(), so the maximum row count here is a 62-bit value.
 *
 * @param sel_ctx input context (2-bit context id, 62-bit row count)
 * @param packed_ctx row context of character block
 * @return total_row_count * 4 + output context id
 **/
inline __host__ __device__ rowctx64_t select_row_context(rowctx64_t sel_ctx,
                                                         packed_rowctx_t packed_ctx)
{
  uint32_t ctxid = static_cast<uint32_t>(sel_ctx & 3);
  rowctx32_t ctx = get_row_context(packed_ctx, ctxid);
  return (sel_ctx & ~3) + ctx;
}

/**
 * @brief Launches kernel to gather row offsets
 *
 * This is done in two phases: the first phase returns the possible row counts
 * per 16K character block for each possible parsing context at the start of the block,
 * along with the resulting parsing context at the end of the block.
 * The caller can then compute the actual parsing context at the beginning of each
 * individual block and total row count.
 * The second phase outputs the location of each row in the block, using the parsing
 * context and initial row counter resulting from the previous phase.
 * Row parsing context will be updated after phase 2 such that the value contains
 * the number of rows starting at byte_range_end or beyond.
 *
 * @param row_ctx Row parsing context (output of phase 1 or input to phase 2)
 * @param offsets_out Row offsets (nullptr for phase1, non-null indicates phase 2)
 * @param start Base pointer of character data (all row offsets are relative to this)
 * @param chunk_size Total number of characters to parse
 * @param parse_pos Current parsing position in the file
 * @param start_offset Position of the start of the character buffer in the file
 * @param data_size CSV file size
 * @param byte_range_start Ignore rows starting before this position in the file
 * @param byte_range_end In phase 2, store the number of rows beyond range in row_ctx
 * @param skip_rows Number of rows to skip (ignored in phase 1)
 * @param num_row_offsets Number of entries in offsets_out array
 * @param options Options that control parsing of individual fields
 * @param stream CUDA stream to use, default 0
 *
 * @return Number of row contexts
 **/
uint32_t gather_row_offsets(uint64_t *row_ctx,
                            uint64_t *offsets_out,
                            const char *start,
                            size_t chunk_size,
                            size_t parse_pos,
                            size_t start_offset,
                            size_t data_size,
                            size_t byte_range_start,
                            size_t byte_range_end,
                            size_t skip_rows,
                            size_t num_row_offsets,
                            const cudf::experimental::io::ParseOptions &options,
                            cudaStream_t stream = 0);

/**
 * Count the number of blank rows in the given row offset array
 *
 * @param row_offsets Row offsets in the character data buffer
 * @param d_data Character data buffer
 * @param options Options that control parsing of individual fields
 * @param stream CUDA stream to use, default 0
 *
 **/
size_t count_blank_rows(rmm::device_vector<uint64_t> const &row_offsets,
                        rmm::device_vector<char> const &d_data,
                        const cudf::experimental::io::ParseOptions &options,
                        cudaStream_t stream = 0);

/**
 * Remove blank rows in the given row offset array
 *
 * @param row_offsets Row offsets in the character data buffer
 * @param d_data Character data buffer
 * @param options Options that control parsing of individual fields
 * @param stream CUDA stream to use, default 0
 *
 **/
void remove_blank_rows(rmm::device_vector<uint64_t> &row_offsets,
                       rmm::device_vector<char> const &d_data,
                       const cudf::experimental::io::ParseOptions &options,
                       cudaStream_t stream = 0);

/**
 * @brief Launches kernel for detecting possible dtype of each column of data
 *
 * @param[in] data The row-column data
 * @param[in] row_starts List of row data start positions (offsets)
 * @param[in] num_rows Number of rows
 * @param[in] num_columns Number of columns
 * @param[in] options Options that control individual field data conversion
 * @param[in,out] flags Flags that control individual column parsing
 * @param[out] stats Histogram of each dtypes' occurrence for each column
 * @param[in] stream CUDA stream to use, default 0
 *
 * @return cudaSuccess if successful, a CUDA error code otherwise
 **/
cudaError_t DetectColumnTypes(const char *data,
                              const uint64_t *row_starts,
                              size_t num_rows,
                              size_t num_columns,
                              const cudf::experimental::io::ParseOptions &options,
                              column_parse::flags *flags,
                              column_parse::stats *stats,
                              cudaStream_t stream = (cudaStream_t)0);

/**
 * @brief Launches kernel for decoding row-column data
 *
 * @param[in] data The row-column data
 * @param[in] row_starts List of row data start positions (offsets)
 * @param[in] num_rows Number of rows
 * @param[in] num_columns Number of columns
 * @param[in] options Options that control individual field data conversion
 * @param[in] flags Flags that control individual column parsing
 * @param[in] dtypes List of dtype corresponding to each column
 * @param[out] columns Device memory output of column data
 * @param[out] valids Device memory output of column valids bitmap data
 * @param[out] num_valid Number of valid fields in each column
 * @param[in] stream CUDA stream to use, default 0
 *
 * @return cudaSuccess if successful, a CUDA error code otherwise
 **/
cudaError_t DecodeRowColumnData(const char *data,
                                const uint64_t *row_starts,
                                size_t num_rows,
                                size_t num_columns,
                                const cudf::experimental::io::ParseOptions &options,
                                const column_parse::flags *flags,
                                cudf::data_type *dtypes,
                                void **columns,
                                cudf::bitmask_type **valids,
                                cudaStream_t stream = (cudaStream_t)0);

}  // namespace gpu
}  // namespace csv
}  // namespace io
}  // namespace cudf
