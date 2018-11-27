#include "cudf.h"
#include "rmm/rmm.h"
#include "utilities/cudf_utils.h"
#include "utilities/error_utils.h"


#include <cub/device/device_segmented_radix_sort.cuh>


struct SegmentedRadixSortPlan{
    const size_t num_items;
    // temporary storage
    void *storage;
    size_t storage_bytes;
    void *back_key, *back_val;
    size_t back_key_size, back_val_size;

    cudaStream_t stream;
    int descending;
    unsigned begin_bit, end_bit;

    SegmentedRadixSortPlan(size_t num_items, int descending,
                           unsigned begin_bit, unsigned end_bit)
        :   num_items(num_items),
            storage(nullptr), storage_bytes(0),
            back_key(nullptr), back_val(nullptr),
            back_key_size(0), back_val_size(0),
            stream(0), descending(descending),
            begin_bit(begin_bit), end_bit(end_bit)
    {}

    gdf_error setup(size_t sizeof_key, size_t sizeof_val) {
        back_key_size = num_items * sizeof_key;
        back_val_size = num_items * sizeof_val;
        RMM_TRY( RMM_ALLOC(&back_key, back_key_size, stream) ); // TODO: non-default stream
        RMM_TRY( RMM_ALLOC(&back_val, back_val_size, stream) );
        return GDF_SUCCESS;
    }

    gdf_error teardown() {
        RMM_TRY(RMM_FREE(back_key, stream));
        RMM_TRY(RMM_FREE(back_val, stream));
        RMM_TRY(RMM_FREE(storage, stream));
        return GDF_SUCCESS;
    }
};




template <typename Tk, typename Tv>
struct SegmentedRadixSort {

    static
    gdf_error sort( SegmentedRadixSortPlan *plan,
                    Tk *d_key_buf, Tv *d_value_buf,
                    unsigned num_segments,
                    unsigned *d_begin_offsets,
                    unsigned *d_end_offsets) {

        unsigned  num_items = plan->num_items;
        Tk *d_key_alt_buf = (Tk*)plan->back_key;
        Tv *d_value_alt_buf = (Tv*)plan->back_val;

        cudaStream_t stream = plan->stream;
        int descending = plan->descending;
        unsigned begin_bit = plan->begin_bit;
        unsigned end_bit = plan->end_bit;

        cub::DoubleBuffer<Tk> d_keys(d_key_buf, d_key_alt_buf);

        typedef cub::DeviceSegmentedRadixSort Sorter;

        if (d_value_buf) {
            // Sort KeyValue pairs
            cub::DoubleBuffer<Tv> d_values(d_value_buf, d_value_alt_buf);
            if (descending) {
                Sorter::SortPairsDescending(plan->storage,
                                            plan->storage_bytes,
                                            d_keys,
                                            d_values,
                                            num_items,
                                            num_segments,
                                            d_begin_offsets,
                                            d_end_offsets,
                                            begin_bit,
                                            end_bit,
                                            stream);
            } else {
                Sorter::SortPairs(  plan->storage,
                                    plan->storage_bytes,
                                    d_keys,
                                    d_values,
                                    num_items,
                                    num_segments,
                                    d_begin_offsets,
                                    d_end_offsets,
                                    begin_bit,
                                    end_bit,
                                    stream    );
            }
            CUDA_CHECK_LAST();
            if (plan->storage && d_value_buf != d_values.Current()){
                cudaMemcpyAsync(d_value_buf, d_value_alt_buf,
                                num_items * sizeof(Tv),
                                cudaMemcpyDeviceToDevice,
                                stream);
                CUDA_CHECK_LAST();
            }
        } else {
            // Sort Keys only
            if (descending) {
                Sorter::SortKeysDescending(   plan->storage,
                                              plan->storage_bytes,
                                              d_keys,
                                              num_items,
                                              num_segments,
                                              d_begin_offsets,
                                              d_end_offsets,
                                              begin_bit,
                                              end_bit,
                                              stream  );
                CUDA_CHECK_LAST()

            } else {
                Sorter::SortKeys( plan->storage,
                                  plan->storage_bytes,
                                  d_keys,
                                  num_items,
                                  num_segments,
                                  d_begin_offsets,
                                  d_end_offsets,
                                  begin_bit,
                                  end_bit,
                                  stream  );
            }

            CUDA_CHECK_LAST();
        }

        if ( plan->storage ) {
            // We have operated and the result is not in front buffer
            if (d_key_buf != d_keys.Current()){
                cudaMemcpyAsync(d_key_buf, d_key_alt_buf, num_items * sizeof(Tk),
                                          cudaMemcpyDeviceToDevice, stream);
                CUDA_CHECK_LAST();
            }
        } else {
            // We have not operated.
            // Just checking for temporary storage requirement
            RMM_TRY( RMM_ALLOC(&plan->storage, plan->storage_bytes, plan->stream) ); // TODO: non-default stream
            CUDA_CHECK_LAST();
            // Now that we have allocated, do real work.
            return sort(plan, d_key_buf, d_value_buf, num_segments,
                        d_begin_offsets, d_end_offsets);
        }
        return GDF_SUCCESS;
    }
};


