from functools import partial

import numpy as np

from numba import (cuda, njit, uint64, int32, float64, numpy_support)

from .utils import mask_bitsize, mask_get, mask_set, make_mask
from .sorting import RadixSort


def to_device(ary):
    dary, _ = cuda._auto_device(ary)
    return dary


# GPU array initializer

@cuda.jit
def gpu_arange(start, size, step, out):
    i = cuda.grid(1)
    if i < size:
        out[i] = i * step + start


def arange(start, stop=None, step=1, dtype=np.int64):
    if stop is None:
        start, stop = 0, start
    size = (stop - start + (step - 1)) // step
    out = cuda.device_array(size, dtype=dtype)
    gpu_arange.forall(size)(start, size, step, out)
    return out


@cuda.jit
def gpu_arange_reversed(size, out):
    i = cuda.grid(1)
    if i < size:
        out[i] = size - i - 1


def arange_reversed(size, dtype=np.int64):
    out = cuda.device_array(size, dtype=dtype)
    gpu_arange_reversed.forall(size)(size, out)
    return out


@cuda.jit
def gpu_ones(size, out):
    i = cuda.grid(1)
    if i < size:
        out[i] = 1


def ones(size, dtype):
    out = cuda.device_array(size, dtype=dtype)
    gpu_ones.forall(size)(size, out)
    return out


# GPU array type casting


@cuda.jit
def gpu_copy(inp, out):
    tid = cuda.grid(1)
    if tid < out.size:
        out[tid] = inp[tid]


def astype(ary, dtype):
    if ary.dtype == np.dtype(dtype):
        return ary
    else:
        out = cuda.device_array(shape=ary.shape, dtype=dtype)
        configured = gpu_copy.forall(out.size)
        configured(ary, out)
        return out


def copy_array(arr, out=None):
    if out is None:
        out = cuda.device_array_like(arr)
    assert out.size == arr.size
    if arr.is_c_contiguous() and out.is_c_contiguous():
        out.copy_to_device(arr)
    else:
        gpu_copy.forall(out.size)(arr, out)
    return out


def as_contiguous(arr):
    assert arr.ndim == 1
    out = cuda.device_array(shape=arr.shape, dtype=arr.dtype)
    return copy_array(arr, out=out)


# Copy column into a matrix

@cuda.jit
def gpu_copy_column(matrix, colidx, colvals):
    tid = cuda.grid(1)
    if tid < colvals.size:
        matrix[colidx, tid] = colvals[tid]


def copy_column(matrix, colidx, colvals):
    assert matrix.shape[1] == colvals.size
    configured = gpu_copy_column.forall(colvals.size)
    configured(matrix, colidx, colvals)


# Mask utils

@cuda.jit
def gpu_set_mask_from_stride(mask, stride):
    bitsize = mask_bitsize
    tid = cuda.grid(1)
    if tid < mask.size:
        base = tid * bitsize
        val = 0
        for shift in range(bitsize):
            idx = base + shift
            bit = (idx % stride) == 0
            val |= bit << shift
        mask[tid] = val


def set_mask_from_stride(mask, stride):
    taskct = mask.size
    configured = gpu_set_mask_from_stride.forall(taskct)
    configured(mask, stride)


@cuda.jit
def gpu_copy_to_dense(data, mask, slots, out):
    tid = cuda.grid(1)
    if tid < data.size and mask_get(mask, tid):
        idx = slots[tid]
        out[idx] = data[tid]


@cuda.jit
def gpu_fill_value(data, value):
    tid = cuda.grid(1)
    if tid < data.size:
        data[tid] = value


@cuda.jit
def gpu_expand_mask_bits(bits, out):
    """Expand each bits in bitmask *bits* into an element in out.
    This is a flexible kernel that can be launch with any number of blocks
    and threads.
    """
    for i in range(cuda.grid(1), out.size, cuda.gridsize(1)):
        out[i] = mask_get(bits, i)


