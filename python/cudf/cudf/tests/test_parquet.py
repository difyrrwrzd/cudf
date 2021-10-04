# Copyright (c) 2019-2021, NVIDIA CORPORATION.

import datetime
import math
import os
import pathlib
import random
from io import BytesIO
from string import ascii_letters

import cupy
import numpy as np
import pandas as pd
import pyarrow as pa
import pytest
from fsspec.core import get_fs_token_paths
from packaging import version
from pyarrow import fs as pa_fs, parquet as pq

import cudf
from cudf.io.parquet import ParquetWriter, merge_parquet_filemetadata
from cudf.testing import dataset_generator as dg
from cudf.testing._utils import (
    TIMEDELTA_TYPES,
    assert_eq,
    assert_exceptions_equal,
)


@pytest.fixture(scope="module")
def datadir(datadir):
    return datadir / "parquet"


@pytest.fixture(params=[1, 5, 10, 100])
def simple_pdf(request):
    types = [
        "bool",
        "int8",
        "int16",
        "int32",
        "int64",
        "uint8",
        "uint16",
        # "uint32", pandas promotes uint32 to int64
        # https://issues.apache.org/jira/browse/ARROW-9215
        "uint64",
        "float32",
        "float64",
    ]
    renamer = {
        "C_l0_g" + str(idx): "col_" + val for (idx, val) in enumerate(types)
    }
    typer = {"col_" + val: val for val in types}
    ncols = len(types)
    nrows = request.param

    # Create a pandas dataframe with random data of mixed types
    test_pdf = pd._testing.makeCustomDataframe(
        nrows=nrows, ncols=ncols, data_gen_f=lambda r, c: r, r_idx_type="i"
    )
    # Delete the name of the column index, and rename the row index
    test_pdf.columns.name = None
    test_pdf.index.name = "test_index"

    # Cast all the column dtypes to objects, rename them, and then cast to
    # appropriate types
    test_pdf = test_pdf.astype("object").rename(renamer, axis=1).astype(typer)

    return test_pdf


@pytest.fixture
def simple_gdf(simple_pdf):
    return cudf.DataFrame.from_pandas(simple_pdf)


def build_pdf(num_columns, day_resolution_timestamps):
    types = [
        "bool",
        "int8",
        "int16",
        "int32",
        "int64",
        "uint8",
        "uint16",
        # "uint32", pandas promotes uint32 to int64
        # https://issues.apache.org/jira/browse/ARROW-9215
        "uint64",
        "float32",
        "float64",
        "datetime64[ms]",
        "datetime64[us]",
        "str",
    ]
    renamer = {
        "C_l0_g" + str(idx): "col_" + val for (idx, val) in enumerate(types)
    }
    typer = {"col_" + val: val for val in types}
    ncols = len(types)
    nrows = num_columns.param

    # Create a pandas dataframe with random data of mixed types
    test_pdf = pd._testing.makeCustomDataframe(
        nrows=nrows, ncols=ncols, data_gen_f=lambda r, c: r, r_idx_type="i"
    )
    # Delete the name of the column index, and rename the row index
    test_pdf.columns.name = None
    test_pdf.index.name = "test_index"

    # Cast all the column dtypes to objects, rename them, and then cast to
    # appropriate types
    test_pdf = test_pdf.rename(renamer, axis=1).astype(typer)

    # make datetime64's a little more interesting by increasing the range of
    # dates note that pandas will convert these to ns timestamps, so care is
    # taken to avoid overflowing a ns timestamp. There is also the ability to
    # request timestamps be whole days only via `day_resolution_timestamps`.
    for t in [
        {
            "name": "datetime64[ms]",
            "nsDivisor": 1000000,
            "dayModulus": 86400000,
        },
        {
            "name": "datetime64[us]",
            "nsDivisor": 1000,
            "dayModulus": 86400000000,
        },
    ]:
        data = [
            np.random.randint(0, (0x7FFFFFFFFFFFFFFF / t["nsDivisor"]))
            for i in range(nrows)
        ]
        if day_resolution_timestamps:
            data = [int(d / t["dayModulus"]) * t["dayModulus"] for d in data]
        test_pdf["col_" + t["name"]] = pd.Series(
            np.asarray(data, dtype=t["name"])
        )

    # Create non-numeric categorical data otherwise parquet may typecast it
    data = [ascii_letters[np.random.randint(0, 52)] for i in range(nrows)]
    test_pdf["col_category"] = pd.Series(data, dtype="category")

    # Create non-numeric str data
    data = [ascii_letters[np.random.randint(0, 52)] for i in range(nrows)]
    test_pdf["col_str"] = pd.Series(data, dtype="str")

    return test_pdf


@pytest.fixture(params=[0, 1, 10, 100])
def pdf(request):
    return build_pdf(request, False)


@pytest.fixture(params=[0, 1, 10, 100])
def pdf_day_timestamps(request):
    return build_pdf(request, True)


@pytest.fixture
def gdf(pdf):
    return cudf.DataFrame.from_pandas(pdf)


@pytest.fixture
def gdf_day_timestamps(pdf_day_timestamps):
    return cudf.DataFrame.from_pandas(pdf_day_timestamps)


@pytest.fixture(params=["snappy", "gzip", "brotli", None, np.str_("snappy")])
def parquet_file(request, tmp_path_factory, pdf):
    fname = tmp_path_factory.mktemp("parquet") / "test.parquet"
    pdf.to_parquet(fname, engine="pyarrow", compression=request.param)
    return fname


@pytest.fixture(scope="module")
def rdg_seed():
    return int(os.environ.get("TEST_CUDF_RDG_SEED", "42"))


def make_pdf(nrows, ncolumns=1, nvalids=0, dtype=np.int64):
    test_pdf = pd._testing.makeCustomDataframe(
        nrows=nrows,
        ncols=1,
        data_gen_f=lambda r, c: r,
        dtype=dtype,
        r_idx_type="i",
    )
    test_pdf.columns.name = None

    # Randomly but reproducibly mark subset of rows as invalid
    random.seed(1337)
    mask = random.sample(range(nrows), nvalids)
    test_pdf[test_pdf.index.isin(mask)] = np.NaN

    return test_pdf


@pytest.fixture
def parquet_path_or_buf(datadir):
    fname = datadir / "spark_timestamp.snappy.parquet"
    try:
        with open(fname, "rb") as f:
            buffer = BytesIO(f.read())
    except Exception as excpr:
        if type(excpr).__name__ == "FileNotFoundError":
            pytest.skip(".parquet file is not found")
        else:
            print(type(excpr).__name__)

    def _make_parquet_path_or_buf(src):
        if src == "filepath":
            return str(fname)
        if src == "pathobj":
            return fname
        if src == "bytes_io":
            return buffer
        if src == "bytes":
            return buffer.getvalue()
        if src == "url":
            return fname.as_uri()

        raise ValueError("Invalid source type")

    yield _make_parquet_path_or_buf


@pytest.mark.filterwarnings("ignore:Using CPU")
@pytest.mark.parametrize("engine", ["pyarrow", "cudf"])
@pytest.mark.parametrize(
    "columns",
    [
        ["col_int8"],
        ["col_category"],
        ["col_int32", "col_float32"],
        ["col_int16", "col_float64", "col_int8"],
        None,
    ],
)
def test_parquet_reader_basic(parquet_file, columns, engine):
    expect = pd.read_parquet(parquet_file, columns=columns)
    got = cudf.read_parquet(parquet_file, engine=engine, columns=columns)
    if len(expect) == 0:
        expect = expect.reset_index(drop=True)
        got = got.reset_index(drop=True)
        if "col_category" in expect.columns:
            expect["col_category"] = expect["col_category"].astype("category")

    # PANDAS returns category objects whereas cuDF returns hashes
    if engine == "cudf":
        if "col_category" in expect.columns:
            expect = expect.drop(columns=["col_category"])
        if "col_category" in got.columns:
            got = got.drop(columns=["col_category"])

    assert_eq(expect, got, check_categorical=False)


@pytest.mark.filterwarnings("ignore:Using CPU")
@pytest.mark.parametrize("engine", ["cudf"])
def test_parquet_reader_empty_pandas_dataframe(tmpdir, engine):
    df = pd.DataFrame()
    fname = tmpdir.join("test_pq_reader_empty_pandas_dataframe.parquet")
    df.to_parquet(fname)
    assert os.path.exists(fname)
    expect = pd.read_parquet(fname)
    got = cudf.read_parquet(fname, engine=engine)
    expect = expect.reset_index(drop=True)
    got = got.reset_index(drop=True)

    assert_eq(expect, got)


