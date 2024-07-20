# Copyright (c) 2019-2024, NVIDIA CORPORATION.
from __future__ import annotations

import itertools
import math
import operator
import shutil
import tempfile
import warnings
from collections import defaultdict
from contextlib import ExitStack
from functools import partial, reduce
from typing import Callable
from uuid import uuid4

import numpy as np
import pandas as pd
import pyarrow as pa
from pyarrow import dataset as ds

import cudf
from cudf._lib import parquet as libparquet
from cudf.api.types import is_list_like
from cudf.core.column import as_column, build_categorical_column, column_empty
from cudf.utils import ioutils
from cudf.utils.performance_tracking import _performance_tracking
from cudf.utils.utils import maybe_filter_deprecation

BYTE_SIZES = {
    "kb": 1000,
    "mb": 1000000,
    "gb": 1000000000,
    "tb": 1000000000000,
    "pb": 1000000000000000,
    "kib": 1024,
    "mib": 1048576,
    "gib": 1073741824,
    "tib": 1099511627776,
    "pib": 1125899906842624,
    "b": 1,
    "": 1,
    "k": 1000,
    "m": 1000000,
    "g": 1000000000,
    "t": 1000000000000,
    "p": 1000000000000000,
    "ki": 1024,
    "mi": 1048576,
    "gi": 1073741824,
    "ti": 1099511627776,
    "pi": 1125899906842624,
}


@_performance_tracking
def _write_parquet(
    df,
    paths,
    compression="snappy",
    index=None,
    statistics="ROWGROUP",
    metadata_file_path=None,
    int96_timestamps=False,
    row_group_size_bytes=ioutils._ROW_GROUP_SIZE_BYTES_DEFAULT,
    row_group_size_rows=None,
    max_page_size_bytes=None,
    max_page_size_rows=None,
    max_dictionary_size=None,
    partitions_info=None,
    storage_options=None,
    force_nullable_schema=False,
    header_version="1.0",
    use_dictionary=True,
    skip_compression=None,
    column_encoding=None,
    column_type_length=None,
    output_as_binary=None,
    write_arrow_schema=True,
):
    if is_list_like(paths) and len(paths) > 1:
        if partitions_info is None:
            ValueError("partition info is required for multiple paths")
        elif not is_list_like(partitions_info):
            ValueError("partition info must be list-like for multiple paths")
        elif not len(paths) == len(partitions_info):
            ValueError("partitions_info and paths must be of same size")
    if is_list_like(partitions_info) and len(partitions_info) > 1:
        if not is_list_like(paths):
            ValueError("paths must be list-like when partitions_info provided")

    paths_or_bufs = [
        ioutils.get_writer_filepath_or_buffer(
            path_or_data=path, mode="wb", storage_options=storage_options
        )
        for path in paths
    ]
    common_args = {
        "index": index,
        "compression": compression,
        "statistics": statistics,
        "metadata_file_path": metadata_file_path,
        "int96_timestamps": int96_timestamps,
        "row_group_size_bytes": row_group_size_bytes,
        "row_group_size_rows": row_group_size_rows,
        "max_page_size_bytes": max_page_size_bytes,
        "max_page_size_rows": max_page_size_rows,
        "max_dictionary_size": max_dictionary_size,
        "partitions_info": partitions_info,
        "force_nullable_schema": force_nullable_schema,
        "header_version": header_version,
        "use_dictionary": use_dictionary,
        "skip_compression": skip_compression,
        "column_encoding": column_encoding,
        "column_type_length": column_type_length,
        "output_as_binary": output_as_binary,
        "write_arrow_schema": write_arrow_schema,
    }
    if all(ioutils.is_fsspec_open_file(buf) for buf in paths_or_bufs):
        with ExitStack() as stack:
            fsspec_objs = [stack.enter_context(file) for file in paths_or_bufs]
            file_objs = [
                ioutils.get_IOBase_writer(file_obj) for file_obj in fsspec_objs
            ]
            write_parquet_res = libparquet.write_parquet(
                df, filepaths_or_buffers=file_objs, **common_args
            )
    else:
        write_parquet_res = libparquet.write_parquet(
            df, filepaths_or_buffers=paths_or_bufs, **common_args
        )

    return write_parquet_res


