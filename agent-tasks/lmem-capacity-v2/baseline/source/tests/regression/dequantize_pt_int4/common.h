#ifndef _DEQUANTIZE_PT_INT4_COMMON_H_
#define _DEQUANTIZE_PT_INT4_COMMON_H_

#include <stdint.h>

// Quantization modes — mirrors quant_utils.py `mode` parameter
// ("sym" / "asym") for dequantize_per_token().
#define QMODE_SYM  0
#define QMODE_ASYM 1

// Kernel IDs
#define KERNEL_DEQUANTIZE_PT_INT4 0

// Kernel arguments structure
typedef struct {
  uint32_t kernel_id;
  uint32_t grid_dim[3];     // Grid dimensions
  uint32_t block_dim[3];    // Block dimensions

  // Input/Output pointers
  uint64_t q_addr;          // int8 row-major [n_rows, D] — signed int4 values in [-8, 7]
  uint64_t scale_addr;      // fp16 [n_rows] — per-row scale S
  uint64_t zero_addr;       // fp16 [n_rows] — per-row zero-point z (only read when mode == QMODE_ASYM)
  uint64_t output_addr;     // fp16 row-major [n_rows, D] — dequantized output x

  // Tensor dimensions
  uint32_t n_rows;          // number of tokens (product of all leading dims)
  uint32_t D;                // row length (last dim)

  // Quantization parameters
  uint32_t mode;             // QMODE_SYM (0) or QMODE_ASYM (1)

  uint32_t power_kernel_iterations;
} kernel_arg_t;
#endif // _DEQUANTIZE_PT_INT4_COMMON_H_
