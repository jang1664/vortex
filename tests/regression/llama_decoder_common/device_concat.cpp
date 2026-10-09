// Reuse the existing standalone regression kernel unchanged.
#define main llama_concat_main
#define kernel_arg_t llama_concat_kernel_arg_t
#define kernel_dispatcher llama_concat_kernel_dispatcher
#define kernel_dispatcher_power llama_concat_kernel_dispatcher_power
#define kernel_body llama_concat_kernel_body
#define kernel_body_power llama_concat_kernel_body_power
#include "../head_concat/kernel.chunk16_packed.cpp"
