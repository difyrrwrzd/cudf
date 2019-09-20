from dask.dataframe.core import get_parallel_type, make_meta, meta_nonempty

import cudf

from .core import DataFrame, Index, Series

get_parallel_type.register(cudf.DataFrame, lambda _: DataFrame)
get_parallel_type.register(cudf.Series, lambda _: Series)
get_parallel_type.register(cudf.Index, lambda _: Index)


@meta_nonempty.register((cudf.DataFrame, cudf.Series, cudf.Index))
def meta_nonempty_cudf(x, index=None):
    y = meta_nonempty(x.to_pandas())  # TODO: add iloc[:5]
    return cudf.from_pandas(y)


try:

    from dask.dataframe.methods import concat_dispatch, group_split, hash_df
    import cudf._lib as libcudf

    @make_meta.register((cudf.Series, cudf.DataFrame))
    def make_meta_cudf(x, index=None):
        return x.head(0)

    @make_meta.register(cudf.Index)
    def make_meta_cudf_index(x, index=None):
        return x[:0]

    @concat_dispatch.register((cudf.DataFrame, cudf.Series, cudf.Index))
    def concat_cudf(
        dfs,
        axis=0,
        join="outer",
        uniform=False,
        filter_warning=True,
        sort=None,
    ):
        assert axis == 0
        assert join == "outer"
        return cudf.concat(dfs)

    @hash_df.register(cudf.DataFrame)
    def hash_df_cudf(dfs):
        return dfs.hash_columns()

    @hash_df.register(cudf.Index)
    def hash_df_cudf_index(ind):
        from cudf.core.column import column, numerical

        cols = [column.as_column(ind)]
        return cudf.Series(numerical.column_hash_values(*cols))

    @group_split.register((cudf.DataFrame, cudf.Series, cudf.Index))
    def group_split_cudf(df, c, k):
        source = [df[col] for col in df.columns]
        # TODO: Use proper python API (#2807)
        tables = libcudf.copying.scatter_to_frames(source, cudf.Series(c))
        for i in range(k - len(tables)):
            tables.append(tables[0].iloc[[]])
        return dict(zip(range(k), tables))


except ImportError:
    pass