# Logic chosen to match: https://arrow.apache.org/
# docs/_modules/pyarrow/parquet.html#write_to_dataset
@_performance_tracking
def write_to_dataset(
    df,
    root_path,
    compression="snappy",
    filename=None,
    partition_cols=None,
    fs=None,
    preserve_index=False,
    return_metadata=False,
    statistics="ROWGROUP",
    int96_timestamps=False,
    row_group_size_bytes=ioutils._ROW_GROUP_SIZE_BYTES_DEFAULT,
    row_group_size_rows=None,
    max_page_size_bytes=None,
    max_page_size_rows=None,
    storage_options=None,
    force_nullable_schema=False,
    header_version="1.0",
    use_dictionary=True,
    skip_compression=None,
    column_encoding=None,
    column_type_length=None,
    output_as_binary=None,
    store_schema=False,
):
    """Wraps `to_parquet` to write partitioned Parquet datasets.
    For each combination of partition group and value,
    subdirectories are created as follows:

    .. code-block:: bash

        root_dir/
            group=value1
                <filename>.parquet
            ...
            group=valueN
                <filename>.parquet

    Parameters
    ----------
    df : cudf.DataFrame
    root_path : string,
        The root directory of the dataset
    compression : {'snappy', 'ZSTD', None}, default 'snappy'
        Name of the compression to use. Use ``None`` for no compression.
    filename : string, default None
        The file name to use (within each partition directory). If None,
        a random uuid4 hex string will be used for each file name.
    partition_cols : list,
        Column names by which to partition the dataset.
        Columns are partitioned in the order they are given.
    fs : FileSystem, default None
        If nothing passed, paths assumed to be found in the local on-disk
        filesystem
    preserve_index : bool, default False
        Preserve index values in each parquet file.
    return_metadata : bool, default False
        Return parquet metadata for written data. Returned metadata will
        include the file-path metadata (relative to `root_path`).
    int96_timestamps : bool, default False
        If ``True``, write timestamps in int96 format. This will convert
        timestamps from timestamp[ns], timestamp[ms], timestamp[s], and
        timestamp[us] to the int96 format, which is the number of Julian
        days and the number of nanoseconds since midnight of 1970-01-01.
        If ``False``, timestamps will not be altered.
    row_group_size_bytes: integer or None, default None
        Maximum size of each stripe of the output.
        If None, 134217728 (128MB) will be used.
    row_group_size_rows: integer or None, default None
        Maximum number of rows of each stripe of the output.
        If None, 1000000 will be used.
    max_page_size_bytes: integer or None, default None
        Maximum uncompressed size of each page of the output.
        If None, 524288 (512KB) will be used.
    max_page_size_rows: integer or None, default None
        Maximum number of rows of each page of the output.
        If None, 20000 will be used.
    storage_options : dict, optional, default None
        Extra options that make sense for a particular storage connection,
        e.g. host, port, username, password, etc. For HTTP(S) URLs the
        key-value pairs are forwarded to ``urllib.request.Request`` as
        header options. For other URLs (e.g. starting with "s3://", and
        "gcs://") the key-value pairs are forwarded to ``fsspec.open``.
        Please see ``fsspec`` and ``urllib`` for more details.
    force_nullable_schema : bool, default False.
        If True, writes all columns as `null` in schema.
        If False, columns are written as `null` if they contain null values,
        otherwise as `not null`.
    header_version : {{'1.0', '2.0'}}, default "1.0"
        Controls whether to use version 1.0 or version 2.0 page headers when
        encoding. Version 1.0 is more portable, but version 2.0 enables the
        use of newer encoding schemes.
    force_nullable_schema : bool, default False.
        If True, writes all columns as `null` in schema.
        If False, columns are written as `null` if they contain null values,
        otherwise as `not null`.
    skip_compression : set, optional, default None
        If a column name is present in the set, that column will not be compressed,
        regardless of the ``compression`` setting.
    column_encoding : dict, optional, default None
        Sets the page encoding to use on a per-column basis. The key is a column
        name, and the value is one of: 'PLAIN', 'DICTIONARY', 'DELTA_BINARY_PACKED',
        'DELTA_LENGTH_BYTE_ARRAY', 'DELTA_BYTE_ARRAY', 'BYTE_STREAM_SPLIT', or
        'USE_DEFAULT'.
    column_type_length : dict, optional, default None
        Specifies the width in bytes of ``FIXED_LEN_BYTE_ARRAY`` column elements.
        The key is a column name and the value is an integer. The named column
        will be output as unannotated binary (i.e. the column will behave as if
        ``output_as_binary`` was set).
    output_as_binary : set, optional, default None
        If a column name is present in the set, that column will be output as
        unannotated binary, rather than the default 'UTF-8'.
    store_schema : bool, default False
        If ``True``, enable computing and writing arrow schema to Parquet
        file footer's key-value metadata section for faithful round-tripping.
    """

    fs = ioutils._ensure_filesystem(fs, root_path, storage_options)
    fs.mkdirs(root_path, exist_ok=True)

    if partition_cols is not None and len(partition_cols) > 0:
        (
            full_paths,
            metadata_file_paths,
            grouped_df,
            part_offsets,
            _,
        ) = _get_partitioned(
            df=df,
            root_path=root_path,
            partition_cols=partition_cols,
            filename=filename,
            fs=fs,
            preserve_index=preserve_index,
            storage_options=storage_options,
        )
        metadata_file_path = metadata_file_paths if return_metadata else None
        metadata = to_parquet(
            df=grouped_df,
            path=full_paths,
            compression=compression,
            index=preserve_index,
            partition_offsets=part_offsets,
            storage_options=storage_options,
            metadata_file_path=metadata_file_path,
            statistics=statistics,
            int96_timestamps=int96_timestamps,
            row_group_size_bytes=row_group_size_bytes,
            row_group_size_rows=row_group_size_rows,
            max_page_size_bytes=max_page_size_bytes,
            max_page_size_rows=max_page_size_rows,
            force_nullable_schema=force_nullable_schema,
            header_version=header_version,
            use_dictionary=use_dictionary,
            skip_compression=skip_compression,
            column_encoding=column_encoding,
            column_type_length=column_type_length,
            output_as_binary=output_as_binary,
            store_schema=store_schema,
        )

    else:
        filename = filename or _generate_filename()
        full_path = fs.sep.join([root_path, filename])

        metadata_file_path = filename if return_metadata else None

        metadata = df.to_parquet(
            path=full_path,
            compression=compression,
            index=preserve_index,
            storage_options=storage_options,
            metadata_file_path=metadata_file_path,
            statistics=statistics,
            int96_timestamps=int96_timestamps,
            row_group_size_bytes=row_group_size_bytes,
            row_group_size_rows=row_group_size_rows,
            max_page_size_bytes=max_page_size_bytes,
            max_page_size_rows=max_page_size_rows,
            force_nullable_schema=force_nullable_schema,
            header_version=header_version,
            use_dictionary=use_dictionary,
            skip_compression=skip_compression,
            column_encoding=column_encoding,
            column_type_length=column_type_length,
            output_as_binary=output_as_binary,
            store_schema=store_schema,
        )

    return metadata