gdf_segmented_radixsort_plan_type* cffi_wrap(SegmentedRadixSortPlan* obj){
    return reinterpret_cast<gdf_segmented_radixsort_plan_type*>(obj);
}

SegmentedRadixSortPlan* cffi_unwrap(gdf_segmented_radixsort_plan_type* hdl){
    return reinterpret_cast<SegmentedRadixSortPlan*>(hdl);
}


gdf_segmented_radixsort_plan_type* gdf_segmented_radixsort_plan(
    size_t num_items, int descending,
    unsigned begin_bit, unsigned end_bit)
{
    return cffi_wrap(new SegmentedRadixSortPlan(num_items, descending,
    begin_bit, end_bit));
}

gdf_error gdf_segmented_radixsort_plan_setup(
    gdf_segmented_radixsort_plan_type *hdl,
    size_t sizeof_key, size_t sizeof_val)
{
    return cffi_unwrap(hdl)->setup(sizeof_key, sizeof_val);
}

gdf_error gdf_segmented_radixsort_plan_free(gdf_segmented_radixsort_plan_type *hdl)
{
    auto plan = cffi_unwrap(hdl);
    gdf_error status = plan->teardown();
    delete plan;
    return status;
}



#define WRAP(Fn, Tk, Tv)                                                            \
gdf_error gdf_segmented_radixsort_##Fn(gdf_segmented_radixsort_plan_type *hdl,      \
                             gdf_column *keycol,                                    \
                             gdf_column *valcol,                                    \
                             unsigned num_segments,                                 \
                             unsigned *d_begin_offsets,                             \
                             unsigned *d_end_offsets)                               \
{                                                                                   \
    /* validity mask must be empty */                                               \
    GDF_REQUIRE(!keycol->valid || !keycol->null_count, GDF_VALIDITY_UNSUPPORTED);   \
    GDF_REQUIRE(!valcol->valid || !valcol->null_count, GDF_VALIDITY_UNSUPPORTED);   \
    /* size of columns must match */                                                \
    GDF_REQUIRE(keycol->size == valcol->size, GDF_COLUMN_SIZE_MISMATCH);            \
    SegmentedRadixSortPlan *plan = cffi_unwrap(hdl);                                \
    /* num_items must match */                                                      \
    GDF_REQUIRE(plan->num_items == keycol->size, GDF_COLUMN_SIZE_MISMATCH);         \
    /* back buffer size must match */                                               \
    GDF_REQUIRE(sizeof(Tk) * plan->num_items == plan->back_key_size,                \
                GDF_COLUMN_SIZE_MISMATCH);                                          \
    GDF_REQUIRE(sizeof(Tv) * plan->num_items == plan->back_val_size,                \
                GDF_COLUMN_SIZE_MISMATCH);                                          \
    /* Do sort */                                                                   \
    return SegmentedRadixSort<Tk, Tv>::sort(plan,                                   \
                                   (Tk*)keycol->data, (Tv*)valcol->data,            \
                                    num_segments, d_begin_offsets, d_end_offsets);  \
}



WRAP(f32, float,   int64_t)
WRAP(f64, double,  int64_t)
WRAP(i8,  int8_t,  int64_t)
WRAP(i32, int32_t, int64_t)
WRAP(i64, int64_t, int64_t)


gdf_error gdf_segmented_radixsort_generic(gdf_segmented_radixsort_plan_type *hdl,
                                          gdf_column *keycol,
                                          gdf_column *valcol,
                                          unsigned num_segments,
                                          unsigned *d_begin_offsets,
                                          unsigned *d_end_offsets)
{
    GDF_REQUIRE(valcol->dtype == GDF_INT64, GDF_UNSUPPORTED_DTYPE);
    // dispatch table
    switch ( keycol->dtype ) {
    case GDF_INT8:    return gdf_segmented_radixsort_i8(hdl, keycol, valcol,
                                                        num_segments, d_begin_offsets,
                                                        d_end_offsets);
    case GDF_INT32:   return gdf_segmented_radixsort_i32(hdl, keycol, valcol,
                                                         num_segments, d_begin_offsets,
                                                         d_end_offsets);
    case GDF_INT64:   return gdf_segmented_radixsort_i64(hdl, keycol, valcol,
                                                        num_segments, d_begin_offsets,
                                                        d_end_offsets);
    case GDF_FLOAT32: return gdf_segmented_radixsort_f32(hdl, keycol, valcol,
                                                        num_segments, d_begin_offsets,
                                                        d_end_offsets);
    case GDF_FLOAT64: return gdf_segmented_radixsort_f64(hdl, keycol, valcol,
                                                        num_segments, d_begin_offsets,
                                                        d_end_offsets);
    default:          return GDF_UNSUPPORTED_DTYPE;
    }
}


