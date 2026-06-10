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

#define VX_EXPF_APPROX_POLY 0
#define VX_EXPF_APPROX_LUT  1

#ifndef VX_EXPF_APPROX
#define VX_EXPF_APPROX VX_EXPF_APPROX_POLY
#endif

#ifndef VX_EXPF_TAYLOR_ORDER
#define VX_EXPF_TAYLOR_ORDER 4
#endif

#ifndef VX_EXPF_LUT_BITS
#define VX_EXPF_LUT_BITS 5
#endif

#if (VX_EXPF_APPROX != VX_EXPF_APPROX_POLY) && (VX_EXPF_APPROX != VX_EXPF_APPROX_LUT)
#error "VX_EXPF_APPROX must be VX_EXPF_APPROX_POLY or VX_EXPF_APPROX_LUT"
#endif

#if (VX_EXPF_TAYLOR_ORDER < 0) || (VX_EXPF_TAYLOR_ORDER > 6)
#error "VX_EXPF_TAYLOR_ORDER must be in the range 0..6"
#endif

#if (VX_EXPF_LUT_BITS != 4) && (VX_EXPF_LUT_BITS != 5) && (VX_EXPF_LUT_BITS != 6)
#error "VX_EXPF_LUT_BITS must be 4, 5, or 6"
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

///////////////////////////////////////////////////////////////////////////////
// vx_expf: e^x via 2^(x/ln2) decomposition.
// Software p=2^f approximation is selected at compile time:
// - VX_EXPF_APPROX_POLY: Taylor-like polynomial, VX_EXPF_TAYLOR_ORDER 0..6
// - VX_EXPF_APPROX_LUT:  left-point LUT + linear interpolation
// Default software mode preserves the existing degree-4 polynomial coefficients.
// Approximate residual max relative error over f in [0,1):
//   poly4: 7.5e-4, LUT16: 9.1e-4, LUT32: 2.3e-4, LUT64: 5.8e-5
// ** Branchless ** — safe for Vortex SIMT (no divergent branches)
///////////////////////////////////////////////////////////////////////////////
static inline float vx_expf_poly_p(float f) {
#if VX_EXPF_TAYLOR_ORDER == 0
  return 1.0f;
#elif VX_EXPF_TAYLOR_ORDER == 1
  return 1.0f + f * 0.6931472f;
#elif VX_EXPF_TAYLOR_ORDER == 2
  return 1.0f + f * (0.6931472f + f * 0.2402265f);
#elif VX_EXPF_TAYLOR_ORDER == 3
  return 1.0f + f * (0.6931472f + f * (0.2402265f + f * 0.0555041f));
#elif VX_EXPF_TAYLOR_ORDER == 4
  return 1.0f + f * (0.6931472f + f * (0.2402265f + f * (0.0555041f + f * 0.0096139f)));
#elif VX_EXPF_TAYLOR_ORDER == 5
  return 1.0f + f * (0.6931472f + f * (0.2402265f + f * (0.0555041f + f * (0.0096139f + f * 0.0013333558f))));
#else
  return 1.0f + f * (0.6931472f + f * (0.2402265f + f * (0.0555041f + f * (0.0096139f + f * (0.0013333558f + f * 0.0001540353f)))));
#endif
}

