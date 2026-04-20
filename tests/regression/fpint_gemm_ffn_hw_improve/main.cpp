#include <iostream>
#include <unistd.h>
#include <string.h>
#include <vector>
#include <cmath>
#include <algorithm>
#include <vortex.h>
#include "common.h"

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

static uint32_t M = 2;
static uint32_t N = 32;
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

static constexpr float FP16_TOL = 0.01f;

// Tile constants
static constexpr uint32_t DMA_MT     = GEMM_FSM_MT;      // 128
static constexpr uint32_t DMA_NT     = GEMM_FSM_NT;      // 128 (full N-tile for LMEM sizing)
static constexpr uint32_t DMA_KT     = GEMM_FSM_KT;      // 128
static constexpr uint32_t DMA_MXU_KT = GEMM_FSM_MXU_KT;  // 32
static constexpr uint32_t DMA_MXU_NT = GEMM_FSM_MXU_NT;   // 32

static constexpr uint64_t LMEM_LAYOUT_ALIGN_BYTES = 4096;

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

static void show_usage() {
  std::cout << "Usage: [-m M] [-n N] [-k K] [-q QBLK] [-t WTRANS] [-d QDIR] [-h]" << std::endl;
}

static void parse_args(int argc, char **argv) {
  int c;
  while ((c = getopt(argc, argv, "m:n:k:q:t:d:h")) != -1) {
    switch (c) {
    case 'm': M = atoi(optarg); break;
    case 'n': N = atoi(optarg); break;
    case 'k': K = atoi(optarg); break;
    case 'q': QBLK = atoi(optarg); break;
    case 't': WTRANS = atoi(optarg); break;
    case 'd': QDIR = atoi(optarg); break;
    case 'h': show_usage(); exit(0); break;
    default: show_usage(); exit(-1);
    }
  }
}

// ============================================================================
// FP16 conversion utilities
// ============================================================================

static uint16_t float_to_fp16(float f) {
  union { float f; uint32_t i; } u = {f};
  uint32_t sign = (u.i >> 16) & 0x8000;
  int32_t exp = ((u.i >> 23) & 0xFF) - 127 + 15;
  uint32_t mantissa = (u.i >> 13) & 0x3FF;

  if (exp <= 0) return sign;
  if (exp >= 31) return sign | 0x7C00;

  return sign | (exp << 10) | mantissa;
}

static float fp16_to_float(uint16_t h) {
  uint32_t sign = (h >> 15) & 0x1;
  uint32_t exp = (h >> 10) & 0x1F;
  uint32_t mantissa = h & 0x3FF;

  if (exp == 0) {
    if (mantissa == 0) return sign ? -0.0f : 0.0f;
    float val = mantissa / 1024.0f;
    return sign ? -val / 16384.0f : val / 16384.0f;
  }
  if (exp == 31) return sign ? -INFINITY : INFINITY;

  uint32_t f = (sign << 31) | ((exp - 15 + 127) << 23) | (mantissa << 13);
  float out;
  __builtin_memcpy(&out, &f, sizeof(float));
  return out;
}

static uint8_t pack_int4_pair(int8_t lo, int8_t hi) {
  return uint8_t((uint8_t(hi) & 0x0F) << 4) | uint8_t(lo & 0x0F);
}

// ============================================================================
// Test vector generation (row-major, same data patterns as before)
// ============================================================================

