# Copyright (c) 2020, NVIDIA CORPORATION.

# cython: profile=False
# distutils: language = c++
# cython: embedsignature = True
# cython: language_level = 3

import pandas as pd

from cudf._libxx.lib cimport *
from cudf._libxx.column cimport Column
from cudf._libxx.table cimport Table
cimport cudf._libxx.includes.quantiles as cpp_quantiles


def quantiles(Table source_table, q, interp, is_input_sorted, column_order, null_precedence):
    cdef unique_ptr[table] c_result
    cdef table_view c_input = source_table.view()
    cdef vector[double] c_q
    cdef interpolation c_interp = <interpolation>(<interpolation_t> interp)
    cdef sorted c_is_input_sorted = <sorted>(<sorted_t> is_input_sorted)
    cdef vector[order] c_column_order
    cdef vector[null_order] c_null_precedence

    for value in column_order:
        c_column_order.push_back(
            <order>(<order_t> value)
        )

    for value in null_precedence:
        c_null_precedence.push_back(
            <null_order>(<null_order_t> value)
        )

    with nogil:
        c_result = move(
            cpp_quantiles.quantiles(
                c_input,
                c_q,
                c_interp,
                c_is_input_sorted,
                c_column_order,
                c_null_precedence
            )
        )

    return Table.from_unique_ptr(
        move(c_result),
        column_names=source_table._column_names,
        index_names=source_table._index._column_names
    )
