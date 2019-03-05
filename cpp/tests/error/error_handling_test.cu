/*
 * Copyright (c) 2018, NVIDIA CORPORATION.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
#include "cudf.h"
#include "gtest/gtest.h"
#include "utilities/error_utils.hpp"

#include <rmm/rmm.h>
#include <cuda_runtime_api.h>
#include <cstring>

// If this test fails, it means an error code was added without
// adding support to gdf_error_get_name().
TEST(ErrorTest, NameEveryError) {
  for (int i = 0; i < N_GDF_ERRORS; i++) {
    const char *res = gdf_error_get_name((gdf_error)i);
    ASSERT_EQ(0, strstr(res, "Unknown error"));
  }
}

TEST(ExpectsTest, FalseCondition) {
  EXPECT_THROW(CUDF_EXPECTS(false, "condition is false"),
               cudf::logic_error);
}

TEST(ExpectsTest, TrueCondition) {
  EXPECT_NO_THROW(CUDF_EXPECTS(true, "condition is true"));
}

TEST(ExpectsTest, TryCatch) {
  try{
      CUDF_EXPECTS(false, "test message");
  }
  catch(cudf::logic_error const& e){
      EXPECT_NE(nullptr, e.what());
      // TODO How to verify that the `what` message is as expected?
      // The exact content of the `what()` message depends on where
      // libcudf was built and therefore it's probably not appropriate to 
      // test the exact contents in a GTest
      //std::cout << e.what() << std::endl;
  }
}
