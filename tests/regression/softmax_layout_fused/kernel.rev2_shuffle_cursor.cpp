// Advance a row's tiled pointers once per warp-sized microtile. The generic
// accessor remains available when the warp and microtile widths differ.
#define SOFTMAX_REV2_SHUFFLE_CURSOR 1
#include "kernel.rev2_shuffle.cpp"
