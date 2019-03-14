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

/** ---------------------------------------------------------------------------*
 * @brief overloads for CUDA atomic operations
 * @file device_atomics.cuh
 *
 * Provides the overloads for all of possible cudf's data types:
 * int8_t, int16_t, int32_t, int64_t, float, double, cudf::date32, cudf::date64,
 * cudf::timestamp, cudf::category
 *
 * @note atomicCAS never provides overloads for int8_t, int16_t
 * ---------------------------------------------------------------------------**/


#include "cudf.h"
#include "utilities/cudf_utils.h"
#include "utilities/wrapper_types.hpp"
#include "utilities/error_utils.hpp"



namespace cudf {

namespace detail {

    template <typename T_output, typename T_input>
    __forceinline__  __device__
    T_output type_reinterpret(T_input value)
    {
        return *( reinterpret_cast<T_output*>(&value) );
    }

    // the implementation of `genericAtomicOperation`
    template <typename T, typename Op, size_t n>
    struct genericAtomicOperationImpl;

    // single byte atomic operation
    template<typename T, typename Op>
    struct genericAtomicOperationImpl<T, Op, 1> {
        __forceinline__  __device__
        T operator()(T* addr, T const & update_value, Op op)
        {
            using T_int = unsigned int;

            T_int * address_uint32 = reinterpret_cast<T_int *>
                (addr - ((size_t)addr & 3));
            unsigned int shift = (((size_t)addr & 3) * 8);

            T_int old = *address_uint32;
            T_int assumed ;

            do {
                assumed = old;
                T target_value = T((old >> shift) & 0xff);
                T new_value = op(update_value, target_value);

                old = (old & ~(0x000000ff << shift)) | (new_value << shift);
                old = atomicCAS(address_uint32, assumed, old);
            } while (assumed != old);

            return T((old >> shift) & 0xff);
        }
    };

    // 2 bytes atomic operation
    template<typename T, typename Op>
    struct genericAtomicOperationImpl<T, Op, 2> {
        __forceinline__  __device__
        T operator()(T* addr, T const & update_value, Op op)
        {
            using T_int = unsigned int;

            T_int * address_uint32 = reinterpret_cast<T_int *>
                (addr - ((size_t)addr & 2));
            bool is_32_align = (reinterpret_cast<size_t>(addr) & 2) ? true : false;

            T_int old = *address_uint32;
            T_int assumed ;

            do {
                assumed = old;
                T target_value = (is_32_align) ? T(old >> 16) : T(old & 0xffff);
                T new_value = op(update_value, target_value);

                old = (is_32_align) ? (old & 0xffff) | (new_value << 16)
                                    : (old & 0xffff0000) | new_value;
                old = atomicCAS(address_uint32, assumed, old);
            } while (assumed != old);

            return (is_32_align) ? T(old >> 16) : T(old & 0xffff);
        }
    };

    // 4 bytes atomic operation
    template<typename T, typename Op>
    struct genericAtomicOperationImpl<T, Op, 4> {
        __forceinline__  __device__
        T operator()(T* addr, T const & update_value, Op op)
        {
            using T_int = unsigned int;

            T old_value = *addr;
            T assumed {old_value};

            do {
                assumed  = old_value;
                const T new_value = op(update_value, old_value);

                T_int ret = atomicCAS(
                    reinterpret_cast<T_int*>(addr),
                    type_reinterpret<T_int, T>(assumed),
                    type_reinterpret<T_int, T>(new_value));
                old_value = type_reinterpret<T, T_int>(ret);

            } while (assumed != old_value);

            return old_value;
        }
    };

