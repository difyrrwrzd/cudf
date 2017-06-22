from __future__ import division, print_function
import pytest
import random
from itertools import product

import numpy as np
from numba import cuda

from libgdf_cffi import ffi, libgdf

from .utils import (new_column, unwrap_devary, get_dtype, gen_rand,
                    buffer_as_bits)


params_dtype = [
    np.float64,
    np.float32,
    np.int64,
    np.int32,
]

params_sizes = [1, 2, 3, 127, 128, 129, 200, 10000]

params = list(product(params_dtype, params_sizes))


@pytest.mark.parametrize('dtype,nelem', params)
def test_sum(dtype, nelem):
    data = gen_rand(dtype, nelem)
    d_data = cuda.to_device(data)
    d_result = cuda.device_array(libgdf.gdf_reduce_optimal_output_size(),
                                 dtype=d_data.dtype)

    col_data = new_column()
    gdf_dtype = get_dtype(dtype)

    libgdf.gdf_column_view(col_data, unwrap_devary(d_data), ffi.NULL, nelem,
                           gdf_dtype)

    libgdf.gdf_sum_generic(col_data, unwrap_devary(d_result), d_result.size)
    got = d_result.copy_to_host()[0]
    expect = data.sum()

    print('expect:', expect)
    print('got:', got)

    np.testing.assert_array_almost_equal(expect, got)


@pytest.mark.parametrize('dtype,nelem', params)
def test_product(dtype, nelem):
    if np.dtype(dtype).kind == 'i':
        data = np.ones(nelem, dtype=dtype)
        # Set at most 30 items to [0..2) to keep the value within 2^32
        for _ in range(30):
            data[random.randrange(nelem)] = random.random() * 2
    else:
        data = gen_rand(dtype, nelem)

    print('max', data.max(), 'min', data.min())
    d_data = cuda.to_device(data)
    d_result = cuda.device_array(libgdf.gdf_reduce_optimal_output_size(),
                                 dtype=d_data.dtype)

    col_data = new_column()
    gdf_dtype = get_dtype(dtype)

    libgdf.gdf_column_view(col_data, unwrap_devary(d_data), ffi.NULL, nelem,
                           gdf_dtype)

    libgdf.gdf_product_generic(col_data, unwrap_devary(d_result), d_result.size)
    got = d_result.copy_to_host()[0]
    expect = np.product(data)

    print('expect:', expect)
    print('got:', got)

    np.testing.assert_array_almost_equal(expect, got)


@pytest.mark.parametrize('nelem', params_sizes)
def test_sum_masked(nelem):
    dtype = np.float64
    data = gen_rand(dtype, nelem)
    mask = gen_rand(np.int8, (nelem + 8 - 1) // 8)

    d_data = cuda.to_device(data)
    d_mask = cuda.to_device(mask)
    d_result = cuda.device_array(libgdf.gdf_reduce_optimal_output_size(),
                                 dtype=d_data.dtype)

    col_data = new_column()
    gdf_dtype = get_dtype(dtype)
    libgdf.gdf_column_view(col_data, unwrap_devary(d_data),
                           unwrap_devary(d_mask), nelem, gdf_dtype)
    libgdf.gdf_sum_generic(col_data, unwrap_devary(d_result), d_result.size)

    got = d_result.copy_to_host()[0]
    boolmask = buffer_as_bits(mask)[:nelem]
    expect = data[boolmask].sum()

    np.testing.assert_almost_equal(expect, got)


accuracy_for_dtype = {
    np.float64: 6,
    np.float32: 5
}
params_real_only = list(product([np.float64, np.float32], params_sizes))


@pytest.mark.parametrize('dtype,nelem', params_real_only)
def test_sum_squared(dtype, nelem):
    decimal = accuracy_for_dtype[dtype]
    data = gen_rand(dtype, nelem)
    d_data = cuda.to_device(data)
    d_result = cuda.device_array(libgdf.gdf_reduce_optimal_output_size(),
                                 dtype=d_data.dtype)

    col_data = new_column()
    gdf_dtype = get_dtype(dtype)

    libgdf.gdf_column_view(col_data, unwrap_devary(d_data), ffi.NULL, nelem,
                           gdf_dtype)

    libgdf.gdf_sum_squared_generic(col_data, unwrap_devary(d_result),
                                   d_result.size)
    got = d_result.copy_to_host()[0]
    expect = (data ** 2).sum()

    print('expect:', expect)
    print('got:', got)

    np.testing.assert_array_almost_equal(expect, got, decimal=decimal)


@pytest.mark.parametrize('dtype,nelem', params)
def test_min(dtype, nelem):
    data = gen_rand(dtype, nelem)
    d_data = cuda.to_device(data)
    d_result = cuda.device_array(libgdf.gdf_reduce_optimal_output_size(),
                                 dtype=d_data.dtype)

    col_data = new_column()
    gdf_dtype = get_dtype(dtype)

    libgdf.gdf_column_view(col_data, unwrap_devary(d_data), ffi.NULL, nelem,
                           gdf_dtype)

    libgdf.gdf_min_generic(col_data, unwrap_devary(d_result), d_result.size)
    got = d_result.copy_to_host()[0]
    expect = data.min()

    print('expect:', expect)
    print('got:', got)

    assert expect == got


@pytest.mark.parametrize('dtype,nelem', params)
def test_max(dtype, nelem):
    data = gen_rand(dtype, nelem)
    d_data = cuda.to_device(data)
    d_result = cuda.device_array(libgdf.gdf_reduce_optimal_output_size(),
                                 dtype=d_data.dtype)

    col_data = new_column()
    gdf_dtype = get_dtype(dtype)

    libgdf.gdf_column_view(col_data, unwrap_devary(d_data), ffi.NULL, nelem,
                           gdf_dtype)

    libgdf.gdf_max_generic(col_data, unwrap_devary(d_result), d_result.size)
    got = d_result.copy_to_host()[0]
    expect = data.max()

    print('expect:', expect)
    print('got:', got)

    assert expect == got