def mask_assign_slot(size, mask):
    from . import _gdf

    dtype = (np.int32 if size < 2 ** 31 else np.int64)
    expanded_mask = cuda.device_array(size, dtype=dtype)
    numtasks = min(64 * 128, expanded_mask.size)
    gpu_expand_mask_bits.forall(numtasks)(mask, expanded_mask)

    # Allocate output
    slots = cuda.device_array(shape=expanded_mask.size + 1,
                              dtype=expanded_mask.dtype)

    # Fill 0 to slot[0]
    gpu_fill_value[1, 1](slots[:1], 0)

    # Compute prefixsum on the mask
    col_slots = _gdf.columnview_from_devary(slots[1:])
    col_mask = _gdf.columnview_from_devary(expanded_mask)
    _gdf.apply_prefixsum(col_mask, col_slots, inclusive=True)

    sz = int(slots[slots.size - 1])
    return slots, sz


def count_nonzero_mask(mask):
    # TODO: this needs optimization
    _, nnz = mask_assign_slot(mask.size * mask_bitsize, mask)
    return nnz


def copy_to_dense(data, mask, out=None):
    """Copy *data* with validity bits in *mask* into *out*.

    The output array can be specified in `out`.

    Return a 2-tuple of:
    * number of non-null element
    * a dense gpu array given the data and mask gpu arrays.
    """
    slots, sz = mask_assign_slot(size=data.size, mask=mask)
    if out is None:
        # output buffer is not provided
        # allocate one
        alloc_shape = sz
        out = cuda.device_array(shape=alloc_shape, dtype=data.dtype)
    else:
        # output buffer is provided
        # check it
        if sz >= out.size:
            raise ValueError('output array too small')
    gpu_copy_to_dense.forall(data.size)(data, mask, slots, out)
    return (sz, out)


@cuda.jit
def gpu_compact_mask_bytes(bools, bits):
    tid = cuda.grid(1)
    base = tid * mask_bitsize
    for i in range(base, base + mask_bitsize):
        if i >= bools.size:
            break
        if bools[i]:
            mask_set(bits, i)


def compact_mask_bytes(boolbytes):
    """Convert booleans (in bytes) to a bitmask
    """
    bits = make_mask(boolbytes.size)
    # Fill zero
    gpu_fill_value.forall(bits.size)(bits, 0)
    # Compact
    gpu_compact_mask_bytes.forall(bits.size)(boolbytes, bits)
    return bits


#
# Gather
#


@cuda.jit
def gpu_gather(data, index, out):
    i = cuda.grid(1)
    if i < index.size:
        idx = index[i]
        # Only do it if the index is in range
        if 0 <= idx < data.size:
            out[i] = data[idx]


def gather(data, index, out=None):
    """Perform ``out = data[index]`` on the GPU
    """
    if out is None:
        out = cuda.device_array(shape=index.size, dtype=data.dtype)
    gpu_gather.forall(index.size)(data, index, out)
    return out


@cuda.jit
def gpu_gather_joined_index(lkeys, rkeys, lidx, ridx, out):
    gid = cuda.grid(1)
    if gid < lidx.size:
        # Try getting from the left side first
        pos = lidx[gid]
        if pos != -1:
            # Get from left
            out[gid] = lkeys[pos]
        else:
            # Get from right
            pos = ridx[gid]
            out[gid] = rkeys[pos]


def gather_joined_index(lkeys, rkeys, lidx, ridx):
    assert lidx.size == ridx.size
    out = cuda.device_array(lidx.size, dtype=lkeys.dtype)
    gpu_gather_joined_index.forall(lidx.size)(lkeys, rkeys, lidx, ridx, out)
    return out


def reverse_array(data, out=None):
    rinds = arange_reversed(data.size)
    out = gather(data=data, index=rinds, out=out)
    return out


#
# Fill NA
#


@cuda.jit
def gpu_fill_masked(value, validity, out):
    tid = cuda.grid(1)
    if tid < out.size:
        valid = mask_get(validity, tid)
        if not valid:
            out[tid] = value