@ioutils.doc_read_parquet_metadata()
@_performance_tracking
def read_parquet_metadata(filepath_or_buffer):
    """{docstring}"""
    # Multiple sources are passed as a list. If a single source is passed,
    # wrap it in a list for unified processing downstream.
    if not is_list_like(filepath_or_buffer):
        filepath_or_buffer = [filepath_or_buffer]

    # Start by trying to construct a filesystem object
    fs, paths = ioutils._get_filesystem_and_paths(
        path_or_data=filepath_or_buffer, storage_options=None
    )

    # Check if filepath or buffer
    filepath_or_buffer = paths if paths else filepath_or_buffer

    # List of filepaths or buffers
    filepaths_or_buffers = []

    for source in filepath_or_buffer:
        tmp_source, compression = ioutils.get_reader_filepath_or_buffer(
            path_or_data=source,
            compression=None,
            fs=fs,
            use_python_file_object=None,
            open_file_options=None,
            storage_options=None,
            bytes_per_thread=None,
        )

        if compression is not None:
            raise ValueError(
                "URL content-encoding decompression is not supported"
            )
        if isinstance(tmp_source, list):
            filepath_or_buffer.extend(tmp_source)
        else:
            filepaths_or_buffers.append(tmp_source)

    return libparquet.read_parquet_metadata(filepaths_or_buffers)


@_performance_tracking
def _process_dataset(
    paths,
    fs,
    filters=None,
    row_groups=None,
    categorical_partitions=True,
    dataset_kwargs=None,
):
    # Returns:
    #     file_list - Expanded/filtered list of paths
    #     row_groups - Filtered list of row-group selections
    #     partition_keys - list of partition keys for each file
    #     partition_categories - Categories for each partition

    # The general purpose of this function is to (1) expand
    # directory input into a list of paths (using the pyarrow
    # dataset API), (2) to apply row-group filters, and (3)
    # to discover directory-partitioning information

    # Deal with case that the user passed in a directory name
    file_list = paths
    if len(paths) == 1 and ioutils.is_directory(paths[0]):
        paths = ioutils.stringify_pathlike(paths[0])

    # Convert filters to ds.Expression
    if filters is not None:
        from pyarrow.parquet import filters_to_expression

        filters = filters_to_expression(filters)

    # Initialize ds.FilesystemDataset
    # TODO: Remove the if len(paths) workaround after following bug is fixed:
    # https://issues.apache.org/jira/browse/ARROW-16438
    dataset = ds.dataset(
        source=paths[0] if len(paths) == 1 else paths,
        filesystem=fs,
        **(
            dataset_kwargs
            or {
                "format": "parquet",
                "partitioning": "hive",
            }
        ),
    )

    file_list = dataset.files
    if len(file_list) == 0:
        raise FileNotFoundError(f"{paths} could not be resolved to any files")

    # Deal with directory partitioning
    # Get all partition keys (without filters)
    partition_categories = defaultdict(list)
    file_fragment = None
    for file_fragment in dataset.get_fragments():
        keys = ds._get_partition_keys(file_fragment.partition_expression)
        if not (keys or partition_categories):
            # Bail - This is not a directory-partitioned dataset
            break
        for k, v in keys.items():
            if v not in partition_categories[k]:
                partition_categories[k].append(v)
        if not categorical_partitions:
            # Bail - We don't need to discover all categories.
            # We only need to save the partition keys from this
            # first `file_fragment`
            break

    if partition_categories and file_fragment is not None:
        # Check/correct order of `categories` using last file_frag,
        # because `_get_partition_keys` does NOT preserve the
        # partition-hierarchy order of the keys.
        cat_keys = [
            part.split("=")[0]
            for part in file_fragment.path.split(fs.sep)
            if "=" in part
        ]
        if set(partition_categories) == set(cat_keys):
            partition_categories = {
                k: partition_categories[k]
                for k in cat_keys
                if k in partition_categories
            }

    # If we do not have partitioned data and
    # are not filtering, we can return here
    if filters is None and not partition_categories:
        return file_list, row_groups, [], {}

    # Record initial row_groups input
    row_groups_map = {}
    if row_groups is not None:
        # Make sure paths and row_groups map 1:1
        # and save the initial mapping
        if len(paths) != len(file_list):
            raise ValueError(
                "Cannot specify a row_group selection for a directory path."
            )
        row_groups_map = {path: rgs for path, rgs in zip(paths, row_groups)}

    # Apply filters and discover partition columns
    partition_keys = []
    if partition_categories or filters is not None:
        file_list = []
        if filters is not None:
            row_groups = []
        for file_fragment in dataset.get_fragments(filter=filters):
            path = file_fragment.path

            # Extract hive-partition keys, and make sure they
            # are ordered the same as they are in `partition_categories`
            if partition_categories:
                raw_keys = ds._get_partition_keys(
                    file_fragment.partition_expression
                )
                partition_keys.append(
                    [
                        (name, raw_keys[name])
                        for name in partition_categories.keys()
                    ]
                )

            # Apply row-group filtering
            selection = row_groups_map.get(path, None)
            if selection is not None or filters is not None:
                filtered_row_groups = [
                    rg_info.id
                    for rg_fragment in file_fragment.split_by_row_group(
                        filters,
                        schema=dataset.schema,
                    )
                    for rg_info in rg_fragment.row_groups
                ]
            file_list.append(path)
            if filters is not None:
                if selection is None:
                    row_groups.append(filtered_row_groups)
                else:
                    row_groups.append(
                        [
                            rg_id
                            for rg_id in filtered_row_groups
                            if rg_id in selection
                        ]
                    )

    return (
        file_list,
        row_groups,
        partition_keys,
        partition_categories if categorical_partitions else {},
    )


