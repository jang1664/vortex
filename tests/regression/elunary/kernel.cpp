#include "common.h"
#include <vx_spawn.h>
#include <vx_intrinsics.h>

// Type aliases
using data_t = float;

///////////////////////////////////////////////////////////////////////////////
// Pure single-precision math functions — avoid libc which uses 'd' extension
///////////////////////////////////////////////////////////////////////////////

// --- expf: e^x via 2^(x/ln2) decomposition + degree-4 polynomial ---
static inline float my_expf(float x) {
  if (x > 88.7f)  return 3.4028235e+38f;
  if (x < -87.3f) return 0.0f;
  const float LOG2E = 1.4426950408889634f;
  float t = x * LOG2E;
  int n = (int)t;
  if ((float)n > t) n--;
  float f = t - (float)n;
  float p = 1.0f + f * (0.6931472f + f * (0.2402265f + f * (0.0555041f + f * 0.0096139f)));
  union { float fval; unsigned int ival; } u;
  u.fval = p;
  u.ival += (unsigned int)n << 23;
  return u.fval;
}

// --- logf: ln(x) via IEEE 754 decomposition + polynomial ---
// x = m * 2^e where m in [1,2), then ln(x) = e*ln(2) + ln(m)
static inline float my_logf(float x) {
  if (x <= 0.0f) {
    // Return -inf for 0, NaN for negative (simplified)
    union { unsigned int i; float f; } u;
    u.i = (x == 0.0f) ? 0xFF800000u : 0x7FC00000u;
    return u.f;
  }
  union { float f; unsigned int i; } u;
  u.f = x;
  int e = (int)((u.i >> 23) & 0xFF) - 127;
  u.i = (u.i & 0x007FFFFFu) | 0x3F800000u; // m in [1,2)
  float m = u.f;
  // ln(m) for m in [1,2) via polynomial in (m-1)
  float t = m - 1.0f;
  // Degree-4 minimax on [0,1): ln(1+t) ≈ t - t²/2 + t³/3 - t⁴/4
  float ln_m = t * (1.0f + t * (-0.4999999f + t * (0.3333145f + t * (-0.2411767f))));
  const float LN2 = 0.6931471805599453f;
  return (float)e * LN2 + ln_m;
}

// --- sinf / cosf: Cody-Waite range reduction + degree-5/4 polynomial ---
// Reduce x to [-pi/2, pi/2] then use polynomial approximation
static inline float my_sinf(float x) {
  // Range reduction: x = k*pi/2 + r, |r| <= pi/4
  const float TWO_OVER_PI = 0.6366197723675814f;
  const float PI_OVER_2_HI = 1.5707963267f;
  const float PI_OVER_2_LO = 7.5497894159e-08f;

  float j = x * TWO_OVER_PI;
  int k = (j >= 0.0f) ? (int)(j + 0.5f) : (int)(j - 0.5f);
  float r = x - (float)k * PI_OVER_2_HI;
  r = r - (float)k * PI_OVER_2_LO;

  int quad = k & 3;
  if (quad < 0) quad += 4;

  // For quadrants 2,3 → negate result
  bool negate = (quad == 2 || quad == 3);
  // For quadrants 1,2 → use cosine (even) polynomial
  bool use_cos = (quad == 1 || quad == 3);

  float r2 = r * r;
  float result;
  if (use_cos) {
    // cos(r) ≈ 1 - r²/2 + r⁴/24 - r⁶/720
    result = 1.0f + r2 * (-0.5f + r2 * (0.04166666f + r2 * (-0.001388889f)));
  } else {
    // sin(r) ≈ r - r³/6 + r⁵/120 - r⁷/5040
    result = r * (1.0f + r2 * (-0.16666667f + r2 * (0.008333333f + r2 * (-0.0001984127f))));
  }
  return negate ? -result : result;
}

static inline float my_cosf(float x) {
  // cos(x) = sin(x + pi/2)
  const float PI_OVER_2 = 1.5707963267948966f;
  return my_sinf(x + PI_OVER_2);
}

// --- fabsf: bit manipulation, no libc needed ---
static inline float my_fabsf(float x) {
  union { float f; unsigned int i; } u;
  u.f = x;
  u.i &= 0x7FFFFFFFu;
  return u.f;
}

// --- sqrtf: hardware fsqrt.s should be available, but provide fallback ---
// On rv64imaf, fsqrt.s is a native instruction, so __builtin_sqrtf is safe.
static inline float my_sqrtf(float x) {
  return __builtin_sqrtf(x);
}

///////////////////////////////////////////////////////////////////////////////
// Element-wise Unary Operations Kernel
// 
// Supports: rsqrt, sin, cos, exp, log, neg, abs, sqrt
// 
// Critical for transformers:
// - rsqrt: RMSNorm (1/sqrt(x))
// - sin/cos: Rotary Position Embedding (RoPE)
// - exp: Softmax computation
///////////////////////////////////////////////////////////////////////////////

void kernel_rsqrt(kernel_arg_t *__UNIFORM__ arg) {
  auto pInput = reinterpret_cast<data_t *>(arg->input_addr);
  auto pOutput = reinterpret_cast<data_t *>(arg->output_addr);
  uint32_t size = arg->size;
  
  uint32_t total_threads = gridDim.x * blockDim.x;
  uint32_t thread_id = blockIdx.x * blockDim.x + threadIdx.x;
  
  for (uint32_t i = thread_id; i < size; i += total_threads) {
    pOutput[i] = 1.0f / my_sqrtf(pInput[i]);
  }
}

