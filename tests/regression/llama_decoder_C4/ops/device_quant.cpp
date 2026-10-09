// Use the same padded-append implementation as the standalone benchmark.
#define main llama_quant_main
#define kernel_arg_t llama_quant_kernel_arg_t
#define kernel_dispatcher llama_quant_kernel_dispatcher
#define kernel_dispatcher_power llama_quant_kernel_dispatcher_power
#include "../../kv_cache_quant_layout_fused_w4a16/kernel.prefill_reuse_inline_group1_source_weight_cursor.cpp"
#undef main
#undef kernel_arg_t
