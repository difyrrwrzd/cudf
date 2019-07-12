/*
 * Copyright (c) 2019, NVIDIA CORPORATION.
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

#include <cudf/bitmask/bitmask.hpp>
#include <cudf/bitmask/bitmask_device_view.cuh>
#include <cudf/bitmask/bitmask_view.hpp>
#include <cudf/types.hpp>
#include <rmm/device_buffer.hpp>

#include <thrust/logical.h>

#include <gmock/gmock.h>
#include <gtest/gtest.h>

struct BitmaskTest : public ::testing::Test {
  std::unique_ptr<cudf::bitmask> bitmask;
};

TEST_F(BitmaskTest, DefaultConstructor) {
  EXPECT_NO_THROW(bitmask = std::make_unique<cudf::bitmask>());
  EXPECT_EQ(0, bitmask->size());
  EXPECT_EQ(0u, bitmask->capacity());
  EXPECT_EQ(nullptr, bitmask->data());
}

namespace {
struct bit_is_set {
  cudf::bitmask_device_view _view;
  bit_is_set(cudf::bitmask_device_view view) : _view{view} {}
  __device__ bool operator()(cudf::size_type bit_index) {
    return _view.bit_is_set(bit_index);
  }
};
}  // namespace

TEST_F(BitmaskTest, SizeConstructorWithDefaults) {
  cudf::size_type size{100};
  EXPECT_NO_THROW(bitmask = std::make_unique<cudf::bitmask>(size));
  EXPECT_EQ(size, bitmask->size());
  EXPECT_EQ(cudf::bitmask_allocation_size_bytes(size), bitmask->capacity());
  EXPECT_NE(nullptr, bitmask->data());

  EXPECT_TRUE(thrust::all_of(thrust::device, thrust::make_counting_iterator(0),
                             thrust::make_counting_iterator(size),
                             bit_is_set{*bitmask}));
}

TEST_F(BitmaskTest, SizeConstructorAllOn) {
  cudf::size_type size{100};
  EXPECT_NO_THROW(
      bitmask = std::make_unique<cudf::bitmask>(size, cudf::bit_state::ON));
  EXPECT_EQ(size, bitmask->size());
  EXPECT_EQ(cudf::bitmask_allocation_size_bytes(size), bitmask->capacity());
  EXPECT_NE(nullptr, bitmask->data());
  EXPECT_TRUE(thrust::all_of(thrust::device, thrust::make_counting_iterator(0),
                             thrust::make_counting_iterator(size),
                             bit_is_set{*bitmask}));
}

TEST_F(BitmaskTest, SizeConstructorAllOff) {
  cudf::size_type size{100};
  EXPECT_NO_THROW(
      bitmask = std::make_unique<cudf::bitmask>(size, cudf::bit_state::OFF));
  EXPECT_EQ(size, bitmask->size());
  EXPECT_EQ(cudf::bitmask_allocation_size_bytes(size), bitmask->capacity());
  EXPECT_NE(nullptr, bitmask->data());
  EXPECT_FALSE(thrust::all_of(thrust::device, thrust::make_counting_iterator(0),
                              thrust::make_counting_iterator(size),
                              bit_is_set{*bitmask}));
}

TEST_F(BitmaskTest, CopyConstructor) {
  cudf::size_type size{100};
  EXPECT_NO_THROW(bitmask = std::make_unique<cudf::bitmask>(size));

  std::unique_ptr<cudf::bitmask> copy;
  EXPECT_NO_THROW(copy = std::make_unique<cudf::bitmask>(*bitmask));

  EXPECT_EQ(bitmask->size(), copy->size());
  EXPECT_EQ(cudf::bitmask_allocation_size_bytes(size), bitmask->capacity());
  EXPECT_NE(nullptr, copy->data());
  EXPECT_NE(bitmask->data(), copy->data());
  // TODO Ensure contents of device memory are equal
}

TEST_F(BitmaskTest, MoveConstructor) {
  cudf::size_type size{100};
  EXPECT_NO_THROW(bitmask = std::make_unique<cudf::bitmask>(size));

  auto original_data = bitmask->data();
  auto original_size = bitmask->size();
  auto original_capacity = bitmask->capacity();

  std::unique_ptr<cudf::bitmask> move;
  EXPECT_NO_THROW(move = std::make_unique<cudf::bitmask>(std::move(*bitmask)));
  EXPECT_EQ(original_data, move->data());
  EXPECT_EQ(original_size, move->size());
  EXPECT_EQ(original_capacity, move->capacity());
  EXPECT_EQ(nullptr, bitmask->data());
  EXPECT_EQ(0, bitmask->size());
}

TEST_F(BitmaskTest, CopyFromBuffer) {
  cudf::size_type size{100};
  rmm::device_buffer buff(cudf::bitmask_allocation_size_bytes(size));

  thrust::sequence(thrust::device, static_cast<uint8_t*>(buff.data()),
                   static_cast<uint8_t*>(buff.data()) + buff.size());

  EXPECT_NO_THROW(bitmask = std::make_unique<cudf::bitmask>(size, buff));
  EXPECT_EQ(size, bitmask->size());
  EXPECT_EQ(cudf::bitmask_allocation_size_bytes(size), bitmask->capacity());
  EXPECT_NE(nullptr, bitmask->data());
  EXPECT_NE(buff.data(), bitmask->data());

  // TODO Ensure contents of device memory are equal
}

TEST_F(BitmaskTest, CopyFromBufferTooSmall) {
  // TODO Implement
}

TEST_F(BitmaskTest, MoveFromBuffer) {
  // TODO Implement
}

TEST_F(BitmaskTest, MoveFromBufferTooSmall) {
  // TODO Implement
}

TEST_F(BitmaskTest, CopyFromViewNoOffset) {
  // TODO Implement
}

TEST_F(BitmaskTest, CopyFromViewWithOffset) {
  // TODO Implement
}

TEST_F(BitmaskTest, CopyFromMutableViewNoOffset) {
  // TODO Implement
}

TEST_F(BitmaskTest, CopyFromMutableViewWithOffset) {
  // TODO Implement
}

TEST_F(BitmaskTest, SliceToEnd) {
  // TODO Implement
}

TEST_F(BitmaskTest, SliceSize) {
  // TODO Implement
}

TEST_F(BitmaskTest, MutableSliceToEnd) {
  // TODO Implement
}

TEST_F(BitmaskTest, MutableSliceSize) {
  // TODO Implement
}

TEST_F(BitmaskTest, TestViews) {
  cudf::size_type size{100};
  EXPECT_NO_THROW(bitmask = std::make_unique<cudf::bitmask>(size));
  EXPECT_EQ(size, bitmask->size());
  EXPECT_NE(nullptr, bitmask->data());

  cudf::bitmask_view view = bitmask->view();
  EXPECT_EQ(size, view.size());
  EXPECT_EQ(0, view.offset());
  EXPECT_NE(nullptr, view.data());
  EXPECT_EQ(bitmask->data(), view.data());

  // Implicit conversion of a bitmask to a bitmask view
  cudf::bitmask_view converted_view = *bitmask;
  EXPECT_EQ(converted_view.size(), view.size());
  EXPECT_EQ(converted_view.offset(), view.offset());
  EXPECT_EQ(converted_view.data(), view.data());

  cudf::mutable_bitmask_view mutable_view = bitmask->mutable_view();
  EXPECT_EQ(size, mutable_view.size());
  EXPECT_EQ(0, mutable_view.offset());
  EXPECT_NE(nullptr, mutable_view.data());
  EXPECT_EQ(bitmask->data(), mutable_view.data());

  // Implicit conversion of a bitmask to a mutable view
  cudf::mutable_bitmask_view converted_mutable_view = *bitmask;
  EXPECT_EQ(converted_mutable_view.size(), mutable_view.size());
  EXPECT_EQ(converted_mutable_view.offset(), mutable_view.offset());
  EXPECT_EQ(converted_mutable_view.data(), mutable_view.data());

  // Members of mutable and immutable views should be equal
  EXPECT_EQ(mutable_view.size(), view.size());
  EXPECT_EQ(mutable_view.offset(), view.offset());
  EXPECT_EQ(mutable_view.data(), view.data());
}