# Copyright (c) 2020, NVIDIA CORPORATION.

from libcpp.memory cimport unique_ptr
from cudf._lib.cpp.io.types cimport datasource

cdef class Datasource:

    def __init__(self, datasource):
        self.c_datasource = datasource