def fillna(data, mask, value):
    out = cuda.device_array_like(data)
    out.copy_to_device(data)
    configured = gpu_fill_masked.forall(data.size)
    configured(value, mask, out)
    return out


#
# Binary kernels
#

@cuda.jit
def gpu_equal_constant(arr, val, out):
    i = cuda.grid(1)
    if i < out.size:
        out[i] = (arr[i] == val)


def apply_equal_constant(arr, val, dtype):
    out = cuda.device_array(shape=arr.size, dtype=dtype)
    configured = gpu_equal_constant.forall(out.size)
    configured(arr, val, out)
    return out


@cuda.jit
def gpu_scale(arr, vmin, vmax, out):
    i = cuda.grid(1)
    if i < out.size:
        val = arr[i]
        out[i] = (val - vmin) / (vmax - vmin)


def compute_scale(arr, vmin, vmax):
    out = cuda.device_array(shape=arr.size, dtype=np.float64)
    configured = gpu_scale.forall(out.size)
    configured(arr, vmin, vmax, out)
    return out


#
# Misc kernels
#


@cuda.jit(device=True)
def gpu_unique_set_insert(vset, sz, val):
    """
    Insert *val* into the *vset* of size *sz*.
    Returns:
        *   -1: out-of-space
        * >= 0: the new size
    """
    for i in range(sz):
        # value matches, so return current size
        if vset[i] == val:
            return sz

    if sz > 0:
        i += 1
    # insert at next available slot
    if i < vset.size:
        vset[i] = val
        return sz + 1

    # out of space
    return -1


MAX_FAST_UNIQUE_K = 2 * 1024


class UniqueK(object):
    _cached_kernels = {}

    def __init__(self, dtype):
        dtype = np.dtype(dtype)
        self._kernel = self._get_kernel(dtype)

    @classmethod
    def _get_kernel(cls, dtype):
        try:
            return cls._cached_kernels[dtype]
        except KeyError:
            return cls._compile(dtype)

    @classmethod
    def _compile(cls, dtype):
        nbtype = numpy_support.from_dtype(dtype)

        @cuda.jit
        def gpu_unique_k(arr, k, out, outsz_ptr):
            """
            Note: run with small blocks.
            """
            tid = cuda.threadIdx.x
            blksz = cuda.blockDim.x
            base = 0

            # shared memory
            vset_size = 0
            sm_mem_size = MAX_FAST_UNIQUE_K
            vset = cuda.shared.array(sm_mem_size, dtype=nbtype)
            share_vset_size = cuda.shared.array(1, dtype=int32)
            share_loaded = cuda.shared.array(sm_mem_size, dtype=nbtype)
            sm_mem_size = min(k, sm_mem_size)

            while vset_size < sm_mem_size and base < arr.size:
                pos = base + tid
                valid_load = min(blksz, arr.size - base)
                # load
                if tid < valid_load:
                    share_loaded[tid] = arr[pos]
                # wait for load to complete
                cuda.syncthreads()
                # thread-0 inserts
                if tid == 0:
                    for i in range(valid_load):
                        val = share_loaded[i]
                        new_size = gpu_unique_set_insert(vset, vset_size, val)
                        if new_size >= 0:
                            vset_size = new_size
                        else:
                            vset_size = sm_mem_size + 1
                    share_vset_size[0] = vset_size
                # wait until the insert is done
                cuda.syncthreads()
                vset_size = share_vset_size[0]
                # increment
                base += blksz

            # output
            if vset_size <= sm_mem_size:
                for i in range(tid, vset_size, blksz):
                    out[i] = vset[i]
                if tid == 0:
                    outsz_ptr[0] = vset_size
            else:
                outsz_ptr[0] = -1

        # cache
        cls._cached_kernels[dtype] = gpu_unique_k
        return gpu_unique_k

    def run(self, arr, k):
        if k >= MAX_FAST_UNIQUE_K:
            raise NotImplementedError('k >= {}'.format(MAX_FAST_UNIQUE_K))
        # setup mem
        outsz_ptr = cuda.device_array(shape=1, dtype=np.intp)
        out = cuda.device_array_like(arr)
        # kernel
        self._kernel[1, 64](arr, k, out, outsz_ptr)
        # copy to host
        unique_ct = outsz_ptr.copy_to_host()[0]
        if unique_ct < 0:
            raise ValueError('too many unique value (hint: increase k)')
        else:
            hout = out.copy_to_host()
            return hout[:unique_ct]