void kernel_sin(kernel_arg_t *__UNIFORM__ arg) {
  auto pInput = reinterpret_cast<data_t *>(arg->input_addr);
  auto pOutput = reinterpret_cast<data_t *>(arg->output_addr);
  uint32_t size = arg->size;
  
  uint32_t total_threads = gridDim.x * blockDim.x;
  uint32_t thread_id = blockIdx.x * blockDim.x + threadIdx.x;
  
  for (uint32_t i = thread_id; i < size; i += total_threads) {
    pOutput[i] = my_sinf(pInput[i]);
  }
}

void kernel_cos(kernel_arg_t *__UNIFORM__ arg) {
  auto pInput = reinterpret_cast<data_t *>(arg->input_addr);
  auto pOutput = reinterpret_cast<data_t *>(arg->output_addr);
  uint32_t size = arg->size;
  
  uint32_t total_threads = gridDim.x * blockDim.x;
  uint32_t thread_id = blockIdx.x * blockDim.x + threadIdx.x;
  
  for (uint32_t i = thread_id; i < size; i += total_threads) {
    pOutput[i] = my_cosf(pInput[i]);
  }
}

void kernel_exp(kernel_arg_t *__UNIFORM__ arg) {
  auto pInput = reinterpret_cast<data_t *>(arg->input_addr);
  auto pOutput = reinterpret_cast<data_t *>(arg->output_addr);
  uint32_t size = arg->size;
  
  uint32_t total_threads = gridDim.x * blockDim.x;
  uint32_t thread_id = blockIdx.x * blockDim.x + threadIdx.x;
  
  for (uint32_t i = thread_id; i < size; i += total_threads) {
    pOutput[i] = my_expf(pInput[i]);
  }
}

void kernel_log(kernel_arg_t *__UNIFORM__ arg) {
  auto pInput = reinterpret_cast<data_t *>(arg->input_addr);
  auto pOutput = reinterpret_cast<data_t *>(arg->output_addr);
  uint32_t size = arg->size;
  
  uint32_t total_threads = gridDim.x * blockDim.x;
  uint32_t thread_id = blockIdx.x * blockDim.x + threadIdx.x;
  
  for (uint32_t i = thread_id; i < size; i += total_threads) {
    pOutput[i] = my_logf(pInput[i]);
  }
}

void kernel_neg(kernel_arg_t *__UNIFORM__ arg) {
  auto pInput = reinterpret_cast<data_t *>(arg->input_addr);
  auto pOutput = reinterpret_cast<data_t *>(arg->output_addr);
  uint32_t size = arg->size;
  
  uint32_t total_threads = gridDim.x * blockDim.x;
  uint32_t thread_id = blockIdx.x * blockDim.x + threadIdx.x;
  
  for (uint32_t i = thread_id; i < size; i += total_threads) {
    pOutput[i] = -pInput[i];
  }
}

void kernel_abs(kernel_arg_t *__UNIFORM__ arg) {
  auto pInput = reinterpret_cast<data_t *>(arg->input_addr);
  auto pOutput = reinterpret_cast<data_t *>(arg->output_addr);
  uint32_t size = arg->size;
  
  uint32_t total_threads = gridDim.x * blockDim.x;
  uint32_t thread_id = blockIdx.x * blockDim.x + threadIdx.x;
  
  for (uint32_t i = thread_id; i < size; i += total_threads) {
    pOutput[i] = my_fabsf(pInput[i]);
  }
}

void kernel_sqrt(kernel_arg_t *__UNIFORM__ arg) {
  auto pInput = reinterpret_cast<data_t *>(arg->input_addr);
  auto pOutput = reinterpret_cast<data_t *>(arg->output_addr);
  uint32_t size = arg->size;
  
  uint32_t total_threads = gridDim.x * blockDim.x;
  uint32_t thread_id = blockIdx.x * blockDim.x + threadIdx.x;
  
  for (uint32_t i = thread_id; i < size; i += total_threads) {
    pOutput[i] = my_sqrtf(pInput[i]);
  }
}

///////////////////////////////////////////////////////////////////////////////
// Kernel dispatch
///////////////////////////////////////////////////////////////////////////////
void kernel_dispatcher(kernel_arg_t *__UNIFORM__ arg) {
  switch (arg->kernel_id) {
    case KERNEL_RSQRT: kernel_rsqrt(arg); break;
    case KERNEL_SIN:   kernel_sin(arg);   break;
    case KERNEL_COS:   kernel_cos(arg);   break;
    case KERNEL_EXP:   kernel_exp(arg);   break;
    case KERNEL_LOG:   kernel_log(arg);   break;
    case KERNEL_NEG:   kernel_neg(arg);   break;
    case KERNEL_ABS:   kernel_abs(arg);   break;
    case KERNEL_SQRT:  kernel_sqrt(arg);  break;
    default: break;
  }
}

///////////////////////////////////////////////////////////////////////////////
// Main entry point
///////////////////////////////////////////////////////////////////////////////
int main() {
  auto arg = (kernel_arg_t *)csr_read(VX_CSR_MSCRATCH);
  return vx_spawn_threads(1, arg->grid_dim, arg->block_dim,
                         (vx_kernel_func_cb)kernel_dispatcher, arg);
}
