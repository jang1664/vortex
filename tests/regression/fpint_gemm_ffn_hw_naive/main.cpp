#include <iostream>
#include <unistd.h>
#include <getopt.h>
#include <string.h>
#include <vector>
#include <cmath>
#include <algorithm>
#include <cerrno>
#include <cctype>
#include <limits>
#include <vortex.h>
#include "common.h"
#include "../fpint_gemm_ffn_hw/test_vectors.h"
#include "fpfp_test_vectors.h"

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
static uint32_t K = 32;
static uint32_t QBLK = 32;
static uint32_t WTRANS = 0;
static uint32_t QDIR = 0;
static uint32_t REPS = 1;
static bool POWER_MODE = false;
static bool TAGGED_VECTORS = false;
static bool SUBNORMAL_VECTORS = false;
#ifdef FPFP_GEMM_ONLY
static bool FP16_WEIGHTS = true;
#else
static bool FP16_WEIGHTS = false;
#endif
static bool ALTERNATE_FORMATS = false;
static bool QUEUED_FORMATS = false;
static uint32_t RANDOM_SEED = 1;
static std::vector<double> mathematical_reference;
static uint64_t LMEM_OFFSET_BYTES = 0;
// Poll-only baseline mode: when > 0, kernel does N MMIO reads instead of GEMM.
// Used to isolate Vortex-core polling power from HW-GEMM power.
static uint32_t POLL_ONLY_ITERS = 0;

static vx_device_h device = nullptr;
static vx_buffer_h krnl_buffer = nullptr;
static vx_buffer_h args_buffer = nullptr;

static vx_buffer_h A_buffer = nullptr;       // fp16 [M x K]
static vx_buffer_h W_int4_buffer = nullptr;  // packed int4 or row-major fp16 [K x N]
static vx_buffer_h scales_buffer = nullptr;  // fp16 [KG x N]
static vx_buffer_h zeros_buffer = nullptr;   // int16 [KG x N]
static vx_buffer_h C_buffer = nullptr;       // fp16 [M x N]

// Relative error for nonzero references; absolute error when the reference is zero.
static constexpr float FP16_TOL = 0.001f;

static constexpr uint64_t LMEM_LAYOUT_ALIGN_BYTES = 64;
static constexpr uint64_t LMEM_STACK_GUARD_BYTES = (1ull << STACK_LOG2_SIZE);
static constexpr uint64_t LMEM_BASE_ADDRESS = static_cast<uint64_t>(LMEM_BASE_ADDR);
static constexpr uint64_t DMA_MT = GEMM_FSM_MT;
static constexpr uint64_t DMA_NT = GEMM_FSM_NT;
static constexpr uint64_t DMA_KT = GEMM_FSM_KT;
static constexpr uint64_t OUTPUT_TILE_ELEMENTS = GEMM_HOST_OUTPUT_TILE_ELEMENTS;
#ifdef GEMM_NAIVE_FP16_ENABLE
static constexpr uint32_t FP16_ROW = FPFP_MXU_ROW;
#else
static constexpr uint32_t FP16_ROW = MXU_ROW; // FPFP dispatch is rejected below.
#endif

static constexpr uint64_t align_up_u64(uint64_t x, uint64_t a) {
  return (a == 0) ? x : ((x + a - 1) / a) * a;
}

static constexpr uint64_t align_down_u64(uint64_t x, uint64_t a) {
  return (a == 0) ? x : (x / a) * a;
}

static const char* status_to_str(uint32_t status) {
  switch (status) {
  case MMIO_STATUS_INIT: return "INIT";
  case MMIO_STATUS_OK: return "OK";
  case MMIO_STATUS_ALLOC_FAIL: return "ALLOC_FAIL";
  case MMIO_STATUS_WAIT_STUCK: return "WAIT_STUCK";
  case MMIO_STATUS_BAD_EID: return "BAD_EID";
  case MMIO_STATUS_BAD_FORMAT: return "BAD_FORMAT";
  default: return "UNKNOWN";
  }
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
#ifdef FPFP_GEMM_ONLY
  std::cout << "FP16 x FP16 naive GEMM: row-major A[M,K], B[K,N], C[M,N]" << std::endl;
  std::cout << "Usage: [-M M] [-K K] [-N N] [-r REPS] [--seed SEED]" << std::endl;
  std::cout << "       [--tagged] [--subnormal] [--lmem-offset BYTES] [-p] [-h]" << std::endl;
  std::cout << "       Lowercase -m/-k/-n are also accepted. FP32 accumulation, final FP16 output." << std::endl;
#else
  std::cout << "Usage: [-m M] [-n N] [-k K] [-q QBLK] [-t WTRANS] [-d QDIR]" << std::endl;
  std::cout << "       [-r REPS] [-p (power-mode: skip reference & verify)]" << std::endl;
  std::cout << "       [--pol POLL_ITERS] (poll-only baseline mode; implies -p)" << std::endl;
  std::cout << "       [--tagged] (directed A/W address-identity vectors)" << std::endl;
  std::cout << "       [--lmem-offset BYTES] (scratch placement offset; default 0)" << std::endl;
  std::cout << "       [--subnormal] (directed FP16 underflow vectors; bit-exact verify)" << std::endl;
  std::cout << "       [--fp16-weights] (FP16 x FP16, row-major B, no quantization)" << std::endl;
  std::cout << "       [--seed SEED] (FPFP random vectors; default 1)" << std::endl;
  std::cout << "       [--alternate-formats] (alternate INT4/FP16 between -r jobs; dual-format build)" << std::endl;
  std::cout << "       [--queued-formats] (queue FPFP/FPINT/FPFP within one kernel; dual-format build)" << std::endl;
  std::cout << "       [-h]" << std::endl;
#endif
}