@cuda.jit
def gpu_diff(arr, out):
    """
    Comptute out[i] = arr[i] - arr[i - 1] for i > 0.
             out[0] = 1
    """
    i = cuda.grid(1)
    if i == 0:
        out[i] = True
    if 0 < i < out.size:
        out[i] = bool(arr[i] - arr[i - 1])


@cuda.jit
def gpu_insert_if_masked(arr, mask, out_idx, out_queue):
    i = cuda.grid(1)
    if i < arr.size:
        diff = mask[i]
        if diff:
            wridx = cuda.atomic.add(out_idx, 0, 1)
            if wridx < out_queue.size:
                out_queue[wridx] = arr[i]


class UniqueBySorting(object):
    """
    Compute unique element in an array by sorting
    """
    def __init__(self, maxcount, k, dtype):
        dtype = np.dtype(dtype)
        self._maxcount = maxcount
        self._dtype = dtype
        self._maxk = k
        self._sorter = RadixSort(maxcount=maxcount, dtype=dtype)

    def run_sort(self, arr):
        self._sorter.sort(arr)

    def run_diff(self, arr):
        out = cuda.device_array(shape=arr.size, dtype=np.intp)
        gpu_diff.forall(out.size)(arr, out)
        return out

    def run_gather(self, arr, diffs):
        h_out_idx = np.zeros(1, dtype=np.intp)
        out_queue = cuda.device_array(shape=self._maxk, dtype=arr.dtype)
        gpu_insert_if_masked.forall(arr.size)(arr, diffs, h_out_idx, out_queue)
        qsz = h_out_idx[0]
        if self._maxk >= 0:
            if qsz > self._maxk:
                msg = 'too many unique value: unique values ({}) > k ({})'
                raise ValueError(msg.format(qsz, self._maxk))
            end = min(qsz, self._maxk)
        else:
            raise NotImplementedError('k is unbounded')
        vals = out_queue[:end]
        return vals

    def run(self, arr):
        if arr.size > self._maxcount:
            raise ValueError("`arr.size` >= maxcount")
        copied = copy_array(arr)
        self.run_sort(copied)
        diffs = self.run_diff(copied)
        return self.run_gather(copied, diffs)


def compute_unique_k(arr, k):
    # return UniqueK(arr.dtype).run(arr, k)
    return UniqueBySorting(maxcount=arr.size, dtype=arr.dtype, k=k).run(arr)


# Find segments

@cuda.jit
def gpu_mark_segment_begins(arr, markers):
    i = cuda.grid(1)
    if i == 0:
        markers[0] = 1
    if 0 < i < markers.size:
        markers[i] = arr[i] != arr[i - 1]


@cuda.jit
def gpu_scatter_segment_begins(markers, scanned, begins):
    i = cuda.grid(1)
    if i < markers.size:
        if markers[i]:
            idx = scanned[i]
            begins[idx] = i


def find_segments(arr):
    markers = cuda.device_array(arr.size, dtype=np.int8)
    gpu_mark_segment_begins.forall(markers.size)(arr, markers)
    # FIXME: slow scan begin
    scanned = np.cumsum(markers.copy_to_host().astype(np.int32)) - 1
    ct = scanned[-1] + 1
    # FIXME: slow scan end
    begins = cuda.device_array(shape=int(ct), dtype=np.intp)
    gpu_scatter_segment_begins.forall(markers.size)(markers, scanned, begins)
    return begins
