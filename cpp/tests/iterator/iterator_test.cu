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

/* Proof the concept of iterator driven aggregations to reuse the logic

   The concepts:
   1. computes the aggregation by given iterators
   2. computes by using cub and thrust with same function parameters
   3. accepts nulls and group_by with same function parameters

    CUB reduction:  https://nvlabs.github.io/cub/structcub_1_1_device_reduce.html#aa4adabeb841b852a7a5ecf4f99a2daeb
    Thrust reduction: https://thrust.github.io/doc/group__reductions.html#ga43eea9a000f912716189687306884fc7

    Thrust iterators: https://thrust.github.io/doc/group__fancyiterator.html
*/

#include <gmock/gmock.h>
#include <gtest/gtest.h>

#include <bitset>
#include <cstdint>
#include <iostream>
#include <numeric>
#include <iterator>
#include <type_traits>

#include <bitmask/bit_mask.cuh>         // need for bitmask
#include <utilities/cudf_utils.h>       // need for CUDA_HOST_DEVICE_CALLABLE
#include <utilities/device_atomics.cuh> // need for device operators.

#include <reduction.hpp>

#include <tests/utilities/cudf_test_fixtures.h>
#include <tests/utilities/column_wrapper.cuh>
#include <tests/utilities/scalar_wrapper.cuh>

#include <cub/device/device_reduce.cuh>
#include <thrust/device_vector.h>
#include <thrust/transform.h>

#include <thrust/tuple.h>
#include <thrust/iterator/zip_iterator.h>
#include <thrust/iterator/constant_iterator.h>
#include <thrust/iterator/counting_iterator.h>
#include <thrust/iterator/transform_iterator.h>
#include <thrust/iterator/iterator_adaptor.h>


// --------------------------------------------------------------------------------------------------------
// structs of output for column_input_iterator

template<typename T>
struct ColumnOutputSingle
{
    T value;

    template<typename T_input>
    __device__ __host__
    ColumnOutputSingle(T_input _value, bool is_valid=false)
    : value( static_cast<T>(_value) )
    {};

    __device__ __host__
    ColumnOutputSingle(){};

    __device__ __host__
    operator T() const { return value; }
};

template<typename T>
struct ColumnOutputSquared
{
    T value_squared;

    template<typename T_input>
    __device__ __host__
    ColumnOutputSquared(T_input _value, bool is_valid=false)
    {
        T v = static_cast<T>(_value);
        value_squared = v*v;
    };

    __device__ __host__
    ColumnOutputSquared(){};

    __device__ __host__
    operator T() const { return value_squared; }
};

template<typename T, bool update_count=true>
struct ColumnOutputMixed;


template<typename T>
struct ColumnOutputMixed<T, true>
{
    T value;
    T value_squared;
    gdf_index_type count;

    template<typename T_input>
    __device__ __host__
    ColumnOutputMixed(T_input _value, bool is_valid)
    : value( static_cast<T>(_value) ), count(is_valid? 1 : 0)
    {
        value_squared = value*value;
    };

    __device__ __host__
    ColumnOutputMixed(T _value, T _value_squared=0, gdf_index_type _count=0)
    : value(_value), value_squared(_value_squared), count(_count)
    {};


    __device__ __host__
    ColumnOutputMixed()
    : value(0), value_squared(0), count(0)
    {};

    using this_t = ColumnOutputMixed<T, true>;

    __device__ __host__
    this_t operator+(this_t const &rhs) const
    {
        return this_t(
            (this->value + rhs.value),
            (this->value_squared + rhs.value_squared),
            (this->count + rhs.count)
        );
    }

    __device__ __host__
    bool operator==(this_t const &rhs) const
    {
        return (
            (this->value == rhs.value) &&
            (this->value_squared == rhs.value_squared) &&
            (this->count == rhs.count)
        );
    }
};

template<typename T>
struct ColumnOutputMixed<T, false>
{
    T value;
    T value_squared;
    gdf_index_type count;

    template<typename T_input>
    __device__ __host__
    ColumnOutputMixed(T_input _value, bool is_valid)
    : value( static_cast<T>(_value) )
    {
        value_squared = value*value;
    };

    __device__ __host__
    ColumnOutputMixed(T _value, T _value_squared=0, gdf_index_type _count=0)
    : value(_value), value_squared(_value_squared), count(_count)
    {};

