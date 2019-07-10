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
#include <cudf/bitmask/bitmask.hpp>
#include <cudf/bitmask/bitmask_device_view.cuh>
#include <cudf/bitmask/bitmask_view.hpp>
#include <cudf/types.hpp>
#include <utilities/cuda_utils.hpp>
#include <utilities/error_utils.hpp>
#include <utilities/integer_utils.hpp>

#include <rmm/mr/device_memory_resource.hpp>

namespace cudf {

namespace {

/**---------------------------------------------------------------------------*
 * @brief Computes the required bytes neccessary to represent the specified
 * number of bits with a given padding boundary.
 *
 * @param number_of_bits The number of bits that need to be represented
 * @param padding_boundary The value returned will be rounded up to a multiple
 * of this value
 * @return std::size_t The necessary number of bytes
 *---------------------------------------------------------------------------**/
std::size_t bitmask_allocation_size_bytes(size_type number_of_bits,
                                          std::size_t padding_boundary = 64) {
  CUDF_EXPECTS(padding_boundary > 0, "Invalid padding boundary");
  auto neccessary_bytes =
      cudf::util::div_rounding_up_safe<size_type>(number_of_bits, CHAR_BIT);

  auto padded_bytes =
      padding_boundary * cudf::util::div_rounding_up_safe<size_type>(
                             neccessary_bytes, padding_boundary);
  return padded_bytes;
}

/**---------------------------------------------------------------------------*
 * @brief Returns the minimum number of bytes required to represent the
 * specified number of bits.
 *
 * @param number_of_bits The number of bits that need to be represented
 * @return cudf::size_type The minimum number of bytes required to represent
 *`number_of_bits` bits
 *---------------------------------------------------------------------------**/
std::size_t minimum_bitmask_size_bytes(size_type number_of_bits) {
  return bitmask_allocation_size_bytes(number_of_bits, sizeof(bitmask_type));
}

}  // namespace

// Allocate new device memory
bitmask::bitmask(size_type size, bit_state initial_state, cudaStream_t stream,
                 rmm::mr::device_memory_resource* mr)
    : _size(size) {
  CUDF_EXPECTS(size >= 0, "Invalid size.");
  CUDF_EXPECTS(nullptr != mr, "Null memory resource.");

  _data = std::make_unique<rmm::device_buffer>(
      bitmask_allocation_size_bytes(_size), stream, mr);

  auto fill_value = (initial_state == ON) ? 0xFF : 0x00;
  CUDA_TRY(cudaMemset(_data->data(), fill_value,
                      bitmask_allocation_size_bytes(_size)));
}

// Copy constructor
bitmask::bitmask(bitmask const& other)
    : _size{other.size()},
      _data{std::make_unique<rmm::device_buffer>(*(other._data))} {}

// Move constructor
bitmask::bitmask(bitmask&& other)
    : _size{other.size()},
      _data{std::make_unique<rmm::device_buffer>(std::move(*(other._data)))} {
  other._size = 0;
}

// Copy from existing buffer
bitmask::bitmask(size_type size, rmm::device_buffer const& source_buffer)
    : _size{size} {
  CUDF_EXPECTS(size >= 0, "Invalid size.");
  CUDF_EXPECTS(source_buffer.size() >= minimum_bitmask_size_bytes(size),
               "Insufficiently sized buffer");
  _data = std::make_unique<rmm::device_buffer>(source_buffer);
}

// Move from existing buffer
bitmask::bitmask(size_type size, rmm::device_buffer&& source_buffer) : _size{size} {
  CUDF_EXPECTS(size >= 0, "Invalid size.");
  CUDF_EXPECTS(source_buffer.size() >= minimum_bitmask_size_bytes(size),
               "Insufficiently sized buffer");
  _data = std::make_unique<rmm::device_buffer>(source_buffer);
}

namespace {

/**---------------------------------------------------------------------------*
 * @brief Copies the bits starting at the specified offset from a source
 * bitmask into the destination bitmask.
 *
 * Bit `i` in `destination` will be equal to bit `i + offset` from `source`.
 *
 * @param destination The mask to copy into
 * @param source The mask to copy from
 * @param bit_offset The offset into `source` from which to begin the copy
 * @param number_of_bits The number of bits to copy
 *---------------------------------------------------------------------------**/
__global__ void copy_offset_bitmask(mutable_bitmask_device_view destination,
                                    bitmask_device_view source,
                                    size_type bit_offset,
                                    size_type number_of_bits) {
  constexpr size_type warp_size{32};
  size_type destination_index = threadIdx.x + blockIdx.x * blockDim.x;

  auto active_mask =
      __ballot_sync(0xFFFF'FFFF, destination_index < number_of_bits);

  while (destination_index < number_of_bits) {
    bitmask_type const new_mask_element = __ballot_sync(
        active_mask, source.bit_is_set(bit_offset + destination_index));

    if (threadIdx.x % warp_size == 0) {
      destination.set_element(element_index(destination_index),
                              new_mask_element);
    }

    destination_index += blockDim.x * gridDim.x;
    active_mask =
        __ballot_sync(active_mask, destination_index < number_of_bits);
  }
}
}  // namespace

// Copy from a view
bitmask::bitmask(bitmask_view source_view, cudaStream_t stream,
                 rmm::mr::device_memory_resource* mr)
    : _size{source_view.size()} {
  if (source_view.offset() == 0) {
    // If there's no offset, do a simple copy
    _data = std::make_unique<rmm::device_buffer>(
        static_cast<void const*>(source_view.data()), _size);
  } else {
    // If there's a non-zero offset, need to handle offset bitmask elements
    _data = std::make_unique<rmm::device_buffer>(
        minimum_bitmask_size_bytes(_size), stream, mr);

    cudf::util::cuda::grid_config_1d config(_size, 256);
    copy_offset_bitmask<<<config.num_blocks, config.num_threads_per_block, 0,
                          stream>>>(this->mutable_view(), source_view,
                                    source_view.offset(), _size);

    CHECK_STREAM(stream);
  }
}

// Copy from a mutable view
bitmask::bitmask(mutable_bitmask_view source_view, cudaStream_t stream,
                 rmm::mr::device_memory_resource* mr)
    : bitmask{bitmask_view(source_view), stream, mr} {}

// Zero-copy slice
bitmask_view bitmask::slice(size_type offset, size_type slice_size) const {
  CUDF_EXPECTS(offset >= 0, "Invalid offset.");
  CUDF_EXPECTS(offset < this->size(), "Slice offset out of bounds.");
  // If the size of the slice is zero or negative, slice until the end of the
  // bitmask
  slice_size = (slice_size > 0) ? slice_size : (this->size() - offset);
  CUDF_EXPECTS((offset + slice_size) <= this->size(), "Slice out of bounds.");
  return bitmask_view{static_cast<bitmask_type const*>(_data->data()),
                      slice_size, offset};
}

// Zero-copy mutable slice
mutable_bitmask_view bitmask::mutable_slice(size_type offset,
                                            size_type slice_size) {
  CUDF_EXPECTS(offset >= 0, "Invalid offset.");
  CUDF_EXPECTS(offset < this->size(), "Slice offset out of bounds.");
  // If the size of the slice is zero or negative, slice until the end of the
  // bitmask
  slice_size = (slice_size > 0) ? slice_size : (this->size() - offset);
  CUDF_EXPECTS((offset + slice_size) <= this->size(), "Slice out of bounds.");
  return mutable_bitmask_view{static_cast<bitmask_type*>(_data->data()),
                              slice_size, offset};
}

}  // namespace cudf