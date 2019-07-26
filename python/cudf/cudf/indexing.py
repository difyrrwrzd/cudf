import numpy as np
import pandas as pd
from numba.cuda.cudadrv.devicearray import DeviceNDArray

import cudf
from cudf.utils.utils import is_single_value


class _SeriesLocIndexer(object):
    """
    Label-based selection
    """

    def __init__(self, sr):
        self._sr = sr

    def __getitem__(self, arg):
        from cudf.dataframe.series import Series
        from cudf.dataframe.index import Index, RangeIndex

        if isinstance(
            arg, (list, np.ndarray, pd.Series, range, Index, DeviceNDArray)
        ):
            if len(arg) == 0:
                arg = Series(np.array([], dtype="int32"))
            else:
                arg = Series(arg)
        if isinstance(arg, Series):
            if arg.dtype in [np.bool, np.bool_]:
                return self._sr.iloc[arg]
            # To do this efficiently we need a solution to
            # https://github.com/rapidsai/cudf/issues/1087
            out = Series(
                [],
                dtype=self._sr.dtype,
                index=self._sr.index.__class__(start=0)
                if isinstance(self._sr.index, RangeIndex)
                else self._sr.index.__class__([]),
            )
            for s in arg:
                out = out.append(self._sr.loc[s:s], ignore_index=False)
            return out
        elif is_single_value(arg):
            found_index = self._sr.index.find_label_range(arg, None)[0]
            return self._sr.iloc[found_index]
        elif isinstance(arg, slice):
            start_index, stop_index = self._sr.index.find_label_range(
                arg.start, arg.stop
            )
            return self._sr.iloc[start_index : stop_index : arg.step]
        else:
            raise NotImplementedError(
                ".loc not implemented for label type {}".format(
                    type(arg).__name__
                )
            )


class _SeriesIlocIndexer(object):
    """
    For integer-location based selection.
    """

    def __init__(self, sr):
        self._sr = sr

    def __getitem__(self, arg):
        if isinstance(arg, tuple):
            arg = list(arg)
        return self._sr[arg]


class _DataFrameIndexer(object):
    def __getitem__(self, arg):
        try:
            scalar_series_or_df = self._getitem_tuple_arg(arg)
        except (TypeError, KeyError, IndexError):
            scalar_series_or_df = self._getitem_tuple_arg((arg, slice(None)))

        return scalar_series_or_df

    def _can_downcast_to_series(self, df, arg):
        """
        This method encapsulates the logic used
        to determine whether or not the result of a loc/iloc
        operation should be "downcasted" from a DataFrame to a
        Series
        """
        if isinstance(df, cudf.Series):
            return False
        nrows, ncols = df.shape
        if nrows == 1:
            if type(arg[0]) is slice:
                if not is_single_value(arg[1]):
                    return False
            dtypes = df.dtypes.values.tolist()
            all_numeric = all(
                [pd.api.types.is_numeric_dtype(t) for t in dtypes]
            )
            all_identical = dtypes.count(dtypes[0]) == len(dtypes)
            if all_numeric or all_identical:
                return True
        if ncols == 1:
            if type(arg[1]) is slice:
                if not is_single_value(arg[0]):
                    return False
            return True
        return False

    def _downcast_to_series(self, df, arg):
        """
        "Downcast" from a DataFrame to a Series
        based on Pandas indexing rules
        """
        nrows, ncols = df.shape
        # determine the axis along which the Series is taken:
        if nrows == 1 and ncols == 1:
            if not is_single_value(arg[0]):
                axis = 1
            else:
                axis = 0
        elif nrows == 1:
            axis = 0
        elif ncols == 1:
            axis = 1
        else:
            raise ValueError("Cannot downcast DataFrame selection to Series")

        # take series along the axis:
        if axis == 1:
            return df[df.columns[0]]
        else:
            df = _normalize_dtypes(df)
            sr = df.T
            return sr[sr.columns[0]]


