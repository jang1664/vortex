#include "common.h"
#include <vx_spawn.h>
#include <vx_intrinsics.h>
#include <vx_math.h>

using data_t = float;

///////////////////////////////////////////////////////////////////////////////
// Two kernels, same binary:
//
//   silu (baseline):
//       out[i] = x * sigmoid(x)             , for i in [0, size)
//       Read+compute+Write i-th element (flat row-major output).
//
//   silu_layout_fused:
//       Same SiLU math, but writes are reordered so the output buffer is
//       already in the tile-major (kb, m, k_in_sub) layout that
//       fpint_gemm_ffn_hw expects. Also zero-fills padded rows m >= M_real.
//
//       i.e., fuses (silu) + (M-pad zero fill) + (tile_input_a) into one
//       kernel — no extra reads or writes beyond what silu already does.
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
    pOutput[i] = silu(pInput[i]);
  }
}

///////////////////////////////////////////////////////////////////////////////
// Fused SiLU + tile_input_a — real-rows-only variant
//
// Key insight: pad rows in the input buffer can stay UNINITIALIZED because
// the downstream GEMM only produces correct output for m < M_real anyway
// (output for pad rows m >= M_real is garbage that the wrapper narrows away).
// Skipping the zero-fill means we launch only M_real worth of threads —
// for decode (M_real=1, M_pad=8) that's 8x fewer threads.
//
// Grid (3D):
//   blockIdx.z = kt                       ∈ [0, k_tiles)
//   blockIdx.y = kb                       ∈ [0, k_micros)
//   blockIdx.x*blockDim.x + threadIdx.x   = mk ∈ [0, M_real*MXU_KT)
//
// Output buffer is still sized [M_pad, K] (tile layout), but only the
// M_real real rows get written. Pad rows are left as whatever at::empty gave.
///////////////////////////////////////////////////////////////////////////////
void kernel_silu_layout_fused(kernel_arg_t *__UNIFORM__ arg) {
  auto pInput  = reinterpret_cast<data_t *>(arg->input_addr);
  auto pOutput = reinterpret_cast<data_t *>(arg->output_addr);
  const uint32_t M_real = arg->M_real;
  const uint32_t M_pad  = arg->M_pad;
  const uint32_t K      = arg->K;

  constexpr uint32_t MXU_KT      = TILE_DMA_MXU_KT;     // 32
  constexpr uint32_t LOG2_MXU_KT = 5;
  constexpr uint32_t MXU_KT_MASK = MXU_KT - 1;
  constexpr uint32_t DMA_KT      = TILE_DMA_KT;          // 128

  const uint32_t kt = blockIdx.z;
  const uint32_t kb = blockIdx.y;
  const uint32_t mk = blockIdx.x * blockDim.x + threadIdx.x;

  if (mk >= M_real * MXU_KT) return;          // real rows only

  const uint32_t m        = mk >> LOG2_MXU_KT;
  const uint32_t k_in_sub = mk & MXU_KT_MASK;

  // Output offset uses M_pad (the slot still reserves M_pad rows worth of
  // storage; we just don't write into the pad ones).
  const uint64_t per_kb_elems = (uint64_t)M_pad * MXU_KT;
  const uint64_t per_kt_elems = (uint64_t)gridDim.y * per_kb_elems;
  const uint64_t out_off = (uint64_t)kt * per_kt_elems
                         + (uint64_t)kb * per_kb_elems
                         + (uint64_t)mk;

  const uint32_t gk = kt * DMA_KT + kb * MXU_KT + k_in_sub;
  const uint64_t in_off = (uint64_t)m * K + (uint64_t)gk;
  pOutput[out_off] = silu(pInput[in_off]);
}

void kernel_dispatcher(kernel_arg_t *__UNIFORM__ arg) {
  switch (arg->kernel_id) {
    case KERNEL_SILU:               kernel_silu(arg);              break;
    case KERNEL_SILU_LAYOUT_FUSED:  kernel_silu_layout_fused(arg); break;
    default: break;
  }
}

int main() {
  auto arg = (kernel_arg_t *)csr_read(VX_CSR_MSCRATCH);
  // Use 3D grid count when fused, 1D for plain silu.
  uint32_t num_dim = (arg->kernel_id == KERNEL_SILU_LAYOUT_FUSED) ? 3 : 1;
  return vx_spawn_threads(num_dim, arg->grid_dim, arg->block_dim,
                          (vx_kernel_func_cb)kernel_dispatcher, arg);
}
