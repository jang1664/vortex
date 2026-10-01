#ifndef _KV_CACHE_QUANT_LAYOUT_FUSED_W4A16_HOST_COMMON_H_
#define _KV_CACHE_QUANT_LAYOUT_FUSED_W4A16_HOST_COMMON_H_

#include "common.h"
#include "../kv_cache_common/kv_cache_w4a16.h"
#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <vector>

static inline bool is_pow2_u32(uint32_t v) {
  return v && ((v & (v - 1u)) == 0);
}

static inline bool valid_fused_quant_shape(uint32_t K,
                                           uint32_t N,
                                           uint32_t QBLK,
                                           uint32_t QDIR,
                                           uint32_t WTRANS,
                                           uint32_t GEMM_QDIR,
                                           uint32_t SOURCE_TRANSPOSED,
                                           uint32_t quant_mode = KV_QUANT_LEGACY_UINT4_ASYMMETRIC,
                                           uint32_t source_total_n = 0,
                                           uint32_t head_col_offset = 0) {
  if (K == 0 || N == 0 || QBLK == 0 || QDIR > 1 || WTRANS > 1 ||
      GEMM_QDIR > 1 || SOURCE_TRANSPOSED > 1 ||
      quant_mode > KV_QUANT_SPINQUANT_SIGNED_SYMMETRIC) {
    return false;
  }
  if (SOURCE_TRANSPOSED != 0 && WTRANS == 0) {
    return false;
  }
  if (!is_pow2_u32(QBLK) || (N & 1u) != 0) {
    return false;
  }
  const uint32_t source_stride = source_total_n == 0 ? N : source_total_n;
  if (head_col_offset > source_stride || N > source_stride - head_col_offset) {
    return false;
  }
  return true;
}

static inline uint32_t parse_quant_mode(const char* value) {
  if (0 == strcmp(value, "legacy_uint4_asymmetric")) {
    return KV_QUANT_LEGACY_UINT4_ASYMMETRIC;
  }
  if (0 == strcmp(value, "spinquant_signed_asymmetric")) {
    return KV_QUANT_SPINQUANT_SIGNED_ASYMMETRIC;
  }
  if (0 == strcmp(value, "spinquant_signed_symmetric")) {
    return KV_QUANT_SPINQUANT_SIGNED_SYMMETRIC;
  }
  return UINT32_MAX;
}

static inline const char* quant_mode_name(uint32_t mode) {
  switch (mode) {
  case KV_QUANT_LEGACY_UINT4_ASYMMETRIC:
    return "legacy_uint4_asymmetric";
  case KV_QUANT_SPINQUANT_SIGNED_ASYMMETRIC:
    return "spinquant_signed_asymmetric";
  case KV_QUANT_SPINQUANT_SIGNED_SYMMETRIC:
    return "spinquant_signed_symmetric";
  default:
    return "invalid";
  }
}

static inline uint32_t parse_src_layout(const char* value) {
  if (0 == strcmp(value, "gemm_c_tiled") || 0 == strcmp(value, "gemm-c-tiled")) {
    return SRC_LAYOUT_GEMM_C_TILED;
  }
  if (0 == strcmp(value, "gemm_a_tiled") || 0 == strcmp(value, "gemm-a-tiled")) {
    return SRC_LAYOUT_GEMM_A_TILED;
  }
  return SRC_LAYOUT_ROW_MAJOR;
}

static inline const char* src_layout_name(uint32_t layout) {
  if (layout == SRC_LAYOUT_GEMM_C_TILED) return "gemm_c_tiled";
  if (layout == SRC_LAYOUT_GEMM_A_TILED) return "gemm_a_tiled";
  return "row_major_fp16";
}

static inline uint32_t log2_u32(uint32_t v) {
  uint32_t r = 0;
  while ((1u << r) < v) ++r;
  return r;
}

static inline uint32_t ceil_div_pow2_u32(uint32_t value, uint32_t divisor) {
  return (value + divisor - 1u) >> log2_u32(divisor);
}

