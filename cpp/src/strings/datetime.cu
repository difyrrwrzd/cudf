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

#include <cudf/column/column_device_view.cuh>
#include <cudf/column/column_factories.hpp>
#include <cudf/utilities/type_dispatcher.hpp>
#include <cudf/wrappers/timestamps.hpp>
#include <cudf/strings/datetime.hpp>
#include <cudf/strings/strings_column_view.hpp>
#include <cudf/strings/string_view.cuh>
#include <cudf/utilities/error.hpp>
#include "./utilities.hpp"
#include "./utilities.cuh"

#include <vector>
#include <map>
#include <rmm/thrust_rmm_allocator.h>
#include <thrust/sort.h>
#include <thrust/sequence.h>

namespace cudf
{
namespace strings
{
namespace
{

/**
 * @brief  Units for timestamp conversion.
 * These are defined since there are more than what cudf supports.
 */
enum timestamp_units {
    years,           ///< precision is years
    months,          ///< precision is months
    days,            ///< precision is days
    hours,           ///< precision is hours
    minutes,         ///< precision is minutes
    seconds,         ///< precision is seconds
    ms,              ///< precision is milliseconds
    us,              ///< precision is microseconds
    ns               ///< precision is nanoseconds
};


// used to index values in a timeparts array
enum timestamp_parse_component {
    TP_YEAR        = 0,
    TP_MONTH       = 1,
    TP_DAY         = 2,
    TP_HOUR        = 3,
    TP_MINUTE      = 4,
    TP_SECOND      = 5,
    TP_SUBSECOND   = 6,
    TP_TZ_MINUTES  = 7,
    TP_ARRAYSIZE   = 8
};

struct format_item
{
    bool item_type;    // 1=specifier, 0=literal
    char specifier;    // specifier
    int8_t length;     // item length in bytes
    char literal;      // pass-thru character

    static format_item new_specifier(char format_char, int8_t length)
    {
        return format_item{true,format_char,length,0};
    }
    static format_item new_delimiter(char literal)
    {
        return format_item{false,0,1,literal};
    }
};

struct format_program
{
    format_item* items;
    size_t count;
};

struct format_compiler
{
    std::vector<format_item> items;
    std::string format;
    std::string template_string;
    timestamp_units units;
    format_program* d_prog;
    format_item* d_items;

    std::map<char,int8_t> specifiers = {
        {'a',0}, {'A',0},
        {'w',1},
        {'b',0}, {'B',0},
        {'Y',4},{'y',2}, {'m',2}, {'d',2},
        {'H',2},{'I',2},{'M',2},{'S',2},{'f',6},
        {'p',2},{'z',5},{'Z',3},
        {'j',3},{'U',2},{'W',2}
    };

    format_compiler( const char* format, timestamp_units units )
    : format(format), units(units), d_prog(nullptr), d_items(nullptr) {}

    ~format_compiler()
    {
        if( !d_prog )
            RMM_FREE(d_prog,0);
        if( !d_items )
            RMM_FREE(d_items,0);
    }

    format_program* compile_to_device()
    {
        const char* str = format.c_str();
        auto length = format.length();
        while( length > 0 )
        {
            char ch = *str++;
            length--;
            if( ch!='%' )
            {
                items.push_back(format_item::new_delimiter(ch));
                template_string.append(1,ch);
                continue;
            }
            CUDF_EXPECTS( length>0, "Unfinished specifier in timestamp format" );

            ch = *str++;
            length--;
            if( ch=='%' )  // escaped % char
            {
                items.push_back(format_item::new_delimiter(ch));
                template_string.append(1,ch);
                continue;
            }
            if( specifiers.find(ch)==specifiers.end() )
            {
                CUDF_FAIL( "Invalid specifier" ); // show ch in here somehow
            }

            int8_t spec_length = specifiers[ch];
            if( ch=='f' )
            {
                // adjust spec_length based on units
                if( units==timestamp_units::ms )
                    spec_length = 3;
                else if( units==timestamp_units::ns )
                    spec_length = 9;
            }
            items.push_back(format_item::new_specifier(ch,spec_length));
            template_string.append((size_t)spec_length,ch);
        }
        // create program in device memory
        auto buffer_size = items.size() * sizeof(format_item);
        RMM_TRY(RMM_ALLOC(&d_items, buffer_size, 0));
        CUDA_TRY( cudaMemcpyAsync(d_items, items.data(), buffer_size, cudaMemcpyHostToDevice));
        format_program h_prog{d_items,items.size()};
        RMM_TRY(RMM_ALLOC(&d_prog, sizeof(format_program),0));
        CUDA_TRY( cudaMemcpyAsync(d_prog,&h_prog,sizeof(format_program),cudaMemcpyHostToDevice));
        return d_prog;
    }

