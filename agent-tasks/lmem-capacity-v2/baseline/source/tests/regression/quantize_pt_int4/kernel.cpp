#include "common.h"
#include "../vector_common/fp16.h"
#include <vx_spawn.h>
#include <vx_intrinsics.h>

// Type aliases
using data_t = fp16_t;

///////////////////////////////////////////////////////////////////////////////
// Per-token int4 quantization kernel
//
// Matches spinquant_inference/utils/quant_utils.py: quantize_per_token()
// with groupsize == D (one scale/zero per row, reducing over the last dim).
//
//   sym  (mode == QMODE_SYM):
//     abs_max = max(|x_i|)  over the row, clamped to >= 1e-8
//     S       = abs_max / 7.5
//     q_i     = clamp(round(x_i / S), -8, 7)
//
//   asym (mode == QMODE_ASYM):
//     x_min   = min(x_i), x_max = max(x_i)  over the row
//     S       = clamp((x_max - x_min) / 15, min=1e-8)
//     z       = round(-x_min / S) - 8
//     q_i     = clamp(round(x_i / S) + z, -8, 7)
//
// Rounding is round-half-to-even, matching torch.round().
//
// Strategy: one thread-block per row/token. Shared-memory tree reduction
// (same pattern as rmsnorm) computes the per-row abs-max (sym) or
// min/max (asym), then every thread quantizes its share of the row.
//
// NOTE: libm floorf()/roundf()/fmodf() are avoided on purpose — on this
// Vortex LLVM backend, those lower through a custom-inserter pseudo op
// ("PseudoFROUND") that is unimplemented for potentially-divergent control
// flow ("error: unimplemented divergent codegen found!"). Rounding below is
// therefore built from plain int<->float casts and comparisons only (the
// same "branchless floor" trick used in kernel/include/vx_math.h).
///////////////////////////////////////////////////////////////////////////////

// Round-half-to-even (banker's rounding), matching torch.round() semantics.
// Implemented without libm floor/round/fmod — see NOTE above.
static inline float round_half_even(float x) {
  // Branchless truncate-toward-zero via native int cast, then correct down
  // to a true floor() for negative non-integers.
  int trunc_i = (int)x;
  float trunc_f = (float)trunc_i;
  int floor_i = trunc_i - (int)(trunc_f > x);
  float floor_x = (float)floor_i;

  float diff = x - floor_x;  // fractional part, in [0, 1)
  int floor_is_odd = floor_i & 1;
  int round_up = (int)(diff > 0.5f) | ((diff == 0.5f) & floor_is_odd);
  return floor_x + (float)round_up;
}

// Clamp a quantized value to the signed int4 range [-8, 7].
static inline int8_t clamp_int4(float q) {
  q = __builtin_fmaxf(-8.0f, __builtin_fminf(7.0f, q));
  return (int8_t)q;
}

