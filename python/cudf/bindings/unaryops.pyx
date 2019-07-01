# Copyright (c) 2019, NVIDIA CORPORATION.

# cython: profile=False
# distutils: language = c++
# cython: embedsignature = True
# cython: language_level = 3
from cudf.bindings.cudf_cpp cimport *
from cudf.bindings.cudf_cpp import *
from cudf.bindings.unaryops cimport *
from cudf.bindings.GDFError import GDFError
from cudf.dataframe.column import Column
from libcpp.vector cimport vector
from libc.stdlib cimport free

from librmm_cffi import librmm as rmm

from libcpp.string cimport string

import numpy as np

_MATH_OP = {
    'sin'   : GDF_SIN,
    'cos'   : GDF_COS,
    'tan'   : GDF_TAN,
    'asin'  : GDF_ARCSIN,
    'acos'  : GDF_ARCCOS,
    'atan'  : GDF_ARCTAN,
    'exp'   : GDF_EXP,
    'log'   : GDF_LOG,
    'sqrt'  : GDF_SQRT,
    'ceil'  : GDF_CEIL,
    'floor' : GDF_FLOOR,
    'abs'   : GDF_ABS,
    'invert': GDF_BIT_INVERT,
    'not'   : GDF_NOT,
}

def apply_math_op(incol, outcol, op):
    """
    Call Unary math ops.
    """

    check_gdf_compatibility(incol)
    check_gdf_compatibility(outcol)
    
    cdef gdf_column* c_incol = column_view_from_column(incol)
    cdef gdf_column* c_outcol = column_view_from_column(outcol)

    cdef gdf_error result
    cdef gdf_unary_math_op c_op = _MATH_OP[op]
    with nogil:    
        result = gdf_unary_math(
            <gdf_column*>c_incol,
            <gdf_column*>c_outcol,
            c_op)
    
    free(c_incol)
    free(c_outcol)

    check_gdf_error(result)

def column_applymap(incol, udf_ptx, np_dtype):
    
    cdef gdf_column* c_incol = column_view_from_column(incol)

    cdef string cpp_str = udf_ptx.encode('UTF-8')
    cdef gdf_column c_outcol

    cdef gdf_dtype g_type = dtypes[np_dtype] # get the gdf_type related to the input np type

    with nogil:
        c_outcol = transform(<gdf_column>c_incol[0], cpp_str, g_type)
    
    (data, mask) = gdf_column_to_column_mem(&c_outcol)

    free(c_incol)

    return Column.from_mem_views(data, mask) 

def apply_dt_extract_op(incol, outcol, op):
    """
    Call a datetime extraction op
    """

    check_gdf_compatibility(incol)
    check_gdf_compatibility(outcol)

    cdef gdf_column* c_incol = column_view_from_column(incol)
    cdef gdf_column* c_outcol = column_view_from_column(outcol)

    cdef gdf_error result = GDF_CUDA_ERROR
    with nogil:
        if op == 'year':
            result = gdf_extract_datetime_year(
                <gdf_column*>c_incol,
                <gdf_column*>c_outcol
            )
        elif op == 'month':
            result = gdf_extract_datetime_month(
                <gdf_column*>c_incol,
                <gdf_column*>c_outcol
            )
        elif op == 'day':
            result = gdf_extract_datetime_day(
                <gdf_column*>c_incol,
                <gdf_column*>c_outcol
            )
        elif op == 'hour':
            result = gdf_extract_datetime_hour(
                <gdf_column*>c_incol,
                <gdf_column*>c_outcol
            )
        elif op == 'minute':
            result = gdf_extract_datetime_minute(
                <gdf_column*>c_incol,
                <gdf_column*>c_outcol
            )
        elif op == 'second':
            result = gdf_extract_datetime_second(
                <gdf_column*>c_incol,
                <gdf_column*>c_outcol
            )

    free(c_incol)
    free(c_outcol)

    check_gdf_error(result)
