// Reuse the TMEM/DRAM-aware tiled host layout from the cmd-stream reference app.
// The target kernel keeps the config-register MMIO driver, but the host-side
// buffer layout must match the same 512B-aligned tiled contract.
#include "../fpint_gemm_ffn_hw_improve/main.cpp"
