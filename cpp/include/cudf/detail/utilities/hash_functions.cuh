/*
 * Copyright (c) 2017-2020, NVIDIA CORPORATION.
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

#include <cudf/strings/string_view.cuh>
#include <hash/hash_constants.hpp>

#include "cuda_runtime_api.h"
#include "cudf/types.hpp"

using hash_value_type = uint32_t;

namespace cudf {
namespace detail {

/**
 * @brief Core MD5 algorithm implementation. Processes a single 512-bit chunk,
 * updating the hash value so far. Does not zero out the buffer contents.
 */
void CUDA_DEVICE_CALLABLE md5_hash_step(md5_intermediate_data* hash_state,
                                        md5_hash_constants_type const* hash_constants,
                                        md5_shift_constants_type const* shift_constants)
{
  uint32_t A = hash_state->hash_value[0];
  uint32_t B = hash_state->hash_value[1];
  uint32_t C = hash_state->hash_value[2];
  uint32_t D = hash_state->hash_value[3];

  for (unsigned int j = 0; j < 64; j++) {
    uint32_t F;
    uint32_t g;
    switch (j / 16) {
      case 0:
        F = (B & C) | ((~B) & D);
        g = j;
        break;
      case 1:
        F = (D & B) | ((~D) & C);
        g = (5 * j + 1) % 16;
        break;
      case 2:
        F = B ^ C ^ D;
        g = (3 * j + 5) % 16;
        break;
      case 3:
        F = C ^ (B | (~D));
        g = (7 * j) % 16;
        break;
    }

    uint32_t buffer_element_as_int;
    thrust::copy_n(thrust::seq,
                   hash_state->buffer + g * 4,
                   4,
                   reinterpret_cast<uint8_t*>(&buffer_element_as_int));
    F = F + A + hash_constants[j] + buffer_element_as_int;
    A = D;
    D = C;
    C = B;

    uint32_t shift = shift_constants[((j / 16) * 4) + (j % 4)];
    B              = B + ((F << shift) | (F >> (32 - shift)));
  }

  hash_state->hash_value[0] += A;
  hash_state->hash_value[1] += B;
  hash_state->hash_value[2] += C;
  hash_state->hash_value[3] += D;

  hash_state->buffer_length = 0;
}

template <typename Key>
struct MD5Hash {
  using argument_type = Key;

  /**
   * @brief Core MD5 element processing function
   */
  template <typename TKey>
  void __device__ process(TKey const& key,
                          md5_intermediate_data* hash_state,
                          md5_hash_constants_type const* hash_constants,
                          md5_shift_constants_type const* shift_constants) const
  {
    uint32_t const len  = sizeof(TKey);
    uint8_t const* data = reinterpret_cast<uint8_t const*>(&key);
    hash_state->message_length += len;

    if (hash_state->buffer_length + len < 64) {
      thrust::copy_n(thrust::seq, data, len, hash_state->buffer + hash_state->buffer_length);
      hash_state->buffer_length += len;
    } else {
      uint32_t copylen = 64 - hash_state->buffer_length;

      thrust::copy_n(thrust::seq, data, copylen, hash_state->buffer + hash_state->buffer_length);
      md5_hash_step(hash_state, hash_constants, shift_constants);

      while (len > 64 + copylen) {
        thrust::copy_n(thrust::seq, data + copylen, 64, hash_state->buffer);
        md5_hash_step(hash_state, hash_constants, shift_constants);
        copylen += 64;
      }

      thrust::copy_n(thrust::seq, data + copylen, len - copylen, hash_state->buffer);
      hash_state->buffer_length = len - copylen;
    }
  }

  template <typename T, typename std::enable_if_t<is_chrono<T>()>* = nullptr>
  void __device__ operator()(T const& key,
                             md5_intermediate_data* hash_state,
                             md5_hash_constants_type const* hash_constants,
                             md5_shift_constants_type const* shift_constants) const
  {
    release_assert(false && "MD5 Unsupported chrono type column");
  }

