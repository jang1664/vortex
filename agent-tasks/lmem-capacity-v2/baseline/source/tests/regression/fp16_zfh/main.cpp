#include <vortex.h>

#include <array>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <iostream>

#include "common.h"

#define RT_CHECK(expr)                                                        \
    do {                                                                      \
        const int status = (expr);                                            \
        if (status != 0) {                                                    \
            std::printf("Error: '%s' returned %d!\n", #expr, status);        \
            cleanup();                                                        \
            return 1;                                                         \
        }                                                                     \
    } while (false)

namespace {

constexpr std::size_t kNumPoints = 32;

template <typename T, std::size_t N>
constexpr std::array<T, kNumPoints> repeat_pattern(
    const std::array<T, N>& pattern) {
    std::array<T, kNumPoints> values = {};
    for (std::size_t i = 0; i < values.size(); ++i) {
        values[i] = pattern[i % N];
    }
    return values;
}

constexpr auto kSrc0 = repeat_pattern(std::array<uint16_t, 4>{
    0x3e00, //  1.5
    0xc000, // -2.0
    0x0000, //  0.0
    0x3c01, //  1.0009765625
});

constexpr auto kSrc1 = repeat_pattern(std::array<uint16_t, 4>{
    0x4000, //  2.0
    0x3800, //  0.5
    0x8000, // -0.0
    0x1000, //  2^-11, a rounding tie for addition
});

constexpr auto kExpectedAdd = repeat_pattern(std::array<uint16_t, 4>{
    0x4300, 0xbe00, 0x0000, 0x3c02,
});

constexpr auto kExpectedMul = repeat_pattern(std::array<uint16_t, 4>{
    0x4200, 0xbc00, 0x8000, 0x1001,
});

#ifdef FPU_DSP
constexpr auto kExpectedDiv = repeat_pattern(std::array<uint16_t, 4>{
    0x3a00, 0xc400, 0x7e00, 0x6801,
});

constexpr auto kExpectedSqrt = repeat_pattern(std::array<uint16_t, 4>{
    0x3ce6, 0x7e00, 0x0000, 0x3c00,
});

constexpr auto kExpectedFma = repeat_pattern(std::array<uint16_t, 4>{
    0x4480, 0xc200, 0x0000, 0x3c02,
});

constexpr auto kExpectedMinimum = repeat_pattern(std::array<uint16_t, 4>{
    0x3e00, 0xc000, 0x8000, 0x1000,
});
#endif

constexpr auto kExpectedNarrowed = repeat_pattern(std::array<uint16_t, 4>{
    0x3f00, 0xbf00, 0x3400, 0x3d01,
});

#ifdef FPU_DSP
constexpr std::array<uint16_t, kNumPoints> kExpectedFromInt = {
    0x0000, 0x3c00, 0x4000, 0x4200, 0x4400, 0x4500, 0x4600, 0x4700,
    0x4800, 0x4880, 0x4900, 0x4980, 0x4a00, 0x4a80, 0x4b00, 0x4b80,
    0x4c00, 0x4c40, 0x4c80, 0x4cc0, 0x4d00, 0x4d40, 0x4d80, 0x4dc0,
    0x4e00, 0x4e40, 0x4e80, 0x4ec0, 0x4f00, 0x4f40, 0x4f80, 0x4fc0,
};
#endif

constexpr auto kExpectedWidened = repeat_pattern(std::array<uint32_t, 4>{
    0x3fc00000, 0xc0000000, 0x00000000, 0x3f802000,
});

constexpr auto kExpectedLessThan = repeat_pattern(std::array<uint32_t, 4>{
    1, 1, 0, 0,
});

#ifdef FPU_DSP
constexpr auto kExpectedToInt = repeat_pattern(
    std::array<int32_t, 4>{1, -2, 0, 1});
constexpr auto kExpectedClassification = repeat_pattern(std::array<uint32_t, 4>{
    0x40, 0x02, 0x10, 0x40,
});
#endif

const char* kKernelFile = "kernel.vxbin";
vx_device_h device = nullptr;
vx_buffer_h src0_buffer = nullptr;
vx_buffer_h src1_buffer = nullptr;
vx_buffer_h dst_buffer = nullptr;
vx_buffer_h kernel_buffer = nullptr;
vx_buffer_h args_buffer = nullptr;

void cleanup() {
    if (device == nullptr) {
        return;
    }
    vx_mem_free(src0_buffer);
    vx_mem_free(src1_buffer);
    vx_mem_free(dst_buffer);
    vx_mem_free(kernel_buffer);
    vx_mem_free(args_buffer);
    vx_dev_close(device);
    device = nullptr;
}

uint32_t float_bits(float value) {
    uint32_t bits;
    std::memcpy(&bits, &value, sizeof(bits));
    return bits;
}

} // namespace

int main() {
    static_assert(sizeof(fp16_result_t) == 32, "unexpected result layout");

    kernel_arg_t args = {};
    args.num_points = kSrc0.size();

    RT_CHECK(vx_dev_open(&device));
    RT_CHECK(vx_mem_alloc(device, sizeof(kSrc0), VX_MEM_READ, &src0_buffer));
    RT_CHECK(vx_mem_alloc(device, sizeof(kSrc1), VX_MEM_READ, &src1_buffer));
    RT_CHECK(vx_mem_alloc(device, sizeof(fp16_result_t) * args.num_points,
                          VX_MEM_WRITE, &dst_buffer));
    RT_CHECK(vx_mem_address(src0_buffer, &args.src0_addr));
    RT_CHECK(vx_mem_address(src1_buffer, &args.src1_addr));
    RT_CHECK(vx_mem_address(dst_buffer, &args.dst_addr));
    RT_CHECK(vx_copy_to_dev(src0_buffer, kSrc0.data(), 0, sizeof(kSrc0)));
    RT_CHECK(vx_copy_to_dev(src1_buffer, kSrc1.data(), 0, sizeof(kSrc1)));
    RT_CHECK(vx_upload_kernel_file(device, kKernelFile, &kernel_buffer));
    RT_CHECK(vx_upload_bytes(device, &args, sizeof(args), &args_buffer));
    RT_CHECK(vx_start(device, kernel_buffer, args_buffer));
    RT_CHECK(vx_ready_wait(device, VX_MAX_TIMEOUT));

    std::array<fp16_result_t, kSrc0.size()> results = {};
    RT_CHECK(vx_copy_from_dev(results.data(), dst_buffer, 0, sizeof(results)));

    uint32_t errors = 0;
    for (uint32_t i = 0; i < results.size(); ++i) {
        const auto& got = results[i];
        bool match = got.add == kExpectedAdd[i]
                  && got.mul == kExpectedMul[i]
                  && got.narrowed == kExpectedNarrowed[i]
                  && float_bits(got.widened) == kExpectedWidened[i]
                  && got.less_than == kExpectedLessThan[i];
#ifdef FPU_DSP
        match = match
             && got.div == kExpectedDiv[i]
             && got.sqrt == kExpectedSqrt[i]
             && got.fma == kExpectedFma[i]
             && got.minimum == kExpectedMinimum[i]
             && got.from_int == kExpectedFromInt[i]
             && got.to_int == kExpectedToInt[i]
             && got.classification == kExpectedClassification[i];
#endif
        if (!match) {
            ++errors;
#ifdef FPU_DSP
            std::printf("[%u] add=%04x mul=%04x div=%04x sqrt=%04x fma=%04x min=%04x "
                        "narrowed=%04x from_int=%04x widened=%08x less=%u to_int=%d class=%x\n",
                        i, got.add, got.mul, got.div, got.sqrt, got.fma, got.minimum,
                        got.narrowed, got.from_int, float_bits(got.widened),
                        got.less_than, got.to_int, got.classification);
#else
            std::printf("[%u] add=%04x mul=%04x narrowed=%04x widened=%08x less=%u\n",
                        i, got.add, got.mul, got.narrowed,
                        float_bits(got.widened), got.less_than);
#endif
        }
    }

    cleanup();
    if (errors != 0) {
        std::cout << "FAILED: " << errors << " mismatches" << std::endl;
        return 1;
    }
    std::cout << "PASSED" << std::endl;
    return 0;
}
