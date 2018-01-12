from weakref import WeakKeyDictionary
import functools

import numpy as np
from numba.utils import pysignature, exec_
from numba import six
from numba import cuda

from pygdf import cudautils


def apply_rows(df, func, incols, outcols, kwargs):
    applyrows = ApplyRowsCompiler(func, incols, outcols, kwargs)
    return applyrows.run(df)


def apply_chunks(df, func, incols, outcols, kwargs, chunks):
    applyrows = ApplyChunksCompiler(func, incols, outcols, kwargs)
    return applyrows.run(df, chunks=chunks)


class ApplyKernelCompilerBase(object):
    def __init__(self, func, incols, outcols, kwargs):
        # Get signature of user function
        sig = pysignature(func)
        self.sig = sig
        self.incols = incols
        self.outcols = outcols
        self.kwargs = kwargs
        self.kernel = self.compile(func, sig.parameters.keys(), kwargs.keys())

    def run(self, df, **launch_params):
        # Get input columns
        inputs = {k: df[k].to_gpu_array() for k in self.incols}
        # Allocate output columns
        outputs = {}
        for k, dt in self.outcols.items():
            outputs[k] = cuda.device_array(len(df), dtype=dt)
        # Bind argument
        args = {}
        for dct in [inputs, outputs, self.kwargs]:
            args.update(dct)
        bound = self.sig.bind(**args)
        # Launch kernel
        self.launch_kernel(df, bound.args, **launch_params)
        # Prepare output frame
        outdf = df.copy()
        for k in sorted(self.outcols):
            outdf[k] = outputs[k]
        return outdf


class ApplyRowsCompiler(ApplyKernelCompilerBase):

    def compile(self, func, argnames, extra_argnames):
        # Compile kernel
        kernel = _load_cache_or_make_row_wise_kernel(func, argnames,
                                                     extra_argnames)
        return kernel

    def launch_kernel(self, df, args):
        blksz = 64
        blkct = min(16, max(1, len(df) // blksz))
        self.kernel[blkct, blksz](*args)


class ApplyChunksCompiler(ApplyKernelCompilerBase):

    def compile(self, func, argnames, extra_argnames):
        # Compile kernel
        kernel = _load_cache_or_make_chunk_wise_kernel(func, argnames,
                                                       extra_argnames)
        return kernel

    def launch_kernel(self, df, args, chunks):
        chunks = self.normalize_chunks(len(df), chunks)
        print("chunks", chunks.copy_to_host())
        self.kernel.forall(chunks.size - 1)(chunks, *args)

    def normalize_chunks(self, size, chunks):
        if isinstance(chunks, six.integer_types):
            stride = min(int(chunks), size)
            return cudautils.arange(0, size + stride, stride)
        else:
            raise NotImplementedError


def _make_row_wise_kernel(func, argnames, extras):
    """
    Make a kernel that does a stride loop over the input columns.
    """
    # Build kernel source
    argnames = list(map(_mangle_user, argnames))
    extras = list(map(_mangle_user, extras))
    source = """
def row_wise_kernel({args}):
{body}
"""

    args = ', '.join(argnames)
    body = []

    body.append('tid = cuda.grid(1)')
    body.append('ntid = cuda.gridsize(1)')

    for a in argnames:
        if a not in extras:
            start = 'tid'
            stop = ''
            stride = 'ntid'
            srcidx = '{a} = {a}[{start}:{stop}:{stride}]'
            body.append(srcidx.format(a=a, start=start, stop=stop,
                                      stride=stride))

    body.append("inner({})".format(args))

    indented = ['{}{}'.format(' ' * 4, ln) for ln in body]
    # Finalize source
    concrete = source.format(args=args, body='\n'.join(indented))
    # Get bytecode
    glbs = {'inner': cuda.jit(device=True)(func),
            'cuda': cuda}
    exec_(concrete, glbs)
    # Compile as CUDA kernel
    kernel = cuda.jit(glbs['row_wise_kernel'])
    return kernel


def _make_chunk_wise_kernel(func, argnames, extras):
    # Build kernel source
    argnames = list(map(_mangle_user, argnames))
    extras = list(map(_mangle_user, extras))
    source = """
def chunk_wise_kernel(chunks, {args}):
{body}
"""

    args = ', '.join(argnames)
    body = []

    body.append('tid = cuda.grid(1)')
    body.append('ntid = cuda.gridsize(1)')

    # Escape condition
    body.append('if tid + 1 >= chunks.size: return')

    for a in argnames:
        if a not in extras:
            start = 'chunks[tid]'
            stop = 'chunks[tid + 1]'
            stride = ''
            srcidx = '{a} = {a}[{start}:{stop}:{stride}]'
            body.append(srcidx.format(a=a, start=start, stop=stop,
                                      stride=stride))

    body.append("inner({})".format(args))

    indented = ['{}{}'.format(' ' * 4, ln) for ln in body]
    # Finalize source
    concrete = source.format(args=args, body='\n'.join(indented))
    # Get bytecode
    glbs = {'inner': cuda.jit(device=True)(func),
            'cuda': cuda}
    exec_(concrete, glbs)
    # Compile as CUDA kernel
    kernel = cuda.jit(glbs['chunk_wise_kernel'])
    return kernel


_cache = WeakKeyDictionary()


@functools.wraps(_make_row_wise_kernel)
def _load_cache_or_make_row_wise_kernel(func, *args, **kwargs):
    """Caching version of ``_make_row_wise_kernel``.
    """
    try:
        return _cache[func]
    except KeyError:
        kernel = _make_row_wise_kernel(func, *args, **kwargs)
        _cache[func] = kernel
        return kernel


@functools.wraps(_make_chunk_wise_kernel)
def _load_cache_or_make_chunk_wise_kernel(func, *args, **kwargs):
    """Caching version of ``_make_row_wise_kernel``.
    """
    try:
        return _cache[func]
    except KeyError:
        kernel = _make_chunk_wise_kernel(func, *args, **kwargs)
        _cache[func] = kernel
        return kernel


def _mangle_user(name):
    """Mangle user variable name
    """
    return "__user_{}".format(name)
