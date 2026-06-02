#include "common.h"
#include "../kv_cache_common/kv_cache_w4a16.h"
#include <vx_intrinsics.h>
#include <vx_spawn.h>

static uint32_t min_u32(uint32_t a, uint32_t b) {
  return a < b ? a : b;
}

static uint32_t align_up_u32(uint32_t value, uint32_t align) {
  return (value + align - 1u) & ~(align - 1u);
}

static uint64_t gemm_c_tiled_offset(uint32_t K,
                                    uint32_t N,
                                    uint32_t k,
                                    uint32_t n) {
  const uint32_t mt = k / TILE_DMA_MT;
  const uint32_t m0 = k & (TILE_DMA_MT - 1u);
  const uint32_t cm = min_u32(K - mt * TILE_DMA_MT, TILE_DMA_MT);
  const uint32_t nt32 = n / TILE_DMA_MXU_NT;
  const uint32_t n0 = n & (TILE_DMA_MXU_NT - 1u);
  return (uint64_t)mt * TILE_DMA_MT * N
       + (uint64_t)nt32 * cm * TILE_DMA_MXU_NT
       + (uint64_t)m0 * TILE_DMA_MXU_NT
       + n0;
}

static fp16_t load_src_value(const fp16_t* src,
                             uint32_t K,
                             uint32_t N,
                             uint32_t k,
                             uint32_t n,
                             uint32_t src_layout) {
  if (src_layout == SRC_LAYOUT_GEMM_C_TILED) {
    return src[gemm_c_tiled_offset(K, N, k, n)];
  }
  return src[(uint64_t)k * N + n];
}

static void compute_params(const fp16_t* src,
                           uint32_t K,
                           uint32_t N,
                           uint32_t QBLK,
                           uint32_t QDIR,
                           uint32_t k,
                           uint32_t n,
                           uint32_t src_layout,
                           float* scale_out,
                           int16_t* zp_out) {
  float min_v = fp16_to_float(load_src_value(src, K, N, k, n, src_layout));
  float max_v = min_v;

  if (QDIR == 0) {
    const uint32_t k0 = (k / QBLK) * QBLK;
    const uint32_t k1 = min_u32(k0 + QBLK, K);
    for (uint32_t kk = k0; kk < k1; ++kk) {
      const float v = fp16_to_float(load_src_value(src, K, N, kk, n, src_layout));
      if (v < min_v) min_v = v;
      if (v > max_v) max_v = v;
    }
  } else {
    const uint32_t n0 = (n / QBLK) * QBLK;
    const uint32_t n1 = min_u32(n0 + QBLK, N);
    for (uint32_t nn = n0; nn < n1; ++nn) {
      const float v = fp16_to_float(load_src_value(src, K, N, k, nn, src_layout));
      if (v < min_v) min_v = v;
      if (v > max_v) max_v = v;
    }
  }

  float scale = (max_v - min_v) / 15.0f;
  if (scale == 0.0f) {
    scale = 1.0f;
  }
  const float zpf = -min_v / scale;
  int32_t zp = (int32_t)(zpf + ((zpf >= 0.0f) ? 0.5f : -0.5f));
  if (zp < 0) zp = 0;
  if (zp > 15) zp = 15;
  *scale_out = scale;
  *zp_out = (int16_t)zp;
}

static uint8_t quant_at(const fp16_t* src,
                        uint32_t K,
                        uint32_t N,
                        uint32_t QBLK,
                        uint32_t QDIR,
                        uint32_t k,
                        uint32_t n,
                        uint32_t src_layout) {
  float scale = 1.0f;
  int16_t zp = 0;
  compute_params(src, K, N, QBLK, QDIR, k, n, src_layout, &scale, &zp);
  const float stored_scale = fp16_to_float(float_to_fp16(scale));
  return kv_quantize_value(
      fp16_to_float(load_src_value(src, K, N, k, n, src_layout)),
      stored_scale,
      zp);
}

static uint8_t quant_with_params(const fp16_t* src,
                                 uint32_t K,
                                 uint32_t N,
                                 uint32_t k,
                                 uint32_t n,
                                 uint32_t src_layout,
                                 float stored_scale,
                                 int16_t zp) {
  return kv_quantize_value(
      fp16_to_float(load_src_value(src, K, N, k, n, src_layout)),
      stored_scale,
      zp);
}

