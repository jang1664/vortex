#include <cstdint>
#include <cstring>
extern "C" {
#include "softfloat.h"
}

static uint32_t hash(uint32_t x) {
    x ^= x >> 16; x *= 0x7feb352du;
    x ^= x >> 15; x *= 0x846ca68bu;
    return x ^ (x >> 16);
}

extern "C" void gemm_mul_case(unsigned index, unsigned* a, unsigned* b,
                               unsigned* expected) {
    softfloat_roundingMode = softfloat_round_near_even;
    // Exhaust every half operand with identity and underflow-producing scale,
    // then cover arbitrary signs, scales, specials and rounding boundaries.
    *a = index < 131072 ? index & 65535 : hash(index) & 65535;
    *b = index < 65536 ? 0x3c00 : index < 131072 ? 0x3800
                                                : hash(index ^ 0x12345678) & 65535;
    *expected = f16_mul(float16_t{uint16_t(*a)}, float16_t{uint16_t(*b)}).v;
}

extern "C" void gemm_convert_case(unsigned index, unsigned* value,
                                   unsigned* expected) {
    softfloat_roundingMode = softfloat_round_near_even;
    if (index < 65536) {
        *value = f16_to_f32(float16_t{uint16_t(index)}).v;
    } else if (index < 65536 + 8192) {
        // All subnormal midpoints, including below/at/above and both signs.
        unsigned j = index - 65536;
        float midpoint = (float((j / 4) % 1024) + 0.5f) * 0x1p-24f;
        std::memcpy(value, &midpoint, sizeof(midpoint));
        *value += int(j % 4) - 1;
        if (j >= 4096) *value |= 0x80000000u;
    } else {
        *value = hash(index);
    }
    *expected = f32_to_f16(float32_t{*value}).v;
}
