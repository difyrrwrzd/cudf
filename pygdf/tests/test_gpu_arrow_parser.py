# Copyright (c) 2018, NVIDIA CORPORATION.

import logging

import numpy as np
from numba import cuda

from pygdf.gpuarrow import GpuArrowReader


def test_gpu_parse_arrow_data():
    # make gpu array
    schema_data = b"""\x00\x01\x00\x00\x10\x00\x00\x00\x0c\x00\x0e\x00\x06\x00\x05\x00\x08\x00\x00\x00\x0c\x00\x00\x00\x00\x01\x02\x00\x10\x00\x00\x00\x00\x00\n\x00\x08\x00\x00\x00\x04\x00\x00\x00\n\x00\x00\x00\x04\x00\x00\x00\x02\x00\x00\x00l\x00\x00\x00\x04\x00\x00\x00\xb0\xff\xff\xff\x00\x00\x01\x038\x00\x00\x00\x1c\x00\x00\x00\x14\x00\x00\x00\x04\x00\x00\x00\x02\x00\x00\x00\x1c\x00\x00\x00\x10\x00\x00\x00\x00\x00\x00\x00\x9a\xff\xff\xff\x00\x00\x01\x00\x8c\xff\xff\xff \x00\x01\x00\x94\xff\xff\xff\x01\x00\x02\x00\x08\x00\x00\x00dest_lon\x00\x00\x00\x00\x14\x00\x18\x00\x08\x00\x06\x00\x07\x00\x0c\x00\x00\x00\x10\x00\x14\x00\x00\x00\x14\x00\x00\x00\x00\x00\x01\x03H\x00\x00\x00$\x00\x00\x00\x14\x00\x00\x00\x04\x00\x00\x00\x02\x00\x00\x00,\x00\x00\x00\x18\x00\x00\x00\x00\x00\x00\x00\x00\x00\x06\x00\x08\x00\x06\x00\x06\x00\x00\x00\x00\x00\x01\x00\xf8\xff\xff\xff \x00\x01\x00\x08\x00\x08\x00\x04\x00\x06\x00\x08\x00\x00\x00\x01\x00\x02\x00\x08\x00\x00\x00dest_lat\x00\x00\x00\x00\x00\x00\x00\x00"""  # noqa: E501
    recbatch_data = b"""\xdc\x00\x00\x00\x14\x00\x00\x00\x00\x00\x00\x00\x0c\x00\x16\x00\x06\x00\x05\x00\x08\x00\x0c\x00\x0c\x00\x00\x00\x00\x03\x02\x00\x18\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00\n\x00\x18\x00\x0c\x00\x04\x00\x08\x00\n\x00\x00\x00|\x00\x00\x00\x10\x00\x00\x00\x17\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x04\x00\x00\x00\xff\xff\xff\xff\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\xff\xff\xff\xff\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x80\x00\x00\x00\x00\x00\x00\x00\xff\xff\xff\xff\x00\x00\x00\x00\x80\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\xff\xff\xff\xff\x00\x00\x00\x00\x80\x00\x00\x00\x00\x00\x00\x00\x80\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x00\x00\x17\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x17\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\xbf0\x1dB\xd9$\'B\x02E\xecA\xd9$\'B\xbf0\x1dB\x9c\xb3\x1cB\xd1)\xedAw\x7f\x10B\x02E\xecArc\x03B\x02E\xecArc\x03B\xd9$\'B\x93\xb2\x18BC\xf7!B\xd9$\'B\x91\xa7\x06Bg\x8e\xf1A\xd9$\'Bw\x7f\x10B]n\xe3A\xd9$\'B\x02E\xecA\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x85m\xbd\xc2>\x81\xaf\xc2\x87\xf0\xc4\xc2>\x81\xaf\xc2\x85m\xbd\xc2\x1eV\x99\xc2\xcb\x8e\xbe\xc2;[\xad\xc2\x87\xf0\xc4\xc2\x1b\xb4\xc1\xc2\x87\xf0\xc4\xc2\x1b\xb4\xc1\xc2>\x81\xaf\xc2\xd5x\xab\xc2;w\xa0\xc2>\x81\xaf\xc2C\xa5\xcb\xc2\xf9V\xc3\xc2>\x81\xaf\xc2;[\xad\xc2\xce\xa1\xa2\xc2>\x81\xaf\xc2\x87\xf0\xc4\xc2\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00"""  # noqa: E501

    cpu_schema = np.ndarray(shape=len(schema_data), dtype=np.byte,
                            buffer=bytearray(schema_data))
    cpu_data = np.ndarray(shape=len(recbatch_data), dtype=np.byte,
                          buffer=bytearray(recbatch_data))
    gpu_data = cuda.to_device(cpu_data)
    del cpu_data

    # test reader
    reader = GpuArrowReader(cpu_schema, gpu_data)
    assert reader[0].name == 'dest_lat'
    assert reader[1].name == 'dest_lon'
    lat = reader[0].data.copy_to_host()
    lon = reader[1].data.copy_to_host()
    assert lat.size == 23
    assert lon.size == 23
    np.testing.assert_array_less(lat, 42)
    np.testing.assert_array_less(27, lat)
    np.testing.assert_array_less(lon, -76)
    np.testing.assert_array_less(-105, lon)

    dct = reader.to_dict()
    np.testing.assert_array_equal(lat, dct['dest_lat'].to_array())
    np.testing.assert_array_equal(lon, dct['dest_lon'].to_array())


