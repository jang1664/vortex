// Benchmark harness for sgemm_tcu. See softmax/bench_main.cpp for design notes.
//
// Compared with main.cpp this skips the structured-sparsity path and the
// per-element comparator templates. Validation is a coarse "output is not
// all-zero" sanity check — kernel correctness is the regression test's job;
// here we only need to know we're timing a kernel that actually ran.

#include "common.h"
#include "bench_util.h"
#include <cmath>
#include <cstdio>
#include <cstring>
#include <iostream>
#include <rvfloats.h>
#include <tensor_cfg.h>
#include <unistd.h>
#include <util.h>
#include <vector>
#include <vortex.h>

#define RT_CHECK(_expr)                                      \
  do {                                                       \
    int _ret = _expr;                                        \
    if (0 == _ret)                                           \
      break;                                                 \
    printf("Error: '%s' returned %d!\n", #_expr, (int)_ret); \
    cleanup();                                               \
    exit(-1);                                                \
  } while (false)

using namespace vortex;
namespace vt = tensor;

using cfg = vt::wmma_config_t<NUM_THREADS, vt::ITYPE, vt::OTYPE>;
using itype_t = typename vt::ITYPE::dtype;
using otype_t = typename vt::OTYPE::dtype;

const char *kernel_file = "kernel.vxbin";

static uint32_t xm = 32;
static uint32_t xn = 128;
static uint32_t xk = 1024;

static vx_device_h device = nullptr;
static vx_buffer_h A_buffer = nullptr;
static vx_buffer_h B_buffer = nullptr;
static vx_buffer_h C_buffer = nullptr;
static vx_buffer_h krnl_buffer = nullptr;
static vx_buffer_h args_buffer = nullptr;
static kernel_arg_t kernel_arg = {};

static void cleanup() {
  if (device) {
    if (A_buffer) vx_mem_free(A_buffer);
    if (B_buffer) vx_mem_free(B_buffer);
    if (C_buffer) vx_mem_free(C_buffer);
    if (krnl_buffer) vx_mem_free(krnl_buffer);
    if (args_buffer) vx_mem_free(args_buffer);
    vx_dev_close(device);
  }
}

template <typename T>
static auto gen_value() {
  if constexpr (std::is_integral_v<typename T::dtype>) {
    return (typename T::dtype)rand();
  } else {
    auto fv = float(rand()) / RAND_MAX;
    return rv_ftoh_s(bit_cast<uint32_t>(fv), 0, nullptr);
  }
}

// Trivial generator that works for all template instantiations: just memset
// random bytes. We don't need numerical fidelity — only need the kernel to
// have something to compute on so its memory traffic is realistic.
static void random_bytes(void* p, size_t n) {
  auto* b = static_cast<uint8_t*>(p);
  for (size_t i = 0; i < n; ++i) b[i] = static_cast<uint8_t>(rand());
}

template <typename T>
static void convert_row_to_col_major(T *dst, uint32_t width, uint32_t height, const T *src) {
  for (uint32_t r = 0; r < height; ++r) {
    for (uint32_t c = 0; c < width; ++c) {
      dst[c * height + r] = src[r * width + c];
    }
  }
}

int main(int argc, char *argv[]) {
  auto bench = vx_bench::parse(argc, argv);

  optind = 1;
  int c;
  while ((c = getopt(argc, argv, "m:n:k:i:o:h")) != -1) {
    switch (c) {
      case 'm': xm = atoi(optarg); break;
      case 'n': xn = atoi(optarg); break;
      case 'k': xk = atoi(optarg); break;
      case 'h':
        printf("Usage: %s [--warmup=N] [--iterations=N] [--csv] "
               "[--output=PATH] [--output-append] "
               "[-m M] [-n N] [-k K]\n", argv[0]);
        return 0;
      default:
        printf("Usage: %s [--warmup=N] [--iterations=N] [--csv] "
               "[--output=PATH] [--output-append] "
               "[-m M] [-n N] [-k K]\n", argv[0]);
        return -1;
    }
  }

  if (!bench.csv) {
    printf("Sgemm-TCU Bench: M=%u N=%u K=%u  warmup=%d iterations=%d\n",
           xm, xn, xk, bench.warmup, bench.iterations);
  }

  std::srand(50);

  RT_CHECK(vx_dev_open(&device));

  uint64_t isa_flags;
  RT_CHECK(vx_dev_caps(device, VX_CAPS_ISA_FLAGS, &isa_flags));
  if ((isa_flags & VX_ISA_EXT_TCU) == 0) {
    printf("TCU extension not supported!\n");
    cleanup();
    return -1;
  }

  uint64_t NT;
  RT_CHECK(vx_dev_caps(device, VX_CAPS_NUM_THREADS, &NT));
  if (NT != NUM_THREADS) {
    printf("Error: device warp size (%lu) must match NUM_THREADS=%d\n",
           (unsigned long)NT, NUM_THREADS);
    cleanup();
    return -1;
  }

  uint32_t M = xm, N = xn, K = xk;
  if ((M % cfg::tileM) || (N % cfg::tileN) || (K % cfg::tileK)) {
    printf("Error: M/N/K must be multiples of tileM/tileN/tileK\n");
    cleanup();
    return -1;
  }

  size_t sizeA = M * K;
  size_t sizeB = K * N;
  size_t sizeC = M * N;

  kernel_arg.grid_dim[0] = N / cfg::tileN;
  kernel_arg.grid_dim[1] = M / cfg::tileM;
  kernel_arg.block_dim[0] = NT;
  kernel_arg.block_dim[1] = 1;
  kernel_arg.M = M;
  kernel_arg.N = N;
  kernel_arg.K = K;

  RT_CHECK(vx_mem_alloc(device, sizeA * sizeof(itype_t), VX_MEM_READ,  &A_buffer));
  RT_CHECK(vx_mem_address(A_buffer, &kernel_arg.A_addr));
  RT_CHECK(vx_mem_alloc(device, sizeB * sizeof(itype_t), VX_MEM_READ,  &B_buffer));
  RT_CHECK(vx_mem_address(B_buffer, &kernel_arg.B_addr));
  RT_CHECK(vx_mem_alloc(device, sizeC * sizeof(otype_t), VX_MEM_WRITE, &C_buffer));
  RT_CHECK(vx_mem_address(C_buffer, &kernel_arg.C_addr));

  std::vector<itype_t> h_A(sizeA);
  std::vector<itype_t> h_B(sizeB);
  random_bytes(h_A.data(), sizeA * sizeof(itype_t));
  random_bytes(h_B.data(), sizeB * sizeof(itype_t));

  RT_CHECK(vx_copy_to_dev(A_buffer, h_A.data(), 0, sizeA * sizeof(itype_t)));
  if constexpr (B_COL_MAJOR && vt::ITYPE::bits >= 8) {
    std::vector<itype_t> h_B_col(sizeB);
    convert_row_to_col_major(h_B_col.data(), N, K, h_B.data());
    RT_CHECK(vx_copy_to_dev(B_buffer, h_B_col.data(), 0, sizeB * sizeof(itype_t)));
  } else {
    RT_CHECK(vx_copy_to_dev(B_buffer, h_B.data(), 0, sizeB * sizeof(itype_t)));
  }
  RT_CHECK(vx_upload_kernel_file(device, kernel_file, &krnl_buffer));
  RT_CHECK(vx_upload_bytes(device, &kernel_arg, sizeof(kernel_arg_t), &args_buffer));

  // One run + sanity check (output not all zeros).
  RT_CHECK(vx_start(device, krnl_buffer, args_buffer));
  RT_CHECK(vx_ready_wait(device, VX_MAX_TIMEOUT));
  std::vector<uint8_t> h_C(sizeC * sizeof(otype_t));
  RT_CHECK(vx_copy_from_dev(h_C.data(), C_buffer, 0, h_C.size()));
  bool any_nonzero = false;
  for (uint8_t b : h_C) { if (b != 0) { any_nonzero = true; break; } }
  if (!any_nonzero) {
    printf("Validation FAILED: C buffer is all zero after kernel run\n");
    cleanup();
    return -1;
  }

  for (int i = 0; i < bench.warmup; ++i) {
    RT_CHECK(vx_start(device, krnl_buffer, args_buffer));
    RT_CHECK(vx_ready_wait(device, VX_MAX_TIMEOUT));
  }

  vx_bench::Stats stats;
  for (int i = 0; i < bench.iterations; ++i) {
    vx_bench::Stopwatch sw; sw.start();
    RT_CHECK(vx_start(device, krnl_buffer, args_buffer));
    RT_CHECK(vx_ready_wait(device, VX_MAX_TIMEOUT));
    stats.record(sw.stop_us());
  }

  stats.report("sgemm_tcu", bench);

  if (!bench.csv) {
    printf("\n[Performance]\n");
    vx_dump_perf(device, stdout);
  }

  cleanup();
  return 0;
}
