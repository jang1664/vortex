// Reuse the existing standalone regression kernel unchanged.
#define main llama_silu_main
#define kernel_arg_t llama_silu_kernel_arg_t
#define kernel_dispatcher llama_silu_kernel_dispatcher
#define kernel_dispatcher_power llama_silu_kernel_dispatcher_power
#define kernel_body llama_silu_kernel_body
#define kernel_body_power llama_silu_kernel_body_power
#include "../silu/kernel.linear.cpp"
