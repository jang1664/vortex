// Groupwise implementation using native Zfh arithmetic.
#if !defined(__riscv_zfh)
#error "groupwise_fp16 requires a Vortex profile with Zfh support"
#endif
#include "kernel.groupwise.cpp"
