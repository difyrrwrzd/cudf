#include <gdf/gdf.h>
#include <gdf/utils.h>
#include <gdf/errorutils.h>


#include <cuda_runtime.h>
#include <vector>
#include <thrust/functional.h>
#include <thrust/execution_policy.h>
#include <thrust/iterator/iterator_adaptor.h>
#include <thrust/iterator/transform_iterator.h>

//std lib
#include <map>




//wow the freaking example from iterator_adaptpr, what a break right!
template<typename Iterator>
class repeat_iterator
		: public thrust::iterator_adaptor<
		  repeat_iterator<Iterator>, // the first template parameter is the name of the iterator we're creating
		  Iterator                   // the second template parameter is the name of the iterator we're adapting
		  // we can use the default for the additional template parameters
		  >
{
public:
	// shorthand for the name of the iterator_adaptor we're deriving from
	typedef thrust::iterator_adaptor<
			repeat_iterator<Iterator>,
			Iterator
			> super_t;
	__host__ __device__
	repeat_iterator(const Iterator &x, int n) : super_t(x), begin(x), n(n) {}
	// befriend thrust::iterator_core_access to allow it access to the private interface below
	friend class thrust::iterator_core_access;
private:
	// repeat each element of the adapted range n times
	unsigned int n;
	// used to keep track of where we began
	const Iterator begin;
	// it is private because only thrust::iterator_core_access needs access to it
	__host__ __device__
	typename super_t::reference dereference() const
	{
		return *(begin + (this->base() - begin) / n);
	}
};



typedef repeat_iterator<thrust::detail::normal_iterator<thrust::device_ptr<gdf_valid_type> > > gdf_valid_iterator;



// note: functor inherits from unary_function
struct modulus_bit_width : public thrust::unary_function<gdf_size_type,gdf_size_type>
{
	__host__ __device__
	gdf_size_type operator()(gdf_size_type x) const
	{
		return x % GDF_VALID_BITSIZE;
	}
};

typedef thrust::transform_iterator<modulus_bit_width, thrust::counting_iterator<gdf_size_type> > bit_position_iterator;


template<typename stencil_type>
struct is_stencil_true
{
	__host__ __device__
	bool operator()(const thrust::tuple<stencil_type, gdf_valid_iterator::value_type, bit_position_iterator::value_type> value)
	{
		gdf_size_type position = thrust::get<2>(value);

		return ((thrust::get<1>(value) >> position) & 1) && (thrust::get<0>(value) != 0);
	}
};

/*
damn im passing out, ok how im going to do this, ill derefence the fucking entire character, offsetting with the iterator i make however the fuck that works right?
		then i will make it so that i zip a counting iterator as well and use that counting iterator to figure out which bit to and
		i think something like a repeat iterator or somethign else will suffce

 */

std::map<gdf_dtype, int16_t> column_type_width = {{GDF_INT8, sizeof(int8_t)}, {GDF_INT16, sizeof(int16_t)},{GDF_INT32, sizeof(int32_t)}, {GDF_INT64, sizeof(int64_t)},
		{GDF_FLOAT32, sizeof(float)}, {GDF_FLOAT64, sizeof(double)} };
