#!/bin/bash

# Copyright (c) 2019-2021, NVIDIA CORPORATION.

# cuDF build script

# This script is used to build the component(s) in this repo from
# source, and can be called with various options to customize the
# build as needed (see the help output for details)
# Abort script on first error
set -e

NUMARGS=$#
ARGS=$*

# NOTE: ensure all dir changes are relative to the location of this
# script, and that this script resides in the repo dir!
REPODIR=$(cd $(dirname $0); pwd)

VALIDARGS="clean libcudf cudf dask_cudf benchmarks tests libcudf_kafka cudf_kafka custreamz -v -g -n -l --allgpuarch --disable_nvtx --show_depr_warn --ptds -h"
HELP="$0 [clean] [libcudf] [cudf] [dask_cudf] [benchmarks] [tests] [libcudf_kafka] [cudf_kafka] [custreamz] [-v] [-g] [-n] [-h] [-l]
   clean                - remove all existing build artifacts and configuration (start
                          over)
   libcudf              - build the cudf C++ code only
   cudf                 - build the cudf Python package
   dask_cudf            - build the dask_cudf Python package
   benchmarks           - build benchmarks
   tests                - build tests
   libcudf_kafka        - build the libcudf_kafka C++ code only
   cudf_kafka           - build the cudf_kafka Python package
   custreamz            - build the custreamz Python package
   -v                   - verbose build mode
   -g                   - build for debug
   -n                   - no install step
   -l                   - build legacy tests
   --allgpuarch         - build for all supported GPU architectures
   --disable_nvtx       - disable inserting NVTX profiling ranges
   --show_depr_warn     - show cmake deprecation warnings
   --ptds               - enable per-thread default stream
   -h | --h[elp]        - print this text

   default action (no args) is to build and install 'libcudf' then 'cudf'
   then 'dask_cudf' targets
"
LIB_BUILD_DIR=${LIB_BUILD_DIR:=${REPODIR}/cpp/build}
KAFKA_LIB_BUILD_DIR=${KAFKA_LIB_BUILD_DIR:=${REPODIR}/cpp/libcudf_kafka/build}
CUDF_KAFKA_BUILD_DIR=${REPODIR}/python/cudf_kafka/build
CUDF_BUILD_DIR=${REPODIR}/python/cudf/build
DASK_CUDF_BUILD_DIR=${REPODIR}/python/dask_cudf/build
CUSTREAMZ_BUILD_DIR=${REPODIR}/python/custreamz/build
BUILD_DIRS="${LIB_BUILD_DIR} ${CUDF_BUILD_DIR} ${DASK_CUDF_BUILD_DIR} ${KAFKA_LIB_BUILD_DIR} ${CUDF_KAFKA_BUILD_DIR} ${CUSTREAMZ_BUILD_DIR}"

# Set defaults for vars modified by flags to this script
VERBOSE_FLAG=""
BUILD_TYPE=Release
INSTALL_TARGET=install
BUILD_BENCHMARKS=OFF
BUILD_ALL_GPU_ARCH=0
BUILD_NVTX=ON
BUILD_TESTS=OFF
BUILD_DISABLE_DEPRECATION_WARNING=ON
BUILD_PER_THREAD_DEFAULT_STREAM=OFF

# Set defaults for vars that may not have been defined externally
#  FIXME: if INSTALL_PREFIX is not set, check PREFIX, then check
#         CONDA_PREFIX, but there is no fallback from there!
INSTALL_PREFIX=${INSTALL_PREFIX:=${PREFIX:=${CONDA_PREFIX}}}
PARALLEL_LEVEL=${PARALLEL_LEVEL:=$(nproc)}

function hasArg {
    (( ${NUMARGS} != 0 )) && (echo " ${ARGS} " | grep -q " $1 ")
}

function buildAll {
    ((${NUMARGS} == 0 )) || !(echo " ${ARGS} " | grep -q " [^-]\+ ")
}

if hasArg -h || hasArg --h || hasArg --help; then
    echo "${HELP}"
    exit 0
fi

# Check for valid usage
if (( ${NUMARGS} != 0 )); then
    for a in ${ARGS}; do
    if ! (echo " ${VALIDARGS} " | grep -q " ${a} "); then
        echo "Invalid option: ${a}"
        exit 1
    fi
    done
fi

# Process flags
if hasArg -v; then
    VERBOSE_FLAG="-v"
fi
if hasArg -g; then
    BUILD_TYPE=Debug
fi
if hasArg -n; then
    INSTALL_TARGET=""
    LIBCUDF_BUILD_DIR=${LIB_BUILD_DIR}
fi
if hasArg --allgpuarch; then
    BUILD_ALL_GPU_ARCH=1
fi
if hasArg benchmarks; then
    BUILD_BENCHMARKS=ON
fi
if hasArg tests; then
    BUILD_TESTS=ON
fi
if hasArg --disable_nvtx; then
    BUILD_NVTX="OFF"
fi
if hasArg --show_depr_warn; then
    BUILD_DISABLE_DEPRECATION_WARNING=OFF
fi
if hasArg --ptds; then
    BUILD_PER_THREAD_DEFAULT_STREAM=ON
fi