    // this call is only valid after compile_to_device is called
    size_type template_bytes() const { return static_cast<size_type>(template_string.size()); }
};


// this parses date/time characters into a timestamp integer
struct parse_datetime
{
    const column_device_view d_strings;
    const format_program* d_prog;
    timestamp_units units;

    //
    __device__ int32_t str2int( const char* str, size_type bytes )
    {
        const char* ptr = str;
        int32_t value = 0;
        for( unsigned int idx=0; idx < bytes; ++idx )
        {
            char chr = *ptr++;
            if( chr < '0' || chr > '9' )
                break;
            value = (value * 10) + static_cast<int32_t>(chr - '0');
        }
        return value;
    }

    // only supports ascii
    __device__ int strcmp_ignore_case( const char* str1, const char* str2, size_t length )
    {
        for( size_t idx=0; idx < length; ++idx )
        {
            char ch1 = *str1;
            if( ch1 >= 'a' && ch1 <= 'z' )
                ch1 = ch1 - 'a' + 'A';
            char ch2 = *str2;
            if( ch2 >= 'a' && ch2 <= 'z' )
                ch2 = ch2 - 'a' + 'A';
            if( ch1==ch2 )
                continue;
            return static_cast<int>(ch1 - ch2);
        }
        return 0;
    }

    // walk the prog to read the datetime string
    // returns 0 if all ok
    __device__ int parse_into_parts( string_view d_string, int32_t* timeparts )
    {
        auto count = d_prog->count;
        auto items = d_prog->items;
        auto ptr = d_string.data();
        auto length = d_string.size_bytes();
        for( size_t idx=0; idx < count; ++idx )
        {
            auto item = items[idx];
            if(item.item_type==false)
            {   // static character we'll just skip;
                // consume item.length bytes from string
                ptr += item.length;
                length -= item.length;
                continue;
            }
            if( length < item.length )
                return 1;

            // special logic for each specifier
            switch(item.specifier)
            {
                case 'Y':
                    timeparts[TP_YEAR] = str2int(ptr,item.length);
                    break;
                case 'y':
                    timeparts[TP_YEAR] = str2int(ptr,item.length)+1900;
                    break;
                case 'm':
                    timeparts[TP_MONTH] = str2int(ptr,item.length);
                    break;
                case 'd':
                case 'j':
                    timeparts[TP_DAY] = str2int(ptr,item.length);
                    break;
                case 'H':
                case 'I':
                    timeparts[TP_HOUR] = str2int(ptr,item.length);
                    break;
                case 'M':
                    timeparts[TP_MINUTE] = str2int(ptr,item.length);
                    break;
                case 'S':
                    timeparts[TP_SECOND] = str2int(ptr,item.length);
                    break;
                case 'f':
                    timeparts[TP_SUBSECOND] = str2int(ptr,item.length);
                    break;
                case 'p':
                    if( timeparts[TP_HOUR] <= 12 && strcmp_ignore_case(ptr,"PM",2)==0 ) // strncasecmp
                        timeparts[TP_HOUR] += 12;
                    break;
                case 'z':
                {
                    int sign = *ptr=='-' ? -1:1;
                    int hh = str2int(ptr+1,2);
                    int mm = str2int(ptr+3,2);
                    // ignoring the rest for now
                    // item.length has how many chars we should read
                    timeparts[TP_TZ_MINUTES] = sign * ((hh*60)+mm);
                    break;
                }
                case 'Z':
                    //if( strcmp_ignore_case(ptr,"UTC",3)!=0 )
                    //    return 2;
                    break;
                default:
                    return 3;
            }
            ptr += item.length;
            length -= item.length;
        }
        return 0;
    }

