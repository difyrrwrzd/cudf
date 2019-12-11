#include <cudf/types.hpp>
#include <tests/utilities/base_fixture.hpp>
#include <cudf/table/table.hpp>
#include <cudf/table/table_view.hpp>

#include <cudf/merge.hpp>
#include <rmm/thrust_rmm_allocator.h>
#include <cudf/column/column_factories.hpp>
#include <tests/utilities/column_utilities.hpp>
#include <tests/utilities/column_wrapper.hpp>
#include <cudf/utilities/type_dispatcher.hpp>
#include <tests/utilities/type_lists.hpp>
#include <tests/utilities/column_wrapper.hpp>
#include <tests/utilities/cudf_gtest.hpp>
#include <cudf/utilities/legacy/wrapper_types.hpp>

#include <cassert>
#include <vector>
#include <memory>
#include <algorithm>
#include <limits>
#include <initializer_list>

#include <gtest/gtest.h>

template <typename T>
class MergeTest_ : public cudf::test::BaseFixture {};

TYPED_TEST_CASE(MergeTest_, cudf::test::FixedWidthTypes);

TYPED_TEST(MergeTest_, MismatchedNumColumns) {
    using columnFactoryT = cudf::test::fixed_width_column_wrapper<TypeParam>;
    
    columnFactoryT leftColWrap1{{0,1,2,3}}; 
    columnFactoryT rightColWrap1{{0,1,2,3}};
    columnFactoryT rightColWrap2{{0,1,2,3}};

    std::vector<cudf::size_type> key_cols{0};
    std::vector<cudf::order> column_order {cudf::order::ASCENDING};
    std::vector<cudf::null_order> null_precedence{};

    cudf::table_view left_view{{leftColWrap1}};
    cudf::table_view right_view{{rightColWrap1, rightColWrap2}};

    EXPECT_THROW(cudf::experimental::merge(left_view,
                                           right_view,
                                           key_cols,
                                           column_order,
                                           null_precedence), cudf::logic_error);
}



TYPED_TEST(MergeTest_, MismatchedColumnDypes) {
    cudf::test::fixed_width_column_wrapper<int32_t> leftColWrap1{{0,1,2,3}};
    cudf::test::fixed_width_column_wrapper<double> rightColWrap1{{0,1,2,3}};

    std::vector<cudf::size_type> key_cols{0};
    std::vector<cudf::order> column_order {cudf::order::ASCENDING};
    std::vector<cudf::null_order> null_precedence{};

    cudf::table_view left_view{{leftColWrap1}};
    cudf::table_view right_view{{rightColWrap1}};


    EXPECT_THROW(cudf::experimental::merge(left_view,
                                           right_view,
                                           key_cols,
                                           column_order,
                                           null_precedence), cudf::logic_error);
}


TYPED_TEST(MergeTest_, EmptyKeyColumns) {
    using columnFactoryT = cudf::test::fixed_width_column_wrapper<TypeParam>;
    
    columnFactoryT leftColWrap1{{0,1,2,3}}; 
    columnFactoryT rightColWrap1{{0,1,2,3}};

    std::vector<cudf::size_type> key_cols{}; // empty! this should trigger exception
    std::vector<cudf::order> column_order {cudf::order::ASCENDING};
    std::vector<cudf::null_order> null_precedence{};

    cudf::table_view left_view{{leftColWrap1}};
    cudf::table_view right_view{{rightColWrap1}};

    EXPECT_THROW(cudf::experimental::merge(left_view,
                                           right_view,
                                           key_cols,
                                           column_order,
                                           null_precedence), cudf::logic_error);
}


