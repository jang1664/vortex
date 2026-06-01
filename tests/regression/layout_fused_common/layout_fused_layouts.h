#ifndef _LAYOUT_FUSED_LAYOUTS_H_
#define _LAYOUT_FUSED_LAYOUTS_H_

#include <stdint.h>

static inline uint32_t align_up_pow2_u32(uint32_t value, uint32_t log2_align) {
  const uint32_t align = 1u << log2_align;
  return (value + align - 1u) & ~(align - 1u);
}

static inline uint32_t min_u32(uint32_t a, uint32_t b) {
  return (a < b) ? a : b;
}

static inline uint64_t batched_matrix_base(uint32_t matrix_idx,
                                           uint64_t matrix_elems) {
  return (uint64_t)matrix_idx * matrix_elems;
}

static inline uint64_t gemm_a_tiled_elem_offset(uint32_t m,
                                                uint32_t k,
                                                uint32_t m_pad,
                                                uint32_t k_dim,
                                                uint32_t log2_mt,
                                                uint32_t log2_mxu_kt) {
  const uint32_t mt = 1u << log2_mt;
  const uint32_t mxu_kt = 1u << log2_mxu_kt;
  const uint32_t mt_mask = mt - 1u;
  const uint32_t mxu_kt_mask = mxu_kt - 1u;
  const uint32_t mt_idx = m >> log2_mt;
  const uint32_t m0 = m & mt_mask;
  const uint32_t cm = min_u32(m_pad - (mt_idx << log2_mt), mt);
  const uint32_t km = k >> log2_mxu_kt;
  const uint32_t k0 = k & mxu_kt_mask;

  return (uint64_t)mt_idx * mt * k_dim
       + (uint64_t)km * cm * mxu_kt
       + (uint64_t)m0 * mxu_kt
       + k0;
}

static inline uint64_t gemm_c_tiled_elem_offset(uint32_t m,
                                                uint32_t n,
                                                uint32_t m_pad,
                                                uint32_t n_dim,
                                                uint32_t log2_mt,
                                                uint32_t log2_mxu_nt) {
  const uint32_t mt = 1u << log2_mt;
  const uint32_t mxu_nt = 1u << log2_mxu_nt;
  const uint32_t mt_mask = mt - 1u;
  const uint32_t mxu_nt_mask = mxu_nt - 1u;
  const uint32_t mt_idx = m >> log2_mt;
  const uint32_t m0 = m & mt_mask;
  const uint32_t cm = min_u32(m_pad - (mt_idx << log2_mt), mt);
  const uint32_t nt32 = n >> log2_mxu_nt;
  const uint32_t n0 = n & mxu_nt_mask;

  return (uint64_t)mt_idx * mt * n_dim
       + (uint64_t)nt32 * cm * mxu_nt
       + (uint64_t)m0 * mxu_nt
       + n0;
}

// WTRANS=1-style fp32 layout used by rope_layout_fused for latency modeling.
// This is not the packed int4 tile_weight_w4a16 byte layout.
static inline uint64_t gemm_w_tiled_wtrans1_elem_offset(uint32_t k,
                                                        uint32_t n,
                                                        uint32_t k_dim,
                                                        uint32_t n_dim,
                                                        uint32_t log2_kt,
                                                        uint32_t log2_mxu_kt,
                                                        uint32_t log2_mxu_nt) {
  const uint32_t kt = 1u << log2_kt;
  const uint32_t mxu_kt = 1u << log2_mxu_kt;
  const uint32_t mxu_nt = 1u << log2_mxu_nt;
  const uint32_t kt_mask = kt - 1u;
  const uint32_t mxu_kt_mask = mxu_kt - 1u;
  const uint32_t mxu_nt_mask = mxu_nt - 1u;

  const uint32_t kt_idx = k >> log2_kt;
  const uint32_t k_in_kt = k & kt_mask;
  const uint32_t kb = k_in_kt >> log2_mxu_kt;
  const uint32_t k0 = k & mxu_kt_mask;
  const uint32_t nt32 = n >> log2_mxu_nt;
  const uint32_t n0 = n & mxu_nt_mask;
  const uint32_t ck = min_u32(k_dim - (kt_idx << log2_kt), kt);

  return (uint64_t)kt_idx * kt * n_dim
       + (uint64_t)nt32 * ck * mxu_nt
       + (uint64_t)kb * mxu_nt * mxu_kt
       + (uint64_t)n0 * mxu_kt
       + k0;
}

#endif // _LAYOUT_FUSED_LAYOUTS_H_
