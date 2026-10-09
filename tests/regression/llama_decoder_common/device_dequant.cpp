// Reuse the existing standalone regression kernel unchanged.
#define main llama_dequant_main
#define kernel_arg_t llama_dequant_kernel_arg_t
#define kernel_dispatcher llama_dequant_kernel_dispatcher
#define kernel_dispatcher_power llama_dequant_kernel_dispatcher_power
#define kernel_body llama_dequant_kernel_body
#define kernel_body_power llama_dequant_kernel_body_power
#include "../kv_cache_dequant_w4a16/kernel.groupwise_fp16.cpp"
