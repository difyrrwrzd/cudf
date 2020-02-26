# Copyright (c) 2020, NVIDIA CORPORATION.

from enum import IntEnum

from cudf._libxx.column cimport Column
from cudf._libxx.lib cimport *
from cudf._libxx.lib import np_to_cudf_types
cimport cudf._libxx.includes.unary as cpp_unary
from cudf._libxx.includes.unary cimport (
    underlying_type_t_unary_op,
    unary_op
)

class UnaryOp(IntEnum):
    SIN = <underlying_type_t_unary_op> unary_op.SIN
    COS = <underlying_type_t_unary_op> unary_op.COS
    TAN = <underlying_type_t_unary_op> unary_op.TAN
    ARCSIN = <underlying_type_t_unary_op> unary_op.ARCSIN
    ARCCOS = <underlying_type_t_unary_op> unary_op.ARCCOS
    ARCTAN = <underlying_type_t_unary_op> unary_op.ARCTAN
    SINH = <underlying_type_t_unary_op> unary_op.SINH
    COSH = <underlying_type_t_unary_op> unary_op.COSH
    TANH = <underlying_type_t_unary_op> unary_op.TANH
    ARCSINH = <underlying_type_t_unary_op> unary_op.ARCSINH
    ARCCOSH = <underlying_type_t_unary_op> unary_op.ARCCOSH
    ARCTANH = <underlying_type_t_unary_op> unary_op.ARCTANH
    EXP = <underlying_type_t_unary_op> unary_op.EXP
    LOG = <underlying_type_t_unary_op> unary_op.LOG
    SQRT = <underlying_type_t_unary_op> unary_op.SQRT
    CBRT = <underlying_type_t_unary_op> unary_op.CBRT
    CEIL = <underlying_type_t_unary_op> unary_op.CEIL
    FLOOR = <underlying_type_t_unary_op> unary_op.FLOOR
    ABS = <underlying_type_t_unary_op> unary_op.ABS
    RINT = <underlying_type_t_unary_op> unary_op.RINT
    BIT_INVERT = <underlying_type_t_unary_op> unary_op.BIT_INVERT
    NOT = <underlying_type_t_unary_op> unary_op.NOT


def unary_operation(Column input, object op):
    cdef column_view c_input = input.view()
    cdef unary_op c_op = <unary_op>(<underlying_type_t_unary_op> op)

    with nogil:
        c_result = move(
            cpp_unary.unary_operation(
                c_input,
                c_op
            )
        )

    return Column.from_unique_ptr(move(c_result))


def is_null(Column input):
    cdef column_view c_input = input.view()

    with nogil:
        c_result = move(cpp_unary.is_null(c_input))

    return Column.from_unique_ptr(move(c_result))


def is_valid(Column input):
    cdef column_view c_input = input.view()

    with nogil:
        c_result = move(cpp_unary.is_valid(c_input))

    return Column.from_unique_ptr(move(c_result))


# def cast(Column input, object out_type):
#     cdef column_view c_input = input.view()
#     cdef type_id tid = np_to_cudf_types[np.dtype(out_type)]
#     cdef data_type c_dtype = data_type(tid)

#     with nogil:
#         c_result = move(cpp_unary.cast(c_input, c_dtype))

#     return Column.from_unique_ptr(move(c_result))


def is_nan(Column input):
    cdef column_view c_input = input.view()

    with nogil:
        c_result = move(cpp_unary.is_nan(c_input))

    return Column.from_unique_ptr(move(c_result))


def is_non_nan(Column input):
    cdef column_view c_input = input.view()

    with nogil:
        c_result = move(cpp_unary.is_not_nan(c_input))

    return Column.from_unique_ptr(move(c_result))
