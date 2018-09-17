/*
 * Copyright 2018 BlazingDB, Inc.
 *     Copyright 2018 Felipe Aramburu <felipe@blazingdb.com>
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

#include "gtest/gtest.h"

#include <iostream>
#include <gdf/gdf.h>
#include <gdf/cffi/functions.h>
#include <thrust/functional.h>
#include <thrust/device_ptr.h>

#include <thrust/execution_policy.h>
#include <cuda_runtime.h>
#include "helper/utils.cuh"


/*
 ============================================================================
 Description : Compute sum of reciprocals using STL on CPU and Thrust on GPU
 ============================================================================
 */
TEST(Example, Equals)
{
	gdf_size_type num_elements = 8;

	char *data_left;
	char *data_right;
	char *data_out;
	cudaError_t cuda_error = cudaMalloc((void **)&data_left, sizeof(int8_t) * num_elements);
	cuda_error = cudaMalloc((void **)&data_right, sizeof(int8_t) * num_elements);
	cuda_error = cudaMalloc((void **)&data_out, sizeof(int8_t) * num_elements);
	ASSERT_EQ(cuda_error, cudaSuccess);

	int8_t int8_value = 2;
	thrust::device_ptr<int8_t> right_ptr = thrust::device_pointer_cast((int8_t *)data_right);
	thrust::fill(thrust::detail::make_normal_iterator(right_ptr), thrust::detail::make_normal_iterator(right_ptr + num_elements), int8_value);

	//for this simple test we will send in only 8 values
	gdf_valid_type *valid = new gdf_valid_type;

	*valid = 255;
	gdf_valid_type *valid_device;
	cuda_error = cudaMalloc((void **)&valid_device, 1);
	cudaMemcpy(valid_device, valid, sizeof(gdf_valid_type), cudaMemcpyHostToDevice);
	
	gdf_valid_type *valid_out;
	cuda_error = cudaMalloc((void **)&valid_out, 1);
	gdf_column lhs;
	gdf_error error = gdf_column_view_augmented(&lhs, (void *)data_left, valid_device, num_elements, GDF_INT8, 0);
	gdf_column rhs;
	error = gdf_column_view_augmented(&rhs, (void *)data_right, valid_device, num_elements, GDF_INT8, 0);
	gdf_column output;
	error = gdf_column_view_augmented(&output, (void *)data_out, valid_out, num_elements, GDF_INT8, 0);
	ASSERT_EQ(error, GDF_SUCCESS);

	std::cout << "Left" << std::endl;
	print_column(&lhs);
	std::cout << "Right" << std::endl;
	print_column(&rhs);
	error = gpu_comparison(&lhs, &rhs, &output, GDF_EQUALS); // gtest!
	std::cout << "Output" << std::endl;
	print_column(&output);

	error = gpu_comparison_static_i8(&lhs, 3, &output, GDF_EQUALS);
	ASSERT_EQ(error, GDF_SUCCESS);
 
	std::cout << "Output static_i8" << std::endl;
	print_column(&output);

	cudaFree(data_left);
	cudaFree(data_right);
	cudaFree(data_out);
	cudaFree(valid_device);
	cudaFree(valid_out); 
	delete valid;

	EXPECT_EQ(1, 1);
}