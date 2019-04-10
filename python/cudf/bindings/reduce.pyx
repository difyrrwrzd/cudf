# Copyright (c) 2018, NVIDIA CORPORATION.

# cython: profile=False
# distutils: language = c++
# cython: embedsignature = True
# cython: language_level = 3

# Copyright (c) 2018, NVIDIA CORPORATION.

from cudf.bindings.cudf_cpp cimport *
from cudf.bindings.cudf_cpp import *

import numpy as np
import pandas as pd
import pyarrow as pa
pandas_version = tuple(map(int,pd.__version__.split('.', 2)[:2]))

from librmm_cffi import librmm as rmm

from libc.stdint cimport uintptr_t
from libc.stdlib cimport calloc, malloc, free

from libcpp.map cimport map as cmap
from libcpp.string  cimport string as cstring


_REDUCTION_OP = {
  'sum': ReductionOp.Sum,
  'min': ReductionOp.Min,
  'max': ReductionOp.Max,
  'product': ReductionOp.Product,
  'sum_of_squares': ReductionOp.SumOfSquares,
}

_SCAN_OP = {
  'sum': ScanOp.Sum,
  'min': ScanOp.Min,
  'max': ScanOp.Max,
  'product': ScanOp.Product,
}


cdef get_scalar_value(gdf_scalar scalar):
    return {
        GDF_FLOAT64: scalar.data.fp64,
        GDF_FLOAT32: scalar.data.fp32,
        GDF_INT64:   scalar.data.si64,
        GDF_INT32:   scalar.data.si32,
        GDF_INT16:   scalar.data.si16,
        GDF_INT8:    scalar.data.si08,
        GDF_DATE32:  scalar.data.dt32,
        GDF_DATE64:  scalar.data.dt64,
        GDF_TIMESTAMP: scalar.data.tmst,
    }[scalar.dtype]


def apply_reduce(reduction_op, col, dtype=None):
    """
      Call gdf reductions.
    """

    check_gdf_compatibility(col)

    # check empty case
    if col.data.size <= col.null_count :
        if reduction_op == 'sum' or reduction_op == 'sum_of_squares':
            return col.dtype.type(0)
        if reduction_op == 'product' and pandas_version >= (0, 22):
            return col.dtype.type(1)
        return np.nan

    col_dtype = dtype if dtype != None else col.dtype

    cdef gdf_column* c_col = column_view_from_column(col)
    cdef ReductionOp c_op = _REDUCTION_OP[reduction_op]
    cdef gdf_dtype c_out_dtype = get_dtype(col_dtype.type if dtype is None else col_dtype)
    cdef gdf_scalar c_result

    print('c_out_dtype:', c_out_dtype)

    with nogil:    
        c_result = reduction(
            <gdf_column*>c_col,
            c_op,
            c_out_dtype
            )

    free(c_col)
    result = get_scalar_value(c_result)

    return result


def apply_scan(col_inp, col_out, scan_op, inclusive):
    """
      Call gdf scan.
    """

    check_gdf_compatibility(col_inp)
    check_gdf_compatibility(col_out)

    cdef gdf_column* c_col_inp = column_view_from_column(col_inp)
    cdef gdf_column* c_col_out = column_view_from_column(col_out)
    cdef ScanOp c_op = _SCAN_OP[scan_op]
    cdef bool b_inclusive = <bool>inclusive;

    with nogil:    
        scan(
            <gdf_column*>c_col_inp,
            <gdf_column*>c_col_out,
            c_op,
	    b_inclusive
            )

    free(c_col_inp)
    free(c_col_out)

    return 



