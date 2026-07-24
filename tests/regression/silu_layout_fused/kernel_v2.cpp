#include "common.h"
#include "../vector_common/fp16.h"
#include <vx_spawn.h>
#include <vx_intrinsics.h>
#include <vx_math.h>

using data_t = fp16_t;

///////////////////////////////////////////////////////////////////////////////
// Two kernels, same binary:
//
//   silu (baseline):
//       out[i] = x * sigmoid(x)             , for i in [0, size)
//       Read+compute+Write i-th element (flat row-major output).
//
//   silu_layout_fused:
//       Same SiLU math, but reads and writes GEMM-C tiled buffers. This keeps
//       the gate projection output in GEMM-C layout until elmul consumes it.
//
//       i.e., fuses (GEMM-C detile) + (silu) + (GEMM-C retile) away.
//
// The two kernels do IDENTICAL work per element (1 fp32 expf + 1 div + 1 mul
// + 1 fp32 load + 1 fp32 store), so any timing delta isolates the
// address-remap overhead.
///////////////////////////////////////////////////////////////////////////////

static inline float silu(float x) {
  return x / (1.0f + vx_expf(-x));
}

#ifdef SILU_LINEAR_SKIP_PAD_ROWS
static inline bool is_power_of_two(uint32_t value) {
  return value != 0u && (value & (value - 1u)) == 0u;
}
#endif

void kernel_silu(kernel_arg_t *__UNIFORM__ arg) {
  auto pInput  = reinterpret_cast<data_t *>(arg->input_addr);
  auto pOutput = reinterpret_cast<data_t *>(arg->output_addr);
  const uint32_t size = arg->size;

  const uint32_t total_threads = gridDim.x * blockDim.x;
  const uint32_t thread_id     = blockIdx.x * blockDim.x + threadIdx.x;

  for (uint32_t i = thread_id; i < size; i += total_threads) {
    pOutput[i] = float_to_fp16(silu(fp16_to_float(pInput[i])));
  }
}

