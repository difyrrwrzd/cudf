/* Copyright 2018 NVIDIA Corporation.  All rights reserved. */

#include <thrust/device_vector.h>
#include <thrust/tuple.h>
#include <thrust/execution_policy.h>
#include <thrust/copy.h>
#include <thrust/sort.h>
#include <thrust/binary_search.h>
#include <thrust/unique.h>
#include <thrust/sequence.h>
#include <thrust/iterator/counting_iterator.h>
#include <thrust/iterator/constant_iterator.h>
#include <thrust/reduce.h>
#include <thrust/functional.h>

#include <iostream>
#include <vector>
#include <tuple>
#include <iterator>
#include <type_traits>
#include <numeric>
#include <unordered_map>
//

#include <cassert>
#include <cmath>

//

#include <gdf/gdf.h>
#include <gdf/utils.h>
#include <gdf/errorutils.h>
#include <gdf/cffi/functions.h>

#include "gtest/gtest.h"

#include "sqls_rtti_comp.hpp"

template<typename T>
using Vector = thrust::device_vector<T>;

///using IndexT = int;//okay...
using IndexT = size_t;

template<typename T, typename Allocator, template<typename, typename> class Vector>
__host__ 
void print_v(const Vector<T, Allocator>& v, std::ostream& os)
{
  thrust::copy(v.begin(), v.end(), std::ostream_iterator<T>(os,","));
  os<<"\n";
}

template<typename T,
	 typename Allocator,
	 template<typename, typename> class Vector>
__host__
void print_v(const Vector<T, Allocator>& v, typename Vector<T, Allocator>::const_iterator pos, std::ostream& os)
{ 
  thrust::copy(v.begin(), pos, std::ostream_iterator<T>(os,","));//okay
  os<<"\n";
}

template<typename T,
	 typename Allocator,
	 template<typename, typename> class Vector>
__host__
void print_v(const Vector<T, Allocator>& v, size_t n, std::ostream& os)
{ 
  thrust::copy_n(v.begin(), n, std::ostream_iterator<T>(os,","));//okay
  os<<"\n";
}

template<typename T>
bool compare(const Vector<T>& d_v, const std::vector<T>& baseline, T eps)
{
  size_t n = baseline.size();//because d_v might be larger
  
  std::vector<T> h_v(n);
  std::vector<int> h_b(n, 0);

  thrust::copy_n(d_v.begin(), n, h_v.begin());//D-H okay...
  
  return std::inner_product(h_v.begin(), h_v.end(),
			    baseline.begin(),
			    true,
			    [](bool b1, bool b2){
			      return b1 && b2;
			    },
			    [eps](T v1, T v2){
			      return (std::abs(v1-v2) < eps);
			    });
}

TEST(HashGroupByTest, max)
{

  std::vector<int64_t> groupby_column{ 1, 1, 2, 2, 3, 3, 4 };
  std::vector<double>  aggregation_column{2., 3., 5., 2., 6., 6., 7.};

  const size_t size = groupby_column.size();

  thrust::device_vector<int64_t> d_groupby_column(groupby_column);
  thrust::device_vector<double> d_aggregation_column(aggregation_column);

  gdf_column gdf_groupby_column;
  gdf_groupby_column.data = static_cast<void*>(d_groupby_column.data().get());
  gdf_groupby_column.size = size;
  gdf_groupby_column.dtype = GDF_INT64;

  gdf_column gdf_aggregation_column;
  gdf_aggregation_column.data = static_cast<void*>(d_aggregation_column.data().get());
  gdf_aggregation_column.size = size;
  gdf_aggregation_column.dtype = GDF_FLOAT64;

  thrust::device_vector<int64_t> groupby_result{size};
  thrust::device_vector<double> aggregation_result{size};

  gdf_column gdf_groupby_result;
  gdf_groupby_result.data = static_cast<void*>(groupby_result.data().get());
  gdf_groupby_result.size = size;
  gdf_groupby_result.dtype = GDF_INT64;

  gdf_column gdf_aggregation_result;
  gdf_aggregation_result.data = static_cast<void*>(aggregation_result.data().get());
  gdf_aggregation_result.size = size;
  gdf_aggregation_result.dtype = GDF_FLOAT64;

  // Determines if the final result is sorted
  int flag_sort_result = 1;

  gdf_context context{0, GDF_HASH, 0, flag_sort_result};

  gdf_column * p_gdf_groupby_column = &gdf_groupby_column;

  gdf_column * p_gdf_groupby_result = &gdf_groupby_result;

  gdf_group_by_max((int) 1,      
                   &p_gdf_groupby_column,
                   &gdf_aggregation_column,
                   nullptr,         
                   &p_gdf_groupby_result,
                   &gdf_aggregation_result,
                   &context);


  // Make sure results are sorted
  if(1 == flag_sort_result){
    std::map<int64_t, double> expected_results { {1,3.}, {2,5.}, {3,6.}, {4,7.} };
    ASSERT_EQ(expected_results.size(), gdf_groupby_result.size);
    ASSERT_EQ(expected_results.size(), gdf_aggregation_result.size);

    int i = 0;
    for(auto kv : expected_results){
      EXPECT_EQ(kv.first, groupby_result[++i]);
      EXPECT_EQ(kv.second, aggregation_result[i]);
    }
  }
  else
  {
    std::unordered_map<int64_t, double> expected_results { {1,3.}, {2,5.}, {3,6.}, {4,7.} };
    ASSERT_EQ(expected_results.size(), gdf_groupby_result.size);
    ASSERT_EQ(expected_results.size(), gdf_aggregation_result.size);

    for(int i = 0; i < gdf_aggregation_result.size; ++i){
      const int64_t key = groupby_result[i];
      const double value = aggregation_result[i];
      auto found = expected_results.find(groupby_result[i]);
      EXPECT_EQ(found->first, key);
      EXPECT_EQ(found->second, value);
    }
  }
}

