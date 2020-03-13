# Copyright (c) 2020, NVIDIA CORPORATION.

from libcpp.memory cimport unique_ptr

from cudf._libxx.cpp.column.column cimport column
from cudf._libxx.cpp.column.column_view cimport column_view

cdef extern from "cudf/nvtext/normalize.hpp" namespace "nvtext" nogil:

    cdef unique_ptr[column] normalize_spaces(
        const column_view & strings
    ) except +
