from __future__ import print_function
import ctypes
from contextlib import contextmanager

import pytest

import numpy as np
from numba import cuda

from libgdf_cffi import ffi, libgdf

from .utils import new_column, unwrap_devary, get_dtype


@contextmanager
def _make_input(left, right):
    d_left = cuda.to_device(left)
    col_left = new_column()
    libgdf.gdf_column_view(col_left, unwrap_devary(d_left), ffi.NULL,
                           left.size, get_dtype(d_left.dtype))

    d_right = cuda.to_device(right)
    col_right = new_column()
    libgdf.gdf_column_view(col_right, unwrap_devary(d_right), ffi.NULL,
                           right.size, get_dtype(d_right.dtype))

    yield col_left, col_right


def _call_join(api, col_left, col_right):
    join_result_ptr = ffi.new("gdf_join_result_type**", None)

    api(col_left, col_right, join_result_ptr)
    join_result = join_result_ptr[0]
    print('join_result', join_result)

    dataptr = libgdf.gdf_join_result_data(join_result)
    print(dataptr)
    datasize = libgdf.gdf_join_result_size(join_result)
    print(datasize)

    addr = ctypes.c_uint64(int(ffi.cast("uintptr_t", dataptr)))
    print(hex(addr.value))
    memptr = cuda.driver.MemoryPointer(context=cuda.current_context(),
                                       pointer=addr, size=4 * datasize)
    print(memptr)
    ary = cuda.devicearray.DeviceNDArray(shape=(datasize,), strides=(4,),
                                         dtype=np.dtype(np.int32),
                                         gpu_data=memptr)

    joined_idx = ary.reshape(2, datasize//2).copy_to_host()
    print(joined_idx)

    libgdf.gdf_join_result_free(join_result)
    return joined_idx


params_dtypes = [np.int8, np.int32, np.int64, np.float32, np.float64]


@pytest.mark.parametrize('dtype', params_dtypes)
def test_innerjoin(dtype):
    # Make data
    left = np.array([0, 0, 1, 2, 3], dtype=dtype)
    right = np.array([0, 1, 2, 2, 3], dtype=dtype)
#    left = np.array([44, 47, 0, 3, 3, 39, 9, 19, 21, 36, 23, 6, 24, 24, 12, 1, 38, 39, 23, 46, 24, 17, 37, 25, 13, 8, 9, 20, 16, 5, 15, 47, 0, 18, 35, 24, 49, 29, 19, 19, 14, 39, 32, 1, 9, 32, 31, 10, 23, 35, 11, 28, 34, 0, 0, 36, 5, 38, 40, 17, 15, 4, 41, 42, 31, 1, 1, 39, 41, 35, 38, 11, 46, 18, 27, 0, 14, 35, 12, 42, 20, 11, 4, 6, 4, 47, 3, 12, 36, 40, 14, 15, 20, 35, 23, 15, 13, 21, 48, 49], dtype=dtype)
#    right = np.array([5, 41, 35, 0, 31, 5, 30, 0, 49, 36, 34, 48, 29, 3, 34, 42, 13, 48, 39, 21, 9, 0, 10, 43, 23, 2, 34, 35, 30, 3, 18, 46, 35, 20, 17, 27, 14, 41, 1, 36, 10, 22, 43, 40, 11, 2, 16, 32, 0, 38, 19, 46, 42, 40, 13, 30, 24, 2, 3, 30, 34, 43, 13, 48, 40, 8, 19, 31, 8, 26, 2, 3, 44, 14, 32, 4, 3, 45, 11, 22, 13, 45, 11, 16, 24, 29, 21, 46, 25, 16, 19, 33, 40, 32, 36, 6, 21, 31, 13, 7], dtype=dtype)

    with _make_input(left, right) as (col_left, col_right):
        # Join
        joined_idx = _call_join(libgdf.gdf_inner_join_generic, col_left,
                                col_right)
    # Check answer
    # Can be generated by:
    # In [56]: df = pd.DataFrame()
    # In [57]: df = pd.DataFrame()
    # In [58]: df['a'] = list(range(5))
    # In [59]: df1 = df.set_index(np.array([0, 0, 1, 2, 3]))
    # In [60]: df2 = df.set_index(np.array([0, 1, 2, 2, 3]))
    # In [61]: df1.join(df2, lsuffix='_left', rsuffix='_right', how='inner')
    # Out[61]:
    #    a_left  a_right
    # 0       0        0
    # 0       1        0
    # 1       2        1
    # 2       3        2
    # 2       3        3
    # 3       4        4
    left_pos, right_pos = joined_idx
    left_idx = left[left_pos]
    right_idx = right[right_pos]

    assert list(left_idx) == list(right_idx)
    # sort before checking since the hash join may produce results in random order
    tmp = sorted(zip(left_pos, right_pos), key=lambda pair: (pair[0], pair[1]))
    left_pos = [x for x,_ in tmp]
    right_pos = [x for _,x in tmp]
    # left_pos == a_left
    assert tuple(left_pos) == (0, 1, 2, 3, 3, 4)
    # right_pos == a_right
    assert tuple(right_pos) == (0, 0, 1, 2, 3, 4)

@pytest.mark.parametrize('dtype', params_dtypes)
def test_leftjoin(dtype):
    # Make data
    left = np.array([0, 0, 4, 5, 5], dtype=dtype)
    right = np.array([0, 0, 2, 3, 5], dtype=dtype)
    with _make_input(left, right) as (col_left, col_right):
        # Join
        joined_idx = _call_join(libgdf.gdf_left_join_generic, col_left,
                                col_right)
    # Check answer
    # Can be generated by:
    # In [75]: df = pd.DataFrame()
    # In [76]: df['a'] = list(range(5))
    # In [77]: df1 = df.set_index(np.array([0, 0, 4, 5, 5]))
    # In [78]: df2 = df.set_index(np.array([0, 0, 2, 3, 5]))
    # In [79]: df1.join(df2, lsuffix='_left', rsuffix='_right', how='left')
    # Out[79]:
    #    a_left  a_right
    # 0       0      0.0
    # 0       0      1.0
    # 0       1      0.0
    # 0       1      1.0
    # 4       2      NaN
    # 5       3      4.0
    # 5       4      4.0
    left_pos, right_pos = joined_idx
    left_idx = [left[a] for a in left_pos]
    right_idx = [right[b] if b != -1 else None for b in right_pos]

    # sort before checking since the hash join may produce results in random order
    left_idx = sorted(left_idx)
    assert tuple(left_idx) == (0, 0, 0, 0, 4, 5, 5)
    # sort wouldn't work for nans
    #assert tuple(right_idx) == (0, 0, 0, 0, None, 5, 5)

    # sort before checking since the hash join may produce results in random order
    tmp = sorted(zip(left_pos, right_pos), key=lambda pair: (pair[0], pair[1]))
    left_pos = [x for x,_ in tmp]
    right_pos = [x for _,x in tmp]
    # left_pos == a_left
    assert tuple(left_pos) == (0, 0, 1, 1, 2, 3, 4)
    # right_pos == a_right
    assert tuple(right_pos) == (0, 1, 0, 1, -1, 4, 4)


@pytest.mark.parametrize('dtype', params_dtypes)
def test_outerjoin(dtype):
    # Make data
    left = np.array([0, 0, 4, 5, 5], dtype=dtype)
    right = np.array([0, 0, 2, 3, 5], dtype=dtype)
    with _make_input(left, right) as (col_left, col_right):
        # Join
        joined_idx = _call_join(libgdf.gdf_outer_join_generic, col_left, col_right)
    # Check answer
    # Can be generated by:
    # In [75]: df = pd.DataFrame()
    # In [76]: df['a'] = list(range(5))
    # In [77]: df1 = df.set_index(np.array([0, 0, 4, 5, 5]))
    # In [78]: df2 = df.set_index(np.array([0, 0, 2, 3, 5]))
    # In [79]: df1.join(df2, lsuffix='_left', rsuffix='_right', how='outer')
    # Out[79]:
    #    a_left  a_right
    # 0     0.0      0.0
    # 0     0.0      1.0
    # 0     1.0      0.0
    # 0     1.0      1.0
    # 2     NaN      2.0
    # 3     NaN      3.0
    # 4     2.0      NaN
    # 5     3.0      4.0
    # 5     4.0      4.0
    #
    # Note: the algorithm is different here that we append the missing rows
    #       from the right to the end.  So the result is actually:
    #    a_left  a_right
    # 0     0.0      0.0
    # 0     0.0      1.0
    # 0     1.0      0.0
    # 0     1.0      1.0
    # 4     2.0      NaN
    # 5     3.0      4.0
    # 5     4.0      4.0
    # 2     NaN      2.0
    # 3     NaN      3.0
    # Note: This is actually leftjoin + append missing

    def at(arr, x):
        if x != -1:
            return arr[x]

    left_pos, right_pos = joined_idx
    left_idx = [at(left, a) for a in left_pos]
    right_idx = [at(right, b) for b in right_pos]

    assert tuple(left_idx) == (0, 0, 0, 0, 4, 5, 5, None, None)
    assert tuple(right_idx) == (0, 0, 0, 0, None, 5, 5, 2, 3)
    # left_pos == a_left
    assert tuple(left_pos) == (0, 0, 1, 1, 2, 3, 4, -1, -1)
    # right_pos == a_right
    assert tuple(right_pos) == (0, 1, 0, 1, -1, 4, 4, 2, 3)
