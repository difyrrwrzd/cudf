/*
 * Copyright (c) 2023, NVIDIA CORPORATION.
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

#include "page_decode.cuh"

#include <io/utilities/column_buffer.hpp>

#include <cudf/hashing/detail/default_hash.cuh>

#include <rmm/exec_policy.hpp>
#include <thrust/reduce.h>

namespace cudf {
namespace io {
namespace parquet {
namespace gpu {

namespace {

// # of threads we're decoding with
constexpr int preprocess_block_size = 512;

// the required number of runs in shared memory we will need to provide the
// rle_stream object
constexpr int rle_run_buffer_size = rle_stream_required_run_buffer_size<preprocess_block_size>();

// the size of the rolling batch buffer
constexpr int rolling_buf_size = LEVEL_DECODE_BUF_SIZE;

using unused_state_buf = page_state_buffers_s<0, 0, 0>;

/**
 *
 * This function expects the dictionary position to be at 0 and will traverse
 * the entire thing.
 *
 * Operates on a single warp only. Expects t < 32
 *
 * @param s The local page info
 * @param t Thread index
 */
__device__ size_type gpuDecodeTotalPageStringSize(page_state_s* s, int t)
{
  size_type target_pos = s->num_input_values;
  size_type str_len    = 0;
  if (s->dict_base) {
    auto const [new_target_pos, len] =
      gpuDecodeDictionaryIndices<true, unused_state_buf>(s, nullptr, target_pos, t);
    target_pos = new_target_pos;
    str_len    = len;
  } else if ((s->col.data_type & 7) == BYTE_ARRAY) {
    str_len = gpuInitStringDescriptors<true, unused_state_buf>(s, nullptr, target_pos, t);
  }
  if (!t) { *(int32_t volatile*)&s->dict_pos = target_pos; }
  return str_len;
}

/**
 * @brief Update output column sizes for every nesting level based on a batch
 * of incoming decoded definition and repetition level values.
 *
 * If bounds_set is true, computes skipped_values and skipped_leaf_values for the
 * page to indicate where we need to skip to based on min/max row.
 *
 * Operates at the block level.
 *
 * @param s The local page info
 * @param target_value_count The target value count to process up to
 * @param rep Repetition level buffer
 * @param def Definition level buffer
 * @param t Thread index
 * @param bounds_set A boolean indicating whether or not min/max row bounds have been set
 */
template <typename level_t>
static __device__ void gpuUpdatePageSizes(page_state_s* s,
                                          int target_value_count,
                                          level_t const* const rep,
                                          level_t const* const def,
                                          int t,
                                          bool bounds_set)
{
  // max nesting depth of the column
  int const max_depth = s->col.max_nesting_depth;

  constexpr int num_warps      = preprocess_block_size / 32;
  constexpr int max_batch_size = num_warps * 32;

  using block_reduce = cub::BlockReduce<int, preprocess_block_size>;
  using block_scan   = cub::BlockScan<int, preprocess_block_size>;
  __shared__ union {
    typename block_reduce::TempStorage reduce_storage;
    typename block_scan::TempStorage scan_storage;
  } temp_storage;

  // how many input level values we've processed in the page so far
  int value_count = s->input_value_count;
  // how many rows we've processed in the page so far
  int row_count = s->input_row_count;
  // how many leaf values we've processed in the page so far
  int leaf_count = s->input_leaf_count;
  // whether or not we need to continue checking for the first row
  bool skipped_values_set = s->page.skipped_values >= 0;

  while (value_count < target_value_count) {
    int const batch_size = min(max_batch_size, target_value_count - value_count);

    // start/end depth
    int start_depth, end_depth, d;
    get_nesting_bounds<rolling_buf_size, level_t>(
      start_depth, end_depth, d, s, rep, def, value_count, value_count + batch_size, t);

    // is this thread within row bounds? in the non skip_rows/num_rows case this will always
    // be true.
    int in_row_bounds = 1;

    // if we are in the skip_rows/num_rows case, we need to check against these limits
    if (bounds_set) {
      // get absolute thread row index
      int const is_new_row = start_depth == 0;
      int thread_row_count, block_row_count;
      block_scan(temp_storage.scan_storage)
        .InclusiveSum(is_new_row, thread_row_count, block_row_count);
      __syncthreads();

      // get absolute thread leaf index
      int const is_new_leaf = (d >= s->nesting_info[max_depth - 1].max_def_level);
      int thread_leaf_count, block_leaf_count;
      block_scan(temp_storage.scan_storage)
        .InclusiveSum(is_new_leaf, thread_leaf_count, block_leaf_count);
      __syncthreads();

      // if this thread is in row bounds
      int const row_index = (thread_row_count + row_count) - 1;
      in_row_bounds =
        (row_index >= s->row_index_lower_bound) && (row_index < (s->first_row + s->num_rows));

      // if we have not set skipped values yet, see if we found the first in-bounds row
      if (!skipped_values_set) {
        int local_count, global_count;
        block_scan(temp_storage.scan_storage)
          .InclusiveSum(in_row_bounds, local_count, global_count);
        __syncthreads();

        // we found it
        if (global_count > 0) {
          // this is the thread that represents the first row.
          if (local_count == 1 && in_row_bounds) {
            s->page.skipped_values = value_count + t;
            s->page.skipped_leaf_values =
              leaf_count + (is_new_leaf ? thread_leaf_count - 1 : thread_leaf_count);
          }
          skipped_values_set = true;
        }
      }

      row_count += block_row_count;
      leaf_count += block_leaf_count;
    }

    // increment value counts across all nesting depths
    for (int s_idx = 0; s_idx < max_depth; s_idx++) {
      int const in_nesting_bounds = (s_idx >= start_depth && s_idx <= end_depth && in_row_bounds);
      int const count = block_reduce(temp_storage.reduce_storage).Sum(in_nesting_bounds);
      __syncthreads();
      if (!t) {
        PageNestingInfo* pni = &s->page.nesting[s_idx];
        pni->batch_size += count;
      }
    }

    value_count += batch_size;
  }

  // update final outputs
  if (!t) {
    s->input_value_count = value_count;

    // only used in the skip_rows/num_rows case
    s->input_leaf_count = leaf_count;
    s->input_row_count  = row_count;
  }
}

