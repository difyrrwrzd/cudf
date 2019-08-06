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

#include <cudf/cudf.h>
#include <io/utilities/wrapper_utils.hpp>
#include <utilities/error_utils.hpp>
#include <cudf/utils/legacy/wrapper_types.hpp>
#include <utilities/bit_util.cuh>

#include <cuda_runtime.h>
#include <nvstrings/NVStrings.h>
#include <nvstrings/NVCategory.h>
#include <rmm/rmm.h>
#include <rmm/thrust_rmm_allocator.h>

#include <fstream>
#include <algorithm>

// Functor for type-dispatcher converts columns into strings
struct column_to_strings_fn
{
    const gdf_column* column;
    gdf_valid_type* valid;
    gdf_size_type row_offset, rows;
    const char* true_string;
    const char* false_string;
    template<typename T>
    NVStrings* operator()()
    {
        throw std::runtime_error("column type not supported");
    }

    // convert cudf time units to nvstrings timestamp units
    NVStrings::timestamp_units cudf2nvs( gdf_time_unit time_unit )
    {
        if( time_unit==TIME_UNIT_s )
            return NVStrings::seconds;
        if( time_unit==TIME_UNIT_us )
            return NVStrings::us;
        if( time_unit==TIME_UNIT_ns )
            return NVStrings::ns;
        return NVStrings::ms;
    }
};

// specialization code for each type
template<>
NVStrings* column_to_strings_fn::operator()<int8_t>()
{
    auto d_src = (static_cast<const int8_t*>(column->data)) + row_offset;
    device_buffer<int32_t> int_buffer(rows);
    thrust::transform( rmm::exec_policy()->on(0), d_src, d_src + rows, int_buffer.data(),
        [] __device__(const int8_t value) { return int32_t{value}; });
    return NVStrings::itos(int_buffer.data(), rows, valid);
}

template<>
NVStrings* column_to_strings_fn::operator()<int16_t>()
{
    auto d_src = (static_cast<const int16_t*>(column->data)) + row_offset;
    device_buffer<int32_t> int_buffer(rows);
    thrust::transform( rmm::exec_policy()->on(0), d_src, d_src + rows, int_buffer.data(),
        [] __device__(const int16_t value) { return int32_t{value}; });
    return NVStrings::itos(int_buffer.data(), rows, valid);
}

template<>
NVStrings* column_to_strings_fn::operator()<int32_t>()
{
    return NVStrings::itos((static_cast<const int32_t*>(column->data)) + row_offset, rows, valid);
}

template<>
NVStrings* column_to_strings_fn::operator()<int64_t>()
{
    return NVStrings::ltos((static_cast<const int64_t*>(column->data)) + row_offset, rows, valid);
}

template<>
NVStrings* column_to_strings_fn::operator()<float>()
{
    return NVStrings::ftos((static_cast<const float*>(column->data)) + row_offset, rows, valid);
}

template<>
NVStrings* column_to_strings_fn::operator()<double>()
{
    return NVStrings::dtos((static_cast<const double*>(column->data)) + row_offset, rows, valid);
}

template<>
NVStrings* column_to_strings_fn::operator()<cudf::bool8>()
{
    if( sizeof(bool) == sizeof(cudf::bool8) )
        return NVStrings::create_from_bools((static_cast<const bool*>(column->data)) + row_offset, rows, true_string, false_string, valid);
    else
    {
        auto d_src = (static_cast<const cudf::bool8*>(column->data)) + row_offset;
        device_buffer<bool> bool_buffer(rows);
        thrust::transform( rmm::exec_policy()->on(0), d_src, d_src + rows, bool_buffer.data(),
                [] __device__(const cudf::bool8 value) { return bool{value}; });
        return NVStrings::create_from_bools(bool_buffer.data(), rows, true_string, false_string, valid);
    }
}

template<>
NVStrings* column_to_strings_fn::operator()<cudf::date32>()
{
    NVStrings::timestamp_units units = NVStrings::days;
    if( column->dtype_info.time_unit != TIME_UNIT_NONE )
        units = cudf2nvs(column->dtype_info.time_unit);
    auto d_src = (static_cast<const cudf::date32*>(column->data)) + row_offset;
    device_buffer<unsigned long> ulong_buffer(rows);
    thrust::transform( rmm::exec_policy()->on(0), d_src, d_src + rows, ulong_buffer.data(),
        [] __device__(const cudf::date32 value) { return (unsigned long)(int32_t{value}); });
    return NVStrings::long2timestamp(ulong_buffer.data(), rows, units, nullptr, valid);
}

template<>
NVStrings* column_to_strings_fn::operator()<cudf::date64>()
{
    return NVStrings::long2timestamp(static_cast<const uint64_t*>(column->data) + row_offset, rows,
                                     NVStrings::ms, nullptr, valid);
}

template<>
NVStrings* column_to_strings_fn::operator()<cudf::timestamp>()
{
    NVStrings::timestamp_units units = cudf2nvs(column->dtype_info.time_unit);
    return NVStrings::long2timestamp(static_cast<const uint64_t*>(column->data) + row_offset, rows,
                                     units, nullptr, valid);
}

