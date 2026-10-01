// Assign each prefill quantization group to a warp, coalescing tiled source
// reads and packed stores. Preserve the established append and generic paths.
#define KV_FUSED_PERSISTENT_WARP 1
#define KV_FUSED_PREFILL_QPARAM_REUSE 1
#define KV_FUSED_FORCE_INLINE 1
#define KV_FUSED_SOURCE_GROUP1_FAST 1
#define KV_FUSED_PREFILL_WARP_GROUP 1
#define KV_FUSED_FP32_PARAMS 1
#define KV_FUSED_SPLIT_PERSISTENT 1
#include "kernel.cpp"
