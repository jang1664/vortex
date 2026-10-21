#pragma once
#include "naive_args.h"
#include <limits>

// Same ordered scratch allocation as fpint_gemm_ffn_hw_naive/main.cpp.
// Kept decoder-local so the existing independent latency benchmark is unchanged.
inline bool decoder_naive_lmem_layout(DecoderNaiveArgs& args,
                                     uint64_t local_mem_size) {
  const bool fpfp = args.weight_format == GEMM_WEIGHT_FP16;
  if (!fpfp && (!args.QBLK || (args.QBLK & (args.QBLK - 1)) || args.QDIR > 1))
    return false;
  constexpr uint64_t mt = GEMM_FSM_MT, kt = GEMM_FSM_KT, nt = GEMM_FSM_NT;
  const uint64_t groups_k = fpfp ? 0 : (kt + args.QBLK - 1) / args.QBLK;
  const uint64_t groups_n = fpfp ? 0 : (nt + args.QBLK - 1) / args.QBLK;
  const uint64_t input_bytes = mt * kt * 2;
  const uint64_t weight_bytes = fpfp ? kt * nt * 2 : kt * ((nt + 1) / 2);
  const uint64_t param_bytes = args.QDIR == 0 ? groups_k * nt * 2
                                             : kt * groups_n * 2;
  uint64_t cursor = static_cast<uint64_t>(LMEM_BASE_ADDR);
  if (local_mem_size > std::numeric_limits<uint64_t>::max() - cursor)
    return false;
  const uint64_t end = cursor + local_mem_size;
  auto alloc = [&](uint64_t bytes, uint64_t& address) {
    if (cursor > std::numeric_limits<uint64_t>::max() - 63) return false;
    cursor = (cursor + 63) & ~uint64_t(63);
    bytes = (bytes + 63) & ~uint64_t(63);
    if (cursor > end || bytes > end - cursor) return false;
    address = cursor;
    cursor += bytes;
    return true;
  };
  return alloc(input_bytes, args.lmem_ibuf0_base)
      && alloc(input_bytes, args.lmem_ibuf1_base)
      && alloc(weight_bytes, args.lmem_wbuf0_base)
      && alloc(weight_bytes, args.lmem_wbuf1_base)
      && alloc(param_bytes, args.lmem_scbuf0_base)
      && alloc(param_bytes, args.lmem_scbuf1_base)
      && alloc(param_bytes, args.lmem_zpbuf0_base)
      && alloc(param_bytes, args.lmem_zpbuf1_base)
      && alloc(GEMM_HOST_OUTPUT_TILE_ELEMENTS * 2, args.lmem_obuf_base)
      && alloc(GEMM_HOST_OUTPUT_TILE_ELEMENTS * 4, args.lmem_psum_base);
}
