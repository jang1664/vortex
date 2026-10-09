// Compile the existing regression implementation unchanged in its own TU.
#define main llama_softmax_main
#define kernel_arg_t llama_softmax_kernel_arg_t
#define kernel_dispatcher llama_softmax_kernel_dispatcher
#define kernel_dispatcher_power llama_softmax_kernel_dispatcher_power
#include "../../softmax_layout_fused/kernel.rev2_shuffle_cursor.cpp"