expected_values = """
0,orange,0.4713545411053003
1,orange,0.003790919207527499
2,orange,0.4396940888188392
3,apple,0.5693619092183622
4,pear,0.10894215574048405
5,pear,0.09547296520000881
6,orange,0.4123169425191555
7,apple,0.4125838710498503
8,orange,0.1904218750870219
9,apple,0.9289366739893021
10,orange,0.9330387015860205
11,pear,0.46564799732291595
12,apple,0.8573176464520044
13,pear,0.21566885180419648
14,orange,0.9199361970381871
15,orange,0.9819955872277085
16,apple,0.415964752238025
17,grape,0.36941794781567516
18,apple,0.9761832273396152
19,grape,0.16672327312068824
20,orange,0.13311815129622395
21,orange,0.6230693626648358
22,pear,0.7321171864853122
23,grape,0.23106658283660853
24,pear,0.0198404248930919
25,orange,0.4032931749027482
26,grape,0.665861129515741
27,pear,0.10253071509254097
28,orange,0.15243296681892238
29,pear,0.3514868485827787
"""


def get_expected_values():
    lines = filter(lambda x: x.strip(), expected_values.splitlines())
    rows = [ln.split(',') for ln in lines]
    return [(int(idx), name, float(weight))
            for idx, name, weight in rows]


