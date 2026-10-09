// Reuse the existing standalone regression kernel unchanged.
#define main llama_rms_main
#define kernel_arg_t llama_rms_kernel_arg_t
#define kernel_dispatcher llama_rms_kernel_dispatcher
#define kernel_dispatcher_power llama_rms_kernel_dispatcher_power
#define kernel_body llama_rms_kernel_body
#define kernel_body_power llama_rms_kernel_body_power
#include "../rmsnorm/kernel.adaptive_m_rows.cpp"
