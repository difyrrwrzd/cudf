# Copyright (c) 2024, NVIDIA CORPORATION.

import cudf_kafka


def test_version_constants_are_populated():
    # __git_commit__ will only be non-empty in a built distribution
    assert isinstance(cudf_kafka.__git_commit__, str)

    # __version__ should always be non-empty
    assert isinstance(cudf_kafka.__version__, str)
    assert len(cudf_kafka.__version__) > 0
