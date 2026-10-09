// Reuse the existing standalone regression kernel unchanged.
#define main llama_elmul_main
#define kernel_arg_t llama_elmul_kernel_arg_t
#define kernel_dispatcher llama_elmul_kernel_dispatcher
#define kernel_dispatcher_power llama_elmul_kernel_dispatcher_power
#define kernel_body llama_elmul_kernel_body
#define kernel_body_power llama_elmul_kernel_body_power
#include "../elmul/kernel.cpp"
