// Compile the existing regression implementation unchanged in its own TU.
#define main llama_rms_main
#define kernel_arg_t llama_rms_kernel_arg_t
#define kernel_dispatcher llama_rms_kernel_dispatcher
#define kernel_dispatcher_power llama_rms_kernel_dispatcher_power
#include "../../rms_norm_layout_fused/kernel.adaptive_m_rows.cpp"