    __device__ int64_t timestamp_from_parts( int32_t* timeparts, timestamp_units units )
    {
        auto year = timeparts[TP_YEAR];
        if( units==timestamp_units::years )
            return year - 1970;
        auto month = timeparts[TP_MONTH];
        if( units==timestamp_units::months )
            return ((year-1970) * 12) + (month-1); // months are 1-12, need to 0-base it here
        auto day = timeparts[TP_DAY];
        // The months are shifted so that March is the starting month and February
        // (possible leap day in it) is the last month for the linear calculation
        year -= (month <= 2) ? 1 : 0;
        // date cycle repeats every 400 years (era)
        constexpr int32_t erasInDays = 146097;
        constexpr int32_t erasInYears = (erasInDays / 365);
        auto era = (year >= 0 ? year : year - 399) / erasInYears;
        auto yoe = year - era * erasInYears;
        auto doy = month==0 ? day : ((153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1);
        auto doe = (yoe * 365) + (yoe / 4) - (yoe / 100) + doy;
        int32_t days = (era * erasInDays) + doe - 719468; // 719468 = days from 0000-00-00 to 1970-03-01
        if( units==timestamp_units::days )
            return days;

        auto tzadjust = timeparts[TP_TZ_MINUTES]; // in minutes
        auto hour = timeparts[TP_HOUR];
        if( units==timestamp_units::hours )
            return (days*24L) + hour + (tzadjust/60);

        auto minute = timeparts[TP_MINUTE];
        if( units==timestamp_units::minutes )
            return static_cast<int64_t>(days * 24L * 60L) + (hour * 60L) + minute + tzadjust;

        auto second = timeparts[TP_SECOND];
        int64_t timestamp = (days * 24L * 3600L) + (hour * 3600L) + (minute * 60L) + second + (tzadjust*60);
        if( units==timestamp_units::seconds )
            return timestamp;

        auto subsecond = timeparts[TP_SUBSECOND];
        if( units==timestamp_units::ms )
            timestamp *= 1000L;
        else if( units==timestamp_units::us )
            timestamp *= 1000000L;
        else if( units==timestamp_units::ns )
            timestamp *= 1000000000L;
        timestamp += subsecond;
        return timestamp;
    }

     __device__ int64_t operator()(size_type idx)
    {
        if( d_strings.is_null(idx) )
            return 0;
        string_view d_str = d_strings.element<string_view>(idx);
        if( d_str.empty() )
            return 0;
        //
        int32_t timeparts[TP_ARRAYSIZE] = {0,1,1}; // month and day are 1-based
        if( parse_into_parts(d_str,timeparts) )
            return 0; // unexpected parse case
        //
        return timestamp_from_parts(timeparts,units);
    }
};

// convert cudf type to timestamp units
struct dispatch_timestamp_to_units_fn
{
    template <typename T>
    timestamp_units operator()()
    {
        CUDF_FAIL("Invalid type for timestamp conversion.");
    }
};

template<>
timestamp_units dispatch_timestamp_to_units_fn::operator()<cudf::timestamp_D>() { return timestamp_units::days; }
template<>
timestamp_units dispatch_timestamp_to_units_fn::operator()<cudf::timestamp_s>() { return timestamp_units::seconds; }
template<>
timestamp_units dispatch_timestamp_to_units_fn::operator()<cudf::timestamp_ms>() { return timestamp_units::ms; }
template<>
timestamp_units dispatch_timestamp_to_units_fn::operator()<cudf::timestamp_us>() { return timestamp_units::us; }
template<>
timestamp_units dispatch_timestamp_to_units_fn::operator()<cudf::timestamp_ns>() { return timestamp_units::ns; }

} // namespace

//
std::unique_ptr<cudf::column> to_timestamps( strings_column_view strings,
                                             data_type timestamp_type,
                                             std::string format,
                                             rmm::mr::device_memory_resource* mr,
                                             cudaStream_t stream )
{
    size_type strings_count = strings.size();
    if( strings_count==0 )
        return make_timestamp_column( timestamp_type, 0 );

    CUDF_EXPECTS( !format.empty(), "Format parameter must not be empty.");
    timestamp_units units = cudf::experimental::type_dispatcher( timestamp_type, dispatch_timestamp_to_units_fn() );

    format_compiler compiler(format.c_str(),units);
    format_program* d_prog = compiler.compile_to_device();

    auto execpol = rmm::exec_policy(stream);
    auto strings_column = column_device_view::create(strings.parent(), stream);
    auto d_column = *strings_column;

    // copy null mask
    rmm::device_buffer null_mask;
    cudf::size_type null_count = d_column.null_count();
    if( d_column.nullable() )
        null_mask = rmm::device_buffer( d_column.null_mask(),
                                        bitmask_allocation_size_bytes(strings_count),
                                        stream, mr);
    // create output column
    auto results = std::make_unique<cudf::column>( timestamp_type, strings_count,
        rmm::device_buffer(strings_count * size_of(timestamp_type), stream, mr),
        null_mask, null_count);
    auto results_view = results->mutable_view();
    auto d_results = results_view.data<int64_t>();
    // set the values
    thrust::transform( execpol->on(stream),
        thrust::make_counting_iterator<size_type>(0),
        thrust::make_counting_iterator<size_type>(strings_count),
        d_results, parse_datetime{d_column,d_prog,units} );
    results->set_null_count(null_count);
    return results;
}

namespace
{
// converts a timestamp into date-time string
struct datetime_formatter
{
    const column_device_view d_timestamps;
    const format_program* d_prog;
    timestamp_units units;
    const int32_t* d_offsets;
    char* d_chars;

