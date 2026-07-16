// Benchmark harness for sgemm_tcu. See softmax/bench_main.cpp for design notes.
//
// Compared with main.cpp this skips the structured-sparsity path and
// per-element correctness checks. Kernel correctness is covered by main.cpp;
// this harness only measures launch-to-ready latency.

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

int main(int argc, char *argv[]) {
  auto bench = vx_bench::parse(argc, argv);
  if (vx_bench::report_parse_error(bench)) {
    return -1;
  }

  optind = 1;
  int c;
  while ((c = getopt(argc, argv, "m:n:k:i:o:h")) != -1) {
    switch (c) {
      case 'm': xm = atoi(optarg); break;
      case 'n': xn = atoi(optarg); break;
      case 'k': xk = atoi(optarg); break;
      case 'h':
        printf("Usage: %s [--warmup=N] [--iterations=N] [--csv] "
               "[--output=PATH] [--output-append] [--power-measure-latency[=on|off]] "
               "[-m M] [-n N] [-k K]\n", argv[0]);
        return 0;
      default:
        printf("Usage: %s [--warmup=N] [--iterations=N] [--csv] "
               "[--output=PATH] [--output-append] [--power-measure-latency[=on|off]] "
               "[-m M] [-n N] [-k K]\n", argv[0]);
        return -1;
    }
  }

  if (!bench.csv) {
    printf("Sgemm-TCU Bench: M=%u N=%u K=%u  warmup=%d iterations=%d\n",
           xm, xn, xk, bench.warmup, bench.iterations);
  }

  std::srand(50);

  vx_bench::LatencyPowerMeasurement latency_power(bench);
  if (!latency_power.prestart()) {
    return -1;
  }

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
  uint32_t M_exec = align_up_u32(M, cfg::tileM);
  uint32_t N_exec = align_up_u32(N, cfg::tileN);
  uint32_t K_exec = align_up_u32(K, cfg::tileK);
  if (!bench.csv && ((M_exec != M) || (N_exec != N) || (K_exec != K))) {
    printf("Sgemm-TCU Bench padded shape: M=%u N=%u K=%u\n",
           M_exec, N_exec, K_exec);
  }

  size_t sizeA = M_exec * K_exec;
  size_t sizeB = K_exec * N_exec;
  size_t sizeC = M_exec * N_exec;

  kernel_arg.grid_dim[0] = N_exec / cfg::tileN;
  kernel_arg.grid_dim[1] = M_exec / cfg::tileM;
  kernel_arg.block_dim[0] = NT;
  kernel_arg.block_dim[1] = 1;
  kernel_arg.M = M_exec;
  kernel_arg.N = N_exec;
  kernel_arg.K = K_exec;

  RT_CHECK(vx_mem_alloc(device, sizeA * sizeof(itype_t), VX_MEM_READ,  &A_buffer));
  RT_CHECK(vx_mem_address(A_buffer, &kernel_arg.A_addr));
  RT_CHECK(vx_mem_alloc(device, sizeB * sizeof(itype_t), VX_MEM_READ,  &B_buffer));
  RT_CHECK(vx_mem_address(B_buffer, &kernel_arg.B_addr));
  RT_CHECK(vx_mem_alloc(device, sizeC * sizeof(otype_t), VX_MEM_WRITE, &C_buffer));
  RT_CHECK(vx_mem_address(C_buffer, &kernel_arg.C_addr));

  std::vector<itype_t> h_A(sizeA, 0);
  std::vector<itype_t> h_B(sizeB, 0);
  for (uint32_t m = 0; m < M; ++m) {
    random_bytes(&h_A[m * K_exec], K * sizeof(itype_t));
  }
  for (uint32_t k = 0; k < K; ++k) {
    random_bytes(&h_B[k * N_exec], N * sizeof(itype_t));
  }

  RT_CHECK(vx_copy_to_dev(A_buffer, h_A.data(), 0, sizeA * sizeof(itype_t)));
  RT_CHECK(vx_copy_to_dev(B_buffer, h_B.data(), 0, sizeB * sizeof(itype_t)));
  RT_CHECK(vx_upload_kernel_file(device, kernel_file, &krnl_buffer));
  kernel_arg.power_kernel_iterations = 1;
  RT_CHECK(vx_upload_bytes(device, &kernel_arg, sizeof(kernel_arg_t), &args_buffer));

  printf("Warmup Start\n"); fflush(stdout);
  for (int i = 0; i < bench.warmup; ++i) {
    RT_CHECK(vx_start(device, krnl_buffer, args_buffer));
    RT_CHECK(vx_ready_wait(device, VX_MAX_TIMEOUT));
    printf("Warmup iteration %0d/%0d\n", i+1, bench.warmup); fflush(stdout);
  }

  vx_bench::Stats stats;
  double first_latency_us = 0.0;
  vx_bench::IterationPerf first_iter_perf;
  if (!latency_power.begin_latency_window()) {
    cleanup();
    return -1;
  }
  printf("Start latency measurement.\n"); fflush(stdout);
  for (int i = 0; i < bench.iterations; ++i) {
    vx_bench::Stopwatch sw; sw.start();
    RT_CHECK(vx_start(device, krnl_buffer, args_buffer));
    RT_CHECK(vx_ready_wait(device, VX_MAX_TIMEOUT));
    const double elapsed_us = sw.stop_us();
    if (i == 0)
      first_latency_us = elapsed_us;
    stats.record(elapsed_us);
    const vx_bench::IterationPerf iter_perf =
        vx_bench::dump_iteration_perf(device, bench, i);
    if (i == 0)
      first_iter_perf = iter_perf;
    printf("iteration %0d/%0d, elapsed:%f\n", i+1, bench.iterations, stats.last()); fflush(stdout);
  }

  if (!latency_power.finish(stats.summary(), first_iter_perf)) {
    cleanup();
    return -1;
  }

  stats.report("sgemm_tcu", bench);

  if (!vx_bench::prepare_power_kernel_iterations(
          bench, kernel_arg, args_buffer, first_latency_us, first_iter_perf,
          "sgemm_tcu")) {
    cleanup();
    return -1;
  }

  if (!vx_bench::run_power_measurement(
          "sgemm_tcu", bench, device, krnl_buffer, args_buffer, bench.power_measure_latency)) {
    cleanup();
    return -1;
  }

  if (!bench.csv) {
    printf("\n[Performance]\n");
    vx_dump_perf(device, stdout);
  }

  cleanup();
  return 0;
}
