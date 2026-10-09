// Reuse the standalone naive device implementation without modifying its source.
#define main llama_naive_main
#define kernel_arg_t llama_naive_kernel_arg_t
#define kernel_mmio_driver llama_naive_kernel_mmio_driver
#include "../fpint_gemm_ffn_hw_naive/kernel.cpp"
