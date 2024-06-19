# SPDX-FileCopyrightText: Copyright (c) 2024 NVIDIA CORPORATION & AFFILIATES.
# SPDX-License-Identifier: Apache-2.0

"""Device-aware assertions."""

from __future__ import annotations

from functools import partial
from typing import TYPE_CHECKING

from polars.testing.asserts import assert_frame_equal

from cudf_polars.callback import execute_with_cudf
from cudf_polars.dsl.translate import translate_ir

if TYPE_CHECKING:
    from collections.abc import Mapping

    import polars as pl

    from cudf_polars.typing import OptimizationArgs

__all__: list[str] = ["assert_gpu_result_equal", "assert_ir_translation_raises"]


def assert_gpu_result_equal(
    lazydf: pl.LazyFrame,
    *,
    collect_kwargs: Mapping[OptimizationArgs, bool] | None = None,
    check_row_order: bool = True,
    check_column_order: bool = True,
    check_dtypes: bool = True,
    check_exact: bool = True,
    rtol: float = 1e-05,
    atol: float = 1e-08,
    categorical_as_str: bool = False,
) -> None:
    """
    Assert that collection of a lazyframe on GPU produces correct results.

    Parameters
    ----------
    lazydf
        frame to collect.
    collect_kwargs
        Keyword arguments to pass to collect. Useful for controlling
        optimization settings.
    check_row_order
        Expect rows to be in same order
    check_column_order
        Expect columns to be in same order
    check_dtypes
        Expect dtypes to match
    check_exact
        Require exact equality for floats, if `False` compare using
        rtol and atol.
    rtol
        Relative tolerance for float comparisons
    atol
        Absolute tolerance for float comparisons
    categorical_as_str
        Decat categoricals to strings before comparing

    Raises
    ------
    AssertionError
        If the GPU and CPU collection do not match.
    NotImplementedError
        If GPU collection failed in some way.
    """
    collect_kwargs = {} if collect_kwargs is None else collect_kwargs
    expect = lazydf.collect(**collect_kwargs)
    got = lazydf.collect(
        **collect_kwargs,
        post_opt_callback=partial(execute_with_cudf, raise_on_fail=True),
    )
    assert_frame_equal(
        expect,
        got,
        check_row_order=check_row_order,
        check_column_order=check_column_order,
        check_dtypes=check_dtypes,
        check_exact=check_exact,
        rtol=rtol,
        atol=atol,
        categorical_as_str=categorical_as_str,
    )


def assert_ir_translation_raises(q: pl.LazyFrame, *exceptions: type[Exception]) -> None:
    """
    Assert that translation of a query raises an exception.

    Parameters
    ----------
    q
        Query to translate.
    exceptions
        Exceptions that one expects might be raised.

    Returns
    -------
    None
        If translation successfully raised the specified exceptions.

    Raises
    ------
    AssertionError
       If the specified exceptions were not raised.
    """
    try:
        _ = translate_ir(q._ldf.visit())
    except exceptions:
        return
    except Exception as e:
        raise AssertionError(f"Translation DID NOT RAISE {exceptions}") from e
    else:
        raise AssertionError(f"Translation DID NOT RAISE {exceptions}")
