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

//Quantile (percentile) functionality

#include "quantiles.hpp"
#include "utilities/cudf_utils.h"
#include "utilities/error_utils.hpp"
#include "utilities/type_dispatcher.hpp"
#include "utilities/wrapper_types.hpp"
#include "rmm/thrust_rmm_allocator.h"
#include "cudf.h"

#include <thrust/device_vector.h>
#include <thrust/copy.h>


namespace{ // anonymouys namespace

  struct QuantiledIndex {
    gdf_size_type lower_bound;
    gdf_size_type upper_bound;
    gdf_size_type nearest;
    double fraction;
  };

  QuantiledIndex find_quantile_index(gdf_size_type length, double quant)
  {
    // clamp quant value.
    // Todo: use std::clamp if c++17 is supported.
    quant = std::min(std::max(quant, 0.0), 1.0);

    // since gdf_size_type is int32_t, there is no underflow/overflow
    double val = quant*(length -1);
    QuantiledIndex qi;
    qi.lower_bound = std::floor(val);
    qi.upper_bound = static_cast<size_t>(std::ceil(val));
    qi.nearest = static_cast<size_t>(std::nearbyint(val));
    qi.fraction = val - qi.lower_bound;

    return qi;
  }

  template<typename T>
  void singleMemcpy(T& res, T* input, cudaStream_t stream = NULL)
  {
    (void)stream;
    //TODO: async with streams?
    CUDA_TRY( cudaMemcpy(&res, input, sizeof(T), cudaMemcpyDeviceToHost) );
  }

  template<typename T, typename RetT>
  gdf_error select_quantile(T* dv,
                          gdf_size_type n,
                          double quant, 
                          gdf_quantile_method interpolation,
                          RetT& result,
                          bool flag_sorted = false,
                          cudaStream_t stream = NULL)
  {
    std::vector<T> hv(2);

    if( n < 2 )
    {
      singleMemcpy(hv[0], dv, stream);
      result = static_cast<RetT>( hv[0] );
      return GDF_SUCCESS;
    }

    if( quant >= 1.0 && !flag_sorted )
    {
      T* d_res = thrust::max_element(rmm::exec_policy(stream)->on(stream), dv, dv+n);
      singleMemcpy(hv[0], d_res, stream);
      result = static_cast<RetT>( hv[0] );
      return GDF_SUCCESS;
    }

    if( quant <= 0.0 && !flag_sorted )
    {
      T* d_res = thrust::min_element(rmm::exec_policy(stream)->on(stream), dv, dv+n);
      singleMemcpy(hv[0], d_res, stream);
      result = static_cast<RetT>( hv[0] );
      return GDF_SUCCESS;
    }

    // sort if the input is not sorted.
    if( !flag_sorted ){
      thrust::sort(rmm::exec_policy(stream)->on(stream), dv, dv+n);
    }

    QuantiledIndex qi = find_quantile_index(n, quant);

    switch( interpolation )
    {
    case GDF_QUANT_LINEAR:
      singleMemcpy(hv[0], dv+qi.lower_bound, stream);
      singleMemcpy(hv[1], dv+qi.upper_bound, stream);
      cudf::interpolate::linear(
          cudf::detail::unwrap(result), 
          cudf::detail::unwrap(hv[0]), 
          cudf::detail::unwrap(hv[1]), qi.fraction);
      break;
    case GDF_QUANT_MIDPOINT:
      singleMemcpy(hv[0], dv+qi.lower_bound, stream);
      singleMemcpy(hv[1], dv+qi.upper_bound, stream);
      cudf::interpolate::midpoint(
          cudf::detail::unwrap(result), 
          cudf::detail::unwrap(hv[0]), 
          cudf::detail::unwrap(hv[1]));
      break;
    case GDF_QUANT_LOWER:
      singleMemcpy(hv[0], dv+qi.lower_bound, stream);
      result = static_cast<RetT>( hv[0] );
      break;
    case GDF_QUANT_HIGHER:
      singleMemcpy(hv[0], dv+qi.upper_bound, stream);
      result = static_cast<RetT>( hv[0] );
      break;
    case GDF_QUANT_NEAREST:
      singleMemcpy(hv[0], dv+qi.nearest, stream);
      result = static_cast<RetT>( hv[0] );
      break;

    default:
      return GDF_UNSUPPORTED_METHOD;
    }
    
    return GDF_SUCCESS;
  }

