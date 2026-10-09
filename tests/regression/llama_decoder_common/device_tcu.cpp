// Reuse the existing standalone regression kernel unchanged.
#define main llama_tcu_main
#define kernel_arg_t llama_tcu_kernel_arg_t
#define kernel_dispatcher llama_tcu_kernel_dispatcher
#define kernel_dispatcher_power llama_tcu_kernel_dispatcher_power
#define kernel_body llama_tcu_kernel_body
#define kernel_body_power llama_tcu_kernel_body_power
#include "../sgemm_tcu/kernel.b_colmajor.cpp"
