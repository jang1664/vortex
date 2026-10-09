// Compile the existing regression implementation unchanged in its own TU.
#define main llama_silu_main
#define kernel_arg_t llama_silu_kernel_arg_t
#define kernel_dispatcher llama_silu_kernel_dispatcher
#define kernel_dispatcher_power llama_silu_kernel_dispatcher_power
#include "../../silu_layout_fused/kernel.linear_skip_pad_rows.cpp"