# If clean given, run it prior to any other steps
if hasArg clean; then
    # If the dirs to clean are mounted dirs in a container, the
    # contents should be removed but the mounted dirs will remain.
    # The find removes all contents but leaves the dirs, the rmdir
    # attempts to remove the dirs but can fail safely.
    for bd in ${BUILD_DIRS}; do
    if [ -d ${bd} ]; then
        find ${bd} -mindepth 1 -delete
        rmdir ${bd} || true
    fi
    done
fi


################################################################################
# Configure, build, and install libcudf

if buildAll || hasArg libcudf; then

    if (( ${BUILD_ALL_GPU_ARCH} == 0 )); then
        CUDF_CMAKE_CUDA_ARCHITECTURES="-DCMAKE_CUDA_ARCHITECTURES="
        echo "Building for the architecture of the GPU in the system..."
    else
        CUDF_CMAKE_CUDA_ARCHITECTURES=""
        echo "Building for *ALL* supported GPU architectures..."
    fi

    cmake -S $REPODIR/cpp -B ${LIB_BUILD_DIR} \
          -DCMAKE_INSTALL_PREFIX=${INSTALL_PREFIX} \
          ${CUDF_CMAKE_CUDA_ARCHITECTURES} \
          -DUSE_NVTX=${BUILD_NVTX} \
          -DBUILD_TESTS=${BUILD_TESTS} \
          -DBUILD_BENCHMARKS=${BUILD_BENCHMARKS} \
          -DDISABLE_DEPRECATION_WARNING=${BUILD_DISABLE_DEPRECATION_WARNING} \
          -DPER_THREAD_DEFAULT_STREAM=${BUILD_PER_THREAD_DEFAULT_STREAM} \
          -DCMAKE_BUILD_TYPE=${BUILD_TYPE}

    cd ${LIB_BUILD_DIR}

    cmake --build . -j${PARALLEL_LEVEL} ${VERBOSE_FLAG}

    if [[ ${INSTALL_TARGET} != "" ]]; then
        cmake --build . -j${PARALLEL_LEVEL} --target install ${VERBOSE_FLAG}
    fi
fi

# Build and install the cudf Python package
if buildAll || hasArg cudf; then

    cd ${REPODIR}/python/cudf
    if [[ ${INSTALL_TARGET} != "" ]]; then
        PARALLEL_LEVEL=${PARALLEL_LEVEL} python setup.py build_ext -j${PARALLEL_LEVEL} install --single-version-externally-managed --record=record.txt
    else
        PARALLEL_LEVEL=${PARALLEL_LEVEL} python setup.py build_ext --inplace -j${PARALLEL_LEVEL} --library-dir=${LIBCUDF_BUILD_DIR}
    fi
fi

# Build and install the dask_cudf Python package
if buildAll || hasArg dask_cudf; then

    cd ${REPODIR}/python/dask_cudf
    if [[ ${INSTALL_TARGET} != "" ]]; then
        PARALLEL_LEVEL=${PARALLEL_LEVEL} python setup.py build_ext --inplace -j${PARALLEL_LEVEL}
        python setup.py install --single-version-externally-managed --record=record.txt
    else
        PARALLEL_LEVEL=${PARALLEL_LEVEL} python setup.py build_ext --inplace -j${PARALLEL_LEVEL}
    fi
fi

# Build libcudf_kafka library
if hasArg libcudf_kafka; then
    cmake -S $REPODIR/cpp/libcudf_kafka -B ${KAFKA_LIB_BUILD_DIR} \
          -DCMAKE_INSTALL_PREFIX=${INSTALL_PREFIX} \
          -DBUILD_TESTS=${BUILD_TESTS} \
          -DCMAKE_BUILD_TYPE=${BUILD_TYPE}


    cd ${KAFKA_LIB_BUILD_DIR}
    cmake --build . -j${PARALLEL_LEVEL} ${VERBOSE_FLAG}

    if [[ ${INSTALL_TARGET} != "" ]]; then
        cmake --build . -j${PARALLEL_LEVEL} --target install ${VERBOSE_FLAG}
    fi
fi

# build cudf_kafka Python package
if hasArg cudf_kafka; then
    cd ${REPODIR}/python/cudf_kafka
    if [[ ${INSTALL_TARGET} != "" ]]; then
        PARALLEL_LEVEL=${PARALLEL_LEVEL} python setup.py build_ext --inplace -j${PARALLEL_LEVEL}
        python setup.py install --single-version-externally-managed --record=record.txt
    else
        PARALLEL_LEVEL=${PARALLEL_LEVEL} python setup.py build_ext --inplace -j${PARALLEL_LEVEL} --library-dir=${LIBCUDF_BUILD_DIR}
    fi
fi

# build custreamz Python package
if hasArg custreamz; then
    cd ${REPODIR}/python/custreamz
    if [[ ${INSTALL_TARGET} != "" ]]; then
        PARALLEL_LEVEL=${PARALLEL_LEVEL} python setup.py build_ext --inplace -j${PARALLEL_LEVEL}
        python setup.py install --single-version-externally-managed --record=record.txt
    else
        PARALLEL_LEVEL=${PARALLEL_LEVEL} python setup.py build_ext --inplace -j${PARALLEL_LEVEL} --library-dir=${LIBCUDF_BUILD_DIR}
    fi
fi
