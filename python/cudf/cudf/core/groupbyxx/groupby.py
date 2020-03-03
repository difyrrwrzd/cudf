import collections

import pandas as pd

import cudf
import cudf._libxx.groupby as libgroupby


class GroupBy(object):
    def __init__(self, obj, by):
        self.grouping = _Grouping(obj, by)
        self.obj = obj
        self._groupby = libgroupby.GroupBy(self.grouping.keys)

    def __iter__(self):
        grouped_keys, grouped_values, offsets = self._groupby.groups(self.obj)

        grouped_keys = cudf.Index._from_table(grouped_keys)
        grouped_values = self.obj.__class__._from_table(grouped_values)
        group_names = grouped_keys.unique()

        for i, name in enumerate(group_names):
            yield name, grouped_values[offsets[i] : offsets[i + 1]]

    def agg(self, aggs):
        normalized_aggs = self._normalize_aggs(aggs)
        result = self._groupby.aggregate(self.obj, normalized_aggs)
        result = self.obj.__class__._from_table(result).sort_index()

        if not any(pd.api.types.is_list_like(agg) for agg in aggs.values()):
            # drop the last level
            columns = result.columns.droplevel(-1)
            result.columns = columns

        # set index names to be group key names
        result.index.names = self.grouping.names

        return result

    def _normalize_aggs(self, aggs):
        """
        Normalize agg to a dict mapping column names
        to a list of aggregations.
        """
        out = aggs.copy()

        if not isinstance(aggs, collections.abc.Mapping):
            # Make col_name->aggs mapping from aggs.
            # Do not include named key columns
            columns = tuple(
                dict.fromkeys(self.obj._column_names, []).keys()
                - dict.fromkeys(self.grouping._named_columns, []).keys()
            )
            out = dict.fromkeys(columns, aggs)

        # Convert all values to list-like:
        for col, agg in out.items():
            if not pd.api.types.is_list_like(agg):
                out[col] = [agg]

        return out


class _Grouping(object):
    def __init__(self, obj, by):
        """
        Parameters
        ----------
        obj : Object on which the GroupBy is performed
        by :
            Any of the following:

            - A Python function called on each value of the object's index
            - A dict or Series that maps index labels to group names
            - A cudf.Index object
            - A str indicating a column name
            - An array of the same length as the object
            - A list of the above
        """
        self.obj = obj
        self._key_columns = []
        self.names = []
        self._named_columns = []

        by_list = by
        if not isinstance(by_list, list):
            by_list = [by]

        for by in by_list:
            if callable(by):
                self._handle_callable(by)
            elif isinstance(by, cudf.Series):
                self._handle_series(by)
            elif isinstance(by, cudf.Index):
                self._handle_index(by)
            elif isinstance(by, collections.abc.Mapping):
                self._handle_mapping(by)
            elif by in self.obj:
                self._handle_label(by)
            else:
                self._handle_misc(by)

    @property
    def keys(self):
        nkeys = len(self._key_columns)
        if nkeys > 1:
            return cudf.MultiIndex(
                source_data=cudf.DataFrame(
                    dict(zip(range(nkeys), self._key_columns))
                ),
                names=self.names,
            )
        else:
            return cudf.core.index.as_index(
                self._key_columns[0], name=self.names[0]
            )

    def _handle_callable(self, by):
        by = by(self.obj.index)
        self.__init__(self.obj, by)

    def _handle_series(self, by):
        by = by._align_to_index(self.obj.index, how="right")
        self._key_columns.append(by._column)
        self.names.append(by.name)

    def _handle_index(self, by):
        self._key_columns.extend(by._data.columns)
        self.names.extend(by._data.names)

    def _handle_mapping(self, by):
        by = cudf.Series(by.values(), index=by.keys())
        self._handle_series(by)

    def _handle_label(self, by):
        self._key_columns.append(self.obj._data[by])
        self.names.append(by)
        self._named_columns.append(by)

    def _handle_misc(self, by):
        by = cudf.core.column.as_column(by)
        if len(by) != len(self.obj):
            raise ValueError("Grouper and object must have same length")
        self._key_columns.append(by)
        self.names.append(None)