def test_gpu_parse_arrow_cats():
    schema_bytes = b"""\xa8\x01\x00\x00\x10\x00\x00\x00\x0c\x00\x0e\x00\x06\x00\x05\x00\x08\x00\x00\x00\x0c\x00\x00\x00\x00\x01\x02\x00\x10\x00\x00\x00\x00\x00\n\x00\x08\x00\x00\x00\x04\x00\x00\x00\n\x00\x00\x00\x04\x00\x00\x00\x03\x00\x00\x00\x18\x01\x00\x00p\x00\x00\x00\x04\x00\x00\x00\x08\xff\xff\xff\x00\x00\x01\x03@\x00\x00\x00$\x00\x00\x00\x14\x00\x00\x00\x04\x00\x00\x00\x02\x00\x00\x00$\x00\x00\x00\x18\x00\x00\x00\x00\x00\x00\x00\x00\x00\x06\x00\x08\x00\x06\x00\x06\x00\x00\x00\x00\x00\x02\x00\xe8\xfe\xff\xff@\x00\x01\x00\xf0\xfe\xff\xff\x01\x00\x02\x00\x06\x00\x00\x00weight\x00\x00\x14\x00\x1e\x00\x08\x00\x06\x00\x07\x00\x0c\x00\x10\x00\x14\x00\x18\x00\x00\x00\x14\x00\x00\x00\x00\x00\x01\x05|\x00\x00\x00T\x00\x00\x00\x18\x00\x00\x00D\x00\x00\x000\x00\x00\x00\x00\x00\n\x00\x14\x00\x08\x00\x04\x00\x00\x00\n\x00\x00\x00\x10\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00p\xff\xff\xff\x00\x00\x00\x01 \x00\x00\x00\x03\x00\x00\x000\x00\x00\x00$\x00\x00\x00\x10\x00\x00\x00\x00\x00\x00\x00\x04\x00\x04\x00\x04\x00\x00\x00|\xff\xff\xff\x08\x00\x01\x00\x08\x00\x08\x00\x06\x00\x00\x00\x08\x00\x00\x00\x00\x00 \x00\x94\xff\xff\xff\x01\x00\x02\x00\x04\x00\x00\x00name\x00\x00\x00\x00\x14\x00\x18\x00\x08\x00\x06\x00\x07\x00\x0c\x00\x00\x00\x10\x00\x14\x00\x00\x00\x14\x00\x00\x00\x00\x00\x01\x02L\x00\x00\x00$\x00\x00\x00\x14\x00\x00\x00\x04\x00\x00\x00\x02\x00\x00\x000\x00\x00\x00\x1c\x00\x00\x00\x00\x00\x00\x00\x08\x00\x0c\x00\x08\x00\x07\x00\x08\x00\x00\x00\x00\x00\x00\x01 \x00\x00\x00\xf8\xff\xff\xff \x00\x01\x00\x08\x00\x08\x00\x04\x00\x06\x00\x08\x00\x00\x00\x01\x00\x02\x00\x03\x00\x00\x00idx\x00\xc8\x00\x00\x00\x14\x00\x00\x00\x00\x00\x00\x00\x0c\x00\x14\x00\x06\x00\x05\x00\x08\x00\x0c\x00\x0c\x00\x00\x00\x00\x02\x02\x00\x14\x00\x00\x00\x80\x00\x00\x00\x00\x00\x00\x00\x08\x00\x12\x00\x08\x00\x04\x00\x08\x00\x00\x00\x18\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\n\x00\x18\x00\x0c\x00\x04\x00\x08\x00\n\x00\x00\x00d\x00\x00\x00\x10\x00\x00\x00\x04\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x03\x00\x00\x00\xff\xff\xff\xff\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\xff\xff\xff\xff\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00@\x00\x00\x00\x00\x00\x00\x00\xff\xff\xff\xff\x00\x00\x00\x00@\x00\x00\x00\x00\x00\x00\x00@\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x04\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x06\x00\x00\x00\x0b\x00\x00\x00\x0f\x00\x00\x00\x14\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00orangeapplepeargrape\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00"""  # noqa: E501
    schema = np.ndarray(shape=len(schema_bytes), dtype=np.byte,
                        buffer=bytearray(schema_bytes))

    recordbatches_bytes = b"""\x1c\x01\x00\x00\x14\x00\x00\x00\x00\x00\x00\x00\x0c\x00\x16\x00\x06\x00\x05\x00\x08\x00\x0c\x00\x0c\x00\x00\x00\x00\x03\x02\x00\x18\x00\x00\x00\x00\x02\x00\x00\x00\x00\x00\x00\x00\x00\n\x00\x18\x00\x0c\x00\x04\x00\x08\x00\n\x00\x00\x00\xac\x00\x00\x00\x10\x00\x00\x00\x1e\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x06\x00\x00\x00\xff\xff\xff\xff\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\xff\xff\xff\xff\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x80\x00\x00\x00\x00\x00\x00\x00\xff\xff\xff\xff\x00\x00\x00\x00\x80\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\xff\xff\xff\xff\x00\x00\x00\x00\x80\x00\x00\x00\x00\x00\x00\x00\x80\x00\x00\x00\x00\x00\x00\x00\xff\xff\xff\xff\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\xff\xff\xff\xff\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x03\x00\x00\x00\x1e\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x1e\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x1e\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x02\x00\x00\x00\x03\x00\x00\x00\x10\x00\x00\x00\x11\x00\x00\x00\x12\x00\x00\x00\x13\x00\x00\x00\x04\x00\x00\x00\x05\x00\x00\x00\x06\x00\x00\x00\x07\x00\x00\x00\x14\x00\x00\x00\x15\x00\x00\x00\x16\x00\x00\x00\x17\x00\x00\x00\x08\x00\x00\x00\t\x00\x00\x00\n\x00\x00\x00\x0b\x00\x00\x00\x18\x00\x00\x00\x19\x00\x00\x00\x1a\x00\x00\x00\x1b\x00\x00\x00\x0c\x00\x00\x00\r\x00\x00\x00\x0e\x00\x00\x00\x0f\x00\x00\x00\x1c\x00\x00\x00\x1d\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x01\x00\x00\x00\x03\x00\x00\x00\x01\x00\x00\x00\x03\x00\x00\x00\x02\x00\x00\x00\x02\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x00\x00\x03\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x02\x00\x00\x00\x02\x00\x00\x00\x00\x00\x00\x00\x03\x00\x00\x00\x02\x00\x00\x00\x01\x00\x00\x00\x02\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x16\x93\xb7<\xac*\xde?\x00Y\x94@"\x0eo?\xf8+\xee\xac\xf2#\xdc?\xa4\xcauw68\xe2?\xf8\xaa\xc9\x9f*\x9f\xda?\xe0\x1e\x1b-\x8b\xa4\xd7?\xe6y\x8a\x9b\xe4<\xef?\x08\x89\xc4.0W\xc5?h\xa5\x0f\x14\xa2\xe3\xbb?\xc0\xa9/\x8f\xeap\xb8?\x0c7\xed\x99fc\xda?:\tA.\xc6g\xda?\x1c\x1f)\xfd\x03\n\xc1?\xfe\x1e\xf9(/\xf0\xe3?\x08h\x99\x05\x81m\xe7?\xa0\xa8=\xfc\x96\x93\xcd?x\x8b\xf8v\xbe_\xc8?\xa2\xd9Zg\xd9\xb9\xed?;\xdb\xa6\xfas\xdb\xed?\xd8\xc9\xfcA-\xcd\xdd?@\xe27`\x0cQ\x94?d\x11:-\x8e\xcf\xd9?\xc9S\xde\xff\xbbN\xe5?\xe0o(\xf4s?\xba?\x0bq\xb9j%o\xeb?\x10\xe8\xa1t\t\x9b\xcb?\xa5\xf0\x15\t\x1ep\xed?\xc7\xb2~\x02\x82l\xef?0\xe6\xa8g\xec\x82\xc3?\xe0\xc6\xe8\xb1\xc2~\xd6?\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00"""  # noqa: E501
    rb_cpu_data = np.ndarray(shape=len(recordbatches_bytes), dtype=np.byte,
                             buffer=bytearray(recordbatches_bytes))
    rb_gpu_data = cuda.to_device(rb_cpu_data)

    gar = GpuArrowReader(schema, rb_gpu_data)
    columns = gar.to_dict()

    sr_idx = columns['idx']
    sr_name = columns['name']
    sr_weight = columns['weight']

    assert sr_idx.dtype == np.int32
    assert sr_name.dtype == 'category'
    assert sr_weight.dtype == np.double
    assert set(sr_name) == {'apple', 'pear', 'orange', 'grape'}

    expected = get_expected_values()
    for i in range(len(sr_idx)):
        got_idx = sr_idx[i]
        got_name = sr_name[i]
        got_weight = sr_weight[i]

        # the serialized data is not of order
        exp_idx, exp_name, exp_weight = expected[got_idx]

        assert got_idx == exp_idx
        assert got_name == exp_name
        np.testing.assert_almost_equal(got_weight, exp_weight)