TYPED_TEST(MergeTest_, TooManyKeyColumns) {
    using columnFactoryT = cudf::test::fixed_width_column_wrapper<TypeParam>;
    
    columnFactoryT leftColWrap1{{0,1,2,3}}; 
    columnFactoryT rightColWrap1{{0,1,2,3}};

    std::vector<cudf::size_type> key_cols{0, 1}; // more keys than columns: this should trigger exception
    std::vector<cudf::order> column_order {cudf::order::ASCENDING};
    std::vector<cudf::null_order> null_precedence{};

    cudf::table_view left_view{{leftColWrap1}};
    cudf::table_view right_view{{rightColWrap1}};

    EXPECT_THROW(cudf::experimental::merge(left_view,
                                           right_view,
                                           key_cols,
                                           column_order,
                                           null_precedence), cudf::logic_error);
}


TYPED_TEST(MergeTest_, EmptyOrderTypes) {
    using columnFactoryT = cudf::test::fixed_width_column_wrapper<TypeParam>;
    
    columnFactoryT leftColWrap1{{0,1,2,3}}; 
    columnFactoryT rightColWrap1{{0,1,2,3}};

    std::vector<cudf::size_type> key_cols{0};
    std::vector<cudf::order> column_order {}; // empty! this should trigger exception
    std::vector<cudf::null_order> null_precedence{};

    cudf::table_view left_view{{leftColWrap1}};
    cudf::table_view right_view{{rightColWrap1}};

    EXPECT_THROW(cudf::experimental::merge(left_view,
                                           right_view,
                                           key_cols,
                                           column_order,
                                           null_precedence), cudf::logic_error);
}


TYPED_TEST(MergeTest_, TooManyOrderTypes) {
    using columnFactoryT = cudf::test::fixed_width_column_wrapper<TypeParam>;
    
    columnFactoryT leftColWrap1{{0,1,2,3}}; 
    columnFactoryT rightColWrap1{{0,1,2,3}};

    std::vector<cudf::size_type> key_cols{0}; 
    std::vector<cudf::order> column_order {cudf::order::ASCENDING, cudf::order::DESCENDING}; // more order types than columns: this should trigger exception
    std::vector<cudf::null_order> null_precedence{};

    cudf::table_view left_view{{leftColWrap1}};
    cudf::table_view right_view{{rightColWrap1}};

    EXPECT_THROW(cudf::experimental::merge(left_view,
                                           right_view,
                                           key_cols,
                                           column_order,
                                           null_precedence), cudf::logic_error);
}

TYPED_TEST(MergeTest_, MismatchedKeyColumnsAndOrderTypes) {
    using columnFactoryT = cudf::test::fixed_width_column_wrapper<TypeParam>;
    
    columnFactoryT leftColWrap1{{0,1,2,3}};
    columnFactoryT leftColWrap2{{0,1,2,3}};
    columnFactoryT rightColWrap1{{0,1,2,3}};
    columnFactoryT rightColWrap2{{0,1,2,3}};

    cudf::table_view left_view{{leftColWrap1, leftColWrap2}};
    cudf::table_view right_view{{rightColWrap1, rightColWrap2}};
    
    std::vector<cudf::size_type> key_cols{0, 1};
    std::vector<cudf::order> column_order {cudf::order::ASCENDING};
    std::vector<cudf::null_order> null_precedence{};

    std::vector<cudf::size_type> sortByCols = {0, 1};
    std::vector<order_by_type> orderByTypes = {GDF_ORDER_ASC};

    EXPECT_THROW(cudf::experimental::merge(left_view,
                                           right_view,
                                           key_cols,
                                           column_order,
                                           null_precedence), cudf::logic_error);
}