TEST(gdf_group_by_sum, UsageTestSum)
{
  std::vector<int> vc1{1,1,1,1,1,1};
  std::vector<int> vi1{1,3,3,5,5,0};
  std::vector<double> vd1{12., 13., 13., 17., 17., 17};

  Vector<int> dc1 = vc1;
  Vector<int> di1 = vi1;
  Vector<double> dd1 = vd1;
  
  size_t sz = dc1.size();
  assert( sz > 0 );
  assert( sz == di1.size() );
  assert( sz == dd1.size() );
 

  Vector<IndexT> d_indx(sz, 0);
  Vector<IndexT> d_keys(sz, 0);
  Vector<IndexT> d_vals(sz, 0);

  size_t ncols = 3;
  size_t& nrows = sz;

  Vector<void*> d_cols(ncols, nullptr);
  Vector<int>   d_types(ncols, 0);

  std::vector<gdf_column> v_gdf_cols(ncols);
  v_gdf_cols[0].data = static_cast<void*>(dc1.data().get());
  v_gdf_cols[0].size = nrows;
  v_gdf_cols[0].dtype = GDF_INT32;

  v_gdf_cols[1].data = static_cast<void*>(di1.data().get());
  v_gdf_cols[1].size = nrows;
  v_gdf_cols[1].dtype = GDF_INT32;

  v_gdf_cols[2].data = static_cast<void*>(dd1.data().get());
  v_gdf_cols[2].size = nrows;
  v_gdf_cols[2].dtype = GDF_FLOAT64;

  gdf_column c_agg;
  gdf_column c_vout;

  Vector<double> d_outd(sz, 0);

  c_agg.dtype = GDF_FLOAT64;
  c_agg.data = dd1.data().get();
  c_agg.size = nrows;

  c_vout.dtype = GDF_FLOAT64;
  c_vout.data = d_outd.data().get();
  c_vout.size = nrows;

  size_t n_group = 0;
  //int flag_sorted = 0;

  std::cout<<"aggregate = sum on column:\n";
  print_v(dd1, std::cout);

  //input
  //{
  gdf_context ctxt{0, GDF_SORT, 0, 0};
  std::vector<gdf_column*> v_pcols(ncols);
  for(int i = 0; i < ncols; ++i)
    {
      v_pcols[i] = &v_gdf_cols[i];
    }
  gdf_column** cols = &v_pcols[0];//pointer semantic (2);
  //}

  //output:
  //{
  Vector<int32_t> d_vc_out(nrows);
  Vector<int32_t> d_vi_out(nrows);
  Vector<double> d_vd_out(nrows);
    
  std::vector<gdf_column> v_gdf_cols_out(ncols);
  v_gdf_cols_out[0].data = d_vc_out.data().get();
  v_gdf_cols_out[0].dtype = GDF_INT32;
  v_gdf_cols_out[0].size = nrows;

  v_gdf_cols_out[1].data = d_vi_out.data().get();
  v_gdf_cols_out[1].dtype = GDF_INT32;
  v_gdf_cols_out[1].size = nrows;

  v_gdf_cols_out[2].data = d_vd_out.data().get();
  v_gdf_cols_out[2].dtype = GDF_FLOAT64;
  v_gdf_cols_out[2].size = nrows;

  std::vector<gdf_column*> h_cols_out(ncols);
  for(int i=0; i<ncols; ++i)
    h_cols_out[i] = &v_gdf_cols_out[i];//
  
  gdf_column** cols_out = &h_cols_out[0];//pointer semantics (2)

  d_keys.assign(nrows, 0);
  gdf_column c_indx;
  c_indx.data = d_keys.data().get();
  c_indx.size = nrows;
  c_indx.dtype = GDF_INT32;
  //}

  ///EXPECT_EQ( 1, 1);
    
  gdf_group_by_sum((int)ncols,      // # columns
                   cols,            //input cols
                   &c_agg,          //column to aggregate on
                   &c_indx,         //if not null return indices of re-ordered rows
                   cols_out,        //if not null return the grouped-by columns
                   &c_vout,         //aggregation result
                   &ctxt);          //struct with additional info;
    
  n_group = c_vout.size;
  const size_t n_rows_expected = 4;
  const double deps = 1.e-8;
  const int ieps = 1;
  const IndexT szeps = 1;
  
  EXPECT_EQ( n_group, n_rows_expected ) << "GROUP-BY SUM returns unexpected #rows:" << n_group;

  //EXPECTED:
  //d_vc_out: 1,1,1,1,
  //d_vi_out: 0,1,3,5
  //d_vd_out: 17,12,13,17,
  vc1 = {1,1,1,1};
  vi1 = {0,1,3,5};
  vd1 = {17,12,13,17};

  bool flag = compare(d_vc_out, vc1, ieps);
  EXPECT_EQ( flag, true ) << "column 1 GROUP-BY returns unexpected result";

  flag = compare(d_vi_out, vi1, ieps);
  EXPECT_EQ( flag, true ) << "column 2 GROUP-BY returns unexpected result";

  flag = compare(d_vd_out, vd1, deps);
  EXPECT_EQ( flag, true ) << "column 3 GROUP-BY returns unexpected result";
  
  //d_keys: 5,0,2,4,
  //d_outd: 17,12,26,34,

  std::vector<IndexT> vk{5,0,2,4};
  vd1 = {17,12,26,34};

  flag = compare(d_keys, vk, szeps);
  EXPECT_EQ( flag, true ) << "GROUP-BY row indices return unexpected result";

  flag = compare(d_outd, vd1, deps);
  EXPECT_EQ( flag, true ) << "GROUP-BY SUM aggregation returns unexpected result";
}

