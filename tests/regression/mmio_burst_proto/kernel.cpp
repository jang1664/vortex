// Compiler-emit prototype for DAE Optimization 2 (8-thread MMIO burst).
//
// Goal: confirm that a per-lane store of the form
//   *(addr + 8 * vx_thread_id()) = words[vx_thread_id()];
// compiles to ONE Vortex warp-store instruction with per-lane addr/data,
// not a serial loop or a strip-mined sequence.
//
// Build only the kernel + dump:
//   make kernel.dump
// Then inspect kernel.dump and look at case_baseline / case_burst8 /
// case_burst_partial bodies.

#include <vx_intrinsics.h>
#include <stdint.h>

static constexpr uint64_t BASE = 0x1088ULL;

// Case A — baseline: 1-thread, 1 store (current stream_send shape)
__attribute__((noinline))
void case_baseline(uint64_t w) {
    *reinterpret_cast<volatile uint64_t*>(BASE) = w;
}

// Case B — full burst: 8-thread, per-lane addr & per-lane data
__attribute__((noinline))
void case_burst8(const uint64_t* words /*[8]*/) {
    int tid = vx_thread_id();
    *reinterpret_cast<volatile uint64_t*>(BASE + 8 * tid) = words[tid];
}

// Case C — partial burst (n<8 threads). Functionally identical to case_burst8;
// the only difference at runtime is tmask. We expect the same instruction
// stream, with tmask propagating through the LSU mask.
__attribute__((noinline))
void case_burst_partial(const uint64_t* words /*[k]*/) {
    int tid = vx_thread_id();
    *reinterpret_cast<volatile uint64_t*>(BASE + 8 * tid) = words[tid];
}

// Case D — variant: per-lane addr but UNIFORM data (broadcast).
// Used to see whether the compiler still emits a per-lane store or
// folds data into a uniform value.
__attribute__((noinline))
void case_burst8_uniform_data(uint64_t w) {
    int tid = vx_thread_id();
    *reinterpret_cast<volatile uint64_t*>(BASE + 8 * tid) = w;
}

extern "C" int main() {
    if (vx_warp_id() != 0) { vx_tmc_zero(); return 0; }

    // Provide some lane-varying data so the compiler can't trivially fold it.
    uint64_t arr[8] = {
        0xDEAD0000ULL, 0xDEAD0001ULL, 0xDEAD0002ULL, 0xDEAD0003ULL,
        0xDEAD0004ULL, 0xDEAD0005ULL, 0xDEAD0006ULL, 0xDEAD0007ULL,
    };

    vx_tmc_one();
    case_baseline(0xCAFE);

    vx_tmc(0xFF);
    case_burst8(arr);

    vx_tmc(0x0F);
    case_burst_partial(arr);

    vx_tmc(0xFF);
    case_burst8_uniform_data(0xBEEFULL);

    vx_tmc_one();
    return 0;
}
