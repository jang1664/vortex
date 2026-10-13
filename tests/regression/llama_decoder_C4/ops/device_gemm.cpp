// Compile the existing regression implementation unchanged in its own TU.
#define main llama_gemm_main
#define kernel_arg_t llama_gemm_kernel_arg_t
#define kernel_dispatcher llama_gemm_kernel_dispatcher
#define kernel_dispatcher_power llama_gemm_kernel_dispatcher_power
#include "../../fpint_gemm_ffn_hw/kernel.cpp"

// Reuse the MMIO driver for each independent matrix, keeping the core running
// between heads. The host supplies the original ABI records contiguously.
int llama_gemm_batch_main(uint32_t count) {
  if (vx_warp_id() != 0 || vx_thread_id() != 0)
    return 0;
  auto args = reinterpret_cast<llama_gemm_kernel_arg_t*>(csr_read(VX_CSR_MSCRATCH));
  for (uint32_t i = 0; i < count; ++i) {
    kernel_mmio_driver(args + i);
    if (vx_core_id() == 0 && args[i].status != STATUS_OK)
      return -1;
  }
  return 0;
}
