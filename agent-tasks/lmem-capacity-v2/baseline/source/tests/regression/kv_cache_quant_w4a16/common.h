#ifndef _KV_CACHE_QUANT_W4A16_COMMON_H_
#define _KV_CACHE_QUANT_W4A16_COMMON_H_

#include <stdint.h>

#define KERNEL_KV_CACHE_QUANT_W4A16 0

#define KV_QUANT_LEGACY_UINT4_ASYMMETRIC 0
#define KV_QUANT_SPINQUANT_SIGNED_ASYMMETRIC 1
#define KV_QUANT_SPINQUANT_SIGNED_SYMMETRIC 2

#define KV_CACHE_QUANT_MAPPING_THREAD_GROUP 0
#define KV_CACHE_QUANT_MAPPING_WARP_GROUP 1

typedef struct {
  uint32_t kernel_id;
  uint32_t grid_dim[3];
  uint32_t block_dim[3];

  uint64_t src_addr;    // fp16 row-major [K, N]
  uint64_t dst_addr;    // uint4 packed row-major [K, N/2]
  uint64_t scale_addr;  // fp16 qparams: QDIR0 [ceil(K/QBLK), N], QDIR1 [K, ceil(N/QBLK)]
  uint64_t zero_addr;   // int16 qparams, same shape as scale

  uint32_t K;
  uint32_t N;
  uint32_t QBLK;
  uint32_t QDIR;
  uint32_t WTRANS;      // Consumed by the following standalone tiler; this output stays row-major.
  uint32_t quant_mode;
  uint32_t mapping_mode;
  uint32_t log2_qblk;   // UINT32_MAX when QBLK is not a power of two.
  uint32_t power_kernel_iterations;
} kernel_arg_t;
#endif // _KV_CACHE_QUANT_W4A16_COMMON_H_