    __device__ __host__
    ColumnOutputMixed()
    : value(0), value_squared(0), count(0)
    {};

    using this_t = ColumnOutputMixed<T, false>;

    __device__ __host__
    this_t operator+(this_t const &rhs) const
    {
        return this_t(
            (this->value + rhs.value),
            (this->value_squared + rhs.value_squared),
            (this->count)
        );
    }

    __device__ __host__
    bool operator==(this_t const &rhs) const
    {
        return (
            (this->value == rhs.value) &&
            (this->value_squared == rhs.value_squared)
        );
    }
};


template<typename T, bool update_count=true>
std::ostream& operator<<(std::ostream& os, ColumnOutputMixed<T, update_count> const& rhs)
{
  return os << "[" << rhs.value <<
      ", " << rhs.value_squared <<
      ", " << rhs.count << "] ";
};

// --------------------------------------------------------------------------------------------------------
// structs for column_input_iterator
template<typename T_output, typename T_element, bool nulls_present=true>
struct ColumnInput;

template<typename T_output, typename T_element>
struct ColumnInput<T_output, T_element, false>{
    const T_element *data;

    __device__ __host__
    ColumnInput(T_element *_data)
    : data(_data){};

    __device__ __host__
    T_output at(gdf_index_type id) const {
        return T_output(data[id], true);
    };
};

template<typename T_output, typename T_element>
struct ColumnInput<T_output, T_element, true>{
    const T_element *data;
    const bit_mask::bit_mask_t *valid;
    T_element identity;

    __device__ __host__
    ColumnInput(const T_element *_data, const bit_mask::bit_mask_t *_valid, T_element _identity)
    : data(_data), valid(_valid), identity(_identity){};

    __device__ __host__
    ColumnInput(const T_element *_data, const gdf_valid_type*_valid, T_element _identity)
    : ColumnInput(_data, reinterpret_cast<const bit_mask::bit_mask_t*>(_valid), _identity) {};

    __device__ __host__
    T_output at(gdf_index_type id) const {
        return T_output(get_value(id), is_valid(id));
    };

    __device__ __host__
    T_element get_value(gdf_index_type id) const {
        return (is_valid(id))? data[id] : identity;
    }

    __device__ __host__
    bool is_valid(gdf_index_type id) const
    {
        return bit_mask::is_valid(valid, id);
    }
};


// ---------------------------------------------------------------------------
// column_input_iterator
template<typename T_output, typename T_input, typename Iterator=thrust::counting_iterator<gdf_index_type> >
  class column_input_iterator
    : public thrust::iterator_adaptor<
        column_input_iterator<T_output, T_input, Iterator>, // the first template parameter is the name of the iterator we're creating
        Iterator,                   // the second template parameter is the name of the iterator we're adapting
        thrust::use_default, thrust::use_default, thrust::use_default,
        T_output,                   // set `super_t::reference` to `T_output`
        thrust::use_default
      >
  {
  public:
    // shorthand for the name of the iterator_adaptor we're deriving from
    using super_t = thrust::iterator_adaptor<
      column_input_iterator<T_output, T_input, Iterator>, Iterator,
      thrust::use_default, thrust::use_default, thrust::use_default, T_output, thrust::use_default
    >;

    __host__ __device__
    column_input_iterator(const T_input col, const Iterator &it) : super_t(it), colData(col){}

    __host__ __device__
    column_input_iterator(const T_input col) : super_t(Iterator{0}), colData(col){}

    __host__ __device__
    column_input_iterator(const column_input_iterator &it) : super_t(it.base()), colData(it.colData){}

    // befriend thrust::iterator_core_access to allow it access to the private interface below
    friend class thrust::iterator_core_access;

    __host__ __device__
    column_input_iterator &operator=(const column_input_iterator &other)
    {
        super_t::operator=(other);

        colData = other.colData;
        return *this;
    }

  private:
    const T_input colData;

    // it is private because only thrust::iterator_core_access needs access to it
    __host__ __device__
    typename super_t::reference dereference() const
    {
      int id = *(this->base());
      return colData.at(id);
    }
};

// ---------------------------------------------------------------------------