///////////////////////////////////////////////////////////////////////////////
// Store-address A/B kernel.
//
// KERNEL_SILU_ROW_MATCHED and KERNEL_SILU_LAYOUT_FUSED both execute this same
// function body. The loop traversal, input load, SiLU compute, and address
// arithmetic are shared; only the selected store address differs.
///////////////////////////////////////////////////////////////////////////////
void kernel_silu_store_matched(kernel_arg_t *__UNIFORM__ arg) {
  auto pInput  = reinterpret_cast<data_t *>(arg->input_addr);
  auto pOutput = reinterpret_cast<data_t *>(arg->output_addr);
  const uint32_t M_real = arg->M_real;
  const uint32_t M_pad  = arg->M_pad;
  const uint32_t K      = arg->K;
  const uint32_t log2_mt     = arg->log2_mt;
  const uint32_t log2_mxu_kt = arg->log2_mxu_kt;
  // Current fpint tiles use MXU_KT == MXU_NT == 32; reuse the existing ABI field.
  const uint32_t log2_mxu_nt = arg->log2_mxu_kt;
  const uint64_t layout_mask =
      (arg->kernel_id == KERNEL_SILU_LAYOUT_FUSED) ? ~uint64_t(0) : uint64_t(0);
  const uint64_t row_mask = ~layout_mask;

  const uint32_t mt          = 1u << log2_mt;
  const uint32_t mt_mask     = mt - 1u;
  const uint32_t mxu_nt      = 1u << log2_mxu_nt;
  const uint32_t mxu_nt_mask = mxu_nt - 1u;

  const uint32_t k_chunks = K >> log2_mxu_nt;
  const uint32_t total_threads = gridDim.x * blockDim.x;
  const uint32_t thread_id = blockIdx.x * blockDim.x + threadIdx.x;

#ifdef SILU_USE_LINEAR_TILED
  if (arg->kernel_id == KERNEL_SILU_LAYOUT_FUSED) {
#ifdef SILU_LINEAR_SKIP_PAD_ROWS
    if (M_real != M_pad && M_real < mt && is_power_of_two(M_real)) {
      // Generation uses M=1/2/4 with M_pad=8. Compact useful elements in a
      // 32-column slot occupy [M_real][32]; insert each [M_pad][32] tile gap
      // with shifts while avoiding all padded-row SiLU evaluations.
      const uint32_t log2_m = __builtin_ctz(M_real);
      const uint32_t log2_compact_group = log2_m + log2_mxu_nt;
      const uint32_t log2_padded_group =
          __builtin_ctz(M_pad) + log2_mxu_nt;
      const uint32_t compact_group_mask =
          (1u << log2_compact_group) - 1u;
      const uint32_t total = M_real * K;
      for (uint32_t i = thread_id; i < total; i += total_threads) {
        const uint32_t physical_i =
            ((i >> log2_compact_group) << log2_padded_group)
          + (i & compact_group_mask);
        pOutput[physical_i] =
            float_to_fp16(silu(fp16_to_float(pInput[physical_i])));
      }
      return;
    }
#endif
    // Input and output use the same GEMM-C slot order. Pad rows contain zero
    // and may be processed safely, avoiding all row/tile address decoding.
    const uint32_t total = M_pad * K;
    for (uint32_t i = thread_id; i < total; i += total_threads)
      pOutput[i] = float_to_fp16(silu(fp16_to_float(pInput[i])));
    return;
  }
#endif

  for (uint32_t m = 0; m < M_real; ++m) {
    const uint64_t in_row_base = (uint64_t)m * K;
    const uint32_t mt_idx = m >> log2_mt;
    const uint32_t m0 = m & mt_mask;
    const uint32_t cm = ((M_pad - (mt_idx << log2_mt)) < mt)
                      ? (M_pad - (mt_idx << log2_mt))
                      : mt;

    for (uint32_t k_chunk = thread_id; k_chunk < k_chunks; k_chunk += total_threads) {
      const uint32_t gk_base = k_chunk << log2_mxu_nt;
      const uint32_t n0 = gk_base & mxu_nt_mask;

      const uint64_t row_base = in_row_base + gk_base;
      const uint64_t tile_out_base =
          (uint64_t)mt_idx * mt * K
        + (uint64_t)k_chunk * cm * mxu_nt
        + (uint64_t)m0 * mxu_nt
        + n0;
      const uint64_t in_base = (tile_out_base & layout_mask)
                             | (row_base & row_mask);
      const uint64_t row_out_base = row_base;
      const uint64_t out_base = (tile_out_base & layout_mask)
                              | (row_out_base & row_mask);

      for (uint32_t k_in_sub = 0; k_in_sub < mxu_nt; ++k_in_sub) {
        pOutput[out_base + k_in_sub] =
            float_to_fp16(silu(fp16_to_float(pInput[in_base + k_in_sub])));
      }
    }
  }
}

void kernel_dispatcher(kernel_arg_t *__UNIFORM__ arg) {
  switch (arg->kernel_id) {
    case KERNEL_SILU:               kernel_silu(arg);              break;
    case KERNEL_SILU_LAYOUT_FUSED:  kernel_silu_store_matched(arg); break;
    case KERNEL_SILU_ROW_MATCHED:   kernel_silu_store_matched(arg); break;
    default: break;
  }
}

static inline uint32_t effective_power_kernel_iterations(const kernel_arg_t* arg) {
  return (arg->power_kernel_iterations == 0u) ? 1u : arg->power_kernel_iterations;
}

void kernel_dispatcher_power(kernel_arg_t *__UNIFORM__ arg) {
  const uint32_t repeat = effective_power_kernel_iterations(arg);
  for (uint32_t power_iter = 0; power_iter < repeat; ++power_iter) {
    kernel_dispatcher(arg);
  }
}

int main() {
  auto arg = (kernel_arg_t *)csr_read(VX_CSR_MSCRATCH);
  return vx_spawn_threads(1, arg->grid_dim, arg->block_dim,
                          (vx_kernel_func_cb)kernel_dispatcher_power, arg);
}
