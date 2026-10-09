// Compile the existing regression implementation unchanged in its own TU.
#define main llama_hadamard_main
#define kernel_arg_t llama_hadamard_kernel_arg_t
#define kernel_dispatcher llama_hadamard_kernel_dispatcher
#define kernel_dispatcher_power llama_hadamard_kernel_dispatcher_power
#include "../../hadamard_layout_fused/kernel.cpp"