    // divide timestamp integer into time components (year, month, day, etc)
    // TODO call the simt::std::chrono methods here instead when the are ready
    __device__ void dissect_timestamp( int64_t timestamp, int32_t* timeparts )
    {
        if( units==timestamp_units::years )
        {
            timeparts[TP_YEAR] = static_cast<int32_t>(timestamp) + 1970;
            timeparts[TP_MONTH] = 1;
            timeparts[TP_DAY] = 1;
            return;
        }

        if( units==timestamp_units::months )
        {
            int32_t month = static_cast<int32_t>(timestamp % 12);
            int32_t year = static_cast<int32_t>(timestamp / 12) + 1970;
            timeparts[TP_YEAR] = year;
            timeparts[TP_MONTH] = month +1; // months start at 1 and not 0
            timeparts[TP_DAY] = 1;
            return;
        }

        // first, convert to days so we can handle months, leap years, etc.
        int32_t days = static_cast<int32_t>(timestamp); // default to days
        if( units==timestamp_units::hours )
            days = static_cast<int32_t>(timestamp / 24L);
        else if( units==timestamp_units::minutes )
            days = static_cast<int32_t>(timestamp / 1440L);  // 24*60
        else if( units==timestamp_units::seconds )
            days = static_cast<int32_t>(timestamp / 86400L); // 24*60*60
        else if( units==timestamp_units::ms )
            days = static_cast<int32_t>(timestamp / 86400000L);
        else if( units==timestamp_units::us )
            days = static_cast<int32_t>(timestamp / 86400000000L);
        else if( units==timestamp_units::ns )
            days = static_cast<int32_t>(timestamp / 86400000000000L);
        days = days + 719468; // 719468 is days between 0000-00-00 and 1970-01-01

        constexpr int32_t daysInEra = 146097; // (400*365)+97
        constexpr int32_t daysInCentury = 36524; // (100*365) + 24;
        constexpr int32_t daysIn4Years = 1461; // (4*365) + 1;
        constexpr int32_t daysInYear = 365;
        // day offsets for each month:   Mar Apr May June July  Aug  Sep  Oct  Nov  Dec  Jan  Feb
        const int32_t monthDayOffset[] = { 0, 31, 61, 92, 122, 153, 184, 214, 245, 275, 306, 337, 366 };

        // code logic handles leap years in chunks: 400y,100y,4y,1y
        int32_t year = 400 * (days / daysInEra);
        days = days % daysInEra;
        int32_t leapy = days / daysInCentury;
        days = days % daysInCentury;
        if( leapy==4 )
        {   // landed exactly on a leap century
            days += daysInCentury;
            --leapy;
        }
        year += 100 * leapy;
        year += 4 * (days / daysIn4Years);
        days = days % daysIn4Years;
        leapy = days / daysInYear;
        days = days % daysInYear;
        if( leapy==4 )
        {   // landed exactly on a leap year
            days += daysInYear;
            --leapy;
        }
        year += leapy;

        //
        int32_t month = 12;
        for( int32_t idx=0; idx < month; ++idx )
        {   // find the month
            if( days < monthDayOffset[idx+1] )
            {
                month = idx;
                break;
            }
        }
        int32_t day = days - monthDayOffset[month] +1; // compute day of month
        if( month >= 10 )
            ++year;
        month = ((month + 2) % 12) +1; // adjust Jan-Mar offset

        timeparts[TP_YEAR] = year;
        timeparts[TP_MONTH] = month;
        timeparts[TP_DAY] = day;
        if( units==timestamp_units::days )
            return;

        // done with date
        // now work on time
        int64_t hour = timestamp, minute = timestamp, second = timestamp;
        if( units==timestamp_units::hours )
        {
            timeparts[TP_HOUR] = static_cast<int32_t>(hour % 24);
            return;
        }
        hour = hour / 60;
        if( units==timestamp_units::minutes )
        {
            timeparts[TP_HOUR] = static_cast<int32_t>(hour % 24);
            timeparts[TP_MINUTE] = static_cast<int32_t>(minute % 60);
            return;
        }
        hour = hour / 60;
        minute = minute / 60;
        if( units==timestamp_units::seconds )
        {
            timeparts[TP_HOUR] = static_cast<int32_t>(hour % 24);
            timeparts[TP_MINUTE] = static_cast<int32_t>(minute % 60);
            timeparts[TP_SECOND] = static_cast<int32_t>(second % 60);
            return;
        }
        hour = hour / 1000;
        minute = minute / 1000;
        second = second / 1000;
        if( units==timestamp_units::ms )
        {
            timeparts[TP_HOUR] = static_cast<int32_t>(hour % 24);
            timeparts[TP_MINUTE] = static_cast<int32_t>(minute % 60);
            timeparts[TP_SECOND] = static_cast<int32_t>(second % 60);
            timeparts[TP_SUBSECOND] = static_cast<int32_t>(timestamp % 1000);
            return;
        }
        hour = hour / 1000;
        minute = minute / 1000;
        second = second / 1000;
        if( units==timestamp_units::us )
        {
            timeparts[TP_HOUR] = static_cast<int32_t>(hour % 24);
            timeparts[TP_MINUTE] = static_cast<int32_t>(minute % 60);
            timeparts[TP_SECOND] = static_cast<int32_t>(second % 60);
            timeparts[TP_SUBSECOND] = static_cast<int32_t>(timestamp % 1000000);
            return;
        }
        hour = hour / 1000;
        minute = minute / 1000;
        second = second / 1000;
        timeparts[TP_HOUR] = static_cast<int32_t>(hour % 24);
        timeparts[TP_MINUTE] = static_cast<int32_t>(minute % 60);
        timeparts[TP_SECOND] = static_cast<int32_t>(second % 60);
        timeparts[TP_SUBSECOND] = static_cast<int32_t>(timestamp % 1000000000);
    }

