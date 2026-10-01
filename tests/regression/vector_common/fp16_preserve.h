#ifndef _VECTOR_COMMON_FP16_PRESERVE_H_
#define _VECTOR_COMMON_FP16_PRESERVE_H_

#include "fp16.h"

// Software repair for subnormal values on Vivado format-conversion IP.
// Normal values continue through the existing hardware conversion.
static inline float fp16_to_float_preserve(fp16_t bits) {
  if ((bits & 0x7c00u) == 0u) {
    const float magnitude = float(bits & 0x03ffu) * 0x1p-24f;
    return (bits & 0x8000u) ? -magnitude : magnitude;
  }
  return fp16_to_float(bits);
}

static inline fp16_t float_to_fp16_preserve(float value) {
  const uint32_t bits = fp32_bits(value);
  const uint32_t magnitude = bits & 0x7fffffffu;
  if (magnitude >= 0x38800000u) return float_to_fp16(value);
  const float units = fp32_from_bits(magnitude) * 0x1p24f;
#ifdef __riscv
  uint32_t rounded;
  __asm__ volatile("fcvt.w.s %0, %1, rne" : "=r"(rounded) : "f"(units));
#else
  uint32_t rounded = (uint32_t)units;
  const float fraction = units - (float)rounded;
  rounded += fraction > 0.5f || (fraction == 0.5f && (rounded & 1u));
#endif
  return (fp16_t)((bits >> 16 & 0x8000u) | rounded);
}

#endif