TEST(gdf_group_by_count, UsageTestCount)
{
  std::vector<int> vc1{1,1,1,1,1,1};
  std::vector<int> vi1{1,3,3,5,5,0};
  std::vector<double> vd1{12., 13., 13., 17., 17., 17};

  Vector<int> dc1 = vc1;
  Vector<int> di1 = vi1;
  Vector<double> dd1 = vd1;
  
  size_t sz = dc1.size();
  assert( sz > 0 );
  assert( sz == di1.size() );
  assert( sz == dd1.size() );
 
  Vector<IndexT> d_indx(sz, 0);
  Vector<IndexT> d_keys(sz, 0);
  Vector<IndexT> d_vals(sz, 0);

  size_t ncols = 3;
  size_t& nrows = sz;

  Vector<void*> d_cols(ncols, nullptr);
  Vector<int>   d_types(ncols, 0);

  std::vector<gdf_column> v_gdf_cols(ncols);
  v_gdf_cols[0].data = static_cast<void*>(dc1.data().get());
  v_gdf_cols[0].size = nrows;
  v_gdf_cols[0].dtype = GDF_INT32;

  v_gdf_cols[1].data = static_cast<void*>(di1.data().get());
  v_gdf_cols[1].size = nrows;
  v_gdf_cols[1].dtype = GDF_INT32;

  v_gdf_cols[2].data = static_cast<void*>(dd1.data().get());
  v_gdf_cols[2].size = nrows;
  v_gdf_cols[2].dtype = GDF_FLOAT64;

  gdf_column c_agg;
  gdf_column c_vout;

  Vector<double> d_outd(sz, 0);

  c_agg.dtype = GDF_FLOAT64;
  c_agg.data = dd1.data().get();
  c_agg.size = nrows;

  c_vout.dtype = GDF_INT32;
  c_vout.data = d_vals.data().get();
  c_vout.size = nrows;

  size_t n_group = 0;
  //int flag_sorted = 0;

  std::cout<<"aggregate = count on column:\n";
  print_v(dd1, std::cout);

  //input
  //{
  gdf_context ctxt{0, GDF_SORT, 0, 0};
  std::vector<gdf_column*> v_pcols(ncols);
  for(int i = 0; i < ncols; ++i)
    {
      v_pcols[i] = &v_gdf_cols[i];
    }
  gdf_column** cols = &v_pcols[0];//pointer semantic (2);
  //}

  //output:
  //{
  Vector<int32_t> d_vc_out(nrows);
  Vector<int32_t> d_vi_out(nrows);
  Vector<double> d_vd_out(nrows);
    
  std::vector<gdf_column> v_gdf_cols_out(ncols);
  v_gdf_cols_out[0].data = d_vc_out.data().get();
  v_gdf_cols_out[0].dtype = GDF_INT32;
  v_gdf_cols_out[0].size = nrows;

  v_gdf_cols_out[1].data = d_vi_out.data().get();
  v_gdf_cols_out[1].dtype = GDF_INT32;
  v_gdf_cols_out[1].size = nrows;

  v_gdf_cols_out[2].data = d_vd_out.data().get();
  v_gdf_cols_out[2].dtype = GDF_FLOAT64;
  v_gdf_cols_out[2].size = nrows;

  std::vector<gdf_column*> h_cols_out(ncols);
  for(int i=0; i<ncols; ++i)
    h_cols_out[i] = &v_gdf_cols_out[i];//
  
  gdf_column** cols_out = &h_cols_out[0];//pointer semantics (2)

  d_keys.assign(nrows, 0);
  gdf_column c_indx;
  c_indx.data = d_keys.data().get();
  c_indx.size = nrows;
  c_indx.dtype = GDF_INT32;
  //}

  gdf_group_by_count((int)ncols,      // # columns
                   cols,            //input cols
                   &c_agg,          //column to aggregate on
                   &c_indx,         //if not null return indices of re-ordered rows
                   cols_out,        //if not null return the grouped-by columns
                   &c_vout,         //aggregation result
                   &ctxt);          //struct with additional info;
    
  n_group = c_vout.size;
  const size_t n_rows_expected = 4;
  const double deps = 1.e-8;
  const int ieps = 1;
  const IndexT szeps = 1;
  
  EXPECT_EQ( n_group, n_rows_expected ) << "GROUP-BY COUNT returns unexpected #rows:" << n_group;

  //EXPECTED:
  //d_vc_out: 1,1,1,1,
  //d_vi_out: 0,1,3,5
  //d_vd_out: 17,12,13,17,
  vc1 = {1,1,1,1};
  vi1 = {0,1,3,5};
  vd1 = {17,12,13,17};

  bool flag = compare(d_vc_out, vc1, ieps);
  EXPECT_EQ( flag, true ) << "column 1 GROUP-BY returns unexpected result";

  flag = compare(d_vi_out, vi1, ieps);
  EXPECT_EQ( flag, true ) << "column 2 GROUP-BY returns unexpected result";

  flag = compare(d_vd_out, vd1, deps);
  EXPECT_EQ( flag, true ) << "column 3 GROUP-BY returns unexpected result";
  
  //d_keys: 5,0,2,4,
  //d_vals: 1,1,2,2,

  std::vector<IndexT> vk{5,0,2,4};
  std::vector<IndexT> vals{1,1,2,2};

  flag = compare(d_keys, vk, szeps);
  EXPECT_EQ( flag, true ) << "GROUP-BY row indices return unexpected result";

  flag = compare(d_vals, vals, szeps);
  EXPECT_EQ( flag, true ) << "GROUP-BY COUNT aggregation returns unexpected result";
}

