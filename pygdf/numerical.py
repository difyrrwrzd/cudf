from __future__ import print_function, division

import numpy as np
import pandas as pd

from libgdf_cffi import libgdf

from . import _gdf, series_impl, utils, cudautils
from .column import Column
from .buffer import Buffer


# Operator mappings

#   Unordered comparators
_unordered_impl = {
    'eq': libgdf.gdf_eq_generic,
    'ne': libgdf.gdf_ne_generic,
}

#   Ordered comparators
_ordered_impl = {
    'lt': libgdf.gdf_lt_generic,
    'le': libgdf.gdf_le_generic,
    'gt': libgdf.gdf_gt_generic,
    'ge': libgdf.gdf_ge_generic,
}

#   Binary operators
_binary_impl = {
    'add': libgdf.gdf_add_generic,
    'sub': libgdf.gdf_sub_generic,
    'mul': libgdf.gdf_mul_generic,
    'floordiv': libgdf.gdf_floordiv_generic,
    'truediv': libgdf.gdf_div_generic,
}

#   Unary operators
_unary_impl = {
    'ceil': libgdf.gdf_ceil_generic,
    'floor': libgdf.gdf_floor_generic,
}


class NumericalSeriesImpl(series_impl.SeriesImpl):
    """
    Implements operations for numerical Series.
    """
    def __init__(self, dtype):
        super(NumericalSeriesImpl, self).__init__(dtype)

    def stats(self, series):
        return Stats(series)

    def element_to_str(self, value):
        return str(value)

    def binary_operator(self, binop, lhs, rhs):
        fn = _binary_impl[binop]
        return self._call_binop(lhs, rhs, fn, self.dtype)

    def unary_operator(self, unaryop, series):
        return self._call_unaryop(series, _unary_impl[unaryop], self.dtype)

    def unordered_compare(self, cmpop, lhs, rhs):
        return self._compare(lhs, rhs, fn=_unordered_impl[cmpop])

    def ordered_compare(self, cmpop, lhs, rhs):
        return self._compare(lhs, rhs, fn=_ordered_impl[cmpop])

    def normalize_compare_value(self, series, other):
        if np.min_scalar_type(other).kind in 'biuf':
            ary = utils.scalar_broadcast_to(other, shape=len(series))
            sr = series.from_any(ary)
            return sr
        return NotImplemented

    def element_indexing(self, series, index):
        return series_impl.element_indexing(series, index)

    def sort_by_values(self, series, ascending):
        from .series import Series

        if series._column.mask:
            raise ValueError('masked array not supported')
        col = Column(series._column.data.copy())
        sr_key = series._copy_construct(data=col, impl=self)
        sr_inds = Series.from_array(cudautils.arange(len(sr_key),
                                    dtype=np.int64))
        _gdf.apply_sort(sr_key, sr_inds, ascending=ascending)
        return sr_key, sr_inds

    def as_index(self, series):
        from .index import RangeIndex

        return series.set_index(RangeIndex(len(series)))

    def to_pandas(self, series, index=True):
        if index is True:
            index = series.index.to_pandas()
        return pd.Series(series.to_array(fillna='pandas'), index=index)

    def shim_wrap_column(self, column):
        return column.view(NumericalColumn, dtype=column.dtype)

    #
    # Internals
    #

    def _compare(self, lhs, rhs, fn):
        """
        Internal util to call a comparison operator *fn*
        comparing *lhs* and *rhs*.  Return the output Series.
        The output dtype is always `np.bool_`.
        """
        return self._call_binop(lhs, rhs, fn, np.bool_)

    def _call_binop(self, lhs, rhs, fn, out_dtype):
        """
        Internal util to call a binary operator *fn* on operands *lhs*
        and *rhs* with output dtype *out_dtype*.  Returns the output
        Series.
        """
        # Allocate output series
        masked = lhs.has_null_mask or rhs.has_null_mask
        out = series_impl.empty_like(lhs, dtype=out_dtype, masked=masked,
                                     impl=NumericalSeriesImpl(out_dtype))
        # Call and fix null_count
        out._null_count = _gdf.apply_binaryop(fn, lhs, rhs, out)
        return out

    def _call_unaryop(self, series, fn, out_dtype):
        """
        Internal util to call a unary operator *fn* on operands *self* with
        output dtype *out_dtype*.  Returns the output Series.
        """
        # Allocate output series
        out = series_impl.empty_like_same_mask(series, dtype=out_dtype)
        _gdf.apply_unaryop(fn, series, out)
        return out


