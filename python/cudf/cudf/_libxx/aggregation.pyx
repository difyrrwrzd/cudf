# Copyright (c) 2020, NVIDIA CORPORATION.

import pandas as pd
import numba
import numpy as np
from libcpp.string cimport string
from libcpp.memory cimport unique_ptr
from libcpp.vector cimport vector
from cudf.utils import cudautils

from cudf._libxx.types import np_to_cudf_types, cudf_to_np_types
from cudf._libxx.move cimport move

cimport cudf._libxx.cpp.types as libcudf_types
cimport cudf._libxx.cpp.aggregation as libcudf_aggregation
from cudf._libxx.types cimport (
    underlying_type_t_interpolation
)
from cudf._libxx.types import Interpolation


cdef unique_ptr[aggregation] make_aggregation(op, kwargs={}) except *:
    cdef _Aggregation agg
    if isinstance(op, str):
        agg = getattr(_Aggregation, op)(**kwargs)
    elif callable(op):
        if "dtype" in kwargs:
            agg = _Aggregation.from_udf(op, **kwargs)
        else:
            agg = op(_Aggregation)
    return move(agg.c_obj)


# need to update as and when we add new aggregations with additional options
cdef class _Aggregation:

    @classmethod
    def sum(cls, *args, **kwargs):
        cdef _Aggregation agg = _Aggregation.__new__(_Aggregation)
        agg.c_obj = move(libcudf_aggregation.make_sum_aggregation())
        return agg

    @classmethod
    def min(cls, *args, **kwargs):
        cdef _Aggregation agg = _Aggregation.__new__(_Aggregation)
        agg.c_obj = move(libcudf_aggregation.make_min_aggregation())
        return agg

    @classmethod
    def max(cls, *args, **kwargs):
        cdef _Aggregation agg = _Aggregation.__new__(_Aggregation)
        agg.c_obj = move(libcudf_aggregation.make_max_aggregation())
        return agg

    @classmethod
    def mean(cls, *args, **kwargs):
        cdef _Aggregation agg = _Aggregation.__new__(_Aggregation)
        agg.c_obj = move(libcudf_aggregation.make_mean_aggregation())
        return agg

    @classmethod
    def count(cls, *args, **kwargs):
        cdef _Aggregation agg = _Aggregation.__new__(_Aggregation)
        agg.c_obj = move(libcudf_aggregation.make_count_aggregation())
        return agg

    @classmethod
    def nunique(cls, *args, **kwargs):
        cdef _Aggregation agg = _Aggregation.__new__(_Aggregation)
        agg.c_obj = move(libcudf_aggregation.make_nunique_aggregation())
        return agg

    @classmethod
    def any(cls, *args, **kwargs):
        cdef _Aggregation agg = _Aggregation.__new__(_Aggregation)
        agg.c_obj = move(libcudf_aggregation.make_any_aggregation())
        return agg

    @classmethod
    def all(cls, *args, **kwargs):
        cdef _Aggregation agg = _Aggregation.__new__(_Aggregation)
        agg.c_obj = move(libcudf_aggregation.make_all_aggregation())
        return agg

    @classmethod
    def product(cls, *args, **kwargs):
        cdef _Aggregation agg = _Aggregation.__new__(_Aggregation)
        agg.c_obj = move(libcudf_aggregation.make_product_aggregation())
        return agg

    @classmethod
    def sum_of_squares(cls, *args, **kwargs):
        cdef _Aggregation agg = _Aggregation.__new__(_Aggregation)
        agg.c_obj = move(libcudf_aggregation.make_sum_of_squares_aggregation())
        return agg

    @classmethod
    def var(cls, ddof, *args, **kwargs):
        cdef _Aggregation agg = _Aggregation.__new__(_Aggregation)
        agg.c_obj = move(
            libcudf_aggregation.make_variance_aggregation(ddof)
        )
        return agg

    @classmethod
    def std(cls, ddof, *args, **kwargs):
        cdef _Aggregation agg = _Aggregation.__new__(_Aggregation)
        agg.c_obj = move(
            libcudf_aggregation.make_std_aggregation(ddof)
        )
        return agg

    @classmethod
    def quantile(cls, q=0.5, interpolation="linear"):
        cdef _Aggregation agg = _Aggregation.__new__(_Aggregation)

        if not pd.api.types.is_list_like(q):
            q = [q]

        cdef vector[double] c_q = q
        cdef libcudf_types.interpolation c_interp = (
            <libcudf_types.interpolation> (
                <underlying_type_t_interpolation> (
                    Interpolation[interpolation.upper()]
                )
            )
        )
        agg.c_obj = move(
            libcudf_aggregation.make_quantile_aggregation(
                c_q,
                c_interp
            )
        )
        return agg

    @classmethod
    def from_udf(cls, op, *args, **kwargs):
        cdef _Aggregation agg = _Aggregation.__new__(_Aggregation)

        cdef libcudf_types.type_id tid
        cdef libcudf_types.data_type out_dtype
        cdef string cpp_str

        # Handling UDF type
        nb_type = numba.numpy_support.from_dtype(kwargs['dtype'])
        type_signature = (nb_type[:],)
        compiled_op = cudautils.compile_udf(op, type_signature)
        output_np_dtype = np.dtype(compiled_op[1])
        cpp_str = compiled_op[0].encode('UTF-8')
        if output_np_dtype not in np_to_cudf_types:
            raise TypeError(
                "Result of window function has unsupported dtype {}"
                .format(op[1])
            )
        tid = np_to_cudf_types[output_np_dtype]

        out_dtype = libcudf_types.data_type(tid)

        agg.c_obj = move(libcudf_aggregation.make_udf_aggregation(
            libcudf_aggregation.udf_type.PTX, cpp_str, out_dtype
        ))
        return agg
