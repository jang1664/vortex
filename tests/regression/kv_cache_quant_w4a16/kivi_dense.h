#pragma once
#include "../kv_cache_common/kivi_int4.h"

static void quantize_kivi_dense(kernel_arg_t *__UNIFORM__ arg) {
  const auto src = reinterpret_cast<const fp16_t*>(arg->src_addr);
  const auto scale = reinterpret_cast<fp16_t*>(arg->scale_addr);
  const auto zero = reinterpret_cast<int16_t*>(arg->zero_addr);
  const auto dst = reinterpret_cast<uint8_t*>(arg->dst_addr);
#if defined(KV_CACHE_QUANT_INPUT_STRIDE) && KV_CACHE_QUANT_INPUT_STRIDE
  const unsigned pitch = arg->src_row_stride ? arg->src_row_stride : arg->N;
#else
  const unsigned pitch = arg->N;
#endif
  kivi_stage_token(arg->fresh_key_addr,arg->src_addr,pitch,arg->K,arg->N,
      blockIdx.x*blockDim.x+threadIdx.x,gridDim.x*blockDim.x);
  kivi_quant_groups(arg->K, arg->N, arg->QDIR == 0,
      blockIdx.x * blockDim.x + threadIdx.x, gridDim.x * blockDim.x,
      [&](unsigned k, unsigned n) { return src[(uint64_t)k*pitch+n]; },
      [&](unsigned k, unsigned n, kivi_params p) {
        auto idx = kv_qparam_index(k,n,arg->K,arg->N,32,arg->QDIR);
        scale[idx] = p.scale;
        zero[idx] = p.zero;
      },
      [&](unsigned k, unsigned n, unsigned packed) { dst[(uint64_t)k*(arg->N/2)+n/2] = packed; });
}
