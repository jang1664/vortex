// Use all warps for very small M, and one shuffle-reduction warp per row once
// there are enough rows to occupy the core.
#define RMS_NORM_USE_ADAPTIVE_REDUCTION 1
#include "kernel.cpp"
