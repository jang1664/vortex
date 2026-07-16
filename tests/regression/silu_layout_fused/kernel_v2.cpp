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