    // utility to create 0-padded integers (up to 9 bytes)
    __device__ char* int2str( char* str, int len, int val )
    {
        char tmpl[9] = {'0','0','0','0','0','0','0','0','0'};
        char* ptr = tmpl;
        while( val > 0 )
        {
            int digit = val % 10;
            *ptr++ = '0' + digit;
            val = val / 10;
        }
        ptr = tmpl + len-1;
        while( len > 0 )
        {
            *str++ = *ptr--;
            --len;
        }
        return str;
    }

    __device__ char* format_from_parts( int32_t* timeparts, char* ptr )
    {
        auto count = d_prog->count;
        auto d_items = d_prog->items;
        for( size_t idx=0; idx < count; ++idx )
        {
            auto item = d_items[idx];
            if(item.item_type==false)
            {
                *ptr++ = item.literal;
                continue;
            }
            // special logic for each specifier
            switch(item.specifier)
            {
                case 'Y': // 4-digit year
                    ptr = int2str(ptr,item.length,timeparts[TP_YEAR]);
                    break;
                case 'y': // 2-digit year
                    ptr = int2str(ptr,item.length,timeparts[TP_YEAR]-1900);
                    break;
                case 'm': // month
                    ptr = int2str(ptr,item.length,timeparts[TP_MONTH]);
                    break;
                case 'd': // day of month
                case 'j': // day of year
                    ptr = int2str(ptr,item.length,timeparts[TP_DAY]);
                    break;
                case 'H': // 24-hour
                    ptr = int2str(ptr,item.length,timeparts[TP_HOUR]);
                    break;
                case 'I': // 12-hour
                    ptr = int2str(ptr,item.length,timeparts[TP_HOUR] % 12);
                    break;
                case 'M': // minute
                    ptr = int2str(ptr,item.length,timeparts[TP_MINUTE]);
                    break;
                case 'S': // second
                    ptr = int2str(ptr,item.length,timeparts[TP_SECOND]);
                    break;
                case 'f': // sub-second
                    ptr = int2str(ptr,item.length,timeparts[TP_SUBSECOND]);
                    break;
                case 'p': // am or pm
                    if( timeparts[TP_HOUR] <= 12 )
                        memcpy(ptr,"AM",2);
                    else
                        memcpy(ptr,"PM",2);
                    ptr += 2;
                    break;
                case 'z': // timezone
                    break; // do nothing for this one
                case 'Z':
                    memcpy(ptr,"UTC",3);
                    ptr += 3;
                    break;
                default: // ignore everything else
                    break;
            }
        }
        return ptr;
    }

