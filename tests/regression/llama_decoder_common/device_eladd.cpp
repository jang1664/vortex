// Reuse the existing standalone regression kernel unchanged.
#define main llama_eladd_main
#define kernel_arg_t llama_eladd_kernel_arg_t
#define kernel_dispatcher llama_eladd_kernel_dispatcher
#define kernel_dispatcher_power llama_eladd_kernel_dispatcher_power
#define kernel_body llama_eladd_kernel_body
#define kernel_body_power llama_eladd_kernel_body_power
// Match eladd/Makefile's latency_on_hw default.
#define ELADD_ROW_COALESCED_CURSOR
#define ELADD_ROW_SIZE 4096
#include "../eladd/kernel.cpp"
