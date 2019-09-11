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
#include "orc_common.h"
#include "orc_gpu.h"

#include <rmm/thrust_rmm_allocator.h>

#include <thrust/execution_policy.h>
#include <thrust/device_ptr.h>
#include <thrust/sort.h>

namespace cudf {
namespace io {
namespace orc {
namespace gpu {

#if (__CUDACC_VER_MAJOR__ >= 9)
#define SHFL0(v)        __shfl_sync(~0, v, 0)
#define SHFL(v, t)      __shfl_sync(~0, v, t)
#define SHFL_XOR(v, m)  __shfl_xor_sync(~0, v, m)
#define SYNCWARP()      __syncwarp()
#define BALLOT(v)       __ballot_sync(~0, v)
#else
#define SHFL0(v)        __shfl(v, 0)
#define SHFL(v, t)      __shfl(v, t)
#define SHFL_XOR(v, m)  __shfl_xor(v, m)
#define SYNCWARP()
#define BALLOT(v)       __ballot(v)
#endif

#define WARP_REDUCE_SUM_2(sum)      sum += SHFL_XOR(sum, 1)
#define WARP_REDUCE_SUM_4(sum)      WARP_REDUCE_SUM_2(sum); sum += SHFL_XOR(sum, 2)
#define WARP_REDUCE_SUM_8(sum)      WARP_REDUCE_SUM_4(sum); sum += SHFL_XOR(sum, 4)
#define WARP_REDUCE_SUM_16(sum)     WARP_REDUCE_SUM_8(sum); sum += SHFL_XOR(sum, 8)
#define WARP_REDUCE_SUM_32(sum)     WARP_REDUCE_SUM_16(sum); sum += SHFL_XOR(sum, 16)

#define WARP_REDUCE_POS_2(pos, tmp, t)  tmp = SHFL(pos, t & 0x1e); pos += (t & 1) ? tmp : 0;
#define WARP_REDUCE_POS_4(pos, tmp, t)  WARP_REDUCE_POS_2(pos, tmp, t); tmp = SHFL(pos, (t & 0x1c) | 1); pos += (t & 2) ? tmp : 0;
#define WARP_REDUCE_POS_8(pos, tmp, t)  WARP_REDUCE_POS_4(pos, tmp, t); tmp = SHFL(pos, (t & 0x18) | 3); pos += (t & 4) ? tmp : 0;
#define WARP_REDUCE_POS_16(pos, tmp, t) WARP_REDUCE_POS_8(pos, tmp, t); tmp = SHFL(pos, (t & 0x10) | 7); pos += (t & 8) ? tmp : 0;
#define WARP_REDUCE_POS_32(pos, tmp, t) WARP_REDUCE_POS_16(pos, tmp, t); tmp = SHFL(pos, 0xf); pos += (t & 16) ? tmp : 0;

#define MAX_SHORT_DICT_ENTRIES      (10*1024)
#define INIT_HASH_BITS              12

/**
 * @brief Compares two strings
 */
template<class T, const T lesser, const T greater, const T equal>
inline __device__ T nvstr_compare(const char *as, uint32_t alen, const char *bs, uint32_t blen)
{
    uint32_t len = min(alen, blen);
    uint32_t i = 0;
    if (len >= 4)
    {
        uint32_t align_a = 3 & reinterpret_cast<uintptr_t>(as);
        uint32_t align_b = 3 & reinterpret_cast<uintptr_t>(bs);
        const uint32_t *as32 = reinterpret_cast<const uint32_t *>(as - align_a);
        const uint32_t *bs32 = reinterpret_cast<const uint32_t *>(bs - align_b);
        uint32_t ofsa = align_a * 8;
        uint32_t ofsb = align_b * 8;
        do {
            uint32_t a = *as32++;
            uint32_t b = *bs32++;
            if (ofsa)
                a = __funnelshift_r(a, *as32, ofsa);
            if (ofsb)
                b = __funnelshift_r(b, *bs32, ofsb);
            if (a != b)
            {
                return (lesser == greater || __byte_perm(a, 0, 0x0123) < __byte_perm(b, 0, 0x0123)) ? lesser : greater;
            }
            i += 4;
        } while (i + 4 <= len);
    }
    while (i < len)
    {
        uint8_t a = as[i];
        uint8_t b = bs[i];
        if (a != b)
        {
            return (a < b) ? lesser : greater;
        }
        ++i;
    }
    return (alen == blen) ? equal : (alen < blen) ? lesser : greater;
}

static inline bool __device__ nvstr_is_lesser(const char *as, uint32_t alen, const char *bs, uint32_t blen)
{
    return nvstr_compare<bool, true, false, false>(as, alen, bs, blen);
}
static inline bool __device__ nvstr_is_equal(const char *as, uint32_t alen, const char *bs, uint32_t blen)
{
    return nvstr_compare<bool, false, false, true>(as, alen, bs, blen);
}


struct dictinit_state_s
{
    uint32_t nnz;
    uint32_t total_dupes;
    DictionaryChunk chunk;
    volatile uint32_t scratch_red[32];
    uint16_t dict[MAX_SHORT_DICT_ENTRIES];
    union {
        uint16_t u16[1 << (INIT_HASH_BITS)];
        uint32_t u32[1 << (INIT_HASH_BITS - 1)];
    } map;
};


/**
 * @brief Return a 12-bit hash from a byte sequence
 */
static inline __device__ uint32_t nvstr_init_hash(const uint8_t *ptr, uint32_t len)
{
    if (len != 0)
    {
        return (ptr[0] + (ptr[len - 1] << 5) + (len << 10)) & ((1 << INIT_HASH_BITS) - 1);
    }
    else
    {
        return 0;
    }
}


/**
 * @brief Fill dictionary with the indices of non-null rows
 *
 * @param[in,out] s dictionary builder state
 * @param[in] t thread id
 *
 **/
static __device__ void LoadNonNullIndices(volatile dictinit_state_s *s, int t)
{
    if (t == 0)
    {
        s->nnz = 0;
    }
    for (uint32_t i = 0; i < s->chunk.num_rows; i += 512)
    {
        const uint32_t *valid_map = s->chunk.valid_map_base;
        uint32_t is_valid, nz_map, nz_pos;
        if (t < 16)
        {
            if (!valid_map)
            {
                s->scratch_red[t] = 0xffffffffu;
            }
            else
            {
                uint32_t row = s->chunk.start_row + i + t * 32;
                uint32_t v = (row < s->chunk.start_row + s->chunk.num_rows) ? valid_map[row >> 5] : 0;
                if (row & 0x1f)
                {
                    uint32_t v1 = (row + 32 < s->chunk.start_row + s->chunk.num_rows) ? valid_map[(row >> 5) + 1] : 0;
                    v = __funnelshift_r(v, v1, row & 0x1f);
                }
                s->scratch_red[t] = v;
            }
        }
        __syncthreads();
        is_valid = (i + t < s->chunk.num_rows) ? (s->scratch_red[t >> 5] >> (t & 0x1f)) & 1 : 0;
        nz_map = BALLOT(is_valid);
        nz_pos = s->nnz + __popc(nz_map & (0x7fffffffu >> (0x1fu - ((uint32_t)t & 0x1f))));
        if (!(t & 0x1f))
        {
            s->scratch_red[16 + (t >> 5)] = __popc(nz_map);
        }
        __syncthreads();
        if (t < 32)
        {
            uint32_t nnz = s->scratch_red[16 + (t & 0xf)];
            uint32_t nnz_pos = nnz, tmp;
            WARP_REDUCE_POS_16(nnz_pos, tmp, t);
            if (t == 0xf)
            {
                s->nnz += nnz_pos;
            }
            if (t <= 0xf)
            {
                s->scratch_red[t] = nnz_pos - nnz;
            }
        }
        __syncthreads();
        if (is_valid)
        {
            s->dict[nz_pos + s->scratch_red[t >> 5]] = i + t;
        }
        __syncthreads();
    }
}


/**
 * @brief Gather all non-NULL string rows and compute total character data size
 *
 * @param[in] chunks DictionaryChunk device array [rowgroup][column]
 * @param[in] num_columns Number of columns
 *
 **/
// blockDim {512,1,1}
extern "C" __global__ void __launch_bounds__(512, 3)
gpuInitDictionaryIndices(DictionaryChunk *chunks, uint32_t num_columns)
{
    __shared__ __align__(16) dictinit_state_s state_g;

    dictinit_state_s * const s = &state_g;
    uint32_t col_id = blockIdx.x;
    uint32_t group_id = blockIdx.y;
    const nvstrdesc_s *ck_data;
    uint32_t *dict_data;
    uint32_t nnz, start_row, dict_char_count;
    int t = threadIdx.x;

    if (t < sizeof(DictionaryChunk) / sizeof(uint32_t))
    {
        ((volatile uint32_t *)&s->chunk)[t] = ((const uint32_t *)&chunks[group_id * num_columns + col_id])[t];
    }
    for (uint32_t i = 0; i < sizeof(s->map) / sizeof(uint32_t); i += 512)
    {
        if (i + t < sizeof(s->map) / sizeof(uint32_t))
            s->map.u32[i + t] = 0;
    }
    __syncthreads();
    // First, take care of NULLs, and count how many strings we have (TODO: bypass this step when there are no nulls)
    LoadNonNullIndices(s, t);
    // Sum the lengths of all the strings
    if (t == 0)
    {
        s->chunk.string_char_count = 0;
        s->total_dupes = 0;
    }
    nnz = s->nnz;
    dict_data = s->chunk.dict_data;
    start_row = s->chunk.start_row;
    ck_data = reinterpret_cast<const nvstrdesc_s *>(s->chunk.column_data_base) + start_row;
    for (uint32_t i = 0; i < nnz; i += 512)
    {
        uint32_t ck_row = 0, len = 0, hash;
        const uint8_t *ptr = 0;
        if (i + t < nnz)
        {
            ck_row = s->dict[i + t];
            ptr = reinterpret_cast<const uint8_t *>(ck_data[ck_row].ptr);
            len = ck_data[ck_row].count;
            hash = nvstr_init_hash(ptr, len);
        }
        WARP_REDUCE_SUM_16(len);
        s->scratch_red[t >> 4] = len;
        __syncthreads();
        if (t < 32)
        {
            len = s->scratch_red[t];
            WARP_REDUCE_SUM_32(len);
            if (t == 0)
                s->chunk.string_char_count += len;
        }
        if (i + t < nnz)
        {
            atomicAdd(&s->map.u32[hash >> 1], 1 << ((hash & 1) ? 16 : 0));
            dict_data[i + t] = start_row + ck_row;
        }
        __syncthreads();
    }
    // Reorder the 16-bit local indices according to the hash value of the strings
#if (INIT_HASH_BITS != 12)
#error "Hardcoded for INIT_HASH_BITS=12"
#endif
    {
        // Cumulative sum of hash map counts
        uint32_t count01 = s->map.u32[t * 4 + 0];
        uint32_t count23 = s->map.u32[t * 4 + 1];
        uint32_t count45 = s->map.u32[t * 4 + 2];
        uint32_t count67 = s->map.u32[t * 4 + 3];
        uint32_t sum01 = count01 + (count01 << 16);
        uint32_t sum23 = count23 + (count23 << 16);
        uint32_t sum45 = count45 + (count45 << 16);
        uint32_t sum67 = count67 + (count67 << 16);
        uint32_t sum_w, tmp;
        sum23 += (sum01 >> 16) * 0x10001;
        sum45 += (sum23 >> 16) * 0x10001;
        sum67 += (sum45 >> 16) * 0x10001;
        sum_w = sum67 >> 16;
        WARP_REDUCE_POS_16(sum_w, tmp, t);
        if ((t & 0xf) == 0xf)
        {
            s->scratch_red[t >> 4] = sum_w;
        }
        __syncthreads();
        if (t < 32)
        {
            uint32_t sum_b = s->scratch_red[t];
            WARP_REDUCE_POS_32(sum_b, tmp, t);
            s->scratch_red[t] = sum_b;
        }
        __syncthreads();
        tmp = (t >= 16) ? s->scratch_red[(t >> 4) - 1] : 0;
        sum_w = (sum_w - (sum67 >> 16) + tmp) * 0x10001;
        s->map.u32[t * 4 + 0] = sum_w + sum01 - count01;
        s->map.u32[t * 4 + 1] = sum_w + sum23 - count23;
        s->map.u32[t * 4 + 2] = sum_w + sum45 - count45;
        s->map.u32[t * 4 + 3] = sum_w + sum67 - count67;
        __syncthreads();
    }
    // Put the indices back in hash order
    for (uint32_t i = 0; i < nnz; i += 512)
    {
        uint32_t ck_row = 0, pos = 0, hash = 0, pos_old, pos_new, sh, colliding_row;
        bool collision;
        if (i + t < nnz)
        {
            const uint8_t *ptr;
            uint32_t len;
            ck_row = dict_data[i + t] - start_row;
            ptr = reinterpret_cast<const uint8_t *>(ck_data[ck_row].ptr);
            len = (uint32_t)ck_data[ck_row].count;
            hash = nvstr_init_hash(ptr, len);
            sh = (hash & 1) ? 16 : 0;
            pos_old = s->map.u16[hash];
        }
        // The isolation of the atomicAdd, along with pos_old/pos_new is to guarantee deterministic behavior for the
        // first row in the hash map that will be used for early duplicate detection
        // The lack of 16-bit atomicMin makes this a bit messy...
        __syncthreads();
        if (i + t < nnz)
        {
            pos = (atomicAdd(&s->map.u32[hash >> 1], 1 << sh) >> sh) & 0xffff;
            s->dict[pos] = ck_row;
        }
        __syncthreads();
        collision = false;
        if (i + t < nnz)
        {
            pos_new = s->map.u16[hash];
            collision = (pos != pos_old && pos_new > pos_old + 1);
            if (collision)
            {
                colliding_row = s->dict[pos_old];
            }
        }
        __syncthreads();
        // evens
        if (collision && !(pos_old & 1))
        {
            uint32_t *dict32 = reinterpret_cast<uint32_t *>(&s->dict[pos_old]);
            atomicMin(dict32, (dict32[0] & 0xffff0000) | ck_row);
        }
        __syncthreads();
        // odds
        if (collision && (pos_old & 1))
        {
            uint32_t *dict32 = reinterpret_cast<uint32_t *>(&s->dict[pos_old-1]);
            atomicMin(dict32, (dict32[0] & 0x0000ffff) | (ck_row << 16));
        }
        __syncthreads();
        // Resolve collision
        if (collision && ck_row == s->dict[pos_old])
        {
            s->dict[pos] = colliding_row;
        }
    }
    __syncthreads();
    // Now that the strings are ordered by hash, compare every string with the first entry in the hash map,
    // the position of the first string can be inferred from the hash map counts
    dict_char_count = 0;
    for (uint32_t i = 0; i < nnz; i += 512)
    {
        uint32_t ck_row = 0, ck_row_ref = 0, is_dupe = 0, dupe_mask, dupes_before;
        if (i + t < nnz)
        {
            const char *str1, *str2;
            uint32_t len1, len2, hash;
            ck_row = s->dict[i + t];
            str1 = ck_data[ck_row].ptr;
            len1 = (uint32_t)ck_data[ck_row].count;
            hash = nvstr_init_hash(reinterpret_cast<const uint8_t *>(str1), len1);
            ck_row_ref = s->dict[(hash > 0) ? s->map.u16[hash - 1] : 0];
            if (ck_row_ref != ck_row)
            {
                str2 = ck_data[ck_row_ref].ptr;
                len2 = (uint32_t)ck_data[ck_row_ref].count;
                is_dupe = nvstr_is_equal(str1, len1, str2, len2);
                dict_char_count += (is_dupe) ? 0 : len1;
            }
        }
        dupe_mask = BALLOT(is_dupe);
        dupes_before = s->total_dupes + __popc(dupe_mask & ((2 << (t & 0x1f)) - 1));
        if (!(t & 0x1f))
        {
            s->scratch_red[t >> 5] = __popc(dupe_mask);
        }
        __syncthreads();
        if (t < 32)
        {
            uint32_t warp_dupes = (t < 16) ? s->scratch_red[t] : 0;
            uint32_t warp_pos = warp_dupes, tmp;
            WARP_REDUCE_POS_16(warp_pos, tmp, t);
            if (t == 0xf)
            {
                s->total_dupes += warp_pos;
            }
            if (t < 16)
            {
                s->scratch_red[t] = warp_pos - warp_dupes;
            }
        }
        __syncthreads();
        if (i + t < nnz)
        {
            if (!is_dupe)
            {
                dupes_before += s->scratch_red[t >> 5];
                dict_data[i + t - dupes_before] = ck_row + start_row;
            }
            else
            {
                s->chunk.dict_index[ck_row + start_row] = (ck_row_ref + start_row) | (1u << 31);
            }
        }
    }
    WARP_REDUCE_SUM_32(dict_char_count);
    if (!(t & 0x1f))
    {
        s->scratch_red[t >> 5] = dict_char_count;
    }
    __syncthreads();
    if (t < 32)
    {
        dict_char_count = (t < 16) ? s->scratch_red[t] : 0;
        WARP_REDUCE_SUM_16(dict_char_count);
    }
    if (!t)
    {
        chunks[group_id * num_columns + col_id].num_strings = nnz;
        chunks[group_id * num_columns + col_id].string_char_count = s->chunk.string_char_count;
        chunks[group_id * num_columns + col_id].num_dict_strings = nnz - s->total_dupes;
        chunks[group_id * num_columns + col_id].dict_char_count = dict_char_count;
    }
}


struct compact_state_s
{
    uint32_t *stripe_data;
    StripeDictionary stripe;
    DictionaryChunk chunk;
    volatile uint32_t scratch_red[32];
};


/**
 * @brief In-place concatenate dictionary data for all chunks in each stripe
 *
 * @param[in] stripes StripeDictionary device array [stripe][column]
 * @param[in] chunks DictionaryChunk device array [rowgroup][column]
 * @param[in] num_columns Number of columns
 *
 **/
// blockDim {1024,1,1}
extern "C" __global__ void __launch_bounds__(1024)
gpuCompactChunkDictionaries(StripeDictionary *stripes, DictionaryChunk *chunks, uint32_t num_columns)
{
    __shared__ __align__(16) compact_state_s state_g;

    volatile compact_state_s * const s = &state_g;
    uint32_t chunk_id = blockIdx.x;
    uint32_t col_id = blockIdx.y;
    uint32_t stripe_id = blockIdx.z;
    uint32_t chunk_len;
    int t = threadIdx.x;
    const uint32_t *src;
    uint32_t *dst;

    if (t < sizeof(StripeDictionary) / sizeof(uint32_t))
    {
        ((volatile uint32_t *)&s->stripe)[t] = ((const uint32_t *)&stripes[stripe_id * num_columns + col_id])[t];
    }
    __syncthreads();
    if (chunk_id >= s->stripe.num_chunks || !s->stripe.dict_data)
    {
        return;
    }
    if (t < sizeof(DictionaryChunk) / sizeof(uint32_t))
    {
        ((volatile uint32_t *)&s->chunk)[t] = ((const uint32_t *)&chunks[(s->stripe.start_chunk + chunk_id) * num_columns + col_id])[t];
    }
    chunk_len = (t < chunk_id) ? chunks[(s->stripe.start_chunk + t) * num_columns + col_id].num_dict_strings : 0;
    if (chunk_id != 0)
    {
        WARP_REDUCE_SUM_32(chunk_len);
        if (!(t & 0x1f))
            s->scratch_red[t >> 5] = chunk_len;
        __syncthreads();
        if (t < 32)
        {
            chunk_len = s->scratch_red[t];
            WARP_REDUCE_SUM_32(chunk_len);
        }
    }
    if (!t)
    {
        s->stripe_data = s->stripe.dict_data + chunk_len;
    }
    __syncthreads();
    chunk_len = s->chunk.num_dict_strings;
    src = s->chunk.dict_data;
    dst = s->stripe_data;
    if (src != dst)
    {
        for (uint32_t i = 0; i < chunk_len; i += 1024)
        {
            uint32_t idx = (i + t < chunk_len) ? src[i + t] : 0;
            __syncthreads();
            if (i + t < chunk_len)
                dst[i + t] = idx;
            __syncthreads();
        }
    }
}


struct build_state_s
{
    uint32_t total_dupes;
    StripeDictionary stripe;
    volatile uint32_t scratch_red[32];
};

/**
 * @brief Eliminate duplicates in-place and generate column dictionary index
 *
 * @param[in] stripes StripeDictionary device array [stripe][column]
 * @param[in] num_columns Number of string columns
 *
 **/
// NOTE: Prone to poor utilization on small datasets due to 1 block per dictionary
// blockDim {1024,1,1}
extern "C" __global__ void __launch_bounds__(1024)
gpuBuildStripeDictionaries(StripeDictionary *stripes, uint32_t num_columns)
{
    __shared__ __align__(16) build_state_s state_g;

    volatile build_state_s * const s = &state_g;
    uint32_t col_id = blockIdx.x;
    uint32_t stripe_id = blockIdx.y;
    uint32_t num_strings;
    uint32_t *dict_data, *dict_index;
    uint32_t dict_char_count;
    const nvstrdesc_s *str_data;
    int t = threadIdx.x;

    if (t < sizeof(StripeDictionary) / sizeof(uint32_t))
    {
        ((volatile uint32_t *)&s->stripe)[t] = ((const uint32_t *)&stripes[stripe_id * num_columns + col_id])[t];
    }
    if (t == 31 * 32)
    {
        s->total_dupes = 0;
    }
    __syncthreads();
    num_strings = s->stripe.num_strings;
    dict_data = s->stripe.dict_data;
    if (!dict_data)
        return;
    dict_index = s->stripe.dict_index;
    str_data = reinterpret_cast<const nvstrdesc_s *>(s->stripe.column_data_base);
    dict_char_count = 0;
    for (uint32_t i = 0; i < num_strings; i += 1024)
    {
        uint32_t cur = (i + t < num_strings) ? dict_data[i + t] : 0;
        uint32_t dupe_mask, dupes_before, cur_len = 0;
        const char *cur_ptr;
        bool is_dupe = false;
        if (i + t < num_strings)
        {
            cur_ptr = str_data[cur].ptr;
            cur_len = str_data[cur].count;
        }
        if (i + t != 0 && i + t < num_strings)
        {
            uint32_t prev = dict_data[i + t - 1];
            is_dupe = nvstr_is_equal(cur_ptr, cur_len, str_data[prev].ptr, str_data[prev].count);
        }
        dict_char_count += (is_dupe) ? 0 : cur_len;
        dupe_mask = BALLOT(is_dupe);
        dupes_before = s->total_dupes + __popc(dupe_mask & ((2 << (t & 0x1f)) - 1));
        if (!(t & 0x1f))
        {
            s->scratch_red[t >> 5] = __popc(dupe_mask);
        }
        __syncthreads();
        if (t < 32)
        {
            uint32_t warp_dupes = s->scratch_red[t];
            uint32_t warp_pos = warp_dupes, tmp;
            WARP_REDUCE_POS_32(warp_pos, tmp, t);
            if (t == 0x1f)
            {
                s->total_dupes += warp_pos;
            }
            s->scratch_red[t] = warp_pos - warp_dupes;
        }
        __syncthreads();
        if (i + t < num_strings)
        {
            dupes_before += s->scratch_red[t >> 5];
            dict_index[cur] = i + t - dupes_before;
            if (!is_dupe && dupes_before != 0)
            {
                dict_data[i + t - dupes_before] = cur;
            }
        }
        __syncthreads();
    }
    WARP_REDUCE_SUM_32(dict_char_count);
    if (!(t & 0x1f))
    {
        s->scratch_red[t >> 5] = dict_char_count;
    }
    __syncthreads();
    if (t < 32)
    {
        dict_char_count = s->scratch_red[t];
        WARP_REDUCE_SUM_32(dict_char_count);
    }
    if (t == 0)
    {
        stripes[stripe_id * num_columns + col_id].num_strings = num_strings - s->total_dupes;
        stripes[stripe_id * num_columns + col_id].dict_char_count = dict_char_count;
    }
}


/**
 * @brief Launches kernel for initializing dictionary chunks
 *
 * @param[in] chunks DictionaryChunk device array [rowgroup][column]
 * @param[in] num_columns Number of columns
 * @param[in] num_rowgroups Number of row groups
 * @param[in] stream CUDA stream to use, default 0
 *
 * @return cudaSuccess if successful, a CUDA error code otherwise
 **/
cudaError_t InitDictionaryIndices(DictionaryChunk *chunks, uint32_t num_columns, uint32_t num_rowgroups, cudaStream_t stream)
{
    dim3 dim_block(512, 1); // 512 threads per chunk
    dim3 dim_grid(num_columns, num_rowgroups);
    gpuInitDictionaryIndices <<< dim_grid, dim_block, 0, stream >>>(chunks, num_columns);
    return cudaSuccess;
}


/**
 * @brief Launches kernel for building stripe dictionaries
 *
 * @param[in] stripes StripeDictionary device array [stripe][column]
 * @param[in] stripes_host StripeDictionary host array [stripe][column]
 * @param[in] chunks DictionaryChunk device array [rowgroup][column]
 * @param[in] num_stripes Number of stripes
 * @param[in] num_rowgroups Number of row groups
 * @param[in] num_columns Number of columns
 * @param[in] max_chunks_in_stripe Maximum number of rowgroups per stripe
 * @param[in] stream CUDA stream to use, default 0
 *
 * @return cudaSuccess if successful, a CUDA error code otherwise
 **/
cudaError_t BuildStripeDictionaries(StripeDictionary *stripes, StripeDictionary *stripes_host, DictionaryChunk *chunks,
                                    uint32_t num_stripes, uint32_t num_rowgroups, uint32_t num_columns, uint32_t max_chunks_in_stripe, cudaStream_t stream)
{
    dim3 dim_block(1024, 1); // 1024 threads per chunk
    dim3 dim_grid_compact(max_chunks_in_stripe, num_columns, num_stripes);
    dim3 dim_grid_build(num_columns, num_stripes);
    gpuCompactChunkDictionaries <<< dim_grid_compact, dim_block, 0, stream >>>(stripes, chunks, num_columns);
    for (uint32_t i = 0; i < num_stripes * num_columns; i++)
    {
        if (stripes_host[i].dict_data != nullptr)
        {
            thrust::device_ptr<uint32_t> p = thrust::device_pointer_cast(stripes_host[i].dict_data);
            const nvstrdesc_s *str_data = reinterpret_cast<const nvstrdesc_s *>(stripes_host[i].column_data_base);
            // NOTE: Requires the --expt-extended-lambda nvcc flag
            thrust::sort(rmm::exec_policy(stream)->on(stream), p, p + stripes_host[i].num_strings,
                [str_data] __device__(const uint32_t &lhs, const uint32_t &rhs) {
                return nvstr_is_lesser(str_data[lhs].ptr, (uint32_t)str_data[lhs].count, str_data[rhs].ptr, (uint32_t)str_data[rhs].count);
            });
        }
    }
    gpuBuildStripeDictionaries <<< dim_grid_build, dim_block, 0, stream >>>(stripes, num_columns);
    return cudaSuccess;
}


} // namespace gpu
} // namespace orc
} // namespace io
} // namespace cudf
