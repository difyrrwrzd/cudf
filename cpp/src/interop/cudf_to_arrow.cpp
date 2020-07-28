/*
 * Copyright (c) 2020, NVIDIA CORPORATION.
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

#include <cudf/column/column.hpp>
#include <cudf/column/column_view.hpp>
#include <cudf/detail/get_value.cuh>
#include <cudf/detail/interop.hpp>
#include <cudf/detail/nvtx/ranges.hpp>
#include <cudf/interop.hpp>
#include <cudf/null_mask.hpp>
#include <cudf/table/table_view.hpp>
#include <cudf/types.hpp>
#include <cudf/utilities/traits.hpp>
#include <cudf/utilities/type_dispatcher.hpp>

namespace cudf {
namespace detail {
namespace {
template <typename T>
std::shared_ptr<arrow::Buffer> fetch_data_buffer(column_view input_view, arrow::MemoryPool* ar_mr)
{
  const int64_t data_size_in_bytes = sizeof(T) * input_view.size();
  std::shared_ptr<arrow::Buffer> data_buffer;

  CUDF_EXPECTS(arrow::AllocateBuffer(ar_mr, data_size_in_bytes, &data_buffer).ok(),
               "Failed to allocate Arrow buffer for data");
  CUDA_TRY(cudaMemcpy(
    data_buffer->mutable_data(), input_view.data<T>(), data_size_in_bytes, cudaMemcpyDeviceToHost));

  return data_buffer;
}

std::shared_ptr<arrow::Buffer> fetch_mask_buffer(column_view input_view, arrow::MemoryPool* ar_mr)
{
  const int64_t mask_size_in_bytes = cudf::bitmask_allocation_size_bytes(input_view.size());
  std::shared_ptr<arrow::Buffer> mask_buffer;

  if (input_view.has_nulls()) {
    CUDF_EXPECTS(
      arrow::AllocateBitmap(ar_mr, static_cast<int64_t>(input_view.size()), &mask_buffer).ok(),
      "Failed to allocate Arrow buffer for mask");
    CUDA_TRY(cudaMemcpy(
      mask_buffer->mutable_data(),
      (input_view.offset() > 0) ? cudf::copy_bitmask(input_view).data() : input_view.null_mask(),
      mask_size_in_bytes,
      cudaMemcpyDeviceToHost));

    // Resets all padded bits to 0
    mask_buffer->ZeroPadding();

    return mask_buffer;
  }

  return nullptr;
}

struct dispatch_to_arrow {
  std::vector<std::shared_ptr<arrow::Array>> fetch_child_array(column_view input_view,
                                                               arrow::MemoryPool* ar_mr)
  {
    std::vector<std::shared_ptr<arrow::Array>> child_arrays;
    std::vector<size_type> child_indices(input_view.num_children());
    std::iota(child_indices.begin(), child_indices.end(), 0);
    std::transform(child_indices.begin(),
                   child_indices.end(),
                   std::back_inserter(child_arrays),
                   [&input_view, &ar_mr](auto const& i) {
                     auto c = input_view.child(i);
                     return type_dispatcher(c.type(), dispatch_to_arrow{}, c, c.type().id(), ar_mr);
                   });
    return child_arrays;
  }

  template <typename T>
  std::enable_if_t<is_fixed_width<T>(), std::shared_ptr<arrow::Array>> operator()(
    column_view input_view, cudf::type_id id, arrow::MemoryPool* ar_mr)
  {
    auto data_buffer = fetch_data_buffer<T>(input_view, ar_mr);
    auto mask_buffer = fetch_mask_buffer(input_view, ar_mr);

    return to_arrow_array(id,
                          static_cast<int64_t>(input_view.size()),
                          data_buffer,
                          mask_buffer,
                          static_cast<int64_t>(input_view.null_count()));
  }

  template <typename T>
  std::enable_if_t<std::is_same<T, cudf::string_view>::value, std::shared_ptr<arrow::Array>>
  operator()(column_view input, cudf::type_id id, arrow::MemoryPool* ar_mr)
  {
    std::unique_ptr<column> tmp_column = nullptr;
    if ((input.offset() != 0) or (input.child(0).size() - 1 != input.size())) {
      tmp_column = std::make_unique<cudf::column>(input);
    }

    column_view input_view = (tmp_column != nullptr) ? tmp_column->view() : input;
    auto child_arrays      = fetch_child_array(input_view, ar_mr);
    if (child_arrays.size() == 0) {
      return std::make_shared<arrow::StringArray>(0, nullptr, nullptr);
    }
    auto offset_buffer = child_arrays[0]->data()->buffers[1];
    auto data_buffer   = child_arrays[1]->data()->buffers[1];
    return std::make_shared<arrow::StringArray>(static_cast<int64_t>(input_view.size()),
                                                offset_buffer,
                                                data_buffer,
                                                fetch_mask_buffer(input_view, ar_mr),
                                                static_cast<int64_t>(input_view.null_count()));
  }

  template <typename T>
  std::enable_if_t<std::is_same<T, cudf::dictionary32>::value, std::shared_ptr<arrow::Array>>
  operator()(column_view input, cudf::type_id id, arrow::MemoryPool* ar_mr)
  {
    std::unique_ptr<column> tmp_column = nullptr;
    if ((input.offset() != 0) or (input.child(0).size() != input.size())) {
      tmp_column = std::make_unique<cudf::column>(input);
    }

    column_view input_view = (tmp_column != nullptr) ? tmp_column->view() : input;
    auto child_arrays      = fetch_child_array(input_view, ar_mr);
    if (child_arrays.size() == 0) {
      return std::make_shared<arrow::StringArray>(0, nullptr, nullptr);
    }

    auto indices    = to_arrow_array(type_id::INT32,
                                  static_cast<int64_t>(input_view.size()),
                                  child_arrays[0]->data()->buffers[1],
                                  fetch_mask_buffer(input_view, ar_mr),
                                  static_cast<int64_t>(input_view.null_count()));
    auto dictionary = child_arrays[1];
    return std::make_shared<arrow::DictionaryArray>(
      arrow::dictionary(indices->type(), dictionary->type()), indices, dictionary);
  }

  template <typename T>
  std::enable_if_t<std::is_same<T, cudf::list_view>::value, std::shared_ptr<arrow::Array>>
  operator()(column_view input, cudf::type_id id, arrow::MemoryPool* ar_mr)
  {
    std::unique_ptr<column> tmp_column = nullptr;
    if ((input.offset() != 0) or (input.child(0).size() - 1 != input.size())) {
      tmp_column = std::make_unique<cudf::column>(input);
    }

    column_view input_view = (tmp_column != nullptr) ? tmp_column->view() : input;
    auto child_arrays      = fetch_child_array(input_view, ar_mr);
    if (child_arrays.size() == 0) {
      return std::make_shared<arrow::StringArray>(0, nullptr, nullptr);
    }
    auto offset_buffer = child_arrays[0]->data()->buffers[1];
    auto data          = child_arrays[1];
    return std::make_shared<arrow::ListArray>(arrow::list(data->type()),
                                              static_cast<int64_t>(input_view.size()),
                                              offset_buffer,
                                              data,
                                              fetch_mask_buffer(input_view, ar_mr),
                                              static_cast<int64_t>(input_view.null_count()));
  }

  template <typename T>
  std::enable_if_t<(!is_fixed_width<T>()) and (!is_compound<T>()), std::shared_ptr<arrow::Array>>
  operator()(column_view input_view, cudf::type_id id, arrow::MemoryPool* ar_mr)
  {
    CUDF_FAIL("Only fixed width and compund types are supported");
  }
};

}  // namespace
}  // namespace detail

std::shared_ptr<arrow::Table> cudf_to_arrow(table_view input,
                                            std::vector<std::string> const& column_names,
                                            arrow::MemoryPool* ar_mr)
{
  CUDF_FUNC_RANGE();

  CUDF_EXPECTS((column_names.size() == input.num_columns()),
               "column names should be empty or should be equal to number of columns in table");

  std::vector<std::shared_ptr<arrow::Array>> arrays;
  std::vector<std::shared_ptr<arrow::Field>> fields;
  std::shared_ptr<arrow::Schema> schema;
  bool const has_names = not column_names.empty();

  std::transform(input.begin(), input.end(), std::back_inserter(arrays), [&](auto const& c) {
    return type_dispatcher(c.type(), detail::dispatch_to_arrow{}, c, c.type().id(), ar_mr);
  });

  std::transform(
    arrays.begin(),
    arrays.end(),
    column_names.begin(),
    std::back_inserter(fields),
    [](auto const& array, auto const& name) { return arrow::field(name, array->type()); });

  schema = arrow::schema(fields);

  return arrow::Table::Make(schema, arrays);
}

}  // namespace cudf
