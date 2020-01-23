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

#include <cmath>
#include <limits>
#include <functional>
#include <boost/serialization/strong_typedef.hpp>

namespace cudf {
namespace fp {

BOOST_STRONG_TYPEDEF(int32_t, scale_type)

enum Radix : int32_t {
    BASE_2  = 2,
    BASE_10 = 10
};

template <typename Rep, Radix Rad>
class fixed_point;

namespace detail {
    // helper function to negate strongly typed scale_type
    auto negate(scale_type const& scale) -> scale_type{
        return scale_type{-1 * scale};
    }

    // perform this operation when constructing with - scale (after negating scale)
    template <Radix Rad, typename T>
    constexpr auto right_shift(T const& val, scale_type const& scale) {
        return val / std::pow(static_cast<int32_t>(Rad), static_cast<int32_t>(scale));
    }

    // perform this operation when constructing with + scale
    template <Radix Rad, typename T>
    constexpr auto left_shift(T const& val, scale_type const& scale) {
        return val * std::pow(static_cast<int32_t>(Rad), static_cast<int32_t>(scale));
    }

    // convenience generic shift function
    template <Radix Rad, typename T>
    constexpr auto shift(T const& val, scale_type const& scale) {
        return scale >= 0 ? right_shift<Rad>(val, scale)
                          : left_shift <Rad>(val, negate(scale));
    }

    // forward declare
    template <typename Rep1, Radix Rad1,
              typename Rep2, Radix Rad2, typename Binop>
    fixed_point<Rep1, Rad1> max_exponent_binop(fixed_point<Rep1, Rad1> const& lhs,
                                               fixed_point<Rep2, Rad2> const& rhs,
                                               Binop binop);
}

// helper struct for constructing fixed_point when value is already shifted
template <typename Rep>
struct scaled_integer{
    Rep value;
    scale_type scale;
    explicit scaled_integer(Rep v, scale_type s) : value(v), scale(s) {}
};


// Rep = representative type
template <typename Rep, Radix Rad>
class fixed_point {

    scale_type _scale;
    Rep        _value;

public:

    // CONSTRUCTORS
    template <typename T = Rep,
              typename std::enable_if_t<(std::numeric_limits<T>::is_integer
                                      || std::is_floating_point<T>::value)>* = nullptr>
    explicit fixed_point(T const& value, scale_type const& scale) :
        _value(detail::shift<Rad>(value, scale)),
        _scale(scale)
    {
    }

    explicit fixed_point(scaled_integer<Rep> s) :
        _value(s.value),
        _scale(s.scale)
    {
    }

    // EXPLICIT CONVERSION OPERATOR
    template <typename U,
              typename std::enable_if_t<(std::numeric_limits<U>::is_integer
                                      || std::is_floating_point<U>::value)>* = nullptr>
    explicit constexpr operator U() const {
        return detail::shift<Rad>(static_cast<U>(_value), detail::negate(_scale));
    }

    auto get() const noexcept {
        auto const underlying_scale     = static_cast<int32_t>(_scale);
        int  const rounded_val          = _value / std::pow(static_cast<int32_t>(Rad), underlying_scale);
        bool const needs_floating_point = rounded_val * Rad * underlying_scale != _value;
        return needs_floating_point ? static_cast<double>(*this) : static_cast<Rep>(*this);
    }

    template <typename Rep2, Radix Rad2>
    fixed_point<Rep2, Rad2>& operator+=(fixed_point<Rep2, Rad2> const& rhs) {
        *this = *this + rhs;
        return *this;
    }

    template <typename Rep2, Radix Rad2>
    fixed_point<Rep2, Rad2>& operator*=(fixed_point<Rep2, Rad2> const& rhs) {
        *this = *this * rhs;
        return *this;
    }

    template <typename Rep2, Radix Rad2>
    fixed_point<Rep2, Rad2>& operator-=(fixed_point<Rep2, Rad2> const& rhs) {
        *this = *this - rhs;
        return *this;
    }

    template <typename Rep2, Radix Rad2>
    fixed_point<Rep2, Rad2>& operator/=(fixed_point<Rep2, Rad2> const& rhs) {
        *this = *this / rhs;
        return *this;
    }

    // enable access to _value & _scale
    template <typename Rep1, Radix Rad1,
              typename Rep2, Radix Rad2, typename Binop>
    friend fixed_point<Rep1, Rad1> detail::max_exponent_binop(fixed_point<Rep1, Rad1> const& lhs,
                                                              fixed_point<Rep2, Rad2> const& rhs,
                                                              Binop binop);

