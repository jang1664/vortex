#include <iostream>
#include <unistd.h>
#include <getopt.h>
#include <string.h>
#include <vector>
#include <cmath>
#include <algorithm>
#include <limits>
#include <sstream>
#include <vortex.h>
#include "common.h"
#include "../fpint_gemm_ffn_hw/test_vectors.h"
#include "layout.h"

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

static uint32_t M = 2;        // user-requested (real) M
static uint32_t M_pad = 0;    // padded to multiple of 8 (set after parse_args)
static uint32_t N = 32;
static uint32_t K = 128;
static uint32_t N_logical = 32;
static uint32_t K_logical = 128;
static uint32_t QBLK = 32;
static uint32_t WTRANS = 0;
static uint32_t QDIR = 0;
static uint32_t REPS = 1;
static bool POWER_MODE = false;
static bool TAGGED_VECTORS = false;
static uint32_t TARGET_M = 0, TARGET_N = 0, TARGET_K = 0;
static uint32_t M_START = 0, N_START = 0;
static std::vector<uint32_t> TARGET_K_LIST, TARGET_N_LIST;
// Poll-only baseline mode: when > 0, kernel does N MMIO reads instead of GEMM.
// Used to isolate Vortex-core polling power from HW-GEMM power.
static uint32_t POLL_ONLY_ITERS = 0;
static constexpr uint32_t POLL_ONLY_QDIR_SENTINEL = 0xDEADu;

static vx_device_h device = nullptr;
static vx_buffer_h krnl_buffer = nullptr;
static vx_buffer_h args_buffer = nullptr;

static vx_buffer_h A_buffer = nullptr;
static vx_buffer_h W_int4_buffer = nullptr;
static vx_buffer_h scales_buffer = nullptr;
static vx_buffer_h zeros_buffer = nullptr;
static vx_buffer_h C_buffer = nullptr;

// Relative error for nonzero references; absolute error when the reference is zero.
static constexpr float FP16_TOL = 0.001f;

// Tile constants
static constexpr uint32_t DMA_MT     = GEMM_MT;      // 128
static constexpr uint32_t DMA_NT     = GEMM_NT;      // 128 (full N-tile for TMEM sizing)
static constexpr uint32_t DMA_KT     = GEMM_KT;      // 128
static constexpr uint32_t DMA_MXU_KT = GEMM_MXU_KT;
static constexpr uint32_t DMA_MXU_NT = GEMM_MXU_NT;
static constexpr uint32_t DMA_MXU_COL_TILE = GEMM_MXU_COL_TILE;

static constexpr uint64_t TMEM_LAYOUT_ALIGN_BYTES = 512;
static constexpr uint64_t DRAM_ALIGN_BYTES = 512;

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
  std::cout << "Usage: [-m M] [-n N] [-k K] [-q QBLK] [-t WTRANS] [-d QDIR]" << std::endl;
  std::cout << "       [-r REPS] [-p (power-mode: skip reference & verify)]" << std::endl;
  std::cout << "       [--pol POLL_ITERS] (poll-only baseline mode; implies -p)" << std::endl;
  std::cout << "       [--tagged] (directed A/W address-identity vectors)" << std::endl;
  std::cout << "       [--target-m M] [--target-n N] [--target-k K]" << std::endl;
  std::cout << "       [--m-start M] [--n-start N] (DMA-tile-aligned region origin)" << std::endl;
  std::cout << "       [--target-k-list K1,K2,... | --target-n-list N1,N2,...]" << std::endl;
  std::cout << "         Sequence jobs reuse the same original packed input buffers." << std::endl;
  std::cout << "       [-h]" << std::endl;
}

// Long-option-only flag value (out of ASCII range so it doesn't collide with short opts).
static constexpr int OPT_POL = 0x100;
static constexpr int OPT_TAGGED = 0x101;
enum { OPT_TM = 0x102, OPT_TN, OPT_TK, OPT_MS, OPT_NS, OPT_K_LIST, OPT_N_LIST };

static uint32_t parse_extent(const char* text, bool allow_zero = false) {
  char* end = nullptr;
  const unsigned long value = strtoul(text, &end, 10);
  if (!*text || *text == '-' || *end || value > UINT32_MAX || (!allow_zero && !value)) {
    std::cerr << "Invalid region extent: " << text << std::endl;
    exit(1);
  }
  return uint32_t(value);
}

static std::vector<uint32_t> parse_extents(const char* text) {
  std::vector<uint32_t> values;
  std::stringstream stream(text);
  std::string item;
  while (std::getline(stream, item, ',')) values.push_back(parse_extent(item.c_str()));
  if (values.empty() || !*text || text[strlen(text) - 1] == ',') {
    std::cerr << "Empty extent in sequence" << std::endl;
    exit(1);
  }
  return values;
}