@ioutils.doc_read_parquet()
@_performance_tracking
def read_parquet(
    filepath_or_buffer,
    engine="cudf",
    columns=None,
    storage_options=None,
    filters=None,
    row_groups=None,
    use_pandas_metadata=True,
    use_python_file_object=None,
    categorical_partitions=True,
    open_file_options=None,
    bytes_per_thread=None,
    dataset_kwargs=None,
    *args,
    **kwargs,
):
    """{docstring}"""
    if engine not in {"cudf", "pyarrow"}:
        raise ValueError(
            f"Only supported engines are {{'cudf', 'pyarrow'}}, got {engine=}"
        )
    # Do not allow the user to set file-opening options
    # when `use_python_file_object=False` is specified
    if use_python_file_object is False:
        if open_file_options:
            raise ValueError(
                "open_file_options is not currently supported when "
                "use_python_file_object is set to False."
            )
        open_file_options = {}

    if bytes_per_thread is None:
        bytes_per_thread = ioutils._BYTES_PER_THREAD_DEFAULT

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

    # Check columns input
    if columns is not None:
        if not is_list_like(columns):
            raise ValueError("Expected list like for columns")

    # Start by trying construct a filesystem object, so we
    # can apply filters on remote file-systems
    fs, paths = ioutils._get_filesystem_and_paths(
        path_or_data=filepath_or_buffer, storage_options=storage_options
    )

    # Normalize and validate filters
    filters = _normalize_filters(filters)

    # Use pyarrow dataset to detect/process directory-partitioned
    # data and apply filters. Note that we can only support partitioned
    # data and filtering if the input is a single directory or list of
    # paths.
    partition_keys = []
    partition_categories = {}
    if fs and paths:
        (
            paths,
            row_groups,
            partition_keys,
            partition_categories,
        ) = _process_dataset(
            paths=paths,
            fs=fs,
            filters=filters,
            row_groups=row_groups,
            categorical_partitions=categorical_partitions,
            dataset_kwargs=dataset_kwargs,
        )
    filepath_or_buffer = paths if paths else filepath_or_buffer

    filepaths_or_buffers = []
    if use_python_file_object:
        open_file_options = _default_open_file_options(
            open_file_options=open_file_options,
            columns=columns,
            row_groups=row_groups,
            fs=fs,
        )
    have_nativefile = any(
        isinstance(source, pa.NativeFile) for source in filepath_or_buffer
    )
    for source in filepath_or_buffer:
        tmp_source, compression = ioutils.get_reader_filepath_or_buffer(
            path_or_data=source,
            compression=None,
            fs=fs,
            use_python_file_object=use_python_file_object,
            open_file_options=open_file_options,
            storage_options=storage_options,
            bytes_per_thread=bytes_per_thread,
        )

        if compression is not None:
            raise ValueError(
                "URL content-encoding decompression is not supported"
            )
        if isinstance(tmp_source, list):
            filepath_or_buffer.extend(tmp_source)
        else:
            filepaths_or_buffers.append(tmp_source)

    # Warn user if they are not using cudf for IO
    # (There is a good chance this was not the intention)
    if engine != "cudf":
        warnings.warn(
            "Using CPU via PyArrow to read Parquet dataset. "
            "This option is both inefficient and unstable!"
        )
        if filters is not None:
            warnings.warn(
                "Parquet row-group filtering is only supported with "
                "'engine=cudf'. Use pandas or pyarrow API directly "
                "for full CPU-based filtering functionality."
            )

    # Make sure we read in the columns needed for row-wise
    # filtering after IO. This means that one or more columns
    # will be dropped almost immediately after IO. However,
    # we do NEED these columns for accurate filtering.
    projected_columns = None
    if columns and filters:
        projected_columns = columns
        columns = sorted(
            set(v[0] for v in itertools.chain.from_iterable(filters))
            | set(columns)
        )

    # Convert parquet data to a cudf.DataFrame

    # Don't want to warn if use_python_file_object causes us to get
    # a NativeFile (there is a separate deprecation warning for that)
    with maybe_filter_deprecation(
        not have_nativefile,
        message="Support for reading pyarrow's NativeFile is deprecated",
        category=FutureWarning,
    ):
        df = _parquet_to_frame(
            filepaths_or_buffers,
            engine,
            *args,
            columns=columns,
            row_groups=row_groups,
            use_pandas_metadata=use_pandas_metadata,
            partition_keys=partition_keys,
            partition_categories=partition_categories,
            dataset_kwargs=dataset_kwargs,
            **kwargs,
        )
    # Apply filters row-wise (if any are defined), and return
    df = _apply_post_filters(df, filters)
    if projected_columns:
        # Elements of `projected_columns` may now be in the index.
        # We must filter these names from our projection
        projected_columns = [
            col for col in projected_columns if col in df._column_names
        ]
        return df[projected_columns]
    return df


def _normalize_filters(filters: list | None) -> list[list[tuple]] | None:
    # Utility to normalize and validate the `filters`
    # argument to `read_parquet`
    if not filters:
        return None

    msg = (
        f"filters must be None, or non-empty List[Tuple] "
        f"or List[List[Tuple]]. Got {filters}"
    )
    if not isinstance(filters, list):
        raise TypeError(msg)

    def _validate_predicate(item):
        if not isinstance(item, tuple) or len(item) != 3:
            raise TypeError(
                f"Predicate must be Tuple[str, str, Any], " f"got {predicate}."
            )

    filters = filters if isinstance(filters[0], list) else [filters]
    for conjunction in filters:
        if not conjunction or not isinstance(conjunction, list):
            raise TypeError(msg)
        for predicate in conjunction:
            _validate_predicate(predicate)

    return filters


def _apply_post_filters(
    df: cudf.DataFrame, filters: list[list[tuple]] | None
) -> cudf.DataFrame:
    """Apply DNF filters to an in-memory DataFrame

    Disjunctive normal form (DNF) means that the inner-most
    tuple describes a single column predicate. These inner
    predicates are combined with an AND conjunction into a
    larger predicate. The outer-most list then combines all
    of the combined filters with an OR disjunction.
    """

    if not filters:
        # No filters to apply
        return df

    def _handle_in(column: cudf.Series, value, *, negate) -> cudf.Series:
        if not isinstance(value, (list, set, tuple)):
            raise TypeError(
                "Value of 'in'/'not in' filter must be a list, set, or tuple."
            )
        return ~column.isin(value) if negate else column.isin(value)

    def _handle_is(column: cudf.Series, value, *, negate) -> cudf.Series:
        if value not in {np.nan, None}:
            raise TypeError(
                "Value of 'is'/'is not' filter must be np.nan or None."
            )
        return ~column.isna() if negate else column.isna()

    handlers: dict[str, Callable] = {
        "==": operator.eq,
        "!=": operator.ne,
        "<": operator.lt,
        "<=": operator.le,
        ">": operator.gt,
        ">=": operator.ge,
        "in": partial(_handle_in, negate=False),
        "not in": partial(_handle_in, negate=True),
        "is": partial(_handle_is, negate=False),
        "is not": partial(_handle_is, negate=True),
    }

    # Can re-set the index before returning if we filter
    # out rows from a DataFrame with a default RangeIndex
    # (to reduce memory usage)
    reset_index = (
        isinstance(df.index, cudf.RangeIndex)
        and df.index.name is None
        and df.index.start == 0
        and df.index.step == 1
    )

    try:
        selection: cudf.Series = reduce(
            operator.or_,
            (
                reduce(
                    operator.and_,
                    (
                        handlers[op](df[column], value)
                        for (column, op, value) in expr
                    ),
                )
                for expr in filters
            ),
        )
        if reset_index:
            return df[selection].reset_index(drop=True)
        return df[selection]
    except (KeyError, TypeError):
        warnings.warn(
            f"Row-wise filtering failed in read_parquet for {filters}"
        )
        return df