static uint64_t weight_offset_wtrans0(uint32_t K,
                                      uint32_t N,
                                      uint32_t k,
                                      uint32_t n_pair) {
  const uint32_t row_bytes = N >> 1;
  const uint32_t kt = k / TILE_DMA_KT;
  const uint32_t kt_start = kt * TILE_DMA_KT;
  const uint32_t ck = min_u32(K - kt_start, TILE_DMA_KT);
  const uint32_t nt = (n_pair << 1) / TILE_DMA_MXU_NT;
  const uint32_t pair = n_pair & ((TILE_DMA_MXU_NT >> 1) - 1u);
  const uint32_t k_local = k - kt_start;
  const uint32_t kb = k_local / TILE_DMA_MXU_KT;
  const uint32_t k_in_sub = k_local & (TILE_DMA_MXU_KT - 1u);
  const uint32_t tid = kb * TILE_DMA_MXU_KT + k_in_sub;
  return (uint64_t)kt * TILE_DMA_KT * row_bytes
       + (uint64_t)nt * ck * (TILE_DMA_MXU_NT >> 1)
       + (uint64_t)tid * (TILE_DMA_MXU_NT >> 1)
       + pair;
}

static uint64_t weight_offset_wtrans1(uint32_t K,
                                      uint32_t N,
                                      uint32_t k0,
                                      uint32_t n) {
  const uint32_t row_bytes = N >> 1;
  const uint32_t kt = k0 / TILE_DMA_KT;
  const uint32_t kt_start = kt * TILE_DMA_KT;
  const uint32_t ck = min_u32(K - kt_start, TILE_DMA_KT);
  const uint32_t nt = n / TILE_DMA_MXU_NT;
  const uint32_t n_in_sub = n & (TILE_DMA_MXU_NT - 1u);
  const uint32_t k_local = k0 - kt_start;
  const uint32_t kb = k_local / TILE_DMA_MXU_KT;
  const uint32_t k_pair = (k_local & (TILE_DMA_MXU_KT - 1u)) >> 1;
  const uint32_t micro_bytes = TILE_DMA_MXU_NT * (TILE_DMA_MXU_KT >> 1);
  return (uint64_t)kt * TILE_DMA_KT * row_bytes
       + (uint64_t)nt * ck * (TILE_DMA_MXU_NT >> 1)
       + (uint64_t)kb * micro_bytes
       + (uint64_t)n_in_sub * (TILE_DMA_MXU_KT >> 1)
       + k_pair;
}

static uint8_t quant_source_at(const fp16_t* src,
                               uint32_t K,
                               uint32_t N,
                               uint32_t QBLK,
                               uint32_t QDIR,
                               uint32_t out_k,
                               uint32_t out_n,
                               uint32_t src_layout,
                               uint32_t source_transposed) {
  const uint32_t source_row = source_transposed ? out_n : out_k;
  const uint32_t source_col = source_transposed ? out_k : out_n;
  return quant_at(src, K, N, QBLK, QDIR, source_row, source_col, src_layout);
}

static uint32_t scale_slot_body_bytes(uint32_t cur_k,
                                      uint32_t cur_n,
                                      uint32_t QBLK,
                                      uint32_t QDIR) {
  const uint32_t ng_per_mxu_nt = (TILE_DMA_MXU_NT + QBLK - 1u) / QBLK;
  if (QDIR == 0) {
    return (cur_k / QBLK) * cur_n * TILE_ELEM_BYTES;
  }
  return (cur_n / TILE_DMA_MXU_NT) * cur_k * ng_per_mxu_nt * TILE_ELEM_BYTES;
}

static uint64_t scale_slot_base(const kernel_arg_t* arg, uint32_t kt, uint32_t nt_dma) {
  const uint32_t slot_full_N = (kt + 1u == arg->k_tiles) ? arg->slot_pk_fn : arg->slot_fk_fn;
  return (uint64_t)kt * arg->per_kt_full_K + (uint64_t)nt_dma * slot_full_N;
}

static void store_u16(uint8_t* dst, uint64_t off, uint16_t value) {
  dst[off] = (uint8_t)(value & 0xffu);
  dst[off + 1] = (uint8_t)(value >> 8);
}