  template <typename T,
            typename std::enable_if_t<!std::is_same<T, cudf::string_view>::value &&
                                      !is_fixed_width<T>()>* = nullptr>
  void __device__ operator()(T const& key,
                             md5_intermediate_data* hash_state,
                             md5_hash_constants_type const* hash_constants,
                             md5_shift_constants_type const* shift_constants) const
  {
    release_assert(false && "MD5 Unsupported non-fixed-width type column");
  }

  void CUDA_DEVICE_CALLABLE operator()(argument_type const& key,
                                       md5_intermediate_data* hash_state,
                                       md5_hash_constants_type const* hash_constants,
                                       md5_shift_constants_type const* shift_constants) const
  {
    process(key, hash_state, hash_constants, shift_constants);
  }

  template <typename T, typename std::enable_if_t<std::is_floating_point<T>::value>* = nullptr>
  void __device__ process_floating_point(T const& key,
                                         md5_intermediate_data* hash_state,
                                         md5_hash_constants_type const* hash_constants,
                                         md5_shift_constants_type const* shift_constants) const
  {
    if (isnan(key)) {
      T nan = std::numeric_limits<T>::quiet_NaN();
      process(nan, hash_state, hash_constants, shift_constants);
    } else if (key == T{0.0}) {
      process(T{0.0}, hash_state, hash_constants, shift_constants);
    } else {
      process(key, hash_state, hash_constants, shift_constants);
    }
  }
};

template <>
void CUDA_DEVICE_CALLABLE
MD5Hash<string_view>::operator()(string_view const& key,
                                 md5_intermediate_data* hash_state,
                                 md5_hash_constants_type const* hash_constants,
                                 md5_shift_constants_type const* shift_constants) const
{
  uint32_t const len  = static_cast<uint32_t>(key.size_bytes());
  uint8_t const* data = reinterpret_cast<uint8_t const*>(key.data());

  hash_state->message_length += len;

  if (hash_state->buffer_length + len < 64) {
    thrust::copy_n(thrust::seq, data, len, hash_state->buffer + hash_state->buffer_length);
    hash_state->buffer_length += len;
  } else {
    uint32_t copylen = 64 - hash_state->buffer_length;
    thrust::copy_n(thrust::seq, data, copylen, hash_state->buffer + hash_state->buffer_length);
    md5_hash_step(hash_state, hash_constants, shift_constants);

    while (len > 64 + copylen) {
      thrust::copy_n(thrust::seq, data + copylen, 64, hash_state->buffer);
      md5_hash_step(hash_state, hash_constants, shift_constants);
      copylen += 64;
    }

    thrust::copy_n(thrust::seq, data + copylen, len - copylen, hash_state->buffer);
    hash_state->buffer_length = len - copylen;
  }
}

template <>
void CUDA_DEVICE_CALLABLE
MD5Hash<float>::operator()(float const& key,
                           md5_intermediate_data* hash_state,
                           md5_hash_constants_type const* hash_constants,
                           md5_shift_constants_type const* shift_constants) const
{
  this->process_floating_point(key, hash_state, hash_constants, shift_constants);
}

template <>
void CUDA_DEVICE_CALLABLE
MD5Hash<double>::operator()(double const& key,
                            md5_intermediate_data* hash_state,
                            md5_hash_constants_type const* hash_constants,
                            md5_shift_constants_type const* shift_constants) const
{
  this->process_floating_point(key, hash_state, hash_constants, shift_constants);
}

}  // namespace detail
}  // namespace cudf

