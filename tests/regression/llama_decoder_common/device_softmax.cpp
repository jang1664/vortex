// Reuse the existing standalone regression kernel unchanged.
#define main llama_softmax_main
#define kernel_arg_t llama_softmax_kernel_arg_t
#define kernel_dispatcher llama_softmax_kernel_dispatcher
#define kernel_dispatcher_power llama_softmax_kernel_dispatcher_power
#define kernel_body llama_softmax_kernel_body
#define kernel_body_power llama_softmax_kernel_body_power
#include "../softmax/kernel.rev2_shuffle_grouped.cpp"