TEST(gdf_group_by_avg, UsageTestAvg)
{
  std::vector<int> vc1{1,1,1,1,1,1};
  std::vector<int> vi1{1,3,3,5,5,0};
  std::vector<double> vd1{12., 13., 13., 17., 17., 17};

  Vector<int> dc1 = vc1;
  Vector<int> di1 = vi1;
  Vector<double> dd1 = vd1;

  size_t sz = dc1.size();
  assert( sz == di1.size() );
  assert( sz == dd1.size() );
    
  Vector<IndexT> d_indx(sz, 0);
  Vector<IndexT> d_keys(sz, 0);
  Vector<IndexT> d_vals(sz, 0);

  size_t ncols = 3;
  size_t& nrows = sz;

  Vector<void*> d_cols(ncols, nullptr);
  Vector<int>   d_types(ncols, 0);

  std::vector<gdf_column> v_gdf_cols(ncols);
  v_gdf_cols[0].data = static_cast<void*>(dc1.data().get());
  v_gdf_cols[0].size = nrows;
  v_gdf_cols[0].dtype = GDF_INT32;

  v_gdf_cols[1].data = static_cast<void*>(di1.data().get());
  v_gdf_cols[1].size = nrows;
  v_gdf_cols[1].dtype = GDF_INT32;

  v_gdf_cols[2].data = static_cast<void*>(dd1.data().get());
  v_gdf_cols[2].size = nrows;
  v_gdf_cols[2].dtype = GDF_FLOAT64;


  gdf_column c_agg;
  gdf_column c_vout;

  Vector<double> d_outd(sz, 0);

  c_agg.dtype = GDF_FLOAT64;
  c_agg.data = dd1.data().get();
  c_agg.size = nrows;

  c_vout.dtype = GDF_FLOAT64;
  c_vout.data = d_outd.data().get();
  c_vout.size = nrows;

  size_t n_group = 0;
  //int flag_sorted = 0;

  std::cout<<"aggregate = avg on column:\n";
  print_v(dd1, std::cout);

  //input
  //{
  gdf_context ctxt{0, GDF_SORT, 0, 0};
  std::vector<gdf_column*> v_pcols(ncols);
  for(int i = 0; i < ncols; ++i)
    {
      v_pcols[i] = &v_gdf_cols[i];
    }
  gdf_column** cols = &v_pcols[0];//pointer semantic (2);
  //}

  //output:
  //{
  Vector<int32_t> d_vc_out(nrows);
  Vector<int32_t> d_vi_out(nrows);
  Vector<double> d_vd_out(nrows);
    
  std::vector<gdf_column> v_gdf_cols_out(ncols);
  v_gdf_cols_out[0].data = d_vc_out.data().get();
  v_gdf_cols_out[0].dtype = GDF_INT32;
  v_gdf_cols_out[0].size = nrows;

  v_gdf_cols_out[1].data = d_vi_out.data().get();
  v_gdf_cols_out[1].dtype = GDF_INT32;
  v_gdf_cols_out[1].size = nrows;

  v_gdf_cols_out[2].data = d_vd_out.data().get();
  v_gdf_cols_out[2].dtype = GDF_FLOAT64;
  v_gdf_cols_out[2].size = nrows;

  std::vector<gdf_column*> h_cols_out(ncols);
  for(int i=0; i<ncols; ++i)
    h_cols_out[i] = &v_gdf_cols_out[i];//
  
  gdf_column** cols_out = &h_cols_out[0];//pointer semantics (2)

  d_keys.assign(nrows, 0);
  gdf_column c_indx;
  c_indx.data = d_keys.data().get();
  c_indx.size = nrows;
  c_indx.dtype = GDF_INT32;
  //}
    
  gdf_group_by_avg((int)ncols,      // # columns
                   cols,            //input cols
                   &c_agg,          //column to aggregate on
                   &c_indx,         //if not null return indices of re-ordered rows
                   cols_out,        //if not null return the grouped-by columns
                   &c_vout,         //aggregation result
                   &ctxt);          //struct with additional info;
    
  n_group = c_vout.size;
  const size_t n_rows_expected = 4;
  const double deps = 1.e-8;
  const int ieps = 1;
  const IndexT szeps = 1;
  
  EXPECT_EQ( n_group, n_rows_expected ) << "GROUP-BY AVG returns unexpected #rows:" << n_group;

  //EXPECTED:
  //d_vc_out: 1,1,1,1,
  //d_vi_out: 0,1,3,5
  //d_vd_out: 17,12,13,17,
  vc1 = {1,1,1,1};
  vi1 = {0,1,3,5};
  vd1 = {17,12,13,17};

  bool flag = compare(d_vc_out, vc1, ieps);
  EXPECT_EQ( flag, true ) << "column 1 GROUP-BY returns unexpected result";

  flag = compare(d_vi_out, vi1, ieps);
  EXPECT_EQ( flag, true ) << "column 2 GROUP-BY returns unexpected result";

  flag = compare(d_vd_out, vd1, deps);
  EXPECT_EQ( flag, true ) << "column 3 GROUP-BY returns unexpected result";
  
  //d_keys: 5,0,2,4,
  //d_outd: 17,12,13,17,

  std::vector<IndexT> vk{5,0,2,4};
  vd1 = {17,12,13,17};

  flag = compare(d_keys, vk, szeps);
  EXPECT_EQ( flag, true ) << "GROUP-BY row indices return unexpected result";

  flag = compare(d_outd, vd1, deps);
  EXPECT_EQ( flag, true ) << "GROUP-BY AVG aggregation returns unexpected result";
}

