#ifndef _KV_CACHE_DEQUANT_W4A16_COMMON_H_
#define _KV_CACHE_DEQUANT_W4A16_COMMON_H_

#include "../kv_cache_common/kv_cache_w4a16.h"
#include <stdint.h>

#define KERNEL_KV_CACHE_DEQUANT_W4A16 0

typedef struct {
  uint32_t kernel_id;
  uint32_t grid_dim[3];
  uint32_t block_dim[3];

  uint64_t src_addr;    // uint4 packed row-major [K, N/2]
  uint64_t dst_addr;    // fp16 row-major [K, N]
  uint64_t scale_addr;  // fp16 qparams
  uint64_t zero_addr;   // int16 qparams

  uint32_t K;
  uint32_t N;
  uint32_t QBLK;
  uint32_t QDIR;
  uint32_t WTRANS;      // Accepted for CLI parity; packed source remains n-pair row-major.
  uint32_t quant_mode;  // legacy uint4 or signed int4 affine/symmetric.
  uint32_t power_kernel_iterations;
} kernel_arg_t;
#endif // _KV_CACHE_DEQUANT_W4A16_COMMON_H_