// Long-option-only flag value (out of ASCII range so it doesn't collide with short opts).
static constexpr int OPT_POL = 0x100;
static constexpr int OPT_TAGGED = 0x101;
static constexpr int OPT_SUBNORMAL = 0x110;
static constexpr int OPT_LMEM_OFFSET = 0x102;
static constexpr int OPT_FP16_WEIGHTS = 0x111;
static constexpr int OPT_SEED = 0x112;
static constexpr int OPT_ALTERNATE_FORMATS = 0x113;
static constexpr int OPT_QUEUED_FORMATS = 0x114;

static struct option long_options[] = {
  {"pol", required_argument, nullptr, OPT_POL},
  {"tagged", no_argument, nullptr, OPT_TAGGED},
  {"subnormal", no_argument, nullptr, OPT_SUBNORMAL},
  {"lmem-offset", required_argument, nullptr, OPT_LMEM_OFFSET},
  {"fp16-weights", no_argument, nullptr, OPT_FP16_WEIGHTS},
  {"seed", required_argument, nullptr, OPT_SEED},
  {"alternate-formats", no_argument, nullptr, OPT_ALTERNATE_FORMATS},
  {"queued-formats", no_argument, nullptr, OPT_QUEUED_FORMATS},
  {nullptr, 0, nullptr, 0},
};

static void parse_args(int argc, char **argv) {
  int c;
  int option_index = 0;
  while ((c = getopt_long(argc, argv, "M:N:K:m:n:k:q:t:d:r:ph", long_options, &option_index)) != -1) {
    switch (c) {
    case 'M':
    case 'm': M = atoi(optarg); break;
    case 'N':
    case 'n': N = atoi(optarg); break;
    case 'K':
    case 'k': K = atoi(optarg); break;
    case 'q': QBLK = atoi(optarg); break;
    case 't': WTRANS = atoi(optarg); break;
    case 'd': QDIR = atoi(optarg); break;
    case 'r': REPS = atoi(optarg); break;
    case 'p': POWER_MODE = true; break;
    case OPT_TAGGED: TAGGED_VECTORS = true; break;
    case OPT_SUBNORMAL: SUBNORMAL_VECTORS = true; break;
    case OPT_FP16_WEIGHTS: FP16_WEIGHTS = true; break;
    case OPT_ALTERNATE_FORMATS: ALTERNATE_FORMATS = true; break;
    case OPT_QUEUED_FORMATS: QUEUED_FORMATS = true; FP16_WEIGHTS = true; break;
    case OPT_SEED: {
      char* end = nullptr;
      errno = 0;
      const unsigned long long value = strtoull(optarg, &end, 0);
      if (!std::isdigit(static_cast<unsigned char>(optarg[0]))
          || errno == ERANGE || end == optarg || *end != '\0'
          || value > std::numeric_limits<uint32_t>::max()) {
        std::cerr << "Invalid --seed: " << optarg << std::endl;
        exit(1);
      }
      RANDOM_SEED = static_cast<uint32_t>(value);
      break;
    }
    case OPT_LMEM_OFFSET: {
      char* end = nullptr;
      errno = 0;
      const unsigned long long value = strtoull(optarg, &end, 0);
      if (!std::isdigit(static_cast<unsigned char>(optarg[0]))
          || errno == ERANGE || end == optarg || *end != '\0'
          || value > std::numeric_limits<uint64_t>::max()) {
        std::cerr << "Invalid --lmem-offset: " << optarg << std::endl;
        exit(1);
      }
      LMEM_OFFSET_BYTES = static_cast<uint64_t>(value);
      break;
    }
    case OPT_POL:
      POLL_ONLY_ITERS = static_cast<uint32_t>(strtoul(optarg, nullptr, 0));
      POWER_MODE = true;  // poll-only is meaningless with verify; skip ref/verify
      break;
    case 'h': show_usage(); exit(0); break;
    default: show_usage(); exit(-1);
    }
  }
}

