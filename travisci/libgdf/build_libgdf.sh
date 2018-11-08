set -e

# Patch tests for CUDA 10 skipping hash_map
## See https://github.com/rapidsai/libgdf/pull/149
if [ ${CUDA:0:4} == '10.0' ]; then
  echo "CUDA 10 detected, removing hash_map tests"
  sed -i.bak 's/add_subdirectory(hash_map)/#add_subdirectory(hash_map)/g' ./libgdf/src/tests/CMakeLists.txt
fi

if [ "$BUILD_LIBGDF" == '1' -o "$BUILD_CFFI" == '1' ]; then
    echo "Building libgdf"
    travis_retry conda build conda-recipes/libgdf -c rapidsai -c nvidia -c numba -c conda-forge -c defaults
fi