static inline uint32_t align_up_u32_host(uint32_t value, uint32_t align) {
  return (value + align - 1u) & ~(align - 1u);
}

static inline uint32_t padded_weight_K_host(uint32_t K, uint32_t N, uint32_t source_transposed) {
  const uint32_t logical = source_transposed ? N : K;
  const uint32_t alignment = logical <= DEFAULT_DMA_KT
      ? TILE_DMA_MXU_KT : DEFAULT_DMA_KT;
  return align_up_u32_host(logical, alignment);
}

static inline uint32_t padded_weight_N_host(uint32_t K, uint32_t N, uint32_t source_transposed) {
  const uint32_t logical = source_transposed ? K : N;
  return align_up_u32_host(logical, TILE_DMA_MXU_NT);
}

static inline uint32_t padded_qparam_K_host(uint32_t K,
                                            uint32_t N,
                                            uint32_t QBLK,
                                            uint32_t GEMM_QDIR,
                                            uint32_t source_transposed) {
  const uint32_t logical = source_transposed ? N : K;
  uint32_t align = logical <= DEFAULT_DMA_KT
      ? TILE_DMA_MXU_KT : DEFAULT_DMA_KT;
  if (GEMM_QDIR == 0 && QBLK > align) align = QBLK;
  return align_up_u32_host(logical, align);
}

static inline uint32_t padded_qparam_N_host(uint32_t K,
                                            uint32_t N,
                                            uint32_t QBLK,
                                            uint32_t GEMM_QDIR,
                                            uint32_t source_transposed) {
  const uint32_t logical = source_transposed ? K : N;
  uint32_t align = TILE_DMA_MXU_NT;
  if (GEMM_QDIR == 1 && QBLK > align) align = QBLK;
  return align_up_u32_host(logical, align);
}

static inline size_t weight_total_bytes_host(uint32_t K,
                                             uint32_t N,
                                             uint32_t source_transposed) {
  const uint32_t out_K = padded_weight_K_host(K, N, source_transposed);
  const uint32_t out_N = padded_weight_N_host(K, N, source_transposed);
  return size_t(out_K) * (out_N >> 1);
}

static inline uint64_t gemm_c_tiled_offset_host(uint32_t K,
                                                uint32_t N,
                                                uint32_t k,
                                                uint32_t n,
                                                uint32_t dma_mt) {
  const uint32_t log2_mt = log2_u32(dma_mt);
  const uint32_t mt = k >> log2_mt;
  const uint32_t m0 = k & (dma_mt - 1u);
  const uint32_t cm = std::min(K - (mt << log2_mt), dma_mt);
  const uint32_t nt32 = n >> log2_u32(TILE_DMA_MXU_NT);
  const uint32_t n0 = n & (TILE_DMA_MXU_NT - 1u);
  return (uint64_t)mt * dma_mt * N
       + (uint64_t)nt32 * cm * TILE_DMA_MXU_NT
       + (uint64_t)m0 * TILE_DMA_MXU_NT
       + n0;
}

static inline void pack_src_for_layout(const std::vector<fp16_t>& row_major,
                                       std::vector<fp16_t>& device_src,
                                       uint32_t K,
                                       uint32_t N,
                                       uint32_t src_layout,
                                       uint32_t dma_mt) {
  std::fill(device_src.begin(), device_src.end(), 0);
  if (src_layout == SRC_LAYOUT_ROW_MAJOR) {
    std::copy(row_major.begin(), row_major.end(), device_src.begin());
    return;
  }
  for (uint32_t k = 0; k < K; ++k) {
    for (uint32_t n = 0; n < N; ++n) {
      device_src[gemm_c_tiled_offset_host(K, N, k, n, dma_mt)] =
          row_major[(uint64_t)k * N + n];
    }
  }
}