//because applying a stencil only needs to know the WIDTH of a type for copying to output, we won't be making a bunch of templated version to store this but rather
//storing a map from gdf_type to width
gdf_error gpu_apply_stencil(gdf_column *lhs, gdf_column * stencil, gdf_column * output){
	//TODO: add a rquire here that output and lhs are the same size


	//find the width in bytes of this data type
	auto searched_item = column_type_width.find(lhs->dtype);
	int16_t width = searched_item->second; //width in bytes

	searched_item = column_type_width.find(stencil->dtype);
	int16_t stencil_width= searched_item->second; //width in bytes

	cudaStream_t stream;
	cudaStreamCreate(&stream);


	bit_position_iterator bit_position_iter(thrust::make_counting_iterator<gdf_size_type>(0), modulus_bit_width());
	gdf_valid_iterator valid_iterator(thrust::detail::make_normal_iterator(thrust::device_pointer_cast(stencil->valid)),GDF_VALID_BITSIZE);
	//TODO: can probably make this happen with some kind of iterator so it can work on any width size
	if(stencil_width == 1){
		//zip the stencil and the valid iterator together
		typedef thrust::tuple<thrust::detail::normal_iterator<thrust::device_ptr<int8_t> >,gdf_valid_iterator, bit_position_iterator > zipped_stencil_tuple;
		typedef thrust::zip_iterator<zipped_stencil_tuple> zipped_stencil_iterator;

		//what kind of shit is that you might wonder?
		//well basically we are zipping up an iterator to the stencil, one to the bit masks, and one which lets us get the bit position based on our index
		zipped_stencil_iterator zipped_stencil_iter(
				thrust::make_tuple(
						thrust::detail::make_normal_iterator(thrust::device_pointer_cast((int8_t * )stencil->data)),
						valid_iterator,
						thrust::make_transform_iterator<modulus_bit_width, thrust::counting_iterator<gdf_size_type> >(
								thrust::make_counting_iterator<gdf_size_type>(0),
								modulus_bit_width())
				));

		//NOTE!!!! the output column is getting set to a specific size  but we are NOT compacting the allocation,
		//whoever calls that should handle that
		if(width == 1){
			thrust::detail::normal_iterator<thrust::device_ptr<int8_t> > input_start =
					thrust::detail::make_normal_iterator(thrust::device_pointer_cast((int8_t *) lhs->data));
			thrust::detail::normal_iterator<thrust::device_ptr<int8_t> > output_start =
					thrust::detail::make_normal_iterator(thrust::device_pointer_cast((int8_t *) output->data));
			thrust::detail::normal_iterator<thrust::device_ptr<int8_t> > output_end =
					thrust::copy_if(thrust::cuda::par.on(stream),input_start,input_start + lhs->size,zipped_stencil_iter,output_start,is_stencil_true<thrust::detail::normal_iterator<thrust::device_ptr<int8_t> >::value_type >());
			output->size = output_end - output_start;
		}else if(width == 2){
			thrust::detail::normal_iterator<thrust::device_ptr<int16_t> > input_start =
					thrust::detail::make_normal_iterator(thrust::device_pointer_cast((int16_t *) lhs->data));
			thrust::detail::normal_iterator<thrust::device_ptr<int16_t> > output_start =
					thrust::detail::make_normal_iterator(thrust::device_pointer_cast((int16_t *) output->data));
			thrust::detail::normal_iterator<thrust::device_ptr<int16_t> > output_end =
					thrust::copy_if(thrust::cuda::par.on(stream),input_start,input_start + lhs->size,zipped_stencil_iter,output_start,is_stencil_true<thrust::detail::normal_iterator<thrust::device_ptr<int8_t> >::value_type >());
			output->size = output_end - output_start;
		}else if(width == 4){
			thrust::detail::normal_iterator<thrust::device_ptr<int32_t> > input_start =
					thrust::detail::make_normal_iterator(thrust::device_pointer_cast((int32_t *) lhs->data));
			thrust::detail::normal_iterator<thrust::device_ptr<int32_t> > output_start =
					thrust::detail::make_normal_iterator(thrust::device_pointer_cast((int32_t *) output->data));
			thrust::detail::normal_iterator<thrust::device_ptr<int32_t> > output_end =
					thrust::copy_if(thrust::cuda::par.on(stream),input_start,input_start + lhs->size,zipped_stencil_iter,output_start,is_stencil_true<thrust::detail::normal_iterator<thrust::device_ptr<int8_t> >::value_type >());
			output->size = output_end - output_start;
		}else if(width == 8){
			thrust::detail::normal_iterator<thrust::device_ptr<int64_t> > input_start =
					thrust::detail::make_normal_iterator(thrust::device_pointer_cast((int64_t *) lhs->data));
			thrust::detail::normal_iterator<thrust::device_ptr<int64_t> > output_start =
					thrust::detail::make_normal_iterator(thrust::device_pointer_cast((int64_t *) output->data));
			thrust::detail::normal_iterator<thrust::device_ptr<int64_t> > output_end =
					thrust::copy_if(thrust::cuda::par.on(stream),input_start,input_start + lhs->size,zipped_stencil_iter,output_start,is_stencil_true<thrust::detail::normal_iterator<thrust::device_ptr<int8_t> >::value_type >());
			output->size = output_end - output_start;
		}

	}else if(stencil_width == 2){
		typedef thrust::tuple<thrust::detail::normal_iterator<thrust::device_ptr<int16_t> >,gdf_valid_iterator, bit_position_iterator > zipped_stencil_tuple;
		typedef thrust::zip_iterator<zipped_stencil_tuple> zipped_stencil_iterator;


		zipped_stencil_iterator zipped_stencil_iter(
				thrust::make_tuple(
						thrust::detail::make_normal_iterator(thrust::device_pointer_cast((int16_t * )stencil->data)),
						valid_iterator,
						thrust::make_transform_iterator<modulus_bit_width, thrust::counting_iterator<gdf_size_type> >(
								thrust::make_counting_iterator<gdf_size_type>(0),
								modulus_bit_width())
				));

		if(width == 1){
			thrust::detail::normal_iterator<thrust::device_ptr<int8_t> > input_start =
					thrust::detail::make_normal_iterator(thrust::device_pointer_cast((int8_t *) lhs->data));
			thrust::detail::normal_iterator<thrust::device_ptr<int8_t> > output_start =
					thrust::detail::make_normal_iterator(thrust::device_pointer_cast((int8_t *) output->data));
			thrust::detail::normal_iterator<thrust::device_ptr<int8_t> > output_end =
					thrust::copy_if(thrust::cuda::par.on(stream),input_start,input_start + lhs->size,zipped_stencil_iter,output_start,is_stencil_true<thrust::detail::normal_iterator<thrust::device_ptr<int16_t> >::value_type >());
			output->size = output_end - output_start;
		}else if(width == 2){
			thrust::detail::normal_iterator<thrust::device_ptr<int16_t> > input_start =
					thrust::detail::make_normal_iterator(thrust::device_pointer_cast((int16_t *) lhs->data));
			thrust::detail::normal_iterator<thrust::device_ptr<int16_t> > output_start =
					thrust::detail::make_normal_iterator(thrust::device_pointer_cast((int16_t *) output->data));
			thrust::detail::normal_iterator<thrust::device_ptr<int16_t> > output_end =
					thrust::copy_if(thrust::cuda::par.on(stream),input_start,input_start + lhs->size,zipped_stencil_iter,output_start,is_stencil_true<thrust::detail::normal_iterator<thrust::device_ptr<int16_t> >::value_type >());
			output->size = output_end - output_start;
		}else if(width == 4){
			thrust::detail::normal_iterator<thrust::device_ptr<int32_t> > input_start =
					thrust::detail::make_normal_iterator(thrust::device_pointer_cast((int32_t *) lhs->data));
			thrust::detail::normal_iterator<thrust::device_ptr<int32_t> > output_start =
					thrust::detail::make_normal_iterator(thrust::device_pointer_cast((int32_t *) output->data));
			thrust::detail::normal_iterator<thrust::device_ptr<int32_t> > output_end =
					thrust::copy_if(thrust::cuda::par.on(stream),input_start,input_start + lhs->size,zipped_stencil_iter,output_start,is_stencil_true<thrust::detail::normal_iterator<thrust::device_ptr<int16_t> >::value_type >());
			output->size = output_end - output_start;
		}else if(width == 8){
			thrust::detail::normal_iterator<thrust::device_ptr<int64_t> > input_start =
					thrust::detail::make_normal_iterator(thrust::device_pointer_cast((int64_t *) lhs->data));
			thrust::detail::normal_iterator<thrust::device_ptr<int64_t> > output_start =
					thrust::detail::make_normal_iterator(thrust::device_pointer_cast((int64_t *) output->data));
			thrust::detail::normal_iterator<thrust::device_ptr<int64_t> > output_end =
					thrust::copy_if(thrust::cuda::par.on(stream),input_start,input_start + lhs->size,zipped_stencil_iter,output_start,is_stencil_true<thrust::detail::normal_iterator<thrust::device_ptr<int16_t> >::value_type >());
			output->size = output_end - output_start;
		}
	}else if(stencil_width == 4){
		typedef thrust::tuple<thrust::detail::normal_iterator<thrust::device_ptr<int32_t> >,gdf_valid_iterator, bit_position_iterator > zipped_stencil_tuple;
		typedef thrust::zip_iterator<zipped_stencil_tuple> zipped_stencil_iterator;

		zipped_stencil_iterator zipped_stencil_iter(
				thrust::make_tuple(
						thrust::detail::make_normal_iterator(thrust::device_pointer_cast((int32_t * )stencil->data)),
						valid_iterator,
						thrust::make_transform_iterator<modulus_bit_width, thrust::counting_iterator<gdf_size_type> >(
								thrust::make_counting_iterator<gdf_size_type>(0),
								modulus_bit_width())
				));

		if(width == 1){
			thrust::detail::normal_iterator<thrust::device_ptr<int8_t> > input_start =
					thrust::detail::make_normal_iterator(thrust::device_pointer_cast((int8_t *) lhs->data));
			thrust::detail::normal_iterator<thrust::device_ptr<int8_t> > output_start =
					thrust::detail::make_normal_iterator(thrust::device_pointer_cast((int8_t *) output->data));
			thrust::detail::normal_iterator<thrust::device_ptr<int8_t> > output_end =
					thrust::copy_if(thrust::cuda::par.on(stream),input_start,input_start + lhs->size,zipped_stencil_iter,output_start,is_stencil_true<thrust::detail::normal_iterator<thrust::device_ptr<int32_t> >::value_type >());
			output->size = output_end - output_start;
		}else if(width == 2){
			thrust::detail::normal_iterator<thrust::device_ptr<int16_t> > input_start =
					thrust::detail::make_normal_iterator(thrust::device_pointer_cast((int16_t *) lhs->data));
			thrust::detail::normal_iterator<thrust::device_ptr<int16_t> > output_start =
					thrust::detail::make_normal_iterator(thrust::device_pointer_cast((int16_t *) output->data));
			thrust::detail::normal_iterator<thrust::device_ptr<int16_t> > output_end =
					thrust::copy_if(thrust::cuda::par.on(stream),input_start,input_start + lhs->size,zipped_stencil_iter,output_start,is_stencil_true<thrust::detail::normal_iterator<thrust::device_ptr<int32_t> >::value_type >());
			output->size = output_end - output_start;
		}else if(width == 4){
			thrust::detail::normal_iterator<thrust::device_ptr<int32_t> > input_start =
					thrust::detail::make_normal_iterator(thrust::device_pointer_cast((int32_t *) lhs->data));
			thrust::detail::normal_iterator<thrust::device_ptr<int32_t> > output_start =
					thrust::detail::make_normal_iterator(thrust::device_pointer_cast((int32_t *) output->data));
			thrust::detail::normal_iterator<thrust::device_ptr<int32_t> > output_end =
					thrust::copy_if(thrust::cuda::par.on(stream),input_start,input_start + lhs->size,zipped_stencil_iter,output_start,is_stencil_true<thrust::detail::normal_iterator<thrust::device_ptr<int32_t> >::value_type >());
			output->size = output_end - output_start;
		}else if(width == 8){
			thrust::detail::normal_iterator<thrust::device_ptr<int64_t> > input_start =
					thrust::detail::make_normal_iterator(thrust::device_pointer_cast((int64_t *) lhs->data));
			thrust::detail::normal_iterator<thrust::device_ptr<int64_t> > output_start =
					thrust::detail::make_normal_iterator(thrust::device_pointer_cast((int64_t *) output->data));
			thrust::detail::normal_iterator<thrust::device_ptr<int64_t> > output_end =
					thrust::copy_if(thrust::cuda::par.on(stream),input_start,input_start + lhs->size,zipped_stencil_iter,output_start,is_stencil_true<thrust::detail::normal_iterator<thrust::device_ptr<int32_t> >::value_type >());
			output->size = output_end - output_start;
		}
	}else if(stencil_width == 8){
		typedef thrust::tuple<thrust::detail::normal_iterator<thrust::device_ptr<int64_t> >,gdf_valid_iterator, bit_position_iterator > zipped_stencil_tuple;
		typedef thrust::zip_iterator<zipped_stencil_tuple> zipped_stencil_iterator;


		zipped_stencil_iterator zipped_stencil_iter(
				thrust::make_tuple(
						thrust::detail::make_normal_iterator(thrust::device_pointer_cast((int64_t * )stencil->data)),
						valid_iterator,
						thrust::make_transform_iterator<modulus_bit_width, thrust::counting_iterator<gdf_size_type> >(
								thrust::make_counting_iterator<gdf_size_type>(0),
								modulus_bit_width())
				));

		if(width == 1){
			thrust::detail::normal_iterator<thrust::device_ptr<int8_t> > input_start =
					thrust::detail::make_normal_iterator(thrust::device_pointer_cast((int8_t *) lhs->data));
			thrust::detail::normal_iterator<thrust::device_ptr<int8_t> > output_start =
					thrust::detail::make_normal_iterator(thrust::device_pointer_cast((int8_t *) output->data));
			thrust::detail::normal_iterator<thrust::device_ptr<int8_t> > output_end =
					thrust::copy_if(thrust::cuda::par.on(stream),input_start,input_start + lhs->size,zipped_stencil_iter,output_start,is_stencil_true<thrust::detail::normal_iterator<thrust::device_ptr<int64_t> >::value_type >());
			output->size = output_end - output_start;
		}else if(width == 2){
			thrust::detail::normal_iterator<thrust::device_ptr<int16_t> > input_start =
					thrust::detail::make_normal_iterator(thrust::device_pointer_cast((int16_t *) lhs->data));
			thrust::detail::normal_iterator<thrust::device_ptr<int16_t> > output_start =
					thrust::detail::make_normal_iterator(thrust::device_pointer_cast((int16_t *) output->data));
			thrust::detail::normal_iterator<thrust::device_ptr<int16_t> > output_end =
					thrust::copy_if(thrust::cuda::par.on(stream),input_start,input_start + lhs->size,zipped_stencil_iter,output_start,is_stencil_true<thrust::detail::normal_iterator<thrust::device_ptr<int64_t> >::value_type >());
			output->size = output_end - output_start;
		}else if(width == 4){
			thrust::detail::normal_iterator<thrust::device_ptr<int32_t> > input_start =
					thrust::detail::make_normal_iterator(thrust::device_pointer_cast((int32_t *) lhs->data));
			thrust::detail::normal_iterator<thrust::device_ptr<int32_t> > output_start =
					thrust::detail::make_normal_iterator(thrust::device_pointer_cast((int32_t *) output->data));
			thrust::detail::normal_iterator<thrust::device_ptr<int32_t> > output_end =
					thrust::copy_if(thrust::cuda::par.on(stream),input_start,input_start + lhs->size,zipped_stencil_iter,output_start,is_stencil_true<thrust::detail::normal_iterator<thrust::device_ptr<int64_t> >::value_type >());
			output->size = output_end - output_start;
		}else if(width == 8){
			thrust::detail::normal_iterator<thrust::device_ptr<int64_t> > input_start =
					thrust::detail::make_normal_iterator(thrust::device_pointer_cast((int64_t *) lhs->data));
			thrust::detail::normal_iterator<thrust::device_ptr<int64_t> > output_start =
					thrust::detail::make_normal_iterator(thrust::device_pointer_cast((int64_t *) output->data));
			thrust::detail::normal_iterator<thrust::device_ptr<int64_t> > output_end =
					thrust::copy_if(thrust::cuda::par.on(stream),input_start,input_start + lhs->size,zipped_stencil_iter,output_start,is_stencil_true<thrust::detail::normal_iterator<thrust::device_ptr<int64_t> >::value_type >());
			output->size = output_end - output_start;
		}
	}

	//TODO:BRING OVER THE BITMASK!!!

	cudaStreamSynchronize(stream);

	cudaStreamDestroy(stream);

	return GDF_SUCCESS;

}
