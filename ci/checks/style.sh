#!/bin/bash
# Copyright (c) 2018-2022, NVIDIA CORPORATION.
#####################
# cuDF Style Tester #
#####################

# Ignore errors and set path
set +e
PATH=/conda/bin:$PATH
LC_ALL=C.UTF-8
LANG=C.UTF-8

# Activate common conda env
. /opt/conda/etc/profile.d/conda.sh
conda activate rapids

FORMAT_FILE_URL=https://raw.githubusercontent.com/rapidsai/rapids-cmake/branch-22.08/cmake-format-rapids-cmake.json
export RAPIDS_CMAKE_FORMAT_FILE=/tmp/rapids_cmake_ci/cmake-formats-rapids-cmake.json
mkdir -p $(dirname ${RAPIDS_CMAKE_FORMAT_FILE})
wget -O ${RAPIDS_CMAKE_FORMAT_FILE} ${FORMAT_FILE_URL}


pre-commit run --hook-stage manual --all-files
PRE_COMMIT_RETVAL=$?

# Check for copyright headers in the files modified currently
COPYRIGHT=`python ci/checks/copyright.py --git-modified-only 2>&1`
CR_RETVAL=$?

# Output results if failure otherwise show pass
if [ "$CR_RETVAL" != "0" ]; then
  echo -e "\n\n>>>> FAILED: copyright check; begin output\n\n"
  echo -e "$COPYRIGHT"
  echo -e "\n\n>>>> FAILED: copyright check; end output\n\n"
else
  echo -e "\n\n>>>> PASSED: copyright check\n\n"
  echo -e "$COPYRIGHT"
fi

# Run clang-format and check for a consistent code format
CLANG_FORMAT=`python cpp/scripts/run-clang-format.py 2>&1`
CLANG_FORMAT_RETVAL=$?

if [ "$CLANG_FORMAT_RETVAL" != "0" ]; then
  echo -e "\n\n>>>> FAILED: clang format check; begin output\n\n"
  echo -e "$CLANG_FORMAT"
  echo -e "\n\n>>>> FAILED: clang format check; end output\n\n"
else
  echo -e "\n\n>>>> PASSED: clang format check\n\n"
fi

# Run header meta.yml check and get results/return code
HEADER_META=`ci/checks/headers_test.sh`
HEADER_META_RETVAL=$?
echo -e "$HEADER_META"

RETVALS=(
  $CR_RETVAL $PRE_COMMIT_RETVAL $CLANG_FORMAT_RETVAL $HEADER_META_RETVAL
)
IFS=$'\n'
RETVAL=`echo "${RETVALS[*]}" | sort -nr | head -n1`

exit $RETVAL
