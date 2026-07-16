#include <iostream>
#include <unistd.h>
#include <getopt.h>
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
static uint32_t K = 32;
static uint32_t QBLK = 32;
static uint32_t WTRANS = 0;
static uint32_t QDIR = 0;
static uint32_t REPS = 1;
static bool POWER_MODE = false;
// Poll-only baseline mode: when > 0, kernel does N MMIO reads instead of GEMM.
// Used to isolate Vortex-core polling power from HW-GEMM power.
static uint32_t POLL_ONLY_ITERS = 0;
static constexpr uint32_t POLL_ONLY_QDIR_SENTINEL = 0xDEADu;

static vx_device_h device = nullptr;
static vx_buffer_h krnl_buffer = nullptr;
static vx_buffer_h args_buffer = nullptr;

static vx_buffer_h A_buffer = nullptr;       // fp16 [M x K]
static vx_buffer_h W_int4_buffer = nullptr;  // packed int4 [K x N]
static vx_buffer_h scales_buffer = nullptr;  // fp16 [KG x N]
static vx_buffer_h zeros_buffer = nullptr;   // int16 [KG x N]
static vx_buffer_h C_buffer = nullptr;       // fp16 [M x N]

static constexpr float FP16_TOL = 0.01f;

static constexpr uint64_t LMEM_LAYOUT_ALIGN_BYTES = 64;
static constexpr uint64_t LMEM_STACK_GUARD_BYTES = (1ull << STACK_LOG2_SIZE);
static constexpr uint64_t LMEM_BASE_ADDRESS = static_cast<uint64_t>(LMEM_BASE_ADDR);
static constexpr uint64_t DMA_MT = GEMM_FSM_MT;
static constexpr uint64_t DMA_NT = GEMM_FSM_NT;
static constexpr uint64_t DMA_KT = GEMM_FSM_KT;

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
  std::cout << "Usage: [-m M] [-n N] [-k K] [-q QBLK] [-t WTRANS] [-d QDIR]" << std::endl;
  std::cout << "       [-r REPS] [-p (power-mode: skip reference & verify)]" << std::endl;
  std::cout << "       [--pol POLL_ITERS] (poll-only baseline mode; implies -p)" << std::endl;
  std::cout << "       [-h]" << std::endl;
}

// Long-option-only flag value (out of ASCII range so it doesn't collide with short opts).
static constexpr int OPT_POL = 0x100;

static struct option long_options[] = {
  {"pol", required_argument, nullptr, OPT_POL},
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
  if (exp == 31) return sign ? -INFINITY : INFINITY;

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
                               bool compute_reference) {
  uint32_t groups_total = (K + QBLK - 1) / QBLK;
  uint32_t ng_total = (N + QBLK - 1) / QBLK;

  uint32_t sc_zp_size = (QDIR == 0) ? (groups_total * N) : (K * ng_total);

  h_A.resize(M * K);
  h_W_int4.resize((WTRANS == 0) ? (K * ((N + 1) / 2)) : (N * ((K + 1) / 2)));
  h_scales.resize(sc_zp_size);
  h_zeros.resize(sc_zp_size);
  h_ref_out_fp16.resize(M * N);

  for (uint32_t m = 0; m < M; ++m) {
    for (uint32_t k = 0; k < K; ++k) {
      float v = 1.0f + float((m + k) % 7);
      h_A[m * K + k] = float_to_fp16(v);
    }
  }

  if (WTRANS == 0) {
    for (uint32_t k = 0; k < K; ++k) {
      for (uint32_t n_pair = 0; n_pair < ((N + 1) / 2); ++n_pair) {
        uint32_t n0 = n_pair * 2;
        uint32_t n1 = n0 + 1;
        int8_t w0 = int8_t(int((k * N + n0) % 7) - 3);
        int8_t w1 = 0;
        if (n1 < N) {
          w1 = int8_t(int((k * N + n1) % 7) - 3);
        }
        h_W_int4[k * ((N + 1) / 2) + n_pair] = pack_int4_pair(w0, w1);
      }
    }
  } else {
    for (uint32_t n = 0; n < N; ++n) {
      for (uint32_t k_pair = 0; k_pair < ((K + 1) / 2); ++k_pair) {
        uint32_t k0 = k_pair * 2;
        uint32_t k1 = k0 + 1;
        int8_t w0 = int8_t(int((k0 * N + n) % 7) - 3);
        int8_t w1 = 0;
        if (k1 < K) {
          w1 = int8_t(int((k1 * N + n) % 7) - 3);
        }
        h_W_int4[n * ((K + 1) / 2) + k_pair] = pack_int4_pair(w0, w1);
      }
    }
  }

  if (QDIR == 0) {
    for (uint32_t kg = 0; kg < groups_total; ++kg) {
      for (uint32_t n = 0; n < N; ++n) {
        float scale = 1.0f + float(n % 7);
        int16_t zp = int16_t(int(n % 7) - 3);
        h_scales[kg * N + n] = float_to_fp16(scale);
        h_zeros[kg * N + n] = zp;
      }
    }
  } else {
    for (uint32_t k = 0; k < K; ++k) {
      for (uint32_t ng = 0; ng < ng_total; ++ng) {
        float scale = 1.0f + float(ng % 7);
        int16_t zp = int16_t(int(ng % 7) - 3);
        h_scales[k * ng_total + ng] = float_to_fp16(scale);
        h_zeros[k * ng_total + ng] = zp;
      }
    }
  }

  if (!compute_reference) {
    return;
  }

  for (uint32_t m = 0; m < M; ++m) {
    for (uint32_t n = 0; n < N; ++n) {
      float sum = 0.0f;
      for (uint32_t k = 0; k < K; ++k) {
        float a = fp16_to_float(h_A[m * K + k]);

        float scale, zp;
        if (QDIR == 0) {
          uint32_t group_id = k / QBLK;
          scale = fp16_to_float(h_scales[group_id * N + n]);
          zp = float(h_zeros[group_id * N + n]);
        } else {
          uint32_t ng = n / QBLK;
          scale = fp16_to_float(h_scales[k * ng_total + ng]);
          zp = float(h_zeros[k * ng_total + ng]);
        }

        int8_t w = int8_t(int((k * N + n) % 7) - 3);

        float dequant = (float(w) - zp) * scale;
        sum += a * dequant;
      }
      h_ref_out_fp16[m * N + n] = float_to_fp16(sum);
    }
  }
}

