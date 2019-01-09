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

#ifndef BIT_MASK_H
#define BIT_MASK_H

#include "utilities/cudf_utils.h"

namespace bit_mask {
  typedef uint32_t     bit_mask_t;
  
  namespace detail {
    constexpr gdf_size_type BITS_PER_ELEMENT{sizeof(bit_mask_t) * 8};

    /**
     *  @brief determine the bit mask element that contains a record
     *
     *  @param[in]  record_idx    The record index
     *
     *  @return the bit mask element index
     */
    template <typename T>
    CUDA_HOST_DEVICE_CALLABLE
    constexpr gdf_size_type WhichElement(T record_idx) {
      return (record_idx / BITS_PER_ELEMENT);
    }

    /**
     *  @brief determine which bit in a bit mask element relates to a record
     *
     *  @param[in]  record_idx    The record index
     *
     *  @return which bit within the bit mask element
     */
    template <typename T>
    CUDA_HOST_DEVICE_CALLABLE
    constexpr gdf_size_type WhichBit(T record_idx) {
      return (record_idx % BITS_PER_ELEMENT);
    }
  }

  /**
   * @brief determine the number of bit_mask_t elements are used
   *
   * @param[in]  size    Number of bits in the bitmask
   *
   * @return the number of elements
   */
  CUDA_HOST_DEVICE_CALLABLE
  constexpr gdf_size_type NumElements(gdf_size_type size) { 
    return (( size + ( detail::BITS_PER_ELEMENT - 1)) / detail::BITS_PER_ELEMENT ); 
  }

  /**
   *  @brief Copy data between host and device
   *
   *  @param[out] dst      - the address of the destination
   *  @param[in] src       - the address of the source
   *  @param[in] num_bits  - the number of bits in the bit container
   *  @param[in] kind      - the direction of the copy
   *
   *  @return GDF_SUCCESS on success, the CUDA error on failure
   */
  inline gdf_error CopyBitMask(bit_mask_t *dst, const bit_mask_t *src, size_t num_bits, enum cudaMemcpyKind kind) {
    CUDA_TRY(cudaMemcpy(dst, src, NumElements(num_bits) * sizeof(bit_mask_t), kind));
    return GDF_SUCCESS;
  }

  /**
   *  @brief Deallocate device space for the valid bit mask
   *
   *  @param[in]  valid   The pointer to device space that we wish to deallocate
   *
   *  @return GDF_SUCCESS on success, the CUDA error on failure
   */
  inline gdf_error DestroyBitMask(bit_mask_t *valid) {
    RMM_TRY(RMM_FREE(valid, 0));
    return GDF_SUCCESS;
  }

  /**
   *  @brief Get a single element of bits from the device
   *
   *  @param[out]  element - address on host where the bits will be stored
   *  @param[out]  device_element - address on the device containing the bits to fetch
   *
   *  @return GDF_SUCCESS on success, the CUDA error on failure
   */
  inline gdf_error GetElement(bit_mask_t *element, const bit_mask_t *device_element) {
    CUDA_TRY(cudaMemcpy(element, device_element, sizeof(bit_mask_t), cudaMemcpyDeviceToHost));
    return GDF_SUCCESS;
  }
	  
  /**
   *  @brief Put a single element of bits to the device
   *
   *  @param[out]  element - address on host containing bits to store
   *  @param[out]  device_element - address on the device where the bits will be stored
   *
   *  @return GDF_SUCCESS on success, the CUDA error on failure
   */
  inline gdf_error PutElement(bit_mask_t element, bit_mask_t *device_element) {
    CUDA_TRY(cudaMemcpy(device_element, &element, sizeof(bit_mask_t), cudaMemcpyHostToDevice));
    return GDF_SUCCESS;
  }

  /**
   *  @brief Allocate device space for the valid bit mask.
   *
   *  @param[out] mask                  address of the bit mask pointer
   *  @param[in]  number_of_records     number of records
   *  @param[in]  fill_value            optional, should the memory be initialized to all 0 or 1s. All other
   *                                    values indicate un-initialized.  Default is uninitialized
   *  @param[in]  padding_bytes         optional, specifies byte boundary the data should be padded to.
   *                                    Defaults to 64 bytes, meaning the space allocated will be rounded
   *                                    up to the next multiple of 64 bytes.
   *
   *  @return GDF_SUCCESS on success, the RMM or CUDA error on error
   */
  gdf_error CreateBitMask(bit_mask_t **mask, gdf_size_type number_of_records, int fill_value = -1, gdf_size_type padding_bytes = 64) {
    //
    //  To handle padding, we will round the number_of_records up to the next padding boundary, then identify how many element
    //  that equates to.  Then we can allocate the appropriate amount of storage.
    //
    gdf_size_type num_bytes = (number_of_records + 7) / 8;
    gdf_size_type num_padding_blocks = (num_bytes + padding_bytes - 1) / padding_bytes;
    gdf_size_type num_elements = bit_mask::NumElements(num_padding_blocks * 8 * padding_bytes);

    RMM_TRY(RMM_ALLOC(mask, sizeof(bit_mask_t) * num_elements, 0));

    if (fill_value == 0) {
      CUDA_TRY(cudaMemset(*mask, 0, sizeof(bit_mask_t) * num_elements));
    } else if (fill_value == 1) {
      //
      //  Filling with one is a more complex case, as we want the first
      //  number_of_records bits set to 1, and all of the remaining
      //  bits set to 0.
      //
      //  We accomplish this by identifying the number of used element.
      //  We'll set all elements from 0 to used_elements - 1 to 1, all elements
      //  from used_elements to num_elements - 1 to 0.  Finally, the last
      //  used element will be constructed to set to a left mask of ones
      //  and stored out on the device.
      //
      gdf_size_type used_elements = bit_mask::NumElements(number_of_records);
      CUDA_TRY(cudaMemset(*mask, 0xff, sizeof(bit_mask_t) * used_elements));
      CUDA_TRY(cudaMemset(&(*mask)[used_elements], 0, sizeof(bit_mask_t) * (num_elements - used_elements)));

      //
      //  Need to worry about the case where we set bits past the end
      //
      int bits_used_in_last_element = number_of_records - (used_elements - 1) * detail::BITS_PER_ELEMENT;
      bit_mask_t temp = bit_mask_t{1} << bits_used_in_last_element;
      temp--;

      return PutElement(temp, &(*mask)[used_elements-1]);
    }

    return GDF_SUCCESS;
  }

