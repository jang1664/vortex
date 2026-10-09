// Compile the existing regression implementation unchanged in its own TU.
#define main llama_elmul_main
#define kernel_arg_t llama_elmul_kernel_arg_t
#define kernel_dispatcher llama_elmul_kernel_dispatcher
#define kernel_dispatcher_power llama_elmul_kernel_dispatcher_power
#include "../../elmul_layout_fused/kernel.linear_skip_pad_rows.cpp"
