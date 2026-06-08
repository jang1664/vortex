// Benchmark harness for fpint_gemm_ffn_hw. See softmax/bench_main.cpp for
// design notes. Reuses kernel.vxbin built from kernel.cpp; differs from
// main.cpp only in that it skips reference output/per-element verification and
// runs warmup + timed-iteration loops around vx_start / vx_ready_wait.
//
// CLI: same shape args as main.cpp (-m -n -k -q -t -d) plus
//      --warmup=N / --iterations=N / --csv / --output=PATH / --output-append
//      parsed by bench_util.
//
// Unlike fpint_gemm_ffn_hw_improve, this variant uploads DRAM buffers in
// plain row-major form (no tile conversion) and uses LMEM-based scratch
// addressing via compute_lmem_layout.

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

// Bench defaults: pick sizes large enough to amortize launch overhead.
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

static constexpr uint64_t LMEM_LAYOUT_ALIGN_BYTES = 64;
static constexpr uint64_t LMEM_BASE_ADDRESS = static_cast<uint64_t>(LMEM_BASE_ADDR);
static constexpr uint64_t DMA_MT = GEMM_FSM_MT;
static constexpr uint64_t DMA_NT = GEMM_FSM_NT;
static constexpr uint64_t DMA_KT = GEMM_FSM_KT;

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

// ============================================================================
// FP16 conversion (used to produce well-formed FP16 inputs and scales)
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

static uint8_t pack_int4_pair(int8_t lo, int8_t hi) {
  return uint8_t((uint8_t(hi) & 0x0F) << 4) | uint8_t(lo & 0x0F);
}

// ============================================================================
// Test vector generation (deterministic; no host-side reference output)
// ============================================================================

static void build_test_vectors(std::vector<uint16_t>& h_A,
                               std::vector<uint8_t>& h_W_int4,
                               std::vector<uint16_t>& h_scales,
                               std::vector<int16_t>& h_zeros) {
  uint32_t groups_total = (K + QBLK - 1) / QBLK;
  uint32_t ng_total = (N + QBLK - 1) / QBLK;
  uint32_t sc_zp_size = (QDIR == 0) ? (groups_total * N) : (K * ng_total);

  h_A.resize(M * K);
  h_W_int4.resize((WTRANS == 0) ? (K * ((N + 1) / 2)) : (N * ((K + 1) / 2)));
  h_scales.resize(sc_zp_size);
  h_zeros.resize(sc_zp_size);

  for (uint32_t m = 0; m < M; ++m) {
    for (uint32_t k = 0; k < K; ++k) {
      h_A[m * K + k] = float_to_fp16(1.0f + float((m + k) % 7));
    }
  }

  if (WTRANS == 0) {
    for (uint32_t k = 0; k < K; ++k) {
      for (uint32_t n_pair = 0; n_pair < ((N + 1) / 2); ++n_pair) {
        uint32_t n0 = n_pair * 2;
        uint32_t n1 = n0 + 1;
        int8_t w0 = int8_t(int((k * N + n0) % 7) - 3);
        int8_t w1 = (n1 < N) ? int8_t(int((k * N + n1) % 7) - 3) : 0;
        h_W_int4[k * ((N + 1) / 2) + n_pair] = pack_int4_pair(w0, w1);
      }
    }
  } else {
    for (uint32_t n = 0; n < N; ++n) {
      for (uint32_t k_pair = 0; k_pair < ((K + 1) / 2); ++k_pair) {
        uint32_t k0 = k_pair * 2;
        uint32_t k1 = k0 + 1;
        int8_t w0 = int8_t(int((k0 * N + n) % 7) - 3);
        int8_t w1 = (k1 < K) ? int8_t(int((k1 * N + n) % 7) - 3) : 0;
        h_W_int4[n * ((K + 1) / 2) + k_pair] = pack_int4_pair(w0, w1);
      }
    }
  }

  if (QDIR == 0) {
    for (uint32_t kg = 0; kg < groups_total; ++kg) {
      for (uint32_t n = 0; n < N; ++n) {
        h_scales[kg * N + n] = float_to_fp16(1.0f + float(n % 7));
        h_zeros[kg * N + n] = int16_t(int(n % 7) - 3);
      }
    }
  } else {
    for (uint32_t k = 0; k < K; ++k) {
      for (uint32_t ng = 0; ng < ng_total; ++ng) {
        h_scales[k * ng_total + ng] = float_to_fp16(1.0f + float(ng % 7));
        h_zeros[k * ng_total + ng] = int16_t(int(ng % 7) - 3);
      }
    }
  }
}

