import numpy as np

from numba import cuda

from .buffer import Buffer
from .index import GenericIndex
from . import utils, cudautils
from .column import Column


class SeriesImpl(object):
    """
    Provides type-based delegation of operations on a Series.

    The ``Series`` class delegate the implementation of each operations
    to the a subclass of ``SeriesImpl``.  Depending of the dtype of the
    Series, it will load the corresponding implementation of the
    ``SeriesImpl``.
    """
    def __init__(self, dtype):
        self._dtype = dtype

    def __eq__(self, other):
        try:
            return self.dtype == other.dtype
        except Exception:
            return False

    def __ne__(self, other):
        return not self == other

    @property
    def dtype(self):
        return self._dtype

    # Methods below are all overridable

    # Categorical

    def cat(self, series):
        raise TypeError('not a categorical series')

    # Stats

    def stats(self, series):
        raise TypeError('stats function is not supported')

    # String

    def element_to_str(self, value):
        raise NotImplementedError

    # Operators

    def binary_operator(self, binop, lhs, rhs):
        raise NotImplementedError

    def unary_operator(self, unaryop, series):
        raise NotImplementedError

    # Comparators

    def unordered_compare(self, cmpop, lhs, rhs):
        raise NotImplementedError

    def ordered_compare(self, cmpop, lhs, rhs):
        raise NotImplementedError

    def normalize_compare_value(self, series, other):
        """Normalize the *other* value in a comparison when it is not a Series
        """
        raise NotImplementedError

    # Indexing

    def element_indexing(self, series, value):
        raise NotImplementedError


def empty_like(df, dtype=None, masked=None, impl=None):
    """Create a new empty Series with the same length.
    Note: Both the data and mask buffer are empty.

    Parameters
    ----------
    dtype : np.dtype like; defaults to None
        The dtype of the data buffer.
        Defaults to the same dtype as this.
    masked : bool; defaults to None
        Whether to allocate a mask array.
        Defaults to the same as this.
    impl : SeriesImpl; defaults to None
        The SeriesImpl to use for operation delegation.
        Defaults to ``get_default_impl(dtype)``.
    """
    # Prepare args
    if dtype is None:
        dtype = df.data.dtype
    if masked is None:
        masked = df.has_null_mask
    if impl is None:
        impl = get_default_impl(dtype)
    # Real work
    data = cuda.device_array(shape=len(df), dtype=dtype)
    params = dict(data=Buffer(data))
    if masked:
        mask = utils.make_mask(data.size)
        params.update(dict(mask=Buffer(mask), null_count=data.size))

    col = impl.shim_wrap_column(Column(**params))
    return df._copy_construct(data=col, impl=impl)


def empty_like_same_mask(df, dtype=None, impl=None):
    """Create a new empty Series with the same length and the same mask.

    Parameters
    ----------
    dtype : np.dtype like; defaults to None
        The dtype of the data buffer.
        Defaults to the same dtype as this.
    impl : SeriesImpl; defaults to None
        The SeriesImpl to use for operation delegation.
        Defaults to ``get_default_impl(dtype)``.
    """

    # Prepare args
    if dtype is None:
        dtype = df.data.dtype
    if impl is None:
        impl = get_default_impl(dtype)
    # Real work
    data = cuda.device_array(shape=len(df), dtype=dtype)
    params = dict(data=Buffer(data))
    if df.has_null_mask:
        params.update(mask=df.nullmask)
    col = Column(**params)
    return df._copy_construct(data=col, impl=impl)


def get_default_impl(dtype):
    """
    Returns the default SeriesImpl for the given dtype.
    """
    from .numerical import NumericalSeriesImpl

    return NumericalSeriesImpl(dtype)


def element_indexing(series, index):
    """Default implementation for indexing to an element

    Raises
    ------
    ``IndexError`` if out-of-bound
    """
    val = series.data[index]  # this raises IndexError
    valid = (cudautils.mask_get.py_func(series.nullmask, index)
             if series.has_null_mask else True)
    return val if valid else None


def select_by_boolmask(series, boolmask):
    """Select by a boolean mask to a series
    """
    assert not series.has_null_mask
    boolbits = cudautils.compact_mask_bytes(boolmask.to_gpu_array())
    indices = cudautils.arange(len(boolmask))
    _, selinds = cudautils.copy_to_dense(indices, mask=boolbits)
    _, selvals = cudautils.copy_to_dense(series.to_gpu_array(), mask=boolbits)

    assert not series.has_null_mask   # the nullmask needs to be recomputed

    params = dict(data=Column(Buffer(selvals)), impl=series._impl,
                  index=GenericIndex(selinds))

    return series._copy_construct(**params)


class ColumnOps(Column):
    def __init__(self, **kwargs):
        dtype = kwargs.pop('dtype')
        super(ColumnOps, self).__init__(**kwargs)
        # Logical dtype
        self._dtype = dtype

    @property
    def dtype(self):
        return self._dtype

    def _replace_defaults(self):
        params = super(ColumnOps, self)._replace_defaults()
        params.update(dict(dtype=self._dtype))
        return params


def column_empty_like(column, dtype, masked):
    """Allocate a new column like the given *column*
    """
    data = cuda.device_array(shape=len(column), dtype=dtype)
    params = dict(data=Buffer(data))
    if masked:
        mask = utils.make_mask(data.size)
        params.update(dict(mask=Buffer(mask), null_count=data.size))
    return Column(**params)


def column_empty_like_same_mask(column, dtype=None):
    """Create a new empty Column with the same length and the same mask.

    Parameters
    ----------
    dtype : np.dtype like; defaults to None
        The dtype of the data buffer.
        Defaults to the same dtype as this.
    """

    # Prepare args
    if dtype is None:
        dtype = column.data.dtype
    # Real work
    data = cuda.device_array(shape=len(column), dtype=dtype)
    params = dict(data=Buffer(data))
    if column.has_null_mask:
        params.update(mask=column.nullmask)
    return Column(**params)