@pytest.mark.parametrize("has_null", [False, True])
@pytest.mark.parametrize("strings_to_categorical", [False, True, None])
def test_parquet_reader_strings(tmpdir, strings_to_categorical, has_null):
    df = pd.DataFrame(
        [(1, "aaa", 9.0), (2, "bbb", 8.0), (3, "ccc", 7.0)],
        columns=pd.Index(list("abc")),
    )
    if has_null:
        df.at[1, "b"] = None
    fname = tmpdir.join("test_pq_reader_strings.parquet")
    df.to_parquet(fname)
    assert os.path.exists(fname)

    if strings_to_categorical is not None:
        gdf = cudf.read_parquet(
            fname, engine="cudf", strings_to_categorical=strings_to_categorical
        )
    else:
        gdf = cudf.read_parquet(fname, engine="cudf")

    if strings_to_categorical:
        if has_null:
            hash_ref = [989983842, None, 1169108191]
        else:
            hash_ref = [989983842, 429364346, 1169108191]
        assert gdf["b"].dtype == np.dtype("int32")
        assert_eq(
            gdf["b"], cudf.Series(hash_ref, dtype=np.dtype("int32"), name="b")
        )
    else:
        assert gdf["b"].dtype == np.dtype("object")
        assert_eq(gdf["b"], df["b"])


@pytest.mark.parametrize("columns", [None, ["b"]])
@pytest.mark.parametrize("index_col", ["b", "Nameless", None])
def test_parquet_reader_index_col(tmpdir, index_col, columns):
    df = pd.DataFrame({"a": range(3), "b": range(3, 6), "c": range(6, 9)})

    if index_col is None:
        # No index column
        df.reset_index(drop=True, inplace=True)
    elif index_col == "Nameless":
        # Index column but no name
        df.set_index("a", inplace=True)
        df.index.name = None
    else:
        # Index column as normal
        df.set_index(index_col, inplace=True)

    fname = tmpdir.join("test_pq_reader_index_col.parquet")

    # PANDAS' PyArrow backend always writes the index unless disabled
    df.to_parquet(fname, index=(False if index_col is None else True))
    assert os.path.exists(fname)

    pdf = pd.read_parquet(fname, columns=columns)
    gdf = cudf.read_parquet(fname, engine="cudf", columns=columns)

    assert_eq(pdf, gdf, check_categorical=False)


@pytest.mark.parametrize("pandas_compat", [True, False])
@pytest.mark.parametrize(
    "columns", [["a"], ["d"], ["a", "b"], ["a", "d"], None]
)
def test_parquet_reader_pandas_metadata(tmpdir, columns, pandas_compat):
    df = pd.DataFrame(
        {
            "a": range(6, 9),
            "b": range(3, 6),
            "c": range(6, 9),
            "d": ["abc", "def", "xyz"],
        }
    )
    df.set_index("b", inplace=True)

    fname = tmpdir.join("test_pq_reader_pandas_metadata.parquet")
    df.to_parquet(fname)
    assert os.path.exists(fname)

    # PANDAS `read_parquet()` and PyArrow `read_pandas()` always includes index
    # Instead, directly use PyArrow to optionally omit the index
    expect = pa.parquet.read_table(
        fname, columns=columns, use_pandas_metadata=pandas_compat
    ).to_pandas()
    got = cudf.read_parquet(
        fname, columns=columns, use_pandas_metadata=pandas_compat
    )

    if pandas_compat or columns is None or "b" in columns:
        assert got.index.name == "b"
    else:
        assert got.index.name is None
    assert_eq(expect, got, check_categorical=False)