static struct option long_options[] = {
  {"pol", required_argument, nullptr, OPT_POL},
  {"tagged", no_argument, nullptr, OPT_TAGGED},
  {"target-m", required_argument, nullptr, OPT_TM},
  {"target-n", required_argument, nullptr, OPT_TN},
  {"target-k", required_argument, nullptr, OPT_TK},
  {"m-start", required_argument, nullptr, OPT_MS},
  {"n-start", required_argument, nullptr, OPT_NS},
  {"target-k-list", required_argument, nullptr, OPT_K_LIST},
  {"target-n-list", required_argument, nullptr, OPT_N_LIST},
  {nullptr, 0, nullptr, 0},
};

static void parse_args(int argc, char **argv) {
  int c;
  int option_index = 0;
  while ((c = getopt_long(argc, argv, "m:n:k:q:t:d:r:ph", long_options, &option_index)) != -1) {
    switch (c) {
    case 'm': M = atoi(optarg); break;
    case 'n': N = atoi(optarg); break;
    case 'k': K = atoi(optarg); break;
    case 'q': QBLK = atoi(optarg); break;
    case 't': WTRANS = atoi(optarg); break;
    case 'd': QDIR = atoi(optarg); break;
    case 'r': REPS = atoi(optarg); break;
    case 'p': POWER_MODE = true; break;
    case OPT_TAGGED: TAGGED_VECTORS = true; break;
    case OPT_TM: TARGET_M = parse_extent(optarg); break;
    case OPT_TN: TARGET_N = parse_extent(optarg); break;
    case OPT_TK: TARGET_K = parse_extent(optarg); break;
    case OPT_MS: M_START = parse_extent(optarg, true); break;
    case OPT_NS: N_START = parse_extent(optarg, true); break;
    case OPT_K_LIST: TARGET_K_LIST = parse_extents(optarg); break;
    case OPT_N_LIST: TARGET_N_LIST = parse_extents(optarg); break;
    case OPT_POL:
      POLL_ONLY_ITERS = static_cast<uint32_t>(strtoul(optarg, nullptr, 0));
      POWER_MODE = true;  // poll-only is meaningless with verify; skip ref/verify
      break;
    case 'h': show_usage(); exit(0); break;
    default: show_usage(); exit(-1);
    }
  }
}

// ============================================================================
// FP16 conversion utilities
// ============================================================================

