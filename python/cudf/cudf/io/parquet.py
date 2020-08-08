# Copyright (c) 2019-2020, NVIDIA CORPORATION.

import warnings

from fsspec.core import get_fs_token_paths
from pyarrow import parquet as pq
from pyarrow.compat import guid
from pyarrow import dataset as ds

import cudf
from cudf._lib import parquet as libparquet
from cudf.utils import ioutils
from cudf.utils.dtypes import is_list_like


def _get_partition_groups(df, partition_cols, preserve_index=False):
    # TODO: We can use groupby functionality here after cudf#4346.
    #       Longer term, we want more slicing logic to be pushed down
    #       into cpp.  For example, it would be best to pass libcudf
    #       a single sorted table with group offsets).
    df = df.sort_values(partition_cols)
    if not preserve_index:
        df = df.reset_index(drop=True)
    divisions = df[partition_cols].drop_duplicates(ignore_index=True)
    splits = df[partition_cols].searchsorted(divisions, side="left")
    splits = splits.tolist() + [len(df[partition_cols])]
    return [
        df.iloc[splits[i] : splits[i + 1]].copy(deep=False)
        for i in range(0, len(splits) - 1)
    ]


def _check_contains_null(val):
    if isinstance(val, bytes):
        for byte in val:
            if isinstance(byte, bytes):
                compare_to = chr(0)
            else:
                compare_to = 0
            if byte == compare_to:
                return True
    elif isinstance(val, str):
        return "\x00" in val
    return False


def _check_filters(filters, check_null_strings=True):
    """
    Check if filters are well-formed.
    """
    if filters is not None:
        if len(filters) == 0 or any(len(f) == 0 for f in filters):
            raise ValueError("Malformed filters")
        if isinstance(filters[0][0], str):
            # We have encountered the situation where we have one nesting level
            # too few:
            #   We have [(,,), ..] instead of [[(,,), ..]]
            filters = [filters]
        if check_null_strings:
            for conjunction in filters:
                for col, op, val in conjunction:
                    if (
                        isinstance(val, list)
                        and all(_check_contains_null(v) for v in val)
                        or _check_contains_null(val)
                    ):
                        raise NotImplementedError(
                            "Null-terminated binary strings are not supported "
                            "as filter values."
                        )
    return filters


def _filters_to_expression(filters):
    """
    Check if filters are well-formed.
    See _DNF_filter_doc above for more details.
    """
    import pyarrow.dataset as ds

    if isinstance(filters, ds.Expression):
        return filters

    filters = _check_filters(filters, check_null_strings=False)

    def convert_single_predicate(col, op, val):
        field = ds.field(col)

        if op == "=" or op == "==":
            return field == val
        elif op == "!=":
            return field != val
        elif op == "<":
            return field < val
        elif op == ">":
            return field > val
        elif op == "<=":
            return field <= val
        elif op == ">=":
            return field >= val
        elif op == "in":
            return field.isin(val)
        elif op == "not in":
            return ~field.isin(val)
        else:
            raise ValueError(
                '"{0}" is not a valid operator in predicates.'.format(
                    (col, op, val)
                )
            )

    or_exprs = []

    for conjunction in filters:
        and_exprs = []
        for col, op, val in conjunction:
            and_exprs.append(convert_single_predicate(col, op, val))

        expr = and_exprs[0]
        if len(and_exprs) > 1:
            for and_expr in and_exprs[1:]:
                expr = ds.AndExpression(expr, and_expr)

        or_exprs.append(expr)

    expr = or_exprs[0]
    if len(or_exprs) > 1:
        expr = ds.OrExpression(*or_exprs)
        for or_expr in or_exprs[1:]:
            expr = ds.OrExpression(expr, or_expr)

    return expr


def _ensure_filesystem(passed_filesystem, path):
    if passed_filesystem is None:
        return get_fs_token_paths(path[0] if isinstance(path, list) else path)[
            0
        ]
    return passed_filesystem