TEST(gdf_group_by_min, UsageTestMin)
{
  std::vector<int> vc1{1,1,1,1,1,1};
  std::vector<int> vi1{1,3,3,5,5,0};
  std::vector<double> vd1{12., 13., 13., 17., 17., 17};

  Vector<int> dc1 = vc1;
  Vector<int> di1 = vi1;
  Vector<double> dd1 = vd1;

  size_t sz = dc1.size();
  assert( sz == di1.size() );
  assert( sz == dd1.size() );
    
  Vector<IndexT> d_indx(sz, 0);
  Vector<IndexT> d_keys(sz, 0);
  Vector<IndexT> d_vals(sz, 0);

  size_t ncols = 3;
  size_t& nrows = sz;

  Vector<void*> d_cols(ncols, nullptr);
  Vector<int>   d_types(ncols, 0);

  std::vector<gdf_column> v_gdf_cols(ncols);
  v_gdf_cols[0].data = static_cast<void*>(dc1.data().get());
  v_gdf_cols[0].size = nrows;
  v_gdf_cols[0].dtype = GDF_INT32;

  v_gdf_cols[1].data = static_cast<void*>(di1.data().get());
  v_gdf_cols[1].size = nrows;
  v_gdf_cols[1].dtype = GDF_INT32;

  v_gdf_cols[2].data = static_cast<void*>(dd1.data().get());
  v_gdf_cols[2].size = nrows;
  v_gdf_cols[2].dtype = GDF_FLOAT64;

  gdf_column c_agg;
  gdf_column c_vout;

  Vector<double> d_outd(sz, 0);

  c_agg.dtype = GDF_FLOAT64;
  ///c_agg.data = dd1.data().get();
  c_agg.size = nrows;

  c_vout.dtype = GDF_FLOAT64;
  c_vout.data = d_outd.data().get();
  c_vout.size = nrows;

  size_t n_group = 0;
  //int flag_sorted = 0;

  std::vector<double> v_col{2., 4., 5., 7., 11., 3.};
  thrust::device_vector<double> d_col = v_col;

  std::cout<<"aggregate = min on column:\n";
  print_v(d_col, std::cout);

  c_agg.dtype = GDF_FLOAT64;
  c_agg.data = d_col.data().get();

  //input
  //{
  gdf_context ctxt{0, GDF_SORT, 0, 0};
  std::vector<gdf_column*> v_pcols(ncols);
  for(int i = 0; i < ncols; ++i)
    {
      v_pcols[i] = &v_gdf_cols[i];
    }
  gdf_column** cols = &v_pcols[0];//pointer semantic (2);
  //}

  //output:
  //{
  Vector<int32_t> d_vc_out(nrows);
  Vector<int32_t> d_vi_out(nrows);
  Vector<double> d_vd_out(nrows);
    
  std::vector<gdf_column> v_gdf_cols_out(ncols);
  v_gdf_cols_out[0].data = d_vc_out.data().get();
  v_gdf_cols_out[0].dtype = GDF_INT32;
  v_gdf_cols_out[0].size = nrows;

  v_gdf_cols_out[1].data = d_vi_out.data().get();
  v_gdf_cols_out[1].dtype = GDF_INT32;
  v_gdf_cols_out[1].size = nrows;

  v_gdf_cols_out[2].data = d_vd_out.data().get();
  v_gdf_cols_out[2].dtype = GDF_FLOAT64;
  v_gdf_cols_out[2].size = nrows;

  std::vector<gdf_column*> h_cols_out(ncols);
  for(int i=0; i<ncols; ++i)
    h_cols_out[i] = &v_gdf_cols_out[i];//
  
  gdf_column** cols_out = &h_cols_out[0];//pointer semantics (2)

  d_keys.assign(nrows, 0);
  gdf_column c_indx;
  c_indx.data = d_keys.data().get();
  c_indx.size = nrows;
  c_indx.dtype = GDF_INT32;
  //}
    
  gdf_group_by_min((int)ncols,      // # columns
                   cols,            //input cols
                   &c_agg,          //column to aggregate on
                   &c_indx,         //if not null return indices of re-ordered rows
                   cols_out,        //if not null return the grouped-by columns
                   &c_vout,         //aggregation result
                   &ctxt);          //struct with additional info;
    
  n_group = c_vout.size;
  const size_t n_rows_expected = 4;
  const double deps = 1.e-8;
  const int ieps = 1;
  const IndexT szeps = 1;
  
  EXPECT_EQ( n_group, n_rows_expected ) << "GROUP-BY MIN returns unexpected #rows:" << n_group;

  //EXPECTED:
  //d_vc_out: 1,1,1,1,
  //d_vi_out: 0,1,3,5
  //d_vd_out: 17,12,13,17,
  vc1 = {1,1,1,1};
  vi1 = {0,1,3,5};
  vd1 = {17,12,13,17};

  bool flag = compare(d_vc_out, vc1, ieps);
  EXPECT_EQ( flag, true ) << "column 1 GROUP-BY returns unexpected result";

  flag = compare(d_vi_out, vi1, ieps);
  EXPECT_EQ( flag, true ) << "column 2 GROUP-BY returns unexpected result";

  flag = compare(d_vd_out, vd1, deps);
  EXPECT_EQ( flag, true ) << "column 3 GROUP-BY returns unexpected result";
    
  //d_keys: 5,0,2,4,
  //d_outd: 3,2,4,7,

  std::vector<IndexT> vk{5,0,2,4};
  vd1 = {3,2,4,7};

  flag = compare(d_keys, vk, szeps);
  EXPECT_EQ( flag, true ) << "GROUP-BY row indices return unexpected result";

  flag = compare(d_outd, vd1, deps);
  EXPECT_EQ( flag, true ) << "GROUP-BY MIN aggregation returns unexpected result";
}