@_performance_tracking
def _parquet_to_frame(
    paths_or_buffers,
    *args,
    row_groups=None,
    partition_keys=None,
    partition_categories=None,
    dataset_kwargs=None,
    **kwargs,
):
    # If this is not a partitioned read, only need
    # one call to `_read_parquet`
    if not partition_keys:
        return _read_parquet(
            paths_or_buffers,
            *args,
            row_groups=row_groups,
            **kwargs,
        )

    partition_meta = None
    partitioning = (dataset_kwargs or {}).get("partitioning", None)
    if hasattr(partitioning, "schema"):
        partition_meta = cudf.DataFrame.from_arrow(
            partitioning.schema.empty_table()
        )

    # For partitioned data, we need a distinct read for each
    # unique set of partition keys. Therefore, we start by
    # aggregating all paths with matching keys using a dict
    plan = {}
    for i, (keys, path) in enumerate(zip(partition_keys, paths_or_buffers)):
        rgs = row_groups[i] if row_groups else None
        tkeys = tuple(keys)
        if tkeys in plan:
            plan[tkeys][0].append(path)
            if rgs is not None:
                plan[tkeys][1].append(rgs)
        else:
            plan[tkeys] = ([path], None if rgs is None else [rgs])

    dfs = []
    for part_key, (key_paths, key_row_groups) in plan.items():
        # Add new DataFrame to our list
        dfs.append(
            _read_parquet(
                key_paths,
                *args,
                row_groups=key_row_groups,
                **kwargs,
            )
        )
        # Add partition columns to the last DataFrame
        for name, value in part_key:
            _len = len(dfs[-1])
            if partition_categories and name in partition_categories:
                # Build the categorical column from `codes`
                codes = as_column(
                    partition_categories[name].index(value),
                    length=_len,
                )
                dfs[-1][name] = build_categorical_column(
                    categories=partition_categories[name],
                    codes=codes,
                    size=codes.size,
                    offset=codes.offset,
                    ordered=False,
                )
            else:
                # Not building categorical columns, so
                # `value` is already what we want
                _dtype = (
                    partition_meta[name].dtype
                    if partition_meta is not None
                    else None
                )
                if pd.isna(value):
                    dfs[-1][name] = column_empty(
                        row_count=_len,
                        dtype=_dtype,
                        masked=True,
                    )
                else:
                    dfs[-1][name] = as_column(
                        value,
                        dtype=_dtype,
                        length=_len,
                    )

    if len(dfs) > 1:
        # Concatenate dfs and return.
        # Assume we can ignore the index if it has no name.
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", FutureWarning)
            res = cudf.concat(dfs, ignore_index=dfs[-1].index.name is None)
        return res
    else:
        return dfs[0]


@_performance_tracking
def _read_parquet(
    filepaths_or_buffers,
    engine,
    columns=None,
    row_groups=None,
    use_pandas_metadata=None,
    *args,
    **kwargs,
):
    # Simple helper function to dispatch between
    # cudf and pyarrow to read parquet data
    if engine == "cudf":
        if kwargs:
            raise ValueError(
                "cudf engine doesn't support the "
                f"following keyword arguments: {list(kwargs.keys())}"
            )
        if args:
            raise ValueError(
                "cudf engine doesn't support the "
                f"following positional arguments: {list(args)}"
            )
        if cudf.get_option("io.parquet.low_memory"):
            return libparquet.ParquetReader(
                filepaths_or_buffers,
                columns=columns,
                row_groups=row_groups,
                use_pandas_metadata=use_pandas_metadata,
            ).read()
        else:
            return libparquet.read_parquet(
                filepaths_or_buffers,
                columns=columns,
                row_groups=row_groups,
                use_pandas_metadata=use_pandas_metadata,
            )
    else:
        if (
            isinstance(filepaths_or_buffers, list)
            and len(filepaths_or_buffers) == 1
        ):
            filepaths_or_buffers = filepaths_or_buffers[0]

        return cudf.DataFrame.from_pandas(
            pd.read_parquet(
                filepaths_or_buffers,
                columns=columns,
                engine=engine,
                *args,
                **kwargs,
            )
        )