    // 8 bytes atomic operation
    template<typename T, typename Op>
    struct genericAtomicOperationImpl<T, Op, 8> {
        __forceinline__  __device__
        T operator()(T* addr, T const & update_value, Op op)
        {
            using T_int = unsigned long long int;

            T old_value = *addr;
            T assumed {old_value};

            do {
                assumed  = old_value;
                const T new_value = op(update_value, old_value);

                T_int ret = atomicCAS(
                    reinterpret_cast<T_int*>(addr),
                    type_reinterpret<T_int, T>(assumed),
                    type_reinterpret<T_int, T>(new_value));
                old_value = type_reinterpret<T, T_int>(ret);

            } while (assumed != old_value);

            return old_value;
        }
    };

} // namespace detail


template <typename T, typename BinaryOp>
__forceinline__  __device__
T genericAtomicOperation(T* address, T const & update_value, BinaryOp op)
{
    return cudf::detail::genericAtomicOperationImpl<T, BinaryOp, sizeof(T)>()
        (address, update_value, op);
}

// call atomic function with type cast between same precision
template <typename T, typename Functor>
__forceinline__  __device__
T typesAtomicOperation32(T* addr, T val, Functor atomicFunc)
{
    using T_int = int;
    T_int ret = atomicFunc(reinterpret_cast<T_int*>(addr),
        cudf::detail::type_reinterpret<T_int, T>(val));

    return cudf::detail::type_reinterpret<T, T_int>(ret);
}


template <typename T, typename Functor>
__forceinline__  __device__
T typesAtomicOperation64(T* addr, T val, Functor atomicFunc)
{
    using T_int = long long int;
    T_int ret = atomicFunc(reinterpret_cast<T_int*>(addr),
        cudf::detail::type_reinterpret<T_int, T>(val));

    return cudf::detail::type_reinterpret<T, T_int>(ret);
}

// ------------------------------------------------------------------------
// Binary ops for sum,
struct DeviceSum {
    template<typename T>
    __device__
    T operator() (const T &lhs, const T &rhs) {
        return lhs + rhs;
    }

    template<typename T>
    static constexpr T identity() { return T{0}; }
};

struct DeviceMin{
    template<typename T>
    __device__
    T operator() (const T &lhs, const T &rhs) {
        return lhs <= rhs? lhs: rhs;
    }

    template<typename T>
    static constexpr T identity() { return std::numeric_limits<T>::max(); }
};

struct DeviceMax{
    template<typename T>
    __device__
    T operator() (const T &lhs, const T &rhs) {
        return lhs >= rhs? lhs: rhs;
    }

    template<typename T>
    static constexpr T identity() { return std::numeric_limits<T>::lowest(); }
};

} // namespace cudf

// ------------------------------------------------------------------------
// ------------------------------------------------------------------------
// Overloads for `atomicAdd`

__forceinline__ __device__
uint8_t atomicAdd(int8_t* address, int8_t val)
{
    return cudf::genericAtomicOperation(address, val, cudf::DeviceSum{});
}

__forceinline__ __device__
uint16_t atomicAdd(int16_t* address, int16_t val)
{
    return cudf::genericAtomicOperation(address, val, cudf::DeviceSum{});
}

__forceinline__ __device__
int64_t atomicAdd(int64_t* address, int64_t val)
{
    // `atomicAdd` supports uint64_t, but not int64_t
    return cudf::genericAtomicOperation(address, val, cudf::DeviceSum{});
}

// for wrappers
inline  __device__
cudf::date32 atomicAdd(cudf::date32* address, cudf::date32 val)
{
    using T = int;
    return cudf::typesAtomicOperation32
        (address, val, [](T* a, T v){return atomicAdd(a, v);});
}

__forceinline__ __device__
cudf::category atomicAdd(cudf::category* address, cudf::category val)
{
    using T = int;
    return cudf::typesAtomicOperation32
        (address, val, [](T* a, T v){return atomicAdd(a, v);});
}

__forceinline__ __device__
cudf::date64 atomicAdd(cudf::date64* address, cudf::date64 val)
{
    return cudf::genericAtomicOperation(address, val, cudf::DeviceSum{});
}

__forceinline__ __device__
cudf::timestamp atomicAdd(cudf::timestamp* address, cudf::timestamp val)
{
    return cudf::genericAtomicOperation(address, val, cudf::DeviceSum{});
}