namespace cudf
{
    template <typename T_element, typename T_output = T_element, typename T_output_helper = ColumnOutputSingle<T_output> >
    auto make_iterator_with_nulls(const T_element *_data, const bit_mask::bit_mask_t *_valid, T_element _identity)
    {
        using T_input = ColumnInput<T_output_helper, T_element>;
        using T_iterator = column_input_iterator<T_output, T_input>;

        return T_iterator(T_input(_data, _valid, _identity));
    }

    template <typename T_element, typename T_output = T_element, typename T_output_helper = ColumnOutputSingle<T_output> >
    auto make_iterator_with_nulls(const T_element *_data, const gdf_valid_type *_valid, T_element _identity)
    {
        return make_iterator_with_nulls<T_element, T_output, T_output_helper>
            (_data, reinterpret_cast<const bit_mask::bit_mask_t*>(_valid), _identity);
    }

}

// ---------------------------------------------------------------------------
// __host__ option is required for thrust::host operation
struct HostDeviceSum {
    template<typename T>
    __device__ __host__
    T operator() (const T &lhs, const T &rhs) {
        return lhs + rhs;
    }

    template<typename T>
    static constexpr T identity() { return T{0}; }
};


template <typename T>
T random_int(T min, T max)
{
  static unsigned seed = 13377331;
  static std::mt19937 engine{seed};
  static std::uniform_int_distribution<T> uniform{min, max};

  return uniform(engine);
}

bool random_bool()
{
  static unsigned seed = 13377331;
  static std::mt19937 engine{seed};
  static std::uniform_int_distribution<int> uniform{0, 1};

  return static_cast<bool>( uniform(engine) );
}


// ---------------------------------------------------------------------------


template <typename T>
struct IteratorTest : public GdfTest
{
    // iterator test case which uses cub
    template <typename InputIterator, typename T_output>
    void iterator_test_cub(T_output expected, InputIterator d_in, int num_items)
    {
        T_output init{0};
        thrust::device_vector<T_output> dev_result(1, init);

        void     *d_temp_storage = NULL;
        size_t   temp_storage_bytes = 0;

        cub::DeviceReduce::Reduce(d_temp_storage, temp_storage_bytes, d_in, dev_result.begin(), num_items,
            HostDeviceSum{}, init);
        // Allocate temporary storage
        RMM_TRY(RMM_ALLOC(&d_temp_storage, temp_storage_bytes, 0));

        // Run reduction
        cub::DeviceReduce::Reduce(d_temp_storage, temp_storage_bytes, d_in, dev_result.begin(), num_items,
            HostDeviceSum{}, init);

        evaluate(expected, dev_result, "cub test");
    }

    // iterator test case which uses thrust
    template <typename InputIterator, typename T_output>
    void iterator_test_thrust(T_output expected, InputIterator d_in, int num_items)
    {
        T_output init{0};
        InputIterator d_in_last =  d_in + num_items;
        EXPECT_EQ( thrust::distance(d_in, d_in_last), num_items);

        T_output result = thrust::reduce(thrust::device, d_in, d_in_last, init, HostDeviceSum{});
        EXPECT_EQ(expected, result) << "thrust test";
    }

    // iterator test case which uses thrust
    template <typename InputIterator, typename T_output>
    void iterator_test_thrust_host(T_output expected, InputIterator d_in, int num_items)
    {
        T_output init{0};
        InputIterator d_in_last =  d_in + num_items;
        EXPECT_EQ( thrust::distance(d_in, d_in_last), num_items);

        T_output result = thrust::reduce(thrust::host, d_in, d_in_last, init, HostDeviceSum{});
        EXPECT_EQ(expected, result) << "thrust host test";
    }

    template <typename T_output>
    void evaluate(T_output expected, thrust::device_vector<T_output> &dev_result, const char* msg=nullptr)
    {
        thrust::host_vector<T_output>  hos_result(dev_result);

        EXPECT_EQ(expected, hos_result[0]) << msg ;
        std::cout << "Done: expected <" << msg << "> = " << hos_result[0] << std::endl;
    }
};

using TestingTypes = ::testing::Types<
    int32_t
>;

TYPED_TEST_CASE(IteratorTest, TestingTypes);


