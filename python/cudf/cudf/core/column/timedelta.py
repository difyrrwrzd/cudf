# Copyright (c) 2020, NVIDIA CORPORATION.
import datetime as dt
from numbers import Number

import numpy as np
import pandas as pd
import pyarrow as pa

import cudf
from cudf import _lib as libcudf
from cudf._lib.nvtx import annotate
from cudf._lib.scalar import Scalar, as_scalar
from cudf.core.column import column, string
from cudf.core.column.datetime import _numpy_to_pandas_conversion
from cudf.utils.dtypes import is_scalar, np_to_pa_dtype
from cudf.utils.utils import buffers_from_pyarrow

_dtype_to_format_conversion = {
    "timedelta64[ns]": "%D days %H:%M:%S",
    "timedelta64[us]": "%D days %H:%M:%S",
    "timedelta64[ms]": "%D days %H:%M:%S",
    "timedelta64[s]": "%D days %H:%M:%S",
}


class TimeDeltaColumn(column.ColumnBase):
    def __init__(
        self, data, dtype, size, mask=None, offset=0, null_count=None
    ):
        """
        Parameters
        ----------
        data : Buffer
            The Timedelta values
        dtype : np.dtype
            The data type
        size : int
            Size of memory allocation.
        mask : Buffer; optional
            The validity mask
        offset : int
            Data offset
        null_count : int, optional
            The number of null values.
            If None, it is calculated automatically.
        """
        dtype = np.dtype(dtype)
        if data.size % dtype.itemsize:
            raise ValueError("Buffer size must be divisible by element size")

        super().__init__(
            data,
            size=size,
            dtype=dtype,
            mask=mask,
            offset=offset,
            null_count=null_count,
        )

        if not (self.dtype.type is np.timedelta64):
            raise TypeError(f"{self.dtype} is not a supported duration type")

        self._time_unit, _ = np.datetime_data(self.dtype)

    def __contains__(self, item):
        try:
            item = np.timedelta64(item, self._time_unit)
        except ValueError:
            # If item cannot be converted to duration type
            # np.timedelta64 raises ValueError, hence `item`
            # cannot exist in `self`.
            return False
        return item.view("int64") in self.as_numerical

    def _repr_str_col(self):
        # NOTE: This is for __repr__ purposes only.
        # Typecasting to "str" yields different output
        # when compared to __repr__ output of a duration type
        # A Typecast to "str" preserves "Days" field even if
        # the number of days in all rows are <= 0, whereas
        # in __repr__ output the number of "Days" are truncated
        # from the output if the number of days in all the rows
        # are <= 0, hence this is an interal API which truncates "Days"
        # from the output repr to both match pandas and have
        # cleaner output.

        if not (
            self.binary_operator(op="gt", rhs=np.timedelta64(1, "D"))
        ).any():
            format = "%H:%M:%S"
        else:
            format = None

        result = self.as_string_column(dtype="str", format=format)
        if self.has_nulls:
            result = result.fillna(cudf._NA_REP)
        return result

    def to_pandas(self, index=None, nullable_pd_dtype=False):
        if nullable_pd_dtype:
            raise NotImplementedError(
                f"nullable_pd_dtype=True is not supported for {self.dtype}"
            )

        return pd.Series(
            self.to_array(fillna="pandas").astype(self.dtype), index=index
        )

    def to_arrow(self):
        mask = None
        if self.nullable:
            mask = pa.py_buffer(self.mask_array_view.copy_to_host())
        data = pa.py_buffer(self.as_numerical.data_array_view.copy_to_host())
        pa_dtype = np_to_pa_dtype(self.dtype)
        return pa.Array.from_buffers(
            type=pa_dtype,
            length=len(self),
            buffers=[mask, data],
            null_count=self.null_count,
        )

    def _binary_op_floordiv(self, rhs):
        lhs, rhs = self, rhs
        if pd.api.types.is_timedelta64_dtype(rhs.dtype):
            common_dtype = determine_out_dtype(self.dtype, rhs.dtype)
            lhs = lhs.astype(common_dtype).astype("float64")

            if isinstance(rhs, Scalar):
                if rhs.is_valid():
                    if isinstance(rhs, Scalar):
                        rhs = np.timedelta64(rhs.value)

                    rhs = rhs.astype(common_dtype).astype("float64")
                else:
                    rhs = as_scalar(None, "float64")
            else:
                rhs = rhs.astype(common_dtype).astype("float64")

            out_dtype = np.dtype("int64")
        elif rhs.dtype.kind in ("f", "i", "u"):
            out_dtype = self.dtype
        else:
            raise TypeError(
                f"Floor Division of {self.dtype} with {rhs.dtype} "
                f"cannot be performed."
            )

        return lhs, rhs, out_dtype

    def _binary_op_mul(self, rhs):
        if rhs.dtype.kind in ("f", "i", "u"):
            out_dtype = self.dtype
        else:
            raise TypeError(
                f"Multiplication of {self.dtype} with {rhs.dtype} "
                f"cannot be performed."
            )
        return out_dtype

    def _binary_op_mod(self, rhs):
        if pd.api.types.is_timedelta64_dtype(rhs.dtype):
            out_dtype = determine_out_dtype(self.dtype, rhs.dtype)
        elif rhs.dtype.kind in ("f", "i", "u"):
            out_dtype = self.dtype
        else:
            raise TypeError(
                f"Modulus of {self.dtype} with {rhs.dtype} "
                f"cannot be performed."
            )
        return out_dtype

    def _binary_op_eq_ne(self, rhs):
        if pd.api.types.is_timedelta64_dtype(rhs.dtype):
            out_dtype = np.bool
        else:
            raise TypeError(
                f"Equality of {self.dtype} with {rhs.dtype} "
                f"cannot be performed."
            )
        return out_dtype

    def _binary_op_lt_gt_le_ge(self, rhs):
        if pd.api.types.is_timedelta64_dtype(rhs.dtype):
            return np.bool
        else:
            raise TypeError(
                f"Invalid comparison between dtype={self.dtype}"
                f" and {rhs.dtype}"
            )

    def _binary_op_truediv(self, rhs):
        lhs, rhs = self, rhs
        if pd.api.types.is_timedelta64_dtype(rhs.dtype):
            common_dtype = determine_out_dtype(self.dtype, rhs.dtype)
            lhs = lhs.astype(common_dtype).astype("float64")

            if isinstance(rhs, Scalar):
                if rhs.is_valid():
                    if isinstance(rhs, Scalar):
                        rhs = np.timedelta64(rhs.value)

                    rhs = rhs.astype(common_dtype).astype("float64")
                else:
                    rhs = as_scalar(None, "float64")
            else:
                rhs = rhs.astype(common_dtype).astype("float64")

            out_dtype = np.dtype("float64")
        elif rhs.dtype.kind in ("f", "i", "u"):
            out_dtype = self.dtype
        else:
            raise TypeError(
                f"Division of {self.dtype} with {rhs.dtype} "
                f"cannot be performed."
            )

        return lhs, rhs, out_dtype

    def binary_operator(self, op, rhs, reflect=False):
        lhs, rhs = self, rhs

        if op in ("eq", "ne"):
            out_dtype = self._binary_op_eq_ne(rhs)
        elif op in ("lt", "gt", "le", "ge"):
            out_dtype = self._binary_op_lt_gt_le_ge(rhs)
        elif op == "mul":
            out_dtype = self._binary_op_mul(rhs)
        elif op == "mod":
            out_dtype = self._binary_op_mod(rhs)
        elif op == "truediv":
            lhs, rhs, out_dtype = self._binary_op_truediv(rhs)
        elif op == "floordiv":
            lhs, rhs, out_dtype = self._binary_op_floordiv(rhs)
            op = "truediv"
        elif op == "add":
            out_dtype = _timedelta_binary_op_add(lhs, rhs)
        elif op == "sub":
            out_dtype = _timedelta_binary_op_sub(lhs, rhs)
        else:
            raise TypeError(
                f"Series of dtype {self.dtype} cannot perform "
                f"the operation {op}"
            )

        if reflect:
            lhs, rhs = rhs, lhs

        return binop(lhs, rhs, op=op, out_dtype=out_dtype)

    def normalize_binop_value(self, other):
        if isinstance(other, dt.timedelta):
            other = np.timedelta64(other)
        elif isinstance(other, pd.Timestamp):
            other = other.to_datetime64()
        elif isinstance(other, pd.Timedelta):
            other = other.to_timedelta64()

        if isinstance(other, np.timedelta64):
            other_time_unit = cudf.utils.dtypes.get_time_unit(other)
            if np.isnat(other):
                return as_scalar(val=None, dtype=self.dtype)

            if other_time_unit not in ("s", "ms", "ns", "us"):
                other = other.astype("timedelta64[s]")
            else:
                common_dtype = determine_out_dtype(self.dtype, other.dtype)
                other = other.astype(common_dtype)
            return as_scalar(other)
        elif np.isscalar(other):
            return as_scalar(other)
        else:
            raise TypeError("cannot normalize {}".format(type(other)))

    @property
    def as_numerical(self):

        return column.build_column(
            data=self.base_data,
            dtype=np.int64,
            mask=self.base_mask,
            offset=self.offset,
            size=self.size,
        )

    @classmethod
    def from_arrow(cls, array, dtype=None):
        if dtype is None:
            dtype = np.dtype("m8[{}]".format(array.type.unit))

        pa_size, pa_offset, pamask, padata, _ = buffers_from_pyarrow(array)

        return TimeDeltaColumn(
            data=padata,
            mask=pamask,
            dtype=dtype,
            size=pa_size,
            offset=pa_offset,
        )

    def default_na_value(self):
        """Returns the default NA value for this column
        """
        return np.timedelta64("nat", self.time_unit)

    @property
    def time_unit(self):
        return self._time_unit

    def fillna(self, fill_value):
        col = self
        if is_scalar(fill_value):
            if isinstance(fill_value, np.timedelta64):
                dtype = determine_out_dtype(self.dtype, fill_value.dtype)
                fill_value = fill_value.astype(dtype)
                col = col.astype(dtype)
            elif not isinstance(fill_value, Scalar):
                fill_value = np.timedelta64(fill_value)
        else:
            fill_value = column.as_column(fill_value, nan_as_null=False)

        result = libcudf.replace.replace_nulls(col, fill_value)

        return result

    def as_numerical_column(self, dtype, **kwargs):
        return self.as_numerical.astype(dtype)

    def as_datetime_column(self, dtype, **kwargs):
        raise TypeError(
            f"cannot astype a timedelta from [{self.dtype}] to [{dtype}]"
        )

    def as_string_column(self, dtype, **kwargs):

        if not kwargs.get("format"):
            fmt = _dtype_to_format_conversion.get(
                self.dtype.name, "%D days %H:%M:%S"
            )
            kwargs["format"] = fmt
        if len(self) > 0:
            return string._numeric_to_str_typecast_functions[
                np.dtype(self.dtype)
            ](self, **kwargs)
        else:
            return column.column_empty(0, dtype="object", masked=False)

    def as_timedelta_column(self, dtype, **kwargs):
        dtype = np.dtype(dtype)
        if dtype == self.dtype:
            return self
        return libcudf.unary.cast(self, dtype=dtype)

    def mean(self, dtype=np.float64):
        return pd.Timedelta(
            self.as_numerical.mean(dtype=dtype), unit=self.time_unit
        )

    def median(self, dtype=np.float64):
        return pd.Timedelta(
            self.as_numerical.median(dtype=dtype), unit=self.time_unit
        )

    def quantile(self, q, interpolation, exact):
        result = self.as_numerical.quantile(
            q=q, interpolation=interpolation, exact=exact
        )
        if isinstance(q, Number):
            return [pd.Timedelta(result[0], unit=self.time_unit)]
        return result.astype(self.dtype)

    def sum(self, dtype=None):
        if len(self) == 0:
            return pd.Timedelta(None, unit=self.time_unit)
        else:
            return pd.Timedelta(
                self.as_numerical.sum(dtype=dtype), unit=self.time_unit
            )

    def components(self, index=None):
        """
        Return a Dataframe of the components of the Timedeltas.

        Returns
        -------
        DataFrame

        Examples
        --------
        >>> s = pd.Series(pd.to_timedelta(np.arange(5), unit='s'))
        >>> s = cudf.Series([12231312123, 1231231231, 1123236768712, 2135656,
        ...     3244334234], dtype='timedelta64[ms]')
        >>> s
        0      141 days 13:35:12.123
        1       14 days 06:00:31.231
        2    13000 days 10:12:48.712
        3        0 days 00:35:35.656
        4       37 days 13:12:14.234
        dtype: timedelta64[ms]
        >>> s.dt.components
            days  hours  minutes  seconds  milliseconds  microseconds  nanoseconds
        0    141     13       35       12           123             0            0
        1     14      6        0       31           231             0            0
        2  13000     10       12       48           712             0            0
        3      0      0       35       35           656             0            0
        4     37     13       12       14           234             0            0
        """  # noqa: E501

        return cudf.DataFrame(
            data={
                "days": self.binary_operator(
                    "floordiv",
                    as_scalar(
                        np.timedelta64(_numpy_to_pandas_conversion["D"], "ns")
                    ),
                ),
                "hours": self.binary_operator(
                    "mod",
                    as_scalar(
                        np.timedelta64(_numpy_to_pandas_conversion["D"], "ns")
                    ),
                ).binary_operator(
                    "floordiv",
                    as_scalar(
                        np.timedelta64(_numpy_to_pandas_conversion["h"], "ns")
                    ),
                ),
                "minutes": self.binary_operator(
                    "mod",
                    as_scalar(
                        np.timedelta64(_numpy_to_pandas_conversion["h"], "ns")
                    ),
                ).binary_operator(
                    "floordiv",
                    as_scalar(
                        np.timedelta64(_numpy_to_pandas_conversion["m"], "ns")
                    ),
                ),
                "seconds": self.binary_operator(
                    "mod",
                    as_scalar(
                        np.timedelta64(_numpy_to_pandas_conversion["m"], "ns")
                    ),
                ).binary_operator(
                    "floordiv",
                    as_scalar(
                        np.timedelta64(_numpy_to_pandas_conversion["s"], "ns")
                    ),
                ),
                "milliseconds": self.binary_operator(
                    "mod",
                    as_scalar(
                        np.timedelta64(_numpy_to_pandas_conversion["s"], "ns")
                    ),
                ).binary_operator(
                    "floordiv",
                    as_scalar(
                        np.timedelta64(_numpy_to_pandas_conversion["ms"], "ns")
                    ),
                ),
                "microseconds": self.binary_operator(
                    "mod",
                    as_scalar(
                        np.timedelta64(_numpy_to_pandas_conversion["ms"], "ns")
                    ),
                ).binary_operator(
                    "floordiv",
                    as_scalar(
                        np.timedelta64(_numpy_to_pandas_conversion["us"], "ns")
                    ),
                ),
                "nanoseconds": self.binary_operator(
                    "mod",
                    as_scalar(
                        np.timedelta64(_numpy_to_pandas_conversion["us"], "ns")
                    ),
                ).binary_operator(
                    "floordiv",
                    as_scalar(
                        np.timedelta64(_numpy_to_pandas_conversion["ns"], "ns")
                    ),
                ),
            },
            index=index,
        )

    @property
    def days(self):
        """
        Number of days for each element.

        Returns
        -------
        NumericalColumn
        """
        return self.binary_operator(
            "floordiv",
            as_scalar(np.timedelta64(_numpy_to_pandas_conversion["D"], "ns")),
        )

    @property
    def seconds(self):
        """
        Number of seconds (>= 0 and less than 1 day).

        Returns
        -------
        NumericalColumn
        """
        # This property must return the number of seconds (>= 0 and
        # less than 1 day) for each element, hence first performing
        # mod operation to remove the number of days and then performing
        # division operation to extract the number of seconds.

        return self.binary_operator(
            "mod",
            as_scalar(np.timedelta64(_numpy_to_pandas_conversion["D"], "ns")),
        ).binary_operator(
            "floordiv",
            as_scalar(np.timedelta64(_numpy_to_pandas_conversion["s"], "ns")),
        )

    @property
    def microseconds(self):
        """
        Number of microseconds (>= 0 and less than 1 second).

        Returns
        -------
        NumericalColumn
        """
        # This property must return the number of microseconds (>= 0 and
        # less than 1 second) for each element, hence first performing
        # mod operation to remove the number of seconds and then performing
        # division operation to extract the number of microseconds.

        return self.binary_operator(
            "mod", np.timedelta64(_numpy_to_pandas_conversion["s"], "ns")
        ).binary_operator(
            "floordiv",
            as_scalar(np.timedelta64(_numpy_to_pandas_conversion["us"], "ns")),
        )

    @property
    def nanoseconds(self):
        """
        Return the number of nanoseconds (n), where 0 <= n < 1 microsecond.

        Returns
        -------
        NumericalColumn
        """
        # This property must return the number of nanoseconds (>= 0 and
        # less than 1 microsecond) for each element, hence first performing
        # mod operation to remove the number of microseconds and then
        # performing division operation to extract the number
        # of nanoseconds.

        return self.binary_operator(
            "mod",
            as_scalar(np.timedelta64(_numpy_to_pandas_conversion["us"], "ns")),
        ).binary_operator(
            "floordiv",
            as_scalar(np.timedelta64(_numpy_to_pandas_conversion["ns"], "ns")),
        )