@ioutils.doc_to_parquet()
@_performance_tracking
def to_parquet(
    df,
    path,
    engine="cudf",
    compression="snappy",
    index=None,
    partition_cols=None,
    partition_file_name=None,
    partition_offsets=None,
    statistics="ROWGROUP",
    metadata_file_path=None,
    int96_timestamps=False,
    row_group_size_bytes=ioutils._ROW_GROUP_SIZE_BYTES_DEFAULT,
    row_group_size_rows=None,
    max_page_size_bytes=None,
    max_page_size_rows=None,
    max_dictionary_size=None,
    storage_options=None,
    return_metadata=False,
    force_nullable_schema=False,
    header_version="1.0",
    use_dictionary=True,
    skip_compression=None,
    column_encoding=None,
    column_type_length=None,
    output_as_binary=None,
    store_schema=False,
    *args,
    **kwargs,
):
    """{docstring}"""

    if engine == "cudf":
        if kwargs:
            raise ValueError(
                "cudf engine doesn't support the "
                f"following keyword arguments: {list(kwargs.keys())}"
            )
        if args:
            raise ValueError(
                "cudf engine doesn't support the "
                f"following positional arguments: {list(args)}"
            )
        # Ensure that no columns dtype is 'category'
        for col in df._column_names:
            if partition_cols is None or col not in partition_cols:
                if df[col].dtype.name == "category":
                    raise ValueError(
                        "'category' column dtypes are currently not "
                        + "supported by the gpu accelerated parquet writer"
                    )

        if partition_cols:
            if metadata_file_path is not None:
                warnings.warn(
                    "metadata_file_path will be ignored/overwritten when "
                    "partition_cols are provided. To request returning the "
                    "metadata binary blob, pass `return_metadata=True`"
                )

            return write_to_dataset(
                df,
                filename=partition_file_name,
                partition_cols=partition_cols,
                root_path=path,
                preserve_index=index,
                compression=compression,
                statistics=statistics,
                int96_timestamps=int96_timestamps,
                row_group_size_bytes=row_group_size_bytes,
                row_group_size_rows=row_group_size_rows,
                max_page_size_bytes=max_page_size_bytes,
                max_page_size_rows=max_page_size_rows,
                return_metadata=return_metadata,
                storage_options=storage_options,
                force_nullable_schema=force_nullable_schema,
                header_version=header_version,
                use_dictionary=use_dictionary,
                skip_compression=skip_compression,
                column_encoding=column_encoding,
                column_type_length=column_type_length,
                output_as_binary=output_as_binary,
                store_schema=store_schema,
            )

        partition_info = (
            [
                (i, j - i)
                for i, j in zip(partition_offsets, partition_offsets[1:])
            ]
            if partition_offsets is not None
            else None
        )
        return _write_parquet(
            df,
            paths=path if is_list_like(path) else [path],
            compression=compression,
            index=index,
            statistics=statistics,
            metadata_file_path=metadata_file_path,
            int96_timestamps=int96_timestamps,
            row_group_size_bytes=row_group_size_bytes,
            row_group_size_rows=row_group_size_rows,
            max_page_size_bytes=max_page_size_bytes,
            max_page_size_rows=max_page_size_rows,
            max_dictionary_size=max_dictionary_size,
            partitions_info=partition_info,
            storage_options=storage_options,
            force_nullable_schema=force_nullable_schema,
            header_version=header_version,
            use_dictionary=use_dictionary,
            skip_compression=skip_compression,
            column_encoding=column_encoding,
            column_type_length=column_type_length,
            output_as_binary=output_as_binary,
            write_arrow_schema=store_schema,
        )

    else:
        import pyarrow.parquet as pq

        if partition_offsets is not None:
            warnings.warn(
                "partition_offsets will be ignored when engine is not cudf"
            )

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


def _generate_filename():
    return uuid4().hex + ".parquet"


def _get_estimated_file_size(df):
    # NOTE: This is purely a guesstimation method
    # and the y = mx+c has been arrived
    # after extensive experimentation of parquet file size
    # vs dataframe sizes.
    df_mem_usage = df.memory_usage().sum()
    # Parquet file size of a dataframe with all unique values
    # seems to be 1/1.5 times as that of on GPU for >10000 rows
    # and 0.6 times else-wise.
    # Y(file_size) = M(0.6) * X(df_mem_usage) + C(705)
    file_size = int((df_mem_usage * 0.6) + 705)
    # 1000 Bytes accounted for row-group metadata.
    # A parquet file takes roughly ~810 Bytes of metadata per column.
    file_size = file_size + 1000 + (810 * df.shape[1])
    return file_size


@_performance_tracking
def _get_partitioned(
    df,
    root_path,
    partition_cols,
    filename=None,
    fs=None,
    preserve_index=False,
    storage_options=None,
):
    fs = ioutils._ensure_filesystem(
        fs, root_path, storage_options=storage_options
    )
    fs.mkdirs(root_path, exist_ok=True)

    part_names, grouped_df, part_offsets = _get_groups_and_offsets(
        df, partition_cols, preserve_index
    )

    full_paths = []
    metadata_file_paths = []
    for keys in part_names.itertuples(index=False):
        subdir = fs.sep.join(
            [
                _hive_dirname(name, val)
                for name, val in zip(partition_cols, keys)
            ]
        )
        prefix = fs.sep.join([root_path, subdir])
        fs.mkdirs(prefix, exist_ok=True)
        filename = filename or _generate_filename()
        full_path = fs.sep.join([prefix, filename])
        full_paths.append(full_path)
        metadata_file_paths.append(fs.sep.join([subdir, filename]))

    return full_paths, metadata_file_paths, grouped_df, part_offsets, filename


@_performance_tracking
def _get_groups_and_offsets(
    df,
    partition_cols,
    preserve_index=False,
    **kwargs,
):
    if not (set(df._data) - set(partition_cols)):
        warnings.warn("No data left to save outside partition columns")

    _, part_offsets, part_keys, grouped_df = df.groupby(
        partition_cols,
        dropna=False,
    )._grouped()
    if not preserve_index:
        grouped_df.reset_index(drop=True, inplace=True)
    grouped_df.drop(columns=partition_cols, inplace=True)
    # Copy the entire keys df in one operation rather than using iloc
    part_names = (
        part_keys.take(part_offsets[:-1])
        .to_pandas(nullable=True)
        .to_frame(index=False)
    )
    return part_names, grouped_df, part_offsets


ParquetWriter = libparquet.ParquetWriter


