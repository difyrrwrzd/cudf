#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2023 NVIDIA CORPORATION & AFFILIATES.
# All rights reserved.
# SPDX-License-Identifier: LicenseRef-NvidiaProprietary
#
# NVIDIA CORPORATION, its affiliates and licensors retain all intellectual
# property and proprietary rights in and to this material, related
# documentation and any modifications thereto. Any use, reproduction,
# disclosure or distribution of this material and related documentation
# without an express license agreement from NVIDIA CORPORATION or
# its affiliates is strictly prohibited.

set -eoxu pipefail

# Function to display script usage
function display_usage {
    echo "Usage: $0 [--no-cudf]"
}

# Default value for the --no-cudf option
no_cudf=false

# Parse command-line arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-cudf)
            no_cudf=true
            shift
            ;;
        *)
            echo "Error: Unknown option $1"
            display_usage
            exit 1
            ;;
    esac
done

if [ "$no_cudf" = true ]; then
    echo "Skipping cudf install"
else
    RAPIDS_PY_CUDA_SUFFIX="$(rapids-wheel-ctk-name-gen ${RAPIDS_CUDA_VERSION})"
    RAPIDS_PY_WHEEL_NAME="cudf_${RAPIDS_PY_CUDA_SUFFIX}" rapids-download-wheels-from-s3 ./local-cudf-dep
    python -m pip install --no-deps ./local-cudf-dep/cudf*.whl
fi
cd python/xdf/
python -m pip install .[test]

python -m pytest ./tests

python -m pytest -p xdf.autoload ./tests
