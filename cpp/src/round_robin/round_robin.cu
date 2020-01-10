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
#include <thrust/execution_policy.h>
#include <thrust/for_each.h>
#include <thrust/iterator/counting_iterator.h>
#include <thrust/iterator/transform_iterator.h>
#include <thrust/tuple.h>
#include <thrust/device_vector.h>
#include <thrust/scan.h>

#include <algorithm>
#include <utility>
#include <vector>
#include <memory>
#include <type_traits>
#include <cmath> // for std::ceil()

#include <cudf/types.hpp>
#include <cudf/table/table.hpp>
#include <cudf/table/table_device_view.cuh>
#include <cudf/table/row_operators.cuh>
#include <cudf/utilities/type_dispatcher.hpp>
#include <rmm/thrust_rmm_allocator.h>
#include <cudf/utilities/bit.hpp>
#include <cudf/null_mask.hpp>
#include <cudf/copying.hpp>
#include <cudf/detail/utilities/cuda.cuh>
#include <cudf/detail/gather.cuh>

namespace cudf {
namespace experimental { 
namespace detail {

std::pair<std::unique_ptr<table>,
          std::vector<cudf::size_type>>
round_robin_partition(table_view const& input,
                      cudf::size_type num_partitions,
                      cudf::size_type start_partition = 0,
                      rmm::mr::device_memory_resource* mr = rmm::mr::get_default_resource(),
                      cudaStream_t stream = 0)
{
  std::pair<std::unique_ptr<table>, std::vector<cudf::size_type>> ret_pair =
    std::make_pair(nullptr, std::vector<cudf::size_type>(num_partitions));
  
  auto nrows = input.num_rows();

  CUDF_EXPECTS( num_partitions > 1 && num_partitions < nrows, "Incorrect number of partitions. Must be greater than 1 and less than number of rows." );
  CUDF_EXPECTS( start_partition < num_partitions, "Incorrect start_partition index. Must be less than number of partitions." );
  
  auto n_pmax = nrows % num_partitions;//# partitions of max size
  cudf::size_type max_p_size = std::ceil( static_cast<double>(nrows) / static_cast<double>(num_partitions));// max size of partitions
  
  auto pmm = n_pmax * max_p_size;
  auto dnpmax = num_partitions - n_pmax;

  //delta is the number of positions to rotate right
  //the original range [0,1,...,n-1]
  //and is calculated by accumulating the first
  //`start_partition` partition sizes from the end;
  //i.e.,
  //the partition sizes array (of size p) being:
  //[m,m,...,m,(m-1),...,(m-1)]
  //(with n_pmax sizes `m` at the beginning;
  //and (p-n_pmax) sizes `(m-1)` at the end)
  //we accumulate the 1st `start_partition` entries from the end:
  //
  auto delta = (start_partition > dnpmax?
                dnpmax*(max_p_size-1) + (start_partition - dnpmax)*max_p_size :
                start_partition*(max_p_size-1));

  
  auto iter_begin =
    thrust::make_transform_iterator(thrust::make_counting_iterator<cudf::size_type>(0),
                                    [nrows, num_partitions, max_p_size, n_pmax, pmm, delta] __device__ (auto index0){
                                      auto indx = (index0 + nrows - delta) % nrows;//rotate original index right by delta positions
                                      auto ipj = (indx <= pmm ? indx % max_p_size: (indx - pmm) % (max_p_size-1) );
                                      auto pij = (indx <= pmm ? indx / max_p_size: n_pmax + (indx - pmm) / (max_p_size-1) );
                                      return num_partitions * ipj + pij;
                                    });

  auto uniq_tbl = cudf::experimental::detail::gather(input,
                                                     iter_begin, iter_begin + nrows,
                                                     false, false, false,
                                                     mr,
                                                     stream);

  rmm::device_vector<cudf::size_type> d_partition_offsets(num_partitions, cudf::size_type{0});

  auto rotated_iter_begin =
    thrust::make_transform_iterator(thrust::make_counting_iterator<cudf::size_type>(0),
                                    //(\indx -> if (indx + np - sp) `mod` np < pmax then m else (m-1) )
                                    [num_partitions, start_partition, max_p_size, n_pmax] __device__ (auto indx){
                                      return ((indx + num_partitions - start_partition) % num_partitions < n_pmax? max_p_size : max_p_size-1);
                                    });

  auto exec = rmm::exec_policy(stream);
  thrust::exclusive_scan(exec->on(stream),
                         rotated_iter_begin, rotated_iter_begin + num_partitions,
                         d_partition_offsets.begin());

  ret_pair.first = std::move(uniq_tbl);
  cudaMemcpy(ret_pair.second.data(), d_partition_offsets.data().get(), sizeof(cudf::size_type)*num_partitions, cudaMemcpyDeviceToHost);

  return ret_pair;
}
  
}  // namespace detail

std::pair<std::unique_ptr<cudf::experimental::table>, std::vector<cudf::size_type>>
round_robin_partition(table_view const& input,
                      cudf::size_type num_partitions,
                      cudf::size_type start_partition = 0,
                      rmm::mr::device_memory_resource* mr = rmm::mr::get_default_resource()) {
  
  return cudf::experimental::detail::round_robin_partition(input, num_partitions, start_partition, mr);
}
  
}  // namespace experimental
}  // namespace cudf