def test_gpu_parse_arrow_int16():
    schema_bytes = b'\x08\x01\x00\x00\x10\x00\x00\x00\x0c\x00\x0e\x00\x06\x00\x05\x00\x08\x00\x00\x00\x0c\x00\x00\x00\x00\x01\x02\x00\x10\x00\x00\x00\x00\x00\n\x00\x08\x00\x00\x00\x04\x00\x00\x00\n\x00\x00\x00\x04\x00\x00\x00\x02\x00\x00\x00p\x00\x00\x00\x04\x00\x00\x00\xac\xff\xff\xff\x00\x00\x01\x02<\x00\x00\x00\x1c\x00\x00\x00\x14\x00\x00\x00\x04\x00\x00\x00\x02\x00\x00\x00 \x00\x00\x00\x14\x00\x00\x00\x00\x00\x00\x00\x98\xff\xff\xff\x00\x00\x00\x01\x10\x00\x00\x00\x88\xff\xff\xff\x10\x00\x01\x00\x90\xff\xff\xff\x01\x00\x02\x00\x08\x00\x00\x00arrdelay\x00\x00\x00\x00\x14\x00\x18\x00\x08\x00\x06\x00\x07\x00\x0c\x00\x00\x00\x10\x00\x14\x00\x00\x00\x14\x00\x00\x00\x00\x00\x01\x02L\x00\x00\x00$\x00\x00\x00\x14\x00\x00\x00\x04\x00\x00\x00\x02\x00\x00\x000\x00\x00\x00\x1c\x00\x00\x00\x00\x00\x00\x00\x08\x00\x0c\x00\x08\x00\x07\x00\x08\x00\x00\x00\x00\x00\x00\x01\x10\x00\x00\x00\xf8\xff\xff\xff\x10\x00\x01\x00\x08\x00\x08\x00\x04\x00\x06\x00\x08\x00\x00\x00\x01\x00\x02\x00\x08\x00\x00\x00depdelay\x00\x00\x00\x00\x00\x00\x00\x00'  # noqa

    recordbatches_bytes = b'\xdc\x00\x00\x00\x14\x00\x00\x00\x00\x00\x00\x00\x0c\x00\x16\x00\x06\x00\x05\x00\x08\x00\x0c\x00\x0c\x00\x00\x00\x00\x03\x02\x00\x18\x00\x00\x00\x80\x00\x00\x00\x00\x00\x00\x00\x00\x00\n\x00\x18\x00\x0c\x00\x04\x00\x08\x00\n\x00\x00\x00|\x00\x00\x00\x10\x00\x00\x00\n\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x04\x00\x00\x00\xff\xff\xff\xff\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\xff\xff\xff\xff\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00@\x00\x00\x00\x00\x00\x00\x00\xff\xff\xff\xff\x00\x00\x00\x00@\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\xff\xff\xff\xff\x00\x00\x00\x00@\x00\x00\x00\x00\x00\x00\x00@\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x00\x00\n\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\n\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\xfd\xff\xfe\xff\x0b\x00\x06\x00\xf9\xff\xfc\xff\x04\x00\xfd\xff\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x05\x00\xfd\xff\x01\x00\xfe\xff\x16\x00\x0b\x00\xf4\xff\xfb\xff\x04\x00\xf7\xff\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00'  # noqa

    schema = np.ndarray(shape=len(schema_bytes), dtype=np.byte,
                        buffer=bytearray(schema_bytes))

    rb_cpu_data = np.ndarray(shape=len(recordbatches_bytes), dtype=np.byte,
                             buffer=bytearray(recordbatches_bytes))

    rb_gpu_data = cuda.to_device(rb_cpu_data)
    gar = GpuArrowReader(schema, rb_gpu_data)
    columns = gar.to_dict()
    assert columns['depdelay'].dtype == np.int16
    assert set(columns) == {"depdelay", "arrdelay"}
    assert list(columns['depdelay']) == [0, 0, -3, -2, 11, 6, -7, -4, 4, -3]


if __name__ == '__main__':
    logging.basicConfig(level=logging.INFO)
    logging.getLogger('pygdf.gpuarrow').setLevel(logging.DEBUG)

    test_gpu_parse_arrow_data()
