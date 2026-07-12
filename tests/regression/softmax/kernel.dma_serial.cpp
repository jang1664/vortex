// Serialize DMA descriptor programming through thread 0 while keeping all
// four warps active for independent row computation.
#define SOFTMAX_SERIAL_BLOCK_DMA 1
#include "kernel.opt_align.cpp"