// tests for non-null iterator (pointer of device array)
TYPED_TEST(IteratorTest, non_null_iterator)
{
    using T = int32_t;
    std::vector<T> hos_array({0, 6, 0, -14, 13, 64, -13, -20, 45});
    thrust::device_vector<T> dev_array(hos_array);

    // calculate the expected value by CPU.
    T expected_value = std::accumulate(hos_array.begin(), hos_array.end(), T{0});

    // driven by iterator as a pointer of device array.
    auto it_dev = dev_array.begin();
    this->iterator_test_cub(expected_value, it_dev, dev_array.size());
    this->iterator_test_thrust(expected_value, it_dev, dev_array.size());

    this->iterator_test_thrust_host(expected_value, hos_array.begin(), hos_array.size());
}



/* tests for null input iterator (column with null bitmap)
   Actually, we can use cub for reduction with nulls without creating custom kernel or multiple steps.
   we may accelarate the reduction for a column using cub
*/
TYPED_TEST(IteratorTest, null_iterator)
{
    using T = int32_t;
    T init = T{0};
    std::vector<bool> host_bools({1, 1, 0, 1, 1, 1, 0, 1, 1});

    // create a column with bool vector
    cudf::test::column_wrapper<T> w_col({0, 6, 0, -14, 13, 64, -13, -20, 45},
        [&](gdf_index_type row) { return host_bools[row]; });

    // copy back data and valid arrays
    auto hos = w_col.to_host();

    // calculate the expected value by CPU.
    std::vector<T> replaced_array(w_col.size());
    std::transform(std::get<0>(hos).begin(), std::get<0>(hos).end(), host_bools.begin(),
        replaced_array.begin(), [&](T x, bool b) { return (b)? x : init; } );
    T expected_value = std::accumulate(replaced_array.begin(), replaced_array.end(), init);
    std::cout << "expected <null_iterator> = " << expected_value << std::endl;

    // CPU test
    auto it_hos = cudf::make_iterator_with_nulls(std::get<0>(hos).data(), std::get<1>(hos).data(), init);
    this->iterator_test_thrust_host(expected_value, it_hos, w_col.size());

    // GPU test
    auto it_dev = cudf::make_iterator_with_nulls(static_cast<T*>( w_col.get()->data ), w_col.get()->valid, init);
    this->iterator_test_thrust(expected_value, it_dev, w_col.size());
    this->iterator_test_cub(expected_value, it_dev, w_col.size());

    std::cout << "test done." << std::endl;
}

/* tests up cast reduction with null iterator
*/
TYPED_TEST(IteratorTest, null_iterator_upcast)
{
    const int column_size{1000};
    using T = int8_t;
    using T_upcast = int64_t;
    T init{0};

    std::vector<bool> host_bools(column_size);
    std::generate(host_bools.begin(), host_bools.end(),
        []() { return static_cast<bool>( random_bool() ); } );

    cudf::test::column_wrapper<T> w_col(
        column_size,
        [](gdf_index_type row) { return T{random_int<T>(-128, 127)}; },
        [&](gdf_index_type row) { return host_bools[row]; } );


    // copy back data and valid arrays
    auto hos = w_col.to_host();

    // calculate the expected value by CPU.
    std::vector<T> replaced_array(w_col.size());
    std::transform(std::get<0>(hos).begin(), std::get<0>(hos).end(), host_bools.begin(),
        replaced_array.begin(), [&](T x, bool b) { return (b)? x : init; } );
    T_upcast expected_value = std::accumulate(replaced_array.begin(), replaced_array.end(), T_upcast{0});
    std::cout << "expected <null_iterator> = " << expected_value << std::endl;

    // CPU test
    auto it_hos = cudf::make_iterator_with_nulls<T, T_upcast>(std::get<0>(hos).data(), std::get<1>(hos).data(), T{0});
    this->iterator_test_thrust_host(expected_value, it_hos, w_col.size());

    // GPU test
    auto it_dev = cudf::make_iterator_with_nulls<T, T_upcast>(static_cast<T*>( w_col.get()->data ), w_col.get()->valid, T{0});
    this->iterator_test_thrust(expected_value, it_dev, w_col.size());
    this->iterator_test_cub(expected_value, it_dev, w_col.size());

    std::cout << "test done." << std::endl;
}



