// Reuse the existing standalone regression kernel unchanged.
#define main llama_quant_main
#define kernel_arg_t llama_quant_kernel_arg_t
#define kernel_dispatcher llama_quant_kernel_dispatcher
#define kernel_dispatcher_power llama_quant_kernel_dispatcher_power
#define kernel_body llama_quant_kernel_body
#define kernel_body_power llama_quant_kernel_body_power
#include "../kv_cache_quant_w4a16/kernel.groupwise_fp16.cpp"
