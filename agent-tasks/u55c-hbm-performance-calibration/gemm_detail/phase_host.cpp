// Reuse the original host including its deterministic data and output check.
// Only the argument allocation/readback gains a diagnostic trailer.
#include <cstdio>
#include <cstddef>
#include <vortex.h>
#include "phase_args.h"
static int phase_alloc(vx_device_h, uint64_t, int, vx_buffer_h*);
static int phase_read(void*, vx_buffer_h, uint64_t, uint64_t);
#define vx_mem_alloc phase_alloc
#define vx_copy_from_dev phase_read
#include "main.cpp"
#undef vx_mem_alloc
#undef vx_copy_from_dev

static_assert(offsetof(phase_args_t, original) == 0);
static_assert(offsetof(phase_args_t, entry_cycle) == sizeof(kernel_arg_t));
static int phase_alloc(vx_device_h dev, uint64_t size, int flags, vx_buffer_h* out) {
    if (out == &args_buffer) {
        if (size != sizeof(kernel_arg_t)) return -1;
        size = sizeof(phase_args_t);
    }
    return vx_mem_alloc(dev, size, flags, out);
}
static int phase_read(void* dest, vx_buffer_h buffer, uint64_t offset, uint64_t size) {
    int err = vx_copy_from_dev(dest, buffer, offset, size);
    if (err || buffer != args_buffer || offset != 0 || size != sizeof(kernel_arg_t))
        return err;
    // Use an offset-zero read; runtime device-copy offsets require alignment.
    phase_args_t captured{};
    err = vx_copy_from_dev(&captured, buffer, 0, sizeof(captured));
    if (err) return err;
    if (!(captured.entry_cycle <= captured.before_program
          && captured.before_program <= captured.after_program
          && captured.after_program <= captured.after_wait
          && captured.after_wait <= captured.return_cycle)) return -1;
    std::printf("GEMM_DETAIL before_program=%llu after_program=%llu after_wait=%llu program=%llu wait=%llu\n",
        (unsigned long long)captured.before_program,
        (unsigned long long)captured.after_program,
        (unsigned long long)captured.after_wait,
        (unsigned long long)(captured.after_program-captured.before_program),
        (unsigned long long)(captured.after_wait-captured.after_program));
    const uint64_t samples[] = {captured.entry_cycle, captured.return_cycle};
    if (!samples[0] || samples[1] < samples[0]) {
        std::fprintf(stderr, "GEMM_PHASE_ERROR invalid snapshots\n");
        return -1;
    }
    std::printf("GEMM_PHASE entry=%llu returned=%llu body=%llu\n",
        (unsigned long long)samples[0], (unsigned long long)samples[1],
        (unsigned long long)(samples[1]-samples[0]));
    return 0;
}