/* tests for square input iterator
*/
TYPED_TEST(IteratorTest, null_iterator_square)
{
    const int column_size{1000};
    using T = int8_t;
    using T_upcast = int64_t;
    T init{0};

    std::vector<bool> host_bools(column_size);
    std::generate(host_bools.begin(), host_bools.end(),
        []() { return static_cast<bool>( random_bool() ); } );

    cudf::test::column_wrapper<T> w_col(
        column_size,
        [](gdf_index_type row) { return T{random_int<T>(-128, 127)}; },
        [&](gdf_index_type row) { return host_bools[row]; } );

    // copy back data and valid arrays
    auto hos = w_col.to_host();

    // calculate the expected value by CPU.
    std::vector<T_upcast> replaced_array(w_col.size());
    std::transform(std::get<0>(hos).begin(), std::get<0>(hos).end(), host_bools.begin(),
        replaced_array.begin(), [&](T x, bool b) { return (b)?  x*x : init; } );
    T_upcast expected_value = std::accumulate(replaced_array.begin(), replaced_array.end(), T_upcast{0});
    std::cout << "expected <null_iterator> = " << expected_value << std::endl;

    // CPU test
    auto it_hos = cudf::make_iterator_with_nulls<T, T_upcast, ColumnOutputSquared<T_upcast>>
        (std::get<0>(hos).data(), std::get<1>(hos).data(), T{0});
    this->iterator_test_thrust_host(expected_value, it_hos, w_col.size());

    // GPU test
    auto it_dev = cudf::make_iterator_with_nulls<T, T_upcast, ColumnOutputSquared<T_upcast>>
        (static_cast<T*>( w_col.get()->data ), w_col.get()->valid, T{0});
    this->iterator_test_thrust(expected_value, it_dev, w_col.size());
    this->iterator_test_cub(expected_value, it_dev, w_col.size());

    std::cout << "test done." << std::endl;
}



/*
    tests for indexed access

    this was used by old implementation of group_by.

    This won't be used with the newer implementation
     (a.k.a. Single pass, distributive groupby https://github.com/rapidsai/cudf/pull/1478)
    distributive groupby uses atomic operation to accumulate.

    For group_by.cumsum() (scan base group_by) may not be single pass scan.
    There is a possiblity that this process may be used for group_by.cumsum().
*/
TYPED_TEST(IteratorTest, indexed_iterator)
{
    using T = int32_t;
    using T_index = gdf_index_type;

    std::vector<T> hos_array({0, 6, 0, -14, 13, 64, -13, -20, 45});
    thrust::device_vector<T> dev_array(hos_array);

    std::vector<T_index> hos_indices({0, 1, 3, 5}); // sorted indices belongs to a group
    thrust::device_vector<T_index> dev_indices(hos_indices);

    // calculate the expected value by CPU.
    T expected_value = std::accumulate(hos_indices.begin(), hos_indices.end(), T{0},
        [&](T acc, T_index id){ return (acc + hos_array[id]); } );
    std::cout << "expected <group_by_iterator> = " << expected_value << std::endl;


    using T_input = ColumnInput<ColumnOutputSingle<T>, T, false>;

    // pass `dev_indices` as base iterator of `column_input_iterator`.
    T_input col(dev_array.data().get());
    column_input_iterator<T, T_input, T_index*> it_dev(col, dev_indices.data().get());

    // reduction using thrust
    this->iterator_test_thrust(expected_value, it_dev, dev_indices.size());
    // reduction using cub
    this->iterator_test_cub(expected_value, it_dev, dev_indices.size());

    // pass `dev_indices` as base iterator of `column_input_iterator`.
    T_input col_hos(hos_array.data());
    column_input_iterator<T, T_input, T_index*> it_host(col_hos, hos_indices.data());
    this->iterator_test_thrust_host(expected_value, it_host, hos_indices.size());
}

