from cudf._libxx.cpp.types cimport data_type
from cudf._libxx.cpp.scalar.scalar cimport scalar
from cudf._libxx.cpp.column.column_view cimport column_view
from cudf._libxx.cpp.column.column cimport column
from cudf._libxx.scalar cimport Scalar
from cudf._libxx.aggregation cimport aggregation
from libcpp.memory cimport unique_ptr


cdef extern from "cudf/reduction.hpp" namespace "cudf::experimental" nogil:
    cdef unique_ptr[scalar] cpp_reduce "cudf::experimental::reduce" (
        column_view col,
        const unique_ptr[aggregation] agg,
        data_type type
    ) except +

    ctypedef enum scan_type:
        INCLUSIVE "cudf::experimental::scan_type::INCLUSIVE",
        EXCLUSIVE "cudf::experimental::scan_type::EXCLUSIVE",

    cdef unique_ptr[column] cpp_scan "cudf::experimental::scan" (
        column_view col,
        const unique_ptr[aggregation] agg,
        scan_type inclusive
    ) except +
