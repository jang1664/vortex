#include <vx_spawn.h>

#include "common.h"

__attribute__((noinline)) static _Float16 narrow_from_float(float value) {
    return static_cast<_Float16>(value);
}

#ifdef FPU_DSP
static _Float16 sqrt_half(_Float16 value) {
    _Float16 result;
    asm volatile ("fsqrt.h %0, %1" : "=f"(result) : "f"(value));
    return result;
}

static _Float16 fma_half(_Float16 a, _Float16 b, _Float16 c) {
    _Float16 result;
    asm volatile ("fmadd.h %0, %1, %2, %3" : "=f"(result)
                  : "f"(a), "f"(b), "f"(c));
    return result;
}

static _Float16 min_half(_Float16 a, _Float16 b) {
    _Float16 result;
    asm volatile ("fmin.h %0, %1, %2" : "=f"(result) : "f"(a), "f"(b));
    return result;
}

static uint32_t classify_half(_Float16 value) {
    uint32_t result;
    asm volatile ("fclass.h %0, %1" : "=r"(result) : "f"(value));
    return result;
}
#endif

static void kernel_body(kernel_arg_t* __UNIFORM__ arg) {
    auto src0 = reinterpret_cast<const _Float16*>(arg->src0_addr);
    auto src1 = reinterpret_cast<const _Float16*>(arg->src1_addr);
    auto dst = reinterpret_cast<fp16_result_t*>(arg->dst_addr);
    const uint32_t index = blockIdx.x;

    const _Float16 a = src0[index];
    const _Float16 b = src1[index];
    const float widened = static_cast<float>(a);

    fp16_result_t result = {};
    result.add = a + b;
    result.mul = a * b;
    result.narrowed = narrow_from_float(widened + 0.25f);
    result.widened = widened;
    result.less_than = a < b;
#ifdef FPU_DSP
    result.div = a / b;
    result.sqrt = sqrt_half(a);
    result.fma = fma_half(a, b, a);
    result.minimum = min_half(a, b);
    result.from_int = static_cast<_Float16>(static_cast<int32_t>(index));
    result.to_int = static_cast<int32_t>(a);
    result.classification = classify_half(a);
#endif
    dst[index] = result;
}

int main() {
    auto arg = reinterpret_cast<kernel_arg_t*>(csr_read(VX_CSR_MSCRATCH));
    return vx_spawn_threads(1, &arg->num_points, nullptr,
                            reinterpret_cast<vx_kernel_func_cb>(kernel_body), arg);
}
