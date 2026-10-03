#ifndef HADAMARD_SHUFFLE16_H
#define HADAMARD_SHUFFLE16_H

#include <vx_intrinsics.h>

// A 128-point transform on one 16-lane warp. Each lane owns eight values;
// first transform within each warp, then across the eight register groups.
static inline void hadamard_shuffle16(float (&values)[8], uint32_t lane) {
#pragma unroll
  for (uint32_t stride = 1; stride < 16; stride <<= 1) {
#pragma unroll
    for (uint32_t index = 0; index < 8; ++index) {
      union { float value; uint32_t bits; } other = {values[index]};
      other.bits = static_cast<uint32_t>(vx_shfl_bfly(other.bits, stride, 15, 0));
      values[index] = (lane & stride)
          ? other.value - values[index] : values[index] + other.value;
    }
  }
#pragma unroll
  for (uint32_t stride = 1; stride < 8; stride <<= 1) {
#pragma unroll
    for (uint32_t index = 0; index < 8; ++index) {
      if ((index & stride) == 0) {
        const float a = values[index];
        const float b = values[index + stride];
        values[index] = a + b;
        values[index + stride] = a - b;
      }
    }
  }
}

#endif
