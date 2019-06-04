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


#include <iterator/iterator.cuh>    // include iterator header

#include <gmock/gmock.h>
#include <gtest/gtest.h>

#include <bitset>
#include <cstdint>
#include <iostream>
#include <numeric>
#include <random>

#include <tests/utilities/cudf_test_fixtures.h>
#include <tests/utilities/column_wrapper.cuh>
#include <tests/utilities/scalar_wrapper.cuh>
#include <utilities/device_operators.cuh>

#include <thrust/transform.h>

// for reduction tests
#include <cub/device/device_reduce.cuh>
#include <thrust/device_vector.h>
#include <reduction.hpp>

// ---------------------------------------------------------------------------

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

template<typename T, bool update_count>
std::ostream& operator<<(std::ostream& os, cudf::detail::mutator_meanvar<T, update_count> const& rhs)
{
  return os << "[" << rhs.value <<
      ", " << rhs.value_squared <<
      ", " << rhs.count << "] ";
};

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
            cudf::DeviceSum{}, init);
        // Allocate temporary storage
        RMM_TRY(RMM_ALLOC(&d_temp_storage, temp_storage_bytes, 0));

        // Run reduction
        cub::DeviceReduce::Reduce(d_temp_storage, temp_storage_bytes, d_in, dev_result.begin(), num_items,
            cudf::DeviceSum{}, init);

        evaluate(expected, dev_result, "cub test");
    }

    // iterator test case which uses thrust
    template <typename InputIterator, typename T_output>
    void iterator_test_thrust(T_output expected, InputIterator d_in, int num_items)
    {
        T_output init{0};
        InputIterator d_in_last =  d_in + num_items;
        EXPECT_EQ( thrust::distance(d_in, d_in_last), num_items);

        T_output result = thrust::reduce(thrust::device, d_in, d_in_last, init, cudf::DeviceSum{});
        EXPECT_EQ(expected, result) << "thrust test";
    }

    // iterator test case which uses thrust
    template <typename InputIterator, typename T_output>
    void iterator_test_thrust_host(T_output expected, InputIterator d_in, int num_items)
    {
        T_output init{0};
        InputIterator d_in_last =  d_in + num_items;
        EXPECT_EQ( thrust::distance(d_in, d_in_last), num_items);

        T_output result = thrust::reduce(thrust::host, d_in, d_in_last, init, cudf::DeviceSum{});
        EXPECT_EQ(expected, result) << "thrust host test";
    }

    template <typename T_output>
    void evaluate(T_output expected, thrust::device_vector<T_output> &dev_result, const char* msg=nullptr)
    {
        thrust::host_vector<T_output>  hos_result(dev_result);

        EXPECT_EQ(expected, hos_result[0]) << msg ;
        std::cout << "Done: expected <" << msg << "> = " << hos_result[0] << std::endl;
    }

    template <typename T_output>
    void column_sum_test(T_output& expected, const gdf_column& col)
    {
        if( col.valid == nullptr){
            column_sum_test<false, T_output>(expected, col);
        }else{
            column_sum_test<true, T_output>(expected, col);
        }
    }

    template <bool has_nulls, typename T_output>
    void column_sum_test(T_output& expected, const gdf_column& col)
    {
        auto it_dev = cudf::make_iterator<has_nulls, T_output>(col,  T{0});
        iterator_test_cub(expected, it_dev, col.size);
    }
};


using TestingTypes = ::testing::Types<
    int32_t
>;

TYPED_TEST_CASE(IteratorTest, TestingTypes);


#if 1

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

    // test column input
    cudf::test::column_wrapper<T> w_col(hos_array);
    this->column_sum_test(expected_value, w_col);
}



// Tests for null input iterator (column with null bitmap)
// Actually, we can use cub for reduction with nulls without creating custom kernel or multiple steps.
// We may accelarate the reduction for a column using cub
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
    auto it_hos = cudf::make_iterator<true>(std::get<0>(hos).data(), std::get<1>(hos).data(), init);
    this->iterator_test_thrust_host(expected_value, it_hos, w_col.size());

    // GPU test
    auto it_dev = cudf::make_iterator<true>(static_cast<T*>( w_col.get()->data ), w_col.get()->valid, init);
    this->iterator_test_thrust(expected_value, it_dev, w_col.size());
    this->iterator_test_cub(expected_value, it_dev, w_col.size());

    this->column_sum_test(expected_value, w_col);
}

