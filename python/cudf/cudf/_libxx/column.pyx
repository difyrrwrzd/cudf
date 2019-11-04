import numpy as np

from libc.stdint cimport uintptr_t
from libcpp.pair cimport pair
from libcpp cimport bool

cimport cudf._lib.cudf as gdf
import cudf._lib.cudf as gdf

from cudf._libxx.lib cimport *
from cudf.core.buffer import Buffer
from libc.stdlib cimport malloc, free

np_to_cudf_types = {np.dtype('int32'): INT32,
                    np.dtype('int64'): INT64,
                    np.dtype('float32'): FLOAT32,
                    np.dtype('float64'): FLOAT64}

cudf_to_np_types = {INT32: np.dtype('int32'),
                    INT64: np.dtype('int64'),
                    FLOAT32: np.dtype('float32'),
                    FLOAT64: np.dtype('float64')}


cdef class Column:
    def __init__(self, data, size, dtype, mask=None):
        self.data = data
        self.size = size
        self.dtype = dtype
        self.mask = mask

    @property
    def null_count(self):
        return self.null_count()
    
    cdef size_type null_count(self):
        return self.view().null_count()

    cdef mutable_column_view mutable_view(self) except *:
        cdef type_id tid = np_to_cudf_types[np.dtype(self.dtype)]
        cdef data_type dtype = data_type(tid)
        cdef void* data = <void*><uintptr_t>(self.data.ptr)
        cdef bitmask_type* mask
        if self.mask is not None:
            mask = <bitmask_type*><uintptr_t>(self.mask.ptr)
        else:
            mask = NULL
        return mutable_column_view(
            dtype,
            self.size,
            data,
            mask)

    cdef column_view view(self) except *:
        cdef type_id tid = np_to_cudf_types[np.dtype(self.dtype)]
        cdef data_type dtype = data_type(tid)
        cdef void* data = <void*><uintptr_t>(self.data.ptr)
        cdef bitmask_type* mask
        if self.mask is not None:
            mask = <bitmask_type*><uintptr_t>(self.mask.ptr)
        else:
            mask = NULL
        return column_view(
            dtype,
            self.size,
            data,
            mask)

    @staticmethod
    cdef Column from_ptr(unique_ptr[column] c_col):
        from cudf.core.column import build_column
        
        size = c_col.get()[0].size()
        dtype = cudf_to_np_types[c_col.get()[0].type().id()]
        has_nulls = c_col.get()[0].has_nulls()
        cdef column_contents contents = c_col.get()[0].release()
        data = DeviceBuffer.from_ptr(contents.data.release())
        if has_nulls:
            mask = DeviceBuffer.from_ptr(contents.null_mask.release())
        else:
            mask = None
        return build_column(data, size=size, dtype=dtype, mask=mask)

    
    cdef gdf.gdf_column* gdf_column_view(self) except *:
        cdef gdf.gdf_column* c_col = <gdf.gdf_column*>malloc(sizeof(gdf.gdf_column))
        cdef uintptr_t data_ptr
        cdef uintptr_t valid_ptr
        cdef uintptr_t category
        cdef gdf.gdf_dtype c_dtype = gdf.dtypes[self.dtype.type]

        if c_dtype == gdf.GDF_STRING_CATEGORY:
            raise NotImplementedError
        else:
            category = 0
            if len(self) > 0:
                data_ptr = self.data.ptr
            else:
                data_ptr = 0

        if self.mask:
            valid_ptr = self.mask.ptr
        else:
            valid_ptr = 0

        cdef char* c_col_name = gdf.py_to_c_str(self.name)
        cdef size_type len_col = len(self)
        cdef size_type c_null_count = self.null_count()
        cdef gdf.gdf_time_unit c_time_unit = gdf.np_dtype_to_gdf_time_unit(self.dtype)
        cdef gdf.gdf_dtype_extra_info c_extra_dtype_info = gdf.gdf_dtype_extra_info(
            time_unit=c_time_unit,
            category=<void*>category
        )

        with nogil:
            gdf.gdf_column_view_augmented(
                <gdf.gdf_column*>c_col,
                <void*>data_ptr,
                <gdf.valid_type*>valid_ptr,
                len_col,
                c_dtype,
                c_null_count,
                c_extra_dtype_info,
                c_col_name
            )

        return c_col