// MurmurHash3_32 implementation from
// https://github.com/aappleby/smhasher/blob/master/src/MurmurHash3.cpp
//-----------------------------------------------------------------------------
// MurmurHash3 was written by Austin Appleby, and is placed in the public
// domain. The author hereby disclaims copyright to this source code.
// Note - The x86 and x64 versions do _not_ produce the same results, as the
// algorithms are optimized for their respective platforms. You can still
// compile and run any of them on any platform, but your performance with the
// non-native version will be less than optimal.
template <typename Key>
struct MurmurHash3_32 {
  using argument_type = Key;
  using result_type   = hash_value_type;

  CUDA_HOST_DEVICE_CALLABLE MurmurHash3_32() : m_seed(0) {}

  CUDA_HOST_DEVICE_CALLABLE uint32_t rotl32(uint32_t x, int8_t r) const
  {
    return (x << r) | (x >> (32 - r));
  }

  CUDA_HOST_DEVICE_CALLABLE uint32_t fmix32(uint32_t h) const
  {
    h ^= h >> 16;
    h *= 0x85ebca6b;
    h ^= h >> 13;
    h *= 0xc2b2ae35;
    h ^= h >> 16;
    return h;
  }

  /* --------------------------------------------------------------------------*/
  /**
   * @brief  Combines two hash values into a new single hash value. Called
   * repeatedly to create a hash value from several variables.
   * Taken from the Boost hash_combine function
   * https://www.boost.org/doc/libs/1_35_0/doc/html/boost/hash_combine_id241013.html
   *
   * @param lhs The first hash value to combine
   * @param rhs The second hash value to combine
   *
   * @returns A hash value that intelligently combines the lhs and rhs hash values
   */
  /* ----------------------------------------------------------------------------*/
  CUDA_HOST_DEVICE_CALLABLE result_type hash_combine(result_type lhs, result_type rhs)
  {
    result_type combined{lhs};

    combined ^= rhs + 0x9e3779b9 + (combined << 6) + (combined >> 2);

    return combined;
  }

  result_type CUDA_HOST_DEVICE_CALLABLE operator()(Key const& key) const { return compute(key); }

  // compute wrapper for floating point types
  template <typename T, typename std::enable_if_t<std::is_floating_point<T>::value>* = nullptr>
  hash_value_type CUDA_HOST_DEVICE_CALLABLE compute_floating_point(T const& key) const
  {
    if (key == T{0.0}) {
      return 0;
    } else if (isnan(key)) {
      T nan = std::numeric_limits<T>::quiet_NaN();
      return compute(nan);
    } else {
      return compute(key);
    }
  }

  template <typename TKey>
  result_type CUDA_HOST_DEVICE_CALLABLE compute(TKey const& key) const
  {
    constexpr int len         = sizeof(argument_type);
    const uint8_t* const data = (const uint8_t*)&key;
    constexpr int nblocks     = len / 4;

    uint32_t h1           = m_seed;
    constexpr uint32_t c1 = 0xcc9e2d51;
    constexpr uint32_t c2 = 0x1b873593;
    //----------
    // body
    const uint32_t* const blocks = (const uint32_t*)(data + nblocks * 4);
    for (int i = -nblocks; i; i++) {
      uint32_t k1 = blocks[i];  // getblock32(blocks,i);
      k1 *= c1;
      k1 = rotl32(k1, 15);
      k1 *= c2;
      h1 ^= k1;
      h1 = rotl32(h1, 13);
      h1 = h1 * 5 + 0xe6546b64;
    }
    //----------
    // tail
    const uint8_t* tail = (const uint8_t*)(data + nblocks * 4);
    uint32_t k1         = 0;
    switch (len & 3) {
      case 3: k1 ^= tail[2] << 16;
      case 2: k1 ^= tail[1] << 8;
      case 1:
        k1 ^= tail[0];
        k1 *= c1;
        k1 = rotl32(k1, 15);
        k1 *= c2;
        h1 ^= k1;
    };
    //----------
    // finalization
    h1 ^= len;
    h1 = fmix32(h1);
    return h1;
  }

 private:
  uint32_t m_seed;
};