static inline size_t scale_slot_bytes_host(uint32_t cur_k,
                                           uint32_t cur_n,
                                           uint32_t qblk,
                                           uint32_t qdir) {
  const uint32_t ng_per_mxu_nt = ceil_div_pow2_u32(TILE_DMA_MXU_NT, qblk);
  const size_t actual = (qdir == 0)
      ? size_t(ceil_div_pow2_u32(cur_k, qblk)) * cur_n * TILE_ELEM_BYTES
      : size_t(cur_n >> log2_u32(TILE_DMA_MXU_NT)) * cur_k * ng_per_mxu_nt * TILE_ELEM_BYTES;
  return align_up_u32_host((uint32_t)actual, TILE_SCALE_SLOT_ALIGN);
}

static inline size_t scale_total_bytes_host(uint32_t K,
                                            uint32_t N,
                                            uint32_t QBLK,
                                            uint32_t QDIR,
                                            uint32_t source_transposed,
                                            uint32_t dma_kt,
                                            uint32_t dma_nt) {
  const uint32_t out_K = padded_qparam_K_host(K, N, QBLK, QDIR, source_transposed);
  const uint32_t out_N = padded_qparam_N_host(K, N, QBLK, QDIR, source_transposed);
  const uint32_t k_tiles = ceil_div_pow2_u32(out_K, dma_kt);
  const uint32_t n_dma_tiles = ceil_div_pow2_u32(out_N, dma_nt);
  size_t total = 0;
  for (uint32_t kt = 0; kt < k_tiles; ++kt) {
    const uint32_t cur_k = std::min(out_K - kt * dma_kt, dma_kt);
    for (uint32_t nt = 0; nt < n_dma_tiles; ++nt) {
      const uint32_t cur_n = std::min(out_N - nt * dma_nt, dma_nt);
      total += scale_slot_bytes_host(cur_k, cur_n, QBLK, QDIR);
    }
  }
  return total;
}

static inline uint32_t max_scale_slot_bytes_host(uint32_t K,
                                                 uint32_t N,
                                                 uint32_t QBLK,
                                                 uint32_t QDIR,
                                                 uint32_t source_transposed,
                                                 uint32_t dma_kt,
                                                 uint32_t dma_nt) {
  const uint32_t out_K = padded_qparam_K_host(K, N, QBLK, QDIR, source_transposed);
  const uint32_t out_N = padded_qparam_N_host(K, N, QBLK, QDIR, source_transposed);
  const uint32_t k_tiles = ceil_div_pow2_u32(out_K, dma_kt);
  const uint32_t n_dma_tiles = ceil_div_pow2_u32(out_N, dma_nt);
  uint32_t max_slot = 0;
  for (uint32_t kt = 0; kt < k_tiles; ++kt) {
    const uint32_t cur_k = std::min(out_K - kt * dma_kt, dma_kt);
    for (uint32_t nt = 0; nt < n_dma_tiles; ++nt) {
      const uint32_t cur_n = std::min(out_N - nt * dma_nt, dma_nt);
      max_slot = std::max(max_slot, (uint32_t)scale_slot_bytes_host(cur_k, cur_n, QBLK, QDIR));
    }
  }
  return max_slot;
}