static void build_test_vectors(std::vector<uint16_t>& h_A,
                               std::vector<int8_t>& h_W_raw,
                               std::vector<uint16_t>& h_scales,
                               std::vector<int16_t>& h_zeros,
                               std::vector<uint16_t>& h_ref_out_fp16) {
  uint32_t groups_total = (K + QBLK - 1) / QBLK;
  uint32_t ng_total = (N + QBLK - 1) / QBLK;
  uint32_t sc_zp_size = (QDIR == 0) ? (groups_total * N) : (K * ng_total);

  h_A.resize(M * K);
  h_W_raw.resize(K * N);
  h_scales.resize(sc_zp_size);
  h_zeros.resize(sc_zp_size);
  h_ref_out_fp16.resize(M * N);

  // Input matrix A [M x K] fp16
  for (uint32_t m = 0; m < M; ++m)
    for (uint32_t k = 0; k < K; ++k)
      h_A[m * K + k] = float_to_fp16(1.0f + float((m + k) % 7));

  // Weight matrix W [K x N] raw int4 values (unpacked for reference)
  for (uint32_t k = 0; k < K; ++k)
    for (uint32_t n = 0; n < N; ++n)
      h_W_raw[k * N + n] = int8_t(int((k * N + n) % 7) - 3);

  // Scale and zero-point
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

  // Reference output C = A * dequant(W) [M x N]
  for (uint32_t m = 0; m < M; ++m)
    for (uint32_t n = 0; n < N; ++n) {
      float sum = 0.0f;
      for (uint32_t k = 0; k < K; ++k) {
        float a = fp16_to_float(h_A[m * K + k]);
        float scale, zp;
        if (QDIR == 0) {
          uint32_t gid = k / QBLK;
          scale = fp16_to_float(h_scales[gid * N + n]);
          zp = float(h_zeros[gid * N + n]);
        } else {
          uint32_t ng = n / QBLK;
          scale = fp16_to_float(h_scales[k * ng_total + ng]);
          zp = float(h_zeros[k * ng_total + ng]);
        }
        float w = float(h_W_raw[k * N + n]);
        sum += a * (w - zp) * scale;
      }
      h_ref_out_fp16[m * N + n] = float_to_fp16(sum);
    }
}

// ============================================================================
// Tiled DRAM data conversion (matching tb_VX_gemm_node_improve layout)
// ============================================================================

