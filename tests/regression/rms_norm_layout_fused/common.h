#ifndef _COMMON_H_
#define _COMMON_H_

#include <stdint.h>

// Kernel IDs — all three compiled into the same .vxbin so timing is
// apples-to-apples.
//
//   RMSNORM              : row-major rms_norm (baseline)
//   RMSNORM_LAYOUT_FUSED : rms_norm + tile_input_a fused into one launch
//   TILE_INPUT_A         : row-major -> tile-major transform only (used to
//                          measure cost of the "second kernel" path
//                          [plain rms_norm] + [tile_input_a]).
#define KERNEL_RMSNORM                0
#define KERNEL_RMSNORM_LAYOUT_FUSED   1
#define KERNEL_TILE_INPUT_A           2

// Tile-layout constants — match
// tests/regression/fpint_gemm_ffn_hw/common.h
#define TILE_DMA_KT       128
#define TILE_DMA_MXU_KT    32

typedef struct {
  uint32_t kernel_id;
  uint32_t grid_dim[3];
  uint32_t block_dim[3];

  uint64_t input_addr;     // fp32 [M_real, K]              (both kernels)
  uint64_t output_addr;    // fp32 [M_real, K] flat         (plain)
                           // OR    [M_pad, K] tile-laid    (fused)
  uint64_t gamma_addr;     // fp32 [K]

  uint32_t M_real;         // real rows
  uint32_t M_pad;          // padded M (multiple of 8) — fused output slot height
  uint32_t K;              // hidden_dim — must be multiple of TILE_DMA_KT
  float    eps;
} kernel_arg_t;

#endif // _COMMON_H_
