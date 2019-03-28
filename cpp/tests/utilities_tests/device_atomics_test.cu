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

#include <tests/utilities/column_wrapper.cuh>
#include <tests/utilities/cudf_test_fixtures.h>
#include <utilities/wrapper_types.hpp>
#include <utilities/device_atomics.cuh>

#include <gmock/gmock.h>
#include <gtest/gtest.h>

#include <thrust/device_vector.h>
#include <thrust/transform.h>

#include <bitset>
#include <cstdint>
#include <random>

template<typename T>
__global__
void gpu_atomic_test(T *result, T *data, size_t size)
{
    size_t id   = blockIdx.x * blockDim.x + threadIdx.x;
    size_t step = blockDim.x * gridDim.x;

    for (; id < size; id += step) {
        atomicAdd(&result[0], data[id]);
        atomicMin(&result[1], data[id]);
        atomicMax(&result[2], data[id]);
        atomicAdd(&result[3], data[id]);
    }
}

template<typename T, typename BinaryOp>
__device__
T atomic_op(T* addr, T const & value, BinaryOp op)
{
    T old_value = *addr;
    T assumed;

    do {
        assumed  = old_value;
        const T new_value = op(old_value, value);

        old_value = atomicCAS(addr, assumed, new_value);
    } while (assumed != old_value);

    return old_value;
}

template<typename T>
__global__
void gpu_atomicCAS_test(T *result, T *data, size_t size)
{
    size_t id   = blockIdx.x * blockDim.x + threadIdx.x;
    size_t step = blockDim.x * gridDim.x;

    for (; id < size; id += step) {
        atomic_op(&result[0], data[id], cudf::DeviceSum{});
        atomic_op(&result[1], data[id], cudf::DeviceMin{});
        atomic_op(&result[2], data[id], cudf::DeviceMax{});
        atomic_op(&result[3], data[id], cudf::DeviceSum{});
    }
}

// TODO: remove these explicit instantiation for kernels
// At TYPED_TEST, the kernel for TypeParam of `wrapper` types won't be instantiated
// because `TypeParam` is a private member of class ::testing::Test
// then kenrel call failed by `cudaErrorInvalidDeviceFunction`

template  __global__ void gpu_atomic_test<cudf::date32>(cudf::date32 *result, cudf::date32 *data, size_t size);
template  __global__ void gpu_atomic_test<cudf::date64>(cudf::date64 *result, cudf::date64 *data, size_t size);
template  __global__ void gpu_atomic_test<cudf::category>(cudf::category *result, cudf::category *data, size_t size);
template  __global__ void gpu_atomic_test<cudf::timestamp>(cudf::timestamp *result, cudf::timestamp *data, size_t size);

template  __global__ void gpu_atomicCAS_test<cudf::date32>(cudf::date32 *result, cudf::date32 *data, size_t size);
template  __global__ void gpu_atomicCAS_test<cudf::date64>(cudf::date64 *result, cudf::date64 *data, size_t size);
template  __global__ void gpu_atomicCAS_test<cudf::category>(cudf::category *result, cudf::category *data, size_t size);
template  __global__ void gpu_atomicCAS_test<cudf::timestamp>(cudf::timestamp *result, cudf::timestamp *data, size_t size);

// ---------------------------------------------

template <typename T>
struct AtomicsTest : public GdfTest {

    void atomic_test(bool call_atomicCAS)
    {
        std::vector<int> v({6, -14, 13, 64, -13, -20, 45});
        int exact[3];
        exact[0] = std::accumulate(v.begin(), v.end(), 0);
        exact[1] = *( std::min_element(v.begin(), v.end()) );
        exact[2] = *( std::max_element(v.begin(), v.end()) );
        size_t vec_size = v.size();

        // std::vector<T> v_type({6, -14, 13, 64, -13, -20, 45}));
        // use transform from std::vector<int> instead.
        std::vector<T> v_type(vec_size);
        std::transform(v.begin(), v.end(), v_type.begin(),
            [](int x) { T t(x) ; return t; } );

        std::vector<T> result_init(4);
        result_init[0] = T{0};
        result_init[1] = std::numeric_limits<T>::max();
        result_init[2] = std::numeric_limits<T>::min();
        result_init[3] = T{0};

        thrust::device_vector<T> dev_result(result_init);
        thrust::device_vector<T> dev_data(v_type);

        cudaDeviceSynchronize();
        CUDA_CHECK_LAST();

        if( call_atomicCAS ){
            gpu_atomicCAS_test<T> <<<1, vec_size>>> (
                reinterpret_cast<T*>( dev_result.data().get() ),
                reinterpret_cast<T*>( dev_data.data().get() ),
                vec_size);
        }else{
            gpu_atomic_test<T> <<<1, vec_size>>> (
                reinterpret_cast<T*>( dev_result.data().get() ),
                reinterpret_cast<T*>( dev_data.data().get() ),
                vec_size);
        }

        cudaDeviceSynchronize();
        CUDA_CHECK_LAST();

        thrust::host_vector<T> host_result(dev_result);
        cudaDeviceSynchronize();

        CUDA_CHECK_LAST();

        EXPECT_EQ(host_result[0], T(exact[0])) << "atomicAdd test failed";
        EXPECT_EQ(host_result[1], T(exact[1])) << "atomicMin test failed";
        EXPECT_EQ(host_result[2], T(exact[2])) << "atomicMax test failed";
        EXPECT_EQ(host_result[3], T(exact[0])) << "atomicAdd test(2) failed";
    }
};

using TestingTypes = ::testing::Types<
    int8_t, int16_t, int32_t, int64_t, float, double,
    cudf::date32, cudf::date64, cudf::timestamp, cudf::category
    >;

TYPED_TEST_CASE(AtomicsTest, TestingTypes);

// tests for atomicAdd/Min/Max
TYPED_TEST(AtomicsTest, atomicOps)
{
    this->atomic_test(false);
}

// tests for atomicCAS
TYPED_TEST(AtomicsTest, atomicCAS)
{
    this->atomic_test(true);
}


