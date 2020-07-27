# Copyright (c) 2020, NVIDIA CORPORATION.

from libcpp.string cimport string
from libcpp.vector cimport vector
from libcpp.map cimport map
from libcpp cimport bool
from libc.stdint cimport int32_t, int64_t
from cudf._lib.cpp.io.types cimport datasource
from libcpp.memory cimport unique_ptr
from cudf._lib.io.datasource cimport Datasource


cdef extern from "kafka_consumer.hpp" \
        namespace "cudf::io::external::kafka" nogil:

    cpdef cppclass kafka_consumer:

        kafka_consumer(map[string, string] configs,
                       string topic_name,
                       int32_t partition,
                       int64_t start_offset,
                       int64_t end_offset,
                       int32_t batch_timeout,
                       string delimiter) except +

        bool assign(vector[string] topics, vector[int] partitions) except +

        map[string, string] current_configs() except +

        bool commit_offset(string topic, int partition, int offset) except +

        int64_t get_committed_offset(string topic,
                                     int partition) except +

        map[string, int64_t] get_watermark_offset(string topic,
                                                  int partition,
                                                  int timeout,
                                                  bool cached) except +

        bool unsubscribe() except +

        bool close(int timeout) except +

cdef class KafkaDatasource(Datasource):

    cdef unique_ptr[datasource] c_datasource
    cdef map[string, string] kafka_configs
    cdef string topic
    cdef int32_t partition
    cdef int64_t start_offset
    cdef int64_t end_offset
    cdef int32_t batch_timeout
    cdef string delimiter

    cdef datasource* get_datasource(self) except +
