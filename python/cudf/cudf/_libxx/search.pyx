# Copyright (c) 2020, NVIDIA CORPORATION.

from cudf._libxx.lib cimport *
from cudf._libxx.column cimport Column
from cudf._libxx.table cimport Table
from libcpp.vector cimport vector
cimport cudf._libxx.includes.search as cpp_search


def search_sorted(
    Table table, Table values, side, ascending=True, na_position="last"
):
    """Find indices where elements should be inserted to maintain order

    Parameters
    ----------
    table : Table
        Table to search in
    values : Table
        Table of values to search for
    side : str {‘left’, ‘right’} optional
        If ‘left’, the index of the first suitable location is given.
        If ‘right’, return the last such index
    """
    cdef unique_ptr[column] c_result
    cdef vector[order] c_column_order
    cdef vector[null_order] c_null_precedence
    cdef order c_order
    cdef null_order c_null_order

    # Note: We are ignoring index columns here
    c_order = order.ASCENDING if ascending else order.DESCENDING
    c_null_order = (
        null_order.AFTER if na_position=="last" else null_order.BEFORE
    )
    for i in range(table._num_columns):
        c_column_order.push_back(c_order)
        c_null_precedence.push_back(c_null_order)

    if side == 'left':
        c_result = (
            cpp_search.lower_bound(
                table.data_view(),
                values.data_view(),
                c_column_order,
                c_null_precedence,
            )
        )
    elif side == 'right':
        c_result = (
            cpp_search.upper_bound(
                table.data_view(),
                values.data_view(),
                c_column_order,
                c_null_precedence,
            )
        )
    return Column.from_unique_ptr(move(c_result))


def contains(Column haystack, Column needles):
    """Check whether column contains multiple values

    Parameters
    ----------
    column : NumericalColumn
        Column to search in
    needles :
        A column of values to search for
    """
    cdef unique_ptr[column] c_result

    c_result = cpp_search.contains(
        haystack.view(),
        needles.view(),
    )
    return Column.from_unique_ptr(move(c_result))