void kernel_kv_cache_quant_layout_fused(kernel_arg_t *__UNIFORM__ arg) {
  auto src = reinterpret_cast<fp16_t *>(arg->src_addr);
  auto weight = reinterpret_cast<uint8_t *>(arg->weight_addr);
  auto scales = reinterpret_cast<uint8_t *>(arg->scale_addr);
  auto zeros = reinterpret_cast<uint8_t *>(arg->zero_addr);

  const uint32_t K = arg->K;
  const uint32_t N = arg->N;
  const uint32_t QBLK = arg->QBLK;
  const uint32_t SOURCE_QDIR = arg->QDIR;
  const uint32_t GEMM_QDIR = arg->GEMM_QDIR;
  const uint32_t WTRANS = arg->WTRANS;
  const uint32_t src_layout = arg->src_layout;
  const uint32_t SOURCE_TRANSPOSED = arg->SOURCE_TRANSPOSED;
  const uint32_t total_threads = gridDim.x * blockDim.x;
  const uint32_t thread_id = blockIdx.x * blockDim.x + threadIdx.x;

  const uint32_t weight_bytes = K * (N >> 1);
  if (SOURCE_TRANSPOSED != 0 && WTRANS != 0 && SOURCE_QDIR == 1 && QBLK >= 2) {
    const uint32_t logical_K = N;
    const uint32_t logical_N = K;
    const uint32_t source_groups = N >> arg->log2_qblk;
    const uint32_t source_group_work = K * source_groups;
    for (uint32_t work = thread_id; work < source_group_work; work += total_threads) {
      const uint32_t source_row = work / source_groups;
      const uint32_t group = work - source_row * source_groups;
      const uint32_t source_col_start = group << arg->log2_qblk;
      const uint32_t source_col_end = source_col_start + QBLK;
      float scale = 1.0f;
      int16_t zp = 0;
      compute_params(src, K, N, QBLK, SOURCE_QDIR,
                     source_row, source_col_start, src_layout, &scale, &zp);
      const float stored_scale = fp16_to_float(float_to_fp16(scale));
      for (uint32_t source_col = source_col_start; source_col < source_col_end; source_col += 2) {
        const uint8_t q0 = quant_with_params(src, K, N, source_row, source_col,
                                             src_layout, stored_scale, zp);
        const uint8_t q1 = quant_with_params(src, K, N, source_row, source_col + 1,
                                             src_layout, stored_scale, zp);
        weight[weight_offset_wtrans1(logical_K, logical_N, source_col, source_row)] =
            (uint8_t)((q0 & 0x0f) | ((q1 & 0x0f) << 4));
      }
    }
  } else if (SOURCE_TRANSPOSED == 0 && WTRANS == 0 && SOURCE_QDIR == 1 && QBLK >= 2) {
    const uint32_t source_groups = N >> arg->log2_qblk;
    const uint32_t source_group_work = K * source_groups;
    for (uint32_t work = thread_id; work < source_group_work; work += total_threads) {
      const uint32_t source_row = work / source_groups;
      const uint32_t group = work - source_row * source_groups;
      const uint32_t source_col_start = group << arg->log2_qblk;
      const uint32_t source_col_end = source_col_start + QBLK;
      float scale = 1.0f;
      int16_t zp = 0;
      compute_params(src, K, N, QBLK, SOURCE_QDIR,
                     source_row, source_col_start, src_layout, &scale, &zp);
      const float stored_scale = fp16_to_float(float_to_fp16(scale));
      for (uint32_t source_col = source_col_start; source_col < source_col_end; source_col += 2) {
        const uint8_t q0 = quant_with_params(src, K, N, source_row, source_col,
                                             src_layout, stored_scale, zp);
        const uint8_t q1 = quant_with_params(src, K, N, source_row, source_col + 1,
                                             src_layout, stored_scale, zp);
        weight[weight_offset_wtrans0(K, N, source_row, source_col >> 1)] =
            (uint8_t)((q0 & 0x0f) | ((q1 & 0x0f) << 4));
      }
    }
  } else {
    for (uint32_t i = thread_id; i < weight_bytes; i += total_threads) {
      if (SOURCE_TRANSPOSED != 0) {
        if (WTRANS == 0) continue;
        const uint32_t logical_K = N;
        const uint32_t logical_N = K;
        const uint32_t k0 = (i / logical_N) << 1;
        const uint32_t n = i - (k0 >> 1) * logical_N;
        const uint8_t q0 = quant_source_at(src, K, N, QBLK, SOURCE_QDIR, k0, n, src_layout, 1);
        const uint8_t q1 = quant_source_at(src, K, N, QBLK, SOURCE_QDIR, k0 + 1, n, src_layout, 1);
        weight[weight_offset_wtrans1(logical_K, logical_N, k0, n)] =
            (uint8_t)((q0 & 0x0f) | ((q1 & 0x0f) << 4));
      } else if (WTRANS == 0) {
        const uint32_t k = i / (N >> 1);
        const uint32_t n_pair = i - k * (N >> 1);
        const uint32_t n0 = n_pair << 1;
        const uint8_t q0 = quant_at(src, K, N, QBLK, SOURCE_QDIR, k, n0, src_layout);
        const uint8_t q1 = quant_at(src, K, N, QBLK, SOURCE_QDIR, k, n0 + 1, src_layout);
        weight[weight_offset_wtrans0(K, N, k, n_pair)] =
            (uint8_t)((q0 & 0x0f) | ((q1 & 0x0f) << 4));
      } else {
        const uint32_t k0 = (i / N) << 1;
        const uint32_t n = i - (k0 >> 1) * N;
        const uint8_t q0 = quant_at(src, K, N, QBLK, SOURCE_QDIR, k0, n, src_layout);
        const uint8_t q1 = quant_at(src, K, N, QBLK, SOURCE_QDIR, k0 + 1, n, src_layout);
        weight[weight_offset_wtrans1(K, N, k0, n)] =
            (uint8_t)((q0 & 0x0f) | ((q1 & 0x0f) << 4));
      }
    }
  }

  const uint32_t out_K = SOURCE_TRANSPOSED ? N : K;
  const uint32_t out_N = SOURCE_TRANSPOSED ? K : N;
  const uint32_t max_slot_elems = arg->max_slot_bytes / TILE_ELEM_BYTES;
  const uint32_t qparam_work = arg->k_tiles * arg->n_dma_tiles * max_slot_elems;
  for (uint32_t work = thread_id; work < qparam_work; work += total_threads) {
    const uint32_t slot = work / max_slot_elems;
    const uint32_t elem_in_slot = work - slot * max_slot_elems;
    const uint32_t kt = slot / arg->n_dma_tiles;
    const uint32_t nt_dma = slot - kt * arg->n_dma_tiles;
    const uint32_t kt_start = kt << arg->log2_kt;
    const uint32_t nt_start = nt_dma << arg->log2_nt;
    const uint32_t cur_k = min_u32(out_K - kt_start, TILE_DMA_KT);
    const uint32_t cur_n = min_u32(out_N - nt_start, TILE_DMA_NT);
    const uint32_t body_bytes = scale_slot_body_bytes(cur_k, cur_n, QBLK, GEMM_QDIR);
    const uint32_t body_elems = body_bytes / TILE_ELEM_BYTES;
    const uint32_t slot_bytes = align_up_u32(body_bytes, TILE_SCALE_SLOT_ALIGN);
    const uint32_t byte_in_slot = elem_in_slot * TILE_ELEM_BYTES;
    if (byte_in_slot >= slot_bytes) {
      continue;
    }

    const uint64_t dst_off = scale_slot_base(arg, kt, nt_dma) + byte_in_slot;
    if (elem_in_slot >= body_elems) {
      store_u16(scales, dst_off, 0);
      store_u16(zeros, dst_off, 0);
      continue;
    }

    uint32_t param_k = kt_start;
    uint32_t param_n = nt_start;
    if (GEMM_QDIR == 0) {
      const uint32_t col = elem_in_slot & (TILE_DMA_MXU_NT - 1u);
      const uint32_t nb_g = elem_in_slot >> arg->log2_mxu_nt;
      const uint32_t cur_groups = cur_k >> arg->log2_qblk;
      const uint32_t g = nb_g % cur_groups;
      const uint32_t nb = nb_g / cur_groups;
      param_k = kt_start + (g << arg->log2_qblk);
      param_n = nt_start + (nb << arg->log2_mxu_nt) + col;
    } else {
      const uint32_t ng_per_mxu_nt = 1u << arg->log2_ng_per_mxu_nt;
      const uint32_t ng_loc = elem_in_slot & (ng_per_mxu_nt - 1u);
      const uint32_t nb_k = elem_in_slot >> arg->log2_ng_per_mxu_nt;
      const uint32_t k_loc = nb_k % cur_k;
      const uint32_t nb = nb_k / cur_k;
      const uint32_t mxu_per_dma_nt = TILE_DMA_NT >> arg->log2_mxu_nt;
      const uint32_t global_nt_mxu = nt_dma * mxu_per_dma_nt + nb;
      const uint32_t global_ng = ((global_nt_mxu << arg->log2_mxu_nt) >> arg->log2_qblk) + ng_loc;
      param_k = kt_start + k_loc;
      param_n = global_ng << arg->log2_qblk;
    }

    const uint32_t source_row = SOURCE_TRANSPOSED ? param_n : param_k;
    const uint32_t source_col = SOURCE_TRANSPOSED ? param_k : param_n;
    float scale = 1.0f;
    int16_t zp = 0;
    compute_params(src, K, N, QBLK, SOURCE_QDIR, source_row, source_col, src_layout, &scale, &zp);
    store_u16(scales, dst_off, float_to_fp16(scale));
    store_u16(zeros, dst_off, (uint16_t)zp);
  }
}

void kernel_dispatcher(kernel_arg_t *__UNIFORM__ arg) {
  switch (arg->kernel_id) {
    case KERNEL_KV_CACHE_QUANT_LAYOUT_FUSED_W4A16:
      kernel_kv_cache_quant_layout_fused(arg);
      break;
    default:
      break;
  }
}

int main() {
  auto arg = (kernel_arg_t *)csr_read(VX_CSR_MSCRATCH);
  return vx_spawn_threads(1, arg->grid_dim, arg->block_dim,
                          (vx_kernel_func_cb)kernel_dispatcher, arg);
}