// Input tiled: for each (mt, km), store [cur_m][MXU_KT] fp16 contiguously
static void convert_input_tiled(const std::vector<uint16_t>& h_A,
                                std::vector<uint8_t>& tiled) {
  uint32_t m_tiles  = (M + DMA_MT - 1) / DMA_MT;
  uint32_t k_micros = K / DMA_MXU_KT;
  size_t idx = 0;

  // Pre-compute total size
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

// Weight tiled: per (kt, nt) tile, kb_per_kt contiguous micro-tiles of packed int4
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
          // [MXU_KT rows][MXU_NT/2 cols], k outer, n-pairs inner
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
          // [MXU_NT rows][MXU_KT/2 cols], n outer, k-pairs inner
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

// Scale tiled: per (kt, nt) tile
//   QCOL: [groups_per_kt][MXU_NT] fp16
//   QROW: [KT][ng_per_nt] fp16
static void convert_scale_tiled(const std::vector<uint16_t>& h_scales,
                                std::vector<uint8_t>& tiled) {
  uint32_t k_tiles = (K + DMA_KT - 1) / DMA_KT;
  uint32_t n_tiles = N / DMA_MXU_NT;
  uint32_t ng_total = (N + QBLK - 1) / QBLK;
  uint32_t full_groups_per_kt = DMA_KT / QBLK;
  uint32_t ng_per_nt = (DMA_MXU_NT + QBLK - 1) / QBLK;

  // Compute total size (last K-tile may be smaller)
  size_t total = 0;
  for (uint32_t kt = 0; kt < k_tiles; kt++) {
    uint32_t ck = ((K - kt * DMA_KT) < DMA_KT) ? (K - kt * DMA_KT) : DMA_KT;
    size_t tile_bytes = (QDIR == 0) ? ((ck / QBLK) * DMA_MXU_NT * 2)
                                     : (ck * ng_per_nt * 2);
    total += n_tiles * tile_bytes;
  }
  tiled.resize(total);
  size_t idx = 0;

  for (uint32_t kt = 0; kt < k_tiles; kt++) {
    uint32_t cur_k = ((K - kt * DMA_KT) < DMA_KT) ? (K - kt * DMA_KT) : DMA_KT;
    for (uint32_t nt = 0; nt < n_tiles; nt++) {
      if (QDIR == 0) {
        uint32_t cur_groups = cur_k / QBLK;
        for (uint32_t g = 0; g < cur_groups; g++) {
          for (uint32_t n = 0; n < DMA_MXU_NT; n++) {
            uint32_t global_g = kt * full_groups_per_kt + g;
            uint16_t val = h_scales[global_g * N + nt * DMA_MXU_NT + n];
            tiled[idx++] = val & 0xFF;
            tiled[idx++] = (val >> 8) & 0xFF;
          }
        }
      } else {
        for (uint32_t k = 0; k < cur_k; k++) {
          for (uint32_t ng = 0; ng < ng_per_nt; ng++) {
            uint32_t global_k  = kt * DMA_KT + k;
            uint32_t global_ng = (nt * DMA_MXU_NT) / QBLK + ng;
            uint16_t val = h_scales[global_k * ng_total + global_ng];
            tiled[idx++] = val & 0xFF;
            tiled[idx++] = (val >> 8) & 0xFF;
          }
        }
      }
    }
  }
}

// Zero-point tiled: same layout as scale
static void convert_zp_tiled(const std::vector<int16_t>& h_zeros,
                             std::vector<uint8_t>& tiled) {
  uint32_t k_tiles = (K + DMA_KT - 1) / DMA_KT;
  uint32_t n_tiles = N / DMA_MXU_NT;
  uint32_t ng_total = (N + QBLK - 1) / QBLK;
  uint32_t full_groups_per_kt = DMA_KT / QBLK;
  uint32_t ng_per_nt = (DMA_MXU_NT + QBLK - 1) / QBLK;

  // Compute total size (last K-tile may be smaller)
  size_t total = 0;
  for (uint32_t kt = 0; kt < k_tiles; kt++) {
    uint32_t ck = ((K - kt * DMA_KT) < DMA_KT) ? (K - kt * DMA_KT) : DMA_KT;
    size_t tile_bytes = (QDIR == 0) ? ((ck / QBLK) * DMA_MXU_NT * 2)
                                     : (ck * ng_per_nt * 2);
    total += n_tiles * tile_bytes;
  }
  tiled.resize(total);
  size_t idx = 0;

  for (uint32_t kt = 0; kt < k_tiles; kt++) {
    uint32_t cur_k = ((K - kt * DMA_KT) < DMA_KT) ? (K - kt * DMA_KT) : DMA_KT;
    for (uint32_t nt = 0; nt < n_tiles; nt++) {
      if (QDIR == 0) {
        uint32_t cur_groups = cur_k / QBLK;
        for (uint32_t g = 0; g < cur_groups; g++) {
          for (uint32_t n = 0; n < DMA_MXU_NT; n++) {
            uint32_t global_g = kt * full_groups_per_kt + g;
            uint16_t val = uint16_t(h_zeros[global_g * N + nt * DMA_MXU_NT + n]);
            tiled[idx++] = val & 0xFF;
            tiled[idx++] = (val >> 8) & 0xFF;
          }
        }
      } else {
        for (uint32_t k = 0; k < cur_k; k++) {
          for (uint32_t ng = 0; ng < ng_per_nt; ng++) {
            uint32_t global_k  = kt * DMA_KT + k;
            uint32_t global_ng = (nt * DMA_MXU_NT) / QBLK + ng;
            uint16_t val = uint16_t(h_zeros[global_k * ng_total + global_ng]);
            tiled[idx++] = val & 0xFF;
            tiled[idx++] = (val >> 8) & 0xFF;
          }
        }
      }
    }
  }
}

// ============================================================================
// Tiled output verification (matching tb check_output_tiled layout)
// Output tiled: for each (mt, nt), store [cur_m][MXU_NT] fp16
// ============================================================================

static bool compare_fp16(uint16_t actual, uint16_t expected, float tolerance) {
  if (actual == expected) return true;
  float a = fp16_to_float(actual);
  float e = fp16_to_float(expected);
  if (!std::isfinite(a) || !std::isfinite(e)) return false;
  float diff = (e == 0.0f) ? std::abs(a) : std::abs((a - e) / e);
  return diff <= tolerance;
}

static int verify_results_tiled(vx_buffer_h out_buffer,
                                const std::vector<uint16_t>& ref) {
  uint32_t m_tiles = (M + DMA_MT - 1) / DMA_MT;
  uint32_t n_tiles = N / DMA_MXU_NT;

  // Compute total output size
  size_t total_bytes = 0;
  for (uint32_t mt = 0; mt < m_tiles; mt++) {
    uint32_t cur_m = ((M - mt * DMA_MT) < DMA_MT) ? (M - mt * DMA_MT) : DMA_MT;
    total_bytes += n_tiles * cur_m * DMA_MXU_NT * 2;
  }

  std::vector<uint8_t> raw(total_bytes);
  RT_CHECK(vx_copy_from_dev(raw.data(), out_buffer, 0, total_bytes));

  int errors = 0;
  size_t idx = 0;

  for (uint32_t mt = 0; mt < m_tiles; mt++) {
    uint32_t cur_m = ((M - mt * DMA_MT) < DMA_MT) ? (M - mt * DMA_MT) : DMA_MT;
    for (uint32_t nt = 0; nt < n_tiles; nt++) {
      for (uint32_t m = 0; m < cur_m; m++) {
        for (uint32_t n = 0; n < DMA_MXU_NT; n++) {
          uint32_t gm = mt * DMA_MT + m;
          uint32_t gn = nt * DMA_MXU_NT + n;
          uint16_t got = uint16_t(raw[idx]) | (uint16_t(raw[idx + 1]) << 8);
          uint16_t exp = ref[gm * N + gn];
          idx += 2;

          if (!compare_fp16(got, exp, FP16_TOL)) {
            if (errors < 10) {
              printf("Mismatch[m=%u,n=%u]: got=0x%04x (%f), exp=0x%04x (%f)\n",
                     gm, gn,
                     unsigned(got), fp16_to_float(got),
                     unsigned(exp), fp16_to_float(exp));
            }
            ++errors;
          }
        }
      }
    }
  }

  return errors;
}

// ============================================================================
// LMEM layout computation (local memory offsets starting from 0)
// ============================================================================

static bool compute_lmem_layout(kernel_arg_t& kargs, uint64_t local_mem_size) {
  uint32_t groups_tile = DMA_KT / QBLK;
  uint32_t ng_tile     = (DMA_NT + QBLK - 1) / QBLK;

  uint64_t lmem_ibuf_bytes  = uint64_t(DMA_MT) * DMA_KT * 2;
  uint64_t lmem_wbuf_bytes  = uint64_t(DMA_KT) * ((DMA_NT + 1) / 2);
  uint64_t lmem_scbuf_bytes = (QDIR == 0)
                                ? (uint64_t(groups_tile) * DMA_NT * 2)
                                : (uint64_t(DMA_KT) * ng_tile * 2);
  uint64_t lmem_zpbuf_bytes = lmem_scbuf_bytes;
  uint64_t lmem_obuf_bytes  = uint64_t(DMA_MT) * DMA_NT * 2;

  uint64_t cur = 0;

  auto alloc = [&](uint64_t bytes, uint64_t& out_base) -> bool {
    cur = align_up_u64(cur, LMEM_LAYOUT_ALIGN_BYTES);
    if (bytes > (local_mem_size - cur)) return false;
    out_base = cur;
    cur += align_up_u64(bytes, LMEM_LAYOUT_ALIGN_BYTES);
    return true;
  };

  // Double-buffered: buf0, buf1 for each type
  // Scale and zp are paired (scbuf0, zpbuf0, scbuf1, zpbuf1) so qparam_src_stride is consistent.
  if (!alloc(lmem_ibuf_bytes,  kargs.lmem_ibuf[0]))  return false;
  if (!alloc(lmem_ibuf_bytes,  kargs.lmem_ibuf[1]))  return false;
  if (!alloc(lmem_wbuf_bytes,  kargs.lmem_wbuf[0]))  return false;
  if (!alloc(lmem_wbuf_bytes,  kargs.lmem_wbuf[1]))  return false;
  if (!alloc(lmem_scbuf_bytes, kargs.lmem_scbuf[0])) return false;
  if (!alloc(lmem_zpbuf_bytes, kargs.lmem_zpbuf[0])) return false;
  if (!alloc(lmem_scbuf_bytes, kargs.lmem_scbuf[1])) return false;
  if (!alloc(lmem_zpbuf_bytes, kargs.lmem_zpbuf[1])) return false;
  if (!alloc(lmem_obuf_bytes,  kargs.lmem_obuf[0]))  return false;
  if (!alloc(lmem_obuf_bytes,  kargs.lmem_obuf[1]))  return false;

  return true;
}

// ============================================================================
// Main
// ============================================================================

int main(int argc, char *argv[]) {
  parse_args(argc, argv);

  // Validate constraints
  if (QBLK == 0 || WTRANS > 1 || QDIR > 1) {
    std::cerr << "Invalid parameters: QBLK=" << QBLK
              << " WTRANS=" << WTRANS << " QDIR=" << QDIR << std::endl;
    return -1;
  }
  if (M % 8 != 0) {
    std::cerr << "M=" << M << " must be a multiple of 8"
              << std::endl;
    return -1;
  }
  if (N % DMA_MXU_NT != 0) {
    std::cerr << "N=" << N << " must be a multiple of DMA_MXU_NT=" << DMA_MXU_NT
              << std::endl;
    return -1;
  }
  if (K % DMA_MXU_KT != 0) {
    std::cerr << "K=" << K << " must be a multiple of DMA_MXU_KT=" << DMA_MXU_KT << std::endl;
    return -1;
  }
  if (QDIR == 0 && (DMA_KT % QBLK != 0)) {
    std::cerr << "QCOL mode: DMA_KT=" << DMA_KT << " must be divisible by QBLK=" << QBLK << std::endl;
    return -1;
  }

  std::cout << "Core-level GEMM instruction stream test" << std::endl;
  std::cout << "M=" << M << ", N=" << N << ", K=" << K
            << ", QBLK=" << QBLK << ", WTRANS=" << WTRANS
            << ", QDIR=" << QDIR << std::endl;
  std::cout << "Tile: MT=" << DMA_MT << " KT=" << DMA_KT
            << " MXU_KT=" << DMA_MXU_KT << " MXU_NT=" << DMA_MXU_NT << std::endl;

  RT_CHECK(vx_dev_open(&device));

  uint64_t num_cores = 0, num_warps = 0, num_threads = 0;
  uint64_t local_mem_size = 0;
  RT_CHECK(vx_dev_caps(device, VX_CAPS_NUM_CORES, &num_cores));
  RT_CHECK(vx_dev_caps(device, VX_CAPS_NUM_WARPS, &num_warps));
  RT_CHECK(vx_dev_caps(device, VX_CAPS_NUM_THREADS, &num_threads));
  RT_CHECK(vx_dev_caps(device, VX_CAPS_LOCAL_MEM_SIZE, &local_mem_size));
  std::cout << "Device: cores=" << num_cores
            << ", warps=" << num_warps
            << ", threads=" << num_threads
            << ", lmem=" << local_mem_size << " bytes" << std::endl;

  // ---- Generate test vectors (row-major) ----
  std::vector<uint16_t> h_A;
  std::vector<int8_t> h_W_raw;
  std::vector<uint16_t> h_scales;
  std::vector<int16_t> h_zeros;
  std::vector<uint16_t> h_ref_out_fp16;

  build_test_vectors(h_A, h_W_raw, h_scales, h_zeros, h_ref_out_fp16);

  // ---- Convert to tiled DRAM layout ----
  std::vector<uint8_t> tiled_input, tiled_weight, tiled_scale, tiled_zp;
  convert_input_tiled(h_A, tiled_input);
  convert_weight_tiled(h_W_raw, tiled_weight);
  convert_scale_tiled(h_scales, tiled_scale);
  convert_zp_tiled(h_zeros, tiled_zp);

  // ---- Debug: verify tiled data per n-tile ----
  if (N > DMA_MXU_NT) {
    uint32_t first_ck = (K < DMA_KT) ? K : DMA_KT;
    uint32_t wkt = first_ck * (DMA_MXU_NT / 2);  // weight bytes per (kt=0,nt)
    uint32_t groups_per_kt = first_ck / QBLK;
    uint32_t skt = (QDIR == 0) ? (groups_per_kt * DMA_MXU_NT * 2)
                                : (first_ck * ((DMA_MXU_NT + QBLK - 1) / QBLK) * 2);
    printf("DEBUG tiled sizes: weight_per_nt=%u, scale_per_nt=%u\n", wkt, skt);
    printf("DEBUG tiled_weight total=%zu, tiled_scale total=%zu\n",
           tiled_weight.size(), tiled_scale.size());

    // Compare first byte of nt=0 vs nt=1 weight tiles
    if (tiled_weight.size() >= 2 * wkt) {
      printf("DEBUG weight nt=0 first 8B: ");
      for (int i = 0; i < 8; i++) printf("%02x ", tiled_weight[i]);
      printf("\nDEBUG weight nt=1 first 8B: ");
      for (int i = 0; i < 8; i++) printf("%02x ", tiled_weight[wkt + i]);
      printf("\n");
      bool w_same = (memcmp(tiled_weight.data(), tiled_weight.data() + wkt, wkt) == 0);
      printf("DEBUG weight nt0==nt1: %s\n", w_same ? "YES (BUG!)" : "NO (ok)");
    }

    // Compare first byte of nt=0 vs nt=1 scale tiles
    if (tiled_scale.size() >= 2 * skt) {
      printf("DEBUG scale nt=0 first 8B: ");
      for (int i = 0; i < 8; i++) printf("%02x ", tiled_scale[i]);
      printf("\nDEBUG scale nt=1 first 8B: ");
      for (int i = 0; i < 8; i++) printf("%02x ", tiled_scale[skt + i]);
      printf("\n");
      bool s_same = (memcmp(tiled_scale.data(), tiled_scale.data() + skt, skt) == 0);
      printf("DEBUG scale nt0==nt1: %s\n", s_same ? "YES (BUG!)" : "NO (ok)");
    }

    // Also verify: host-side reference at n=0 vs n=32
    printf("DEBUG ref_out[0,0]=0x%04x (%f)\n",
           h_ref_out_fp16[0], fp16_to_float(h_ref_out_fp16[0]));
    printf("DEBUG ref_out[0,%u]=0x%04x (%f)\n",
           DMA_MXU_NT, h_ref_out_fp16[DMA_MXU_NT],
           fp16_to_float(h_ref_out_fp16[DMA_MXU_NT]));
  }

  // Compute tiled output buffer size
  uint32_t m_tiles = (M + DMA_MT - 1) / DMA_MT;
  uint32_t n_tiles = N / DMA_MXU_NT;
  size_t out_total_bytes = 0;
  for (uint32_t mt = 0; mt < m_tiles; mt++) {
    uint32_t cur_m = ((M - mt * DMA_MT) < DMA_MT) ? (M - mt * DMA_MT) : DMA_MT;
    out_total_bytes += n_tiles * cur_m * DMA_MXU_NT * 2;
  }

  // ---- Allocate device buffers ----
  RT_CHECK(vx_mem_alloc(device, tiled_input.size(),  VX_MEM_READ, &A_buffer));
  RT_CHECK(vx_mem_alloc(device, tiled_weight.size(), VX_MEM_READ, &W_int4_buffer));
  RT_CHECK(vx_mem_alloc(device, tiled_scale.size(),  VX_MEM_READ, &scales_buffer));
  RT_CHECK(vx_mem_alloc(device, tiled_zp.size(),     VX_MEM_READ, &zeros_buffer));
  RT_CHECK(vx_mem_alloc(device, out_total_bytes,     VX_MEM_WRITE, &C_buffer));

  // ---- Upload tiled data ----
  RT_CHECK(vx_copy_to_dev(A_buffer,       tiled_input.data(),  0, tiled_input.size()));
  RT_CHECK(vx_copy_to_dev(W_int4_buffer,  tiled_weight.data(), 0, tiled_weight.size()));
  RT_CHECK(vx_copy_to_dev(scales_buffer,  tiled_scale.data(),  0, tiled_scale.size()));
  RT_CHECK(vx_copy_to_dev(zeros_buffer,   tiled_zp.data(),     0, tiled_zp.size()));

  // Zero output buffer
  std::vector<uint8_t> zero_out(out_total_bytes, 0);
  RT_CHECK(vx_copy_to_dev(C_buffer, zero_out.data(), 0, out_total_bytes));

  // ---- Upload kernel ----
  RT_CHECK(vx_upload_kernel_file(device, kernel_file, &krnl_buffer));

  // ---- Set up kernel arguments ----
  kernel_arg_t kargs = {};

  RT_CHECK(vx_mem_address(A_buffer,       &kargs.dram_in_base));
  RT_CHECK(vx_mem_address(W_int4_buffer,  &kargs.dram_w_base));
  RT_CHECK(vx_mem_address(scales_buffer,  &kargs.dram_sc_base));
  RT_CHECK(vx_mem_address(zeros_buffer,   &kargs.dram_zp_base));
  RT_CHECK(vx_mem_address(C_buffer,       &kargs.dram_out_base));

  if (!compute_lmem_layout(kargs, local_mem_size)) {
    std::cerr << "LMEM layout does not fit device local memory (size="
              << local_mem_size << ")" << std::endl;
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

  std::cout << "LMEM layout (double-buffered):" << std::hex
            << " ibuf=[0x" << kargs.lmem_ibuf[0] << ",0x" << kargs.lmem_ibuf[1] << "]"
            << " wbuf=[0x" << kargs.lmem_wbuf[0] << ",0x" << kargs.lmem_wbuf[1] << "]"
            << " scbuf=[0x" << kargs.lmem_scbuf[0] << ",0x" << kargs.lmem_scbuf[1] << "]"
            << " zpbuf=[0x" << kargs.lmem_zpbuf[0] << ",0x" << kargs.lmem_zpbuf[1] << "]"
            << " obuf=[0x" << kargs.lmem_obuf[0] << ",0x" << kargs.lmem_obuf[1] << "]"
            << std::dec << std::endl;

  // args_buffer must be read/write: the kernel writes status back to args.
  RT_CHECK(vx_mem_alloc(device, sizeof(kargs), VX_MEM_READ_WRITE, &args_buffer));
  RT_CHECK(vx_copy_to_dev(args_buffer, &kargs, 0, sizeof(kargs)));

  // ---- Run kernel ----
  RT_CHECK(vx_start(device, krnl_buffer, args_buffer));

  int wait_ret = vx_ready_wait(device, VX_MAX_TIMEOUT);
  if (wait_ret != 0) {
    std::cerr << "vx_ready_wait failed: ret=" << wait_ret << std::endl;
    vx_copy_from_dev(&kargs, args_buffer, 0, sizeof(kargs));
    std::cerr << "Kernel status: " << kargs.status << std::endl;
    cleanup();
    return -1;
  }

  RT_CHECK(vx_copy_from_dev(&kargs, args_buffer, 0, sizeof(kargs)));

  if (kargs.status != STATUS_OK) {
    std::cout << "Kernel failed: status=" << kargs.status << std::endl;
    cleanup();
    return -1;
  }

  // ---- Verify output ----
  int errors = verify_results_tiled(C_buffer, h_ref_out_fp16);

  cleanup();

  if (errors != 0) {
    std::cout << "FAILED: errors=" << errors << std::endl;
    return -1;
  }

  std::cout << "PASSED" << std::endl;
  return 0;
}
