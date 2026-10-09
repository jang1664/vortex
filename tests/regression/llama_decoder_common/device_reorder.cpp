// Decoder-only connection between native row-major regression layouts.
#include "common.h"
#include <vx_intrinsics.h>
#include <vx_spawn.h>
static void reorder(DecoderReorderArgs* __UNIFORM__ a) {
 auto* src=reinterpret_cast<const uint16_t*>(a->input);auto* dst=reinterpret_cast<uint16_t*>(a->output);
 uint32_t total=a->batch*a->seq*a->heads*a->dim;
 for(uint32_t i=blockIdx.x*blockDim.x+threadIdx.x;i<total;i+=gridDim.x*blockDim.x){
  if(a->kind==1){uint32_t r=i/a->dim,c=i%a->dim;dst[c*a->seq+r]=src[i];}
  else {uint32_t d=i%a->dim,h=(i/a->dim)%a->heads,s=(i/(a->dim*a->heads))%a->seq,b=i/(a->seq*a->heads*a->dim);dst[((b*a->heads+h)*a->seq+s)*a->dim+d]=src[i];}
 }
}
int llama_reorder_main(){auto* a=reinterpret_cast<DecoderReorderArgs*>(csr_read(VX_CSR_MSCRATCH));return vx_spawn_threads(3,a->grid_dim,a->block_dim,(vx_kernel_func_cb)reorder,a);}
