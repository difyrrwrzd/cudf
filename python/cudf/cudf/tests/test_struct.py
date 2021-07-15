# Copyright (c) 2020, NVIDIA CORPORATION.

import numpy as np
import pandas as pd
import pyarrow as pa
import pytest

import cudf
from cudf.core.dtypes import StructDtype
from cudf.testing._utils import assert_eq


@pytest.mark.parametrize(
    "data",
    [
        [{}],
        [{"a": None}],
        [{"a": 1}],
        [{"a": "one"}],
        [{"a": 1}, {"a": 2}],
        [{"a": 1, "b": "one"}, {"a": 2, "b": "two"}],
        [{"b": "two", "a": None}, None, {"a": "one", "b": "two"}],
    ],
)
def test_create_struct_series(data):
    expect = pd.Series(data)
    got = cudf.Series(data)
    assert_eq(expect, got, check_dtype=False)


def test_struct_of_struct_copy():
    sr = cudf.Series([{"a": {"b": 1}}])
    assert_eq(sr, sr.copy())


def test_struct_of_struct_loc():
    df = cudf.DataFrame({"col": [{"a": {"b": 1}}]})
    expect = cudf.Series([{"a": {"b": 1}}], name="col")
    assert_eq(expect, df["col"])


@pytest.mark.parametrize(
    "key, expect", [(0, [1, 3]), (1, [2, 4]), ("a", [1, 3]), ("b", [2, 4])]
)
def test_struct_for_field(key, expect):
    sr = cudf.Series([{"a": 1, "b": 2}, {"a": 3, "b": 4}])
    expect = cudf.Series(expect)
    got = sr.struct.field(key)
    assert_eq(expect, got)


@pytest.mark.parametrize("input_obj", [[{"a": 1, "b": cudf.NA, "c": 3}]])
def test_series_construction_with_nulls(input_obj):
    expect = pa.array(input_obj, from_pandas=True)
    got = cudf.Series(input_obj).to_arrow()

    assert expect == got


@pytest.mark.parametrize(
    "fields",
    [
        {"a": np.dtype(np.int64)},
        {"a": np.dtype(np.int64), "b": None},
        {
            "a": cudf.ListDtype(np.dtype(np.int64)),
            "b": cudf.Decimal64Dtype(1, 0),
        },
        {
            "a": cudf.ListDtype(cudf.StructDtype({"b": np.dtype(np.int64)})),
            "b": cudf.ListDtype(cudf.ListDtype(np.dtype(np.int64))),
        },
    ],
)
def test_serialize_struct_dtype(fields):
    dtype = cudf.StructDtype(fields)
    recreated = dtype.__class__.deserialize(*dtype.serialize())
    assert recreated == dtype


@pytest.mark.parametrize(
    "series, expected",
    [
        (
            [
                {"a": "Hello world", "b": []},
                {"a": "CUDF", "b": [1, 2, 3], "c": 1},
                {},
            ],
            {"a": "Hello world", "b": [], "c": cudf.NA},
        ),
        ([{}], {}),
        (
            [{"b": True}, {"a": 1, "c": [1, 2, 3], "d": "1", "b": False}],
            {"a": cudf.NA, "c": cudf.NA, "d": cudf.NA, "b": True},
        ),
    ],
)
def test_struct_getitem(series, expected):
    sr = cudf.Series(series)
    assert sr[0] == expected


@pytest.mark.parametrize(
    "data, item",
    [
        (
            [
                {"a": "Hello world", "b": []},
                {"a": "CUDF", "b": [1, 2, 3], "c": cudf.NA},
                {"a": "abcde", "b": [4, 5, 6], "c": 9},
            ],
            {"a": "Hello world", "b": [], "c": cudf.NA},
        ),
        (
            [
                {"a": "Hello world", "b": []},
                {"a": "CUDF", "b": [1, 2, 3], "c": cudf.NA},
                {"a": "abcde", "b": [4, 5, 6], "c": 9},
            ],
            {},
        ),
        (
            [
                {"a": "Hello world", "b": []},
                {"a": "CUDF", "b": [1, 2, 3], "c": cudf.NA},
                {"a": "abcde", "b": [4, 5, 6], "c": 9},
            ],
            cudf.NA,
        ),
        (
            [
                {"a": "Hello world", "b": []},
                {"a": "CUDF", "b": [1, 2, 3], "c": cudf.NA},
                {"a": "abcde", "b": [4, 5, 6], "c": 9},
            ],
            {"a": "Second element", "b": [1, 2], "c": 1000},
        ),
    ],
)
def test_struct_setitem(data, item):
    sr = cudf.Series(data)
    sr[1] = item
    data[1] = item
    expected = cudf.Series(data)
    assert sr.to_arrow() == expected.to_arrow()


@pytest.mark.parametrize(
    "data",
    [
        {"a": 1, "b": "rapids", "c": [1, 2, 3, 4]},
        {"a": 1, "b": "rapids", "c": [1, 2, 3, 4], "d": cudf.NA},
        {"a": "Hello"},
        {"b": [], "c": [1, 2, 3]},
    ],
)
def test_struct_scalar_host_construction(data):
    slr = cudf.Scalar(data)
    assert slr.value == data
    assert list(slr.device_value.value.values()) == list(data.values())


def test_struct_scalar_null():
    slr = cudf.Scalar(cudf.NA, dtype=StructDtype)
    assert slr.device_value.value is cudf.NA


def test_dataframe_to_struct():
    df = cudf.DataFrame()
    expect = cudf.Series(dtype=cudf.StructDtype({}))
    got = df.to_struct()
    assert_eq(expect, got)

    df = cudf.DataFrame({"a": [1, 2, 3], "b": ["x", "y", "z"]})
    expect = cudf.Series(
        [{"a": 1, "b": "x"}, {"a": 2, "b": "y"}, {"a": 3, "b": "z"}]
    )
    got = df.to_struct()
    assert_eq(expect, got)