TYPED_TEST(IteratorTest, large_size_reduction)
{
    using T = int32_t;

    const int column_size{1000000};
    const T init{0};

    std::vector<bool> host_bools(column_size);
    std::generate(host_bools.begin(), host_bools.end(),
        []() { return static_cast<bool>( random_bool() ); } );

    cudf::test::column_wrapper<TypeParam> w_col(
        column_size,
        [](gdf_index_type row) { return T{random_int(-128, 128)}; },
        [&](gdf_index_type row) { return host_bools[row]; } );

    // copy back data and valid arrays
    auto hos = w_col.to_host();

    // calculate by cudf::reduction
    std::vector<T> replaced_array(w_col.size());
    std::transform(std::get<0>(hos).begin(), std::get<0>(hos).end(), host_bools.begin(),
        replaced_array.begin(), [&](T x, bool b) { return (b)? x : init; } );
    T expected_value = std::accumulate(replaced_array.begin(), replaced_array.end(), init);
    std::cout << "expected <null_iterator> = " << expected_value << std::endl;

    // CPU test
    auto it_hos = cudf::make_iterator_with_nulls(std::get<0>(hos).data(), std::get<1>(hos).data(), init);
    this->iterator_test_thrust_host(expected_value, it_hos, w_col.size());

    // GPU test
    auto it_dev = cudf::make_iterator_with_nulls(static_cast<T*>( w_col.get()->data ), w_col.get()->valid, init);
    this->iterator_test_thrust(expected_value, it_dev, w_col.size());
    this->iterator_test_cub(expected_value, it_dev, w_col.size());


    // compare with cudf::reduction
    cudf::test::scalar_wrapper<T> result =
        cudf::reduction(w_col, GDF_REDUCTION_SUM, GDF_INT32);

    EXPECT_EQ(expected_value, result.value());

}


// test for mixed output value using `ColumnOutputMix`
// it wpuld be useful for `var`, `std` operation
TYPED_TEST(IteratorTest, mixed_output)
{
    using T = int32_t;
    using T_upcast = int64_t;

    const int column_size{5000};
    const T init{0};

    std::vector<bool> host_bools(column_size);
    std::generate(host_bools.begin(), host_bools.end(),
        []() { return static_cast<bool>( random_bool() ); } );

    cudf::test::column_wrapper<TypeParam> w_col(
        column_size,
        [](gdf_index_type row) { return T{random_int(-128, 128)}; },
        [&](gdf_index_type row) { return host_bools[row]; } );

    // copy back data and valid arrays
    auto hos = w_col.to_host();

    // calculate expected values by CPU
    ColumnOutputMixed<T_upcast> expected_value;

    expected_value.count = w_col.size() - w_col.null_count();

    std::vector<T> replaced_array(w_col.size());
    std::transform(std::get<0>(hos).begin(), std::get<0>(hos).end(), host_bools.begin(),
        replaced_array.begin(), [&](T x, bool b) { return (b)? x : init; } );

    expected_value.count = w_col.size() - w_col.null_count();
    expected_value.value = std::accumulate(replaced_array.begin(), replaced_array.end(), T_upcast{0});
    expected_value.value_squared = std::accumulate(replaced_array.begin(), replaced_array.end(), T_upcast{0},
        [](T acc, T i) { return acc + i * i; });

    std::cout << "expected <mixed_output> = " << expected_value << std::endl;

    // CPU test
    auto it_hos = cudf::make_iterator_with_nulls<T, ColumnOutputMixed<T_upcast>, ColumnOutputMixed<T_upcast>>
        (std::get<0>(hos).data(), std::get<1>(hos).data(), T{0});
    this->iterator_test_thrust_host(expected_value, it_hos, w_col.size());

    // GPU test
    auto it_dev = cudf::make_iterator_with_nulls<T, ColumnOutputMixed<T_upcast>, ColumnOutputMixed<T_upcast>>
        (static_cast<T*>( w_col.get()->data ), w_col.get()->valid, init);
    this->iterator_test_thrust(expected_value, it_dev, w_col.size());
    this->iterator_test_cub(expected_value, it_dev, w_col.size());

    { // ColumnOutputMixedNoCount test
        using T_helper = ColumnOutputMixed<T_upcast, false>;

        T_helper expected_value_no_count;
        expected_value_no_count.value = expected_value.value;
        expected_value_no_count.value_squared = expected_value.value_squared;
        expected_value_no_count.count = 0;


        auto it_hos = cudf::make_iterator_with_nulls<T, T_helper, T_helper>
            (std::get<0>(hos).data(), std::get<1>(hos).data(), T{0});
        this->iterator_test_thrust_host(expected_value_no_count, it_hos, w_col.size());

        // GPU test
        auto it_dev = cudf::make_iterator_with_nulls<T, T_helper, T_helper>
            (static_cast<T*>( w_col.get()->data ), w_col.get()->valid, init);
        this->iterator_test_thrust(expected_value_no_count, it_dev, w_col.size());
        this->iterator_test_cub(expected_value_no_count, it_dev, w_col.size());
    }
}

