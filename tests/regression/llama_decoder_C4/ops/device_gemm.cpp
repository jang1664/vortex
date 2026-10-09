// Compile the existing regression implementation unchanged in its own TU.
#define main llama_gemm_main
#define kernel_arg_t llama_gemm_kernel_arg_t
#define kernel_dispatcher llama_gemm_kernel_dispatcher
#define kernel_dispatcher_power llama_gemm_kernel_dispatcher_power
#include "../../fpint_gemm_ffn_hw/kernel.cpp"
