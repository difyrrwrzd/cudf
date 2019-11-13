/*
 * Copyright (c) 2019, NVIDIA CORPORATION.
 *
 * Copyright 2018-2019 BlazingDB, Inc.
 *     Copyright 2018 Christian Noboa Mardini <christian@blazingdb.com>
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

#include <tests/utilities/legacy/cudf_test_fixtures.h>
#include <cudf/legacy/transform.hpp>
#include "assert-unary.h"
#include <cudf/types.h>

#include <cctype>

#include <tests/utilities/legacy/nvcategory_utils.cuh>
#include <tests/utilities/legacy/valid_vectors.h>

namespace cudf {
namespace test {
namespace transformation {

struct UnaryOperationIntegrationTest : public GdfTest {};

template<class dtype, class Op, class Data>
void test_cuda_and_ptx_udf(
    const char cuda[], 
    const char ptx[], 
    Op op, 
    Data data_init, 
    cudf::size_type size
){
    auto in = cudf::test::column_wrapper<dtype>(
        size, data_init, [](cudf::size_type row) {return true;});
  { 
    gdf_column cpp_output_col;
    // false means the string is a piece of CUDA code
    CUDF_EXPECT_NO_THROW(cpp_output_col = cudf::transform(*in.get(), cuda, gdf_dtype_of<dtype>(), false));

    auto cpp_out = cudf::test::column_wrapper<dtype>(cpp_output_col);
    ASSERT_UNARY(cpp_out, in, op);
    
    gdf_column_free(&cpp_output_col);
  }
  {
    gdf_column cpp_output_col;
    // true means the string is a piece of PTX code
    CUDF_EXPECT_NO_THROW(cpp_output_col = cudf::transform(*in.get(), ptx, gdf_dtype_of<dtype>(), true));

    auto cpp_out = cudf::test::column_wrapper<dtype>(cpp_output_col);
    ASSERT_UNARY(cpp_out, in, op);
    
    gdf_column_free(&cpp_output_col);
  }
}

TEST_F(UnaryOperationIntegrationTest, Transform_FP32_FP32) {

// c = a*a*a*a
const char* cuda =
R"***(
__device__ inline void    fdsf   (
       float* C,
       float a
)
{
  *C = a*a*a*a;
}
)***";

const char* ptx =
R"***(
//
// Generated by NVIDIA NVVM Compiler
//
// Compiler Build ID: CL-24817639
// Cuda compilation tools, release 10.0, V10.0.130
// Based on LLVM 3.4svn
//

.version 6.3
.target sm_70
.address_size 64

	// .globl	_ZN8__main__7add$241Ef
.common .global .align 8 .u64 _ZN08NumbaEnv8__main__7add$241Ef;
.common .global .align 8 .u64 _ZN08NumbaEnv5numba7targets7numbers14int_power_impl12$3clocals$3e13int_power$242Efx;

.visible .func  (.param .b32 func_retval0) _ZN8__main__7add$241Ef(
	.param .b64 _ZN8__main__7add$241Ef_param_0,
	.param .b32 _ZN8__main__7add$241Ef_param_1
)
{
	.reg .f32 	%f<4>;
	.reg .b32 	%r<2>;
	.reg .b64 	%rd<2>;


	ld.param.u64 	%rd1, [_ZN8__main__7add$241Ef_param_0];
	ld.param.f32 	%f1, [_ZN8__main__7add$241Ef_param_1];
	mul.f32 	%f2, %f1, %f1;
	mul.f32 	%f3, %f2, %f2;
	st.f32 	[%rd1], %f3;
	mov.u32 	%r1, 0;
	st.param.b32	[func_retval0+0], %r1;
	ret;
}
)***";

  using dtype = float;
  auto op = [](dtype a) {return a*a*a*a;};
  auto data_init = [](cudf::size_type row) {return row % 3;};
  
  test_cuda_and_ptx_udf<dtype>(cuda, ptx, op, data_init, 500);

}

TEST_F(UnaryOperationIntegrationTest, Transform_INT32_INT32) {

// c = a * a - a
const char cuda[] =
R"***(
__device__ inline void f(
  int* output, 
  int input
){
  *output = input*input - input;
}
)***";

const char* ptx =
R"***(
.func _Z1fPii(
        .param .b64 _Z1fPii_param_0,
        .param .b32 _Z1fPii_param_1
)
{
        .reg .b32       %r<4>;
        .reg .b64       %rd<3>;


        ld.param.u64    %rd1, [_Z1fPii_param_0];
        ld.param.u32    %r1, [_Z1fPii_param_1];
        cvta.to.global.u64      %rd2, %rd1;
        mul.lo.s32      %r2, %r1, %r1;
        sub.s32         %r3, %r2, %r1;
        st.global.u32   [%rd2], %r3;
        ret;
}
)***";
  
  using dtype = int;
  auto op = [](dtype a) {return a*a-a;};
  auto data_init = [](cudf::size_type row) {return row % 78;};
  
  test_cuda_and_ptx_udf<dtype>(cuda, ptx, op, data_init, 500);

}

TEST_F(UnaryOperationIntegrationTest, Transform_INT8_INT8) {

  // Capitalize all the lower case letters
  // Assuming ASCII, the PTX code is compiled from the following CUDA code

  const char cuda[] = 
R"***(
__device__ inline void f(
  signed char* output, 
  signed char input
){
	if(input > 96 && input < 123){	
  	*output = input - 32;
  }else{
  	*output = input;    
  }
}
)***";

  const char ptx[] = 
R"***(
.func _Z1fPcc(
        .param .b64 _Z1fPcc_param_0,
        .param .b32 _Z1fPcc_param_1
)
{
        .reg .pred      %p<2>;
        .reg .b16       %rs<6>;
        .reg .b32       %r<3>;
        .reg .b64       %rd<3>;


        ld.param.u64    %rd1, [_Z1fPcc_param_0];
        cvta.to.global.u64      %rd2, %rd1;
        ld.param.s8     %rs1, [_Z1fPcc_param_1];
        add.s16         %rs2, %rs1, -97;
        and.b16         %rs3, %rs2, 255;
        setp.lt.u16     %p1, %rs3, 26;
        cvt.u32.u16     %r1, %rs1;
        add.s32         %r2, %r1, 224;
        cvt.u16.u32     %rs4, %r2;
        selp.b16        %rs5, %rs4, %rs1, %p1;
        st.global.u8    [%rd2], %rs5;
        ret;
}
)***";

  using dtype = int8_t;
  auto op = [](dtype a){return std::toupper(a);};  
  auto data_init = [](cudf::size_type row){return 'a' + (row % 26);};

  test_cuda_and_ptx_udf<dtype>(cuda, ptx, op, data_init, 500);

}

} // namespace transformation
} // namespace test
} // namespace cudf