@annotate("BINARY_OP", color="orange", domain="cudf_python")
def binop(lhs, rhs, op, out_dtype):
    out = libcudf.binaryop.binaryop(lhs, rhs, op, out_dtype)
    return out


def determine_out_dtype(lhs_dtype, rhs_dtype):
    if np.can_cast(np.dtype(lhs_dtype), np.dtype(rhs_dtype)):
        return rhs_dtype
    elif np.can_cast(np.dtype(rhs_dtype), np.dtype(lhs_dtype)):
        return lhs_dtype
    else:
        raise TypeError(f"Cannot type-cast {lhs_dtype} and {rhs_dtype}")


def _timedelta_binary_op_add(lhs, rhs):
    if pd.api.types.is_timedelta64_dtype(rhs.dtype):
        out_dtype = determine_out_dtype(lhs.dtype, rhs.dtype)
    elif pd.api.types.is_datetime64_dtype(rhs.dtype):
        units = ["s", "ms", "us", "ns"]
        lhs_time_unit = cudf.utils.dtypes.get_time_unit(lhs)
        lhs_unit = units.index(lhs_time_unit)
        rhs_time_unit = cudf.utils.dtypes.get_time_unit(rhs)
        rhs_unit = units.index(rhs_time_unit)
        out_dtype = np.dtype(f"datetime64[{units[max(lhs_unit, rhs_unit)]}]")
    else:
        raise TypeError(
            f"Addition of {lhs.dtype} with {rhs.dtype} "
            f"cannot be performed."
        )

    return out_dtype


def _timedelta_binary_op_sub(lhs, rhs):
    if pd.api.types.is_timedelta64_dtype(
        lhs.dtype
    ) and pd.api.types.is_timedelta64_dtype(rhs.dtype):
        out_dtype = determine_out_dtype(lhs.dtype, rhs.dtype)
    elif pd.api.types.is_timedelta64_dtype(
        rhs.dtype
    ) and pd.api.types.is_datetime64_dtype(lhs.dtype):
        units = ["s", "ms", "us", "ns"]
        lhs_time_unit = cudf.utils.dtypes.get_time_unit(lhs)
        lhs_unit = units.index(lhs_time_unit)
        rhs_time_unit = cudf.utils.dtypes.get_time_unit(rhs)
        rhs_unit = units.index(rhs_time_unit)
        out_dtype = np.dtype(f"datetime64[{units[max(lhs_unit, rhs_unit)]}]")
    else:
        raise TypeError(
            f"Subtraction of {lhs.dtype} with {rhs.dtype} "
            f"cannot be performed."
        )

    return out_dtype
