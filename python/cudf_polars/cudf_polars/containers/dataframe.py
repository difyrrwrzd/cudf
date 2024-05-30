# SPDX-FileCopyrightText: Copyright (c) 2024 NVIDIA CORPORATION & AFFILIATES.
# SPDX-License-Identifier: Apache-2.0

"""A dataframe, with some properties."""

from __future__ import annotations

from functools import cached_property
from typing import TYPE_CHECKING

import polars as pl

import cudf._lib.pylibcudf as plc

from cudf_polars.containers.column import Column

if TYPE_CHECKING:
    from collections.abc import Mapping, Sequence, Set

    from typing_extensions import Self

    import cudf

    from cudf_polars.containers.scalar import Scalar


__all__: list[str] = ["DataFrame"]


class DataFrame:
    """A representation of a dataframe."""

    columns: list[Column]
    scalars: list[Scalar]
    table: plc.Table | None

    def __init__(self, columns: Sequence[Column], scalars: Sequence[Scalar]) -> None:
        self.columns = list(columns)
        self._column_map = {c.name: c for c in self.columns}
        self.scalars = list(scalars)
        if len(scalars) == 0:
            self.table = plc.Table([c.obj for c in columns])
        else:
            self.table = None

    def copy(self) -> Self:
        """Return a shallow copy of self."""
        return type(self)(self.columns, self.scalars)

    def to_polars(self) -> pl.DataFrame:
        """Convert to a polars DataFrame."""
        assert len(self.scalars) == 0
        return pl.from_arrow(
            plc.interop.to_arrow(
                self.table,
                [plc.interop.ColumnMetadata(name=c.name) for c in self.columns],
            )
        )

    @cached_property
    def column_names_set(self) -> frozenset[str]:
        """Return the column names as a set."""
        return frozenset(c.name for c in self.columns)

    @cached_property
    def column_names(self) -> list[str]:
        """Return a list of the column names."""
        return [c.name for c in self.columns]

    @cached_property
    def num_columns(self) -> int:
        """Number of columns."""
        return len(self.columns)

    @cached_property
    def num_rows(self) -> int:
        """Number of rows."""
        if self.table is None:
            raise ValueError("Number of rows of frame with scalars makes no sense")
        return self.table.num_rows()

    @classmethod
    def from_cudf(cls, df: cudf.DataFrame) -> Self:
        """Create from a cudf dataframe."""
        return cls(
            [Column(c.to_pylibcudf(mode="read"), name) for name, c in df._data.items()],
            [],
        )

    @classmethod
    def from_table(cls, table: plc.Table, names: Sequence[str]) -> Self:
        """
        Create from a pylibcudf table.

        Parameters
        ----------
        table
            Pylibcudf table to obtain columns from
        names
            Names for the columns

        Returns
        -------
        New dataframe sharing  data with the input table.

        Raises
        ------
        ValueError if the number of provided names does not match the
        number of columns in the table.
        """
        # TODO: strict=True when we drop py39
        if table.num_columns() != len(names):
            raise ValueError("Mismatching name and table length.")
        return cls([Column(c, name) for c, name in zip(table.columns(), names)], [])

    def sorted_like(
        self, like: DataFrame, /, *, subset: Set[str] | None = None
    ) -> Self:
        """
        Copy sortedness from a dataframe onto self.

        Parameters
        ----------
        like
            The dataframe to copy from
        subset
            Optional subset of columns from which to copy data.

        Returns
        -------
        Self with metadata set.

        Raises
        ------
        ValueError if there is a name mismatch between self and like.
        """
        if like.column_names != self.column_names:
            raise ValueError("Can only copy from identically named frame")
        subset = self.column_names_set if subset is None else subset
        self.columns = [
            c.sorted_like(other) if c.name in subset else c
            for c, other in zip(self.columns, like.columns)
        ]
        return self

    def with_columns(self, columns: Sequence[Column]) -> Self:
        """
        Return a new dataframe with extra columns.

        Parameters
        ----------
        columns
            Columns to add

        Returns
        -------
        New dataframe

        Notes
        -----
        If column names overlap, newer names replace older ones.
        """
        return type(self)([*self.columns, *columns], self.scalars)

    def discard_columns(self, names: Set[str]) -> Self:
        """Drop columns by name."""
        return type(self)(
            [c for c in self.columns if c.name not in names], self.scalars
        )

    def select(self, names: Sequence[str]) -> Self:
        """Select columns by name returning DataFrame."""
        want = set(names)
        if not want.issubset(self.column_names_set):
            raise ValueError("Can't select missing names")
        return type(self)([self._column_map[name] for name in names], self.scalars)

    def replace_columns(self, *columns: Column) -> Self:
        """Return a new dataframe with columns replaced by name."""
        new = {c.name: c for c in columns}
        if not set(new).issubset(self.column_names_set):
            raise ValueError("Cannot replace with non-existing names")
        return type(self)([new.get(c.name, c) for c in self.columns], self.scalars)

    def rename_columns(self, mapping: Mapping[str, str]) -> Self:
        """Rename some columns."""
        return type(self)(
            [c.copy(new_name=mapping.get(c.name)) for c in self.columns], self.scalars
        )

    def select_columns(self, names: Set[str]) -> list[Column]:
        """Select columns by name."""
        return [c for c in self.columns if c.name in names]

    def filter(self, mask: Column) -> Self:
        """Return a filtered table given a mask."""
        table = plc.stream_compaction.apply_boolean_mask(self.table, mask.obj)
        return type(self).from_table(table, self.column_names).sorted_like(self)

    def slice(self, zlice: tuple[int, int] | None) -> Self:
        """
        Slice a dataframe.

        Parameters
        ----------
        zlice
            optional, tuple of start and length, negative values of start
            treated as for python indexing. If not provided, returns self.

        Returns
        -------
        New dataframe (if zlice is not None) other self (if it is)
        """
        if zlice is None:
            return self
        start, length = zlice
        if start < 0:
            start += self.num_rows
        # Polars slice takes an arbitrary positive integer and slice
        # to the end of the frame if it is larger.
        end = min(start + length, self.num_rows)
        (table,) = plc.copying.slice(self.table, [start, end])
        return type(self).from_table(table, self.column_names).sorted_like(self)
