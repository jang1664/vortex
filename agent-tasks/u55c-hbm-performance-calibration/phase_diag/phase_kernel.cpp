// Software-only instrumentation, deliberately a different diagnostic binary.
#define main reference_original_main
#include "kernel.cpp"
#undef main
#include "phase_args.h"

int main() {
    const uint64_t entry = csr_read(VX_CSR_MCYCLE);
    asm volatile ("" ::: "memory");
    const int result = reference_original_main();
    asm volatile ("" ::: "memory");
    const uint64_t returned = csr_read(VX_CSR_MCYCLE);
    auto args = reinterpret_cast<volatile phase_args_t*>(csr_read(VX_CSR_MSCRATCH));
    if (vx_warp_id() == 0 && vx_thread_id() == 0) {
        args->entry_cycle = entry;
        args->return_cycle = returned;
    }
    return result;
}