// ============================================================================
// LMEM layout (verbatim from main.cpp)
// ============================================================================

static bool compute_lmem_layout(kernel_arg_t& kargs, uint64_t local_mem_size) {
  uint64_t groups_tile = (DMA_KT + uint64_t(QBLK) - 1ull) / uint64_t(QBLK);
  uint64_t ng_tile     = (DMA_NT + uint64_t(QBLK) - 1ull) / uint64_t(QBLK);

  uint64_t lmem_ibuf_bytes  = DMA_MT * DMA_KT * 2ull;
  uint64_t lmem_wbuf_bytes  = DMA_KT * ((DMA_NT + 1ull) / 2ull);
  uint64_t lmem_scbuf_bytes = (QDIR == 0)
                                ? (groups_tile * DMA_NT * 2ull)
                                : (DMA_KT * ng_tile     * 2ull);
  uint64_t lmem_zpbuf_bytes = lmem_scbuf_bytes;
  uint64_t lmem_obuf_bytes  = DMA_MT * DMA_NT * 2ull;

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

  if (!alloc(lmem_ibuf_bytes,  kargs.lmem_ibuf0_base))  return false;
  if (!alloc(lmem_ibuf_bytes,  kargs.lmem_ibuf1_base))  return false;
  if (!alloc(lmem_wbuf_bytes,  kargs.lmem_wbuf0_base))  return false;
  if (!alloc(lmem_wbuf_bytes,  kargs.lmem_wbuf1_base))  return false;
  if (!alloc(lmem_scbuf_bytes, kargs.lmem_scbuf0_base)) return false;
  if (!alloc(lmem_scbuf_bytes, kargs.lmem_scbuf1_base)) return false;
  if (!alloc(lmem_zpbuf_bytes, kargs.lmem_zpbuf0_base)) return false;
  if (!alloc(lmem_zpbuf_bytes, kargs.lmem_zpbuf1_base)) return false;
  if (!alloc(lmem_obuf_bytes,  kargs.lmem_obuf_base))   return false;

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

  if (!bench.csv) {
    printf("FPINT-GEMM-FFN-HW Bench: M=%u N=%u K=%u QBLK=%u WTRANS=%u QDIR=%u  "
           "warmup=%d iterations=%d\n",
           M, N, K, QBLK, WTRANS, QDIR, bench.warmup, bench.iterations);
  }

  RT_CHECK(vx_dev_open(&device));

  uint64_t num_cores = 0, num_warps = 0, num_threads = 0;
  uint64_t local_mem_size = 0;
  RT_CHECK(vx_dev_caps(device, VX_CAPS_NUM_CORES,      &num_cores));
  RT_CHECK(vx_dev_caps(device, VX_CAPS_NUM_WARPS,      &num_warps));
  RT_CHECK(vx_dev_caps(device, VX_CAPS_NUM_THREADS,    &num_threads));
  RT_CHECK(vx_dev_caps(device, VX_CAPS_LOCAL_MEM_SIZE, &local_mem_size));

  // Reserve the kernel's fixed VMA before large data buffers are allocated.
  // Otherwise large M/N/K cases can place C across STARTUP_ADDR and make the
  // later kernel upload fail with an address-overlap error.
  RT_CHECK(vx_upload_kernel_file(device, kernel_file, &krnl_buffer));

  // ---- Generate test vectors (no host reference) ----
  std::vector<uint16_t> h_A;
  std::vector<uint8_t>  h_W_int4;
  std::vector<uint16_t> h_scales;
  std::vector<int16_t>  h_zeros;
  build_test_vectors(h_A, h_W_int4, h_scales, h_zeros);

  size_t out_total_bytes = size_t(M) * N * sizeof(uint16_t);

  // ---- Allocate device buffers (row-major; no tile conversion) ----
  RT_CHECK(vx_mem_alloc(device, h_A.size()      * sizeof(uint16_t), VX_MEM_READ,  &A_buffer));
  RT_CHECK(vx_mem_alloc(device, h_W_int4.size() * sizeof(uint8_t),  VX_MEM_READ,  &W_int4_buffer));
  RT_CHECK(vx_mem_alloc(device, h_scales.size() * sizeof(uint16_t), VX_MEM_READ,  &scales_buffer));
  RT_CHECK(vx_mem_alloc(device, h_zeros.size()  * sizeof(int16_t),  VX_MEM_READ,  &zeros_buffer));
  RT_CHECK(vx_mem_alloc(device, out_total_bytes,                    VX_MEM_WRITE, &C_buffer));

  // ---- Upload row-major data ----
  RT_CHECK(vx_copy_to_dev(A_buffer,      h_A.data(),      0, h_A.size()      * sizeof(uint16_t)));
  RT_CHECK(vx_copy_to_dev(W_int4_buffer, h_W_int4.data(), 0, h_W_int4.size() * sizeof(uint8_t)));
  RT_CHECK(vx_copy_to_dev(scales_buffer, h_scales.data(), 0, h_scales.size() * sizeof(uint16_t)));
  RT_CHECK(vx_copy_to_dev(zeros_buffer,  h_zeros.data(),  0, h_zeros.size()  * sizeof(int16_t)));

  std::vector<uint8_t> zero_out(out_total_bytes, 0);
  RT_CHECK(vx_copy_to_dev(C_buffer, zero_out.data(), 0, out_total_bytes));

  // ---- Set up kernel arguments ----
  kernel_arg_t kargs = {};
  kargs.grid_dim[0]  = static_cast<uint32_t>(num_cores);
  kargs.grid_dim[1]  = 1;
  kargs.block_dim[0] = 1;
  kargs.block_dim[1] = 1;

  kargs.M      = M;
  kargs.N      = N;
  kargs.K      = K;
  kargs.QBLK   = QBLK;
  kargs.WTRANS = WTRANS;
  kargs.QDIR   = QDIR;

  RT_CHECK(vx_mem_address(A_buffer,      &kargs.input_base));
  RT_CHECK(vx_mem_address(W_int4_buffer, &kargs.weight_base));
  RT_CHECK(vx_mem_address(scales_buffer, &kargs.scale_base));
  RT_CHECK(vx_mem_address(zeros_buffer,  &kargs.zp_base));
  RT_CHECK(vx_mem_address(C_buffer,      &kargs.output_base));

  if (!compute_lmem_layout(kargs, local_mem_size)) {
    std::cerr << "LMEM layout does not fit device local memory (size="
              << local_mem_size << ")" << std::endl;
    cleanup();
    return -1;
  }

  kargs.status         = MMIO_STATUS_INIT;
  kargs.job_eid        = 0;
  kargs.job_generation = 0;
  kargs.last_ctrl      = 0;

  RT_CHECK(vx_upload_bytes(device, &kargs, sizeof(kargs), &args_buffer));

  auto check_kernel_status = [&](const char* phase, int iter) -> bool {
    RT_CHECK(vx_copy_from_dev(&kargs, args_buffer, 0, sizeof(kargs)));
    if (kargs.status != MMIO_STATUS_OK) {
      std::cerr << "Kernel failed during " << phase << " iter=" << iter
                << ": status=" << kargs.status
                << " (" << status_to_str(kargs.status) << ")"
                << ", eid=" << kargs.job_eid
                << ", gen=" << kargs.job_generation
                << ", ctrl=0x" << std::hex << kargs.last_ctrl << std::dec
                << std::endl;
      cleanup();
      return false;
    }
    return true;
  };

  // ---- Warmup --------------------------------------------------------------
  for (int i = 0; i < bench.warmup; ++i) {
    RT_CHECK(vx_start(device, krnl_buffer, args_buffer));
    RT_CHECK(vx_ready_wait(device, VX_MAX_TIMEOUT));
    if (!check_kernel_status("warmup", i))
      return -1;
  }

  // ---- Timed iterations ----------------------------------------------------
  vx_bench::Stats stats;
  for (int i = 0; i < bench.iterations; ++i) {
    vx_bench::Stopwatch sw; sw.start();
    RT_CHECK(vx_start(device, krnl_buffer, args_buffer));
    RT_CHECK(vx_ready_wait(device, VX_MAX_TIMEOUT));
    if (!check_kernel_status("timed", i))
      return -1;
    stats.record(sw.stop_us());
  }

  stats.report("fpint_gemm_ffn_hw", bench);

  if (!bench.csv) {
    printf("\n[Performance]\n");
    vx_dump_perf(device, stdout);
  }

  cleanup();
  return 0;
}