static bool compare_fp16(uint16_t actual, uint16_t expected, float tolerance) {
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

static int verify_results(vx_buffer_h out_buffer, const std::vector<uint16_t>& ref) {
  std::vector<uint16_t> got(ref.size());
  RT_CHECK(vx_copy_from_dev(got.data(), out_buffer, 0, ref.size() * sizeof(uint16_t)));

  int errors = 0;
  for (uint32_t i = 0; i < ref.size(); ++i) {
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

  return errors;
}

static bool compute_lmem_layout(kernel_arg_t& kargs, uint64_t local_mem_size) {
  // Tile-local group counts for SC/ZP
  uint64_t groups_tile = (DMA_KT + uint64_t(QBLK) - 1ull) / uint64_t(QBLK);
  uint64_t ng_tile     = (DMA_NT + uint64_t(QBLK) - 1ull) / uint64_t(QBLK);

  // Scratch sizes (bytes)
  uint64_t lmem_ibuf_bytes  = DMA_MT * DMA_KT * 2ull;                 // fp16
  uint64_t lmem_wbuf_bytes  = DMA_KT * ((DMA_NT + 1ull) / 2ull);      // packed int4
  uint64_t lmem_scbuf_bytes = (QDIR == 0)
                                ? (groups_tile * DMA_NT * 2ull)       // fp16
                                : (DMA_KT * ng_tile     * 2ull);      // fp16
  uint64_t lmem_zpbuf_bytes = (QDIR == 0)
                                ? (groups_tile * DMA_NT * 2ull)       // int16
                                : (DMA_KT * ng_tile     * 2ull);      // int16
  uint64_t lmem_obuf_bytes  = DMA_MT * DMA_NT * 2ull;                 // fp16

  // LMEM address range: [LMEM_BASE_ADDRESS, LMEM_BASE_ADDRESS + local_mem_size)
  const uint64_t lmem_begin = LMEM_BASE_ADDRESS;
  const uint64_t lmem_end   = LMEM_BASE_ADDRESS + local_mem_size;

  uint64_t cur = lmem_begin;

  auto alloc = [&](uint64_t bytes, uint64_t& out_base) -> bool {
    cur = align_up_u64(cur, LMEM_LAYOUT_ALIGN_BYTES);
    if (cur > lmem_end) return false;
    if (bytes > (lmem_end - cur)) return false;
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

  return true;
}

int main(int argc, char *argv[]) {
  parse_args(argc, argv);

  if (QBLK == 0) {
    std::cout << "QBLK must be > 0" << std::endl;
    return -1;
  }
  if (WTRANS > 1) {
    std::cout << "WTRANS must be 0 or 1" << std::endl;
    return -1;
  }
  if (QDIR > 1) {
    std::cout << "QDIR must be 0 or 1" << std::endl;
    return -1;
  }

  std::cout << "TB-style GEMM MMIO test"
            << (POWER_MODE ? " [POWER MODE: no reference, no verify]" : "")
            << std::endl;
  std::cout << "M=" << M << ", N=" << N << ", K=" << K
            << ", QBLK=" << QBLK << ", WTRANS=" << WTRANS
            << ", QDIR=" << QDIR << ", REPS=" << REPS << std::endl;

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

  RT_CHECK(vx_mem_alloc(device, h_A.size() * sizeof(uint16_t), VX_MEM_READ, &A_buffer));
  RT_CHECK(vx_mem_alloc(device, h_W_int4.size() * sizeof(uint8_t), VX_MEM_READ, &W_int4_buffer));
  RT_CHECK(vx_mem_alloc(device, h_scales.size() * sizeof(uint16_t), VX_MEM_READ, &scales_buffer));
  RT_CHECK(vx_mem_alloc(device, h_zeros.size() * sizeof(int16_t), VX_MEM_READ, &zeros_buffer));
  RT_CHECK(vx_mem_alloc(device, h_ref_out_fp16.size() * sizeof(uint16_t), VX_MEM_WRITE, &C_buffer));

  std::cout << "Host buffers allocated and initialized" << std::endl;
  RT_CHECK(vx_copy_to_dev(A_buffer, h_A.data(), 0, h_A.size() * sizeof(uint16_t)));
  RT_CHECK(vx_copy_to_dev(W_int4_buffer, h_W_int4.data(), 0, h_W_int4.size() * sizeof(uint8_t)));
  RT_CHECK(vx_copy_to_dev(scales_buffer, h_scales.data(), 0, h_scales.size() * sizeof(uint16_t)));
  RT_CHECK(vx_copy_to_dev(zeros_buffer, h_zeros.data(), 0, h_zeros.size() * sizeof(int16_t)));

  std::vector<uint16_t> zero_out(h_ref_out_fp16.size(), 0);
  RT_CHECK(vx_copy_to_dev(C_buffer, zero_out.data(), 0, zero_out.size() * sizeof(uint16_t)));

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

  RT_CHECK(vx_mem_address(A_buffer, &kargs.input_base));
  RT_CHECK(vx_mem_address(W_int4_buffer, &kargs.weight_base));
  RT_CHECK(vx_mem_address(scales_buffer, &kargs.scale_base));
  RT_CHECK(vx_mem_address(zeros_buffer, &kargs.zp_base));
  RT_CHECK(vx_mem_address(C_buffer, &kargs.output_base));
  std::cout << "Device buffer addresses: " << std::endl;
  std::cout << "  input_base=0x" << std::hex << kargs.input_base << std::endl;
  std::cout << "  weight_base=0x" << std::hex << kargs.weight_base << std::endl;
  std::cout << "  scale_base=0x" << std::hex << kargs.scale_base << std::endl;
  std::cout << "  zp_base=0x" << std::hex << kargs.zp_base << std::endl;
  std::cout << "  output_base=0x" << std::hex << kargs.output_base << std::dec << std::endl;

  if (!compute_lmem_layout(kargs, local_mem_size)) {
    std::cerr << "LMEM layout does not fit device local memory (size=" << local_mem_size << ")" << std::endl;
    cleanup();
    return -1;
  }

  kargs.status = MMIO_STATUS_INIT;
  kargs.job_eid = 0;
  kargs.job_generation = 0;
  kargs.last_ctrl = 0;

  std::cout << "Uploading kernel arguments and kernel" << std::endl;
  // The kernel reports completion and allocation failures through kargs.
  RT_CHECK(vx_mem_alloc(device, sizeof(kargs), VX_MEM_READ_WRITE, &args_buffer));
  RT_CHECK(vx_copy_to_dev(args_buffer, &kargs, 0, sizeof(kargs)));

  std::cout << "Starting kernel execution (reps=" << REPS
            << (POLL_ONLY_ITERS ? " [POLL-ONLY MODE]" : "")
            << ", poll_iters=" << POLL_ONLY_ITERS << ")" << std::endl;
  for (uint32_t rep = 0; rep < REPS; ++rep) {
    // Reset status before each launch and bump generation/eid so the AFU
    // does not treat consecutive launches as duplicates.
    kargs.status = MMIO_STATUS_INIT;
    kargs.job_eid = rep;
    kargs.job_generation = rep + 1;
    kargs.last_ctrl = 0;
    if (POLL_ONLY_ITERS) {
      // Hijack kargs.QDIR (sentinel) + kargs.K (iteration count) so the
      // device kernel takes the polling-only path. Real M/N/K stay valid
      // for the LMEM layout already computed; the kernel ignores them.
      kargs.QDIR = POLL_ONLY_QDIR_SENTINEL;
      kargs.K    = POLL_ONLY_ITERS;
    }
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
  }

  std::cout << "Kernel execution completed, reading back results" << std::endl;
  RT_CHECK(vx_copy_from_dev(&kargs, args_buffer, 0, sizeof(kargs)));

  if (kargs.status != MMIO_STATUS_OK) {
    std::cout << "MMIO kernel failed: status=" << kargs.status
              << " (" << status_to_str(kargs.status) << ")"
              << ", eid=" << kargs.job_eid
              << ", gen=" << kargs.job_generation
              << ", ctrl=0x" << std::hex << kargs.last_ctrl << std::dec
              << std::endl;
    cleanup();
    return -1;
  }

  int errors = 0;
  if (POWER_MODE) {
    std::cout << "Power mode: skipping verification" << std::endl;
  } else {
    errors = verify_results(C_buffer, h_ref_out_fp16);
  }

  cleanup();

  if (errors != 0) {
    std::cout << "FAILED: errors=" << errors << std::endl;
    return -1;
  }

  std::cout << "PASSED" << std::endl;
  return 0;
}
