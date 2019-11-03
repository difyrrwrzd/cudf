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

#include "unary_ops.cuh"
#include <cudf/legacy/unary.hpp>
#include <cudf/legacy/copying.hpp>

#include <cudf/utilities/type_dispatcher.hpp>
#include <cudf/column/column_factories.hpp>
#include <cudf/copying.hpp>

#include <cmath>
#include <algorithm>
#include <type_traits>

namespace cudf {
namespace experimental {
namespace detail {

// trig functions

struct DeviceSin {
    template<typename T>
    __device__
    T operator()(T data) {
        return std::sin(data);
    }
};

struct DeviceCos {
    template<typename T>
    __device__
    T operator()(T data) {
        return std::cos(data);
    }
};

struct DeviceTan {
    template<typename T>
    __device__
    T operator()(T data) {
        return std::tan(data);
    }
};

struct DeviceArcSin {
    template<typename T>
    __device__
    T operator()(T data) {
        return std::asin(data);
    }
};

struct DeviceArcCos {
    template<typename T>
    __device__
    T operator()(T data) {
        return std::acos(data);
    }
};

struct DeviceArcTan {
    template<typename T>
    __device__
    T operator()(T data) {
        return std::atan(data);
    }
};

// exponential functions

struct DeviceExp {
    template<typename T>
    __device__
    T operator()(T data) {
        return std::exp(data);
    }
};

struct DeviceLog {
    template<typename T>
    __device__
    T operator()(T data) {
        return std::log(data);
    }
};

struct DeviceSqrt {
    template<typename T>
    __device__
    T operator()(T data) {
        return std::sqrt(data);
    }
};

// rounding functions

struct DeviceCeil {
    template<typename T>
    __device__
    T operator()(T data) {
        return std::ceil(data);
    }
};

struct DeviceFloor {
    template<typename T>
    __device__
    T operator()(T data) {
        return std::floor(data);
    }
};

struct DeviceAbs {
    template<typename T>
    __device__
    T operator()(T data) {
        return std::abs(data);
    }
};

// bitwise op

struct DeviceInvert {
    // TODO: maybe sfinae overload this for cudf::bool8
    template<typename T>
    __device__
    T operator()(T data) {
        return ~data;
    }
};

// logical op

struct DeviceNot {
    template<typename T>
    __device__
    cudf::bool8 operator()(T data) {
        return static_cast<cudf::bool8>( !data );
    }
};


template<typename T, typename F>
static void launch(cudf::column_view const& input, cudf::mutable_column_view& output) {
    cudf::experimental::unary::Launcher<T, T, F>::launch(input, output);
}


template <typename F>
struct MathOpDispatcher {
    template <typename T>
    typename std::enable_if_t<std::is_arithmetic<T>::value, void>
    operator()(cudf::column_view const& input, cudf::mutable_column_view& output) {
        launch<T, F>(input, output);
    }

    template <typename T>
    typename std::enable_if_t<!std::is_arithmetic<T>::value, void>
    operator()(cudf::column_view const& input, cudf::mutable_column_view& output) {
        CUDF_FAIL("Unsupported datatype for operation");
    }
};


template <typename F>
struct BitwiseOpDispatcher {
    template <typename T>
    typename std::enable_if_t<std::is_integral<T>::value, void>
    operator()(cudf::column_view const& input, cudf::mutable_column_view& output) {
        launch<T, F>(input, output);
    }

    template <typename T>
    typename std::enable_if_t<!std::is_integral<T>::value, void>
    operator()(cudf::column_view const& input, cudf::mutable_column_view& output) {
        CUDF_FAIL("Unsupported datatype for operation");
    }
};


template <typename F>
struct LogicalOpDispatcher {
private:
    template <typename T>
    static constexpr bool is_supported() {
        return std::is_arithmetic<T>::value ||
               std::is_same<T, cudf::bool8>::value;

        // TODO: try using member detector
        // std::is_member_function_pointer<decltype(&T::operator!)>::value;
    }

public:
    template <typename T>
    typename std::enable_if_t<is_supported<T>(), void>
    operator()(cudf::column_view const& input, cudf::mutable_column_view& output) {
        cudf::experimental::unary::Launcher<T, cudf::bool8, F>::launch(input, output);
    }

