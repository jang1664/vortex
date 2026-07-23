// Keep 64-bit matrix bases, but use the fixed 32-element microtile geometry
// for cheaper per-element within-matrix address arithmetic.
#define SOFTMAX_REV2_SHUFFLE_ADDR32 1
#include "kernel.rev2_shuffle.cpp"