// Tests up cast reduction with null iterator.
// The up cast iterator will be created by `cudf::make_iterator<true, T, T_upcast>(...)`
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
    auto it_hos = cudf::make_iterator<true, T, T_upcast>(std::get<0>(hos).data(), std::get<1>(hos).data(), T{0});
    this->iterator_test_thrust_host(expected_value, it_hos, w_col.size());

    // GPU test
    auto it_dev = cudf::make_iterator<true, T, T_upcast>(static_cast<T*>( w_col.get()->data ), w_col.get()->valid, T{0});
    this->iterator_test_thrust(expected_value, it_dev, w_col.size());
    this->iterator_test_cub(expected_value, it_dev, w_col.size());
}



// Tests for square input iterator using helper strcut `cudf::ColumnOutputSquared<T_upcast>`
// The up cast iterator will be created by
//  `cudf::make_iterator<true, T, T_upcast, cudf::ColumnOutputSquared<T_upcast>>(...)`
TYPED_TEST(IteratorTest, null_iterator_square)
{
    const int column_size{1000};
    using T = int8_t;
    using T_upcast = int64_t;
    using T_mutator = cudf::detail::mutator_squared<T_upcast>;
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
    auto it_hos = cudf::make_iterator<true, T, T_upcast, T_mutator>
        (std::get<0>(hos).data(), std::get<1>(hos).data(), T{0});
    this->iterator_test_thrust_host(expected_value, it_hos, w_col.size());

    // GPU test
    auto it_dev = cudf::make_iterator<true, T, T_upcast, T_mutator>
        (static_cast<T*>( w_col.get()->data ), w_col.get()->valid, T{0});
    this->iterator_test_thrust(expected_value, it_dev, w_col.size());
    this->iterator_test_cub(expected_value, it_dev, w_col.size());
}


//    tests for indexed access
//    this was used by old implementation of group_by.
//
//    This won't be used with the newer implementation
//     (a.k.a. Single pass, distributive groupby https://github.com/rapidsai/cudf/pull/1478)
//    distributive groupby uses atomic operation to accumulate.
//
//    For group_by.cumsum() (scan base group_by) may not be single pass scan.
//    There is a possiblity that this process may be used for group_by.cumsum().
TYPED_TEST(IteratorTest, indexed_iterator)
{
    using T = int32_t;
    using T_index = gdf_index_type;
    using T_output = T;
    using T_helper = cudf::detail::mutator_single<T_output>;

    std::vector<T> hos_array({0, 6, 0, -14, 13, 64, -13, -20, 45});
    thrust::device_vector<T> dev_array(hos_array);

    std::vector<T_index> hos_indices({0, 1, 3, 5}); // sorted indices belongs to a group
    thrust::device_vector<T_index> dev_indices(hos_indices);

    // calculate the expected value by CPU.
    T expected_value = std::accumulate(hos_indices.begin(), hos_indices.end(), T{0},
        [&](T acc, T_index id){ return (acc + hos_array[id]); } );
    std::cout << "expected <group_by_iterator> = " << expected_value << std::endl;

    const bit_mask::bit_mask_t *dummy = nullptr;
    // CPU test
    auto it_host = cudf::make_iterator<false, T, T_output, T_helper, T_index*>
        (hos_array.data(), dummy, T{0}, hos_indices.data());
    this->iterator_test_thrust_host(expected_value, it_host, hos_indices.size());

    // GPU test
    auto it_dev = cudf::make_iterator<false, T, T_output, T_helper, T_index*>
        (dev_array.data().get(), dummy, T{0}, dev_indices.data().get());
    this->iterator_test_thrust(expected_value, it_dev, dev_indices.size());
    this->iterator_test_cub(expected_value, it_dev, dev_indices.size());
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
    auto it_hos = cudf::make_iterator<true>(std::get<0>(hos).data(), std::get<1>(hos).data(), init);
    this->iterator_test_thrust_host(expected_value, it_hos, w_col.size());

    // GPU test
    auto it_dev = cudf::make_iterator<true>(static_cast<T*>( w_col.get()->data ), w_col.get()->valid, init);
    this->iterator_test_thrust(expected_value, it_dev, w_col.size());
    this->iterator_test_cub(expected_value, it_dev, w_col.size());


    // compare with cudf::reduction
    cudf::test::scalar_wrapper<T> result =
        cudf::reduction(w_col, GDF_REDUCTION_SUM, GDF_INT32);

    EXPECT_EQ(expected_value, result.value());
}


