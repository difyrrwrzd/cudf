from __future__ import division, print_function

import cupy
import numpy as np
import pandas as pd
import pytest

import cudf
import cudf._lib as libcudf
from cudf.core import Series
from cudf.core.column import column
from cudf.tests.utils import assert_eq


@pytest.mark.parametrize(
    "dtype",
    ["bool", "int8", "int16", "int32", "int64", "float32", "float64", "str"],
)
def test_repeat(dtype):
    arr = np.random.rand(10) * 10
    repeats = np.random.randint(10, size=10)
    psr = pd.Series(arr).astype(dtype)
    gsr = cudf.from_pandas(psr)

    assert_eq(psr.repeat(repeats), gsr.repeat(repeats))


def test_repeat_index():
    arrays = [[1, 1, 2, 2], ["red", "blue", "red", "blue"]]
    psr = pd.MultiIndex.from_arrays(arrays, names=("number", "color"))
    gsr = cudf.from_pandas(psr)
    repeats = np.random.randint(10, size=4)

    assert_eq(psr.repeat(repeats), gsr.repeat(repeats))


def test_repeat_dataframe():
    psr = pd.DataFrame({"a": [1, 1, 2, 2]})
    gsr = cudf.from_pandas(psr)
    repeats = np.random.randint(10, size=4)

    # pd.DataFrame doesn't have repeat() so as a workaround, we are
    # comparing pd.Series.repeat() with cudf.DataFrame.repeat()['a']
    assert_eq(psr["a"].repeat(repeats), gsr.repeat(repeats)["a"])


@pytest.mark.parametrize(
    "dtype", ["bool", "int8", "int16", "int32", "int64", "float32", "float64"]
)
def test_repeat_scalar(dtype):
    arr = np.random.rand(10) * 10
    repeats = 10
    psr = pd.Series(arr).astype(dtype)
    gsr = cudf.from_pandas(psr)

    assert_eq(psr.repeat(repeats), gsr.repeat(repeats))


def test_null_copy():
    col = Series(np.arange(2049))
    col[:] = None
    assert len(col) == 2049
