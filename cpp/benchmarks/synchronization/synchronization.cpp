#include "synchronization.hpp"

int cuda_event_timer::l2_cache_bytes = 0;
int cuda_event_timer::current_device = 0;
int* cuda_event_timer::l2_cache_buffer = nullptr;
bool initialized = false;

void cuda_event_timer::init() {
  
  if(!initialized){
    // The CUDA device is not expected to change during one benchmark
    // so query the L2$ size once per run should be fine.
    CUDA_TRY(cudaGetDevice(&current_device));
    CUDA_TRY(cudaDeviceGetAttribute(&l2_cache_bytes, cudaDevAttrL2CacheSize, current_device));
    initialized = true;
  }
  
  // Invalidate all of L2$
  if(l2_cache_bytes > 0){
    RMM_TRY(RMM_ALLOC(&l2_cache_buffer, l2_cache_bytes, 0));
    CUDA_TRY(cudaMemset(l2_cache_buffer, 0, l2_cache_bytes));
    RMM_TRY(RMM_FREE(l2_cache_buffer, 0));
  }
 
  CUDA_TRY(cudaEventCreate(&start));
  CUDA_TRY(cudaEventCreate(&stop));
  CUDA_TRY(cudaEventRecord(start));
 
}

cuda_event_timer::cuda_event_timer() {
  init();
}

cuda_event_timer::cuda_event_timer::cuda_event_timer(benchmark::State& state): p_state(&state) {
  init();
}

cuda_event_timer::~cuda_event_timer(){  
  
  CUDA_TRY(cudaEventRecord(stop));
  CUDA_TRY(cudaEventSynchronize(stop));
 
  float milliseconds = 0.0f;
  CUDA_TRY(cudaEventElapsedTime(&milliseconds, start, stop));
  if(p_state){
    p_state->SetIterationTime(milliseconds/(1000.0f));
  }
  CUDA_TRY(cudaEventDestroy(start));
  CUDA_TRY(cudaEventDestroy(stop));

}

