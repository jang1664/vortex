// Preserve the existing weight-layout fast paths and parallelize each qparam
// group's min/max scan across one warp.
#define KV_FUSED_QPARAM_WARP 1
#include "kernel.cpp"