TEST(gdf_group_by_max, UsageTestMax)
{
  std::vector<int> vc1{1,1,1,1,1,1};
  std::vector<int> vi1{1,3,3,5,5,0};
  std::vector<double> vd1{12., 13., 13., 17., 17., 17};

  Vector<int> dc1 = vc1;
  Vector<int> di1 = vi1;
  Vector<double> dd1 = vd1;

  size_t sz = dc1.size();
  assert( sz == di1.size() );
  assert( sz == dd1.size() );
    
  Vector<IndexT> d_indx(sz, 0);
  Vector<IndexT> d_keys(sz, 0);
  Vector<IndexT> d_vals(sz, 0);

  size_t ncols = 3;
  size_t& nrows = sz;

  Vector<void*> d_cols(ncols, nullptr);
  Vector<int>   d_types(ncols, 0);

  std::vector<gdf_column> v_gdf_cols(ncols);
  v_gdf_cols[0].data = static_cast<void*>(dc1.data().get());
  v_gdf_cols[0].size = nrows;
  v_gdf_cols[0].dtype = GDF_INT32;

  v_gdf_cols[1].data = static_cast<void*>(di1.data().get());
  v_gdf_cols[1].size = nrows;
  v_gdf_cols[1].dtype = GDF_INT32;

  v_gdf_cols[2].data = static_cast<void*>(dd1.data().get());
  v_gdf_cols[2].size = nrows;
  v_gdf_cols[2].dtype = GDF_FLOAT64;

  gdf_column c_agg;
  gdf_column c_vout;

  Vector<double> d_outd(sz, 0);

  c_agg.dtype = GDF_FLOAT64;
  ///c_agg.data = dd1.data().get();
  c_agg.size = nrows;

  c_vout.dtype = GDF_FLOAT64;
  c_vout.data = d_outd.data().get();
  c_vout.size = nrows;

  size_t n_group = 0;
  //int flag_sorted = 0;

  std::vector<double> v_col{2., 4., 5., 7., 11., 3.};
  thrust::device_vector<double> d_col = v_col;

  std::cout<<"aggregate = max on column:\n";
  print_v(d_col, std::cout);

  c_agg.dtype = GDF_FLOAT64;
  c_agg.data = d_col.data().get();

  //input
  //{
  gdf_context ctxt{0, GDF_SORT, 0, 0};
  std::vector<gdf_column*> v_pcols(ncols);
  for(int i = 0; i < ncols; ++i)
    {
      v_pcols[i] = &v_gdf_cols[i];
    }
  gdf_column** cols = &v_pcols[0];//pointer semantic (2);
  //}

  //output:
  //{
  Vector<int32_t> d_vc_out(nrows);
  Vector<int32_t> d_vi_out(nrows);
  Vector<double> d_vd_out(nrows);
    
  std::vector<gdf_column> v_gdf_cols_out(ncols);
  v_gdf_cols_out[0].data = d_vc_out.data().get();
  v_gdf_cols_out[0].dtype = GDF_INT32;
  v_gdf_cols_out[0].size = nrows;

  v_gdf_cols_out[1].data = d_vi_out.data().get();
  v_gdf_cols_out[1].dtype = GDF_INT32;
  v_gdf_cols_out[1].size = nrows;

  v_gdf_cols_out[2].data = d_vd_out.data().get();
  v_gdf_cols_out[2].dtype = GDF_FLOAT64;
  v_gdf_cols_out[2].size = nrows;

  std::vector<gdf_column*> h_cols_out(ncols);
  for(int i=0; i<ncols; ++i)
    h_cols_out[i] = &v_gdf_cols_out[i];//
  
  gdf_column** cols_out = &h_cols_out[0];//pointer semantics (2)

  d_keys.assign(nrows, 0);
  gdf_column c_indx;
  c_indx.data = d_keys.data().get();
  c_indx.size = nrows;
  c_indx.dtype = GDF_INT32;
  //}
    
  gdf_group_by_max((int)ncols,      // # columns
                   cols,            //input cols
                   &c_agg,          //column to aggregate on
                   &c_indx,         //if not null return indices of re-ordered rows
                   cols_out,        //if not null return the grouped-by columns
                   &c_vout,         //aggregation result
                   &ctxt);          //struct with additional info;
    
  n_group = c_vout.size;
  const size_t n_rows_expected = 4;
  const double deps = 1.e-8;
  const int ieps = 1;
  const IndexT szeps = 1;
  
  EXPECT_EQ( n_group, n_rows_expected ) << "GROUP-BY MAX returns unexpected #rows:" << n_group;

  //EXPECTED:
  //d_vc_out: 1,1,1,1,
  //d_vi_out: 0,1,3,5
  //d_vd_out: 17,12,13,17,
  vc1 = {1,1,1,1};
  vi1 = {0,1,3,5};
  vd1 = {17,12,13,17};

  bool flag = compare(d_vc_out, vc1, ieps);
  EXPECT_EQ( flag, true ) << "column 1 GROUP-BY returns unexpected result";

  flag = compare(d_vi_out, vi1, ieps);
  EXPECT_EQ( flag, true ) << "column 2 GROUP-BY returns unexpected result";

  flag = compare(d_vd_out, vd1, deps);
  EXPECT_EQ( flag, true ) << "column 3 GROUP-BY returns unexpected result";
    
  //d_keys: 5,0,2,4,
  //d_outd: 3,2,5,11,

  std::vector<IndexT> vk{5,0,2,4};
  vd1 = {3,2,5,11};

  flag = compare(d_keys, vk, szeps);
  EXPECT_EQ( flag, true ) << "GROUP-BY row indices return unexpected result";

  flag = compare(d_outd, vd1, deps);
  EXPECT_EQ( flag, true ) << "GROUP-BY MAX aggregation returns unexpected result";
}

int main(int argc, char **argv) {
  ::testing::InitGoogleTest(&argc, argv);
  return RUN_ALL_TESTS();
}