TYPED_TEST(MergeTest_, MergeWithEmptyColumn) {
    using columnFactoryT = cudf::test::fixed_width_column_wrapper<TypeParam>;

    cudf::size_type inputRows = 40;

    auto sequence = cudf::test::make_counting_transform_iterator(0, [](auto i) { return TypeParam(i); });
    columnFactoryT leftColWrap1(sequence, sequence+inputRows);
    columnFactoryT rightColWrap1{};//wrapper of empty column <- this might require a (sequence, sequence) generator 

    std::vector<cudf::size_type> key_cols{0};
    std::vector<cudf::order> column_order {cudf::order::ASCENDING};
    std::vector<cudf::null_order> null_precedence{};

    cudf::table_view left_view{{leftColWrap1}};
    cudf::table_view right_view{{rightColWrap1}};

    std::unique_ptr<cudf::experimental::table> p_outputTable;
    EXPECT_NO_THROW(p_outputTable = cudf::experimental::merge(left_view,
                                                              right_view,
                                                              key_cols,
                                                              column_order,
                                                              null_precedence));

    cudf::column_view const& a_left_tbl_cview{static_cast<cudf::column_view const&>(leftColWrap1)};
    cudf::column_view const& a_right_tbl_cview{static_cast<cudf::column_view const&>(rightColWrap1)};
    const cudf::size_type outputRows = a_left_tbl_cview.size() + a_right_tbl_cview.size();
    
    columnFactoryT expectedDataWrap1(sequence, sequence+outputRows);//<- confirmed I can reuse a sequence, wo/ creating overlapping columns!

    auto expected_column_view{static_cast<cudf::column_view const&>(expectedDataWrap1)};
    auto output_column_view{p_outputTable->view().column(0)};
    
    cudf::test::expect_columns_equal(expected_column_view, output_column_view);
}

TYPED_TEST(MergeTest_, Merge1KeyColumns) {
    using columnFactoryT = cudf::test::fixed_width_column_wrapper<TypeParam>;
    
    cudf::size_type inputRows = 40;
    
    auto sequence0 = cudf::test::make_counting_transform_iterator(0, [](auto row) {
        if (cudf::experimental::type_to_id<TypeParam>() == cudf::BOOL8)
          return 0;
        else
          return row; });
        
    auto sequence1 = cudf::test::make_counting_transform_iterator(0, [](auto row) {
        if (cudf::experimental::type_to_id<TypeParam>() == cudf::BOOL8)
          return 1;
        else
          return 2 * row; });
    
    auto sequence2 = cudf::test::make_counting_transform_iterator(0, [](auto row) {
        if (cudf::experimental::type_to_id<TypeParam>() == cudf::BOOL8)
          return 0;
        else
          return 2 * row + 1; });

    columnFactoryT leftColWrap1(sequence1, sequence1+inputRows);
    columnFactoryT leftColWrap2(sequence0, sequence0+inputRows);

  
    columnFactoryT rightColWrap1(sequence2, sequence2+inputRows);
    columnFactoryT rightColWrap2(sequence0, sequence0+inputRows);//<- confirmed I can reuse a sequence, wo/ creating overlapping columns!
  
    cudf::table_view left_view{{leftColWrap1, leftColWrap2}};
    cudf::table_view right_view{{rightColWrap1, rightColWrap2}};
    
    std::vector<cudf::size_type> key_cols{0};
    std::vector<cudf::order> column_order {cudf::order::ASCENDING};
    std::vector<cudf::null_order> null_precedence{};

    std::unique_ptr<cudf::experimental::table> p_outputTable;
    EXPECT_NO_THROW(p_outputTable = cudf::experimental::merge(left_view,
                                                              right_view,
                                                              key_cols,
                                                              column_order,
                                                              null_precedence));

    cudf::column_view const& a_left_tbl_cview{static_cast<cudf::column_view const&>(leftColWrap1)};
    cudf::column_view const& a_right_tbl_cview{static_cast<cudf::column_view const&>(rightColWrap1)};
    const cudf::size_type outputRows = a_left_tbl_cview.size() + a_right_tbl_cview.size();
    
    auto seq_out1 = cudf::test::make_counting_transform_iterator(0, [outputRows](auto row) {
        if (cudf::experimental::type_to_id<TypeParam>() == cudf::BOOL8)
          {
            cudf::experimental::bool8 ret = (row >= outputRows / 2); 
            return static_cast<TypeParam>(ret);
          }
        else
          return static_cast<TypeParam>(row);
      });
    columnFactoryT expectedDataWrap1(seq_out1, seq_out1+outputRows);

    auto seq_out2 = cudf::test::make_counting_transform_iterator(0, [outputRows](auto row) {
        if (cudf::experimental::type_to_id<TypeParam>() == cudf::BOOL8)
          return 0;
        else
          return row / 2; });
    columnFactoryT expectedDataWrap2(seq_out2, seq_out2+outputRows);

    auto expected_column_view1{static_cast<cudf::column_view const&>(expectedDataWrap1)};
    auto expected_column_view2{static_cast<cudf::column_view const&>(expectedDataWrap2)};

    auto output_column_view1{p_outputTable->view().column(0)};
    auto output_column_view2{p_outputTable->view().column(1)};    

    cudf::test::expect_columns_equal(expected_column_view1, output_column_view1);
    cudf::test::expect_columns_equal(expected_column_view2, output_column_view2);
}