    template <typename T>
    typename std::enable_if_t<!is_supported<T>(), void>
    operator()(cudf::column_view const& input, cudf::mutable_column_view& output) {
        CUDF_FAIL("Unsupported datatype for operation");
    }
};

} // namespace detail

std::unique_ptr<cudf::column> 
unary_operation(cudf::column_view const& input, 
                cudf::unary_op op, 
                cudaStream_t stream = 0, 
                rmm::mr::device_memory_resource* mr = 
                rmm::mr::get_default_resource()) {

    std::unique_ptr<cudf::column> output = [&] {
        if (op == cudf::unary_op::NOT) {
            auto mask_state = input.null_mask() ? cudf::UNINITIALIZED
                                                : cudf::UNALLOCATED;

            return cudf::make_numeric_column(cudf::data_type(cudf::BOOL8), 
                                             input.size(), 
                                             mask_state,
                                             stream, 
                                             mr);
        } else {
            return cudf::experimental::allocate_like(input);
        }
    } ();

    if (input.size() == 0) return output;

    auto output_view = output->mutable_view();;

    cudf::experimental::unary::handleChecksAndValidity(input, output_view);

    switch(op){
        case unary_op::SIN:
            cudf::experimental::type_dispatcher(
                input.type(),
                detail::MathOpDispatcher<detail::DeviceSin>{},
                input, output_view);
            break;
        case unary_op::COS:
            cudf::experimental::type_dispatcher(
                input.type(),
                detail::MathOpDispatcher<detail::DeviceCos>{},
                input, output_view);
            break;
        case unary_op::TAN:
            cudf::experimental::type_dispatcher(
                input.type(),
                detail::MathOpDispatcher<detail::DeviceTan>{},
                input, output_view);
            break;
        case unary_op::ARCSIN:
            cudf::experimental::type_dispatcher(
                input.type(),
                detail::MathOpDispatcher<detail::DeviceArcSin>{},
                input, output_view);
            break;
        case unary_op::ARCCOS:
            cudf::experimental::type_dispatcher(
                input.type(),
                detail::MathOpDispatcher<detail::DeviceArcCos>{},
                input, output_view);
            break;
        case unary_op::ARCTAN:
            cudf::experimental::type_dispatcher(
                input.type(),
                detail::MathOpDispatcher<detail::DeviceArcTan>{},
                input, output_view);
            break;
        case unary_op::EXP:
            cudf::experimental::type_dispatcher(
                input.type(),
                detail::MathOpDispatcher<detail::DeviceExp>{},
                input, output_view);
            break;
        case unary_op::LOG:
            cudf::experimental::type_dispatcher(
                input.type(),
                detail::MathOpDispatcher<detail::DeviceLog>{},
                input, output_view);
            break;
        case unary_op::SQRT:
            cudf::experimental::type_dispatcher(
                input.type(),
                detail::MathOpDispatcher<detail::DeviceSqrt>{},
                input, output_view);
            break;
        case unary_op::CEIL:
            cudf::experimental::type_dispatcher(
                input.type(),
                detail::MathOpDispatcher<detail::DeviceCeil>{},
                input, output_view);
            break;
        case unary_op::FLOOR:
            cudf::experimental::type_dispatcher(
                input.type(),
                detail::MathOpDispatcher<detail::DeviceFloor>{},
                input, output_view);
            break;
        case unary_op::ABS:
            cudf::experimental::type_dispatcher(
                input.type(),
                detail::MathOpDispatcher<detail::DeviceAbs>{},
                input, output_view);
            break;
        case unary_op::BIT_INVERT:
            cudf::experimental::type_dispatcher(
                input.type(),
                detail::BitwiseOpDispatcher<detail::DeviceInvert>{},
                input, output_view);
            break;
        case unary_op::NOT:
            cudf::experimental::type_dispatcher(
                input.type(),
                detail::LogicalOpDispatcher<detail::DeviceNot>{},
                input, output_view);
            break;
        default:
            CUDF_FAIL("Undefined unary operation");
    }
    return output;
}

} // namespace experimental
} // namespace cudf
