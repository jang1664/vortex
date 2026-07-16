// Correctness-first DMA variant: reuse the opt_align kernel implementation,
// but pair it with a single-warp host launch.  One warp owns one row and one
// DMA descriptor at a time, avoiding the existing multi-warp staging failure
// while preserving pitched HBM, cached exponentials, and shuffle reductions.
#include "kernel.opt_align.cpp"
