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

#include <cudf/null_mask.hpp>
#include <cudf/detail/null_mask.hpp>
#include <cudf/column/column_device_view.cuh>
#include <cudf/utilities/bit.hpp>
#include <cudf/utilities/error.hpp>
#include <cudf/detail/utilities/integer_utils.hpp>
#include <cudf/detail/utilities/cuda.cuh>
#include <cudf/detail/null_mask.hpp>


#include <thrust/copy.h>
#include <thrust/device_ptr.h>
#include <thrust/extrema.h>
#include <thrust/binary_search.h>
#include <cub/cub.cuh>
#include <rmm/device_buffer.hpp>
#include <rmm/device_scalar.hpp>
#include <rmm/mr/device_memory_resource.hpp>
#include <rmm/thrust_rmm_allocator.h>

#include <algorithm>
#include <numeric>
#include <type_traits>

namespace cudf {

size_type state_null_count(mask_state state, size_type size) {
  switch (state) {
    case UNALLOCATED:
      return 0;
    case UNINITIALIZED:
      return UNKNOWN_NULL_COUNT;
    case ALL_NULL:
      return size;
    case ALL_VALID:
      return 0;
    default:
      CUDF_FAIL("Invalid null mask state.");
  }
}

// Computes required allocation size of a bitmask
std::size_t bitmask_allocation_size_bytes(size_type number_of_bits,
                                          std::size_t padding_boundary) {
  CUDF_EXPECTS(padding_boundary > 0, "Invalid padding boundary");
  auto necessary_bytes =
      cudf::util::div_rounding_up_safe<size_type>(number_of_bits, CHAR_BIT);

  auto padded_bytes =
      padding_boundary * cudf::util::div_rounding_up_safe<size_type>(
                             necessary_bytes, padding_boundary);
  return padded_bytes;
}

// Computes number of *actual* bitmask_type elements needed
size_type num_bitmask_words(size_type number_of_bits) {
  return cudf::util::div_rounding_up_safe<size_type>(
      number_of_bits, detail::size_in_bits<bitmask_type>());
}

// Create a device_buffer for a null mask
rmm::device_buffer create_null_mask(size_type size, mask_state state,
                                    cudaStream_t stream,
                                    rmm::mr::device_memory_resource *mr) {
  size_type mask_size{0};

  if (state != UNALLOCATED) {
    mask_size = bitmask_allocation_size_bytes(size);
  }

  rmm::device_buffer mask(mask_size, stream, mr);

  if (state != UNINITIALIZED) {
    uint8_t fill_value = (state == ALL_VALID) ? 0xff : 0x00;
    CUDA_TRY(cudaMemsetAsync(static_cast<bitmask_type *>(mask.data()),
                             fill_value, mask_size, stream));
  }

  return mask;
}

//Set pre-allocated null mask to:
//all entries to valid, if valid_flag==true,
//or null, otherwise;
void set_null_mask(bitmask_type* bitmask,
                   size_type size, bool valid,
                   cudaStream_t stream)
{
  if (bitmask != nullptr) {
    size_type mask_size = bitmask_allocation_size_bytes(size);

    uint8_t fill_value = (valid == true) ? 0xff : 0x00;
    CUDA_TRY(cudaMemsetAsync(bitmask,
                             fill_value, mask_size, stream));
  }
}

namespace {

/**---------------------------------------------------------------------------*
 * @brief Counts the number of non-zero bits in a bitmask in the range
 * `[first_bit_index, last_bit_index]`.
 *
 * Expects `0 <= first_bit_index <= last_bit_index`.
 *
 * @param[in] bitmask The bitmask whose non-zero bits will be counted.
 * @param[in] first_bit_index The index (inclusive) of the first bit to count
 * @param[in] last_bit_index The index (inclusive) of the last bit to count
 * @param[out] global_count The number of non-zero bits in the specified range
 *---------------------------------------------------------------------------**/
template <size_type block_size>
__global__ void count_set_bits_kernel(bitmask_type const *bitmask,
                                      size_type first_bit_index,
                                      size_type last_bit_index,
                                      size_type *global_count) {
  constexpr auto const word_size{detail::size_in_bits<bitmask_type>()};

  auto const first_word_index{word_index(first_bit_index)};
  auto const last_word_index{word_index(last_bit_index)};
  auto const tid = threadIdx.x + blockIdx.x * blockDim.x;
  auto thread_word_index = tid + first_word_index;
  size_type thread_count{0};

  // First, just count the bits in all words
  while (thread_word_index <= last_word_index) {
    thread_count += __popc(bitmask[thread_word_index]);
    thread_word_index += blockDim.x * gridDim.x;
  }

  // Subtract any slack bits counted from the first and last word
  // Two threads handle this -- one for first word, one for last
  if (tid < 2) {
    bool const first{tid == 0};
    bool const last{not first};

    size_type bit_index = (first) ? first_bit_index : last_bit_index;
    size_type word_index = (first) ? first_word_index : last_word_index;

    size_type num_slack_bits = bit_index % word_size;
    if (last) {
      num_slack_bits = word_size - num_slack_bits - 1;
    }

    if (num_slack_bits > 0) {
      bitmask_type word = bitmask[word_index];
      auto slack_mask = (first) ? set_least_significant_bits(num_slack_bits)
                                : set_most_significant_bits(num_slack_bits);

      thread_count -= __popc(word & slack_mask);
    }
  }

  using BlockReduce = cub::BlockReduce<size_type, block_size>;
  __shared__ typename BlockReduce::TempStorage temp_storage;
  size_type block_count{BlockReduce(temp_storage).Sum(thread_count)};

  if (threadIdx.x == 0) {
    atomicAdd(global_count, block_count);
  }
}

/**
 * @brief Convenience function to get offset word from a bitmask
 * 
 * @see copy_offset_bitmask
 * @see offset_bitmask_and
 */
__device__ bitmask_type get_mask_offset_word(
  bitmask_type const *__restrict__ source,
  size_type destination_word_index,
  size_type source_begin_bit,
  size_type source_end_bit)
{
  size_type source_word_index = destination_word_index + word_index(source_begin_bit);
  bitmask_type curr_word = source[source_word_index];
  bitmask_type next_word = 0;
  if ((word_index(source_begin_bit) != 0) &&
      (word_index(source_end_bit) >
        word_index(source_begin_bit +
          destination_word_index * detail::size_in_bits<bitmask_type>()))) {
    next_word = source[source_word_index + 1];
  }
  return __funnelshift_r(curr_word, next_word, source_begin_bit);
}

/**
 * For each range `[first_bit_indices[i], last_bit_indices[i])`
 * (where 0 <= i < `num_ranges`), count the number of bits set outside the range
 * in the boundary words (i.e. words that include either
 * `first_bit_indices[i]'th` bit or `(last_bit_indices[i] - 1)'th` bit) and
 * subtract the count from the range's null count.
 *
 * Expects `0 <= first_bit_indices[i] <= last_bit_indices[i]`.
 *
 * @param[in] bitmask The bitmask whose non-zero bits outside the range in the
 * boundary words will be counted.
 * @param[in] num_ranges The number of ranges
 * @param[in] first_bit_indices The indices (inclusive) of the first bit in each
 * range
 * @param[in] last_bit_indices The indices (exclusive) of the last bit in each
 * range
 * @param[in,out] null_counts The number of non-zero bits in each range to be
 * updated
 */
template <typename OffsetIterator, typename OutputIterator>
__global__ void subtract_set_bits_range_boundaries_kerenel(
    bitmask_type const* bitmask,
    size_type num_ranges,
    OffsetIterator first_bit_indices,
    OffsetIterator last_bit_indices,
    OutputIterator null_counts) {
  constexpr size_type const
    word_size_in_bits{detail::size_in_bits<bitmask_type>()};

  cudf::size_type const tid = threadIdx.x + blockIdx.x * blockDim.x;
  cudf::size_type range_id = tid;

  while (range_id < num_ranges) {
    size_type const first_bit_index = *(first_bit_indices + range_id);
    size_type const last_bit_index = *(last_bit_indices + range_id);
    size_type delta = 0;
    size_type num_slack_bits = 0;

    // compute delta due to the preceding bits in the first word in the range

    num_slack_bits = intra_word_index(first_bit_index);
    if (num_slack_bits > 0) {
      bitmask_type word = bitmask[word_index(first_bit_index)];
      bitmask_type slack_mask = set_least_significant_bits(num_slack_bits);
      delta -= __popc(word & slack_mask);
    }

    // compute delta due to the following bits in the last word in the range

    num_slack_bits =
      (last_bit_index % word_size_in_bits) == 0 ?
        0 : word_size_in_bits - intra_word_index(last_bit_index);
    if (num_slack_bits > 0) {
      bitmask_type word = bitmask[word_index(last_bit_index)];
      bitmask_type slack_mask = set_most_significant_bits(num_slack_bits);
      delta -= __popc(word & slack_mask);
    }

    size_type updated_null_count = *(null_counts + range_id) + delta;
    *(null_counts + range_id) = updated_null_count;

    range_id += blockDim.x * gridDim.x;
  }
}

/**---------------------------------------------------------------------------*
 * @brief Copies the bits starting at the specified offset from a source
 * bitmask into the destination bitmask.
 *
 * Bit `i` in `destination` will be equal to bit `i + offset` from `source`.
 *
 * @param destination The mask to copy into
 * @param source The mask to copy from
 * @param source_begin_bit The offset into `source` from which to begin the copy
 * @param source_end_bit   The offset into `source` till which copying is done
 * @param number_of_mask_words The number of `cudf::bitmask_type` words to copy
 *---------------------------------------------------------------------------**/
// TODO: Also make binops test that uses offset in column_view
__global__ void copy_offset_bitmask(bitmask_type *__restrict__ destination,
                                    bitmask_type const *__restrict__ source,
                                    size_type source_begin_bit,
                                    size_type source_end_bit,
                                    size_type number_of_mask_words) {
  for (size_type destination_word_index = threadIdx.x + blockIdx.x * blockDim.x;
       destination_word_index < number_of_mask_words;
       destination_word_index += blockDim.x * gridDim.x) {
    destination[destination_word_index] =
      get_mask_offset_word(source, destination_word_index, source_begin_bit, source_end_bit);
  }
}

/**---------------------------------------------------------------------------*
 * @brief Concatenates the null mask bits of all the column device views in the
 * `views` array to the destination bitmask.
 *
 * @param views Array of column_device_view
 * @param output_offsets Prefix sum of sizes of elements of `views`
 * @param number_of_views Size of `views` array
 * @param dest_mask The output buffer to copy null masks into
 * @param number_of_mask_bits The total number of null masks bits that are being
 * copied
 *---------------------------------------------------------------------------**/
__global__
void
concatenate_masks_kernel(
    column_device_view* views,
    size_type* output_offsets,
    size_type number_of_views,
    bitmask_type* dest_mask,
    size_type number_of_mask_bits) {

  size_type mask_index = threadIdx.x + blockIdx.x * blockDim.x;

  auto active_mask =
      __ballot_sync(0xFFFF'FFFF, mask_index < number_of_mask_bits);

  while (mask_index < number_of_mask_bits) {
    size_type source_view_index = thrust::upper_bound(thrust::seq,
        output_offsets, output_offsets + number_of_views,
        mask_index) - output_offsets - 1;
    bool bit_is_set = 1;
    if (source_view_index < number_of_views) {
      size_type column_element_index = mask_index - output_offsets[source_view_index];
      bit_is_set = views[source_view_index].is_valid(column_element_index);
    }
    bitmask_type const new_word = __ballot_sync(active_mask, bit_is_set);

    if (threadIdx.x % experimental::detail::warp_size == 0) {
      dest_mask[word_index(mask_index)] = new_word;
    }

    mask_index += blockDim.x * gridDim.x;
    active_mask =
        __ballot_sync(active_mask, mask_index < number_of_mask_bits);
  }
}

/**
 * @brief Computes the bitwise AND of two bitmasks
 * 
 * @param destination The bitmask to write result into
 * @param source1 The first source mask
 * @param source2 The second source mask
 * @param begin_bit1 The @p source1 begin offset
 * @param end_bit1 The @p source1 end offset
 * @param begin_bit2 The @p source1 begin offset
 * @param end_bit2 The @p source1 end offset
 * @param number_of_mask_words The number of words of type bitmask_type to copy
 */
__global__ void offset_bitmask_and(bitmask_type *__restrict__ destination,
                                    bitmask_type const *__restrict__ source1,
                                    bitmask_type const *__restrict__ source2,
                                    size_type begin_bit1, size_type end_bit1,
                                    size_type begin_bit2, size_type end_bit2,
                                    size_type number_of_mask_words) {
  for (size_type destination_word_index = threadIdx.x + blockIdx.x * blockDim.x;
       destination_word_index < number_of_mask_words;
       destination_word_index += blockDim.x * gridDim.x) {
    bitmask_type source1_word = get_mask_offset_word(
        source1, destination_word_index, begin_bit1, end_bit1);
    bitmask_type source2_word = get_mask_offset_word(
        source2, destination_word_index, begin_bit2, end_bit2);

    destination[destination_word_index] = source1_word & source2_word;
  }
}

// Create a bitmask from a specific range
rmm::device_buffer bitmask_and(bitmask_type const *mask1, size_type begin_bit1,
                               bitmask_type const *mask2, size_type begin_bit2,
                               size_type size, cudaStream_t stream,
                               rmm::mr::device_memory_resource *mr) {
  CUDF_EXPECTS(begin_bit1 >= 0 && begin_bit2 >= 0, "Invalid range.");
  CUDF_EXPECTS(size > 0, "Invalid bit range.");
  CUDF_EXPECTS(mask1 != nullptr && mask2 != nullptr,
               "Mask pointer cannot be null");

  rmm::device_buffer dest_mask{};
  auto num_bytes = bitmask_allocation_size_bytes(size);

  auto number_of_mask_words = cudf::util::div_rounding_up_safe(
      static_cast<size_t>(size),
      detail::size_in_bits<bitmask_type>());
  dest_mask = rmm::device_buffer{num_bytes, stream, mr};
  cudf::experimental::detail::grid_1d config(number_of_mask_words, 256);
  offset_bitmask_and<<<config.num_blocks, config.num_threads_per_block, 0,
                        stream>>>(
      static_cast<bitmask_type *>(dest_mask.data()), mask1, mask2,
      begin_bit1, begin_bit1 + size,
      begin_bit2, begin_bit2 + size,
      number_of_mask_words);
  
  CHECK_CUDA(stream);

  return dest_mask;
}

// convert [first_bit_index,last_bit_index) to
// [first_word_index,last_word_index)
struct to_word_index : public thrust::unary_function<size_type, size_type> {
  bool _first = false;
  size_type const* _d_bit_indices = nullptr;

  __host__ to_word_index(bool first, size_type const* d_bit_indices) : _first(first), _d_bit_indices(d_bit_indices) {}

  __device__ size_type operator()(const size_type& i) const {
    auto bit_index = _d_bit_indices[i];
    if (_first) {  // inclusive
      return word_index(bit_index);
    }
    else {  // exclusive
      return intra_word_index(bit_index) == 0 ?
        word_index(bit_index) : word_index(bit_index) + 1;
    }
  }
};

}  // namespace

namespace detail {
cudf::size_type count_set_bits(bitmask_type const *bitmask, size_type start,
                               size_type stop, cudaStream_t stream = 0) {
  if (nullptr == bitmask) {
    return 0;
  }

  CUDF_EXPECTS(start >= 0, "Invalid range.");
  CUDF_EXPECTS(start <= stop, "Invalid bit range.");

  std::size_t num_bits_to_count = stop - start;
  if (num_bits_to_count == 0) {
    return 0;
  }

  auto num_words = cudf::util::div_rounding_up_safe(
      num_bits_to_count, detail::size_in_bits<bitmask_type>());

  constexpr size_type block_size{256};

  cudf::experimental::detail::grid_1d grid(num_words, block_size);

  rmm::device_scalar<size_type> non_zero_count(0, stream);

  count_set_bits_kernel<block_size>
      <<<grid.num_blocks, grid.num_threads_per_block, 0, stream>>>(
          bitmask, start, stop - 1, non_zero_count.data());

  return non_zero_count.value();
}

cudf::size_type count_unset_bits(bitmask_type const *bitmask, size_type start,
                                 size_type stop, cudaStream_t stream = 0) {
  if (nullptr == bitmask) {
    return 0;
  }
  auto num_bits = (stop - start);
  return (num_bits - detail::count_set_bits(bitmask, start, stop, stream));
}

std::vector<size_type>
segmented_count_set_bits(bitmask_type const* bitmask,
                         std::vector<size_type> const& indices,
                         cudaStream_t stream) {
  CUDF_EXPECTS(indices.size() % 2 == 0, "Invalid ranges.");

  if ((bitmask == nullptr) || (indices.size() == 0)) {
    return std::vector<size_type>{};
  }

  size_type num_ranges = indices.size() / 2;
  thrust::host_vector<size_type> h_first_indices(num_ranges);
  thrust::host_vector<size_type> h_last_indices(num_ranges);
  for (size_type i = 0; i < num_ranges; i++) {
    auto begin = indices[i * 2];
    auto end = indices[i * 2 + 1];
    CUDF_EXPECTS(begin >= 0, "Invalid range.");
    CUDF_EXPECTS(end >= begin, "Invalid range.");
    h_first_indices[i] = begin;
    h_last_indices[i] = end;
  }

  rmm::device_vector<size_type> d_first_indices = h_first_indices;
  rmm::device_vector<size_type> d_last_indices = h_last_indices;
  rmm::device_vector<size_type> d_null_counts(num_ranges, 0);

  auto word_elements =
    thrust::make_transform_iterator(
      thrust::make_counting_iterator(0),
      [bitmask] __device__ (auto i) {
        return static_cast<size_type>(__popc(bitmask[i]));
      });
  auto first_word_indices =
    thrust::make_transform_iterator(
      thrust::make_counting_iterator(0),
      // We cannot use lambda as cub::DeviceSegmentedReduce::Sum() requires
      // first_word_indices and last_word_indices to have the same type.
      to_word_index(true, d_first_indices.data().get()));
  auto last_word_indices =
    thrust::make_transform_iterator(
      thrust::make_counting_iterator(0),
      // We cannot use lambda as cub::DeviceSegmentedReduce::Sum() requires
      // first_word_indices and last_word_indices to have the same type.
      to_word_index(false, d_last_indices.data().get()));

  // first allocate temporary memroy

  size_t temp_storage_bytes{0};
  cub::DeviceSegmentedReduce::Sum(nullptr, temp_storage_bytes,
                                  word_elements,
                                  d_null_counts.begin(),
                                  num_ranges,
                                  first_word_indices, last_word_indices,
                                  stream);
  rmm::device_buffer d_temp_storage(temp_storage_bytes, stream);

  // second perform segmented reduction

  cub::DeviceSegmentedReduce::Sum(d_temp_storage.data(), temp_storage_bytes,
                                  word_elements,
                                  d_null_counts.begin(),
                                  num_ranges,
                                  first_word_indices, last_word_indices,
                                  stream);

  CHECK_CUDA(stream);

  // third adjust counts in segement boundaries (if segments are not
  // word-aligned)

  constexpr size_type block_size{256};

  cudf::experimental::detail::grid_1d grid(num_ranges, block_size);

  subtract_set_bits_range_boundaries_kerenel
    <<<grid.num_blocks, grid.num_threads_per_block, 0, stream>>>(
      bitmask, num_ranges, d_first_indices.begin(), d_last_indices.begin(),
      d_null_counts.begin());

  CHECK_CUDA(stream);

  std::vector<size_type> ret(num_ranges);
  CUDA_TRY(cudaMemcpyAsync(ret.data(), d_null_counts.data().get(),
                           num_ranges * sizeof(size_type),
                           cudaMemcpyDeviceToHost, stream));

  CHECK_CUDA(stream);

  return ret;
}

std::vector<size_type>
segmented_count_unset_bits(bitmask_type const* bitmask,
                           std::vector<size_type> const& indices,
                           cudaStream_t stream) {
  if (bitmask == nullptr) {
    return std::vector<size_type>();
  }

  auto ret = segmented_count_set_bits(bitmask, indices, stream);
  for (size_type i = 0; i < static_cast<size_type>(ret.size()); i++) {
    auto begin = indices[i * 2];
    auto end = indices[i * 2 + 1];
    ret[i] = (end - begin) - ret[i];
  }

  return ret;
}

// Create a bitmask from a vector of column views
void concatenate_masks(std::vector<column_view> const &views,
    bitmask_type * dest_mask,
    cudaStream_t stream) {
  using CDViewPtr =
    decltype(column_device_view::create(std::declval<column_view>(), std::declval<cudaStream_t>()));
  std::vector<CDViewPtr> cols;
  thrust::host_vector<column_device_view> device_views;

  thrust::host_vector<size_type> view_offsets(1, 0);
  for (auto &v : views) {
    cols.emplace_back(column_device_view::create(v, stream));
    device_views.push_back(*(cols.back()));
    view_offsets.push_back(v.size());
  }
  thrust::inclusive_scan(thrust::host,
      view_offsets.begin(), view_offsets.end(),
      view_offsets.begin());

  rmm::device_vector<column_device_view> d_views{device_views};
  rmm::device_vector<size_type> d_offsets{view_offsets};

  auto number_of_mask_bits = view_offsets.back();
  constexpr size_type block_size{256};
  cudf::experimental::detail::grid_1d config(number_of_mask_bits, block_size);
  concatenate_masks_kernel<<<config.num_blocks, config.num_threads_per_block,
                             0, stream>>>(
    d_views.data().get(),
    d_offsets.data().get(),
    static_cast<size_type>(d_views.size()),
    dest_mask, number_of_mask_bits);
}

}  // namespace detail

// Count non-zero bits in the specified range
cudf::size_type count_set_bits(bitmask_type const *bitmask, size_type start,
                               size_type stop) {
  return detail::count_set_bits(bitmask, start, stop);
}

// Count zero bits in the specified range
cudf::size_type count_unset_bits(bitmask_type const *bitmask, size_type start,
                                 size_type stop) {
  return detail::count_unset_bits(bitmask, start, stop);
}

// Count non-zero bits in the specified ranges
std::vector<size_type>
segmented_count_set_bits(bitmask_type const *bitmask,
                         std::vector<size_type> const& indices) {
  return detail::segmented_count_set_bits(bitmask, indices, 0);
}

// Count zero bits in the specified ranges
std::vector<size_type>
segmented_count_unset_bits(bitmask_type const *bitmask,
                           std::vector<size_type> const& indices) {
  return detail::segmented_count_unset_bits(bitmask, indices, 0);
}

// Create a bitmask from a specific range
rmm::device_buffer copy_bitmask(bitmask_type const *mask, size_type begin_bit,
                                size_type end_bit, cudaStream_t stream,
                                rmm::mr::device_memory_resource *mr) {
  CUDF_EXPECTS(begin_bit >= 0, "Invalid range.");
  CUDF_EXPECTS(begin_bit <= end_bit, "Invalid bit range.");
  rmm::device_buffer dest_mask{};
  auto num_bytes = bitmask_allocation_size_bytes(end_bit - begin_bit);
  if ((mask == nullptr) || (num_bytes == 0)) {
    return dest_mask;
  }
  if (begin_bit == 0) {
    dest_mask = rmm::device_buffer{static_cast<void const *>(mask), num_bytes,
                                   stream, mr};
  } else {
    auto number_of_mask_words = cudf::util::div_rounding_up_safe(
        static_cast<size_t>(end_bit - begin_bit),
        detail::size_in_bits<bitmask_type>());
    dest_mask = rmm::device_buffer{num_bytes, stream, mr};
    cudf::experimental::detail::grid_1d config(number_of_mask_words, 256);
    copy_offset_bitmask<<<config.num_blocks, config.num_threads_per_block, 0,
                          stream>>>(
        static_cast<bitmask_type *>(dest_mask.data()), mask, begin_bit, end_bit,
        number_of_mask_words);
    CHECK_CUDA(stream);
  }
  return dest_mask;
}

// Create a bitmask from a column view
rmm::device_buffer copy_bitmask(column_view const &view, cudaStream_t stream,
                                rmm::mr::device_memory_resource *mr) {
  rmm::device_buffer null_mask{};
  if (view.nullable()) {
    null_mask = copy_bitmask(view.null_mask(), view.offset(),
                             view.offset() + view.size(), stream, mr);
  }
  return null_mask;
}

// Create a bitmask from a vector of column views
rmm::device_buffer concatenate_masks(std::vector<column_view> const &views,
                                     rmm::mr::device_memory_resource *mr,
                                     cudaStream_t stream) {
  rmm::device_buffer null_mask{};
  bool has_nulls = std::any_of(views.begin(), views.end(),
                     [](const column_view col) { return col.has_nulls(); });
  if (has_nulls) {
   size_type total_element_count =
     std::accumulate(views.begin(), views.end(), 0,
         [](auto accumulator, auto const& v) { return accumulator + v.size(); });
    null_mask = create_null_mask(total_element_count, UNINITIALIZED, stream, mr);

    detail::concatenate_masks(
        views, static_cast<bitmask_type *>(null_mask.data()), stream);
  }

  return null_mask;
}

// Create a bitmask from a specific range
rmm::device_buffer bitmask_and(column_view const& view1,
                               column_view const& view2,
                               cudaStream_t stream,
                               rmm::mr::device_memory_resource *mr) {
  CUDF_EXPECTS(view1.size() == view2.size(), "Sizes cannot be different");

  rmm::device_buffer null_mask{};
  if (view1.size() == 0) {
    return null_mask;
  }

  if (view1.nullable() and not view2.nullable()) {
    null_mask = copy_bitmask(view1, stream, mr);
  } else if (not view1.nullable() and view2.nullable()) {
    null_mask = copy_bitmask(view2, stream, mr);
  } else if (view1.nullable() and view2.nullable()) {
    null_mask = bitmask_and(view1.null_mask(), view1.offset(),
                            view2.null_mask(), view2.offset(),
                            view1.size(), stream, mr);
  }
  
  return null_mask;
}

}  // namespace cudf