def test_parquet_read_metadata(tmpdir, pdf):
    def num_row_groups(rows, group_size):
        return max(1, (rows + (group_size - 1)) // group_size)

    fname = tmpdir.join("metadata.parquet")
    row_group_size = 5
    pdf.to_parquet(fname, compression="snappy", row_group_size=row_group_size)

    num_rows, row_groups, col_names = cudf.io.read_parquet_metadata(fname)

    assert num_rows == len(pdf.index)
    assert row_groups == num_row_groups(num_rows, row_group_size)
    for a, b in zip(col_names, pdf.columns):
        assert a == b


def test_parquet_read_filtered(tmpdir, rdg_seed):
    # Generate data
    fname = tmpdir.join("filtered.parquet")
    dg.generate(
        fname,
        dg.Parameters(
            num_rows=2048,
            column_parameters=[
                dg.ColumnParameters(
                    cardinality=40,
                    null_frequency=0.05,
                    generator=lambda g: [g.address.city() for _ in range(40)],
                    is_sorted=False,
                ),
                dg.ColumnParameters(
                    40,
                    0.2,
                    lambda g: [g.person.age() for _ in range(40)],
                    True,
                ),
            ],
            seed=rdg_seed,
        ),
        format={"name": "parquet", "row_group_size": 64},
    )

    # Get dataframes to compare
    df = cudf.read_parquet(fname)
    df_filtered = cudf.read_parquet(fname, filters=[("1", ">", 60)])
    # PyArrow's read_table function does row-group-level filtering in addition
    # to applying given filters once the table has been read into memory.
    # Because of this, we aren't using PyArrow as a reference for testing our
    # row-group selection method since the only way to only select row groups
    # with PyArrow is with the method we use and intend to test.
    tbl_filtered = pq.read_table(
        fname, filters=[("1", ">", 60)], use_legacy_dataset=False
    )

    assert_eq(cudf.io.read_parquet_metadata(fname)[1], 2048 / 64)
    print(len(df_filtered))
    print(len(tbl_filtered))
    assert len(df_filtered) < len(df)
    assert len(tbl_filtered) <= len(df_filtered)


def test_parquet_read_filtered_everything(tmpdir):
    # Generate data
    fname = tmpdir.join("filtered_everything.parquet")
    df = pd.DataFrame({"x": range(10), "y": list("aabbccddee")})
    df.to_parquet(fname, row_group_size=2)

    # Check filter
    df_filtered = cudf.read_parquet(fname, filters=[("x", "==", 12)])
    assert_eq(len(df_filtered), 0)
    assert_eq(df_filtered["x"].dtype, "int64")
    assert_eq(df_filtered["y"].dtype, "object")


def test_parquet_read_filtered_multiple_files(tmpdir):
    # Generate data
    fname_0 = tmpdir.join("filtered_multiple_files_0.parquet")
    df = pd.DataFrame({"x": range(10), "y": list("aabbccddee")})
    df.to_parquet(fname_0, row_group_size=2)
    fname_1 = tmpdir.join("filtered_multiple_files_1.parquet")
    df = pd.DataFrame({"x": range(10), "y": list("aaccccddee")})
    df.to_parquet(fname_1, row_group_size=2)
    fname_2 = tmpdir.join("filtered_multiple_files_2.parquet")
    df = pd.DataFrame(
        {"x": [0, 1, 9, 9, 4, 5, 6, 7, 8, 9], "y": list("aabbzzddee")}
    )
    df.to_parquet(fname_2, row_group_size=2)

    # Check filter
    filtered_df = cudf.read_parquet(
        [fname_0, fname_1, fname_2], filters=[("x", "==", 2)]
    )
    assert_eq(
        filtered_df,
        cudf.DataFrame(
            {"x": [2, 3, 2, 3], "y": list("bbcc")}, index=[2, 3, 2, 3]
        ),
    )


@pytest.mark.skipif(
    version.parse(pa.__version__) < version.parse("1.0.1"),
    reason="pyarrow 1.0.0 needed for various operators and operand types",
)
@pytest.mark.parametrize(
    "predicate,expected_len",
    [
        ([[("x", "==", 0)], [("z", "==", 0)]], 4),
        ([("x", "==", 0), ("z", "==", 0)], 0),
        ([("x", "==", 0), ("z", "!=", 0)], 2),
        ([("x", "==", 0), ("z", "==", 0)], 0),
        ([("y", "==", "c"), ("x", ">", 8)], 0),
        ([("y", "==", "c"), ("x", ">=", 5)], 2),
        ([[("y", "==", "c")], [("x", "<", 3)]], 6),
    ],
)
def test_parquet_read_filtered_complex_predicate(
    tmpdir, predicate, expected_len
):
    # Generate data
    fname = tmpdir.join("filtered_complex_predicate.parquet")
    df = pd.DataFrame(
        {"x": range(10), "y": list("aabbccddee"), "z": reversed(range(10))}
    )
    df.to_parquet(fname, row_group_size=2)

    # Check filters
    df_filtered = cudf.read_parquet(fname, filters=predicate)
    assert_eq(cudf.io.read_parquet_metadata(fname)[1], 10 / 2)
    assert_eq(len(df_filtered), expected_len)


@pytest.mark.parametrize("row_group_size", [1, 5, 100])
def test_parquet_read_row_groups(tmpdir, pdf, row_group_size):
    if "col_category" in pdf.columns:
        pdf = pdf.drop(columns=["col_category"])
    fname = tmpdir.join("row_group.parquet")
    pdf.to_parquet(fname, compression="gzip", row_group_size=row_group_size)

    num_rows, row_groups, col_names = cudf.io.read_parquet_metadata(fname)

    gdf = [cudf.read_parquet(fname, row_groups=[i]) for i in range(row_groups)]
    gdf = cudf.concat(gdf)
    assert_eq(pdf.reset_index(drop=True), gdf.reset_index(drop=True))

    # first half rows come from the first source, rest from the second
    gdf = cudf.read_parquet(
        [fname, fname],
        row_groups=[
            list(range(row_groups // 2)),
            list(range(row_groups // 2, row_groups)),
        ],
    )
    assert_eq(pdf.reset_index(drop=True), gdf.reset_index(drop=True))


@pytest.mark.parametrize("row_group_size", [1, 5, 100])
def test_parquet_read_row_groups_non_contiguous(tmpdir, pdf, row_group_size):
    fname = tmpdir.join("row_group.parquet")
    pdf.to_parquet(fname, compression="gzip", row_group_size=row_group_size)

    num_rows, row_groups, col_names = cudf.io.read_parquet_metadata(fname)

    # alternate rows between the two sources
    gdf = cudf.read_parquet(
        [fname, fname],
        row_groups=[
            list(range(0, row_groups, 2)),
            list(range(1, row_groups, 2)),
        ],
    )

    ref_df = [
        cudf.read_parquet(fname, row_groups=i)
        for i in list(range(0, row_groups, 2)) + list(range(1, row_groups, 2))
    ]
    ref_df = cudf.concat(ref_df)

    assert_eq(ref_df, gdf)


@pytest.mark.parametrize("row_group_size", [1, 4, 33])
def test_parquet_read_rows(tmpdir, pdf, row_group_size):
    fname = tmpdir.join("row_group.parquet")
    pdf.to_parquet(fname, compression="None", row_group_size=row_group_size)

    total_rows, row_groups, col_names = cudf.io.read_parquet_metadata(fname)

    num_rows = total_rows // 4
    skiprows = (total_rows - num_rows) // 2
    gdf = cudf.read_parquet(fname, skiprows=skiprows, num_rows=num_rows)

    for row in range(num_rows):
        assert gdf["col_int32"].iloc[row] == row + skiprows


def test_parquet_reader_spark_timestamps(datadir):
    fname = datadir / "spark_timestamp.snappy.parquet"

    expect = pd.read_parquet(fname)
    got = cudf.read_parquet(fname)

    assert_eq(expect, got)


def test_parquet_reader_spark_decimals(datadir):
    fname = datadir / "spark_decimal.parquet"

    expect = pd.read_parquet(fname)
    got = cudf.read_parquet(fname)

    # Convert the decimal dtype from PyArrow to float64 for comparison to cuDF
    # This is because cuDF returns as float64 as it lacks an equivalent dtype
    expect = expect.apply(pd.to_numeric)

    # np.testing.assert_allclose(expect, got)
    assert_eq(expect, got)


def test_parquet_reader_microsecond_timestamps(datadir):
    fname = datadir / "usec_timestamp.parquet"

    expect = pd.read_parquet(fname)
    got = cudf.read_parquet(fname)

    assert_eq(expect, got)


def test_parquet_reader_mixedcompression(datadir):
    fname = datadir / "mixed_compression.parquet"

    expect = pd.read_parquet(fname)
    got = cudf.read_parquet(fname)

    assert_eq(expect, got)


def test_parquet_reader_select_columns(datadir):
    fname = datadir / "nested_column_map.parquet"

    expect = cudf.read_parquet(fname).to_pandas()[["value"]]
    got = cudf.read_parquet(fname, columns=["value"])

    assert_eq(expect, got)


def test_parquet_reader_invalids(tmpdir):
    test_pdf = make_pdf(nrows=1000, nvalids=1000 // 4, dtype=np.int64)

    fname = tmpdir.join("invalids.parquet")
    test_pdf.to_parquet(fname, engine="pyarrow")

    expect = pd.read_parquet(fname)
    got = cudf.read_parquet(fname)

    assert_eq(expect, got)


def test_parquet_chunked_skiprows(tmpdir):
    processed = 0
    batch = 10000
    n = 100000
    out_df = cudf.DataFrame(
        {
            "y": np.arange(n),
            "z": np.random.choice(range(1000000, 2000000), n, replace=False),
            "s": np.random.choice(range(20), n, replace=True),
            "a": np.round(np.random.uniform(1, 5000, n), 2),
        }
    )

    fname = tmpdir.join("skiprows.parquet")
    out_df.to_pandas().to_parquet(fname)

    for i in range(10):
        chunk = cudf.read_parquet(fname, skiprows=processed, num_rows=batch)
        expect = out_df[processed : processed + batch].reset_index(drop=True)
        assert_eq(chunk.reset_index(drop=True), expect)
        processed += batch
        del chunk


def test_parquet_reader_filenotfound(tmpdir):
    with pytest.raises(FileNotFoundError):
        cudf.read_parquet("TestMissingFile.parquet")

    with pytest.raises(FileNotFoundError):
        cudf.read_parquet(tmpdir.mkdir("cudf_parquet"))


def test_parquet_reader_local_filepath():
    fname = "~/TestLocalFile.parquet"
    if not os.path.isfile(fname):
        pytest.skip("Local .parquet file is not found")

    cudf.read_parquet(fname)


@pytest.mark.parametrize(
    "src", ["filepath", "pathobj", "bytes_io", "bytes", "url"]
)
def test_parquet_reader_filepath_or_buffer(parquet_path_or_buf, src):
    expect = pd.read_parquet(parquet_path_or_buf("filepath"))
    got = cudf.read_parquet(parquet_path_or_buf(src))

    assert_eq(expect, got)


def test_parquet_reader_arrow_nativefile(parquet_path_or_buf):
    # Check that we can read a file opened with the
    # Arrow FileSystem inferface
    expect = cudf.read_parquet(parquet_path_or_buf("filepath"))
    fs, path = pa_fs.FileSystem.from_uri(parquet_path_or_buf("filepath"))
    with fs.open_input_file(path) as fil:
        got = cudf.read_parquet(fil)

    assert_eq(expect, got)


def test_parquet_reader_use_python_file_object(parquet_path_or_buf):
    # Check that the non-default `use_python_file_object=True`
    # option works as expected
    expect = cudf.read_parquet(parquet_path_or_buf("filepath"))
    fs, _, paths = get_fs_token_paths(parquet_path_or_buf("filepath"))

    # Pass open fsspec file
    with fs.open(paths[0], mode="rb") as fil:
        got1 = cudf.read_parquet(fil, use_python_file_object=True)
    assert_eq(expect, got1)

    # Pass path only
    got2 = cudf.read_parquet(paths[0], use_python_file_object=True)
    assert_eq(expect, got2)


def create_parquet_source(df, src_type, fname):
    if src_type == "filepath":
        df.to_parquet(fname, engine="pyarrow")
        return str(fname)
    if src_type == "pathobj":
        df.to_parquet(fname, engine="pyarrow")
        return fname
    if src_type == "bytes_io":
        buffer = BytesIO()
        df.to_parquet(buffer, engine="pyarrow")
        return buffer
    if src_type == "bytes":
        buffer = BytesIO()
        df.to_parquet(buffer, engine="pyarrow")
        return buffer.getvalue()
    if src_type == "url":
        df.to_parquet(fname, engine="pyarrow")
        return pathlib.Path(fname).as_uri()


@pytest.mark.parametrize(
    "src", ["filepath", "pathobj", "bytes_io", "bytes", "url"]
)
def test_parquet_reader_multiple_files(tmpdir, src):
    test_pdf1 = make_pdf(nrows=1000, nvalids=1000 // 2)
    test_pdf2 = make_pdf(nrows=500)
    expect = pd.concat([test_pdf1, test_pdf2])

    src1 = create_parquet_source(test_pdf1, src, tmpdir.join("multi1.parquet"))
    src2 = create_parquet_source(test_pdf2, src, tmpdir.join("multi2.parquet"))
    got = cudf.read_parquet([src1, src2])

    assert_eq(expect, got)


def test_parquet_reader_reordered_columns(tmpdir):
    src = pd.DataFrame(
        {"name": ["cow", None, "duck", "fish", None], "id": [0, 1, 2, 3, 4]}
    )
    fname = tmpdir.join("test_parquet_reader_reordered_columns.parquet")
    src.to_parquet(fname)
    assert os.path.exists(fname)
    expect = pd.DataFrame(
        {"id": [0, 1, 2, 3, 4], "name": ["cow", None, "duck", "fish", None]}
    )
    got = cudf.read_parquet(fname, columns=["id", "name"])
    assert_eq(expect, got, check_dtype=False)


def test_parquet_reader_reordered_columns_mixed(tmpdir):
    src = pd.DataFrame(
        {
            "name": ["cow", None, "duck", "fish", None],
            "list0": [
                [[1, 2], [3, 4]],
                None,
                [[5, 6], None],
                [[1]],
                [[5], [6, None, 8]],
            ],
            "id": [0, 1, 2, 3, 4],
            "list1": [
                [[1, 2], [3, 4]],
                [[0, 0]],
                [[5, 6], [10, 12]],
                [[1]],
                [[5], [6, 8]],
            ],
        }
    )
    fname = tmpdir.join("test_parquet_reader_reordered_columns.parquet")
    src.to_parquet(fname)
    assert os.path.exists(fname)
    expect = pd.DataFrame(
        {
            "list1": [
                [[1, 2], [3, 4]],
                [[0, 0]],
                [[5, 6], [10, 12]],
                [[1]],
                [[5], [6, 8]],
            ],
            "id": [0, 1, 2, 3, 4],
            "list0": [
                [[1, 2], [3, 4]],
                None,
                [[5, 6], None],
                [[1]],
                [[5], [6, None, 8]],
            ],
            "name": ["cow", None, "duck", "fish", None],
        }
    )
    got = cudf.read_parquet(fname, columns=["list1", "id", "list0", "name"])
    assert_eq(expect, got, check_dtype=False)


def test_parquet_reader_list_basic(tmpdir):
    expect = pd.DataFrame({"a": [[[1, 2], [3, 4]], None, [[5, 6], None]]})
    fname = tmpdir.join("test_parquet_reader_list_basic.parquet")
    expect.to_parquet(fname)
    assert os.path.exists(fname)
    got = cudf.read_parquet(fname)
    assert_eq(expect, got)


def test_parquet_reader_list_table(tmpdir):
    expect = pd.DataFrame(
        {
            "a": [[[1, 2], [3, 4]], None, [[5, 6], None]],
            "b": [[None, None], None, [None, None]],
            "c": [[[1, 2, 3]], [[None]], [[], None]],
            "d": [[[]], [[None]], [[1, 2, 3], None]],
            "e": [[["cows"]], [["dogs"]], [["cats", "birds", "owls"], None]],
        }
    )
    fname = tmpdir.join("test_parquet_reader_list_table.parquet")
    expect.to_parquet(fname)
    assert os.path.exists(fname)
    got = cudf.read_parquet(fname)
    assert_eq(expect, got, check_dtype=False)


def int_gen(first_val, i):
    """
    Returns an integer based on an absolute index and a starting value. Used
    as input to `list_gen`.
    """
    return int(i + first_val)


strings = [
    "cats",
    "dogs",
    "cows",
    "birds",
    "fish",
    "sheep",
    "owls",
    "bears",
    "ants",
]


def string_gen(first_val, i):
    """
    Returns a string based on an absolute index and a starting value. Used as
    input to `list_gen`.
    """
    return strings[int_gen(first_val, i) % len(strings)]


def list_row_gen(
    gen, first_val, list_size, lists_per_row, include_validity=False
):
    """
    Generate a single row for a List<List<>> column based on input parameters.

    Args:
        gen: A callable which generates an individual leaf element based on an
            absolute index.
        first_val : Generate the column as if it had started at 'first_val'
            instead of 0.
        list_size : Size of each generated list.
        lists_per_row : Number of lists to generate per row.
        include_validity : Whether or not to include nulls as part of the
            column. If true, it will add a selection of nulls at both the
            topmost row level and at the leaf level.

    Returns:
        The generated list column.
    """

    def L(list_size, first_val):
        return [
            (gen(first_val, i) if i % 2 == 0 else None)
            if include_validity
            else (gen(first_val, i))
            for i in range(list_size)
        ]

    return [
        (L(list_size, first_val + (list_size * i)) if i % 2 == 0 else None)
        if include_validity
        else L(list_size, first_val + (list_size * i))
        for i in range(lists_per_row)
    ]


def list_gen(
    gen, skiprows, num_rows, lists_per_row, list_size, include_validity=False
):
    """
    Generate a list column based on input parameters.

    Args:
        gen: A callable which generates an individual leaf element based on an
            absolute index.
        skiprows : Generate the column as if it had started at 'skiprows'
            instead of 0. The intent here is to emulate the skiprows
            parameter of the parquet reader.
        num_rows : Number of rows to generate.  Again, this is to emulate the
            'num_rows' parameter of the parquet reader.
        lists_per_row : Number of lists to generate per row.
        list_size : Size of each generated list.
        include_validity : Whether or not to include nulls as part of the
            column. If true, it will add a selection of nulls at both the
            topmost row level and at the leaf level.

    Returns:
        The generated list column.
    """

    def L(list_size, first_val):
        return [
            (gen(first_val, i) if i % 2 == 0 else None)
            if include_validity
            else (gen(first_val, i))
            for i in range(list_size)
        ]

    def R(first_val, lists_per_row, list_size):
        return [
            L(list_size, first_val + (list_size * i))
            for i in range(lists_per_row)
        ]

    return [
        (
            R(
                lists_per_row * list_size * (i + skiprows),
                lists_per_row,
                list_size,
            )
            if (i + skiprows) % 2 == 0
            else None
        )
        if include_validity
        else R(
            lists_per_row * list_size * (i + skiprows),
            lists_per_row,
            list_size,
        )
        for i in range(num_rows)
    ]


def test_parquet_reader_list_large(tmpdir):
    expect = pd.DataFrame({"a": list_gen(int_gen, 0, 256, 80, 50)})
    fname = tmpdir.join("test_parquet_reader_list_large.parquet")
    expect.to_parquet(fname)
    assert os.path.exists(fname)
    got = cudf.read_parquet(fname)
    assert_eq(expect, got, check_dtype=False)


def test_parquet_reader_list_validity(tmpdir):
    expect = pd.DataFrame(
        {"a": list_gen(int_gen, 0, 256, 80, 50, include_validity=True)}
    )
    fname = tmpdir.join("test_parquet_reader_list_validity.parquet")
    expect.to_parquet(fname)
    assert os.path.exists(fname)
    got = cudf.read_parquet(fname)
    assert_eq(expect, got, check_dtype=False)


def test_parquet_reader_list_large_mixed(tmpdir):
    expect = pd.DataFrame(
        {
            "a": list_gen(string_gen, 0, 128, 80, 50),
            "b": list_gen(int_gen, 0, 128, 80, 50),
            "c": list_gen(int_gen, 0, 128, 80, 50, include_validity=True),
            "d": list_gen(string_gen, 0, 128, 80, 50, include_validity=True),
        }
    )
    fname = tmpdir.join("test_parquet_reader_list_large_mixed.parquet")
    expect.to_parquet(fname)
    assert os.path.exists(fname)
    got = cudf.read_parquet(fname)
    assert_eq(expect, got, check_dtype=False)


def test_parquet_reader_list_large_multi_rowgroup(tmpdir):
    # > 40 row groups
    num_rows = 100000
    num_docs = num_rows / 2
    num_categories = 1_000
    row_group_size = 1000

    cupy.random.seed(0)

    # generate a random pairing of doc: category
    documents = cudf.DataFrame(
        {
            "document_id": cupy.random.randint(num_docs, size=num_rows),
            "category_id": cupy.random.randint(num_categories, size=num_rows),
        }
    )

    # group categories by document_id to create a list column
    expect = documents.groupby("document_id").agg({"category_id": ["collect"]})
    expect.columns = expect.columns.get_level_values(0)
    expect.reset_index(inplace=True)

    # round trip the dataframe to/from parquet
    fname = tmpdir.join(
        "test_parquet_reader_list_large_multi_rowgroup.parquet"
    )
    expect.to_pandas().to_parquet(fname, row_group_size=row_group_size)
    got = cudf.read_parquet(fname)

    assert_eq(expect, got)


def test_parquet_reader_list_large_multi_rowgroup_nulls(tmpdir):
    # 25 row groups
    num_rows = 25000
    row_group_size = 1000

    expect = cudf.DataFrame(
        {"a": list_gen(int_gen, 0, num_rows, 3, 2, include_validity=True)}
    )

    # round trip the dataframe to/from parquet
    fname = tmpdir.join(
        "test_parquet_reader_list_large_multi_rowgroup_nulls.parquet"
    )
    expect.to_pandas().to_parquet(fname, row_group_size=row_group_size)
    assert os.path.exists(fname)
    got = cudf.read_parquet(fname)
    assert_eq(expect, got)


@pytest.mark.parametrize("skip", range(0, 128))
def test_parquet_reader_list_skiprows(skip, tmpdir):
    num_rows = 128
    src = pd.DataFrame(
        {
            "a": list_gen(int_gen, 0, num_rows, 80, 50),
            "b": list_gen(string_gen, 0, num_rows, 80, 50),
            "c": list_gen(int_gen, 0, num_rows, 80, 50, include_validity=True),
        }
    )
    fname = tmpdir.join("test_parquet_reader_list_skiprows.parquet")
    src.to_parquet(fname)
    assert os.path.exists(fname)

    expect = src.iloc[skip:]
    got = cudf.read_parquet(fname, skiprows=skip)
    assert_eq(expect, got, check_dtype=False)


@pytest.mark.parametrize("skip", range(0, 120))
def test_parquet_reader_list_num_rows(skip, tmpdir):
    num_rows = 128
    src = pd.DataFrame(
        {
            "a": list_gen(int_gen, 0, num_rows, 80, 50),
            "b": list_gen(string_gen, 0, num_rows, 80, 50),
            "c": list_gen(int_gen, 0, num_rows, 80, 50, include_validity=True),
            "d": list_gen(
                string_gen, 0, num_rows, 80, 50, include_validity=True
            ),
        }
    )
    fname = tmpdir.join("test_parquet_reader_list_num_rows.parquet")
    src.to_parquet(fname)
    assert os.path.exists(fname)

    # make sure to leave a few rows at the end that we don't read
    rows_to_read = min(3, (num_rows - skip) - 5)
    expect = src.iloc[skip:].head(rows_to_read)
    got = cudf.read_parquet(fname, skiprows=skip, num_rows=rows_to_read)
    assert_eq(expect, got, check_dtype=False)


def struct_gen(gen, skip_rows, num_rows, include_validity=False):
    """
    Generate a struct column based on input parameters.

    Args:
        gen: A array of callables which generate an individual row based on an
            absolute index.
        skip_rows : Generate the column as if it had started at 'skip_rows'
            instead of 0. The intent here is to emulate the skip_rows
            parameter of the parquet reader.
        num_fields : Number of fields in the struct.
        include_validity : Whether or not to include nulls as part of the
            column. If true, it will add a selection of nulls at both the
            field level and at the value level.

    Returns:
        The generated struct column.
    """

    def R(first_val, num_fields):
        return {
            "col"
            + str(f): (gen[f](first_val, first_val) if f % 4 != 0 else None)
            if include_validity
            else (gen[f](first_val, first_val))
            for f in range(len(gen))
        }

    return [
        (R((i + skip_rows), len(gen)) if (i + skip_rows) % 4 != 0 else None)
        if include_validity
        else R((i + skip_rows), len(gen))
        for i in range(num_rows)
    ]


@pytest.mark.parametrize(
    "data",
    [
        # struct
        [
            {"a": 1, "b": 2},
            {"a": 10, "b": 20},
            {"a": None, "b": 22},
            {"a": None, "b": None},
            {"a": 15, "b": None},
        ],
        # struct-of-list
        [
            {"a": 1, "b": 2, "c": [1, 2, 3]},
            {"a": 10, "b": 20, "c": [4, 5]},
            {"a": None, "b": 22, "c": [6]},
            {"a": None, "b": None, "c": None},
            {"a": 15, "b": None, "c": [-1, -2]},
            None,
            {"a": 100, "b": 200, "c": [-10, None, -20]},
        ],
        # list-of-struct
        [
            [{"a": 1, "b": 2}, {"a": 2, "b": 3}, {"a": 4, "b": 5}],
            None,
            [{"a": 10, "b": 20}],
            [{"a": 100, "b": 200}, {"a": None, "b": 300}, None],
        ],
        # struct-of-struct
        [
            {"a": 1, "b": {"inner_a": 10, "inner_b": 20}, "c": 2},
            {"a": 3, "b": {"inner_a": 30, "inner_b": 40}, "c": 4},
            {"a": 5, "b": {"inner_a": 50, "inner_b": None}, "c": 6},
            {"a": 7, "b": None, "c": 8},
            {"a": None, "b": {"inner_a": None, "inner_b": None}, "c": None},
            None,
            {"a": None, "b": {"inner_a": None, "inner_b": 100}, "c": 10},
        ],
    ],
)
def test_parquet_reader_struct_basic(tmpdir, data):
    expect = pa.Table.from_pydict({"struct": data})
    fname = tmpdir.join("test_parquet_reader_struct_basic.parquet")
    pa.parquet.write_table(expect, fname)
    assert os.path.exists(fname)
    got = cudf.read_parquet(fname)
    assert expect.equals(got.to_arrow())


def select_columns_params():
    dfs = [
        # struct
        (
            [
                {"a": 1, "b": 2},
                {"a": 10, "b": 20},
                {"a": None, "b": 22},
                {"a": None, "b": None},
                {"a": 15, "b": None},
            ],
            [["struct"], ["struct.a"], ["struct.b"], ["c"]],
        ),
        # struct-of-list
        (
            [
                {"a": 1, "b": 2, "c": [1, 2, 3]},
                {"a": 10, "b": 20, "c": [4, 5]},
                {"a": None, "b": 22, "c": [6]},
                {"a": None, "b": None, "c": None},
                {"a": 15, "b": None, "c": [-1, -2]},
                None,
                {"a": 100, "b": 200, "c": [-10, None, -20]},
            ],
            [
                ["struct"],
                ["struct.c"],
                ["struct.c.list"],
                ["struct.c.list.item"],
                ["struct.b", "struct.c"],
                ["struct.b", "struct.d", "struct.c"],
            ],
        ),
        # list-of-struct
        (
            [
                [{"a": 1, "b": 2}, {"a": 2, "b": 3}, {"a": 4, "b": 5}],
                None,
                [{"a": 10, "b": 20}],
                [{"a": 100, "b": 200}, {"a": None, "b": 300}, None],
            ],
            [
                ["struct"],
                ["struct.list"],
                ["struct.list.item"],
                ["struct.list.item.a", "struct.list.item.b"],
                ["struct.list.item.c"],
            ],
        ),
        # struct with "." in field names
        (
            [
                {"a.b": 1, "b.a": 2},
                {"a.b": 10, "b.a": 20},
                {"a.b": None, "b.a": 22},
                {"a.b": None, "b.a": None},
                {"a.b": 15, "b.a": None},
            ],
            [["struct"], ["struct.a"], ["struct.b.a"]],
        ),
    ]
    for df_col_pair in dfs:
        for cols in df_col_pair[1]:
            yield df_col_pair[0], cols


@pytest.mark.parametrize("data, columns", select_columns_params())
def test_parquet_reader_struct_select_columns(tmpdir, data, columns):
    table = pa.Table.from_pydict({"struct": data})
    buff = BytesIO()

    pa.parquet.write_table(table, buff)

    expect = pq.ParquetFile(buff).read(columns=columns)
    got = cudf.read_parquet(buff, columns=columns)
    assert expect.equals(got.to_arrow())


def test_parquet_reader_struct_los_large(tmpdir):
    num_rows = 256
    list_size = 64
    data = [
        struct_gen([string_gen, int_gen, string_gen], 0, list_size, False)
        if i % 2 == 0
        else None
        for i in range(num_rows)
    ]
    expect = pa.Table.from_pydict({"los": data})
    fname = tmpdir.join("test_parquet_reader_struct_los_large.parquet")
    pa.parquet.write_table(expect, fname)
    assert os.path.exists(fname)
    got = cudf.read_parquet(fname)
    assert expect.equals(got.to_arrow())


@pytest.mark.parametrize(
    "params", [[3, 4, 32, False], [3, 4, 32, True], [100, 25, 256, True]]
)
def test_parquet_reader_struct_sol_table(tmpdir, params):
    # Struct<List<List>>
    lists_per_row = params[0]
    list_size = params[1]
    num_rows = params[2]
    include_validity = params[3]

    def list_gen_wrapped(x, y):
        return list_row_gen(
            int_gen, x * list_size * lists_per_row, list_size, lists_per_row
        )

    def string_list_gen_wrapped(x, y):
        return list_row_gen(
            string_gen,
            x * list_size * lists_per_row,
            list_size,
            lists_per_row,
            include_validity,
        )

    data = struct_gen(
        [int_gen, string_gen, list_gen_wrapped, string_list_gen_wrapped],
        0,
        num_rows,
        include_validity,
    )
    expect = pa.Table.from_pydict({"sol": data})
    fname = tmpdir.join("test_parquet_reader_struct_sol_table.parquet")
    pa.parquet.write_table(expect, fname)
    assert os.path.exists(fname)
    got = cudf.read_parquet(fname)
    assert expect.equals(got.to_arrow())


@pytest.mark.filterwarnings("ignore:Using CPU")
def test_parquet_writer_cpu_pyarrow(
    tmpdir, pdf_day_timestamps, gdf_day_timestamps
):
    pdf_fname = tmpdir.join("pdf.parquet")
    gdf_fname = tmpdir.join("gdf.parquet")

    if len(pdf_day_timestamps) == 0:
        pdf_day_timestamps = pdf_day_timestamps.reset_index(drop=True)
        gdf_day_timestamps = pdf_day_timestamps.reset_index(drop=True)

    pdf_day_timestamps.to_parquet(pdf_fname.strpath)
    gdf_day_timestamps.to_parquet(gdf_fname.strpath, engine="pyarrow")

    assert os.path.exists(pdf_fname)
    assert os.path.exists(gdf_fname)

    expect = pa.parquet.read_pandas(pdf_fname)
    got = pa.parquet.read_pandas(gdf_fname)

    assert_eq(expect, got)

    def clone_field(table, name, datatype):
        f = table.schema.field(name)
        return pa.field(f.name, datatype, f.nullable, f.metadata)

    # Pandas uses a datetime64[ns] while we use a datetime64[ms]
    for t in [expect, got]:
        for t_col in ["col_datetime64[ms]", "col_datetime64[us]"]:
            idx = t.schema.get_field_index(t_col)
            field = clone_field(t, t_col, pa.timestamp("ms"))
            t = t.set_column(idx, field, t.column(idx).cast(field.type))
            t = t.replace_schema_metadata()

    assert_eq(expect, got)


@pytest.mark.filterwarnings("ignore:Using CPU")
def test_parquet_writer_int96_timestamps(tmpdir, pdf, gdf):
    gdf_fname = tmpdir.join("gdf.parquet")

    if len(pdf) == 0:
        pdf = pdf.reset_index(drop=True)
        gdf = gdf.reset_index(drop=True)

    if "col_category" in pdf.columns:
        pdf = pdf.drop(columns=["col_category"])
    if "col_category" in gdf.columns:
        gdf = gdf.drop(columns=["col_category"])

    assert_eq(pdf, gdf)

    # Write out the gdf using the GPU accelerated writer with INT96 timestamps
    gdf.to_parquet(gdf_fname.strpath, index=None, int96_timestamps=True)

    assert os.path.exists(gdf_fname)

    expect = pdf
    got = pd.read_parquet(gdf_fname)

    # verify INT96 timestamps were converted back to the same data.
    assert_eq(expect, got, check_categorical=False)


def test_multifile_parquet_folder(tmpdir):

    test_pdf1 = make_pdf(nrows=10, nvalids=10 // 2)
    test_pdf2 = make_pdf(nrows=20)
    expect = pd.concat([test_pdf1, test_pdf2])

    tmpdir.mkdir("multi_part")

    create_parquet_source(
        test_pdf1, "filepath", tmpdir.join("multi_part/multi1.parquet")
    )
    create_parquet_source(
        test_pdf2, "filepath", tmpdir.join("multi_part/multi2.parquet")
    )

    got1 = cudf.read_parquet(tmpdir.join("multi_part/*.parquet"))
    assert_eq(expect, got1)

    got2 = cudf.read_parquet(tmpdir.join("multi_part"))
    assert_eq(expect, got2)


# Validates the metadata return path of the parquet writer
def test_parquet_writer_return_metadata(tmpdir, simple_gdf):
    gdf_fname = tmpdir.join("data1.parquet")

    # Write out the gdf using the GPU accelerated writer
    df_metadata = simple_gdf.to_parquet(
        gdf_fname.strpath, index=None, metadata_file_path="test/data1.parquet"
    )
    # Verify that we got a valid parquet signature in the initial metadata blob
    assert df_metadata.tobytes()[0:4] == b"PAR1"

    df_metadata_list1 = [df_metadata]
    df_metadata_list2 = [df_metadata, df_metadata]
    merged_metadata1 = merge_parquet_filemetadata(df_metadata_list1)
    merged_metadata2 = merge_parquet_filemetadata(df_metadata_list2)

    # Verify that we got a valid parquet signature in the final metadata blob
    assert merged_metadata1.tobytes()[0:4] == b"PAR1"
    assert merged_metadata2.tobytes()[0:4] == b"PAR1"

    # Make sure aggregation is combining metadata correctly
    fmd1 = pa.parquet.ParquetFile(BytesIO(merged_metadata1.tobytes())).metadata
    fmd2 = pa.parquet.ParquetFile(BytesIO(merged_metadata2.tobytes())).metadata
    assert fmd2.num_columns == fmd1.num_columns
    assert fmd2.num_rows == 2 * fmd1.num_rows
    assert fmd2.num_row_groups == 2 * fmd1.num_row_groups


# Validates the integrity of the GPU accelerated parquet writer.
def test_parquet_writer_gpu_none_index(tmpdir, simple_pdf, simple_gdf):
    gdf_fname = tmpdir.join("gdf.parquet")
    pdf_fname = tmpdir.join("pdf.parquet")

    assert_eq(simple_pdf, simple_gdf)

    # Write out the gdf using the GPU accelerated writer
    simple_gdf.to_parquet(gdf_fname.strpath, index=None)
    simple_pdf.to_parquet(pdf_fname.strpath, index=None)

    assert os.path.exists(gdf_fname)
    assert os.path.exists(pdf_fname)

    expect = pd.read_parquet(pdf_fname)
    got = pd.read_parquet(gdf_fname)

    assert_eq(expect, got, check_categorical=False)


def test_parquet_writer_gpu_true_index(tmpdir, simple_pdf, simple_gdf):
    gdf_fname = tmpdir.join("gdf.parquet")
    pdf_fname = tmpdir.join("pdf.parquet")

    assert_eq(simple_pdf, simple_gdf)

    # Write out the gdf using the GPU accelerated writer
    simple_gdf.to_parquet(gdf_fname.strpath, index=True)
    simple_pdf.to_parquet(pdf_fname.strpath, index=True)

    assert os.path.exists(gdf_fname)
    assert os.path.exists(pdf_fname)

    expect = pd.read_parquet(pdf_fname)
    got = pd.read_parquet(gdf_fname)

    assert_eq(expect, got, check_categorical=False)


def test_parquet_writer_gpu_false_index(tmpdir, simple_pdf, simple_gdf):
    gdf_fname = tmpdir.join("gdf.parquet")
    pdf_fname = tmpdir.join("pdf.parquet")

    assert_eq(simple_pdf, simple_gdf)

    # Write out the gdf using the GPU accelerated writer
    simple_gdf.to_parquet(gdf_fname.strpath, index=False)
    simple_pdf.to_parquet(pdf_fname.strpath, index=False)

    assert os.path.exists(gdf_fname)
    assert os.path.exists(pdf_fname)

    expect = pd.read_parquet(pdf_fname)
    got = pd.read_parquet(gdf_fname)

    assert_eq(expect, got, check_categorical=False)


def test_parquet_writer_gpu_multi_index(tmpdir, simple_pdf, simple_gdf):
    gdf_fname = tmpdir.join("gdf.parquet")
    pdf_fname = tmpdir.join("pdf.parquet")

    simple_pdf = simple_pdf.set_index(["col_bool", "col_int8"])
    simple_gdf = simple_gdf.set_index(["col_bool", "col_int8"])

    assert_eq(simple_pdf, simple_gdf)

    print("PDF Index Type: " + str(type(simple_pdf.index)))
    print("GDF Index Type: " + str(type(simple_gdf.index)))

    # Write out the gdf using the GPU accelerated writer
    simple_gdf.to_parquet(gdf_fname.strpath, index=None)
    simple_pdf.to_parquet(pdf_fname.strpath, index=None)

    assert os.path.exists(gdf_fname)
    assert os.path.exists(pdf_fname)

    expect = pd.read_parquet(pdf_fname)
    got = pd.read_parquet(gdf_fname)

    assert_eq(expect, got, check_categorical=False)


def test_parquet_writer_gpu_chunked(tmpdir, simple_pdf, simple_gdf):
    gdf_fname = tmpdir.join("gdf.parquet")

    writer = ParquetWriter(gdf_fname)
    writer.write_table(simple_gdf)
    writer.write_table(simple_gdf)
    writer.close()

    assert_eq(pd.read_parquet(gdf_fname), pd.concat([simple_pdf, simple_pdf]))


def test_parquet_write_bytes_io(simple_gdf):
    output = BytesIO()
    simple_gdf.to_parquet(output)
    assert_eq(cudf.read_parquet(output), simple_gdf)


def test_parquet_writer_bytes_io(simple_gdf):
    output = BytesIO()

    writer = ParquetWriter(output)
    writer.write_table(simple_gdf)
    writer.write_table(simple_gdf)
    writer.close()

    assert_eq(cudf.read_parquet(output), cudf.concat([simple_gdf, simple_gdf]))


@pytest.mark.parametrize("filename", ["myfile.parquet", None])
@pytest.mark.parametrize("cols", [["b"], ["c", "b"]])
def test_parquet_write_partitioned(tmpdir_factory, cols, filename):
    # Checks that write_to_dataset is wrapping to_parquet
    # as expected
    gdf_dir = str(tmpdir_factory.mktemp("gdf_dir"))
    pdf_dir = str(tmpdir_factory.mktemp("pdf_dir"))
    size = 100
    pdf = pd.DataFrame(
        {
            "a": np.arange(0, stop=size, dtype="int64"),
            "b": np.random.choice(list("abcd"), size=size),
            "c": np.random.choice(np.arange(4), size=size),
        }
    )
    pdf.to_parquet(pdf_dir, index=False, partition_cols=cols)
    gdf = cudf.from_pandas(pdf)
    gdf.to_parquet(
        gdf_dir, index=False, partition_cols=cols, partition_file_name=filename
    )

    # Use pandas since dataset may be partitioned
    expect = pd.read_parquet(pdf_dir)
    got = pd.read_parquet(gdf_dir)
    assert_eq(expect, got)

    # If filename is specified, check that it is correct
    if filename:
        for _, _, files in os.walk(gdf_dir):
            for fn in files:
                assert fn == filename


@pytest.mark.parametrize("cols", [None, ["b"]])
def test_parquet_write_to_dataset(tmpdir_factory, cols):
    dir1 = tmpdir_factory.mktemp("dir1")
    dir2 = tmpdir_factory.mktemp("dir2")
    if cols is None:
        dir1 = dir1.join("file.pq")
        dir2 = dir2.join("file.pq")
    dir1 = str(dir1)
    dir2 = str(dir2)

    size = 100
    gdf = cudf.DataFrame(
        {
            "a": np.arange(0, stop=size),
            "b": np.random.choice(np.arange(4), size=size),
        }
    )
    gdf.to_parquet(dir1, partition_cols=cols)
    cudf.io.write_to_dataset(gdf, dir2, partition_cols=cols)

    # cudf read_parquet cannot handle partitioned dataset
    expect = pd.read_parquet(dir1)
    got = pd.read_parquet(dir2)
    assert_eq(expect, got)

    gdf = cudf.DataFrame(
        {
            "a": cudf.Series([1, 2, 3]),
            "b": cudf.Series([1, 2, 3]),
            "c": cudf.Series(["a", "b", "c"], dtype="category"),
        }
    )
    with pytest.raises(ValueError):
        gdf.to_parquet(dir1, partition_cols=cols)


def test_parquet_writer_chunked_metadata(tmpdir, simple_pdf, simple_gdf):
    gdf_fname = tmpdir.join("gdf.parquet")
    test_path = "test/path"

    writer = ParquetWriter(gdf_fname)
    writer.write_table(simple_gdf)
    writer.write_table(simple_gdf)
    meta_byte_array = writer.close(metadata_file_path=test_path)
    fmd = pq.ParquetFile(BytesIO(meta_byte_array)).metadata

    assert fmd.num_rows == 2 * len(simple_gdf)
    assert fmd.num_row_groups == 2

    for r in range(fmd.num_row_groups):
        for c in range(fmd.num_columns):
            assert fmd.row_group(r).column(c).file_path == test_path


def test_write_read_cudf(tmpdir, pdf):
    file_path = tmpdir.join("cudf.parquet")
    if "col_category" in pdf.columns:
        pdf = pdf.drop(columns=["col_category"])

    gdf = cudf.from_pandas(pdf)
    gdf.to_parquet(file_path)
    gdf = cudf.read_parquet(file_path)

    assert_eq(gdf, pdf, check_index_type=False if pdf.empty else True)


def test_write_cudf_read_pandas_pyarrow(tmpdir, pdf):
    cudf_path = tmpdir.join("cudf.parquet")
    pandas_path = tmpdir.join("pandas.parquet")

    if "col_category" in pdf.columns:
        pdf = pdf.drop(columns=["col_category"])

    df = cudf.from_pandas(pdf)

    df.to_parquet(cudf_path)
    pdf.to_parquet(pandas_path)

    cudf_res = pd.read_parquet(cudf_path)
    pd_res = pd.read_parquet(pandas_path)

    assert_eq(pd_res, cudf_res, check_index_type=False if pdf.empty else True)

    cudf_res = pa.parquet.read_table(
        cudf_path, use_pandas_metadata=True
    ).to_pandas()
    pd_res = pa.parquet.read_table(
        pandas_path, use_pandas_metadata=True
    ).to_pandas()

    assert_eq(cudf_res, pd_res, check_index_type=False if pdf.empty else True)


def test_parquet_writer_criteo(tmpdir):
    # To run this test, download the day 0 of criteo dataset from
    # http://labs.criteo.com/2013/12/download-terabyte-click-logs/
    # and place the uncompressed dataset in the home directory
    fname = os.path.expanduser("~/day_0")
    if not os.path.isfile(fname):
        pytest.skip("Local criteo day 0 tsv file is not found")

    cudf_path = tmpdir.join("cudf.parquet")

    cont_names = ["I" + str(x) for x in range(1, 14)]
    cat_names = ["C" + str(x) for x in range(1, 27)]
    cols = ["label"] + cont_names + cat_names

    df = cudf.read_csv(fname, sep="\t", names=cols, byte_range=(0, 1000000000))
    df = df.drop(columns=cont_names)

    df.to_parquet(cudf_path)


def test_trailing_nans(datadir, tmpdir):
    fname = "trailing_nans.parquet"
    file_path = datadir / fname
    cu_df = cudf.read_parquet(file_path)

    tmp_file_path = tmpdir.join(fname)
    cu_df.to_parquet(tmp_file_path)

    pd.read_parquet(tmp_file_path)


def test_parquet_writer_sliced(tmpdir):
    cudf_path = tmpdir.join("cudf.parquet")

    df = pd.DataFrame()
    df["String"] = np.array(["Alpha", "Beta", "Gamma", "Delta"])
    df = cudf.from_pandas(df)

    df_select = df.iloc[1:3]

    df_select.to_parquet(cudf_path)
    assert_eq(cudf.read_parquet(cudf_path), df_select)


def test_parquet_writer_list_basic(tmpdir):
    expect = pd.DataFrame({"a": [[[1, 2], [3, 4]], None, [[5, 6], None]]})
    fname = tmpdir.join("test_parquet_writer_list_basic.parquet")

    gdf = cudf.from_pandas(expect)

    gdf.to_parquet(fname)
    assert os.path.exists(fname)

    got = pd.read_parquet(fname)
    assert_eq(expect, got)


def test_parquet_writer_list_large(tmpdir):
    expect = pd.DataFrame({"a": list_gen(int_gen, 0, 256, 80, 50)})
    fname = tmpdir.join("test_parquet_writer_list_large.parquet")

    gdf = cudf.from_pandas(expect)

    gdf.to_parquet(fname)
    assert os.path.exists(fname)

    got = pd.read_parquet(fname)
    assert_eq(expect, got)


def test_parquet_writer_list_large_mixed(tmpdir):
    expect = pd.DataFrame(
        {
            "a": list_gen(string_gen, 0, 128, 80, 50),
            "b": list_gen(int_gen, 0, 128, 80, 50),
            "c": list_gen(int_gen, 0, 128, 80, 50, include_validity=True),
            "d": list_gen(string_gen, 0, 128, 80, 50, include_validity=True),
        }
    )
    fname = tmpdir.join("test_parquet_writer_list_large_mixed.parquet")
    gdf = cudf.from_pandas(expect)

    gdf.to_parquet(fname)
    assert os.path.exists(fname)

    got = pd.read_parquet(fname)
    assert_eq(expect, got)


def test_parquet_writer_list_chunked(tmpdir):
    table1 = cudf.DataFrame(
        {
            "a": list_gen(string_gen, 0, 128, 80, 50),
            "b": list_gen(int_gen, 0, 128, 80, 50),
            "c": list_gen(int_gen, 0, 128, 80, 50, include_validity=True),
            "d": list_gen(string_gen, 0, 128, 80, 50, include_validity=True),
        }
    )
    table2 = cudf.DataFrame(
        {
            "a": list_gen(string_gen, 0, 128, 80, 50),
            "b": list_gen(int_gen, 0, 128, 80, 50),
            "c": list_gen(int_gen, 0, 128, 80, 50, include_validity=True),
            "d": list_gen(string_gen, 0, 128, 80, 50, include_validity=True),
        }
    )
    fname = tmpdir.join("test_parquet_writer_list_chunked.parquet")
    expect = cudf.concat([table1, table2])
    expect = expect.reset_index(drop=True)

    writer = ParquetWriter(fname)
    writer.write_table(table1)
    writer.write_table(table2)
    writer.close()

    assert os.path.exists(fname)

    got = pd.read_parquet(fname)
    assert_eq(expect, got)


@pytest.mark.parametrize("engine", ["cudf", "pyarrow"])
def test_parquet_nullable_boolean(tmpdir, engine):
    pandas_path = tmpdir.join("pandas_bools.parquet")

    pdf = pd.DataFrame(
        {
            "a": pd.Series(
                [True, False, None, True, False], dtype=pd.BooleanDtype()
            )
        }
    )
    expected_gdf = cudf.DataFrame({"a": [True, False, None, True, False]})

    pdf.to_parquet(pandas_path)
    actual_gdf = cudf.read_parquet(pandas_path, engine=engine)

    assert_eq(actual_gdf, expected_gdf)


@pytest.mark.parametrize(
    "pdf",
    [
        pd.DataFrame(index=[1, 2, 3]),
        pytest.param(
            pd.DataFrame(index=pd.RangeIndex(0, 10, 1)),
            marks=pytest.mark.xfail(
                reason="https://issues.apache.org/jira/browse/ARROW-10643"
            ),
        ),
        pd.DataFrame({"a": [1, 2, 3]}, index=[0.43534, 345, 0.34534]),
        pd.DataFrame(
            {"b": [11, 22, 33], "c": ["a", "b", "c"]},
            index=pd.Index(["a", "b", "c"], name="custom name"),
        ),
        pd.DataFrame(
            {"a": [10, 11, 12], "b": [99, 88, 77]},
            index=pd.RangeIndex(12, 17, 2),
        ),
        pd.DataFrame(
            {"b": [99, 88, 77]},
            index=pd.RangeIndex(22, 27, 2, name="hello index"),
        ),
        pd.DataFrame(index=pd.Index(["a", "b", "c"], name="custom name")),
        pd.DataFrame(
            {"a": ["a", "bb", "cc"], "b": [10, 21, 32]},
            index=pd.MultiIndex.from_tuples([[1, 2], [10, 11], [15, 16]]),
        ),
        pd.DataFrame(
            {"a": ["a", "bb", "cc"], "b": [10, 21, 32]},
            index=pd.MultiIndex.from_tuples(
                [[1, 2], [10, 11], [15, 16]], names=["first", "second"]
            ),
        ),
    ],
)
@pytest.mark.parametrize("index", [None, True, False])
def test_parquet_index(pdf, index):
    pandas_buffer = BytesIO()
    cudf_buffer = BytesIO()

    gdf = cudf.from_pandas(pdf)

    pdf.to_parquet(pandas_buffer, index=index)
    gdf.to_parquet(cudf_buffer, index=index)

    expected = pd.read_parquet(cudf_buffer)
    actual = cudf.read_parquet(pandas_buffer)

    assert_eq(expected, actual, check_index_type=True)

    expected = pd.read_parquet(pandas_buffer)
    actual = cudf.read_parquet(cudf_buffer)

    assert_eq(expected, actual, check_index_type=True)


@pytest.mark.parametrize("engine", ["cudf", "pyarrow"])
def test_parquet_allnull_str(tmpdir, engine):
    pandas_path = tmpdir.join("pandas_allnulls.parquet")

    pdf = pd.DataFrame(
        {"a": pd.Series([None, None, None, None, None], dtype="str")}
    )
    expected_gdf = cudf.DataFrame(
        {"a": cudf.Series([None, None, None, None, None], dtype="str")}
    )

    pdf.to_parquet(pandas_path)
    actual_gdf = cudf.read_parquet(pandas_path, engine=engine)

    assert_eq(actual_gdf, expected_gdf)


def normalized_equals(value1, value2):
    if isinstance(value1, pd.Timestamp):
        value1 = value1.to_pydatetime()
    if isinstance(value2, pd.Timestamp):
        value2 = value2.to_pydatetime()
    if isinstance(value1, datetime.datetime):
        value1 = value1.replace(tzinfo=None)
    if isinstance(value2, datetime.datetime):
        value2 = value2.replace(tzinfo=None)

    # if one is datetime then both values are datetimes now
    if isinstance(value1, datetime.datetime):
        return value1 == value2

    # Compare integers with floats now
    if isinstance(value1, float) or isinstance(value2, float):
        return math.isclose(value1, value2)

    return value1 == value2


def test_parquet_writer_statistics(tmpdir, pdf):
    file_path = tmpdir.join("cudf.parquet")
    if "col_category" in pdf.columns:
        pdf = pdf.drop(columns=["col_category", "col_bool"])

    for t in TIMEDELTA_TYPES:
        pdf["col_" + t] = pd.Series(np.arange(len(pdf.index))).astype(t)

    gdf = cudf.from_pandas(pdf)
    gdf.to_parquet(file_path, index=False)

    # Read back from pyarrow
    pq_file = pq.ParquetFile(file_path)
    # verify each row group's statistics
    for rg in range(0, pq_file.num_row_groups):
        pd_slice = pq_file.read_row_group(rg).to_pandas()

        # statistics are per-column. So need to verify independently
        for i, col in enumerate(pd_slice):
            stats = pq_file.metadata.row_group(rg).column(i).statistics

            actual_min = pd_slice[col].min()
            stats_min = stats.min
            assert normalized_equals(actual_min, stats_min)

            actual_max = pd_slice[col].max()
            stats_max = stats.max
            assert normalized_equals(actual_max, stats_max)


def test_parquet_writer_list_statistics(tmpdir):
    df = pd.DataFrame(
        {
            "a": list_gen(string_gen, 0, 128, 80, 50),
            "b": list_gen(int_gen, 0, 128, 80, 50),
            "c": list_gen(int_gen, 0, 128, 80, 50, include_validity=True),
            "d": list_gen(string_gen, 0, 128, 80, 50, include_validity=True),
        }
    )
    fname = tmpdir.join("test_parquet_writer_list_statistics.parquet")
    gdf = cudf.from_pandas(df)

    gdf.to_parquet(fname)
    assert os.path.exists(fname)

    # Read back from pyarrow
    pq_file = pq.ParquetFile(fname)
    # verify each row group's statistics
    for rg in range(0, pq_file.num_row_groups):
        pd_slice = pq_file.read_row_group(rg).to_pandas()

        # statistics are per-column. So need to verify independently
        for i, col in enumerate(pd_slice):
            stats = pq_file.metadata.row_group(rg).column(i).statistics

            actual_min = cudf.Series(pd_slice[col].explode().explode()).min()
            stats_min = stats.min
            assert normalized_equals(actual_min, stats_min)

            actual_max = cudf.Series(pd_slice[col].explode().explode()).max()
            stats_max = stats.max
            assert normalized_equals(actual_max, stats_max)


@pytest.mark.parametrize(
    "data",
    [
        # Structs
        {
            "being": [
                None,
                {"human?": True, "Deets": {"Name": "Carrot", "Age": 27}},
                {"human?": None, "Deets": {"Name": "Angua", "Age": 25}},
                {"human?": False, "Deets": {"Name": "Cheery", "Age": 31}},
                {"human?": False, "Deets": None},
                {"human?": None, "Deets": {"Name": "Mr", "Age": None}},
            ]
        },
        # List of Structs
        {
            "family": [
                [None, {"human?": True, "deets": {"weight": 2.4, "age": 27}}],
                [
                    {"human?": None, "deets": {"weight": 5.3, "age": 25}},
                    {"human?": False, "deets": {"weight": 8.0, "age": 31}},
                    {"human?": False, "deets": None},
                ],
                [],
                [{"human?": None, "deets": {"weight": 6.9, "age": None}}],
            ]
        },
        # Struct of Lists
        pytest.param(
            {
                "Real estate records": [
                    None,
                    {
                        "Status": "NRI",
                        "Ownerships": {
                            "land_unit": [None, 2, None],
                            "flats": [[1, 2, 3], [], [4, 5], [], [0, 6, 0]],
                        },
                    },
                    {
                        "Status": None,
                        "Ownerships": {
                            "land_unit": [4, 5],
                            "flats": [[7, 8], []],
                        },
                    },
                    {
                        "Status": "RI",
                        "Ownerships": {"land_unit": None, "flats": [[]]},
                    },
                    {"Status": "RI", "Ownerships": None},
                    {
                        "Status": None,
                        "Ownerships": {
                            "land_unit": [7, 8, 9],
                            "flats": [[], [], []],
                        },
                    },
                ]
            },
            marks=pytest.mark.xfail(
                reason="https://github.com/rapidsai/cudf/issues/7562"
            ),
        ),
    ],
)
def test_parquet_writer_nested(tmpdir, data):
    expect = pd.DataFrame(data)
    gdf = cudf.from_pandas(expect)

    fname = tmpdir.join("test_parquet_writer_nested.parquet")
    gdf.to_parquet(fname)
    assert os.path.exists(fname)

    got = pd.read_parquet(fname)
    assert_eq(expect, got)


def test_parquet_writer_decimal(tmpdir):
    from cudf.core.dtypes import Decimal64Dtype

    gdf = cudf.DataFrame({"val": [0.00, 0.01, 0.02]})

    gdf["dec_val"] = gdf["val"].astype(Decimal64Dtype(7, 2))

    fname = tmpdir.join("test_parquet_writer_decimal.parquet")
    gdf.to_parquet(fname)
    assert os.path.exists(fname)

    got = pd.read_parquet(fname)
    assert_eq(gdf, got)


def test_parquet_writer_column_validation():
    df = cudf.DataFrame({1: [1, 2, 3], "1": ["a", "b", "c"]})
    pdf = df.to_pandas()

    assert_exceptions_equal(
        lfunc=df.to_parquet,
        rfunc=pdf.to_parquet,
        lfunc_args_and_kwargs=(["cudf.parquet"],),
        rfunc_args_and_kwargs=(["pandas.parquet"],),
    )


def test_parquet_writer_nulls_pandas_read(tmpdir, pdf):
    if "col_bool" in pdf.columns:
        pdf.drop(columns="col_bool", inplace=True)
    if "col_category" in pdf.columns:
        pdf.drop(columns="col_category", inplace=True)
    gdf = cudf.from_pandas(pdf)

    num_rows = len(gdf)
    if num_rows == 1:
        pytest.skip("Skipping due a bug in parquet writer with all null df")

    if num_rows > 0:
        for col in gdf.columns:
            gdf[col][random.randint(0, num_rows - 1)] = None

    fname = tmpdir.join("test_parquet_writer_nulls_pandas_read.parquet")
    gdf.to_parquet(fname)
    assert os.path.exists(fname)

    got = pd.read_parquet(fname)
    nullable = True if num_rows > 0 else False
    assert_eq(gdf.to_pandas(nullable=nullable), got)


def test_parquet_decimal_precision(tmpdir):
    df = cudf.DataFrame({"val": ["3.5", "4.2"]}).astype(
        cudf.Decimal64Dtype(5, 2)
    )
    assert df.val.dtype.precision == 5

    fname = tmpdir.join("decimal_test.parquet")
    df.to_parquet(fname)
    df = cudf.read_parquet(fname)
    assert df.val.dtype.precision == 5


def test_parquet_decimal_precision_empty(tmpdir):
    df = (
        cudf.DataFrame({"val": ["3.5", "4.2"]})
        .astype(cudf.Decimal64Dtype(5, 2))
        .iloc[:0]
    )
    assert df.val.dtype.precision == 5

    fname = tmpdir.join("decimal_test.parquet")
    df.to_parquet(fname)
    df = cudf.read_parquet(fname)
    assert df.val.dtype.precision == 5
