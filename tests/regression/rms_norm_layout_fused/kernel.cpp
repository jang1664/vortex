#include "common.h"
#include "../vector_common/fp16.h"
#include <vx_spawn.h>
#include <vx_intrinsics.h>
#include <math.h>

using data_t = fp16_t;

///////////////////////////////////////////////////////////////////////////////
// Two kernels, same binary:
//
//   rms_norm (baseline):
//       output[m, i] = input[m, i] * rsqrt(mean(input[m, :]^2) + eps) * gamma[i]
//       Row-major output: out[m * K + i].
//
//   rms_norm_layout_fused:
//       Same RMSNorm math, but writes are reordered so the output buffer is
//       already in the tile-major (kt, kb, m, k_in_sub) layout that
//       fpint_gemm_ffn_hw expects. Pad rows m >= M_real are skipped (we
//       launch only M_real blocks; downstream GEMM only uses real rows).
//
// Both kernels share the same block-wide reduction structure: one block per
// token, threads within the block do partial sum-of-squares then a tree
// reduction in shared memory. Phase 2 normalizes + applies gamma. The only
// difference is the output address computation — so any timing delta isolates
// the layout-remap overhead, exactly like silu_layout_fused.
///////////////////////////////////////////////////////////////////////////////

void kernel_rmsnorm(kernel_arg_t *__UNIFORM__ arg) {
  auto pInput  = reinterpret_cast<data_t *>(arg->input_addr);
  auto pOutput = reinterpret_cast<data_t *>(arg->output_addr);
  auto pGamma  = reinterpret_cast<data_t *>(arg->gamma_addr);

  const uint32_t K   = arg->K;
  const float    eps = arg->eps;

  const uint32_t m    = blockIdx.x;          // one block per real row
  const uint32_t tid  = threadIdx.x;
  const uint32_t bdim = blockDim.x;

  auto pInputRow  = pInput  + (uint64_t)m * K;
  auto pOutputRow = pOutput + (uint64_t)m * K;

  auto cache = reinterpret_cast<float *>(__local_mem(bdim * sizeof(float)));

  // Phase 1: partial sum of squares (per thread).
  float sum_sq = 0.0f;
  for (uint32_t i = tid; i < K; i += bdim) {
    float v = fp16_to_float(pInputRow[i]);
    sum_sq += v * v;
  }
  cache[tid] = sum_sq;
  __syncthreads();

  // Tree reduction in shared memory.
  int r = bdim / 2;
  while (r != 0) {
    if ((int)tid < r) {
      cache[tid] += cache[tid + r];
    }
    __syncthreads();
    r /= 2;
  }
  sum_sq = cache[0];

  const float rms = 1.0f / sqrtf(sum_sq / (float)K + eps);

  // Phase 2: normalize + gamma, row-major write.
  for (uint32_t i = tid; i < K; i += bdim) {
    float v = fp16_to_float(pInputRow[i]);
    float g = fp16_to_float(pGamma[i]);
    pOutputRow[i] = float_to_fp16(v * rms * g);
  }
}

///////////////////////////////////////////////////////////////////////////////
// Fused RMSNorm + tile_input_a — real-rows-only variant.
//
// Pad rows in the output buffer stay uninitialized (downstream GEMM doesn't
// consume them — output for pad rows is discarded by the wrapper).
//
// Grid (1D over real rows):
//   blockIdx.x = m  ∈ [0, M_real)
//   threadIdx.x    = tid ∈ [0, blockDim.x)
//
// Output buffer is sized [M_pad, K] (tile layout slot), but only M_real real
// rows get written. Each thread handles strided K elements and computes the
// tile-major offset per element.
//
// Assumes K is a multiple of TILE_DMA_KT (true for LLaMA hidden_dims).
///////////////////////////////////////////////////////////////////////////////
void kernel_rms_norm_layout_fused(kernel_arg_t *__UNIFORM__ arg) {
  auto pInput  = reinterpret_cast<data_t *>(arg->input_addr);
  auto pOutput = reinterpret_cast<data_t *>(arg->output_addr);
  auto pGamma  = reinterpret_cast<data_t *>(arg->gamma_addr);

  const uint32_t M_pad = arg->M_pad;
  const uint32_t K     = arg->K;
  const float    eps   = arg->eps;
  const uint32_t log2_mt     = arg->log2_mt;
  const uint32_t log2_kt     = arg->log2_kt;
  const uint32_t log2_mxu_kt = arg->log2_mxu_kt;

  const uint32_t mt          = 1u << log2_mt;
  const uint32_t mt_mask     = mt - 1u;
  const uint32_t kt_mask     = (1u << log2_kt) - 1u;
  const uint32_t mxu_kt      = 1u << log2_mxu_kt;
  const uint32_t mxu_kt_mask = mxu_kt - 1u;

  const uint32_t m    = blockIdx.x;          // one block per real row
  const uint32_t tid  = threadIdx.x;
  const uint32_t bdim = blockDim.x;

  auto pInputRow = pInput + (uint64_t)m * K;

  auto cache = reinterpret_cast<float *>(__local_mem(bdim * sizeof(float)));

  // Phase 1: partial sum of squares (identical to plain kernel).
  float sum_sq = 0.0f;
  for (uint32_t i = tid; i < K; i += bdim) {
    float v = fp16_to_float(pInputRow[i]);
    sum_sq += v * v;
  }
  cache[tid] = sum_sq;
  __syncthreads();

  int r = bdim / 2;
  while (r != 0) {
    if ((int)tid < r) {
      cache[tid] += cache[tid + r];
    }
    __syncthreads();
    r /= 2;
  }
  sum_sq = cache[0];

  const float rms = 1.0f / sqrtf(sum_sq / (float)K + eps);

  const uint32_t mt_idx = m >> log2_mt;
  const uint32_t m0 = m & mt_mask;
  const uint32_t cm = ((M_pad - (mt_idx << log2_mt)) < mt)
                    ? (M_pad - (mt_idx << log2_mt))
                    : mt;

  // Phase 2: normalize + gamma, tile-major write.
  for (uint32_t i = tid; i < K; i += bdim) {
    float v = fp16_to_float(pInputRow[i]);
    float g = fp16_to_float(pGamma[i]);
    float out = v * rms * g;

    const uint32_t k_chunk  = i >> log2_mxu_kt;
    const uint32_t k_in_sub = i & mxu_kt_mask;
    (void)kt_mask;

    const uint64_t out_off =
        (uint64_t)mt_idx * mt * K
      + (uint64_t)k_chunk * cm * mxu_kt
      + (uint64_t)m0 * mxu_kt
      + (uint64_t)k_in_sub;
    pOutput[out_off] = float_to_fp16(out);
  }
}

