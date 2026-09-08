#include <cstdio>
#include <cstdlib>
#include <vortex.h>
#include "phase_args.h"

int main(int argc, char** argv) {
    const unsigned polls = argc == 2 ? std::strtoul(argv[1], nullptr, 10) : 1;
    if (polls != 1 && polls != 256) return 2;
    vx_device_h device = nullptr;
    vx_buffer_h program = nullptr, arguments = nullptr;
    phase_args_t args{};
    int status = 1;
    args.original.M = 16;
    args.original.N = 16;
    args.original.K = polls;
    args.original.QDIR = 0xDEAD;
#define CHECK(call) do { int err = (call); if (err) { \
    std::fprintf(stderr, "PHASE_ERROR %s: %d\n", #call, err); goto cleanup; } } while (0)
    CHECK(vx_dev_open(&device));
    CHECK(vx_upload_kernel_file(device, "kernel.vxbin", &program));
    CHECK(vx_mem_alloc(device, sizeof(args), VX_MEM_READ_WRITE, &arguments));
    CHECK(vx_copy_to_dev(arguments, &args, 0, sizeof(args)));
    CHECK(vx_start(device, program, arguments));
    CHECK(vx_ready_wait(device, 60000));
    CHECK(vx_copy_from_dev(&args, arguments, 0, sizeof(args)));
    if (args.original.status != STATUS_OK || !args.entry_cycle || args.return_cycle < args.entry_cycle) {
        std::fprintf(stderr, "PHASE_ERROR invalid status/snapshots\n");
        goto cleanup;
    }
    std::printf("PHASE_RESULT polls=%u entry=%llu returned=%llu body=%llu\n", polls,
        (unsigned long long)args.entry_cycle, (unsigned long long)args.return_cycle,
        (unsigned long long)(args.return_cycle-args.entry_cycle));
    std::puts("PHASE_CONTROL_PASS (no GEMM output verification)");
    status = 0;
cleanup:
    if (arguments) vx_mem_free(arguments);
    if (program) vx_mem_free(program);
    if (device) vx_dev_close(device);
    return status;
}
