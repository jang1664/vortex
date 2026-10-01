
#ifndef _COMMON_H_
#define _COMMON_H_

#include <stdint.h>

#ifndef NUM_THREADS
#define NUM_THREADS 4
#endif

#ifndef ITYPE
#define ITYPE fp16
#endif

#ifndef WTYPE
#define WTYPE int4
#endif

#ifndef OTYPE
#define OTYPE fp32
#endif

// Kernel IDs
#define KERNEL_DEQUANT       0  // int4 -> fp16 dequantization
#define KERNEL_GEMM          1  // fp16 x fp16 GEMM (standard)
#define KERNEL_FUSED         2  // fused dequant + GEMM

typedef struct {
  uint32_t kernel_id;         // Which kernel to run
  uint32_t grid_dim[2];       // Grid dimensions
  uint32_t block_dim[2];      // Block dimensions
  
  // Matrix dimensions
  uint32_t M, N, K;
  
  // For all kernels
  uint64_t A_addr;            // Activations (fp16) [M x K]
  uint64_t C_addr;            // Output (fp16 or fp32) [M x N]
  
  // For KERNEL_DEQUANT
  uint64_t W_int4_addr;       // Quantized weights (int4, packed) [K x N]
  uint64_t W_fp16_addr;       // Dequantized weights (fp16) [K x N]
  uint64_t scales_addr;       // Scales (fp16) [K/group_size x N]
  uint64_t zeros_addr;        // Zero points (fp16) [K/group_size x N]
  uint32_t group_size;        // Quantization group size (e.g., 128)
  
  // For KERNEL_GEMM (uses W_fp16_addr as B matrix)
  uint64_t B_addr;            // Weight matrix (fp16) [K x N] - alias for W_fp16_addr
  
  // For KERNEL_FUSED (uses W_int4_addr, scales, zeros directly)
  // Same as KERNEL_DEQUANT inputs but no W_fp16_addr output
} kernel_arg_t;

#endif // _COMMON_H_