void kernel_quantize_pt_int4(kernel_arg_t *__UNIFORM__ arg) {
  auto pInput = reinterpret_cast<data_t *>(arg->input_addr);
  auto pQ     = reinterpret_cast<int8_t *>(arg->q_addr);
  auto pScale = reinterpret_cast<data_t *>(arg->scale_addr);
  auto pZero  = reinterpret_cast<data_t *>(arg->zero_addr);

  uint32_t n_rows = arg->n_rows;
  uint32_t D = arg->D;
  uint32_t mode = arg->mode;
  uint32_t packed = arg->packed;

  int cache_idx = threadIdx.x;

  // Each block processes one row/token.
  uint32_t row = blockIdx.x;
  if (row >= n_rows) return;

  auto pRow = pInput + (uint64_t)row * D;
  auto pQRow = pQ + (uint64_t)row * (packed ? (D / 2) : D);

  // Shared memory for the reduction. Note: __syncthreads() must not be
  // nested inside a branch on `mode` (even though `mode` is uniform across
  // the block) — the Vortex backend rejects barriers under divergent-looking
  // control flow. So we unconditionally reduce abs-max *and* min/max
  // together, then pick which result to use for the (barrier-free) math.
  auto cache_min = reinterpret_cast<float*>(__local_mem(3 * blockDim.x * sizeof(float)));
  auto cache_max = cache_min + blockDim.x;
  auto cache_amax = cache_max + blockDim.x;

  // Phase 1: per-thread partial min / max / abs-max.
  float local_min = 1e30f;
  float local_max = -1e30f;
  float local_amax = 0.0f;
  for (uint32_t i = cache_idx; i < D; i += blockDim.x) {
    float v = fp16_to_float(pRow[i]);
    local_min = __builtin_fminf(local_min, v);
    local_max = __builtin_fmaxf(local_max, v);
    local_amax = __builtin_fmaxf(local_amax, __builtin_fabsf(v));
  }
  cache_min[cache_idx] = local_min;
  cache_max[cache_idx] = local_max;
  cache_amax[cache_idx] = local_amax;
  __syncthreads();

  // Tree reduction in shared memory.
  for (int i = blockDim.x / 2; i != 0; i /= 2) {
    if (cache_idx < i) {
      cache_min[cache_idx] = __builtin_fminf(cache_min[cache_idx], cache_min[cache_idx + i]);
      cache_max[cache_idx] = __builtin_fmaxf(cache_max[cache_idx], cache_max[cache_idx + i]);
      cache_amax[cache_idx] = __builtin_fmaxf(cache_amax[cache_idx], cache_amax[cache_idx + i]);
    }
    __syncthreads();
  }

  float x_min = cache_min[0];
  float x_max = cache_max[0];
  float abs_max = cache_amax[0];

  // Phase 2: derive scale/zero per mode (no barriers below this point).
  float S, z;
  if (mode == QMODE_SYM) {
    abs_max = __builtin_fmaxf(abs_max, 1e-8f);
    S = abs_max / 7.5f;
    z = 0.0f;  // unused in sym mode
  } else {
    S = __builtin_fmaxf((x_max - x_min) / 15.0f, 1e-8f);
    z = round_half_even(-x_min / S) - 8.0f;
  }

  if (cache_idx == 0) {
    pScale[row] = float_to_fp16(S);
    pZero[row] = float_to_fp16(z);
  }

  // Phase 3: quantize using the fp32 scale (not the fp16-rounded one).
  if (packed == 0) {
    for (uint32_t i = cache_idx; i < D; i += blockDim.x) {
      float v = fp16_to_float(pRow[i]);
      float qf = round_half_even(v / S) + (mode == QMODE_SYM ? 0.0f : z);
      pQRow[i] = clamp_int4(qf);
    }
  } else {
    for (uint32_t pair = cache_idx; pair < D / 2; pair += blockDim.x) {
      const uint32_t i0 = pair * 2;
      const uint32_t i1 = i0 + 1;
      const float v0 = fp16_to_float(pRow[i0]);
      const float v1 = fp16_to_float(pRow[i1]);
      const float qf0 = (mode == QMODE_SYM)
          ? round_half_even(v0 / S) : round_half_even(v0 / S) + z;
      const float qf1 = (mode == QMODE_SYM)
          ? round_half_even(v1 / S) : round_half_even(v1 / S) + z;
      const uint8_t q0 = static_cast<uint8_t>(clamp_int4(qf0)) & 0x0f;
      const uint8_t q1 = static_cast<uint8_t>(clamp_int4(qf1)) & 0x0f;
      reinterpret_cast<uint8_t*>(pQRow)[pair] = q0 | (q1 << 4);
    }
  }
}

///////////////////////////////////////////////////////////////////////////////
// Kernel dispatch
///////////////////////////////////////////////////////////////////////////////
void kernel_dispatcher(kernel_arg_t *__UNIFORM__ arg) {
  switch (arg->kernel_id) {
    case KERNEL_QUANTIZE_PT_INT4:
      kernel_quantize_pt_int4(arg);
      break;
    default:
      break;
  }
}

///////////////////////////////////////////////////////////////////////////////
// Main entry point
///////////////////////////////////////////////////////////////////////////////
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
  return vx_spawn_threads(2, arg->grid_dim, arg->block_dim,
                         (vx_kernel_func_cb)kernel_dispatcher_power, arg);
}