    __device__ void operator()( size_type idx )
    {
        if( d_timestamps.is_null(idx) )
            return;
        auto timestamp = d_timestamps.element<int64_t>(idx);
        int32_t timeparts[TP_ARRAYSIZE] = {0};
        dissect_timestamp(timestamp,timeparts);
        // convert to characters
        char* d_buffer = d_chars + d_offsets[idx];
        format_from_parts(timeparts,d_buffer);
    }
};

} // namespace


//
std::unique_ptr<cudf::column> from_timestamps( column_view timestamps,
                                               std::string format,
                                               rmm::mr::device_memory_resource* mr,
                                               cudaStream_t stream )
{
    size_type strings_count = timestamps.size();
    if( strings_count == 0 )
        return detail::make_empty_strings_column(mr,stream);

    CUDF_EXPECTS( !format.empty(), "Format parameter must not be empty.");
    timestamp_units units = cudf::experimental::type_dispatcher( timestamps.type(), dispatch_timestamp_to_units_fn() );

    format_compiler compiler(format.c_str(),units);
    format_program* d_prog = compiler.compile_to_device();

    auto execpol = rmm::exec_policy(stream);
    auto column = column_device_view::create(timestamps, stream);
    auto d_column = *column;

    // copy null mask
    rmm::device_buffer null_mask;
    cudf::size_type null_count = d_column.null_count();
    if( d_column.nullable() )
        null_mask = rmm::device_buffer( d_column.null_mask(),
                                        bitmask_allocation_size_bytes(strings_count),
                                        stream, mr);
    // Each string will be the same number of bytes which can be determined
    // directly from the format string.
    auto d_str_bytes = compiler.template_bytes(); // size in bytes of each string
    // build offsets column
    auto offsets_transformer_itr = thrust::make_transform_iterator( thrust::make_counting_iterator<size_type>(0),
        [d_column, d_str_bytes] __device__ (size_type idx) { return ( d_column.is_null(idx) ? 0 : d_str_bytes ); });
    auto offsets_column = detail::make_offsets_child_column(offsets_transformer_itr,
                                                            offsets_transformer_itr+strings_count,
                                                            mr, stream);
    auto offsets_view = offsets_column->view();
    auto d_new_offsets = offsets_view.template data<int32_t>();

    // build chars column
    size_type bytes = thrust::device_pointer_cast(d_new_offsets)[strings_count];
    auto chars_column = detail::create_chars_child_column( strings_count, null_count, bytes, mr, stream );
    auto chars_view = chars_column->mutable_view();
    auto d_chars = chars_view.template data<char>();
    thrust::for_each_n(execpol->on(0), thrust::make_counting_iterator<cudf::size_type>(0), strings_count,
        datetime_formatter{d_column, d_prog, units, d_new_offsets, d_chars});
    //
    return make_strings_column(strings_count, std::move(offsets_column), std::move(chars_column),
                               null_count, std::move(null_mask), stream, mr);
}


} // namespace strings
} // namespace cudf
