#ifndef _VECTOR_COMMON_FP16_H_
#define _VECTOR_COMMON_FP16_H_

#include <stdint.h>

typedef uint16_t fp16_t;

static inline uint32_t fp32_bits(float f) {
  union {
    float f;
    uint32_t u;
  } v;
  v.f = f;
  return v.u;
}

static inline float fp32_from_bits(uint32_t u) {
  union {
    uint32_t u;
    float f;
  } v;
  v.u = u;
  return v.f;
}

static inline float fp16_to_float(fp16_t h) {
#if defined(__riscv_zfh) && !defined(VX_FP16_FORCE_SOFTWARE_CONVERSION)
  union {
    fp16_t bits;
    _Float16 value;
  } input;
  input.bits = h;

  float output;
  __asm__ volatile("fcvt.s.h %0, %1" : "=f"(output) : "f"(input.value));
  return output;
#else
  const uint32_t sign = ((uint32_t)h & 0x8000u) << 16;
  uint32_t exp = ((uint32_t)h >> 10) & 0x1fu;
  uint32_t mant = (uint32_t)h & 0x03ffu;

  if (exp == 0) {
    if (mant == 0) {
      return fp32_from_bits(sign);
    }

    int32_t e = -14;
    while ((mant & 0x0400u) == 0) {
      mant <<= 1;
      --e;
    }
    mant &= 0x03ffu;
    return fp32_from_bits(sign | (uint32_t)(e + 127) << 23 | (mant << 13));
  }

  if (exp == 0x1fu) {
    return fp32_from_bits(sign | 0x7f800000u | (mant << 13));
  }

  exp = exp + (127u - 15u);
  return fp32_from_bits(sign | (exp << 23) | (mant << 13));
#endif
}

static inline fp16_t float_to_fp16(float f) {
#if defined(__riscv_zfh) && !defined(VX_FP16_FORCE_SOFTWARE_CONVERSION)
  union {
    _Float16 value;
    fp16_t bits;
  } output;
  __asm__ volatile("fcvt.h.s %0, %1" : "=f"(output.value) : "f"(f));
  return output.bits;
#else
  const uint32_t bits = fp32_bits(f);
  const uint32_t sign = (bits >> 16) & 0x8000u;
  const uint32_t exp = (bits >> 23) & 0xffu;
  uint32_t mant = bits & 0x007fffffu;

  if (exp == 0xffu) {
    if (mant == 0) {
      return (fp16_t)(sign | 0x7c00u);
    }
    mant >>= 13;
    return (fp16_t)(sign | 0x7c00u | mant | (mant == 0));
  }

  int32_t exp16 = (int32_t)exp - 127 + 15;
  if (exp16 >= 31) {
    return (fp16_t)(sign | 0x7c00u);
  }

  if (exp16 <= 0) {
    if (exp16 < -10) {
      return (fp16_t)sign;
    }

    mant |= 0x00800000u;
    const uint32_t shift = (uint32_t)(14 - exp16);
    uint32_t mant16 = mant >> shift;
    const uint32_t round_bits = mant & ((1u << shift) - 1u);
    const uint32_t half = 1u << (shift - 1u);
    if (round_bits > half || (round_bits == half && (mant16 & 1u))) {
      ++mant16;
    }
    return (fp16_t)(sign | mant16);
  }

  uint32_t mant16 = mant >> 13;
  const uint32_t round_bits = mant & 0x1fffu;
  if (round_bits > 0x1000u || (round_bits == 0x1000u && (mant16 & 1u))) {
    ++mant16;
    if (mant16 == 0x0400u) {
      mant16 = 0;
      ++exp16;
      if (exp16 >= 31) {
        return (fp16_t)(sign | 0x7c00u);
      }
    }
  }

  return (fp16_t)(sign | ((uint32_t)exp16 << 10) | mant16);
#endif
}

#endif // _VECTOR_COMMON_FP16_H_