// Test for mixed output value using `ColumnOutputMix`
// It computes `count`, `sum`, `sum_of_squares` at a single reduction call.
// It wpuld be useful for `var`, `std` operation
TYPED_TEST(IteratorTest, mean_var_output)
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
    using T_Mutator = cudf::detail::mutator_meanvar<T_upcast, true>;
    T_Mutator expected_value;

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
    auto it_hos = cudf::make_iterator<true, T, T_Mutator, T_Mutator>
        (std::get<0>(hos).data(), std::get<1>(hos).data(), T{0});
    this->iterator_test_thrust_host(expected_value, it_hos, w_col.size());

    // GPU test
    auto it_dev = cudf::make_iterator<true, T, T_Mutator, T_Mutator>
        (static_cast<T*>( w_col.get()->data ), w_col.get()->valid, init);
    this->iterator_test_thrust(expected_value, it_dev, w_col.size());
    this->iterator_test_cub(expected_value, it_dev, w_col.size());

    { // mutator_meanvarNoCount test
        using T_helper = cudf::detail::mutator_meanvar<T_upcast, false>;

        T_helper expected_value_no_count;
        expected_value_no_count.value = expected_value.value;
        expected_value_no_count.value_squared = expected_value.value_squared;
        expected_value_no_count.count = 0;

        auto it_hos = cudf::make_iterator<true, T, T_helper, T_helper>
            (std::get<0>(hos).data(), std::get<1>(hos).data(), T{0});
        this->iterator_test_thrust_host(expected_value_no_count, it_hos, w_col.size());

        // GPU test
        auto it_dev = cudf::make_iterator<true, T, T_helper, T_helper>
            (static_cast<T*>( w_col.get()->data ), w_col.get()->valid, init);
        this->iterator_test_thrust(expected_value_no_count, it_dev, w_col.size());
        this->iterator_test_cub(expected_value_no_count, it_dev, w_col.size());
    }
}

#endif


/**---------------------------------------------------------------------------*
 * @brief test macro to be expected as no exception.
 * The testing is same with EXPECT_ANY_THROW() in gtest.
 * It also outputs captured error message, useful for debugging.
 *
 * @param statement The statement to be tested
 *---------------------------------------------------------------------------**/
 #define CUDF_EXPECT_ANY_THROW(statement)        \
 try{ statement; \
      FAIL() << "No exception thrown at"         \
      << "statement:" << #statement << std::endl; \
    } catch (std::exception& e)                  \
     { std::cout << "Caught expected exception. " \
              << "reason: " << e.what() << std::endl; }


TYPED_TEST(IteratorTest, error_handling)
{
    using T = int32_t;
    std::vector<T> hos_array({0, 6, 0, -14, 13, 64, -13, -20, 45});

    cudf::test::column_wrapper<T> w_col_no_null(hos_array);
    cudf::test::column_wrapper<T> w_col_null(hos_array,
        [&](gdf_index_type row) { return true; });

    // expects error: data type mismatch
    CUDF_EXPECT_ANY_THROW( (cudf::make_iterator<false, double>( *w_col_null.get(), double{0}) ) );

    // expects error: data type mismatch
    CUDF_EXPECT_ANY_THROW( (cudf::make_iterator<true, float>( *w_col_null.get(), float{0}) ) );

    // expects error: valid == nullptr
    CUDF_EXPECT_ANY_THROW( (cudf::make_iterator<true, T>( *w_col_no_null.get(), T{0}) ) );

    // expects no error: treat no null iterator with column has nulls
    CUDF_EXPECT_NO_THROW( (cudf::make_iterator<false, T>( *w_col_null.get(), T{0}) ) );
}
