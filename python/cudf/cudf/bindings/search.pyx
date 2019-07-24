# Copyright (c) 2019, NVIDIA CORPORATION.

# cython: profile=False
# distutils: language = c++
# cython: embedsignature = True
# cython: language_level = 3

# Copyright (c) 2018, NVIDIA CORPORATION.

from cudf.bindings.cudf_cpp cimport *
from cudf.bindings.cudf_cpp import *
from cudf.bindings.search cimport *
from libc.stdlib cimport free

from cudf.dataframe.column import Column


def search_sorted(column, values, side):
    """Find indices where elements should be inserted to maintain order

    Parameters
    ----------
    column : Column
        Column to search in
    values : Column
        Column of values to search for
    side : str {‘left’, ‘right’} optional
        If ‘left’, the index of the first suitable location found is given.
        If ‘right’, return the last such index
    """
    cdef gdf_column *c_column = column_view_from_column(column)
    cdef gdf_column *c_values = column_view_from_column(values)
    cdef gdf_column result

    if side == 'left':
        with nogil:
            result = lower_bound(c_column[0], c_values[0], False)
    if side == 'right':
        with nogil:
            result = upper_bound(c_column[0], c_values[0], False)

    free(c_column)
    free(c_values)

    data, mask = gdf_column_to_column_mem(&result)
    return Column.from_mem_views(data, mask)
