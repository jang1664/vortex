// Compile the existing regression implementation unchanged in its own TU.
#define main llama_eladd_main
#define kernel_arg_t llama_eladd_kernel_arg_t
#define kernel_dispatcher llama_eladd_kernel_dispatcher
#define kernel_dispatcher_power llama_eladd_kernel_dispatcher_power
#include "../../eladd_layout_fused/kernel.adaptive_chunk32.cpp"