static inline bool init_kernel_arg(kernel_arg_t& arg,
                                   uint32_t K,
                                   uint32_t N,
                                   uint32_t QBLK,
                                   uint32_t QDIR,
                                   uint32_t WTRANS,
                                   uint32_t GEMM_QDIR,
                                   uint32_t SOURCE_TRANSPOSED,
                                   uint32_t src_layout,
                                   uint32_t dma_mt,
                                   uint32_t dma_kt,
                                   uint32_t dma_nt,
                                   uint32_t blocks,
                                   uint32_t threads_per_block,
                                   uint32_t quant_mode = KV_QUANT_LEGACY_UINT4_ASYMMETRIC,
                                   uint32_t source_total_n = 0,
                                   uint32_t head_col_offset = 0) {
  if (!is_pow2_u32(dma_mt) || !is_pow2_u32(dma_kt) || !is_pow2_u32(dma_nt) ||
      !is_pow2_u32(TILE_DMA_MXU_KT) || !is_pow2_u32(TILE_DMA_MXU_NT) ||
      !is_pow2_u32(QBLK)) {
    return false;
  }
  if ((dma_kt & (TILE_DMA_MXU_KT - 1u)) != 0 ||
      (dma_nt & (TILE_DMA_MXU_NT - 1u)) != 0) {
    return false;
  }
  const uint32_t source_stride = source_total_n == 0 ? N : source_total_n;
  if (src_layout > SRC_LAYOUT_GEMM_A_TILED ||
      (src_layout != SRC_LAYOUT_ROW_MAJOR
       && (source_stride & (TILE_DMA_MXU_NT - 1u)) != 0)) {
    return false;
  }
  if (GEMM_QDIR == 0 && dma_kt < QBLK) {
    return false;
  }
  arg = {};
  arg.kernel_id = KERNEL_KV_CACHE_QUANT_LAYOUT_FUSED_W4A16;
  arg.grid_dim[0] = blocks;
  arg.grid_dim[1] = 1;
  arg.grid_dim[2] = 1;
  arg.block_dim[0] = threads_per_block;
  arg.block_dim[1] = 1;
  arg.block_dim[2] = 1;
  arg.K = K;
  arg.N = N;
  arg.QBLK = QBLK;
  arg.QDIR = QDIR;
  arg.GEMM_QDIR = GEMM_QDIR;
  arg.WTRANS = WTRANS;
  arg.src_layout = src_layout;
  arg.SOURCE_TRANSPOSED = SOURCE_TRANSPOSED;
  arg.quant_mode = quant_mode;
  arg.src_total_N = source_total_n == 0 ? N : source_total_n;
  arg.src_col_offset = head_col_offset;
  const uint32_t out_K = padded_qparam_K_host(K, N, QBLK, GEMM_QDIR, SOURCE_TRANSPOSED);
  const uint32_t out_N = padded_qparam_N_host(K, N, QBLK, GEMM_QDIR, SOURCE_TRANSPOSED);
  arg.k_tiles = ceil_div_pow2_u32(out_K, dma_kt);
  arg.n_dma_tiles = ceil_div_pow2_u32(out_N, dma_nt);
  const uint32_t ck_last =
      std::min(out_K - (arg.k_tiles - 1u) * dma_kt, dma_kt);
  const uint32_t cn_last =
      std::min(out_N - (arg.n_dma_tiles - 1u) * dma_nt, dma_nt);
  arg.slot_fk_fn = (uint32_t)scale_slot_bytes_host(dma_kt, dma_nt, QBLK, GEMM_QDIR);
  arg.slot_fk_pn = (uint32_t)scale_slot_bytes_host(dma_kt, cn_last, QBLK, GEMM_QDIR);
  arg.slot_pk_fn = (uint32_t)scale_slot_bytes_host(ck_last, dma_nt, QBLK, GEMM_QDIR);
  arg.per_kt_full_K = (arg.n_dma_tiles - 1u) * arg.slot_fk_fn + arg.slot_fk_pn;
  arg.max_slot_bytes = max_scale_slot_bytes_host(K, N, QBLK, GEMM_QDIR,
                                                 SOURCE_TRANSPOSED, dma_kt, dma_nt);
  arg.log2_mt = log2_u32(dma_mt);
  arg.log2_kt = log2_u32(dma_kt);
  arg.log2_nt = log2_u32(dma_nt);
  arg.log2_mxu_kt = log2_u32(TILE_DMA_MXU_KT);
  arg.log2_mxu_nt = log2_u32(TILE_DMA_MXU_NT);
  arg.log2_qblk = log2_u32(QBLK);
  const uint32_t ng_per_mxu_nt = ceil_div_pow2_u32(TILE_DMA_MXU_NT, QBLK);
  arg.log2_ng_per_mxu_nt = log2_u32(ng_per_mxu_nt);
  return true;
}

static inline void init_src(std::vector<fp16_t>& src) {
  for (size_t i = 0; i < src.size(); ++i) {
    const int x = int((i * 1103515245u + 12345u) & 0xffu) - 128;
    src[i] = float_to_fp16(float(x) / 64.0f);
  }
}

#endif // _KV_CACHE_QUANT_LAYOUT_FUSED_W4A16_HOST_COMMON_H_