    // enable access to _value & _scale
    template <typename Rep1, Radix Rad1,
              typename Rep2, Radix Rad2>
    friend fixed_point<Rep1, Rad1> operator*(fixed_point<Rep1, Rad1> const& lhs,
                                             fixed_point<Rep2, Rad2> const& rhs);

    // enable access to _value & _scale
    template <typename Rep1, Radix Rad1,
              typename Rep2, Radix Rad2>
    friend fixed_point<Rep1, Rad1> operator/(fixed_point<Rep1, Rad1> const& lhs,
                                             fixed_point<Rep2, Rad2> const& rhs);
};

namespace detail {
    // this function is for binary operations like + and - which when the exponent (scale)
    // differ for lhs and rhs, you take the max exponent of the two and shift the other
    // fixed_point in order to have the same exponent
    template<typename Rep1, Radix Rad1,
             typename Rep2, Radix Rad2, typename Binop>
    fixed_point<Rep1, Rad1> max_exponent_binop(fixed_point<Rep1, Rad1> const& lhs,
                                               fixed_point<Rep2, Rad2> const& rhs,
                                               Binop binop) {

        static_assert(std::is_same<Rep1, Rep2>::value, "Represenation types should be the same");
        static_assert(Rad1 == Rad2,                "Radix types should be the same");

        // if exponents (aka scales) are different
        if (lhs._scale > rhs._scale) {
            auto const rhs_shifted_value = detail::shift<Rad1>(rhs._value, lhs._scale - rhs._scale);
            return fixed_point<Rep1, Rad1>{scaled_integer<Rep1>(binop(lhs._value, rhs_shifted_value), lhs._scale)};
        } else if (rhs._scale > lhs._scale) {
            auto lhs_shifted_value = detail::shift<Rad1>(lhs._value, rhs._scale - lhs._scale);
            return fixed_point<Rep1, Rad1>{scaled_integer<Rep1>(binop(lhs_shifted_value, rhs._value), rhs._scale)};
        }

        // if exponents (aka scales) are the same
        return fixed_point<Rep1, Rad1>{scaled_integer<Rep1>(binop(lhs._value, rhs._value), lhs._scale)};
    }
}

// PLUS Operation
template<typename Rep1, Radix Rad1,
         typename Rep2, Radix Rad2>
fixed_point<Rep1, Rad1> operator+(fixed_point<Rep1, Rad1> const& lhs,
                                  fixed_point<Rep2, Rad2> const& rhs) {
    return detail::max_exponent_binop(lhs, rhs, std::plus<>());
}

// MINUS Operation
template<typename Rep1, Radix Rad1,
         typename Rep2, Radix Rad2>
fixed_point<Rep1, Rad1> operator-(fixed_point<Rep1, Rad1> const& lhs,
                                  fixed_point<Rep2, Rad2> const& rhs) {
    return detail::max_exponent_binop(lhs, rhs, std::minus<>());
}

// MULTIPLIES Operation
template<typename Rep1, Radix Rad1,
         typename Rep2, Radix Rad2>
fixed_point<Rep1, Rad1> operator*(fixed_point<Rep1, Rad1> const& lhs,
                                  fixed_point<Rep2, Rad2> const& rhs) {

    static_assert(std::is_same<Rep1, Rep2>::value, "Represenation types should be the same");
    static_assert(Rad1 == Rad2,                "Radix types should be the same");

    return fixed_point<Rep1, Rad1>{scaled_integer<Rep1>(lhs._value * rhs._value, lhs._scale + rhs._scale)};
}

// DIVISION Operation
template<typename Rep1, Radix Rad1,
         typename Rep2, Radix Rad2>
fixed_point<Rep1, Rad1> operator/(fixed_point<Rep1, Rad1> const& lhs,
                                  fixed_point<Rep2, Rad2> const& rhs) {

    static_assert(std::is_same<Rep1, Rep2>::value, "Represenation types should be the same");
    static_assert(Rad1 == Rad2,                "Radix types should be the same");

    return fixed_point<Rep1, Rad1>{scaled_integer<Rep1>(lhs._value / rhs._value, lhs._scale - rhs._scale)};
}

template <typename Rep, Radix Radix>
std::ostream& operator<<(std::ostream& os, fixed_point<Rep, Radix> const& si) {
    return os << si.get();
}

} // namespace fp
} // namespace cudf