// IEEE 754 FP32 -> FP16 with round-to-nearest-even, matching HW converter (NRE).
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
  if (exp == 31) return mantissa ? NAN : (sign ? -INFINITY : INFINITY);

  uint32_t f = (sign << 31) | ((exp - 15 + 127) << 23) | (mantissa << 13);
  float out;
  __builtin_memcpy(&out, &f, sizeof(float));
  return out;
}

static uint8_t pack_int4_pair(int8_t lo, int8_t hi) {
  return uint8_t((uint8_t(hi) & 0x0F) << 4) | uint8_t(lo & 0x0F);
}

static void build_test_vectors(std::vector<uint16_t>& h_A,
                               std::vector<uint8_t>& h_W_int4,
                               std::vector<uint16_t>& h_scales,
                               std::vector<int16_t>& h_zeros,
                               std::vector<uint16_t>& h_ref_out_fp16,
                               bool compute_reference,
                               uint32_t generation = 0) {
  mathematical_reference.clear();
  if (FP16_WEIGHTS) {
    h_scales.clear();
    h_zeros.clear();
    fpfp_gemm_test::initialize(M, K, N, FP16_ROW, RANDOM_SEED, generation,
        TAGGED_VECTORS, SUBNORMAL_VECTORS, h_A, h_W_int4, h_ref_out_fp16,
        mathematical_reference, compute_reference, fp16_to_float, float_to_fp16);
    return;
  }
  std::vector<int8_t> raw_weight;
  fpint_gemm_test::initialize(M, K, N, K, N, QBLK, QDIR,
      generation, TAGGED_VECTORS, h_A, raw_weight, h_scales, h_zeros, float_to_fp16, SUBNORMAL_VECTORS);
  const uint32_t stride = WTRANS ? (K + 1) / 2 : (N + 1) / 2;
  h_W_int4.assign((WTRANS ? N : K) * stride, 0);
  for (uint32_t k = 0; k < K; ++k)
    for (uint32_t n = 0; n < N; ++n) {
      const uint32_t index = WTRANS ? n * stride + k / 2 : k * stride + n / 2;
      const uint32_t lane = WTRANS ? k : n;
      h_W_int4[index] |= (uint8_t(raw_weight[k * N + n]) & 15) << (4 * (lane & 1));
    }
  h_ref_out_fp16.assign(M * N, 0);
  if (compute_reference) {
    auto weight = [&](uint32_t k, uint32_t n) {
      const uint32_t index = WTRANS ? n * stride + k / 2 : k * stride + n / 2;
      return fpint_gemm_test::unpack_int4(h_W_int4[index], WTRANS ? k : n);
    };
    fpint_gemm_test::reference(M, K, N, K, N, QBLK, QDIR,
        h_A, h_scales, h_zeros, weight, fp16_to_float, float_to_fp16, h_ref_out_fp16);
  }
}

static bool compare_fp16(uint16_t actual, uint16_t expected, float tolerance) {
  // FPFP reference mirrors the balanced FP32 tree and ACC order. Treat signed
  // zeros as numerically equal, but report their raw-bit differences separately.
  if (FP16_WEIGHTS)
    return actual == expected || ((actual & 0x7fffu) == 0 && (expected & 0x7fffu) == 0);
  if (SUBNORMAL_VECTORS) return actual == expected;
  if (actual == expected) {
    return true;
  }

  float a = fp16_to_float(actual);
  float e = fp16_to_float(expected);

  if (!std::isfinite(a) || !std::isfinite(e)) {
    return false;
  }

  float diff;
  if (e == 0.0f) {
    diff = std::abs(a);
  } else {
    diff = std::abs((a - e) / e);
  }
  return diff <= tolerance;
}

static int verify_results(vx_buffer_h out_buffer, const std::vector<uint16_t>& ref,
                          uint64_t offset = 0) {
  std::vector<uint16_t> got(ref.size());
  RT_CHECK(vx_copy_from_dev(got.data(), out_buffer, offset, ref.size() * sizeof(uint16_t)));

  int errors = 0;
  size_t bit_mismatches = 0;
  double max_abs = 0, max_rel = 0, max_math_abs = 0;
  size_t nan_count = 0, inf_count = 0, reference_nonfinite = 0;
  for (uint32_t i = 0; i < ref.size(); ++i) {
    bit_mismatches += got[i] != ref[i];
    const double actual = fp16_to_float(got[i]);
    const double expected = fp16_to_float(ref[i]);
    nan_count += std::isnan(actual);
    inf_count += std::isinf(actual);
    reference_nonfinite += !std::isfinite(expected);
    if (std::isfinite(actual) && std::isfinite(expected)) {
      const double error = std::abs(actual - expected);
      max_abs = std::max(max_abs, error);
      max_rel = std::max(max_rel, expected == 0 ? error : error / std::abs(expected));
      if (!mathematical_reference.empty())
        max_math_abs = std::max(max_math_abs, std::abs(actual - mathematical_reference[i]));
    }
    if (!compare_fp16(got[i], ref[i], FP16_TOL)) {
      if (errors < 10) {
        printf("Mismatch[%u]: got=0x%04x (%f), exp=0x%04x (%f)\n",
               i,
               unsigned(got[i]), fp16_to_float(got[i]),
               unsigned(ref[i]), fp16_to_float(ref[i]));
      }
      ++errors;
    }
  }
  std::cout << "Verification: mismatches=" << errors << "/" << ref.size()
            << ", bit_mismatches=" << bit_mismatches
            << ", max_abs=" << max_abs << ", max_rel=" << max_rel
            << ", output_nan=" << nan_count << ", output_inf=" << inf_count
            << ", reference_nonfinite=" << reference_nonfinite;
  if (FP16_WEIGHTS) std::cout << ", max_abs_vs_fp64=" << max_math_abs;
  std::cout << std::endl;
  return errors;
}