# Logic chosen to match: https://arrow.apache.org/
# docs/_modules/pyarrow/parquet.html#write_to_dataset
def write_to_dataset(
    df,
    root_path,
    partition_cols=None,
    fs=None,
    preserve_index=False,
    return_metadata=False,
    **kwargs,
):
    """Wraps `to_parquet` to write partitioned Parquet datasets.
    For each combination of partition group and value,
    subdirectories are created as follows:

    .. code-block:: bash

        root_dir/
            group=value1
                <uuid>.parquet
            ...
            group=valueN
                <uuid>.parquet

    Parameters
    ----------
    df : cudf.DataFrame
    root_path : string,
        The root directory of the dataset
    fs : FileSystem, default None
        If nothing passed, paths assumed to be found in the local on-disk
        filesystem
    preserve_index : bool, default False
        Preserve index values in each parquet file.
    partition_cols : list,
        Column names by which to partition the dataset
        Columns are partitioned in the order they are given
    return_metadata : bool, default False
        Return parquet metadata for written data. Returned metadata will
        include the file-path metadata (relative to `root_path`).
    **kwargs : dict,
        kwargs for to_parquet function.
    """

    fs = _ensure_filesystem(fs, root_path)
    fs.mkdirs(root_path, exist_ok=True)
    metadata = []

    if partition_cols is not None and len(partition_cols) > 0:

        data_cols = df.columns.drop(partition_cols)
        if len(data_cols) == 0:
            raise ValueError("No data left to save outside partition columns")

        #  Loop through the partition groups
        for i, sub_df in enumerate(
            _get_partition_groups(
                df, partition_cols, preserve_index=preserve_index
            )
        ):
            if sub_df is None or len(sub_df) == 0:
                continue
            keys = tuple([sub_df[col].iloc[0] for col in partition_cols])
            if not isinstance(keys, tuple):
                keys = (keys,)
            subdir = fs.sep.join(
                [
                    "{colname}={value}".format(colname=name, value=val)
                    for name, val in zip(partition_cols, keys)
                ]
            )
            prefix = fs.sep.join([root_path, subdir])
            fs.mkdirs(prefix, exist_ok=True)
            outfile = guid() + ".parquet"
            full_path = fs.sep.join([prefix, outfile])
            write_df = sub_df.copy(deep=False)
            write_df.drop(columns=partition_cols, inplace=True)
            with fs.open(full_path, mode="wb") as fil:
                fil = ioutils.get_IOBase_writer(fil)
                if return_metadata:
                    metadata.append(
                        write_df.to_parquet(
                            fil,
                            index=preserve_index,
                            metadata_file_path=fs.sep.join([subdir, outfile]),
                            **kwargs,
                        )
                    )
                else:
                    write_df.to_parquet(fil, index=preserve_index, **kwargs)

    else:
        outfile = guid() + ".parquet"
        full_path = fs.sep.join([root_path, outfile])
        if return_metadata:
            metadata.append(
                df.to_parquet(
                    full_path,
                    index=preserve_index,
                    metadata_file_path=outfile,
                    **kwargs,
                )
            )
        else:
            df.to_parquet(full_path, index=preserve_index, **kwargs)

    if metadata:
        return (
            merge_parquet_filemetadata(metadata)
            if len(metadata) > 1
            else metadata[0]
        )


@ioutils.doc_read_parquet_metadata()
def read_parquet_metadata(path):
    """{docstring}"""

    pq_file = pq.ParquetFile(path)

    num_rows = pq_file.metadata.num_rows
    num_row_groups = pq_file.num_row_groups
    col_names = pq_file.schema.names

    return num_rows, num_row_groups, col_names