TYPED_TEST(MergeTest_, Merge2KeyColumns) {
    using columnFactoryT = cudf::test::fixed_width_column_wrapper<TypeParam>;
    
    cudf::size_type inputRows = 40;

    auto sequence1 = cudf::test::make_counting_transform_iterator(0, [inputRows](auto row) {
        if (cudf::experimental::type_to_id<TypeParam>() == cudf::BOOL8)
          {
            cudf::experimental::bool8 ret = (row >= inputRows / 2); 
            return static_cast<TypeParam>(ret);
          }
        else
          return static_cast<TypeParam>(row);
      });
    columnFactoryT leftColWrap1(sequence1, sequence1 + inputRows);

    auto sequence2 = cudf::test::make_counting_transform_iterator(0, [inputRows](auto row) {
        if (cudf::experimental::type_to_id<TypeParam>() == cudf::BOOL8)
          {
            cudf::experimental::bool8 ret = ((row / (inputRows / 4)) % 2 == 0); 
            return static_cast<TypeParam>(ret);
          }
        else
          {
            auto row2 = row * 2;
            TypeParam res = static_cast<TypeParam>(row2);
            return static_cast<TypeParam>(res);
          }
      });
    columnFactoryT leftColWrap2(sequence2, sequence2 + inputRows);

    columnFactoryT rightColWrap1(sequence1, sequence1 + inputRows);

    auto sequence3 = cudf::test::make_counting_transform_iterator(0, [inputRows](auto row) {
        if (cudf::experimental::type_to_id<TypeParam>() == cudf::BOOL8)
          {
            cudf::experimental::bool8 ret = ((row / (inputRows / 4)) % 2 == 0); 
            return static_cast<TypeParam>(ret);
          }
        else
          return static_cast<TypeParam>(2 * row + 1);
      });
    columnFactoryT rightColWrap2(sequence3, sequence3 + inputRows);

    cudf::table_view left_view{{leftColWrap1, leftColWrap2}};
    cudf::table_view right_view{{rightColWrap1, rightColWrap2}};

    std::vector<cudf::size_type> key_cols{0, 1};
    std::vector<cudf::order> column_order {cudf::order::ASCENDING, cudf::order::DESCENDING};
    std::vector<cudf::null_order> null_precedence{};

    std::unique_ptr<cudf::experimental::table> p_outputTable;
    EXPECT_NO_THROW(p_outputTable = cudf::experimental::merge(left_view,
                                                              right_view,
                                                              key_cols,
                                                              column_order,
                                                              null_precedence));

    cudf::column_view const& a_left_tbl_cview{static_cast<cudf::column_view const&>(leftColWrap1)};
    cudf::column_view const& a_right_tbl_cview{static_cast<cudf::column_view const&>(rightColWrap1)};
    const cudf::size_type outputRows = a_left_tbl_cview.size() + a_right_tbl_cview.size();
    
    auto seq_out1 = cudf::test::make_counting_transform_iterator(0, [outputRows](auto row) {
        if (cudf::experimental::type_to_id<TypeParam>() == cudf::BOOL8)
          {
            cudf::experimental::bool8 ret = (row >= outputRows / 2); 
            return static_cast<TypeParam>(ret);
          }
        else
          return static_cast<TypeParam>(row / 2);
      });
    columnFactoryT expectedDataWrap1(seq_out1, seq_out1+outputRows);

    auto seq_out2 = cudf::test::make_counting_transform_iterator(0, [outputRows](auto row) {
        if (cudf::experimental::type_to_id<TypeParam>() == cudf::BOOL8)
          {
            cudf::experimental::bool8 ret = ((row / (outputRows / 4)) % 2 == 0); 
            return static_cast<TypeParam>(ret);
          }
        else
          {
            auto ret = (row % 2 == 0 ? row + 1 : row - 1);
            return static_cast<TypeParam>(ret);
          }
      });
    columnFactoryT expectedDataWrap2(seq_out2, seq_out2+outputRows);

    auto expected_column_view1{static_cast<cudf::column_view const&>(expectedDataWrap1)};
    auto expected_column_view2{static_cast<cudf::column_view const&>(expectedDataWrap2)};

    auto output_column_view1{p_outputTable->view().column(0)};
    auto output_column_view2{p_outputTable->view().column(1)};

    cudf::test::expect_columns_equal(expected_column_view1, output_column_view1);
    cudf::test::expect_columns_equal(expected_column_view2, output_column_view2);
}

