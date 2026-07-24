// Keep the full-cache layout path unchanged, but compute a single-token
// persistent update's shared qparams cooperatively with one warp.
#define KV_FUSED_PERSISTENT_WARP 1
#include "kernel.cpp"