class Stats(object):
    def __init__(self, series):
        self._series = series

    def min(self):
        return _gdf.apply_reduce(libgdf.gdf_min_generic, self._series)

    def max(self):
        return _gdf.apply_reduce(libgdf.gdf_max_generic, self._series)

    def sum(self):
        dt = np.promote_types('i8', self._series.dtype)
        x = self._series.astype(dt)
        return _gdf.apply_reduce(libgdf.gdf_sum_generic, x)

    def mean(self):
        return self.sum().astype('f8') / self._series.valid_count

    def mean_var(self):
        x = self._series.astype('f8')
        mu = x.mean()
        n = x.valid_count
        asum = _gdf.apply_reduce(libgdf.gdf_sum_squared_generic, x)
        var = asum / n - mu ** 2
        return mu, var


class NumericalColumn(series_impl.ColumnOps):
    @property
    def shim_impl(self):
        return NumericalSeriesImpl(self.dtype)

    def binary_operator(self, binop, rhs):
        if isinstance(rhs, NumericalColumn):
            op = _binary_impl[binop]
            print('dtype = ', self.dtype)
            return numeric_column_binop(lhs=self, rhs=rhs, op=op,
                                        out_dtype=self.dtype)
        else:
            return NotImplemented

    def unary_operator(self, unaryop):
        return numeric_column_unaryop(self, op=_unary_impl[unaryop],
                                      out_dtype=self.dtype)

    def unordered_compare(self, cmpop, rhs):
        return numeric_column_compare(self, rhs, op=_unordered_impl[cmpop])

    def ordered_compare(self, cmpop, rhs):
        return numeric_column_compare(self, rhs, op=_ordered_impl[cmpop])

    def normalize_compare_value(self, other):
        if np.min_scalar_type(other).kind in 'biuf':
            ary = utils.scalar_broadcast_to(other, shape=len(self))
            return self.replace(data=Buffer(ary), dtype=ary.dtype)
        else:
            raise TypeError('cannot broadcast {}'.format(type(other)))

    @property
    def stats(self):
        return ColumnStats(self)

    def astype(self, dtype):
        if self.dtype == dtype:
            return self
        else:
            col = self.replace(data=self.data.astype(dtype),
                               dtype=dtype)
            return col


class ColumnStats(object):
    def __init__(self, column):
        self._column = column

    def min(self):
        return _gdf.apply_reduce(libgdf.gdf_min_generic, self._column)

    def max(self):
        return _gdf.apply_reduce(libgdf.gdf_max_generic, self._column)

    def sum(self):
        dt = np.promote_types('i8', self._column.dtype)
        x = self._column.astype(dt)
        return _gdf.apply_reduce(libgdf.gdf_sum_generic, x)

    def mean(self):
        return self.sum().astype('f8') / self._column.valid_count

    def mean_var(self):
        x = self._column.astype('f8')
        mu = x.mean()
        n = x.valid_count
        asum = _gdf.apply_reduce(libgdf.gdf_sum_squared_generic, x)
        var = asum / n - mu ** 2
        return mu, var


def numeric_column_binop(lhs, rhs, op, out_dtype):
     # Allocate output series
    masked = lhs.has_null_mask or rhs.has_null_mask
    impl = NumericalSeriesImpl(out_dtype)
    out = series_impl.column_empty_like(lhs, dtype=out_dtype, masked=masked)
    # Call and fix null_count
    null_count = _gdf.apply_binaryop(op, lhs, rhs, out)
    out = out.replace(null_count=null_count)
    return impl.shim_wrap_column(out)


def numeric_column_unaryop(operand, op, out_dtype):
    out = series_impl.column_empty_like_same_mask(operand, dtype=out_dtype)
    _gdf.apply_unaryop(op, operand, out)
    impl = NumericalSeriesImpl(out_dtype)
    return impl.shim_wrap_column(out)


def numeric_column_compare(lhs, rhs, op):
    return numeric_column_binop(lhs, rhs, op, out_dtype=np.bool_)
