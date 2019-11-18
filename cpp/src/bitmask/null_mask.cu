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
#include <cudf/utilities/bit.hpp>
#include <cudf/utilities/error.hpp>
#include <cudf/detail/utilities/integer_utils.hpp>
#include <utilities/cuda_utils.hpp>


#include <thrust/copy.h>
#include <thrust/device_ptr.h>
#include <thrust/extrema.h>
#include <cub/cub.cuh>
#include <rmm/device_buffer.hpp>
#include <rmm/device_scalar.hpp>
#include <rmm/mr/device_memory_resource.hpp>
#include <rmm/thrust_rmm_allocator.h>

#include <algorithm>

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
 * @param number_of_mask_words The number of words of type bitmask_type to copy
 *---------------------------------------------------------------------------**/
__global__ void copy_offset_bitmask(bitmask_type *__restrict__ destination,
                                    bitmask_type const *__restrict__ source,
                                    size_type source_begin_bit,
                                    size_type source_end_bit,
                                    size_type number_of_mask_words) {
  for (size_type destination_word_index = threadIdx.x + blockIdx.x * blockDim.x;
       destination_word_index < number_of_mask_words;
       destination_word_index += blockDim.x * gridDim.x) {
    size_type source_word_index =
        destination_word_index + word_index(source_begin_bit);
    bitmask_type curr_word = source[source_word_index];
    bitmask_type next_word = 0;

    //Read next word if needed
    if ((intra_word_index(source_begin_bit) != 0) &&
        (word_index(source_end_bit) > word_index(source_begin_bit))) {
      next_word = source[source_word_index + 1];
    }
    bitmask_type write_word = __funnelshift_r(curr_word, next_word, source_begin_bit);
    destination[destination_word_index] = write_word;
  }
}

__global__ void
copy_first_bitmask_word(bitmask_type *__restrict__ destination,
                        size_type destination_begin_bit,
                        bitmask_type const *__restrict__ source,
                        size_type source_begin_bit,
                        size_type source_end_bit) {

  size_type destination_word_index = word_index(destination_begin_bit);
  if (source != nullptr) {
    size_type source_word_index = word_index(source_begin_bit);
    bitmask_type curr_word = source[source_word_index];
    bitmask_type next_word = 0;
    if ((intra_word_index(source_begin_bit) != 0) &&
        (word_index(source_end_bit) > word_index(source_begin_bit))) {
      next_word = source[source_word_index + 1];
    }
    bitmask_type write_word = __funnelshift_r(curr_word, next_word, source_begin_bit);
    write_word = __funnelshift_l(bitmask_type{-1}, write_word, destination_begin_bit);
    bitmask_type masked_destination = destination[destination_word_index] |
      (bitmask_type{-1} << (destination_begin_bit &31));
    destination[destination_word_index] = write_word & masked_destination;
  } else {
    bitmask_type write_word =
      __funnelshift_r(bitmask_type{0}, bitmask_type{-1}, destination_begin_bit);
    destination[destination_word_index] = write_word | destination[destination_word_index];
  }
}

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

  cudf::util::cuda::grid_config_1d grid(num_words, block_size);

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
    cudf::util::cuda::grid_config_1d config(number_of_mask_words, 256);
    copy_offset_bitmask<<<config.num_blocks, config.num_threads_per_block, 0,
                          stream>>>(
        static_cast<bitmask_type *>(dest_mask.data()), mask, begin_bit, end_bit,
        number_of_mask_words);
    CUDA_CHECK_LAST()
  }
  return dest_mask;
}

void copy_bitmask(
    bitmask_type const * mask,
    size_type source_begin_bit,
    size_type source_end_bit,
    bitmask_type * dest_mask,
    size_type destination_begin_bit,
    cudaStream_t stream) {

  //If destination_begin_bit is not aligned to bitmask_type word then write
  //bitmasks to the first few elements till alignment is reached.
  if (intra_word_index(destination_begin_bit) != 0) {
    auto offset = detail::size_in_bits<bitmask_type>() -
      intra_word_index(destination_begin_bit);
    copy_first_bitmask_word<<<1, 1, 0, stream>>>(
        dest_mask, destination_begin_bit,
        mask, source_begin_bit, source_end_bit);
    CUDA_CHECK_LAST();

    source_begin_bit += offset;
    destination_begin_bit += offset;
  }

  //From this point onwards destination_begin_bit should be aligned to
  //bitmask_type word
  auto number_of_mask_words = cudf::util::div_rounding_up_safe(
      static_cast<size_type>(source_end_bit - source_begin_bit),
      static_cast<size_type>(detail::size_in_bits<bitmask_type>()));

  //If source is nullptr then writing valid bitmasks is sufficient
  if (mask == nullptr) {
    thrust::constant_iterator<bitmask_type> src(bitmask_type{-1});
    thrust::device_ptr<bitmask_type> dst(dest_mask + word_index(destination_begin_bit));
    thrust::copy(rmm::exec_policy()->on(stream),
        src, src + number_of_mask_words,
        dst);
  }
  //If source is now aligned to bitmask_type word then a simple copy is
  //sufficient
  else if (intra_word_index(source_begin_bit) == 0) {
    thrust::device_ptr<const bitmask_type> src(mask + word_index(source_begin_bit));
    thrust::device_ptr<bitmask_type> dst(dest_mask + word_index(destination_begin_bit));
    thrust::copy(rmm::exec_policy()->on(stream),
        src, src + number_of_mask_words,
        dst);
  }
  //If source is misaligned then two words are read at a time and shuffled
  //to destination appropriately. This branch is avoided if
  //copy_first_bitmask_word has already handled writing appropriate
  //destination bits
  else if (number_of_mask_words != 0) {
    cudf::util::cuda::grid_config_1d config(number_of_mask_words, 256);
    copy_offset_bitmask<<<config.num_blocks, config.num_threads_per_block, 0,
                          stream>>>(
        dest_mask + word_index(destination_begin_bit), mask,
        source_begin_bit, source_end_bit,
        number_of_mask_words);
    CUDA_CHECK_LAST();
  }
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
rmm::device_buffer copy_bitmask(std::vector<column_view> const &views,
                                cudaStream_t stream,
                                rmm::mr::device_memory_resource *mr) {
  rmm::device_buffer null_mask{};
  bool has_nulls = std::any_of(views.begin(), views.end(),
                     [](const column_view col) { return col.has_nulls(); });
  if (has_nulls) {
    size_type total_element_count = 0;
    for (auto &v : views) {
      total_element_count += v.size();
    }
    null_mask = rmm::device_buffer{
      bitmask_allocation_size_bytes(total_element_count), stream, mr};

    size_type destination_begin_bit = 0;
    for (auto &v : views) {
      if (v.size() != 0) {
        copy_bitmask(
            v.null_mask(),
            v.offset(),
            v.offset() + v.size(),
            static_cast<bitmask_type *>(null_mask.data()),
            destination_begin_bit,
            stream);
      }
      destination_begin_bit += v.size();
    }
  }
  return null_mask;
}

}  // namespace cudf