/**
 * @brief Kernel for computing per-page column size information for all nesting levels.
 *
 * This function will write out the size field for each level of nesting.
 *
 * @param pages List of pages
 * @param chunks List of column chunks
 * @param min_row Row index to start reading at
 * @param num_rows Maximum number of rows to read. Pass as INT_MAX to guarantee reading all rows
 * @param is_base_pass Whether or not this is the base pass.  We first have to compute
 * the full size information of every page before we come through in a second (trim) pass
 * to determine what subset of rows in this page we should be reading
 * @param compute_string_sizes Whether or not we should be computing string sizes
 * (PageInfo::str_bytes) as part of the pass
 */
template <typename level_t>
__global__ void __launch_bounds__(preprocess_block_size)
  gpuComputePageSizes(PageInfo* pages,
                      device_span<ColumnChunkDesc const> chunks,
                      size_t min_row,
                      size_t num_rows,
                      bool is_base_pass,
                      bool compute_string_sizes)
{
  __shared__ __align__(16) page_state_s state_g;

  page_state_s* const s = &state_g;
  int page_idx          = blockIdx.x;
  int t                 = threadIdx.x;
  PageInfo* pp          = &pages[page_idx];

  // whether or not we have repetition levels (lists)
  bool has_repetition = chunks[pp->chunk_idx].max_level[level_type::REPETITION] > 0;

  // the level stream decoders
  __shared__ rle_run<level_t> def_runs[rle_run_buffer_size];
  __shared__ rle_run<level_t> rep_runs[rle_run_buffer_size];
  rle_stream<level_t, preprocess_block_size> decoders[level_type::NUM_LEVEL_TYPES] = {{def_runs},
                                                                                      {rep_runs}};

  // setup page info
  if (!setupLocalPageInfo(s, pp, chunks, min_row, num_rows, all_types_filter{}, false)) { return; }

  // initialize the stream decoders (requires values computed in setupLocalPageInfo)
  // the size of the rolling batch buffer
  int const max_batch_size = rolling_buf_size;
  level_t* rep             = reinterpret_cast<level_t*>(pp->lvl_decode_buf[level_type::REPETITION]);
  level_t* def             = reinterpret_cast<level_t*>(pp->lvl_decode_buf[level_type::DEFINITION]);
  decoders[level_type::DEFINITION].init(s->col.level_bits[level_type::DEFINITION],
                                        s->abs_lvl_start[level_type::DEFINITION],
                                        s->abs_lvl_end[level_type::DEFINITION],
                                        max_batch_size,
                                        def,
                                        s->page.num_input_values);
  if (has_repetition) {
    decoders[level_type::REPETITION].init(s->col.level_bits[level_type::REPETITION],
                                          s->abs_lvl_start[level_type::REPETITION],
                                          s->abs_lvl_end[level_type::REPETITION],
                                          max_batch_size,
                                          rep,
                                          s->page.num_input_values);
  }
  __syncthreads();

  if (!t) {
    s->page.skipped_values      = -1;
    s->page.skipped_leaf_values = 0;
    s->page.str_bytes           = 0;
    s->input_row_count          = 0;
    s->input_value_count        = 0;

    // in the base pass, we're computing the number of rows, make sure we visit absolutely
    // everything
    if (is_base_pass) {
      s->first_row             = 0;
      s->num_rows              = INT_MAX;
      s->row_index_lower_bound = -1;
    }
  }

  // we only need to preprocess hierarchies with repetition in them (ie, hierarchies
  // containing lists anywhere within).
  compute_string_sizes =
    compute_string_sizes && ((s->col.data_type & 7) == BYTE_ARRAY && s->dtype_len != 4);

  // early out optimizations:

  // - if this is a flat hierarchy (no lists) and is not a string column. in this case we don't need
  // to do the expensive work of traversing the level data to determine sizes.  we can just compute
  // it directly.
  if (!has_repetition && !compute_string_sizes) {
    int depth = 0;
    while (depth < s->page.num_output_nesting_levels) {
      auto const thread_depth = depth + t;
      if (thread_depth < s->page.num_output_nesting_levels) {
        if (is_base_pass) { pp->nesting[thread_depth].size = pp->num_input_values; }
        pp->nesting[thread_depth].batch_size = pp->num_input_values;
      }
      depth += blockDim.x;
    }
    return;
  }

  // in the trim pass, for anything with lists, we only need to fully process bounding pages (those
  // at the beginning or the end of the row bounds)
  if (!is_base_pass && !is_bounds_page(s, min_row, num_rows, has_repetition)) {
    int depth = 0;
    while (depth < s->page.num_output_nesting_levels) {
      auto const thread_depth = depth + t;
      if (thread_depth < s->page.num_output_nesting_levels) {
        // if we are not a bounding page (as checked above) then we are either
        // returning all rows/values from this page, or 0 of them
        pp->nesting[thread_depth].batch_size =
          (s->num_rows == 0 && !is_page_contained(s, min_row, num_rows))
            ? 0
            : pp->nesting[thread_depth].size;
      }
      depth += blockDim.x;
    }
    return;
  }

  // zero sizes
  int depth = 0;
  while (depth < s->page.num_output_nesting_levels) {
    auto const thread_depth = depth + t;
    if (thread_depth < s->page.num_output_nesting_levels) {
      s->page.nesting[thread_depth].batch_size = 0;
    }
    depth += blockDim.x;
  }
  __syncthreads();

  // the core loop. decode batches of level stream data using rle_stream objects
  // and pass the results to gpuUpdatePageSizes
  int processed = 0;
  while (processed < s->page.num_input_values) {
    // TODO:  it would not take much more work to make it so that we could run both of these
    // decodes concurrently. there are a couple of shared variables internally that would have to
    // get dealt with but that's about it.
    if (has_repetition) {
      decoders[level_type::REPETITION].decode_next(t);
      __syncthreads();
    }
    // the # of rep/def levels will always be the same size
    processed += decoders[level_type::DEFINITION].decode_next(t);
    __syncthreads();

    // update page sizes
    gpuUpdatePageSizes<level_t>(s, processed, rep, def, t, !is_base_pass);
    __syncthreads();
  }

  // retrieve total string size.
  // TODO: make this block-based instead of just 1 warp
  if (compute_string_sizes) {
    if (t < 32) { s->page.str_bytes = gpuDecodeTotalPageStringSize(s, t); }
  }

  // update output results:
  // - real number of rows for the whole page
  // - nesting sizes for the whole page
  // - skipped value information for trimmed pages
  // - string bytes
  if (is_base_pass) {
    // nesting level 0 is the root column, so the size is also the # of rows
    if (!t) { pp->num_rows = s->page.nesting[0].batch_size; }

    // store off this batch size as the "full" size
    int depth = 0;
    while (depth < s->page.num_output_nesting_levels) {
      auto const thread_depth = depth + t;
      if (thread_depth < s->page.num_output_nesting_levels) {
        pp->nesting[thread_depth].size = pp->nesting[thread_depth].batch_size;
      }
      depth += blockDim.x;
    }
  }

  if (!t) {
    pp->skipped_values      = s->page.skipped_values;
    pp->skipped_leaf_values = s->page.skipped_leaf_values;
    pp->str_bytes           = s->page.str_bytes;
  }
}

}  // anonymous namespace

