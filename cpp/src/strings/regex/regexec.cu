/*
* Copyright (c) 2019, NVIDIA CORPORATION.  All rights reserved.
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

#include <rmm/device_buffer.hpp>
#include "./regex.cuh"
#include "./regcomp.h"

#include <memory.h>
#include <rmm/rmm.hpp>
#include <rmm/rmm_api.h>

namespace cudf
{
namespace strings
{
namespace detail
{

// Copy Reprog primitive values
Reprog_device::Reprog_device(Reprog& prog)
{
    _startinst_id = prog.get_start_inst();
    _num_capturing_groups = prog.groups_count();
    _insts_count = prog.insts_count();
    _starts_count = prog.starts_count();
    _classes_count = prog.classes_count();
    _relists_mem = nullptr;
    _stack_mem1 = nullptr;
    _stack_mem2 = nullptr;
}

// Create instance of the Reprog that can be passed into a device kernel
std::unique_ptr<Reprog_device, std::function<void(Reprog_device*)>>
 Reprog_device::create(const char32_t* pattern, const uint8_t* codepoint_flags, size_type strings_count, cudaStream_t stream )
{
    // compile pattern into host object
    Reprog h_prog = Reprog::create_from(pattern);
    // compute size to hold all the member data
    auto insts_count = h_prog.insts_count();
    auto classes_count = h_prog.classes_count();
    auto starts_count = h_prog.starts_count();
    auto insts_size = insts_count * sizeof(_insts[0]);
    auto startids_size = starts_count * sizeof(_startinst_ids[0]);
    auto classes_size = classes_count * sizeof(_classes[0]);
    for( int32_t idx=0; idx < classes_count; ++idx )
        classes_size += static_cast<int32_t>((h_prog.class_at(idx).chrs.size())*sizeof(char32_t));
    size_t memsize = insts_size + startids_size + classes_size;
    size_t rlm_size = 0;
    // check memory size needed for executing regex
    if( insts_count > MAX_STACK_INSTS )
    {
        auto relist_alloc_size = Relist::alloc_size(insts_count);
        size_t rlm_size = relist_alloc_size*2L*strings_count; // Reljunk has 2 Relist ptrs
        size_t freeSize=0, totalSize=0;
        rmmGetInfo(&freeSize,&totalSize,stream);
        if( rlm_size + memsize > freeSize ) // do not allocate more than we have
        {                                   // otherwise, this is unrecoverable
            std::ostringstream message;
            message << "cuDF failure at: " __FILE__ ":" << __LINE__ << ": ";
            message << "number of instructions (" << insts_count << ") ";
            message << "and number of strings (" << strings_count << ") ";
            message << "exceeds available memory";
            throw cudf::logic_error(message.str());
        }
    }

    // allocate memory to store prog data
    std::vector<u_char> h_buffer(memsize);
    u_char* h_ptr = h_buffer.data(); // running pointer
    u_char* d_buffer = 0;
    RMM_TRY(RMM_ALLOC(&d_buffer,memsize,stream));
    u_char* d_ptr = d_buffer;        // running device pointer
    // put everything into a flat host buffer first
    Reprog_device* d_prog = new Reprog_device(h_prog);
    // copy the instructions array first (fixed-size structs)
    Reinst* insts = reinterpret_cast<Reinst*>(h_ptr);
    memcpy( insts, h_prog.insts_data(), insts_size);
    h_ptr += insts_size; // next section
    d_prog->_insts = reinterpret_cast<Reinst*>(d_ptr);
    d_ptr += insts_size;
    // copy the startinst_ids next (ints)
    int32_t* startinst_ids = reinterpret_cast<int32_t*>(h_ptr);
    memcpy( startinst_ids, h_prog.starts_data(), startids_size );
    h_ptr += startids_size; // next section
    d_prog->_startinst_ids = reinterpret_cast<int32_t*>(d_ptr);
    d_ptr += startids_size;
    // copy classes into flat memory: [class1,class2,...][char32 arrays]
    Reclass_device* classes = reinterpret_cast<Reclass_device*>(h_ptr);
    d_prog->_classes = reinterpret_cast<Reclass_device*>(d_ptr);
    // get pointer to the end to handle variable length data
    u_char* h_end = h_ptr + (classes_count * sizeof(Reclass_device));
    u_char* d_end = d_ptr + (classes_count * sizeof(Reclass_device));
    // place each class and append the variable length data
    for( int32_t idx=0; idx < classes_count; ++idx )
    {
        Reclass& h_class = h_prog.class_at(idx);
        Reclass_device d_class;
        d_class.builtins = h_class.builtins;
        d_class.count = h_class.chrs.size();
        d_class.chrs = reinterpret_cast<char32_t*>(d_end);
        memcpy( classes++, &d_class, sizeof(d_class) );
        memcpy( h_end, h_class.chrs.c_str(), h_class.chrs.size()*sizeof(char32_t) );
        h_end += h_class.chrs.size()*sizeof(char32_t);
        d_end += h_class.chrs.size()*sizeof(char32_t);
    }
    // initialize the rest of the elements
    d_prog->_insts_count = insts_count;
    d_prog->_starts_count = starts_count;
    d_prog->_classes_count = classes_count;
    d_prog->_codepoint_flags = codepoint_flags;
    // allocate execute memory if needed
    if( rlm_size > 0 )
    {
        RMM_TRY(RMM_ALLOC(&(d_prog->_relists_mem),rlm_size,stream));
    }

    // copy flat prog to device memory
    CUDA_TRY(cudaMemcpy(d_buffer,h_buffer.data(),memsize,cudaMemcpyHostToDevice));
    //
    auto deleter = [](Reprog_device*t) {t->destroy();};
    return std::unique_ptr<Reprog_device, std::function<void(Reprog_device*)>>(d_prog,deleter);
}

void Reprog_device::destroy()
{
    if( _relists_mem )
        RMM_FREE(_relists_mem,0);
    RMM_FREE(_insts,0);
    delete this;
}

} // namespace detail
} // namespace strings
} // namespace cudf