def _parse_bytes(s):
    """Parse byte string to numbers

    Utility function vendored from Dask.

    >>> _parse_bytes('100')
    100
    >>> _parse_bytes('100 MB')
    100000000
    >>> _parse_bytes('100M')
    100000000
    >>> _parse_bytes('5kB')
    5000
    >>> _parse_bytes('5.4 kB')
    5400
    >>> _parse_bytes('1kiB')
    1024
    >>> _parse_bytes('1e6')
    1000000
    >>> _parse_bytes('1e6 kB')
    1000000000
    >>> _parse_bytes('MB')
    1000000
    >>> _parse_bytes(123)
    123
    >>> _parse_bytes('5 foos')
    Traceback (most recent call last):
        ...
    ValueError: Could not interpret 'foos' as a byte unit
    """
    if isinstance(s, (int, float)):
        return int(s)
    s = s.replace(" ", "")
    if not any(char.isdigit() for char in s):
        s = "1" + s

    for i in range(len(s) - 1, -1, -1):
        if not s[i].isalpha():
            break
    index = i + 1

    prefix = s[:index]
    suffix = s[index:]

    try:
        n = float(prefix)
    except ValueError as e:
        raise ValueError(
            "Could not interpret '%s' as a number" % prefix
        ) from e

    try:
        multiplier = BYTE_SIZES[suffix.lower()]
    except KeyError as e:
        raise ValueError(
            "Could not interpret '%s' as a byte unit" % suffix
        ) from e

    result = n * multiplier
    return int(result)


