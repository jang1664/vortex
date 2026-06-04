// Benchmark harness for fpint_gemm_ffn_hw_improve. See softmax/bench_main.cpp
// for design notes. Reuses kernel.vxbin built from kernel.cpp; differs from
// main.cpp only in that it skips reference output/per-element verification and
// runs warmup + timed-iteration loops around vx_start / vx_ready_wait.
//
// CLI: same shape args as main.cpp (-m -n -k -q -t -d) plus
//      --warmup=N / --iterations=N / --csv / --output=PATH / --output-append
//      parsed by bench_util.
//
// The kernel expects DRAM input/weight/scale/zp buffers in the same tiled
// layout as the regression test, so the layout-conversion helpers are kept
// here verbatim. The behavior swap vs main.cpp is that this binary does not
// build or compare host reference output.

#include <iostream>
#include <unistd.h>
#include <string.h>
#include <vector>
#include <cmath>
#include <algorithm>
#include <vortex.h>
#include "common.h"
#include "bench_util.h"

#define RT_CHECK(_expr)                                         \
   do {                                                         \
     int _ret = _expr;                                          \
     if (0 == _ret)                                             \
       break;                                                   \
     printf("Error: '%s' returned %d!\n", #_expr, (int)_ret);   \
     cleanup();                                                 \
     exit(-1);                                                  \
   } while (false)

static const char* kernel_file = "kernel.vxbin";

// Bench defaults: pick sizes large enough to amortize launch overhead while
// still fitting in TMEM for the standard NUM_DMA_CHANNELS configuration.
static uint32_t M = 128;
static uint32_t N = 128;
static uint32_t K = 128;
static uint32_t QBLK = 32;
static uint32_t WTRANS = 0;
static uint32_t QDIR = 0;

static vx_device_h device = nullptr;
static vx_buffer_h krnl_buffer = nullptr;
static vx_buffer_h args_buffer = nullptr;

static vx_buffer_h A_buffer = nullptr;
static vx_buffer_h W_int4_buffer = nullptr;
static vx_buffer_h scales_buffer = nullptr;
static vx_buffer_h zeros_buffer = nullptr;
static vx_buffer_h C_buffer = nullptr;

// Tile constants (mirror main.cpp)
static constexpr uint32_t DMA_MT     = GEMM_MT;      // 128
static constexpr uint32_t DMA_NT     = GEMM_NT;      // 128 (full N-tile for TMEM sizing)
static constexpr uint32_t DMA_KT     = GEMM_KT;      // 128
static constexpr uint32_t DMA_MXU_KT = GEMM_MXU_KT;  // 32
static constexpr uint32_t DMA_MXU_NT = GEMM_MXU_NT;  // 32

static constexpr uint64_t TMEM_LAYOUT_ALIGN_BYTES = 512;
static constexpr uint64_t DRAM_ALIGN_BYTES = 512;

static constexpr uint64_t align_up_u64(uint64_t x, uint64_t a) {
  return (a == 0) ? x : ((x + a - 1) / a) * a;
}

static void cleanup() {
  if (A_buffer) vx_mem_free(A_buffer);
  if (W_int4_buffer) vx_mem_free(W_int4_buffer);
  if (scales_buffer) vx_mem_free(scales_buffer);
  if (zeros_buffer) vx_mem_free(zeros_buffer);
  if (C_buffer) vx_mem_free(C_buffer);
  if (krnl_buffer) vx_mem_free(krnl_buffer);
  if (args_buffer) vx_mem_free(args_buffer);
  if (device) vx_dev_close(device);

  A_buffer = nullptr;
  W_int4_buffer = nullptr;
  scales_buffer = nullptr;
  zeros_buffer = nullptr;
  C_buffer = nullptr;
  krnl_buffer = nullptr;
  args_buffer = nullptr;
  device = nullptr;
}

// ============================================================================
// FP16 conversion (used to produce well-formed FP16 inputs and scales)
// ============================================================================

static uint16_t float_to_fp16(float f) {
  union { float f; uint32_t i; } u = {f};
  uint32_t x       = u.i;
  uint16_t sign    = uint16_t((x >> 16) & 0x8000u);
  int32_t  exp32   = int32_t((x >> 23) & 0xFFu);
  uint32_t mant32  = x & 0x7FFFFFu;

  if (exp32 == 0xFF) {
    return sign | (mant32 ? 0x7E00u : 0x7C00u);
  }
  if (exp32 == 0) return sign;

  int32_t exp_f16 = exp32 - 127 + 15;
  if (exp_f16 >= 31) return sign | 0x7C00u;

  if (exp_f16 >= 1) {
    uint32_t mant_top   = mant32 >> 13;
    uint32_t round_bits = mant32 & 0x1FFFu;
    if (round_bits > 0x1000u ||
        (round_bits == 0x1000u && (mant_top & 1u))) {
      mant_top += 1;
      if (mant_top == 0x400u) {
        mant_top = 0;
        exp_f16 += 1;
        if (exp_f16 >= 31) return sign | 0x7C00u;
      }
    }
    return sign | uint16_t(exp_f16 << 10) | uint16_t(mant_top);
  }

  if (exp_f16 < -10) return sign;

  uint32_t m24         = mant32 | 0x800000u;
  int32_t  shift       = 14 - exp_f16;
  uint32_t round_mask  = (1u << shift) - 1u;
  uint32_t half        = 1u << (shift - 1);
  uint32_t round_bits  = m24 & round_mask;
  uint32_t mant10      = m24 >> shift;
  if (round_bits > half ||
      (round_bits == half && (mant10 & 1u))) {
    mant10 += 1;
    if (mant10 == 0x400u) {
      return sign | (1u << 10);
    }
  }
  return sign | uint16_t(mant10);
}

static uint8_t pack_int4_pair(int8_t lo, int8_t hi) {
  return uint8_t((uint8_t(hi) & 0x0F) << 4) | uint8_t(lo & 0x0F);
}

// ============================================================================
// Test vector generation (deterministic; no host-side reference output)
// ============================================================================

static void build_test_vectors(std::vector<uint16_t>& h_A,
                               std::vector<int8_t>& h_W_raw,
                               std::vector<uint16_t>& h_scales,
                               std::vector<int16_t>& h_zeros) {
  uint32_t groups_total = (K + QBLK - 1) / QBLK;
  uint32_t ng_total = (N + QBLK - 1) / QBLK;
  uint32_t sc_zp_size = (QDIR == 0) ? (groups_total * N) : (K * ng_total);

  h_A.resize(M * K);
  h_W_raw.resize(K * N);
  h_scales.resize(sc_zp_size);
  h_zeros.resize(sc_zp_size);

  for (uint32_t m = 0; m < M; ++m)
    for (uint32_t k = 0; k < K; ++k)
      h_A[m * K + k] = float_to_fp16(1.0f + float((m + k) % 7));

  for (uint32_t k = 0; k < K; ++k)
    for (uint32_t n = 0; n < N; ++n)
      h_W_raw[k * N + n] = int8_t(int((k * N + n) % 7) - 3);

  if (QDIR == 0) {
    for (uint32_t kg = 0; kg < groups_total; ++kg)
      for (uint32_t n = 0; n < N; ++n) {
        h_scales[kg * N + n] = float_to_fp16(1.0f + float(n % 7));
        h_zeros[kg * N + n] = int16_t(int(n % 7) - 3);
      }
  } else {
    for (uint32_t k = 0; k < K; ++k)
      for (uint32_t ng = 0; ng < ng_total; ++ng) {
        h_scales[k * ng_total + ng] = float_to_fp16(1.0f + float(ng % 7));
        h_zeros[k * ng_total + ng] = int16_t(int(ng % 7) - 3);
      }
  }
}

// ============================================================================
// Tiled DRAM layout (verbatim from main.cpp; kernel relies on this layout)
// ============================================================================

static void convert_input_tiled(const std::vector<uint16_t>& h_A,
                                std::vector<uint8_t>& tiled) {
  uint32_t m_tiles  = (M + DMA_MT - 1) / DMA_MT;
  uint32_t k_micros = K / DMA_MXU_KT;
  size_t idx = 0;

  size_t total = 0;
  for (uint32_t mt = 0; mt < m_tiles; mt++) {
    uint32_t cur_m = ((M - mt * DMA_MT) < DMA_MT) ? (M - mt * DMA_MT) : DMA_MT;
    total += cur_m * K * 2;
  }
  tiled.resize(total);

  for (uint32_t mt = 0; mt < m_tiles; mt++) {
    uint32_t cur_m = ((M - mt * DMA_MT) < DMA_MT) ? (M - mt * DMA_MT) : DMA_MT;
    for (uint32_t km = 0; km < k_micros; km++) {
      for (uint32_t m = 0; m < cur_m; m++) {
        for (uint32_t k = 0; k < DMA_MXU_KT; k++) {
          uint16_t val = h_A[(mt * DMA_MT + m) * K + (km * DMA_MXU_KT + k)];
          tiled[idx++] = val & 0xFF;
          tiled[idx++] = (val >> 8) & 0xFF;
        }
      }
    }
  }
}

static void convert_weight_tiled(const std::vector<int8_t>& h_W_raw,
                                 std::vector<uint8_t>& tiled) {
  uint32_t k_tiles   = (K + DMA_KT - 1) / DMA_KT;
  uint32_t n_tiles   = N / DMA_MXU_NT;

  size_t seg = (WTRANS == 0) ? DMA_MXU_KT * (DMA_MXU_NT / 2)
                              : DMA_MXU_NT * (DMA_MXU_KT / 2);
  size_t total = 0;
  for (uint32_t kt = 0; kt < k_tiles; kt++) {
    uint32_t ck = ((K - kt * DMA_KT) < DMA_KT) ? (K - kt * DMA_KT) : DMA_KT;
    total += n_tiles * (ck / DMA_MXU_KT) * seg;
  }
  tiled.resize(total);
  size_t idx = 0;

  for (uint32_t kt = 0; kt < k_tiles; kt++) {
    uint32_t cur_k = ((K - kt * DMA_KT) < DMA_KT) ? (K - kt * DMA_KT) : DMA_KT;
    uint32_t cur_kb_per_kt = cur_k / DMA_MXU_KT;
    for (uint32_t nt = 0; nt < n_tiles; nt++) {
      for (uint32_t kb = 0; kb < cur_kb_per_kt; kb++) {
        if (WTRANS == 0) {
          for (uint32_t k = 0; k < DMA_MXU_KT; k++) {
            for (uint32_t n = 0; n < DMA_MXU_NT; n += 2) {
              uint32_t gk  = kt * DMA_KT + kb * DMA_MXU_KT + k;
              uint32_t gn0 = nt * DMA_MXU_NT + n;
              uint32_t gn1 = gn0 + 1;
              int8_t w0 = h_W_raw[gk * N + gn0];
              int8_t w1 = (gn1 < N) ? h_W_raw[gk * N + gn1] : 0;
              tiled[idx++] = pack_int4_pair(w0, w1);
            }
          }
        } else {
          for (uint32_t n = 0; n < DMA_MXU_NT; n++) {
            for (uint32_t k = 0; k < DMA_MXU_KT; k += 2) {
              uint32_t gk0 = kt * DMA_KT + kb * DMA_MXU_KT + k;
              uint32_t gk1 = gk0 + 1;
              uint32_t gn  = nt * DMA_MXU_NT + n;
              int8_t w0 = h_W_raw[gk0 * N + gn];
              int8_t w1 = (gk1 < K) ? h_W_raw[gk1 * N + gn] : 0;
              tiled[idx++] = pack_int4_pair(w0, w1);
            }
          }
        }
      }
    }
  }
}

static size_t scale_slot_bytes(uint32_t ck, uint32_t cn) {
  uint32_t ng_per_mxu_nt = (DMA_MXU_NT + QBLK - 1) / QBLK;
  size_t actual = (QDIR == 0)
                    ? (size_t(ck / QBLK) * cn * 2)
                    : (size_t(cn / DMA_MXU_NT) * ck * ng_per_mxu_nt * 2);
  return (actual + 511u) & ~size_t(511u);
}

template <typename T>
static void fill_scale_zp_slot(const std::vector<T>& h_src,
                               std::vector<uint8_t>& tiled,
                               size_t slot_off, uint32_t kt,
                               uint32_t nt_dma, uint32_t cur_k,
                               uint32_t cur_nb_per_nt) {
  uint32_t ng_total            = (N + QBLK - 1) / QBLK;
  uint32_t full_groups_per_kt  = DMA_KT / QBLK;
  uint32_t ng_per_mxu_nt       = (DMA_MXU_NT + QBLK - 1) / QBLK;
  uint32_t mxu_per_dma_nt      = DMA_NT / DMA_MXU_NT;

  size_t idx = slot_off;
  for (uint32_t nb = 0; nb < cur_nb_per_nt; nb++) {
    uint32_t global_nt_mxu = nt_dma * mxu_per_dma_nt + nb;
    if (QDIR == 0) {
      uint32_t cur_groups = cur_k / QBLK;
      for (uint32_t g = 0; g < cur_groups; g++) {
        for (uint32_t n = 0; n < DMA_MXU_NT; n++) {
          uint32_t global_g = kt * full_groups_per_kt + g;
          uint16_t val = uint16_t(h_src[global_g * N + global_nt_mxu * DMA_MXU_NT + n]);
          tiled[idx++] = val & 0xFF;
          tiled[idx++] = (val >> 8) & 0xFF;
        }
      }
    } else {
      for (uint32_t k = 0; k < cur_k; k++) {
        for (uint32_t ng = 0; ng < ng_per_mxu_nt; ng++) {
          uint32_t global_k  = kt * DMA_KT + k;
          uint32_t global_ng = (global_nt_mxu * DMA_MXU_NT) / QBLK + ng;
          uint16_t val = uint16_t(h_src[global_k * ng_total + global_ng]);
          tiled[idx++] = val & 0xFF;
          tiled[idx++] = (val >> 8) & 0xFF;
        }
      }
    }
  }
}

static size_t scale_total_bytes() {
  uint32_t k_tiles     = (K + DMA_KT - 1) / DMA_KT;
  uint32_t n_tiles_dma = (N + DMA_NT - 1) / DMA_NT;
  size_t total = 0;
  for (uint32_t kt = 0; kt < k_tiles; kt++) {
    uint32_t cur_k = ((K - kt * DMA_KT) < DMA_KT) ? (K - kt * DMA_KT) : DMA_KT;
    for (uint32_t nt_dma = 0; nt_dma < n_tiles_dma; nt_dma++) {
      uint32_t cur_n = ((N - nt_dma * DMA_NT) < DMA_NT) ? (N - nt_dma * DMA_NT) : DMA_NT;
      total += scale_slot_bytes(cur_k, cur_n);
    }
  }
  return total;
}

static void convert_scale_tiled(const std::vector<uint16_t>& h_scales,
                                std::vector<uint8_t>& tiled) {
  uint32_t k_tiles     = (K + DMA_KT - 1) / DMA_KT;
  uint32_t n_tiles_dma = (N + DMA_NT - 1) / DMA_NT;

  tiled.assign(scale_total_bytes(), 0);

  size_t slot_off = 0;
  for (uint32_t kt = 0; kt < k_tiles; kt++) {
    uint32_t cur_k = ((K - kt * DMA_KT) < DMA_KT) ? (K - kt * DMA_KT) : DMA_KT;
    for (uint32_t nt_dma = 0; nt_dma < n_tiles_dma; nt_dma++) {
      uint32_t cur_n = ((N - nt_dma * DMA_NT) < DMA_NT) ? (N - nt_dma * DMA_NT) : DMA_NT;
      uint32_t cur_nb_per_nt = cur_n / DMA_MXU_NT;
      fill_scale_zp_slot(h_scales, tiled, slot_off, kt, nt_dma, cur_k, cur_nb_per_nt);
      slot_off += scale_slot_bytes(cur_k, cur_n);
    }
  }
}

static void convert_zp_tiled(const std::vector<int16_t>& h_zeros,
                             std::vector<uint8_t>& tiled) {
  uint32_t k_tiles     = (K + DMA_KT - 1) / DMA_KT;
  uint32_t n_tiles_dma = (N + DMA_NT - 1) / DMA_NT;

  tiled.assign(scale_total_bytes(), 0);

  size_t slot_off = 0;
  for (uint32_t kt = 0; kt < k_tiles; kt++) {
    uint32_t cur_k = ((K - kt * DMA_KT) < DMA_KT) ? (K - kt * DMA_KT) : DMA_KT;
    for (uint32_t nt_dma = 0; nt_dma < n_tiles_dma; nt_dma++) {
      uint32_t cur_n = ((N - nt_dma * DMA_NT) < DMA_NT) ? (N - nt_dma * DMA_NT) : DMA_NT;
      uint32_t cur_nb_per_nt = cur_n / DMA_MXU_NT;
      fill_scale_zp_slot(h_zeros, tiled, slot_off, kt, nt_dma, cur_k, cur_nb_per_nt);
      slot_off += scale_slot_bytes(cur_k, cur_n);
    }
  }
}

// ============================================================================
// TMEM layout (verbatim from main.cpp)
// ============================================================================

static bool compute_tmem_layout(kernel_arg_t& kargs, uint64_t tensor_mem_size) {
  uint32_t groups_tile = DMA_KT / QBLK;
  uint32_t ng_tile     = (DMA_NT + QBLK - 1) / QBLK;

  uint64_t tmem_ibuf_bytes  = uint64_t(DMA_MT) * DMA_KT * 2;
  uint64_t tmem_wbuf_bytes  = uint64_t(DMA_KT) * ((DMA_NT + 1) / 2);
  uint64_t tmem_scbuf_bytes = (QDIR == 0)
                                ? (uint64_t(groups_tile) * DMA_NT * 2)
                                : (uint64_t(DMA_KT) * ng_tile * 2);
  uint64_t tmem_zpbuf_bytes = tmem_scbuf_bytes;
  uint64_t tmem_obuf_bytes  = uint64_t(DMA_MT) * DMA_NT * 2;

  uint64_t cur = 0;

  auto alloc = [&](uint64_t bytes, uint64_t& out_base) -> bool {
    cur = align_up_u64(cur, TMEM_LAYOUT_ALIGN_BYTES);
    if (bytes > (tensor_mem_size - cur)) return false;
    out_base = cur;
    cur += align_up_u64(bytes, TMEM_LAYOUT_ALIGN_BYTES);
    return true;
  };

  if (!alloc(tmem_ibuf_bytes,  kargs.lmem_ibuf[0]))  return false;
  if (!alloc(tmem_ibuf_bytes,  kargs.lmem_ibuf[1]))  return false;
  if (!alloc(tmem_wbuf_bytes,  kargs.lmem_wbuf[0]))  return false;
  if (!alloc(tmem_wbuf_bytes,  kargs.lmem_wbuf[1]))  return false;
  if (!alloc(tmem_scbuf_bytes, kargs.lmem_scbuf[0])) return false;
  if (!alloc(tmem_scbuf_bytes, kargs.lmem_scbuf[1])) return false;
  if (!alloc(tmem_zpbuf_bytes, kargs.lmem_zpbuf[0])) return false;
  if (!alloc(tmem_zpbuf_bytes, kargs.lmem_zpbuf[1])) return false;
  if (!alloc(tmem_obuf_bytes,  kargs.lmem_obuf[0]))  return false;
  if (!alloc(tmem_obuf_bytes,  kargs.lmem_obuf[1]))  return false;

  return true;
}

// ============================================================================
// Main
// ============================================================================

int main(int argc, char *argv[]) {
  // Strip --warmup / --iterations / --csv first; remaining argv goes to getopt.
  auto bench = vx_bench::parse(argc, argv);

  optind = 1;
  int c;
  while ((c = getopt(argc, argv, "m:n:k:q:t:d:h")) != -1) {
    switch (c) {
    case 'm': M = atoi(optarg); break;
    case 'n': N = atoi(optarg); break;
    case 'k': K = atoi(optarg); break;
    case 'q': QBLK = atoi(optarg); break;
    case 't': WTRANS = atoi(optarg); break;
    case 'd': QDIR = atoi(optarg); break;
    case 'h':
      printf("Usage: %s [--warmup=N] [--iterations=N] [--csv] "
             "[--output=PATH] [--output-append] "
             "[-m M] [-n N] [-k K] [-q QBLK] [-t WTRANS] [-d QDIR]\n", argv[0]);
      return 0;
    default:
      printf("Usage: %s [--warmup=N] [--iterations=N] [--csv] "
             "[--output=PATH] [--output-append] "
             "[-m M] [-n N] [-k K] [-q QBLK] [-t WTRANS] [-d QDIR]\n", argv[0]);
      return -1;
    }
  }

  if (QBLK == 0 || WTRANS > 1 || QDIR > 1) {
    std::cerr << "Invalid parameters: QBLK=" << QBLK
              << " WTRANS=" << WTRANS << " QDIR=" << QDIR << std::endl;
    return -1;
  }
  if (M % 8 != 0) {
    std::cerr << "M=" << M << " must be a multiple of 8" << std::endl;
    return -1;
  }
  if (N % DMA_MXU_NT != 0) {
    std::cerr << "N=" << N << " must be a multiple of DMA_MXU_NT=" << DMA_MXU_NT << std::endl;
    return -1;
  }
  if (K % DMA_MXU_KT != 0) {
    std::cerr << "K=" << K << " must be a multiple of DMA_MXU_KT=" << DMA_MXU_KT << std::endl;
    return -1;
  }
  if (QDIR == 0 && (DMA_KT % QBLK != 0)) {
    std::cerr << "QCOL mode: DMA_KT=" << DMA_KT
              << " must be divisible by QBLK=" << QBLK << std::endl;
    return -1;
  }

  if (!bench.csv) {
    printf("FPINT-GEMM-FFN-HW-Improve Bench: M=%u N=%u K=%u QBLK=%u WTRANS=%u QDIR=%u  "
           "warmup=%d iterations=%d\n",
           M, N, K, QBLK, WTRANS, QDIR, bench.warmup, bench.iterations);
  }

  RT_CHECK(vx_dev_open(&device));

  uint64_t num_cores = 0, num_warps = 0, num_threads = 0;
  RT_CHECK(vx_dev_caps(device, VX_CAPS_NUM_CORES,   &num_cores));
  RT_CHECK(vx_dev_caps(device, VX_CAPS_NUM_WARPS,   &num_warps));
  RT_CHECK(vx_dev_caps(device, VX_CAPS_NUM_THREADS, &num_threads));

  uint64_t tensor_mem_size = TMEM_BANK_SIZE * NUM_DMA_CHANNELS;

  // ---- Generate test vectors (no host reference) ----
  std::vector<uint16_t> h_A;
  std::vector<int8_t>   h_W_raw;
  std::vector<uint16_t> h_scales;
  std::vector<int16_t>  h_zeros;
  build_test_vectors(h_A, h_W_raw, h_scales, h_zeros);

  // ---- Convert to tiled DRAM layout ----
  std::vector<uint8_t> tiled_input, tiled_weight, tiled_scale, tiled_zp;
  convert_input_tiled(h_A,      tiled_input);
  convert_weight_tiled(h_W_raw, tiled_weight);
  convert_scale_tiled(h_scales, tiled_scale);
  convert_zp_tiled(h_zeros,     tiled_zp);

  // Compute tiled output buffer size
  uint32_t m_tiles = (M + DMA_MT - 1) / DMA_MT;
  uint32_t n_tiles = N / DMA_MXU_NT;
  size_t out_total_bytes = 0;
  for (uint32_t mt = 0; mt < m_tiles; mt++) {
    uint32_t cur_m = ((M - mt * DMA_MT) < DMA_MT) ? (M - mt * DMA_MT) : DMA_MT;
    out_total_bytes += n_tiles * cur_m * DMA_MXU_NT * 2;
  }

  // ---- Allocate device buffers ----
  RT_CHECK(vx_mem_alloc_aligned(device, tiled_input.size(),  DRAM_ALIGN_BYTES, VX_MEM_READ,  &A_buffer));
  RT_CHECK(vx_mem_alloc_aligned(device, tiled_weight.size(), DRAM_ALIGN_BYTES, VX_MEM_READ,  &W_int4_buffer));
  RT_CHECK(vx_mem_alloc_aligned(device, tiled_scale.size(),  DRAM_ALIGN_BYTES, VX_MEM_READ,  &scales_buffer));
  RT_CHECK(vx_mem_alloc_aligned(device, tiled_zp.size(),     DRAM_ALIGN_BYTES, VX_MEM_READ,  &zeros_buffer));
  RT_CHECK(vx_mem_alloc_aligned(device, out_total_bytes,     DRAM_ALIGN_BYTES, VX_MEM_WRITE, &C_buffer));

  // ---- Upload tiled data ----
  RT_CHECK(vx_copy_to_dev(A_buffer,      tiled_input.data(),  0, tiled_input.size()));
  RT_CHECK(vx_copy_to_dev(W_int4_buffer, tiled_weight.data(), 0, tiled_weight.size()));
  RT_CHECK(vx_copy_to_dev(scales_buffer, tiled_scale.data(),  0, tiled_scale.size()));
  RT_CHECK(vx_copy_to_dev(zeros_buffer,  tiled_zp.data(),     0, tiled_zp.size()));

  std::vector<uint8_t> zero_out(out_total_bytes, 0);
  RT_CHECK(vx_copy_to_dev(C_buffer, zero_out.data(), 0, out_total_bytes));

  RT_CHECK(vx_upload_kernel_file(device, kernel_file, &krnl_buffer));

  // ---- Set up kernel arguments ----
  kernel_arg_t kargs = {};

  RT_CHECK(vx_mem_address(A_buffer,      &kargs.dram_in_base));
  RT_CHECK(vx_mem_address(W_int4_buffer, &kargs.dram_w_base));
  RT_CHECK(vx_mem_address(scales_buffer, &kargs.dram_sc_base));
  RT_CHECK(vx_mem_address(zeros_buffer,  &kargs.dram_zp_base));
  RT_CHECK(vx_mem_address(C_buffer,      &kargs.dram_out_base));

  if (!compute_tmem_layout(kargs, tensor_mem_size)) {
    std::cerr << "TMEM layout does not fit device tensor memory (size="
              << tensor_mem_size << ")" << std::endl;
    cleanup();
    return -1;
  }

  kargs.M      = M;
  kargs.N      = N;
  kargs.K      = K;
  kargs.QBLK   = QBLK;
  kargs.WTRANS = WTRANS;
  kargs.QDIR   = QDIR;
  kargs.status = STATUS_INIT;

  RT_CHECK(vx_mem_alloc(device, sizeof(kargs), VX_MEM_READ_WRITE, &args_buffer));
  RT_CHECK(vx_copy_to_dev(args_buffer, &kargs, 0, sizeof(kargs)));

  // ---- Warmup --------------------------------------------------------------
  // No need to re-upload args: the kernel only reads kargs once per launch and
  // never reads back its own status field. DRAM contents persist between runs.
  for (int i = 0; i < bench.warmup; ++i) {
    RT_CHECK(vx_start(device, krnl_buffer, args_buffer));
    RT_CHECK(vx_ready_wait(device, VX_MAX_TIMEOUT));
  }

  // ---- Timed iterations ----------------------------------------------------
  vx_bench::Stats stats;
  for (int i = 0; i < bench.iterations; ++i) {
    vx_bench::Stopwatch sw; sw.start();
    RT_CHECK(vx_start(device, krnl_buffer, args_buffer));
    RT_CHECK(vx_ready_wait(device, VX_MAX_TIMEOUT));
    stats.record(sw.stop_us());
  }

  stats.report("fpint_gemm_ffn_hw_improve", bench);

  if (!bench.csv) {
    printf("\n[Performance]\n");
    vx_dump_perf(device, stdout);
  }

  cleanup();
  return 0;
}
