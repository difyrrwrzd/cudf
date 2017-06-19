from numba import cuda

from .dataframe import Buffer
from . import utils


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
        return self.dtype == other.dtype

    def __ne__(self, other):
        out = self.dtype == other.dtype
        if out is NotImplemented:
            return out
        return not out

    @property
    def dtype(self):
        return self._dtype

    # Methods below are all overridable

    def cat(self, series):
        raise TypeError('not a categorical series')

    def element_to_str(self, value):
        raise NotImplementedError

    def binary_operator(self, binop, lhs, rhs):
        raise NotImplementedError

    def unary_operator(self, unaryop, series):
        raise NotImplementedError

    def unordered_compare(self, cmpop, lhs, rhs):
        raise NotImplementedError

    def ordered_compare(self, cmpop, lhs, rhs):
        raise NotImplementedError


def empty_like(df, dtype=None, masked=None, impl=None):
    """Create a new empty Series with the same length.

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
        Defaults to the same as this.
    """
    # Prepare args
    if dtype is None:
        dtype = df.data.dtype
    if masked is None:
        masked = df.has_null_mask
    if impl is None:
        impl = df._impl
    # Real work
    data = cuda.device_array(shape=len(df), dtype=dtype)
    params = dict(buffer=Buffer(data), dtype=dtype, impl=impl)
    if masked:
        mask_size = utils.calc_chunk_size(data.size, utils.mask_bitsize)
        mask = cuda.device_array(shape=mask_size, dtype=utils.mask_dtype)
        params.update(dict(mask=Buffer(mask), null_count=data.size))
    return df._copy_construct(**params)
