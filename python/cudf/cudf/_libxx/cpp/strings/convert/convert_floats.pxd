# Copyright (c) 2020, NVIDIA CORPORATION.

from cudf._libxx.cpp.column.column cimport column
from cudf._libxx.cpp.column.column_view cimport column_view
from cudf._libxx.cpp.types cimport data_type

from libcpp.memory cimport unique_ptr

cdef extern from "cudf/strings/convert/convert_floats.hpp" namespace \
        "cudf::strings" nogil:
    cdef unique_ptr[column] to_floats(
        column_view input_col,
        data_type output_type) except +

    cdef unique_ptr[column] from_floats(
        column_view input_col) except +