// IEEE 754 FP32 -> FP16 with round-to-nearest-even, matching HW converter.
static uint16_t float_to_fp16(float f) {
  union { float f; uint32_t i; } u = {f};
  uint32_t x       = u.i;
  uint16_t sign    = uint16_t((x >> 16) & 0x8000u);
  int32_t  exp32   = int32_t((x >> 23) & 0xFFu);
  uint32_t mant32  = x & 0x7FFFFFu;

  // NaN / Inf
  if (exp32 == 0xFF) {
    return sign | (mant32 ? 0x7E00u : 0x7C00u);
  }
  // FP32 zero / subnormal -> FP16 zero
  if (exp32 == 0) return sign;

  int32_t exp_f16 = exp32 - 127 + 15;

  // Overflow -> inf
  if (exp_f16 >= 31) return sign | 0x7C00u;

  // Normal FP16 (exp_f16 in [1, 30])
  if (exp_f16 >= 1) {
    uint32_t mant_top   = mant32 >> 13;        // top 10 bits
    uint32_t round_bits = mant32 & 0x1FFFu;    // low 13 bits (guard+round+sticky)
    // RNE: round up if > 0.5 ulp, or exactly 0.5 ulp with odd LSB.
    if (round_bits > 0x1000u ||
        (round_bits == 0x1000u && (mant_top & 1u))) {
      mant_top += 1;
      if (mant_top == 0x400u) {        // mantissa overflow -> bump exponent
        mant_top = 0;
        exp_f16 += 1;
        if (exp_f16 >= 31) return sign | 0x7C00u;
      }
    }
    return sign | uint16_t(exp_f16 << 10) | uint16_t(mant_top);
  }

  // Subnormal FP16 (exp_f16 in [-10, 0]). Outside this range -> underflow to 0.
  if (exp_f16 < -10) return sign;

  uint32_t m24         = mant32 | 0x800000u;             // prepend implicit 1
  int32_t  shift       = 14 - exp_f16;                    // >= 14, <= 24
  uint32_t round_mask  = (1u << shift) - 1u;
  uint32_t half        = 1u << (shift - 1);
  uint32_t round_bits  = m24 & round_mask;
  uint32_t mant10      = m24 >> shift;
  if (round_bits > half ||
      (round_bits == half && (mant10 & 1u))) {
    mant10 += 1;
    if (mant10 == 0x400u) {            // rounds up to smallest normal
      return sign | (1u << 10);
    }
  }
  return sign | uint16_t(mant10);
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

// QDIR_ROW scales the FP16 input in the GEMM input pipeline before the dot
// product.  Both operands are FP16, so their product is exact in FP32; the
// conversion below applies the same round-to-nearest-even FP16 boundary as
// the RTL multiplier before the value reaches the accumulator.
static float fp16_mul_rne(float lhs, float rhs) {
  return fp16_to_float(float_to_fp16(lhs * rhs));
}

static uint8_t pack_int4_pair(int8_t lo, int8_t hi) {
  return uint8_t((uint8_t(hi) & 0x0F) << 4) | uint8_t(lo & 0x0F);
}

// ============================================================================
// Shared corrected logical vectors and backend-specific weight decoding
// ============================================================================

static void convert_weight_tiled(const std::vector<int8_t>& h_W_raw,
                                 std::vector<uint8_t>& tiled);

// Random access decoder independent of the sequential packing loop below.
static int8_t tiled_weight_at(const std::vector<uint8_t>& packed,
                              uint32_t k, uint32_t n) {
  const uint32_t kt = k / DMA_KT;
  const uint32_t ck = std::min(K - kt * DMA_KT, DMA_KT);
  const uint32_t kb = (k % DMA_KT) / DMA_MXU_KT;
  const uint32_t nt = n / DMA_MXU_NT;
  const size_t segment = DMA_MXU_KT * DMA_MXU_NT / 2;
  const size_t base = size_t(kt) * DMA_KT * N / 2
                    + (size_t(nt) * (ck / DMA_MXU_KT) + kb) * segment;
  const uint32_t local_k = k % DMA_MXU_KT;
  const uint32_t local_n = n % DMA_MXU_NT;
  const size_t index = base + (WTRANS ? local_n * (DMA_MXU_KT / 2) + local_k / 2
                                      : local_k * (DMA_MXU_NT / 2) + local_n / 2);
  return fpint_gemm_test::unpack_int4(packed.at(index), WTRANS ? local_k : local_n);
}

static void build_test_vectors(std::vector<uint16_t>& h_A,
                               std::vector<int8_t>& h_W_raw,
                               std::vector<uint16_t>& h_scales,
                               std::vector<int16_t>& h_zeros,
                               std::vector<uint16_t>& h_ref_out_fp16,
                               bool compute_reference = true,
                               uint32_t generation = 0) {
  fpint_gemm_test::initialize(M, K, N, K_logical, N_logical, QBLK, QDIR,
      generation, TAGGED_VECTORS, h_A, h_W_raw, h_scales, h_zeros, float_to_fp16);
  h_ref_out_fp16.assign(M * N, 0);
  if (compute_reference) {
    std::vector<uint8_t> packed;
    convert_weight_tiled(h_W_raw, packed);
    auto weight = [&](uint32_t k, uint32_t n) { return tiled_weight_at(packed, k, n); };
    fpint_gemm_test::reference(M, K, N, std::min(K_logical, TARGET_K), N_logical, QBLK, QDIR,
        h_A, h_scales, h_zeros, weight, fp16_to_float, float_to_fp16, h_ref_out_fp16);
  }
}

// ============================================================================
// Tiled DRAM data conversion (matching tb_VX_gemm_node_improve layout)
// ============================================================================

// Input tiled: reserve an 8-row-aligned slot for each (mt, kt) tile so the next
// tile address stays aligned, but store only real M rows inside that slot.
static void convert_input_tiled(const std::vector<uint16_t>& h_A,
                                std::vector<uint8_t>& tiled) {
  uint32_t m_tiles  = (M + DMA_MT - 1) / DMA_MT;
  uint32_t k_tiles  = (K + DMA_KT - 1) / DMA_KT;

  // Pre-compute total reserved size. Padding exists only at the end of each
  // (mt, kt) slot and safely covers the final 64-byte external DMA rounding.
  uint64_t total = 0;
  for (uint32_t mt = 0; mt < m_tiles; mt++) {
    uint32_t cur_m = ((M - mt * DMA_MT) < DMA_MT) ? (M - mt * DMA_MT) : DMA_MT;
    for (uint32_t kt = 0; kt < k_tiles; kt++) {
      uint32_t cur_k = ((K - kt * DMA_KT) < DMA_KT) ? (K - kt * DMA_KT) : DMA_KT;
      const auto bytes = fpint_gemm_layout::input_slot_bytes(cur_m, cur_k);
      assert(bytes.transfer <= bytes.reserved);
      total = fpint_gemm_layout::checked_add(total, bytes.reserved);
    }
  }
  tiled.assign(fpint_gemm_layout::to_size(total), 0);

  size_t slot_off = 0;
  for (uint32_t mt = 0; mt < m_tiles; mt++) {
    uint32_t cur_m = ((M - mt * DMA_MT) < DMA_MT) ? (M - mt * DMA_MT) : DMA_MT;
    for (uint32_t kt = 0; kt < k_tiles; kt++) {
      uint32_t cur_k = ((K - kt * DMA_KT) < DMA_KT) ? (K - kt * DMA_KT) : DMA_KT;
      const auto bytes = fpint_gemm_layout::input_slot_bytes(cur_m, cur_k);
      assert(bytes.transfer <= bytes.reserved);
      uint32_t k_micros = cur_k / DMA_MXU_KT;
      size_t idx = slot_off;
      for (uint32_t kb = 0; kb < k_micros; kb++) {
        for (uint32_t m = 0; m < cur_m; m++) {
          uint32_t gm = mt * DMA_MT + m;
          for (uint32_t k = 0; k < DMA_MXU_KT; k++) {
            uint32_t gk = kt * DMA_KT + kb * DMA_MXU_KT + k;
            uint16_t val = h_A[gm * K + gk];
            tiled[idx++] = val & 0xFF;
            tiled[idx++] = (val >> 8) & 0xFF;
          }
        }
      }
      slot_off += fpint_gemm_layout::to_size(bytes.reserved);
    }
  }
}

// Weight tiled: per (kt, nt) tile, kb_per_kt contiguous micro-tiles of packed int4
static void convert_weight_tiled(const std::vector<int8_t>& h_W_raw,
                                 std::vector<uint8_t>& tiled) {
  uint32_t k_tiles   = (K + DMA_KT - 1) / DMA_KT;
  uint32_t n_tiles   = N / DMA_MXU_NT;

  const auto microtile =
      fpint_gemm_layout::weight_microtile_bytes(DMA_MXU_KT, DMA_MXU_NT);
  assert(microtile.transfer <= microtile.reserved);
  const uint64_t seg = microtile.payload;
  uint64_t total = 0;
  for (uint32_t kt = 0; kt < k_tiles; kt++) {
    uint32_t ck = ((K - kt * DMA_KT) < DMA_KT) ? (K - kt * DMA_KT) : DMA_KT;
    const uint64_t tile_bytes = fpint_gemm_layout::checked_mul3(
        n_tiles, ck / DMA_MXU_KT, seg);
    total = fpint_gemm_layout::checked_add(total, tile_bytes);
  }
  tiled.resize(fpint_gemm_layout::to_size(total));
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

// Scale/zero-point tiled: (kt, nt_dma) slot-based layout.
//
// Each (kt, nt_dma) reserves a 512B-aligned slot in DRAM sized to
// align_up(actual_data_bytes, 512). This guarantees the channel-slot invariant
// in VX_gemm_tmem_dma_ctrl (src[8:6] == dst[8:6]) while avoiding the full-tile
// padding overhead. Actual data occupies the slot start; remainder is zero.
//
// QCOL slot body: [nb=0..cur_nb-1][groups_per_kt][MXU_NT] fp16
// QROW slot body: [nb=0..cur_nb-1][KT][ng_per_nt] fp16
static size_t scale_slot_bytes(uint32_t ck, uint32_t cn) {
  const auto bytes = fpint_gemm_layout::qparam_slot_bytes(
      ck, cn, DMA_MXU_NT, QBLK, QDIR);
  assert(bytes.transfer <= bytes.reserved);
  return fpint_gemm_layout::to_size(bytes.reserved);
}

template <typename T>
static void fill_scale_zp_slot(const std::vector<T>& h_src,
                               std::vector<uint8_t>& tiled,
                               size_t slot_off, uint32_t kt,
                               uint32_t nt_dma, uint32_t cur_k,
                               uint32_t cur_nb_per_nt) {
  uint32_t ng_total            = (N + QBLK - 1) / QBLK;
  uint32_t full_groups_per_kt  = DMA_KT / QBLK;
  uint32_t ng_per_mxu_nt =
      fpint_gemm_layout::qrow_groups_per_mxu_nt(DMA_MXU_NT, QBLK);
  uint32_t mxu_per_dma_nt      = DMA_NT / DMA_MXU_NT;  // NB_PER_NT

  size_t idx = slot_off;
  for (uint32_t nb = 0; nb < cur_nb_per_nt; nb++) {
    uint32_t global_nt_mxu = nt_dma * mxu_per_dma_nt + nb;
    if (QDIR == 0) {
      uint32_t cur_groups = fpint_gemm_layout::qcol_groups(cur_k, QBLK);
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

// Compute total scale/zp DRAM bytes across all (kt, nt_dma) slots.
static size_t scale_total_bytes() {
  uint32_t k_tiles     = (K + DMA_KT - 1) / DMA_KT;
  uint32_t n_tiles_dma = (N + DMA_NT - 1) / DMA_NT;
  uint64_t total = 0;
  for (uint32_t kt = 0; kt < k_tiles; kt++) {
    uint32_t cur_k = ((K - kt * DMA_KT) < DMA_KT) ? (K - kt * DMA_KT) : DMA_KT;
    for (uint32_t nt_dma = 0; nt_dma < n_tiles_dma; nt_dma++) {
      uint32_t cur_n = ((N - nt_dma * DMA_NT) < DMA_NT) ? (N - nt_dma * DMA_NT) : DMA_NT;
      total = fpint_gemm_layout::checked_add(
          total, scale_slot_bytes(cur_k, cur_n));
    }
  }
  return fpint_gemm_layout::to_size(total);
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
// Tiled output verification (matching tb check_output_tiled layout)
// Output tiled: [mt][nt_dma][nt_micro][cur_m][MXU_NT] fp16.
// Padding is reserved only at the end of each (mt, nt_dma) slot, as for A.
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

  // Aggregate reservation is unchanged; padding now follows each DMA tile.
  uint64_t total_bytes_u64 = 0;
  for (uint32_t mt = 0; mt < m_tiles; mt++) {
    uint32_t cur_m = ((M - mt * DMA_MT) < DMA_MT) ? (M - mt * DMA_MT) : DMA_MT;
    const auto bytes = fpint_gemm_layout::output_slot_bytes(cur_m, N);
    assert(bytes.transfer <= bytes.reserved);
    total_bytes_u64 = fpint_gemm_layout::checked_add(
        total_bytes_u64,
        bytes.reserved);
  }
  const size_t total_bytes = fpint_gemm_layout::to_size(total_bytes_u64);

  std::vector<uint8_t> raw(total_bytes);
  RT_CHECK(vx_copy_from_dev(raw.data(), out_buffer, 0, total_bytes));

  int errors = 0;
  for (uint32_t mt = 0; mt < m_tiles; mt++) {
    uint32_t cur_m = ((M - mt * DMA_MT) < DMA_MT) ? (M - mt * DMA_MT) : DMA_MT;
    const auto slot = fpint_gemm_layout::output_slot_bytes(cur_m, DMA_NT);
    const uint32_t micros_per_tile = DMA_NT / DMA_MXU_NT;
    const size_t mt_base = size_t(mt) * DMA_MT * N * 2;
    for (uint32_t nt = 0; nt < n_tiles; nt++) {
      size_t idx = mt_base + (nt / micros_per_tile) * slot.reserved
                 + size_t(nt % micros_per_tile) * cur_m * DMA_MXU_NT * 2;
      for (uint32_t m = 0; m < cur_m; m++) {
        uint32_t gm = mt * DMA_MT + m;
        for (uint32_t n = 0; n < DMA_MXU_NT; n++) {
          uint32_t gn = nt * DMA_MXU_NT + n;
          uint16_t got = uint16_t(raw[idx]) | (uint16_t(raw[idx + 1]) << 8);
          idx += 2;

          // N is rounded to the MXU width; skip only non-logical columns.
          if (gn >= N_logical) continue;

          const bool in_region = gm >= M_START && gm - M_START < TARGET_M
                              && gn >= N_START && gn - N_START < TARGET_N;
          if (!in_region) {
            if (got != 0xffffu) {
              if (errors < 10) printf("Outside-region overwrite[m=%u,n=%u]: 0x%04x\n", gm, gn, got);
              ++errors;
            }
            continue;
          }

          uint16_t exp = ref[gm * N + gn];
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
// TMEM layout computation (tensor memory offsets starting from 0)
// ============================================================================

static bool compute_tmem_layout(kernel_arg_t& kargs, uint64_t tensor_mem_size) {
  uint32_t groups_tile = DMA_KT / QBLK;
  uint32_t nb_per_nt = DMA_NT / DMA_MXU_NT;
  uint32_t ng_per_mxu_nt =
      fpint_gemm_layout::qrow_groups_per_mxu_nt(DMA_MXU_NT, QBLK);

  uint64_t tmem_ibuf_bytes =
      fpint_gemm_layout::checked_mul3(DMA_MT, DMA_KT, 2);
  uint64_t tmem_wbuf_bytes = fpint_gemm_layout::checked_mul(
      DMA_KT, (DMA_NT + 1) / 2);
  uint64_t tmem_scbuf_bytes = (QDIR == 0)
      ? fpint_gemm_layout::checked_mul3(groups_tile, DMA_NT, 2)
      : fpint_gemm_layout::checked_mul3(
            fpint_gemm_layout::checked_mul(DMA_KT, nb_per_nt),
            ng_per_mxu_nt, 2);
  uint64_t tmem_zpbuf_bytes = tmem_scbuf_bytes;
  uint64_t tmem_obuf_bytes =
      fpint_gemm_layout::checked_mul3(DMA_MT, DMA_NT, 2);

  uint64_t cur = 0;

  auto alloc = [&](uint64_t bytes, uint64_t& out_base) -> bool {
    cur = fpint_gemm_layout::align_up(cur, TMEM_LAYOUT_ALIGN_BYTES);
    if (cur > tensor_mem_size || bytes > (tensor_mem_size - cur)) return false;
    out_base = cur;
    cur = fpint_gemm_layout::checked_add(
        cur, fpint_gemm_layout::align_up(bytes, TMEM_LAYOUT_ALIGN_BYTES));
    return true;
  };

  // Double-buffered: buf0, buf1 consecutive for each category.
  // scbuf_bytes == zpbuf_bytes, so zpbuf[i] - scbuf[i] is constant = 2 * scbuf_slot.
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
  parse_args(argc, argv);
  if (REPS == 0) {
    std::cerr << "REPS must be > 0" << std::endl;
    return -1;
  }

  // Validate constraints
  if ((QBLK != 16 && QBLK != 32 && QBLK != 64 && QBLK != 128)
      || QBLK < (QDIR ? DMA_MXU_NT : DMA_MXU_KT) || WTRANS > 1 || QDIR > 1) {
    std::cerr << "Invalid parameters: QBLK=" << QBLK
              << " WTRANS=" << WTRANS << " QDIR=" << QDIR << std::endl;
    return -1;
  }
  if (M == 0 || N == 0 || K == 0) {
    std::cerr << "M, N, and K must be > 0" << std::endl;
    return -1;
  }
  N_logical = N;
  K_logical = K;
  if (N_logical > std::numeric_limits<uint32_t>::max() - (DMA_MXU_NT - 1) ||
      K_logical > std::numeric_limits<uint32_t>::max() - (DMA_MXU_KT - 1)) {
    std::cerr << "N/K execution padding exceeds the 32-bit command ABI" << std::endl;
    return -1;
  }
  N = uint32_t(fpint_gemm_layout::align_up(N_logical, DMA_MXU_NT));
  K = uint32_t(fpint_gemm_layout::align_up(K_logical, DMA_MXU_KT));
  const bool sequence = !TARGET_K_LIST.empty() || !TARGET_N_LIST.empty();
  if ((!TARGET_K_LIST.empty() && !TARGET_N_LIST.empty()) || (sequence && REPS != 1)
      || (sequence && POWER_MODE) || M_START >= M || N_START >= N
      || M_START % DMA_MT || N_START % DMA_NT) {
    std::cerr << "Invalid sequence or unaligned/out-of-range region start" << std::endl;
    return 1;
  }
  TARGET_M = TARGET_M ? TARGET_M : M - M_START;
  TARGET_N = TARGET_N ? TARGET_N : N - N_START;
  TARGET_K = TARGET_K ? TARGET_K : K;
  if (TARGET_M > M - M_START || TARGET_N > N - N_START || TARGET_K > K
      || TARGET_N % DMA_MXU_NT || TARGET_K % DMA_MXU_KT) {
    std::cerr << "Target must fit original storage; N/K must align to MXU" << std::endl;
    return 1;
  }
  for (auto value : TARGET_K_LIST) {
    if (value > K || value % DMA_MXU_KT) return 1;
  }
  for (auto value : TARGET_N_LIST) {
    if (value > N - N_START || value % DMA_MXU_NT) return 1;
  }
  if (!TARGET_K_LIST.empty()) { TARGET_K = TARGET_K_LIST.front(); REPS = TARGET_K_LIST.size(); }
  if (!TARGET_N_LIST.empty()) { TARGET_N = TARGET_N_LIST.front(); REPS = TARGET_N_LIST.size(); }
  // Pad M up to multiple of 8 for DMA stripe alignment (NUM_DMA_CHANNELS=8).
  // DRAM slots reserve M_pad rows for address alignment; compute/DMA use real M.
  M_pad = (M + 7u) & ~7u;
  if (QDIR == 0 && (DMA_KT % QBLK != 0)) {
    std::cerr << "QCOL mode: DMA_KT=" << DMA_KT << " must be divisible by QBLK=" << QBLK << std::endl;
    return -1;
  }

  std::cout << "Core-level GEMM instruction stream test"
            << (POWER_MODE ? " [POWER MODE: no reference, no verify]" : "")
            << std::endl;
  std::cout << "M=" << M << " (padded to " << M_pad << ")"
            << ", N=" << N_logical << " (execution " << N << ")"
            << ", K=" << K_logical << " (execution " << K << ")"
            << ", QBLK=" << QBLK << ", WTRANS=" << WTRANS
            << ", QDIR=" << QDIR << ", REPS=" << REPS
            << ", vectors=" << (TAGGED_VECTORS ? "tagged" : "corrected-default") << std::endl;
  std::cout << "Active MXU profile: MXU_ROW=" << DMA_MXU_KT
            << " MXU_COL=" << DMA_MXU_NT
            << " MXU_COL_TILE=" << DMA_MXU_COL_TILE << std::endl;
  std::cout << "Tile: MT=" << DMA_MT << " KT=" << DMA_KT
            << " MXU_KT=" << DMA_MXU_KT << " MXU_NT=" << DMA_MXU_NT << std::endl;

  RT_CHECK(vx_dev_open(&device));

  uint64_t num_cores = 0, num_warps = 0, num_threads = 0;
  uint64_t tensor_mem_size = 0;
  RT_CHECK(vx_dev_caps(device, VX_CAPS_NUM_CORES, &num_cores));
  RT_CHECK(vx_dev_caps(device, VX_CAPS_NUM_WARPS, &num_warps));
  RT_CHECK(vx_dev_caps(device, VX_CAPS_NUM_THREADS, &num_threads));
  // RT_CHECK(vx_dev_caps(device, VX_CAPS_LOCAL_MEM_SIZE, &tensor_mem_size));
  std::cout << "Device: cores=" << num_cores
            << ", warps=" << num_warps
            << ", threads=" << num_threads << std::endl;
  
  tensor_mem_size = TMEM_BANK_SIZE * NUM_TMEM_BANKS;

  // ---- Generate test vectors (row-major) ----
  std::vector<uint16_t> h_A;
  std::vector<int8_t> h_W_raw;
  std::vector<uint16_t> h_scales;
  std::vector<int16_t> h_zeros;
  std::vector<uint16_t> h_ref_out_fp16;

  build_test_vectors(h_A, h_W_raw, h_scales, h_zeros, h_ref_out_fp16,
                     /*compute_reference=*/!POWER_MODE);

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
    uint32_t groups_per_kt = fpint_gemm_layout::qcol_groups(first_ck, QBLK);
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
      printf("DEBUG weight nt0==nt1: %s\n", w_same ? "YES" : "NO");
    }

    // Compare first byte of nt=0 vs nt=1 scale tiles
    if (tiled_scale.size() >= 2 * skt) {
      printf("DEBUG scale nt=0 first 8B: ");
      for (int i = 0; i < 8; i++) printf("%02x ", tiled_scale[i]);
      printf("\nDEBUG scale nt=1 first 8B: ");
      for (int i = 0; i < 8; i++) printf("%02x ", tiled_scale[skt + i]);
      printf("\n");
      bool s_same = (memcmp(tiled_scale.data(), tiled_scale.data() + skt, skt) == 0);
      printf("DEBUG scale nt0==nt1: %s\n", s_same ? "YES" : "NO");
    }

    // Also verify: host-side reference at n=0 vs n=32 (only when reference exists)
    if (!POWER_MODE) {
      printf("DEBUG ref_out[0,0]=0x%04x (%f)\n",
             h_ref_out_fp16[0], fp16_to_float(h_ref_out_fp16[0]));
      printf("DEBUG ref_out[0,%u]=0x%04x (%f)\n",
             DMA_MXU_NT, h_ref_out_fp16[DMA_MXU_NT],
             fp16_to_float(h_ref_out_fp16[DMA_MXU_NT]));
    }
  }

  // Reserve padded DMA tiles, aggregated over N for each M tile.
  uint32_t m_tiles = (M + DMA_MT - 1) / DMA_MT;
  uint64_t out_total_bytes_u64 = 0;
  for (uint32_t mt = 0; mt < m_tiles; mt++) {
    uint32_t cur_m = ((M - mt * DMA_MT) < DMA_MT) ? (M - mt * DMA_MT) : DMA_MT;
    const auto bytes = fpint_gemm_layout::output_slot_bytes(cur_m, N);
    assert(bytes.transfer <= bytes.reserved);
    out_total_bytes_u64 = fpint_gemm_layout::checked_add(
        out_total_bytes_u64,
        bytes.reserved);
  }
  const size_t out_total_bytes =
      fpint_gemm_layout::to_size(out_total_bytes_u64);

  // ---- Allocate device buffers ----
  RT_CHECK(vx_mem_alloc_aligned(device, tiled_input.size(),  DRAM_ALIGN_BYTES, VX_MEM_READ, &A_buffer));
  RT_CHECK(vx_mem_alloc_aligned(device, tiled_weight.size(), DRAM_ALIGN_BYTES, VX_MEM_READ, &W_int4_buffer));
  RT_CHECK(vx_mem_alloc_aligned(device, tiled_scale.size(),  DRAM_ALIGN_BYTES, VX_MEM_READ, &scales_buffer));
  RT_CHECK(vx_mem_alloc_aligned(device, tiled_zp.size(),     DRAM_ALIGN_BYTES, VX_MEM_READ, &zeros_buffer));
  RT_CHECK(vx_mem_alloc_aligned(device, out_total_bytes,     DRAM_ALIGN_BYTES, VX_MEM_READ_WRITE, &C_buffer));

  // ---- Upload kernel ----
  RT_CHECK(vx_upload_kernel_file(device, kernel_file, &krnl_buffer));

  // ---- Set up kernel arguments ----
  kernel_arg_t kargs = {};

  RT_CHECK(vx_mem_address(A_buffer,       &kargs.dram_in_base));
  RT_CHECK(vx_mem_address(W_int4_buffer,  &kargs.dram_w_base));
  RT_CHECK(vx_mem_address(scales_buffer,  &kargs.dram_sc_base));
  RT_CHECK(vx_mem_address(zeros_buffer,   &kargs.dram_zp_base));
  RT_CHECK(vx_mem_address(C_buffer,       &kargs.dram_out_base));

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
  kargs.target_M = TARGET_M;
  kargs.target_N = TARGET_N;
  kargs.target_K = TARGET_K;
  kargs.m_start = M_START;
  kargs.n_start = N_START;
  kargs.status = STATUS_INIT;

  std::cout << "TMEM layout (double-buffered):" << std::hex
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
  std::cout << "Starting kernel execution (reps=" << REPS
            << (POWER_MODE ? ", POWER MODE: no reference, no verify" : "")
            << (POLL_ONLY_ITERS ? " [POLL-ONLY MODE]" : "")
            << ", poll_iters=" << POLL_ONLY_ITERS << ")" << std::endl;
  for (uint32_t rep = 0; rep < REPS; ++rep) {
    if (rep != 0 && !sequence) {
      build_test_vectors(h_A, h_W_raw, h_scales, h_zeros, h_ref_out_fp16,
                         !POWER_MODE, rep);
      convert_input_tiled(h_A, tiled_input);
      convert_weight_tiled(h_W_raw, tiled_weight);
      convert_scale_tiled(h_scales, tiled_scale);
      convert_zp_tiled(h_zeros, tiled_zp);
    }
    if (!TARGET_K_LIST.empty()) TARGET_K = TARGET_K_LIST[rep];
    if (!TARGET_N_LIST.empty()) TARGET_N = TARGET_N_LIST[rep];
    kargs.target_K = TARGET_K;
    kargs.target_N = TARGET_N;
    if (sequence && rep != 0) {
      auto weight = [&](uint32_t k, uint32_t n) { return tiled_weight_at(tiled_weight, k, n); };
      fpint_gemm_test::reference(M, K, N, std::min(K_logical, TARGET_K), N_logical, QBLK, QDIR,
          h_A, h_scales, h_zeros, weight, fp16_to_float, float_to_fp16, h_ref_out_fp16);
    }
    if (!sequence || rep == 0) {
      RT_CHECK(vx_copy_to_dev(A_buffer, tiled_input.data(), 0, tiled_input.size()));
      RT_CHECK(vx_copy_to_dev(W_int4_buffer, tiled_weight.data(), 0, tiled_weight.size()));
      RT_CHECK(vx_copy_to_dev(scales_buffer, tiled_scale.data(), 0, tiled_scale.size()));
      RT_CHECK(vx_copy_to_dev(zeros_buffer, tiled_zp.data(), 0, tiled_zp.size()));
    }
    printf("GEMM region: orig=%ux%ux%u start=%u,%u target=%ux%ux%u inputs=%s\n",
           M, N, K, M_START, N_START, TARGET_M, TARGET_N, TARGET_K,
           sequence && rep ? "reused" : "uploaded");
    // Every FP16 lane is NaN, including reserved padding between output slots.
    const std::vector<uint8_t> poison_out(out_total_bytes, 0xffu);
    RT_CHECK(vx_copy_to_dev(C_buffer, poison_out.data(), 0, poison_out.size()));

    // Reset status before each launch so the kernel sees a fresh INIT.
    kargs.status = STATUS_INIT;
    if (POLL_ONLY_ITERS) {
      // Hijack kargs.QDIR (sentinel) + kargs.K (iteration count) so the
      // device kernel takes the polling-only path. TMEM layout already
      // computed remains valid; kernel ignores M/N/K in poll-only.
      kargs.QDIR = POLL_ONLY_QDIR_SENTINEL;
      kargs.K    = POLL_ONLY_ITERS;
    }
    printf("Init kernel args: status=%u, QDIR=%u, K=%u\n",
           kargs.status, kargs.QDIR, kargs.K);
    RT_CHECK(vx_copy_to_dev(args_buffer, &kargs, 0, sizeof(kargs)));

    printf("Launching kernel (rep=%u/%u)...\n", rep + 1, REPS);
    RT_CHECK(vx_start(device, krnl_buffer, args_buffer));

    printf("Waiting for kernel to complete (rep=%u/%u)...\n", rep + 1, REPS);
    int wait_ret = vx_ready_wait(device, VX_MAX_TIMEOUT);
    if (wait_ret != 0) {
      std::cerr << "vx_ready_wait failed at rep=" << rep
                << ": ret=" << wait_ret << std::endl;
      vx_copy_from_dev(&kargs, args_buffer, 0, sizeof(kargs));
      std::cerr << "Kernel status: " << kargs.status << std::endl;
      cleanup();
      return -1;
    }

    RT_CHECK(vx_copy_from_dev(&kargs, args_buffer, 0, sizeof(kargs)));

    if (kargs.status != STATUS_OK) {
      std::cout << "Kernel failed at rep=" << rep
                << ": status=" << kargs.status << std::endl;
      cleanup();
      return -1;
    }
    if (!POWER_MODE) {
      const int errors = verify_results_tiled(C_buffer, h_ref_out_fp16);
      if (errors != 0) {
        std::cerr << "FAILED: rep=" << rep << ", errors=" << errors << std::endl;
        cleanup();
        return -1;
      }
      std::cout << "Verified job " << rep + 1 << "/" << REPS << std::endl;
    }
  }
  if (POWER_MODE)
    std::cout << "Power mode: skipping numerical verification" << std::endl;
  cleanup();

  std::cout << "PASSED" << std::endl;
  return 0;
}