  template<typename ColType,
           typename RetT = double>
  gdf_error trampoline_exact(gdf_column*  col_in,
                             gdf_quantile_method interpolation,
                             double quant,
                             void* t_erased_res,
                             gdf_context* ctxt,
                             cudaStream_t stream = NULL)
  {
    RetT* ptr_res = static_cast<RetT*>(t_erased_res);
    size_t n = col_in->size;
    ColType* p_dv = static_cast<ColType*>(col_in->data);
    
    if( ctxt->flag_sort_inplace || ctxt->flag_sorted)
      {
        return select_quantile(p_dv,
                               n,
                               quant, 
                               interpolation,
                               *ptr_res,
                               ctxt->flag_sorted, stream);
      }
    else
      {
        rmm::device_vector<ColType> dv(n);
        thrust::copy_n(rmm::exec_policy(stream)->on(stream), p_dv, n, dv.begin());
        p_dv = dv.data().get();

        return select_quantile(p_dv,
                               n,
                               quant, 
                               interpolation,
                               *ptr_res,
                               ctxt->flag_sorted, stream);
      }
  }
    
  struct trampoline_exact_functor{
    template <typename T,
              typename std::enable_if_t<!std::is_arithmetic<T>::value, int> = 0>
    gdf_error operator()(gdf_column* col_in,
                         gdf_quantile_method interpolation,
                         double              quant,
                         void*               t_erased_res,
                         gdf_context*        ctxt,
                         cudaStream_t        stream = NULL)
    {
      return GDF_UNSUPPORTED_DTYPE;
    }

    template <typename T,
              typename std::enable_if_t<std::is_arithmetic<T>::value, int> = 0>
    gdf_error operator()(gdf_column*  col_in,
                         gdf_quantile_method interpolation,
                         double              quant,
                         void*               t_erased_res,
                         gdf_context*        ctxt,
                         cudaStream_t        stream = NULL)
    {
      // just in case double won't be enough to hold result
      // it can be changed in future
      return trampoline_exact<T, double>
                 (col_in, interpolation, quant, t_erased_res, ctxt, stream);
    }
  };

  struct trampoline_approx_functor{
    template <typename T>
    gdf_error operator()(gdf_column*  col_in, 
                    double       quant,
                    void*        t_erased_res,
                    gdf_context* ctxt,
                    cudaStream_t stream = NULL)
    {
      return trampoline_exact<T, T>(col_in, GDF_QUANT_LOWER, quant, t_erased_res, ctxt, stream);
    }
  };

} // end of anonymouys namespace

gdf_error gdf_quantile_exact( gdf_column*         col_in,       // input column
                              gdf_quantile_method prec,         // interpolation method
                              double              q,            // requested quantile in [0,1]
                              gdf_scalar*         result,       // the result
                              gdf_context*        ctxt)         // context info
{
  GDF_REQUIRE(nullptr != col_in, GDF_DATASET_EMPTY);
  GDF_REQUIRE(nullptr != col_in->data, GDF_DATASET_EMPTY);
  GDF_REQUIRE(0 < col_in->size, GDF_DATASET_EMPTY);
  GDF_REQUIRE(nullptr == col_in->valid || 0 == col_in->null_count, GDF_VALIDITY_UNSUPPORTED);

  gdf_error ret = GDF_SUCCESS;
  result->dtype = GDF_FLOAT64;
  result->is_valid = false; // the scalar is not valid for error case

  ret = cudf::type_dispatcher(col_in->dtype,
                              trampoline_exact_functor{},
                              col_in, prec, q, &result->data, ctxt);

  if( ret == GDF_SUCCESS ) result->is_valid = true;
  return ret;
}

gdf_error gdf_quantile_approx(	gdf_column*  col_in,       // input column
                                double       q,            // requested quantile in [0,1]
                                gdf_scalar*  result,       // the result
                                gdf_context* ctxt)         // context info
{
  GDF_REQUIRE(nullptr != col_in, GDF_DATASET_EMPTY);
  GDF_REQUIRE(nullptr != col_in->data, GDF_DATASET_EMPTY);
  GDF_REQUIRE(0 < col_in->size, GDF_DATASET_EMPTY);
  GDF_REQUIRE(nullptr == col_in->valid || 0 == col_in->null_count, GDF_VALIDITY_UNSUPPORTED);

  gdf_error ret = GDF_SUCCESS;
  result->dtype = col_in->dtype;
  result->is_valid = false; // the scalar is not valid for error case

  ret = cudf::type_dispatcher(col_in->dtype,
                              trampoline_approx_functor{},
                              col_in, q, &result->data, ctxt);
  
  if( ret == GDF_SUCCESS ) result->is_valid = true;
  return ret;
}

