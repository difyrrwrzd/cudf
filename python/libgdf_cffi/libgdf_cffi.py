# auto-generated file
import _cffi_backend

ffi = _cffi_backend.FFI('libgdf_cffi.libgdf_cffi',
    _version = 0x2601,
    _types = b'\x00\x00\x16\x0D\x00\x00\x01\x0B\x00\x00\x00\x0F\x00\x00\x01\x0D\x00\x00\x19\x03\x00\x00\x04\x11\x00\x00\x00\x0F\x00\x00\x01\x0D\x00\x00\x04\x11\x00\x00\x04\x11\x00\x00\x04\x11\x00\x00\x00\x0F\x00\x00\x01\x0D\x00\x00\x04\x11\x00\x00\x1B\x03\x00\x00\x1A\x03\x00\x00\x1C\x01\x00\x00\x00\x0B\x00\x00\x00\x0F\x00\x00\x10\x0D\x00\x00\x00\x0F\x00\x00\x1B\x0D\x00\x00\x18\x03\x00\x00\x00\x0F\x00\x00\x02\x01\x00\x00\x00\x09\x00\x00\x04\x01\x00\x00\x00\x01',
    _globals = (b'\xFF\xFF\xFF\x0BGDF_COLUMN_SIZE_MISMATCH',3,b'\xFF\xFF\xFF\x0BGDF_CUDA_ERROR',1,b'\xFF\xFF\xFF\x0BGDF_FLOAT32',5,b'\xFF\xFF\xFF\x0BGDF_FLOAT64',6,b'\xFF\xFF\xFF\x0BGDF_INT16',2,b'\xFF\xFF\xFF\x0BGDF_INT32',3,b'\xFF\xFF\xFF\x0BGDF_INT64',4,b'\xFF\xFF\xFF\x0BGDF_INT8',1,b'\xFF\xFF\xFF\x0BGDF_SUCCESS',0,b'\xFF\xFF\xFF\x0BGDF_UNSUPPORTED_DTYPE',2,b'\xFF\xFF\xFF\x0BGDF_invalid',0,b'\x00\x00\x03\x23gdf_acos_f32',0,b'\x00\x00\x03\x23gdf_acos_f64',0,b'\x00\x00\x03\x23gdf_acos_generic',0,b'\x00\x00\x07\x23gdf_add_f32',0,b'\x00\x00\x07\x23gdf_add_f64',0,b'\x00\x00\x07\x23gdf_add_generic',0,b'\x00\x00\x07\x23gdf_add_i32',0,b'\x00\x00\x07\x23gdf_add_i64',0,b'\x00\x00\x03\x23gdf_asin_f32',0,b'\x00\x00\x03\x23gdf_asin_f64',0,b'\x00\x00\x03\x23gdf_asin_generic',0,b'\x00\x00\x03\x23gdf_atan_f32',0,b'\x00\x00\x03\x23gdf_atan_f64',0,b'\x00\x00\x03\x23gdf_atan_generic',0,b'\x00\x00\x03\x23gdf_cast_f32_to_f32',0,b'\x00\x00\x03\x23gdf_cast_f32_to_f64',0,b'\x00\x00\x03\x23gdf_cast_f32_to_i32',0,b'\x00\x00\x03\x23gdf_cast_f32_to_i64',0,b'\x00\x00\x03\x23gdf_cast_f32_to_i8',0,b'\x00\x00\x03\x23gdf_cast_f64_to_f32',0,b'\x00\x00\x03\x23gdf_cast_f64_to_f64',0,b'\x00\x00\x03\x23gdf_cast_f64_to_i32',0,b'\x00\x00\x03\x23gdf_cast_f64_to_i64',0,b'\x00\x00\x03\x23gdf_cast_f64_to_i8',0,b'\x00\x00\x03\x23gdf_cast_generic_to_f32',0,b'\x00\x00\x03\x23gdf_cast_generic_to_f64',0,b'\x00\x00\x03\x23gdf_cast_generic_to_i32',0,b'\x00\x00\x03\x23gdf_cast_generic_to_i64',0,b'\x00\x00\x03\x23gdf_cast_generic_to_i8',0,b'\x00\x00\x03\x23gdf_cast_i32_to_f32',0,b'\x00\x00\x03\x23gdf_cast_i32_to_f64',0,b'\x00\x00\x03\x23gdf_cast_i32_to_i32',0,b'\x00\x00\x03\x23gdf_cast_i32_to_i64',0,b'\x00\x00\x03\x23gdf_cast_i32_to_i8',0,b'\x00\x00\x03\x23gdf_cast_i64_to_f32',0,b'\x00\x00\x03\x23gdf_cast_i64_to_f64',0,b'\x00\x00\x03\x23gdf_cast_i64_to_i32',0,b'\x00\x00\x03\x23gdf_cast_i64_to_i64',0,b'\x00\x00\x03\x23gdf_cast_i64_to_i8',0,b'\x00\x00\x03\x23gdf_cast_i8_to_f32',0,b'\x00\x00\x03\x23gdf_cast_i8_to_f64',0,b'\x00\x00\x03\x23gdf_cast_i8_to_i32',0,b'\x00\x00\x03\x23gdf_cast_i8_to_i64',0,b'\x00\x00\x03\x23gdf_cast_i8_to_i8',0,b'\x00\x00\x03\x23gdf_ceil_f32',0,b'\x00\x00\x03\x23gdf_ceil_f64',0,b'\x00\x00\x03\x23gdf_ceil_generic',0,b'\x00\x00\x13\x23gdf_column_sizeof',0,b'\x00\x00\x0C\x23gdf_column_view',0,b'\x00\x00\x03\x23gdf_cos_f32',0,b'\x00\x00\x03\x23gdf_cos_f64',0,b'\x00\x00\x03\x23gdf_cos_generic',0,b'\x00\x00\x07\x23gdf_div_f32',0,b'\x00\x00\x07\x23gdf_div_f64',0,b'\x00\x00\x07\x23gdf_div_generic',0,b'\x00\x00\x07\x23gdf_eq_f32',0,b'\x00\x00\x07\x23gdf_eq_f64',0,b'\x00\x00\x07\x23gdf_eq_generic',0,b'\x00\x00\x07\x23gdf_eq_i32',0,b'\x00\x00\x07\x23gdf_eq_i64',0,b'\x00\x00\x00\x23gdf_error_get_name',0,b'\x00\x00\x03\x23gdf_exp_f32',0,b'\x00\x00\x03\x23gdf_exp_f64',0,b'\x00\x00\x03\x23gdf_exp_generic',0,b'\x00\x00\x03\x23gdf_floor_f32',0,b'\x00\x00\x03\x23gdf_floor_f64',0,b'\x00\x00\x03\x23gdf_floor_generic',0,b'\x00\x00\x07\x23gdf_floordiv_f32',0,b'\x00\x00\x07\x23gdf_floordiv_f64',0,b'\x00\x00\x07\x23gdf_floordiv_generic',0,b'\x00\x00\x07\x23gdf_floordiv_i32',0,b'\x00\x00\x07\x23gdf_floordiv_i64',0,b'\x00\x00\x07\x23gdf_ge_f32',0,b'\x00\x00\x07\x23gdf_ge_f64',0,b'\x00\x00\x07\x23gdf_ge_generic',0,b'\x00\x00\x07\x23gdf_ge_i32',0,b'\x00\x00\x07\x23gdf_ge_i64',0,b'\x00\x00\x07\x23gdf_gt_f32',0,b'\x00\x00\x07\x23gdf_gt_f64',0,b'\x00\x00\x07\x23gdf_gt_generic',0,b'\x00\x00\x07\x23gdf_gt_i32',0,b'\x00\x00\x07\x23gdf_gt_i64',0,b'\x00\x00\x15\x23gdf_ipc_parse',0,b'\x00\x00\x07\x23gdf_le_f32',0,b'\x00\x00\x07\x23gdf_le_f64',0,b'\x00\x00\x07\x23gdf_le_generic',0,b'\x00\x00\x07\x23gdf_le_i32',0,b'\x00\x00\x07\x23gdf_le_i64',0,b'\x00\x00\x03\x23gdf_log_f32',0,b'\x00\x00\x03\x23gdf_log_f64',0,b'\x00\x00\x03\x23gdf_log_generic',0,b'\x00\x00\x07\x23gdf_lt_f32',0,b'\x00\x00\x07\x23gdf_lt_f64',0,b'\x00\x00\x07\x23gdf_lt_generic',0,b'\x00\x00\x07\x23gdf_lt_i32',0,b'\x00\x00\x07\x23gdf_lt_i64',0,b'\x00\x00\x07\x23gdf_mul_f32',0,b'\x00\x00\x07\x23gdf_mul_f64',0,b'\x00\x00\x07\x23gdf_mul_generic',0,b'\x00\x00\x07\x23gdf_mul_i32',0,b'\x00\x00\x07\x23gdf_mul_i64',0,b'\x00\x00\x07\x23gdf_ne_f32',0,b'\x00\x00\x07\x23gdf_ne_f64',0,b'\x00\x00\x07\x23gdf_ne_generic',0,b'\x00\x00\x07\x23gdf_ne_i32',0,b'\x00\x00\x07\x23gdf_ne_i64',0,b'\x00\x00\x03\x23gdf_sin_f32',0,b'\x00\x00\x03\x23gdf_sin_f64',0,b'\x00\x00\x03\x23gdf_sin_generic',0,b'\x00\x00\x03\x23gdf_sqrt_f32',0,b'\x00\x00\x03\x23gdf_sqrt_f64',0,b'\x00\x00\x03\x23gdf_sqrt_generic',0,b'\x00\x00\x07\x23gdf_sub_f32',0,b'\x00\x00\x07\x23gdf_sub_f64',0,b'\x00\x00\x07\x23gdf_sub_generic',0,b'\x00\x00\x07\x23gdf_sub_i32',0,b'\x00\x00\x07\x23gdf_sub_i64',0,b'\x00\x00\x03\x23gdf_tan_f32',0,b'\x00\x00\x03\x23gdf_tan_f64',0,b'\x00\x00\x03\x23gdf_tan_generic',0),
    _struct_unions = ((b'\x00\x00\x00\x19\x00\x00\x00\x02gdf_column_',b'\x00\x00\x0E\x11data',b'\x00\x00\x0F\x11valid',b'\x00\x00\x10\x11size',b'\x00\x00\x11\x11dtype'),),
    _enums = (b'\x00\x00\x00\x11\x00\x00\x00\x16$gdf_dtype\x00GDF_invalid,GDF_INT8,GDF_INT16,GDF_INT32,GDF_INT64,GDF_FLOAT32,GDF_FLOAT64',b'\x00\x00\x00\x01\x00\x00\x00\x16$gdf_error\x00GDF_SUCCESS,GDF_CUDA_ERROR,GDF_UNSUPPORTED_DTYPE,GDF_COLUMN_SIZE_MISMATCH'),
    _typenames = (b'\x00\x00\x00\x19gdf_column',b'\x00\x00\x00\x11gdf_dtype',b'\x00\x00\x00\x01gdf_error',b'\x00\x00\x00\x10gdf_index_type',b'\x00\x00\x00\x10gdf_size_type',b'\x00\x00\x00\x1Agdf_valid_type'),
)
