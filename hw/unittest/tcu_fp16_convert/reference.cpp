#include <cstdint>
extern "C" {
#include "softfloat.h"
}

extern "C" unsigned int tcu_half_reference(unsigned int bits) {
    const float16_t half = {static_cast<uint16_t>(bits)};
    return f16_to_f32(half).v;
}
