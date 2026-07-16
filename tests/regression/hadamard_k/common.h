#ifndef _HADAMARD_COMMON_H_
#define _HADAMARD_COMMON_H_

#include <stdint.h>

#define KERNEL_HADAMARD 0

// Mixed-radix FWHT contract (matches SpinQuant's hadamard_transform()):
//   n = dim (logical row length), K = base-matrix size from get_hadK(n).
//     - K == 1  : n is a pure power of 2 -> this kernel performs the FULL
//                 transform (all log2(padded_dim) butterfly stages), exactly
//                 like the original hadamard kernel. Set stop_stride =
//                 padded_dim (or leave it 0, see effective default below).
//     - K  > 1  : n % K == 0 and n/K is a power of 2 (e.g. LLaMA-2-7B,
//                 n=11008, K=172). The device only performs the first
//                 log2(n/K) butterfly stages and STOPS, leaving K
//                 independently-transformed contiguous blocks of size
//                 n/K each (block k occupies flat range
//                 [k*(n/K), (k+1)*(n/K))). Set stop_stride = padded_dim / K.
//                 The remaining KxK base-matrix multiply (mixing the K
//                 blocks together along the block axis) is NOT done on
//                 device -- it is delegated to the host/PyTorch native
//                 `bmm` (see main.cpp / kernel.cpp comments for the exact
//                 reshape needed).
//   For K > 1, padded_dim MUST equal dim exactly (no zero-padding is
//   allowed, since n/K is already a power of 2 by construction).
typedef struct {
  uint32_t kernel_id;
  uint32_t grid_dim[3];
  uint32_t block_dim[3];

  uint64_t input_addr;
  uint64_t output_addr;

  uint32_t rows;
  uint32_t dim;
  uint32_t padded_dim;
  // Stage at which the butterfly stops: loop runs while stride < stop_stride.
  // stop_stride == padded_dim   -> full transform (K == 1 case).
  // stop_stride == padded_dim/K -> early-stop, base KxK matmul left to host.
  // If left as 0, the kernel defaults it to padded_dim (full transform),
  // matching the original kernel's behavior.
  uint32_t stop_stride;
  float inv_sqrt_dim;
  uint32_t power_kernel_iterations;
} kernel_arg_t;
#endif // _HADAMARD_COMMON_H_
