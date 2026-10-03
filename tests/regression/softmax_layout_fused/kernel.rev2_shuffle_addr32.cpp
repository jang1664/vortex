// Keep 64-bit matrix bases and 32-bit within-matrix address arithmetic;
// microtile geometry still comes from the selected MXU config.
#define SOFTMAX_REV2_SHUFFLE_ADDR32 1
#include "kernel.rev2_shuffle.cpp"