class _DataFrameLocIndexer(_DataFrameIndexer):
    """
    For selection by label.
    """

    def __init__(self, df):
        self._df = df

    def _getitem_scalar(self, arg):
        return self._df[arg[1]].loc[arg[0]]

    def _getitem_tuple_arg(self, arg):
        from cudf.dataframe.dataframe import DataFrame
        from cudf.dataframe.index import as_index
        from cudf.utils.cudautils import arange
        from cudf import MultiIndex
        # Step 1: Gather columns
        if isinstance(self._df.columns, MultiIndex):
            columns_df = self._df.columns._get_column_major(self._df, arg[1])
        else:
            columns = self._get_column_selection(arg[1])
            columns_df = DataFrame()
            for col in columns:
                columns_df.add_column(name=col, data=self._df[col])
        # Step 2: Gather rows
        if isinstance(columns_df.index, MultiIndex):
            return columns_df.index._get_row_major(columns_df, arg[0])
        else:
            if isinstance(self._df.columns, MultiIndex):
                if isinstance(arg[0], slice):
                    start, stop, step = arg[0].indices(len(columns_df))
                    indices = arange(start, stop, step)
                    df = columns_df.take(indices)
                else:
                    df = columns_df.take(arg[0])
            else:
                df = DataFrame()
                for col in columns_df.columns:
                    df[col] = columns_df[col].loc[arg[0]]
        # Step 3: Gather index
        if df.shape[0] == 1:  # we have a single row
            if isinstance(arg[0], slice):
                start = arg[0].start
                if start is None:
                    start = self._df.index[0]
                df.index = as_index(start)
            else:
                df.index = as_index(arg[0])
        # Step 4: Downcast
        if self._can_downcast_to_series(df, arg):
            return self._downcast_to_series(df, arg)
        return df

    def _get_column_selection(self, arg):
        if is_single_value(arg):
            return [arg]

        elif isinstance(arg, slice):
            start = self._df.columns[0] if arg.start is None else arg.start
            stop = self._df.columns[-1] if arg.stop is None else arg.stop
            cols = []
            within_slice = False
            for c in self._df.columns:
                if c == start:
                    within_slice = True
                if within_slice:
                    cols.append(c)
                if c == stop:
                    break
            return cols

        else:
            return arg


class _DataFrameIlocIndexer(_DataFrameIndexer):
    """
    For selection by index.
    """

    def __init__(self, df):
        self._df = df

    def _getitem_tuple_arg(self, arg):
        from cudf import MultiIndex
        from cudf.dataframe.dataframe import DataFrame
        from cudf.dataframe.dataframe import Series
        from cudf.dataframe.index import as_index

        # Iloc Step 1:
        # Gather the columns specified by the second tuple arg
        columns = self._get_column_selection(arg[1])
        if isinstance(self._df.columns, MultiIndex):
            columns_df = self._df.columns._get_column_major(self._df, arg[1])
            if len(columns_df) == 0 and len(columns_df.columns) == 0 and not\
                    isinstance(arg[0], slice):
                result = Series([], name=arg[0])
                result._index = columns_df.columns.copy(deep=False)
                return result
        else:
            if isinstance(arg[0], slice):
                columns_df = DataFrame()
                for col in columns:
                    columns_df.add_column(name=col, data=self._df[col])
                columns_df._index = self._df._index
            else:
                columns_df = self._df._columns_view(columns)

        # Iloc Step 2:
        # Gather the rows specified by the first tuple arg
        if isinstance(columns_df.index, MultiIndex):
            df = columns_df.index._get_row_major(columns_df, arg[0])
            if (len(df) == 1 and len(columns_df) >= 1) and not\
                    (isinstance(arg[0], slice) or isinstance(arg[1], slice)):
                # Pandas returns a numpy scalar in this case
                return df[0]
            if self._can_downcast_to_series(df, arg):
                return self._downcast_to_series(df, arg)
            return df
        else:
            df = DataFrame()
            for key, col in columns_df._cols.items():
                df[key] = col.iloc[arg[0]]
            df.columns = columns_df.columns

        # Iloc Step 3:
        # Reindex
        if df.shape[0] == 1:  # we have a single row without an index
            if isinstance(arg[0], slice):
                start = arg[0].start
                if start is None:
                    start = 0
                df.index = as_index(self._df.index[start])
            else:
                df.index = as_index(self._df.index[arg[0]])

        # Iloc Step 4:
        # Downcast
        if self._can_downcast_to_series(df, arg):
            if isinstance(df.columns, MultiIndex):
                if len(df) > 0 and not (
                        isinstance(arg[0], slice) or isinstance(arg[1], slice)
                ):
                    return list(df._cols.values())[0][0]
                elif df.shape[1] > 1:
                    result = self._downcast_to_series(df, arg)
                    result.index = df.columns
                    return result
                elif not isinstance(arg[0], slice):
                    result_series = list(df._cols.values())[0]
                    result_series.index = df.columns
                    result_series.name = arg[0]
                    return result_series
                else:
                    return list(df._cols.values())[0]
            return self._downcast_to_series(df, arg)
        if df.shape[0] == 0 and df.shape[1] == 0:
            from cudf.dataframe.index import RangeIndex
            slice_len = arg[0].stop or len(self._df)
            start, stop, step = arg[0].indices(slice_len)
            df._index = RangeIndex(start, stop)
        return df

    def _getitem_scalar(self, arg):
        col = self._df.columns[arg[1]]
        return self._df[col].iloc[arg[0]]

    def _get_column_selection(self, arg):
        cols = self._df.columns
        if is_single_value(arg):
            return [cols[arg]]
        else:
            return cols[arg]


def _normalize_dtypes(df):
    dtypes = df.dtypes.values.tolist()
    normalized_dtype = np.result_type(*dtypes)
    for name, col in df._cols.items():
        df[name] = col.astype(normalized_dtype)
    return df


class _IndexLocIndexer(object):
    def __init__(self, idx):
        self.idx = idx

    def __getitem__(self, arg):
        from cudf.dataframe.index import as_index

        return as_index(self.idx.to_series().loc[arg])
