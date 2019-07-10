import numbers
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
        from cudf.dataframe.index import Index

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
                [], dtype=self._sr.dtype, index=self._sr.index.__class__([])
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
        arg = self._create_valid_tuple(arg)
        df = self._getitem_tuple_arg(arg)

        return df

    def _create_valid_tuple(self, arg):
        if isinstance(arg, (str, numbers.Number)):
            return (arg, slice(None))
        if type(arg) is not tuple:
            arg = (arg, slice(None))
        if isinstance(self._df.columns, cudf.MultiIndex):
            # the second arg can be: single value, tuple of valid keys, slice,
            # or None
            if self._df.columns._is_valid_index_key(arg):
                arg = (slice(None), arg)
            elif not isinstance(arg, tuple) or len(arg) == 1:
                arg = (slice(None), arg)
        if isinstance(self._df.index, cudf.MultiIndex):
            # the first arg can be: single value, tuple of valid keys, or slice
            if self._df.index._is_valid_index_key(arg):
                arg = (arg, slice(None))
            elif not isinstance(arg, (slice, tuple)) or len(arg) == 1:
                arg = (arg, slice(None))
        return arg

    def _is_scalar_access(self, arg):
        """
        Determine if we are accessing a single value (scalar)
        """
        if isinstance(arg, str):
            return False
        if not hasattr(arg, "__len__"):
            return False
        for obj in arg:
            if not is_single_value(obj):
                return False
        return True

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
        from cudf import MultiIndex
        if isinstance(self._df.columns, MultiIndex):
            columns_df = self._df.columns._get_column_major(self._df, arg[1])
        else:
            columns = self._get_column_selection(arg[1])
            columns_df = DataFrame()
            for col in columns:
                columns_df.add_column(name=col, data=self._df[col])
        if isinstance(columns_df.index, MultiIndex):
            return columns_df.index._get_row_major(columns_df, arg[0])
        else:
            df = DataFrame()
            for col in columns_df.columns:
                df[col] = columns_df[col].loc[arg[0]]
        if df.shape[0] == 1:  # we have a single row
            if isinstance(arg[0], slice):
                df.index = as_index(arg[0].start)
            else:
                df.index = as_index(arg[0])
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
        from cudf.dataframe.index import as_index

        columns = self._get_column_selection(arg[1])
        if isinstance(self._df.columns, MultiIndex):
            columns_df = self._df.columns._get_column_major(self._df, arg)
        else:
            if isinstance(arg[0], slice):
                columns_df = DataFrame()
                for col in columns:
                    columns_df.add_column(name=col, data=self._df[col])
                columns_df._index = self._df._index
            else:
                columns_df = self._df._columns_view(columns)
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
            for col in columns_df.columns:
                df[col] = columns_df[col].iloc[arg[0]]

        if df.shape[0] == 1:  # we have a single row without an index
            if isinstance(arg[0], slice):
                df.index = as_index(self._df.index[arg[0].start])
            elif not hasattr(df.index, 'labels'):
                df.index = as_index(self._df.index[arg[0]])
        if self._can_downcast_to_series(df, arg):
            return self._downcast_to_series(df, arg)
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
    for name, col in df.iteritems():
        df[name] = col.astype(normalized_dtype)
    return df


class _IndexLocIndexer(object):
    def __init__(self, idx):
        self.idx = idx

    def __getitem__(self, arg):
        from cudf.dataframe.index import as_index

        return as_index(self.idx.to_series().loc[arg])
