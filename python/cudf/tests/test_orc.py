# Copyright (c) 2019, NVIDIA CORPORATION.

import cudf
from cudf.tests.utils import assert_eq

import pandas as pd
import numpy as np
import pytest
import pyarrow as pa


@pytest.fixture(scope='module')
def datadir(datadir):
    return datadir / 'orc'


@pytest.mark.filterwarnings("ignore:Using CPU")
@pytest.mark.filterwarnings("ignore:Strings are not yet supported")
@pytest.mark.parametrize('engine', ['cudf'])
@pytest.mark.parametrize(
    'orc_args',
    [
        ['TestOrcFile.emptyFile.orc', ['boolean1']],
        ['TestOrcFile.test1.orc', ['boolean1', 'byte1', 'short1',
                                   'int1', 'long1', 'float1', 'double1']],
        ['TestOrcFile.testDate1900.orc', None]
    ]
)
def test_orc_reader(datadir, orc_args, engine):
    path = datadir / orc_args[0]
    orcfile = pa.orc.ORCFile(path)
    columns = orc_args[1]

    expect = orcfile.read(columns=columns).to_pandas(date_as_object=False)
    got = cudf.read_orc(path, engine=engine, columns=columns)

    # cuDF's default currently handles some types differently
    if engine == 'cudf':
        # For bool, cuDF doesn't support it so convert it to int8
        if 'boolean1' in expect.columns:
            expect['boolean1'] = expect['boolean1'].astype('int8')
        # For datetime64, cuDF only supports milliseconds, so convert Numpy
        if 'time' in expect.columns:
            #expect['time'] = pd.to_datetime(expect['time'], unit='ms')
            expect['time'] = expect['time'].astype('int64')
            got['time'] = got['time'].astype('int64')
        if 'date' in expect.columns:
            #expect['time'] = pd.to_datetime(expect['time'], unit='ms')
            expect['date'] = expect['date'].astype('int64')
            got['date'] = got['date'].astype('int64')

    print("")
    print("")
    print("Pyarrow:")
    print(expect.dtypes)
    if 'time' in expect.columns:
        print(expect['time'])
    print("")
    print("cuDF:")
    print(got.dtypes)
    print(got)
    print("")

    if 'time' in got.columns:
        #with open(str('/tmp/test.txt'), 'w') as fp:
            expectcol = expect['time']
            gotcol = got['time']
            for i in range(len(gotcol)):
                if expectcol[i] != gotcol[i]:
                    print("Time mismatched at [", i, "] expect: ", expectcol[i], " got: ", gotcol[i])
                    break
                #print("[", i, "] expect: ", expectcol[i], " got: ", gotcol[i], file=fp)
    if 'date' in got.columns:
        #with open(str('/tmp/test.txt'), 'w') as fp:
            expectcol = expect['date']
            gotcol = got['date']
            for i in range(len(gotcol)):
                if expectcol[i] != gotcol[i]:
                    print("Date mismatched at [", i, "] expect: ", expectcol[i], " got: ", gotcol[i])
                    break

    #np.testing.assert_allclose(expect['date'], got['date'])
    #np.testing.assert_allclose(expect['time'], got['time'])
