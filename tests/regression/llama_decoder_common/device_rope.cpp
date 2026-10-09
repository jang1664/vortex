// Reuse the existing standalone regression kernel unchanged.
#define main llama_rope_main
#define kernel_arg_t llama_rope_kernel_arg_t
#define kernel_dispatcher llama_rope_kernel_dispatcher
#define kernel_dispatcher_power llama_rope_kernel_dispatcher_power
#define kernel_body llama_rope_kernel_body
#define kernel_body_power llama_rope_kernel_body_power
#include "../rope/kernel.task_chunk16.cpp"