static bool compute_lmem_layout(kernel_arg_t& kargs, uint64_t local_mem_size) {
  // Tile-local group counts for SC/ZP
  uint64_t groups_tile = FP16_WEIGHTS ? 0 : (DMA_KT + uint64_t(QBLK) - 1ull) / uint64_t(QBLK);
  uint64_t ng_tile     = FP16_WEIGHTS ? 0 : (DMA_NT + uint64_t(QBLK) - 1ull) / uint64_t(QBLK);

  // Scratch sizes (bytes)
  uint64_t lmem_ibuf_bytes  = DMA_MT * DMA_KT * 2ull;                 // fp16
  uint64_t lmem_wbuf_bytes  = FP16_WEIGHTS ? DMA_KT * DMA_NT * 2ull
                                         : DMA_KT * ((DMA_NT + 1ull) / 2ull);
  uint64_t lmem_scbuf_bytes = (QDIR == 0)
                                ? (groups_tile * DMA_NT * 2ull)       // fp16
                                : (DMA_KT * ng_tile     * 2ull);      // fp16
  uint64_t lmem_zpbuf_bytes = (QDIR == 0)
                                ? (groups_tile * DMA_NT * 2ull)       // int16
                                : (DMA_KT * ng_tile     * 2ull);      // int16
  uint64_t lmem_obuf_bytes  = OUTPUT_TILE_ELEMENTS * 2ull;           // fp16
  uint64_t lmem_psum_bytes  = OUTPUT_TILE_ELEMENTS * 4ull;           // fp32

  // LMEM address range: [LMEM_BASE_ADDRESS, LMEM_BASE_ADDRESS + local_mem_size)
  const uint64_t lmem_begin = LMEM_BASE_ADDRESS;
  if (local_mem_size > std::numeric_limits<uint64_t>::max() - lmem_begin
      || LMEM_OFFSET_BYTES > local_mem_size)
    return false;
  const uint64_t lmem_end = lmem_begin + local_mem_size;
  uint64_t cur = lmem_begin + LMEM_OFFSET_BYTES;

  auto alloc = [&](uint64_t bytes, uint64_t& out_base) -> bool {
    if (cur > std::numeric_limits<uint64_t>::max() - (LMEM_LAYOUT_ALIGN_BYTES - 1))
      return false;
    cur = align_up_u64(cur, LMEM_LAYOUT_ALIGN_BYTES);
    if (cur > lmem_end) return false;
    if (bytes > (lmem_end - cur)
        || align_up_u64(bytes, LMEM_LAYOUT_ALIGN_BYTES) > (lmem_end - cur)) return false;
    out_base = cur;
    cur += align_up_u64(bytes, LMEM_LAYOUT_ALIGN_BYTES);
    return true;
  };

  // Linear layout (no stack gap)
  if (!alloc(lmem_ibuf_bytes,  kargs.lmem_ibuf0_base)) return false;
  if (!alloc(lmem_ibuf_bytes,  kargs.lmem_ibuf1_base)) return false;

  if (!alloc(lmem_wbuf_bytes,  kargs.lmem_wbuf0_base)) return false;
  if (!alloc(lmem_wbuf_bytes,  kargs.lmem_wbuf1_base)) return false;

  if (!alloc(lmem_scbuf_bytes, kargs.lmem_scbuf0_base)) return false;
  if (!alloc(lmem_scbuf_bytes, kargs.lmem_scbuf1_base)) return false;

  if (!alloc(lmem_zpbuf_bytes, kargs.lmem_zpbuf0_base)) return false;
  if (!alloc(lmem_zpbuf_bytes, kargs.lmem_zpbuf1_base)) return false;

  if (!alloc(lmem_obuf_bytes,  kargs.lmem_obuf_base))  return false;
  if (!alloc(lmem_psum_bytes,  kargs.lmem_psum_base))  return false;

  // In FPFP there are no qparam allocations; keep unused bases explicitly null.
  if (FP16_WEIGHTS) {
    kargs.lmem_scbuf0_base = kargs.lmem_scbuf1_base = 0;
    kargs.lmem_zpbuf0_base = kargs.lmem_zpbuf1_base = 0;
  }
  std::cout << "LMEM scratch: format=" << (FP16_WEIGHTS ? "FP16" : "INT4")
            << ", bytes=" << (cur - lmem_begin - LMEM_OFFSET_BYTES)
            << ", weight_tile_bytes=" << lmem_wbuf_bytes << std::endl;

  return true;
}