template<>
NVStrings* column_to_strings_fn::operator()<cudf::nvstring_category>()
{
    NVCategory* category = reinterpret_cast<NVCategory*>(column->dtype_info.category);
    CUDF_EXPECTS( category != nullptr, "write_csv: invalid category column");
    return category->gather_strings((static_cast<const int32_t*>(column->data)) + row_offset, rows);
}


//
// This is called by the write_csv method below.
//
// Parameters:
// - column: The column to be converted.
// - row_offset: Number entries from the beginning to skip; must be multiple of 8.
// - rows: Number of rows from the offset that should be converted for this column.
// - delimiter: Separator to append to the column strings
// - null_representation: String to use for null entries
// - true_string: String to use for 'true' values in boolean columns
// - false_string: String to use for 'false' values in boolean columns
// Return: NVStrings instance formated for CSV column output.
//
NVStrings* column_to_strings_csv(const gdf_column* column, gdf_size_type row_offset, gdf_size_type rows,
                                 const char* delimiter, const char* null_representation,
                                 const char* true_string, const char* false_string )
{
    NVStrings* rtn = nullptr;
    // point the null bitmask to the next set of bits associated with this chunk of rows
    gdf_valid_type* valid = column->valid;
    if( valid )                                    // normalize row_offset (number of bits here)
        valid += (row_offset / GDF_VALID_BITSIZE); // to appropriate pointer for the bitmask

    if( column->dtype == GDF_STRING )
        rtn = (static_cast<NVStrings*>(column->data))->sublist(row_offset,row_offset+rows);
    else
        rtn = cudf::type_dispatcher(column->dtype, column_to_strings_fn{column,valid,row_offset,rows,true_string,false_string});

    CUDF_EXPECTS( rtn != nullptr, "write_csv: unsupported column type");

    // replace nulls if specified
    if( null_representation )
    {
        NVStrings* nstr = rtn->fillna(null_representation);
        NVStrings::destroy(rtn);
        rtn = nstr;
    }

    // probably could collapse this more
    bool bquoted = (column->dtype==GDF_STRING || column->dtype==GDF_DATE64);
    // check for delimiters and quotes
    bool* bmatches = nullptr;
    RMM_TRY( RMM_ALLOC(&bmatches,rows*sizeof(bool),0) );
    if( rtn->contains("\"",bmatches) > 0 )
    {
        NVStrings* esc = rtn->replace("\"","\"\"");
        NVStrings::destroy(rtn);
        rtn = esc;
    }
    else if( rtn->contains(",",bmatches) > 0 )
        bquoted = true;
    RMM_TRY( RMM_FREE( bmatches, 0 ) );
    if( bquoted )
    {
        // prepend and append quotes if needed
        NVStrings* pre = rtn->slice_replace("\"",0,0);
        NVStrings::destroy(rtn);
        rtn = pre->slice_replace("\"",-1,-1);
        NVStrings::destroy(pre);
    }
    // append the delimiter last
    if( delimiter && *delimiter )
    {
        NVStrings* dstr = rtn->slice_replace(delimiter,-1,-1);
        NVStrings::destroy(rtn);
        rtn = dstr;
    }
    return rtn;
}

