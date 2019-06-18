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

#ifndef CUDF_REDUCTION_DISPATCHER_CUH
#define CUDF_REDUCTION_DISPATCHER_CUH

#include "reduction_functions.cuh"

//namespace { // anonymous namespace



template<typename T_in, typename T_out, typename Op, bool has_nulls>
void ReduceOp(const gdf_column *input,
                   gdf_scalar* scalar, cudaStream_t stream)
{
    T_out identity = Op::Op::template identity<T_out>();

    // allocate temporary memory for the result
    void *result = NULL;
    RMM_TRY(RMM_ALLOC(&result, sizeof(T_out), stream));

    // initialize output by identity value
    CUDA_TRY(cudaMemcpyAsync(result, &identity,
            sizeof(T_out), cudaMemcpyHostToDevice, stream));
    CHECK_STREAM(stream);

    if( std::is_same<Op, cudf::reductions::ReductionSumOfSquares>::value ){
        auto it_raw = cudf::make_iterator<has_nulls, T_in, T_out>(*input, identity);
        auto it = thrust::make_transform_iterator(it_raw, cudf::transformer_squared<T_out>{});
        reduction_op(static_cast<T_out*>(result), it, input->size, identity,
            typename Op::Op{}, stream);
    }else{
        auto it = cudf::make_iterator<has_nulls, T_in, T_out>(*input, identity);
        reduction_op(static_cast<T_out*>(result), it, input->size, identity,
            typename Op::Op{}, stream);
    }

    // read back the result to host memory
    // TODO: asynchronous copy
    CUDA_TRY(cudaMemcpy(&scalar->data, result,
            sizeof(T_out), cudaMemcpyDeviceToHost));

    // cleanup temporary memory
    RMM_TRY(RMM_FREE(result, stream));

    // set scalar is valid
    scalar->is_valid = true;
};


template <typename T_in, typename Op>
struct ReduceOutputDispatcher {
private:
    template <typename T_out>
    static constexpr bool is_convertible_v()
    {
        return  std::is_convertible<T_in, T_out>::value ||
        ( std::is_arithmetic<T_in >::value && std::is_same<T_out, cudf::bool8>::value ) ||
        ( std::is_arithmetic<T_out>::value && std::is_same<T_in , cudf::bool8>::value );
    }

public:
    template <typename T_out, typename std::enable_if<
        is_convertible_v<T_out>() >::type* = nullptr>
    void operator()(const gdf_column *col,
                         gdf_scalar* scalar, cudaStream_t stream)
    {
        if( col->valid == nullptr ){
            ReduceOp<T_in, T_out, Op, false>(col, scalar, stream);
        }else{
            ReduceOp<T_in, T_out, Op, true >(col, scalar, stream);
        }
    }

    template <typename T_out, typename std::enable_if<
        not is_convertible_v<T_out>() >::type* = nullptr >
    void operator()(const gdf_column *col,
                         gdf_scalar* scalar, cudaStream_t stream)
    {
        CUDF_FAIL("input data type is not convertible to output data type");
    }
};

template <typename Op>
struct ReduceDispatcher {
private:
    // return true if T is arithmetic type or
    // Op is DeviceMin or DeviceMax for wrapper (non-arithmetic) types
    template <typename T>
    static constexpr bool is_supported()
    {
        return std::is_arithmetic<T>::value ||
               std::is_same<T, cudf::bool8>::value ||
               std::is_same<Op, cudf::reductions::ReductionMin>::value ||
               std::is_same<Op, cudf::reductions::ReductionMax>::value ;
    }

public:
    template <typename T, typename std::enable_if<
        is_supported<T>()>::type* = nullptr>
    void operator()(const gdf_column *col,
                         gdf_scalar* scalar, cudaStream_t stream=0)
    {
        cudf::type_dispatcher(scalar->dtype,
            ReduceOutputDispatcher<T, Op>(), col, scalar, stream);
    }

    template <typename T, typename std::enable_if<
        not is_supported<T>()>::type* = nullptr>
    void operator()(const gdf_column *col,
                         gdf_scalar* scalar, cudaStream_t stream=0)
    {
        CUDF_FAIL("Reduction operators other than `min` and `max`"
                  " are not supported for non-arithmetic types");
    }
};


//}

#endif