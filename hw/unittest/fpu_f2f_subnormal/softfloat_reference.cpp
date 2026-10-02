// Independent conversion oracle: Berkeley SoftFloat, tininess after rounding.
#include <cstdint>
#include <cstring>
#include <vector>
extern "C" {
#include "softfloat.h"
}

namespace {
std::vector<uint32_t> inputs[2];

uint32_t float_bits(float value) {
    uint32_t bits;
    std::memcpy(&bits, &value, sizeof(bits));
    return bits;
}

void add_signed(std::vector<uint32_t>& cases, uint32_t bits) {
    cases.push_back(bits);
    cases.push_back(bits | 0x80000000u);
}

void initialize() {
    if (!inputs[0].empty()) return;
    // Exhaust every signed half subnormal in the widening direction.
    for (uint32_t h = 1; h < 1024; ++h) {
        inputs[0].push_back(0xffff0000u | h);
        inputs[0].push_back(0xffff8000u | h);
        float16_t half = {static_cast<uint16_t>(h)};
        // Exact small values also test narrowing without spurious UF or NX.
        add_signed(inputs[1], f16_to_f32(half).v);
    }
    // Values immediately below, at and above every half-unit midpoint.
    for (unsigned n = 0; n < 1024; ++n) {
        const uint32_t midpoint = float_bits((float(n) + 0.5f) * 0x1p-24f);
        for (int adjacent = -1; adjacent <= 1; ++adjacent)
            add_signed(inputs[1], midpoint + adjacent);
    }
    // The normal boundary and very tiny inputs exercise sign/directed rounding.
    const uint32_t boundaries[] = {
        0, 1, 0x007fffff, 0x00800000, 0x00800001,
        0x33000000, 0x33800000, 0x33800001,
        0x387fdfff, 0x387fe000, 0x387fe001, 0x387ffffe, 0x387fffff,
        0x38800000, 0x38802000,
        0x3f800000, 0x40000000, 0x477fe000, 0x7f800000
    };
    for (uint32_t bits : boundaries) add_signed(inputs[1], bits);
    inputs[1].push_back(0x7fc00000);
    const uint32_t half_controls[] = {
        0xffff0000, 0xffff8000, 0xffff0400, 0xffff8400,
        0xffff3c00, 0xffffbc00, 0xffff7bff, 0xfffffbff,
        0xffff7c00, 0xfffffc00, 0xffff7e00,
        0x00000001, 0x00003c00 // Invalid NaN boxing must become canonical qNaN.
    };
    for (uint32_t bits : half_controls) inputs[0].push_back(bits);
    // Deterministic finite random inputs within the corrected narrowing domain.
    uint32_t state = 0xc41f0016;
    for (unsigned i = 0; i < 4096; ++i) {
        state ^= state << 13; state ^= state >> 17; state ^= state << 5;
        const uint32_t exponent = (state >> 24) % 113;
        const uint32_t bits = (exponent << 23) | (state & 0x007fffff);
        add_signed(inputs[1], bits);
    }
    // Padding makes each four-lane request use one common rounding mode.
    for (auto& cases : inputs)
        while (cases.size() % 4) cases.push_back(0);
}
} // namespace

extern "C" int fp16_reference_count(int direction) {
    initialize();
    return static_cast<int>(inputs[direction].size() * 5);
}

extern "C" void fp16_reference_case(int direction, int index,
    unsigned int* input, unsigned int* rounding,
    unsigned int* expected, unsigned int* flags) {
    initialize();
    const unsigned group = static_cast<unsigned>(index) / 20;
    const unsigned lane = static_cast<unsigned>(index) % 4;
    *rounding = (static_cast<unsigned>(index) / 4) % 5;
    *input = inputs[direction][group * 4 + lane];
    softfloat_roundingMode = static_cast<uint_fast8_t>(*rounding);
    softfloat_detectTininess = softfloat_tininess_afterRounding;
    softfloat_exceptionFlags = 0;
    if (direction == 1) {
        float32_t value = {*input};
        *expected = 0xffff0000u | f32_to_f16(value).v;
    } else if ((*input >> 16) != 0xffff) {
        *expected = 0x7fc00000;
    } else {
        float16_t value = {static_cast<uint16_t>(*input)};
        *expected = f16_to_f32(value).v;
    }
    *flags = static_cast<unsigned>(softfloat_exceptionFlags);
}