static int run_queued_formats(kernel_arg_t root, uint64_t local_mem_size) {
  constexpr uint32_t count = 3;
  const uint64_t a_stride = align_up_u64(uint64_t(M) * K * 2, 64);
  const uint64_t w_stride = align_up_u64(uint64_t(K) * N * 2, 64);
  const uint64_t c_stride = align_up_u64(uint64_t(M) * N * 2, 64);
  std::vector<kernel_arg_t> args(count + 1, root);
  std::vector<std::vector<uint16_t>> references(count);
  std::vector<std::vector<double>> mathematical(count);
  const uint64_t original_offset = LMEM_OFFSET_BYTES;
  for (uint32_t i = 0; i < count; ++i) {
    FP16_WEIGHTS = i != 1;
    auto& job = args[i + 1];
    job.weight_format = FP16_WEIGHTS ? GEMM_WEIGHT_FP16 : GEMM_WEIGHT_INT4;
    job.input_base += i * a_stride;
    job.weight_base += i * w_stride;
    job.output_base += i * c_stride;
    if (!compute_lmem_layout(job, local_mem_size)) {
      std::cerr << "Queued job " << i << " scratch does not fit LMEM" << std::endl;
      LMEM_OFFSET_BYTES = original_offset;
      return -1;
    }
    LMEM_OFFSET_BYTES = job.lmem_psum_base + OUTPUT_TILE_ELEMENTS * 4 - LMEM_BASE_ADDRESS;
    std::vector<uint16_t> a, scales;
    std::vector<uint8_t> w;
    std::vector<int16_t> zeros;
    build_test_vectors(a, w, scales, zeros, references[i], true, i);
    mathematical[i] = mathematical_reference;
    RT_CHECK(vx_copy_to_dev(A_buffer, a.data(), i * a_stride, a.size() * 2));
    RT_CHECK(vx_copy_to_dev(W_int4_buffer, w.data(), i * w_stride, w.size()));
    if (FP16_WEIGHTS) {
      job.scale_base = job.zp_base = 0;
    } else {
      RT_CHECK(vx_copy_to_dev(scales_buffer, scales.data(), 0, scales.size() * 2));
      RT_CHECK(vx_copy_to_dev(zeros_buffer, zeros.data(), 0, zeros.size() * 2));
    }
    const std::vector<uint16_t> poison(size_t(M) * N, 0x7e00);
    RT_CHECK(vx_copy_to_dev(C_buffer, poison.data(), i * c_stride, poison.size() * 2));
  }
  std::cout << "Queued scratch: total_bytes=" << LMEM_OFFSET_BYTES - original_offset << std::endl;
  LMEM_OFFSET_BYTES = original_offset;
  uint64_t args_address = 0;
  RT_CHECK(vx_mem_address(args_buffer, &args_address));
  args[0].queued_jobs_base = args_address + sizeof(kernel_arg_t);
  args[0].queued_jobs_count = count;
  args[0].queued_pending_mask = 0;
  RT_CHECK(vx_copy_to_dev(args_buffer, args.data(), 0, args.size() * sizeof(kernel_arg_t)));
  RT_CHECK(vx_start(device, krnl_buffer, args_buffer));
  RT_CHECK(vx_ready_wait(device, VX_MAX_TIMEOUT));
  RT_CHECK(vx_copy_from_dev(args.data(), args_buffer, 0, args.size() * sizeof(kernel_arg_t)));
  if (args[0].status != MMIO_STATUS_OK) {
    std::cerr << "Queued kernel failed: status=" << status_to_str(args[0].status) << std::endl;
    return -1;
  }
  std::cout << "Queued pending mask after all submissions: 0x" << std::hex
            << args[0].queued_pending_mask << std::dec << std::endl;
  if (__builtin_popcount(args[0].queued_pending_mask) < 2) {
    std::cerr << "Queued overlap was not observed; increase the test shape" << std::endl;
    return -1;
  }
  for (uint32_t i = 0; i < count; ++i) {
    FP16_WEIGHTS = i != 1;
    mathematical_reference = mathematical[i];
    if (args[i + 1].status != MMIO_STATUS_OK
        || verify_results(C_buffer, references[i], i * c_stride) != 0)
      return -1;
    std::cout << "Verified queued job " << i + 1 << "/" << count
              << ", format=" << (FP16_WEIGHTS ? "FP16" : "INT4")
              << ", eid=" << args[i + 1].job_eid << std::endl;
  }
  return 0;
}