TYPED_TEST(MergeTest_, Merge1KeyNullColumns) {
    using columnFactoryT = cudf::test::fixed_width_column_wrapper<TypeParam>;
    
    cudf::size_type inputRows = 40;

    // data: 0  2  4  6 | valid: 1 1 1 0
    auto sequence1 = cudf::test::make_counting_transform_iterator(0, [inputRows](auto row) {
        if (cudf::experimental::type_to_id<TypeParam>() == cudf::BOOL8)
          {
            cudf::experimental::bool8 ret = 0; 
            return static_cast<TypeParam>(ret); // <- no shortcut to this can avoid compiler errors
          }
        else
          {
            auto row2 = row * 2;
            TypeParam res = static_cast<TypeParam>(row2);
            return static_cast<TypeParam>(res);
          }
      });
    auto valid_sequence1 = cudf::test::make_counting_transform_iterator(0, [inputRows](auto row) {
        return (row < inputRows - 1);
      });
    columnFactoryT leftColWrap1(sequence1, sequence1 + inputRows, valid_sequence1);

    // data: 1  3  5  7 | valid: 1 1 1 0
    auto sequence2 = cudf::test::make_counting_transform_iterator(0, [inputRows](auto row) {
        if (cudf::experimental::type_to_id<TypeParam>() == cudf::BOOL8)
          {
            cudf::experimental::bool8 ret = 1; 
            return static_cast<TypeParam>(ret);
          }
        else
          return static_cast<TypeParam>(2 * row + 1);
      });
    columnFactoryT rightColWrap1(sequence2, sequence2 + inputRows, valid_sequence1); // <- recycle valid_seq1, confirmed okay...

    std::vector<cudf::size_type> key_cols{0};
    std::vector<cudf::order> column_order {cudf::order::ASCENDING};

    /*Note: default behavior semantics for null_precedence has changed
     *      wrt legacy code:
     *
     * in legacy code missing (default) nulls argument 
     * meant nulls are greatest; i.e., null_order::AFTER (not null_order::BEFORE)
     *
     * While new semantics is (see row_operators.cuh: row_lexicographic_comparator::operator() ):
     * null_order null_precedence = _null_precedence == nullptr ?
     *                  null_order::BEFORE: _null_precedence[i];
     *
     * hence missing (default) value meant nulls are smallest
     * null_order::BEFORE (not  null_order::AFTER) (!)
    */
    std::vector<cudf::null_order> null_precedence{cudf::null_order::AFTER};

    cudf::table_view left_view{{leftColWrap1}};
    cudf::table_view right_view{{rightColWrap1}};

    std::unique_ptr<cudf::experimental::table> p_outputTable;
    EXPECT_NO_THROW(p_outputTable = cudf::experimental::merge(left_view,
                                                              right_view,
                                                              key_cols,
                                                              column_order,
                                                              null_precedence));

    cudf::column_view const& a_left_tbl_cview{static_cast<cudf::column_view const&>(leftColWrap1)};
    cudf::column_view const& a_right_tbl_cview{static_cast<cudf::column_view const&>(rightColWrap1)};
    const cudf::size_type outputRows = a_left_tbl_cview.size() + a_right_tbl_cview.size();
    const cudf::size_type column1TotalNulls = a_left_tbl_cview.null_count() + a_right_tbl_cview.null_count();

    // data: 0 1 2 3 4 5 6 7 | valid: 1 1 1 1 1 1 0 0
    auto seq_out1 = cudf::test::make_counting_transform_iterator(0, [outputRows, column1TotalNulls](auto row) {
        if (cudf::experimental::type_to_id<TypeParam>() == cudf::BOOL8)
          {
            cudf::experimental::bool8 ret = (row >= (outputRows - column1TotalNulls) / 2); 
            return static_cast<TypeParam>(ret);
          }
        else
          return static_cast<TypeParam>(row);
      });
    auto valid_seq_out = cudf::test::make_counting_transform_iterator(0, [outputRows, column1TotalNulls](auto row) {
        return (row < (outputRows - column1TotalNulls));
      });
    columnFactoryT expectedDataWrap1(seq_out1, seq_out1 + outputRows, valid_seq_out);
    
    auto expected_column_view1{static_cast<cudf::column_view const&>(expectedDataWrap1)};
    auto output_column_view1{p_outputTable->view().column(0)};
    
    cudf::test::expect_columns_equal(expected_column_view1, output_column_view1);
}

