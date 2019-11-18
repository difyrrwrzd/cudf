#include <cudf/column/column_view.hpp>
#include <cudf/column/column_factories.hpp>
#include <cudf/column/column_device_view.cuh>
#include <cudf/detail/iterator.cuh>

#include <rmm/rmm.h>
#include <cudf/utilities/error.hpp>
#include <cudf/null_mask.hpp>
#include <cudf/utilities/type_dispatcher.hpp>

#include <utilities/device_atomics.cuh>
#include <cub/device/device_scan.cuh>
#include <cudf/reduction.hpp>


namespace cudf {
namespace experimental {

namespace detail {

template <typename T, typename Op>
struct Scan {
    static
    void call(const column_view input, mutable_column_view output,
                  bool inclusive, cudaStream_t stream,
                  rmm::mr::device_memory_resource* mr)
    {
        size_t size = input.size();

        // Prepare temp storage
        void *temp_storage = NULL;
        size_t temp_storage_bytes = 0;

        if (input.has_nulls()) {
          auto d_input = column_device_view::create(input, stream);
          auto it = make_null_replacement_iterator(*d_input, Op::template identity<T>());
          auto scan_function = (inclusive ? inclusive_scan<decltype(it)> : exclusive_scan<decltype(it)>);
          scan_function(temp_storage, temp_storage_bytes,
              it, output.data<T>(), size, stream);
          rmm::device_buffer buff(temp_storage_bytes, stream, mr);
          temp_storage = buff.data(); 

          scan_function(temp_storage, temp_storage_bytes,
              it, output.data<T>(), size, stream);
        } else {
          auto it = input.data<T>();  //since scan is for arithmetic types only
          auto scan_function = (inclusive ? inclusive_scan<decltype(it)> : exclusive_scan<decltype(it)>);
          scan_function(temp_storage, temp_storage_bytes,
              it, output.data<T>(), size, stream);
          rmm::device_buffer buff(temp_storage_bytes, stream, mr);
          temp_storage = buff.data(); 

          scan_function(temp_storage, temp_storage_bytes,
              it, output.data<T>(), size, stream);
        }
    }

    template <typename InputIterator>
    static void exclusive_scan(void *&temp_storage, size_t &temp_storage_bytes,
        const InputIterator input, T* output, size_t size, cudaStream_t stream)
    {
        //TODO benchmark between thrust and cub reduce and scan
        cub::DeviceScan::ExclusiveScan(temp_storage, temp_storage_bytes,
            input, output, Op{}, Op::template identity<T>(), size, stream);
        CUDA_CHECK_LAST();
    }

    template <typename InputIterator>
    static void inclusive_scan(void *&temp_storage, size_t &temp_storage_bytes,
        const InputIterator input, T* output, size_t size, cudaStream_t stream)
    {
      cub::DeviceScan::InclusiveScan(temp_storage, temp_storage_bytes, input,
                                     output, Op{}, size, stream);
      CUDA_CHECK_LAST();
    }
};

template <typename Op>
struct PrefixSumDispatcher {
  private:
  // return true if T is arithmetic type (including cudf::experimental::bool8)
  template <typename T>
  static constexpr bool is_supported() {
    return std::is_arithmetic<T>::value;
  }

  public:
  template <typename T,
            typename std::enable_if_t<is_supported<T>(), T> * = nullptr>
  void operator()(const column_view& input, mutable_column_view& output,
                  bool inclusive, cudaStream_t stream,
                  rmm::mr::device_memory_resource* mr)
  {
    CUDF_EXPECTS(input.size() == output.size(),
                 "input and output data size must be same");
    CUDF_EXPECTS(input.type() == output.type(),
                 "input and output data types must be same");

    CUDF_EXPECTS(input.nullable() == output.nullable(),
                 "Input column and Output column nullable mismatch (either one "
                 "cannot be nullable)");

    Scan<T, Op>::call(input, output, inclusive, stream, mr);
    CUDF_EXPECTS(input.null_count() == output.null_count(),
                 "Input / output column null count mismatch");
  }

  template <typename T,
            typename std::enable_if_t<!is_supported<T>(), T> * = nullptr>
  void operator()(const column_view& input, mutable_column_view& output,
                  bool inclusive, cudaStream_t stream,
                  rmm::mr::device_memory_resource* mr) {
    CUDF_FAIL("Non-arithmetic types not supported for `cudf::scan`");
  }
};

std::unique_ptr<column> scan(const column_view& input,
                             scan_operators op, bool inclusive,
                             cudaStream_t stream=0,
                             rmm::mr::device_memory_resource* mr = rmm::mr::get_default_resource())
{
  CUDF_EXPECTS(is_numeric(input.type()), "Unexpected non-numeric type.");

  std::unique_ptr<column> output_column = make_numeric_column(
      input.type(), input.size(), 
      copy_bitmask(input, stream, mr), //copy bit mask
      input.null_count(), stream, mr);

  mutable_column_view output = output_column->mutable_view();

  switch (op) {
    case scan_operators::SCAN_SUM:
        cudf::experimental::type_dispatcher(input.type(),
            PrefixSumDispatcher<cudf::DeviceSum>(), input, output, inclusive, stream, mr);
        break;
    case scan_operators::SCAN_MIN:
        cudf::experimental::type_dispatcher(input.type(),
            PrefixSumDispatcher<cudf::DeviceMin>(), input, output, inclusive, stream, mr);
        break;
    case scan_operators::SCAN_MAX:
        cudf::experimental::type_dispatcher(input.type(),
            PrefixSumDispatcher<cudf::DeviceMax>(), input, output, inclusive, stream, mr);
        break;
    case scan_operators::SCAN_PRODUCT:
        cudf::experimental::type_dispatcher(input.type(),
            PrefixSumDispatcher<cudf::DeviceProduct>(), input, output, inclusive, stream, mr);
        break;
    default:
        CUDF_FAIL("The input enum `scan::operators` is out of the range");
    }
  return output_column;
}
} // namespace detail

std::unique_ptr<column> scan(const column_view& input,
                             scan_operators op, bool inclusive,
                             rmm::mr::device_memory_resource* mr)
{
  return detail::scan(input, op, inclusive, 0, mr);
}

}  // namespace experimental
}  // namespace cudf