/**
 * @copydoc cudf::io::parquet::gpu::ComputePageSizes
 */
void ComputePageSizes(cudf::detail::hostdevice_vector<PageInfo>& pages,
                      cudf::detail::hostdevice_vector<ColumnChunkDesc> const& chunks,
                      size_t min_row,
                      size_t num_rows,
                      bool compute_num_rows,
                      bool compute_string_sizes,
                      int level_type_size,
                      rmm::cuda_stream_view stream)
{
  dim3 dim_block(preprocess_block_size, 1);
  dim3 dim_grid(pages.size(), 1);  // 1 threadblock per page

  // computes:
  // PageNestingInfo::size for each level of nesting, for each page.
  // This computes the size for the entire page, not taking row bounds into account.
  // If uses_custom_row_bounds is set to true, we have to do a second pass later that "trims"
  // the starting and ending read values to account for these bounds.
  if (level_type_size == 1) {
    gpuComputePageSizes<uint8_t><<<dim_grid, dim_block, 0, stream.value()>>>(
      pages.device_ptr(), chunks, min_row, num_rows, compute_num_rows, compute_string_sizes);
  } else {
    gpuComputePageSizes<uint16_t><<<dim_grid, dim_block, 0, stream.value()>>>(
      pages.device_ptr(), chunks, min_row, num_rows, compute_num_rows, compute_string_sizes);
  }
}

}  // namespace gpu
}  // namespace parquet
}  // namespace io
}  // namespace cudf