@ioutils.doc_read_parquet()
def read_parquet(
    filepath_or_buffer,
    engine="cudf",
    columns=None,
    filters=None,
    row_groups=None,
    skip_rows=None,
    num_rows=None,
    strings_to_categorical=False,
    use_pandas_metadata=True,
    *args,
    **kwargs,
):
    """{docstring}"""

    # Multiple sources are passed as a list. If a single source is passed,
    # wrap it in a list for unified processing downstream.
    if not is_list_like(filepath_or_buffer):
        filepath_or_buffer = [filepath_or_buffer]

    # a list of row groups per source should be passed. make the list of
    # lists that is expected for multiple sources
    if row_groups is not None:
        if not is_list_like(row_groups):
            row_groups = [[row_groups]]
        elif not is_list_like(row_groups[0]):
            row_groups = [row_groups]

    filepaths_or_buffers = []
    for source in filepath_or_buffer:
        tmp_source, compression = ioutils.get_filepath_or_buffer(
            path_or_data=source, compression=None, **kwargs
        )
        if compression is not None:
            raise ValueError(
                "URL content-encoding decompression is not supported"
            )
        filepaths_or_buffers.append(tmp_source)

    if filters is not None:
        # Convert filters to ds.Expression
        filters = _filters_to_expression(filters)

        # Initialize ds.FilesystemDataset
        dataset = ds.dataset(filepaths_or_buffers, format="parquet")

        # Load IDs of filtered row groups for each file in dataset
        filtered_rg_ids = {}
        for fragment in dataset.get_fragments(filter=filters):
            for rg_fragment in fragment.get_row_group_fragments(filters):
                for rg_id in rg_fragment.row_groups:
                    path = rg_fragment.path
                    if path not in filtered_rg_ids:
                        filtered_rg_ids[path] = [rg_id]
                    else:
                        filtered_rg_ids[path].append(rg_id)

        # TODO: Use this with pyarrow 1.0.0
        # # Load IDs of filtered row groups for each file in dataset
        # filtered_row_group_ids = {}
        # for fragment in dataset.get_fragments(filters):
        #     for row_group_fragment in fragment.split_by_row_group(filters):
        #         for row_group_info in row_group_fragment.row_groups:
        #             path = row_group_fragment.path
        #             if path not in filtered_row_group_ids:
        #                 filtered_row_group_ids[path] = [row_group_info.id]
        #             else:
        #                 filtered_row_group_ids[path].append(row_group_info.id)

        # Initialize row_groups to be selected
        if row_groups is None:
            row_groups = [None for _ in dataset.files]

        # Store IDs of selected row groups for each file
        for i, file in enumerate(dataset.files):
            if row_groups[i] is None:
                row_groups[i] = filtered_rg_ids[file]
            else:
                row_groups[i] = filter(
                    lambda id: id in row_groups[i], filtered_rg_ids[file]
                )

    if engine == "cudf":
        return libparquet.read_parquet(
            filepaths_or_buffers,
            columns=columns,
            row_groups=row_groups,
            skip_rows=skip_rows,
            num_rows=num_rows,
            strings_to_categorical=strings_to_categorical,
            use_pandas_metadata=use_pandas_metadata,
        )
    else:
        warnings.warn("Using CPU via PyArrow to read Parquet dataset.")
        return cudf.DataFrame.from_arrow(
            pq.ParquetDataset(filepaths_or_buffers).read_pandas(
                columns=columns, *args, **kwargs
            )
        )


@ioutils.doc_to_parquet()
def to_parquet(
    df,
    path,
    engine="cudf",
    compression="snappy",
    index=None,
    partition_cols=None,
    statistics="ROWGROUP",
    metadata_file_path=None,
    *args,
    **kwargs,
):
    """{docstring}"""

    if engine == "cudf":
        if partition_cols:
            write_to_dataset(
                df,
                root_path=path,
                partition_cols=partition_cols,
                preserve_index=index,
                **kwargs,
            )
            return

        # Ensure that no columns dtype is 'category'
        for col in df.columns:
            if df[col].dtype.name == "category":
                raise ValueError(
                    "'category' column dtypes are currently not "
                    + "supported by the gpu accelerated parquet writer"
                )

        path_or_buf = ioutils.get_writer_filepath_or_buffer(
            path, mode="wb", **kwargs
        )
        if ioutils.is_fsspec_open_file(path_or_buf):
            with path_or_buf as file_obj:
                file_obj = ioutils.get_IOBase_writer(file_obj)
                write_parquet_res = libparquet.write_parquet(
                    df,
                    path=file_obj,
                    index=index,
                    compression=compression,
                    statistics=statistics,
                    metadata_file_path=metadata_file_path,
                )
        else:
            write_parquet_res = libparquet.write_parquet(
                df,
                path=path_or_buf,
                index=index,
                compression=compression,
                statistics=statistics,
                metadata_file_path=metadata_file_path,
            )

        return write_parquet_res

    else:

        # If index is empty set it to the expected default value of True
        if index is None:
            index = True

        pa_table = df.to_arrow(preserve_index=index)
        return pq.write_to_dataset(
            pa_table,
            root_path=path,
            partition_cols=partition_cols,
            *args,
            **kwargs,
        )


@ioutils.doc_merge_parquet_filemetadata()
def merge_parquet_filemetadata(filemetadata_list):
    """{docstring}"""

    return libparquet.merge_filemetadata(filemetadata_list)


ParquetWriter = libparquet.ParquetWriter
