// Make the fixed microtile group/lane decomposition explicit in each memory
// pass while preserving independent address calculation per iteration.
#define SOFTMAX_REV2_SHUFFLE_ADDR32 1
#define SOFTMAX_REV2_SHUFFLE_GROUPED 1
#include "kernel.rev2_shuffle.cpp"