static inline float vx_expf_lut_p(float f) {
#if VX_EXPF_LUT_BITS == 4
  static const float lut[][2] = {
    {1.0f, 0.693147181f},
    {1.04427378f, 0.723835428f},
    {1.09050773f, 0.75588236f},
    {1.13878863f, 0.789348131f},
    {1.18920712f, 0.824295559f},
    {1.24185781f, 0.860790241f},
    {1.29683955f, 0.898900681f},
    {1.35425555f, 0.938698414f},
    {1.41421356f, 0.980258143f},
    {1.47682615f, 1.02365788f},
    {1.54221083f, 1.06897909f},
    {1.61049033f, 1.11630683f},
    {1.68179283f, 1.16572996f},
    {1.75625216f, 1.21734123f},
    {1.83400809f, 1.27123753f},
    {1.91520656f, 1.32752003f},
  };
#elif VX_EXPF_LUT_BITS == 5
  static const float lut[][2] = {
    {1.0f, 0.693147181f},
    {1.02189715f, 0.708325127f},
    {1.04427378f, 0.723835428f},
    {1.0671404f, 0.73968536f},
    {1.09050773f, 0.75588236f},
    {1.11438674f, 0.772434029f},
    {1.13878863f, 0.789348131f},
    {1.16372486f, 0.806632605f},
    {1.18920712f, 0.824295559f},
    {1.21524736f, 0.842345281f},
    {1.24185781f, 0.860790241f},
    {1.26905096f, 0.879639093f},
    {1.29683955f, 0.898900681f},
    {1.32523664f, 0.918584043f},
    {1.35425555f, 0.938698414f},
    {1.38390988f, 0.959253233f},
    {1.41421356f, 0.980258143f},
    {1.44518081f, 1.001723f},
    {1.47682615f, 1.02365788f},
    {1.50916443f, 1.04607307f},
    {1.54221083f, 1.06897909f},
    {1.57598085f, 1.09238668f},
    {1.61049033f, 1.11630683f},
    {1.64575548f, 1.14075077f},
    {1.68179283f, 1.16572996f},
    {1.7186193f, 1.19125612f},
    {1.75625216f, 1.21734123f},
    {1.79470908f, 1.24399754f},
    {1.83400809f, 1.27123753f},
    {1.87416763f, 1.29907401f},
    {1.91520656f, 1.32752003f},
    {1.95714412f, 1.35658893f},
  };
#else
  static const float lut[][2] = {
    {1.0f, 0.693147181f},
    {1.01088929f, 0.700695058f},
    {1.02189715f, 0.708325127f},
    {1.03302488f, 0.716038282f},
    {1.04427378f, 0.723835428f},
    {1.05564518f, 0.731717479f},
    {1.0671404f, 0.73968536f},
    {1.0787608f, 0.747740005f},
    {1.09050773f, 0.75588236f},
    {1.10238258f, 0.76411338f},
    {1.11438674f, 0.772434029f},
    {1.12652162f, 0.780845284f},
    {1.13878863f, 0.789348131f},
    {1.15118923f, 0.797943569f},
    {1.16372486f, 0.806632605f},
    {1.17639699f, 0.815416258f},
    {1.18920712f, 0.824295559f},
    {1.20215673f, 0.833271549f},
    {1.21524736f, 0.842345281f},
    {1.22848054f, 0.85151782f},
    {1.24185781f, 0.860790241f},
    {1.25538076f, 0.870163632f},
    {1.26905096f, 0.879639093f},
    {1.28287002f, 0.889217735f},
    {1.29683955f, 0.898900681f},
    {1.31096121f, 0.908689068f},
    {1.32523664f, 0.918584043f},
    {1.33966752f, 0.928586767f},
    {1.35425555f, 0.938698414f},
    {1.36900242f, 0.94892017f},
    {1.38390988f, 0.959253233f},
    {1.39897967f, 0.969698816f},
    {1.41421356f, 0.980258143f},
    {1.42961334f, 0.990932455f},
    {1.44518081f, 1.001723f},
    {1.46091779f, 1.01263105f},
    {1.47682615f, 1.02365788f},
    {1.49290773f, 1.03480478f},
    {1.50916443f, 1.04607307f},
    {1.52559815f, 1.05746406f},
    {1.54221083f, 1.06897909f},
    {1.5590044f, 1.0806195f},
    {1.57598085f, 1.09238668f},
    {1.59314215f, 1.10428199f},
    {1.61049033f, 1.11630683f},
    {1.62802742f, 1.12846262f},
    {1.64575548f, 1.14075077f},
    {1.66367658f, 1.15317273f},
    {1.68179283f, 1.16572996f},
    {1.70010635f, 1.17842393f},
    {1.7186193f, 1.19125612f},
    {1.73733384f, 1.20422805f},
    {1.75625216f, 1.21734123f},
    {1.77537649f, 1.23059721f},
    {1.79470908f, 1.24399754f},
    {1.81425218f, 1.25754378f},
    {1.83400809f, 1.27123753f},
    {1.85397913f, 1.2850804f},
    {1.87416763f, 1.29907401f},
    {1.89457598f, 1.31322f},
    {1.91520656f, 1.32752003f},
    {1.93606179f, 1.34197577f},
    {1.95714412f, 1.35658893f},
    {1.97845603f, 1.37136122f},
  };
#endif
  const int idx = (int)(f * (float)(1 << VX_EXPF_LUT_BITS));
  const float f0 = (float)idx * (1.0f / (float)(1 << VX_EXPF_LUT_BITS));
  const float df = f - f0;
  return lut[idx][0] + lut[idx][1] * df;
}

static inline float vx_expf_approx_p(float f) {
#if VX_EXPF_APPROX == VX_EXPF_APPROX_LUT
  return vx_expf_lut_p(f);
#else
  return vx_expf_poly_p(f);
#endif
}

static inline float vx_expf(float x) {
#ifdef VX_ENABLE_HW_EXPF
  return vx_expf_hw(x);
#else
  // Branchless clamp using fmin.s / fmax.s hardware instructions
  float clamped = __builtin_fmaxf(__builtin_fminf(x, 88.7f), -87.3f);

  const float LOG2E = 1.4426950408889634f;  // 1/ln(2)
  float t = clamped * LOG2E;

  // Branchless floor: n = floor(t)
  // (int) truncates toward zero; fix for negatives with arithmetic
  int n = (int)t;
  n -= ((float)n > t);  // subtracts 1 when truncation rounded toward zero
  float f = t - (float)n;

  // 2^f approximation for f in [0,1)
  float p = vx_expf_approx_p(f);

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
