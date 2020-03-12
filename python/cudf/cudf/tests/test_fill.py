import pandas as pd
import pytest
from pandas.util.testing import assert_series_equal

import cudf


@pytest.mark.parametrize(
    "fill_value,data",
    [
        (7, [6, 3, 4]),
        ("x", ["a", "b", "c", "d", "e", "f"]),
        (7, [6, 3, 4, 2, 1, 7, 8, 5]),
        (0.8, [0.6, 0.3, 0.4, 0.2, 0.1, 0.7, 0.8, 0.5]),
        ("b", pd.Categorical(["a", "b", "c"])),
    ],
)
@pytest.mark.parametrize(
    "begin,end",
    [
        (0, -1),
        (0, 4),
        (1, -1),
        (1, 4),
        (-2, 1),
        (-2, -1),
        (10, 12),
        (8, 10),
        (10, 8),
        (-10, -8),
        (-2, 6),
    ],
)
@pytest.mark.parametrize("inplace", [True, False])
def test_fill(data, fill_value, begin, end, inplace):
    gs = cudf.Series(data)
    ps = gs.to_pandas()

    if inplace:
        actual = gs
        gs[begin:end] = fill_value
    else:
        actual = gs._fill([fill_value], begin, end, inplace)
        assert actual is not gs

    ps[begin:end] = fill_value

    assert_series_equal(ps, actual.to_pandas())


@pytest.mark.xfail(raises=ValueError)
def test_fill_new_category():
    gs = cudf.Series(pd.Categorical(["a", "b", "c"]))
    gs[0:1] = "d"