///////////////////////////////////////////////////////////////////////////////
// Standalone tile_input_a (row-major fp32 -> tile-major fp32).
//
// Used to measure the cost of running rms_norm and tile_input_a as two
// separate kernels (the realistic alternative to fusion). Uses the same
// 3D-grid / 1-thread-per-element pattern as silu_layout_fused so we get a
// best-case standalone layout-transform number.
//
// input_addr : fp32 [M_real, K] row-major (the plain rms_norm output)
// output_addr: fp32 [M_pad,  K] tile-major
///////////////////////////////////////////////////////////////////////////////
void kernel_tile_input_a(kernel_arg_t *__UNIFORM__ arg) {
  auto pInput  = reinterpret_cast<data_t *>(arg->input_addr);
  auto pOutput = reinterpret_cast<data_t *>(arg->output_addr);
  const uint32_t M_real = arg->M_real;
  const uint32_t M_pad  = arg->M_pad;
  const uint32_t K      = arg->K;
  const uint32_t log2_mt     = arg->log2_mt;
  const uint32_t log2_kt     = arg->log2_kt;
  const uint32_t log2_mxu_kt = arg->log2_mxu_kt;

  const uint32_t mt          = 1u << log2_mt;
  const uint32_t mt_mask     = mt - 1u;
  const uint32_t mxu_kt      = 1u << log2_mxu_kt;
  const uint32_t mxu_kt_mask = mxu_kt - 1u;

  const uint32_t kt = blockIdx.z;
  const uint32_t kb = blockIdx.y;
  const uint32_t mk = blockIdx.x * blockDim.x + threadIdx.x;

  if (mk >= M_real * mxu_kt) return;

  const uint32_t m        = mk >> log2_mxu_kt;
  const uint32_t k_in_sub = mk & mxu_kt_mask;

  const uint32_t gk = (kt << log2_kt) + (kb << log2_mxu_kt) + k_in_sub;
  if (gk >= K) return;

  const uint32_t mt_idx = m >> log2_mt;
  const uint32_t m0 = m & mt_mask;
  const uint32_t cm = ((M_pad - (mt_idx << log2_mt)) < mt)
                    ? (M_pad - (mt_idx << log2_mt))
                    : mt;
  const uint32_t k_chunk = gk >> log2_mxu_kt;
  const uint64_t out_off =
      (uint64_t)mt_idx * mt * K
    + (uint64_t)k_chunk * cm * mxu_kt
    + (uint64_t)m0 * mxu_kt
    + (uint64_t)k_in_sub;
  pOutput[out_off] = pInput[(uint64_t)m * K + gk];
}

void kernel_dispatcher(kernel_arg_t *__UNIFORM__ arg) {
  switch (arg->kernel_id) {
    case KERNEL_RMSNORM:               kernel_rmsnorm(arg);               break;
    case KERNEL_RMSNORM_LAYOUT_FUSED:  kernel_rms_norm_layout_fused(arg); break;
    case KERNEL_TILE_INPUT_A:          kernel_tile_input_a(arg);          break;
    default: break;
  }
}

int main() {
  auto arg = (kernel_arg_t *)csr_read(VX_CSR_MSCRATCH);
  // 3D grid only for the standalone layout transform.
  uint32_t num_dim = (arg->kernel_id == KERNEL_TILE_INPUT_A) ? 3 : 1;
  return vx_spawn_threads(num_dim, arg->grid_dim, arg->block_dim,
                          (vx_kernel_func_cb)kernel_dispatcher, arg);
}
