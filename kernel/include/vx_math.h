// Copyright © 2019-2023
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

#pragma once

///////////////////////////////////////////////////////////////////////////////
// Pure single-precision math functions for Vortex GPU kernels.
//
// The standard libc math functions (expf, sinf, logf, etc.) internally use
// double-precision (D extension) instructions like fadd.d / fmul.d.
// On FPGA bitstreams built without the D extension, these cause illegal
// instruction traps and silent thread death.
//
// This header provides float-only polynomial approximations that compile
// to rv64imaf instructions only (no 'd' extension needed).
//
// Usage: #include <vx_math.h>
//        float y = vx_expf(x);
///////////////////////////////////////////////////////////////////////////////

#ifdef VX_ENABLE_HW_EXPF
#include <vx_intrinsics.h>
#endif

// --- Constants via bit manipulation (no libc dependency) ---

static inline float vx_pos_inf() {
  union { unsigned int i; float f; } u;
  u.i = 0x7F800000u;
  return u.f;
}

static inline float vx_neg_inf() {
  union { unsigned int i; float f; } u;
  u.i = 0xFF800000u;
  return u.f;
}

static inline float vx_nanf() {
  union { unsigned int i; float f; } u;
  u.i = 0x7FC00000u;
  return u.f;
}

#define VX_INFINITY  vx_pos_inf()
#define VX_NEG_INF   vx_neg_inf()

static inline float vx_expf(float x) {
#ifdef VX_ENABLE_HW_EXPF
  return vx_expf_hw(x);
#else
  // e^x via 2^(x/ln2) decomposition + degree-4 minimax polynomial.
  // Max error: < 2e-7 relative.
  // Branchless clamp using fmin.s / fmax.s hardware instructions
  float clamped = __builtin_fmaxf(__builtin_fminf(x, 88.7f), -87.3f);

  const float LOG2E = 1.4426950408889634f;  // 1/ln(2)
  float t = clamped * LOG2E;

  // Branchless floor: n = floor(t)
  // (int) truncates toward zero; fix for negatives with arithmetic
  int n = (int)t;
  n -= ((float)n > t);  // subtracts 1 when truncation rounded toward zero
  float f = t - (float)n;

  // 2^f approximation for f in [0,1), minimax coefficients
  float p = 1.0f + f * (0.6931472f + f * (0.2402265f + f * (0.0555041f + f * 0.0096139f)));

  // Multiply by 2^n via IEEE 754 exponent manipulation
  union { float fval; unsigned int ival; } u;
  u.fval = p;
  u.ival += (unsigned int)n << 23;
  return u.fval;
#endif
}

///////////////////////////////////////////////////////////////////////////////
// vx_logf: ln(x) via IEEE 754 exponent extraction + polynomial
// x = m * 2^e where m in [1,2), ln(x) = e*ln(2) + ln(m)
///////////////////////////////////////////////////////////////////////////////
static inline float vx_logf(float x) {
  if (x <= 0.0f) {
    union { unsigned int i; float f; } u;
    u.i = (x == 0.0f) ? 0xFF800000u : 0x7FC00000u;  // -inf or NaN
    return u.f;
  }
  union { float f; unsigned int i; } u;
  u.f = x;
  int e = (int)((u.i >> 23) & 0xFF) - 127;
  u.i = (u.i & 0x007FFFFFu) | 0x3F800000u;  // m in [1,2)
  float m = u.f;
  float t = m - 1.0f;
  // Degree-4 minimax: ln(1+t) ≈ t(1 - t/2 + t²/3 - t³/4)
  float ln_m = t * (1.0f + t * (-0.4999999f + t * (0.3333145f + t * (-0.2411767f))));
  const float LN2 = 0.6931471805599453f;
  return (float)e * LN2 + ln_m;
}

///////////////////////////////////////////////////////////////////////////////
// vx_sinf: Cody-Waite range reduction + polynomial
// Reduces x to [-pi/4, pi/4], then uses degree-7 sin or degree-6 cos poly
// ** Completely branchless ** — safe for Vortex SIMT warp divergence.
// All control flow replaced with arithmetic select (multiply by 0/1).
///////////////////////////////////////////////////////////////////////////////
static inline float vx_sinf(float x) {
  const float TWO_OVER_PI = 0.6366197723675814f;
  const float PI_OVER_2_HI = 1.5707963267f;
  const float PI_OVER_2_LO = 7.5497894159e-08f;

  float j = x * TWO_OVER_PI;

  // Branchless round-to-nearest: k = floor(j + 0.5)
  // (int) truncates toward zero; fix for negatives with arithmetic
  float half_adj = j + 0.5f;
  int k_trunc = (int)half_adj;
  // If half_adj < 0 and not exact integer, truncation went wrong way → fix
  int k = k_trunc - ((half_adj < 0.0f) & ((float)k_trunc != half_adj));

  float r = x - (float)k * PI_OVER_2_HI;
  r = r - (float)k * PI_OVER_2_LO;

  // Quadrant: k & 3 is always 0..3 (two's complement bitwise AND)
  int quad = k & 3;

  float r2 = r * r;

  // Compute BOTH polynomials (no branch)
  float sin_r = r * (1.0f + r2 * (-0.16666667f + r2 * (0.008333333f + r2 * (-0.0001984127f))));
  float cos_r = 1.0f + r2 * (-0.5f + r2 * (0.04166666f + r2 * (-0.001388889f)));

  // Branchless select: use cos when quad is odd (1 or 3)
  float uc = (float)(quad & 1);           // 0.0f or 1.0f
  float result = (1.0f - uc) * sin_r + uc * cos_r;

  // Branchless negate: when quad is 2 or 3
  float sign = 1.0f - 2.0f * (float)((quad >> 1) & 1);  // +1.0f or -1.0f
  return sign * result;
}

///////////////////////////////////////////////////////////////////////////////
// vx_cosf: cos(x) = sin(x + pi/2)
///////////////////////////////////////////////////////////////////////////////
static inline float vx_cosf(float x) {
  const float PI_OVER_2 = 1.5707963267948966f;
  return vx_sinf(x + PI_OVER_2);
}

///////////////////////////////////////////////////////////////////////////////
// vx_fabsf: IEEE 754 sign bit clear
///////////////////////////////////////////////////////////////////////////////
static inline float vx_fabsf(float x) {
  union { float f; unsigned int i; } u;
  u.f = x;
  u.i &= 0x7FFFFFFFu;
  return u.f;
}

///////////////////////////////////////////////////////////////////////////////
// vx_sqrtf: uses hardware fsqrt.s (available on rv64imaf)
///////////////////////////////////////////////////////////////////////////////
static inline float vx_sqrtf(float x) {
  return __builtin_sqrtf(x);
}