  /**
   *  @brief check to see if the specified bit is set to one
   *
   *  @param[in]  valid         The bit mask to update
   *  @param[in]  record_idx    The record index
   *
   *  @return which bit within the bit mask
   */
  template <typename T>
  CUDA_HOST_DEVICE_CALLABLE
  bool IsValid(const bit_mask_t *valid, T record_idx) {
    static_assert(std::is_integral<T>::value, "Record index must be of an integral type");

    const gdf_size_type rec{detail::WhichElement(record_idx)};
    const gdf_size_type bit{detail::WhichBit(record_idx)};

    return ((valid[rec] & (bit_mask_t{1} << bit)) != 0);
  }

  /**
   *  @brief set the specified bit in the bit mask in an unsafe manner
   *
   *  This function sets the specified bit in an unsafe manner.  It assumes that
   *  that the calling code guarantees a thread-safe context.  That is, either
   *  the function is called from a block of serial code, or the data is distributed
   *  among the threads such that no two threads could be updating a bit in the
   *  same memory location concurrently.
   *
   *  @param[in,out]  valid         The bit mask to update
   *  @param[in]      record_idx    The record index
   *
   */
  template <typename T>
  CUDA_HOST_DEVICE_CALLABLE
  void SetBitUnsafe(bit_mask_t *valid, T record_idx) {
    static_assert(std::is_integral<T>::value, "Record index must be of an integral type");

    const gdf_size_type rec{detail::WhichElement(record_idx)};
    const gdf_size_type bit{detail::WhichBit(record_idx)};

    valid[rec] = valid[rec] | (bit_mask_t{1} << bit);
  }

  /**
   *  @brief clear the specified bit in the bit mask in an unsafe manner.
   *
   *  This function clears the specified bit in an unsafe manner.  It assumes that
   *  that the calling code guarantees a thread-safe context.  That is, either
   *  the function is called from a block of serial code, or the data is distributed
   *  among the threads such that no two threads could be updating a bit in the
   *  same memory location concurrently.
   *
   *  @param[in,out]  valid         The bit mask to update
   *  @param[in]      record_idx    The record index
   *
   */
  template <typename T>
  CUDA_HOST_DEVICE_CALLABLE
  void ClearBitUnsafe(bit_mask_t *valid, T record_idx) {
    static_assert(std::is_integral<T>::value, "Record index must be of an integral type");

    const gdf_size_type rec{detail::WhichElement(record_idx)};
    const gdf_size_type bit{detail::WhichBit(record_idx)};

    valid[rec] = valid[rec] & (~(bit_mask_t{1} << bit));
  }

  /**
   *  @brief set the specified bit in the bit mask in an threadsafe manner
   *
   *  This function sets the specified bit in an threadsafe manner.  It uses
   *  atomic memory operations to guarantee that no update interferes with
   *  on another.
   *
   *  @param[in,out]  valid         The bit mask to update
   *  @param[in]      record_idx    The record index
   *
   */
  template <typename T>
  CUDA_DEVICE_CALLABLE
  void SetBitSafe(bit_mask_t *valid, T record_idx) {
    static_assert(std::is_integral<T>::value, "Record index must be of an integral type");

    const gdf_size_type rec{detail::WhichElement(record_idx)};
    const gdf_size_type bit{detail::WhichBit(record_idx)};

    atomicOr( &valid[rec], (bit_mask_t{1} << bit));
  }

  /**
   *  @brief clear the specified bit in the bit mask in an threadsafe manner
   *
   *  This function clear the specified bit in an threadsafe manner.  It uses
   *  atomic memory operations to guarantee that no update interferes with
   *  on another.
   *
   *  @param[in,out]  valid         The bit mask to update
   *  @param[in]      record_idx    The record index
   *
   */
  template <typename T>
  CUDA_DEVICE_CALLABLE
  void ClearBitSafe(bit_mask_t *valid, T record_idx) {
    static_assert(std::is_integral<T>::value, "Record index must be of an integral type");

    const gdf_size_type rec{detail::WhichElement(record_idx)};
    const gdf_size_type bit{detail::WhichBit(record_idx)};

    atomicAnd( &valid[rec], ~(bit_mask_t{1} << bit));
  }

};

#endif