int main(int argc, char *argv[]) {
  parse_args(argc, argv);
#ifdef FPFP_GEMM_ONLY
  if (ALTERNATE_FORMATS || QUEUED_FORMATS) {
    std::cerr << "fpfp_gemm_ffn_hw_naive supports only FP16 weights, not mixed-format jobs" << std::endl;
    return -1;
  }
#endif
  if (REPS == 0) {
    std::cerr << "REPS must be > 0" << std::endl;
    return -1;
  }

  const bool needs_fp16 = FP16_WEIGHTS || ALTERNATE_FORMATS || QUEUED_FORMATS;
  const bool needs_int4 = !FP16_WEIGHTS || ALTERNATE_FORMATS || QUEUED_FORMATS;
  if (QUEUED_FORMATS && (REPS != 1 || POWER_MODE || POLL_ONLY_ITERS || ALTERNATE_FORMATS)) {
    std::cerr << "--queued-formats requires -r 1 without power/poll/alternate modes" << std::endl;
    return -1;
  }
  if (QUEUED_FORMATS && GEMM_JOB_NUM_ENTRIES < 3) {
    std::cerr << "--queued-formats requires JOB_MMIO_NUM_ENTRIES >= 3; this build has "
              << GEMM_JOB_NUM_ENTRIES << std::endl;
    return -1;
  }
#ifndef GEMM_NAIVE_FP16_ENABLE
  if (needs_fp16) {
    std::cerr << "FP16 weights require a GEMM_NAIVE_FP16_ENABLE build" << std::endl;
    return -1;
  }
#endif
#ifndef GEMM_NAIVE_ENABLE
  if (needs_int4) {
    std::cerr << "INT4 weights require a GEMM_NAIVE_ENABLE build" << std::endl;
    return -1;
  }
#endif
  if (M == 0 || N == 0 || K == 0) {
    std::cerr << "Require positive M/K/N" << std::endl;
    return -1;
  }
  if ((needs_int4 && K % MXU_ROW != 0) || (needs_fp16 && K % FP16_ROW != 0)) {
    std::cerr << "K must be divisible by each requested format's ROW: INT4="
              << MXU_ROW << ", FP16=" << FP16_ROW << std::endl;
    return -1;
  }
  if (needs_int4 && (QBLK < 16 || QBLK > 128 || (QBLK & (QBLK - 1)) != 0)) {
    std::cerr << "INT4 QBLK must be a power of two from 16 through 128" << std::endl;
    return -1;
  }
  if (ALTERNATE_FORMATS && REPS < 2) {
    std::cerr << "--alternate-formats requires -r >= 2" << std::endl;
    return -1;
  }
  if (needs_fp16 && WTRANS != 0) {
    std::cerr << "FP16 weights support only row-major [K,N] (WTRANS=0)" << std::endl;
    return -1;
  }
  if (WTRANS > 1) {
    std::cout << "WTRANS must be 0 or 1" << std::endl;
    return -1;
  }
  if (needs_int4 && QDIR > 1) {
    std::cout << "QDIR must be 0 or 1" << std::endl;
    return -1;
  }

  std::cout << "TB-style GEMM MMIO test"
            << (POWER_MODE ? " [POWER MODE: no reference, no verify]" : "")
            << std::endl;
  std::cout << "M=" << M << ", N=" << N << ", K=" << K
            << ", QBLK=" << QBLK << ", WTRANS=" << WTRANS
            << ", QDIR=" << QDIR << ", REPS=" << REPS
            << ", lmem_offset=" << LMEM_OFFSET_BYTES
            << ", format=" << (FP16_WEIGHTS ? "FP16" : "INT4")
            << ", alternate=" << ALTERNATE_FORMATS << ", seed=" << RANDOM_SEED
            << ", vectors=" << (SUBNORMAL_VECTORS ? "subnormal" : TAGGED_VECTORS ? "tagged" : FP16_WEIGHTS ? "random" : "corrected-default") << std::endl;
  if (FP16_WEIGHTS)
    std::cout << "FPFP ignores QDIR/QBLK; B is row-major; FP32 tree/ACC, final FP16 output" << std::endl;

  RT_CHECK(vx_dev_open(&device));

  uint64_t num_cores = 0, num_warps = 0, num_threads = 0;
  uint64_t local_mem_size = 0;
  RT_CHECK(vx_dev_caps(device, VX_CAPS_NUM_CORES, &num_cores));
  RT_CHECK(vx_dev_caps(device, VX_CAPS_NUM_WARPS, &num_warps));
  RT_CHECK(vx_dev_caps(device, VX_CAPS_NUM_THREADS, &num_threads));
  RT_CHECK(vx_dev_caps(device, VX_CAPS_LOCAL_MEM_SIZE, &local_mem_size));
  std::cout << "Device: cores=" << num_cores
            << ", warps=" << num_warps
            << ", threads=" << num_threads << std::endl;
  std::cout << "Device: local_mem_size=" << local_mem_size << " bytes" << std::endl;
  std::cout << "Device: stack_base_addr=0x" << std::hex << uint64_t(STACK_BASE_ADDR)
            << ", lmem_base_addr=0x" << uint64_t(LMEM_BASE_ADDR)
            << std::dec << std::endl;

  std::vector<uint16_t> h_A;
  std::vector<uint8_t> h_W_int4;
  std::vector<uint16_t> h_scales;
  std::vector<int16_t> h_zeros;
  std::vector<uint16_t> h_ref_out_fp16;

  build_test_vectors(h_A, h_W_int4, h_scales, h_zeros, h_ref_out_fp16,
                     /*compute_reference=*/!POWER_MODE);

  const uint64_t a_bytes = h_A.size() * sizeof(uint16_t);
  RT_CHECK(vx_mem_alloc(device, QUEUED_FORMATS ? 3 * align_up_u64(a_bytes, 64) : a_bytes,
                        VX_MEM_READ, &A_buffer));
  const uint64_t weight_bytes = needs_fp16 ? uint64_t(K) * N * 2 : h_W_int4.size();
  RT_CHECK(vx_mem_alloc(device, QUEUED_FORMATS ? 3 * align_up_u64(weight_bytes, 64) : weight_bytes,
                        VX_MEM_READ, &W_int4_buffer));
  if (needs_int4) {
    const uint64_t qcount = QDIR ? uint64_t(K) * ((uint64_t(N) + QBLK - 1) / QBLK)
                                : ((uint64_t(K) + QBLK - 1) / QBLK) * N;
    RT_CHECK(vx_mem_alloc(device, qcount * sizeof(uint16_t), VX_MEM_READ, &scales_buffer));
    RT_CHECK(vx_mem_alloc(device, qcount * sizeof(int16_t), VX_MEM_READ, &zeros_buffer));
  }
  const uint64_t c_bytes = uint64_t(M) * N * sizeof(uint16_t);
  RT_CHECK(vx_mem_alloc(device, QUEUED_FORMATS ? 3 * align_up_u64(c_bytes, 64) : c_bytes,
                        VX_MEM_WRITE, &C_buffer));

  std::cout << "Host buffers allocated and initialized" << std::endl;

  std::cout << "Kernel file uploaded" << std::endl;
  RT_CHECK(vx_upload_kernel_file(device, kernel_file, &krnl_buffer));

  kernel_arg_t kargs = {};
  kargs.grid_dim[0] = static_cast<uint32_t>(num_cores);
  kargs.grid_dim[1] = 1;
  kargs.block_dim[0] = 1;
  kargs.block_dim[1] = 1;

  kargs.M = M;
  kargs.N = N;
  kargs.K = K;
  kargs.QBLK = QBLK;
  kargs.WTRANS = WTRANS;
  kargs.QDIR = QDIR;
  kargs.weight_format = FP16_WEIGHTS ? GEMM_WEIGHT_FP16 : GEMM_WEIGHT_INT4;
  kargs.poll_only_iterations = POLL_ONLY_ITERS;

  RT_CHECK(vx_mem_address(A_buffer, &kargs.input_base));
  RT_CHECK(vx_mem_address(W_int4_buffer, &kargs.weight_base));
  if (scales_buffer) RT_CHECK(vx_mem_address(scales_buffer, &kargs.scale_base));
  if (zeros_buffer) RT_CHECK(vx_mem_address(zeros_buffer, &kargs.zp_base));
  RT_CHECK(vx_mem_address(C_buffer, &kargs.output_base));
  std::cout << "Device buffer addresses: " << std::endl;
  std::cout << "  input_base=0x" << std::hex << kargs.input_base << std::endl;
  std::cout << "  weight_base=0x" << std::hex << kargs.weight_base << std::endl;
  std::cout << "  scale_base=0x" << std::hex << kargs.scale_base << std::endl;
  std::cout << "  zp_base=0x" << std::hex << kargs.zp_base << std::endl;
  std::cout << "  output_base=0x" << std::hex << kargs.output_base << std::dec << std::endl;

  if (!compute_lmem_layout(kargs, local_mem_size)) {
    std::cerr << "LMEM layout does not fit device local memory (size=" << local_mem_size
              << ", offset=" << LMEM_OFFSET_BYTES << ")" << std::endl;
    cleanup();
    return -1;
  }

  kargs.status = MMIO_STATUS_INIT;
  kargs.job_eid = 0;
  kargs.job_generation = 0;
  kargs.last_ctrl = 0;

  std::cout << "Uploading kernel arguments and kernel" << std::endl;
  // The kernel reports completion and allocation failures through kargs.
  RT_CHECK(vx_mem_alloc(device, sizeof(kargs) * (QUEUED_FORMATS ? 4 : 1), VX_MEM_READ_WRITE, &args_buffer));
  RT_CHECK(vx_copy_to_dev(args_buffer, &kargs, 0, sizeof(kargs)));

  if (QUEUED_FORMATS) {
    const int result = run_queued_formats(kargs, local_mem_size);
    cleanup();
    std::cout << (result == 0 ? "PASSED" : "FAILED") << std::endl;
    return result;
  }

  std::cout << "Starting kernel execution (reps=" << REPS
            << (POLL_ONLY_ITERS ? " [POLL-ONLY MODE]" : "")
            << ", poll_iters=" << POLL_ONLY_ITERS << ")" << std::endl;
  for (uint32_t rep = 0; rep < REPS; ++rep) {
    if (rep != 0 && ALTERNATE_FORMATS) {
      FP16_WEIGHTS = !FP16_WEIGHTS;
      kargs.weight_format = FP16_WEIGHTS ? GEMM_WEIGHT_FP16 : GEMM_WEIGHT_INT4;
      if (!compute_lmem_layout(kargs, local_mem_size)) {
        std::cerr << "LMEM layout does not fit for the next format" << std::endl;
        cleanup();
        return -1;
      }
    }
    if (rep != 0)
      build_test_vectors(h_A, h_W_int4, h_scales, h_zeros, h_ref_out_fp16,
                         !POWER_MODE, rep);
    RT_CHECK(vx_copy_to_dev(A_buffer, h_A.data(), 0, h_A.size() * sizeof(uint16_t)));
    RT_CHECK(vx_copy_to_dev(W_int4_buffer, h_W_int4.data(), 0, h_W_int4.size()));
    if (!FP16_WEIGHTS) {
      RT_CHECK(vx_copy_to_dev(scales_buffer, h_scales.data(), 0, h_scales.size() * sizeof(uint16_t)));
      RT_CHECK(vx_copy_to_dev(zeros_buffer, h_zeros.data(), 0, h_zeros.size() * sizeof(int16_t)));
      RT_CHECK(vx_mem_address(scales_buffer, &kargs.scale_base));
      RT_CHECK(vx_mem_address(zeros_buffer, &kargs.zp_base));
    } else {
      kargs.scale_base = kargs.zp_base = 0;
    }
    std::cout << "Job " << rep + 1 << ": format=" << (FP16_WEIGHTS ? "FP16" : "INT4") << std::endl;
    // A missed output store must fail even when the expected value is zero.
    const std::vector<uint16_t> poison_out(size_t(M) * N, 0x7e00u);
    RT_CHECK(vx_copy_to_dev(C_buffer, poison_out.data(), 0, poison_out.size() * sizeof(uint16_t)));

    // Reset status before each launch and bump generation/eid so the AFU
    // does not treat consecutive launches as duplicates.
    kargs.status = MMIO_STATUS_INIT;
    kargs.job_eid = rep;
    kargs.job_generation = rep + 1;
    kargs.last_ctrl = 0;
    RT_CHECK(vx_copy_to_dev(args_buffer, &kargs, 0, sizeof(kargs)));

    RT_CHECK(vx_start(device, krnl_buffer, args_buffer));
    int wait_ret = vx_ready_wait(device, VX_MAX_TIMEOUT);
    if (wait_ret != 0) {
      std::cerr << "vx_ready_wait failed at rep=" << rep
                << ": ret=" << wait_ret << std::endl;

      int arg_ret = vx_copy_from_dev(&kargs, args_buffer, 0, sizeof(kargs));
      if (arg_ret == 0) {
        std::cerr << "Kernel status after wait failure: status=" << kargs.status
                  << " (" << status_to_str(kargs.status) << ")"
                  << ", eid=" << kargs.job_eid
                  << ", gen=" << kargs.job_generation
                  << ", ctrl=0x" << std::hex << kargs.last_ctrl << std::dec
                  << std::endl;
      } else {
        std::cerr << "Failed to read args buffer after wait failure, ret=" << arg_ret << std::endl;
      }

      cleanup();
      return -1;
    }
    RT_CHECK(vx_copy_from_dev(&kargs, args_buffer, 0, sizeof(kargs)));
    if (kargs.status != MMIO_STATUS_OK) {
      std::cerr << "MMIO kernel failed at rep=" << rep
                << ": status=" << kargs.status
                << " (" << status_to_str(kargs.status) << ")"
                << ", eid=" << kargs.job_eid << ", gen=" << kargs.job_generation
                << ", ctrl=0x" << std::hex << kargs.last_ctrl << std::dec << std::endl;
      cleanup();
      return -1;
    }
    if (!POWER_MODE) {
      const int errors = verify_results(C_buffer, h_ref_out_fp16);
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