class ParquetDatasetWriter:
    """
    Write a parquet file or dataset incrementally

    Parameters
    ----------
    path : str
        A local directory path or S3 URL. Will be used as root directory
        path while writing a partitioned dataset.
    partition_cols : list
        Column names by which to partition the dataset
        Columns are partitioned in the order they are given
    index : bool, default None
        If ``True``, include the dataframe's index(es) in the file output.
        If ``False``, they will not be written to the file. If ``None``,
        index(es) other than RangeIndex will be saved as columns.
    compression : {'snappy', None}, default 'snappy'
        Name of the compression to use. Use ``None`` for no compression.
    statistics : {'ROWGROUP', 'PAGE', 'COLUMN', 'NONE'}, default 'ROWGROUP'
        Level at which column statistics should be included in file.
    max_file_size : int or str, default None
        A file size that cannot be exceeded by the writer.
        It is in bytes, if the input is int.
        Size can also be a str in form or "10 MB", "1 GB", etc.
        If this parameter is used, it is mandatory to pass
        `file_name_prefix`.
    file_name_prefix : str
        This is a prefix to file names generated only when
        `max_file_size` is specified.
    storage_options : dict, optional, default None
        Extra options that make sense for a particular storage connection,
        e.g. host, port, username, password, etc. For HTTP(S) URLs the
        key-value pairs are forwarded to ``urllib.request.Request`` as
        header options. For other URLs (e.g. starting with "s3://", and
        "gcs://") the key-value pairs are forwarded to ``fsspec.open``.
        Please see ``fsspec`` and ``urllib`` for more details.


    Examples
    --------
    Using a context

    >>> df1 = cudf.DataFrame({"a": [1, 1, 2, 2, 1], "b": [9, 8, 7, 6, 5]})
    >>> df2 = cudf.DataFrame({"a": [1, 3, 3, 1, 3], "b": [4, 3, 2, 1, 0]})
    >>> with ParquetDatasetWriter("./dataset", partition_cols=["a"]) as cw:
    ...     cw.write_table(df1)
    ...     cw.write_table(df2)

    By manually calling ``close()``

    >>> cw = ParquetDatasetWriter("./dataset", partition_cols=["a"])
    >>> cw.write_table(df1)
    >>> cw.write_table(df2)
    >>> cw.close()

    Both the methods will generate the same directory structure

    .. code-block:: none

        dataset/
            a=1
                <filename>.parquet
            a=2
                <filename>.parquet
            a=3
                <filename>.parquet

    """

    @_performance_tracking
    def __init__(
        self,
        path,
        partition_cols,
        index=None,
        compression="snappy",
        statistics="ROWGROUP",
        max_file_size=None,
        file_name_prefix=None,
        storage_options=None,
    ) -> None:
        if isinstance(path, str) and path.startswith("s3://"):
            self.fs_meta = {"is_s3": True, "actual_path": path}
            self.dir_: tempfile.TemporaryDirectory | None = (
                tempfile.TemporaryDirectory()
            )
            self.path = self.dir_.name
        else:
            self.fs_meta = {}
            self.dir_ = None
            self.path = path

        self.common_args = {
            "index": index,
            "compression": compression,
            "statistics": statistics,
        }
        self.partition_cols = partition_cols
        # Collection of `ParquetWriter`s, and the corresponding
        # partition_col values they're responsible for
        self._chunked_writers: list[
            tuple[libparquet.ParquetWriter, list[str], str]
        ] = []
        # Map of partition_col values to their ParquetWriter's index
        # in self._chunked_writers for reverse lookup
        self.path_cw_map: dict[str, int] = {}
        self.storage_options = storage_options
        self.filename = file_name_prefix
        self.max_file_size = max_file_size
        if max_file_size is not None:
            if file_name_prefix is None:
                raise ValueError(
                    "file_name_prefix cannot be None if max_file_size is "
                    "passed"
                )
            self.max_file_size = _parse_bytes(max_file_size)

        self._file_sizes: dict[str, int] = {}

    @_performance_tracking
    def write_table(self, df):
        """
        Write a dataframe to the file/dataset
        """
        part_names, grouped_df, part_offsets = _get_groups_and_offsets(
            df=df,
            partition_cols=self.partition_cols,
            preserve_index=self.common_args["index"],
        )
        fs = ioutils._ensure_filesystem(None, self.path, None)
        fs.mkdirs(self.path, exist_ok=True)

        full_paths = []
        metadata_file_paths = []
        full_offsets = [0]

        for idx, keys in enumerate(part_names.itertuples(index=False)):
            subdir = fs.sep.join(
                [
                    f"{name}={val}"
                    for name, val in zip(self.partition_cols, keys)
                ]
            )
            prefix = fs.sep.join([self.path, subdir])
            fs.mkdirs(prefix, exist_ok=True)
            current_offset = (part_offsets[idx], part_offsets[idx + 1])
            num_chunks = 1
            parts = 1

            if self.max_file_size is not None:
                # get the current partition
                start, end = current_offset
                sliced_df = grouped_df[start:end]

                current_file_size = _get_estimated_file_size(sliced_df)
                if current_file_size > self.max_file_size:
                    # if the file is too large, compute metadata for
                    # smaller chunks
                    parts = math.ceil(current_file_size / self.max_file_size)
                    new_offsets = list(
                        range(start, end, int((end - start) / parts))
                    )[1:]
                    new_offsets.append(end)
                    num_chunks = len(new_offsets)
                    parts = len(new_offsets)
                    full_offsets.extend(new_offsets)
                else:
                    full_offsets.append(end)

                curr_file_num = 0
                num_chunks = 0
                while num_chunks < parts:
                    new_file_name = f"{self.filename}_{curr_file_num}.parquet"
                    new_full_path = fs.sep.join([prefix, new_file_name])

                    # Check if the same `new_file_name` exists and
                    # generate a `new_file_name`
                    while new_full_path in self._file_sizes and (
                        self._file_sizes[new_full_path]
                        + (current_file_size / parts)
                    ) > (self.max_file_size):
                        curr_file_num += 1
                        new_file_name = (
                            f"{self.filename}_{curr_file_num}.parquet"
                        )
                        new_full_path = fs.sep.join([prefix, new_file_name])

                    self._file_sizes[new_full_path] = self._file_sizes.get(
                        new_full_path, 0
                    ) + (current_file_size / parts)
                    full_paths.append(new_full_path)
                    metadata_file_paths.append(
                        fs.sep.join([subdir, new_file_name])
                    )
                    num_chunks += 1
                    curr_file_num += 1
            else:
                self.filename = self.filename or _generate_filename()
                full_path = fs.sep.join([prefix, self.filename])
                full_paths.append(full_path)
                metadata_file_paths.append(
                    fs.sep.join([subdir, self.filename])
                )
                full_offsets.append(current_offset[1])

        paths, metadata_file_paths, offsets = (
            full_paths,
            metadata_file_paths,
            full_offsets,
        )
        existing_cw_batch = defaultdict(dict)
        new_cw_paths = []
        partition_info = [(i, j - i) for i, j in zip(offsets, offsets[1:])]

        for path, part_info, meta_path in zip(
            paths,
            partition_info,
            metadata_file_paths,
        ):
            if path in self.path_cw_map:  # path is a currently open file
                cw_idx = self.path_cw_map[path]
                existing_cw_batch[cw_idx][path] = part_info
            else:  # path not currently handled by any chunked writer
                new_cw_paths.append((path, part_info, meta_path))

        # Write out the parts of grouped_df currently handled by existing cw's
        for cw_idx, path_to_part_info_map in existing_cw_batch.items():
            cw = self._chunked_writers[cw_idx][0]
            # match found paths with this cw's paths and nullify partition info
            # for partition_col values not in this batch
            this_cw_part_info = [
                path_to_part_info_map.get(path, (0, 0))
                for path in self._chunked_writers[cw_idx][1]
            ]
            cw.write_table(grouped_df, this_cw_part_info)

        if new_cw_paths:
            # Create new cw for unhandled paths encountered in this write_table
            new_paths, part_info, meta_paths = zip(*new_cw_paths)
            self._chunked_writers.append(
                (
                    ParquetWriter(new_paths, **self.common_args),
                    new_paths,
                    meta_paths,
                )
            )
            new_cw_idx = len(self._chunked_writers) - 1
            self.path_cw_map.update({k: new_cw_idx for k in new_paths})
            self._chunked_writers[-1][0].write_table(grouped_df, part_info)

    @_performance_tracking
    def close(self, return_metadata=False):
        """
        Close all open files and optionally return footer metadata as a binary
        blob
        """

        metadata = [
            cw.close(metadata_file_path=meta_path if return_metadata else None)
            for cw, _, meta_path in self._chunked_writers
        ]

        if self.fs_meta.get("is_s3", False):
            local_path = self.path
            s3_path = self.fs_meta["actual_path"]
            s3_file, _ = ioutils._get_filesystem_and_paths(
                s3_path, storage_options=self.storage_options
            )
            s3_file.put(local_path, s3_path, recursive=True)
            shutil.rmtree(self.path)

        if self.dir_ is not None:
            self.dir_.cleanup()

        if return_metadata:
            return (
                merge_parquet_filemetadata(metadata)
                if len(metadata) > 1
                else metadata[0]
            )

    def __enter__(self):
        return self

    def __exit__(self, *args):
        self.close()


def _default_open_file_options(
    open_file_options, columns, row_groups, fs=None
):
    """
    Set default fields in open_file_options.

    Copies and updates `open_file_options` to
    include column and row-group information
    under the "precache_options" key. By default,
    we set "method" to "parquet", but precaching
    will be disabled if the user chooses `method=None`

    Parameters
    ----------
    open_file_options : dict or None
    columns : list
    row_groups : list
    fs : fsspec.AbstractFileSystem, Optional
    """
    if fs and ioutils._is_local_filesystem(fs):
        # Quick return for local fs
        return open_file_options or {}
    # Assume remote storage if `fs` was not specified
    open_file_options = (open_file_options or {}).copy()
    precache_options = open_file_options.pop("precache_options", {}).copy()
    if precache_options.get("method", "parquet") == "parquet":
        precache_options.update(
            {
                "method": "parquet",
                "engine": precache_options.get("engine", "pyarrow"),
                "columns": columns,
                "row_groups": row_groups,
            }
        )
    open_file_options["precache_options"] = precache_options
    return open_file_options


def _hive_dirname(name, val):
    # Simple utility to produce hive directory name
    if pd.isna(val):
        val = "__HIVE_DEFAULT_PARTITION__"
    return f"{name}={val}"
