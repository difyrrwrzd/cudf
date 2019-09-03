from datetime import datetime as dt

import pandas as pd
import pytest

from cudf.core.index import RangeIndex, as_index
from cudf import Series
from cudf.tests.utils import assert_eq


def cudf_date_series(start, stop, freq):
    return Series(pd.date_range(start, stop, freq=freq, name="times"))


def cudf_num_series(start, stop, step=1):
    return Series(range(start, stop, step))


def get_categorical_series():
    return Series(
        pd.Categorical(
            ["ab", "ac", "cd", "ab", "cd"], categories=["ab", "ac", "cd"]
        )
    )


def get_string_series():
    return Series(["ab", "ac", "ba", "cc", "ad"])


# If the type being searched is different from type of series, exceptions
# are thrown well within the python code, and needs to be handled.
# Some of the test cases check this scenario. Example : String Vs Numerical
testdata_all = [
    (
        cudf_date_series("20010101", "20020215", freq="400h"),
        dt.strptime("2001-01-01", "%Y-%m-%d"),
        True,
    ),
    (
        cudf_date_series("20010101", "20020215", freq="400h"),
        dt.strptime("2000-01-01", "%Y-%m-%d"),
        False,
    ),
    (cudf_date_series("20010101", "20020215", freq="400h"), 20000101, False),
    (get_categorical_series(), "cd", True),
    (get_categorical_series(), "dc", False),
    (get_categorical_series(), "c", False),
    (get_categorical_series(), "c", False),
    (get_categorical_series(), 1, False),
    (get_string_series(), "ac", True),
    (get_string_series(), "ca", False),
    (get_string_series(), "c", False),
    (get_string_series(), 97, False),
    (cudf_num_series(0, 100, 5), 60, True),
    (cudf_num_series(0, 100, 5), 71, False),
    (cudf_num_series(0, 100, 5), "a", False),
]


@pytest.mark.parametrize("values, item, expected", testdata_all)
def test_series_contains(values, item, expected):
    assert_eq(expected, item in Series(index=values))


@pytest.mark.parametrize("values, item, expected", testdata_all)
def test_index_contains(values, item, expected):
    index = as_index(values)
    assert_eq(expected, item in index)


def test_rangeindex_contains():
    assert_eq(True, 9 in RangeIndex(start=0, stop=10, name="Index"))
    assert_eq(False, 10 in RangeIndex(start=0, stop=10, name="Index"))
