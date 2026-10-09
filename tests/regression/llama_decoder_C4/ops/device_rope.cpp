// Compile the existing regression implementation unchanged in its own TU.
#define main llama_rope_main
#define kernel_arg_t llama_rope_kernel_arg_t
#define kernel_dispatcher llama_rope_kernel_dispatcher
#define kernel_dispatcher_power llama_rope_kernel_dispatcher_power
#include "../../rope_layout_fused/kernel.task_chunk16.cpp"