TYPED_TEST(MergeTest_, Merge2KeyNullColumns) {
    using columnFactoryT = cudf::test::fixed_width_column_wrapper<TypeParam>;
    
    cudf::size_type inputRows = 40;

    // data: 0 1 2 3 | valid: 1 1 1 1
    auto sequence1 = cudf::test::make_counting_transform_iterator(0, [inputRows](auto row) {
        if (cudf::experimental::type_to_id<TypeParam>() == cudf::BOOL8)
          {
            cudf::experimental::bool8 ret = (row >= inputRows / 2); 
            return static_cast<TypeParam>(ret);
          }
        else
          return static_cast<TypeParam>(row);
      });
    auto valid_sequence1 = cudf::test::make_counting_transform_iterator(0, [](auto row) {
        return true;
      });
    columnFactoryT leftColWrap1(sequence1, sequence1 + inputRows, valid_sequence1);// if left out: valid_sequence defaults to `false`;

    // data: 0 2 4 6 | valid: 1 1 1 1
    auto sequence2 = cudf::test::make_counting_transform_iterator(0, [inputRows](auto row) {
        if (cudf::experimental::type_to_id<TypeParam>() == cudf::BOOL8)
          {
            cudf::experimental::bool8 ret = ((row / (inputRows / 4)) % 2 == 0); 
            return static_cast<TypeParam>(ret);
          }
        else
          {
            auto row2 = row * 2;
            TypeParam res = static_cast<TypeParam>(row2);
            return static_cast<TypeParam>(res);
          }
      });
    columnFactoryT leftColWrap2(sequence2, sequence2 + inputRows, valid_sequence1);


    // data: 0 1 2 3 | valid: 1 1 1 1
    columnFactoryT rightColWrap1(sequence1, sequence1 + inputRows, valid_sequence1);// if left out: valid_sequence defaults to `false`;
    
    // data: 0 1 2 3 | valid: 0 0 0 0
    auto sequence3 = cudf::test::make_counting_transform_iterator(0, [inputRows](auto row) {
        if (cudf::experimental::type_to_id<TypeParam>() == cudf::BOOL8)
          {
            cudf::experimental::bool8 ret = ((row / (inputRows / 4)) % 2 == 0); 
            return static_cast<TypeParam>(ret);
          }
        else
          return static_cast<TypeParam>(row);
      });
    auto valid_sequence0 = cudf::test::make_counting_transform_iterator(0, [](auto row) {
        return false;
      });
    columnFactoryT rightColWrap2(sequence3, sequence3 + inputRows, valid_sequence0);

    cudf::table_view left_view{{leftColWrap1, leftColWrap2}};
    cudf::table_view right_view{{rightColWrap1, rightColWrap2}};

    std::vector<cudf::size_type> key_cols{0, 1};
    std::vector<cudf::order> column_order {cudf::order::ASCENDING, cudf::order::DESCENDING};
    std::vector<cudf::null_order> null_precedence{cudf::null_order::AFTER, cudf::null_order::AFTER};

    std::unique_ptr<cudf::experimental::table> p_outputTable;
    EXPECT_NO_THROW(p_outputTable = cudf::experimental::merge(left_view,
                                                              right_view,
                                                              key_cols,
                                                              column_order,
                                                              null_precedence));

    cudf::column_view const& a_left_tbl_cview{static_cast<cudf::column_view const&>(leftColWrap1)};
    cudf::column_view const& a_right_tbl_cview{static_cast<cudf::column_view const&>(rightColWrap1)};
    const cudf::size_type outputRows = a_left_tbl_cview.size() + a_right_tbl_cview.size();
    
    // data: 0 0 1 1 2 2 3 3 | valid: 1 1 1 1 1 1 1 1
    auto seq_out1 = cudf::test::make_counting_transform_iterator(0, [outputRows](auto row) {
        if (cudf::experimental::type_to_id<TypeParam>() == cudf::BOOL8)
          {
            cudf::experimental::bool8 ret = (row >= outputRows / 2); 
            return static_cast<TypeParam>(ret);
          }
        else
          return static_cast<TypeParam>(row / 2);
      });
    columnFactoryT expectedDataWrap1(seq_out1, seq_out1+outputRows, valid_sequence1);
    
    // data: 0 0 2 1 4 2 6 3 | valid: 0 1 0 1 0 1 0 1
    auto seq_out2 = cudf::test::make_counting_transform_iterator(0, [outputRows](auto row) {
        if (cudf::experimental::type_to_id<TypeParam>() == cudf::BOOL8)
          {
            cudf::experimental::bool8 ret = ((row / (outputRows / 8)) % 2 == 0); 
            return static_cast<TypeParam>(ret);
          }
        else
          {
            auto ret = (row % 2 != 0 ? 2 * (row / 2) : (row / 2));
            return static_cast<TypeParam>(ret);
          }
      });
    auto valid_sequence_out = cudf::test::make_counting_transform_iterator(0, [outputRows](auto row) {
        if (cudf::experimental::type_to_id<TypeParam>() == cudf::BOOL8)
          { 
            return ((row / (outputRows / 4)) % 2 == 1);
          }
        else
          {
            return (row % 2 != 0);
          }
      });
    columnFactoryT expectedDataWrap2(seq_out2, seq_out2 + outputRows, valid_sequence_out);

    auto expected_column_view1{static_cast<cudf::column_view const&>(expectedDataWrap1)};
    auto expected_column_view2{static_cast<cudf::column_view const&>(expectedDataWrap2)};

    auto output_column_view1{p_outputTable->view().column(0)};
    auto output_column_view2{p_outputTable->view().column(1)};

    cudf::test::expect_columns_equal(expected_column_view1, output_column_view1);
    cudf::test::expect_columns_equal(expected_column_view2, output_column_view2);
}

