/* Copyright 2018 NVIDIA Corporation.  All rights reserved. */

/* Header-only join C++ API */

#include <limits>

#include "hash-join/inner_join.cuh"
#include "sort-join.cuh"

#define HASH_TBL_OCC    50

using namespace mgpu;

// TODO: a global typedef with the name size_type note even part of a name space is not a good idea
// TODO: change this to int64 when the join output is updated to int64
typedef int size_type;
typedef struct { size_type x, y; } joined_type;

// single-column join
template<typename launch_arg_t = empty_t,
         typename a_it, typename b_it, typename comp_t>
mem_t<size_type> inner_join_hash(a_it a, size_type a_count, b_it b, size_type b_count,
                                comp_t comp, context_t& context, bool flip_indices = false)
{
  // here follows the custom code for hash-joins
  typedef typename std::iterator_traits<a_it>::value_type key_type;

  // swap buffers if a_count > b_count to use the smaller table for build
  if (a_count > b_count)
    return inner_join_hash(b, b_count, a, a_count, comp, context, true);

  // TODO: find an estimate for the output buffer size
  // currently using 10x maximum expansion rate
  const double matching_rate = 10;
  size_type joined_size = (size_type)(b_count * matching_rate);

  // create a temp output buffer to store pairs
  joined_type *joined;
  CUDA_RT_CALL( cudaMallocManaged(&joined, sizeof(joined_type) * joined_size) );

  // allocate a counter
  size_type* joined_idx;
  CUDA_RT_CALL( cudaMallocManaged(&joined_idx, sizeof(size_type)) );
  CUDA_RT_CALL( cudaMemsetAsync(joined_idx, 0, sizeof(size_type), 0) );

  // step 1: initialize a HT for the smaller buffer A
  typedef concurrent_unordered_multimap<key_type, size_type, -1, -1> multimap_type;
  size_type hash_tbl_size = (size_type)(a_count * 100 / HASH_TBL_OCC);
  std::unique_ptr<multimap_type> hash_tbl(new multimap_type(hash_tbl_size));
  hash_tbl->prefetch(0);  // FIXME: use GPU device id from the context?

  // step 2: build the HT
  const int block_size = 128;
  build_hash_tbl<<<(a_count+block_size-1)/block_size, block_size>>>(hash_tbl.get(), a, a_count);
  CUDA_RT_CALL( cudaGetLastError() );

  // step 3: scan B, probe the HT and output the joined indices
  probe_hash_tbl<multimap_type, key_type, size_type, joined_type, 128, 128>
                 <<<(b_count+block_size-1)/block_size, block_size>>>
                  (hash_tbl.get(), b, b_count, joined, joined_idx, 0);
  CUDA_RT_CALL( cudaDeviceSynchronize() );

  // TODO: can we avoid this transformation from pairs to decoupled?
  size_type output_npairs = *joined_idx;
  mem_t<size_type> output(2 * output_npairs, context);
  if (output_npairs > 0) {
    size_type* output_data = output.data();
    auto k = [=] MGPU_DEVICE(size_type index) {
      output_data[index] = flip_indices ? joined[index].y : joined[index].x;
      output_data[index + output_npairs] = flip_indices ? joined[index].x : joined[index].y;
    };
    transform(k, output_npairs, context);
  }

  return output;
}

// two-column join
template<typename launch_arg_t = empty_t,
         typename a1_it, typename b1_it,
         typename a2_it, typename b2_it,
         typename comp_t>
mem_t<size_type> inner_join_hash(a1_it a1, a2_it a2, size_type a_count,
                                 b1_it b1, b2_it b2, size_type b_count,
                                 comp_t comp, context_t& context,
				 size_type estimated_join_count = 0, bool flip_indices = false)
{
  // here follows the custom code for hash-joins
  typedef typename std::iterator_traits<a1_it>::value_type key_type1;
  typedef typename std::iterator_traits<a2_it>::value_type key_type2;

  // swap buffers if a_count > b_count to use the smaller table for build
  if (a_count > b_count)
    return inner_join_hash(b1, b2, b_count, a1, a2, a_count, comp, context, true);

  // TODO: find an estimate for the output buffer size
  // currently using 10x maximum expansion rate
  const double matching_rate = 10;
  size_type joined_size = (size_type)(b_count * matching_rate);

  // create a temp output buffer to store pairs
  joined_type *joined;
  CUDA_RT_CALL( cudaMallocManaged(&joined, sizeof(joined_type) * joined_size) );

  // prefetch the estimated output size
  if (estimated_join_count > 0)
    CUDA_RT_CALL( cudaMemPrefetchAsync(joined, sizeof(joined_type) * estimated_join_count, 0) ); // FIXME: use GPU device id from the context?

  // allocate a counter
  size_type* joined_idx;
  CUDA_RT_CALL( cudaMallocManaged(&joined_idx, sizeof(size_type)) );
  CUDA_RT_CALL( cudaMemsetAsync(joined_idx, 0, sizeof(size_type), 0) );

  // step 1: initialize a HT for the smaller buffer A
  typedef concurrent_unordered_multimap<key_type1, size_type, -1, -1> multimap_type;
  size_type hash_tbl_size = (size_type)(a_count * 100 / HASH_TBL_OCC);
  std::unique_ptr<multimap_type> hash_tbl(new multimap_type(hash_tbl_size));
  hash_tbl->prefetch(0);  // FIXME: use GPU device id from the context?

  // step 2: build the HT
  const int block_size = 128;
  build_hash_tbl<<<(a_count+block_size-1)/block_size, block_size>>>(hash_tbl.get(), a1, a_count);
  CUDA_RT_CALL( cudaGetLastError() );

  // step 3: scan B, probe the HT and output the joined indices
  probe_hash_tbl<multimap_type, key_type1, key_type2, size_type, joined_type, 128, 128>
                 <<<(b_count+block_size-1)/block_size, block_size>>>
                  (hash_tbl.get(), b1, b2, b_count, a2, joined, joined_idx, 0);
  CUDA_RT_CALL( cudaDeviceSynchronize() );

  // TODO: can we avoid this transformation from pairs to decoupled?
  size_type output_npairs = *joined_idx;
  mem_t<size_type> output(2 * output_npairs, context);
  if (output_npairs > 0) {
    size_type* output_data = output.data();
    auto k = [=] MGPU_DEVICE(size_type index) {
      output_data[index] = flip_indices ? joined[index].y : joined[index].x;
      output_data[index + output_npairs] = flip_indices ? joined[index].x : joined[index].y;
    };
    transform(k, output_npairs, context);
  }

  return output;
}

struct join_result_base {
  virtual ~join_result_base() {}
  virtual void* data() = 0;
  virtual size_t size() = 0;
};

template <typename T>
struct join_result : public join_result_base {
  standard_context_t context;
  mem_t<T> result;

  join_result() : context(false) {}
  virtual void* data() {
    return result.data();
  }
  virtual size_t size() {
    return result.size();
  }
};