//---------------------------------------------------------------------------
// Creates CSV file from array of gdf_columns.
//
// This will create the CSV format by allocating host memory for the
// entire output and determine pointers for each row/column entry.
// Each column is converted to an NVStrings instance and then
// copied into their position in the output memory. This way,
// one column is processed at a time minimizing device memory usage.
//
//---------------------------------------------------------------------------
gdf_error write_csv(csv_write_arg* args)
{
    // when args becomes a struct/class these can be modified
    auto columns = args->columns;
    unsigned int count = (unsigned int)args->num_cols;
    gdf_size_type total_rows = columns[0]->size;
    const char* filepath = args->filepath;
    char delimiter[2] = {',','\0'};
    if( args->delimiter )
        delimiter[0] = args->delimiter;
    const char* terminator = "\n";
    if( args->line_terminator )
        terminator = args->line_terminator;
    const char* narep = "";
    if( args->na_rep )
        narep = args->na_rep;
    const char* true_value = (args->true_value ? args->true_value : "true");
    const char* false_value = (args->false_value ? args->false_value : "false");
    bool include_header = args->include_header;

    // check for issues here
    CUDF_EXPECTS( filepath!=nullptr, "write_csv: filepath not specified" );
    CUDF_EXPECTS( count!=0, "write_csv: num_cols is required" );
    CUDF_EXPECTS( columns!=0, "write_csv: invalid data values" );

    // check all columns are the same size
    const bool all_sizes_match = std::all_of( columns, columns+count,
        [total_rows] (auto col) {
            if( col->dtype==GDF_STRING )
            {
                NVStrings* strs = (NVStrings*)col->data;
                unsigned int elems = strs != nullptr ? strs->size() : 0;
                return (total_rows==(gdf_size_type)elems);
            }
            return (total_rows==col->size);
        });
    CUDF_EXPECTS( all_sizes_match, "write_csv: columns sizes do not match" );

    // check the file can be written
    std::ofstream filecsv(filepath,std::ios::out|std::ios::binary|std::ios::trunc);
    CUDF_EXPECTS( filecsv.is_open(), "write_csv: file could not be opened");

    //
    // This outputs the CSV in row chunks to save memory.
    // Maybe we can use the total_rows*count calculation and a memory threshold
    // instead of an arbitrary chunk count.
    // The entire CSV chunk must fit in CPU memory before writing it out.
    //
    gdf_size_type rows_chunk = (args->rows_per_chunk/8)*8; // must be divisible by 8
    CUDF_EXPECTS( rows_chunk>0, "write_csv: invalid chunk_rows; must be at least 8" );

    gdf_size_type row_offset = 0;
    gdf_size_type rows = total_rows;
    while( rows > 0 )
    {
        if( rows > rows_chunk )
            rows = rows_chunk;
        //
        // Compute string lengths for each string to go into the CSV output.
        std::unique_ptr<int[]> pstring_lengths(new int[rows*count]); // matrix of lengths
        int* string_lengths = pstring_lengths.get(); // each string length in each row,column
        size_t memsize = 0;
        for( unsigned int idx=0; idx < count; ++idx )
        {
            const gdf_column* col = columns[idx];
            const char* delim = ((idx+1)<count ? delimiter : terminator);
            NVStrings* strs = column_to_strings_csv(col,row_offset,rows,delim,narep,true_value,false_value);
            memsize += strs->byte_count(string_lengths + (idx*rows),false);
            NVStrings::destroy(strs);
        }

        //
        // Example string_lengths matrix for 4 columns and 7 rows
        //                                     row-sums
        // col0:   1,  1,  2, 11, 12,  7,  7 |  41
        // col1:   1,  1,  2,  2,  3,  7,  6 |  22
        // col2:  20, 20, 20, 20, 20, 20, 20 | 140
        // col3:   5,  6,  4,  6,  4,  4,  5 |  34
        //        --------------------------------
        // col-   27, 28, 28, 39, 39, 38, 38 = 237   (for reference only)
        // sums
        //
        // Need to convert this into the following -- string_locations (below)
        //     0,  27,  55,  83, 122, 161, 199
        //     1,  28,  57,  94, 134, 168, 206
        //     2,  29,  59,  96, 137, 175, 212
        //    22,  49,  79, 116, 157, 195, 232
        //
        // This is essentially an exclusive-scan (prefix-sum) across columns.
        // Moving left-to-right, add up each column and carry each value to the next column.
        // Looks like we could transpose the matrix, scan it, and then untranspose it.
        // Should be able to parallelize the math for this -- will look at prefix-sum algorithms.
        //
        std::vector<char> buffer(memsize+1);
        std::vector<size_t> string_locations(rows*count); // all the memory pointers for each column
        string_locations[0] = 0; // first one is always 0
        // compute offsets as described above into locations matrix
        size_t offset = 0;
        for( gdf_size_type jdx=0; jdx < rows; ++jdx )
        {
            // add up column values for each row
            // this is essentially an exclusive-scan across columns
            string_locations[jdx] = (size_t)(buffer.data() + offset); // initialize first item
            for( unsigned int idx=0; idx < count; ++idx )
            {
                int* in = string_lengths + (idx*rows);
                int len = in[jdx];
                offset += (len > 0 ? len:0);
                if( (idx+1) < count )
                {
                    size_t* out = string_locations.data() + ((idx+1)*rows);
                    out[jdx] = (size_t)(buffer.data() + offset);
                }
            }
        }
        // now fill in the memory one column at a time
        for( unsigned int idx=0; idx < count; ++idx )
        {
            const gdf_column* col = columns[idx];
            const char* delim = ((idx+1)<count ? delimiter : terminator);
            NVStrings* strs = column_to_strings_csv(col,row_offset,rows,delim,narep,true_value,false_value);
            size_t* colptrs = string_locations.data() + (idx*rows);
            // to_host places all the strings into their correct positions in host memory
            strs->to_host((char**)colptrs,0,rows);
            NVStrings::destroy(strs);
        }
        //buffer[memsize] = 0; // just so we can printf if needed
        // now write buffer to file
        // first write the header
        if(include_header)
        {
            for( unsigned int idx=0; idx < count; ++idx )
            {
                const gdf_column* col = columns[idx];
                const char* delim = ((idx+1)<count ? delimiter : terminator);
                if( col->col_name )
                    filecsv << "\"" << col->col_name << "\"";
                filecsv << delim;
            }
        }
        // now write the data
        filecsv.write(buffer.data(),memsize);

        // get ready for the next chunk of rows
        row_offset += rows_chunk;
        if( row_offset < total_rows )
            rows = total_rows - row_offset;
        else
            rows = 0;
        // prevent header for subsequent chunks
        include_header = false;
    }

    filecsv.close();
    return gdf_error::GDF_SUCCESS;
}
