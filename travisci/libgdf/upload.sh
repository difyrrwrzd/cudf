#!/bin/bash
#
# Copyright (c) 2018, NVIDIA CORPORATION.

set -e

function upload() {
    echo "UPLOADFILE = ${UPLOADFILE}"
    test -e ${UPLOADFILE}
    source ./travisci/libgdf/upload-anaconda.sh
}

# Upload libgdf
export UPLOADFILE=`conda build conda-recipes/libgdf -c defaults -c conda-forge --output`
upload

# Upload libgdf_cffi
export UPLOADFILE=`conda build conda-recipes/libgdf_cffi -c defaults -c conda-forge --python=${PYTHON} --output`
upload