template <>
hash_value_type CUDA_HOST_DEVICE_CALLABLE MurmurHash3_32<bool>::operator()(bool const& key) const
{
  return this->compute(static_cast<uint8_t>(key));
}

/**
 * @brief Specialization of MurmurHash3_32 operator for strings.
 */
template <>
hash_value_type CUDA_HOST_DEVICE_CALLABLE
MurmurHash3_32<cudf::string_view>::operator()(cudf::string_view const& key) const
{
  const int len         = (int)key.size_bytes();
  const uint8_t* data   = (const uint8_t*)key.data();
  const int nblocks     = len / 4;
  result_type h1        = m_seed;
  constexpr uint32_t c1 = 0xcc9e2d51;
  constexpr uint32_t c2 = 0x1b873593;
  auto getblock32       = [] __host__ __device__(const uint32_t* p, int i) -> uint32_t {
  // Individual byte reads for unaligned accesses (very likely)
#ifndef __CUDA_ARCH__
    CUDF_FAIL("Hashing a string in host code is not supported.");
#else
    auto q = (const uint8_t*)(p + i);
    return q[0] | (q[1] << 8) | (q[2] << 16) | (q[3] << 24);
#endif
  };

  //----------
  // body
  const uint32_t* const blocks = (const uint32_t*)(data + nblocks * 4);
  for (int i = -nblocks; i; i++) {
    uint32_t k1 = getblock32(blocks, i);
    k1 *= c1;
    k1 = rotl32(k1, 15);
    k1 *= c2;
    h1 ^= k1;
    h1 = rotl32(h1, 13);
    h1 = h1 * 5 + 0xe6546b64;
  }
  //----------
  // tail
  const uint8_t* tail = (const uint8_t*)(data + nblocks * 4);
  uint32_t k1         = 0;
  switch (len & 3) {
    case 3: k1 ^= tail[2] << 16;
    case 2: k1 ^= tail[1] << 8;
    case 1:
      k1 ^= tail[0];
      k1 *= c1;
      k1 = rotl32(k1, 15);
      k1 *= c2;
      h1 ^= k1;
  };
  //----------
  // finalization
  h1 ^= len;
  h1 = fmix32(h1);
  return h1;
}

template <>
hash_value_type CUDA_HOST_DEVICE_CALLABLE MurmurHash3_32<float>::operator()(float const& key) const
{
  return this->compute_floating_point(key);
}

template <>
hash_value_type CUDA_HOST_DEVICE_CALLABLE
MurmurHash3_32<double>::operator()(double const& key) const
{
  return this->compute_floating_point(key);
}

/* --------------------------------------------------------------------------*/
/**
 * @brief  This hash function simply returns the value that is asked to be hash
 reinterpreted as the result_type of the functor.
 */
/* ----------------------------------------------------------------------------*/
template <typename Key>
struct IdentityHash {
  using result_type = hash_value_type;

  /* --------------------------------------------------------------------------*/
  /**
   * @brief  Combines two hash values into a new single hash value. Called
   * repeatedly to create a hash value from several variables.
   * Taken from the Boost hash_combine function
   * https://www.boost.org/doc/libs/1_35_0/doc/html/boost/hash_combine_id241013.html
   *
   * @param lhs The first hash value to combine
   * @param rhs The second hash value to combine
   *
   * @returns A hash value that intelligently combines the lhs and rhs hash values
   */
  /* ----------------------------------------------------------------------------*/
  CUDA_HOST_DEVICE_CALLABLE result_type hash_combine(result_type lhs, result_type rhs) const
  {
    result_type combined{lhs};

    combined ^= rhs + 0x9e3779b9 + (combined << 6) + (combined >> 2);

    return combined;
  }

  CUDA_HOST_DEVICE_CALLABLE result_type operator()(const Key& key) const
  {
    return static_cast<result_type>(key);
  }
};

template <typename Key>
using default_hash = MurmurHash3_32<Key>;
