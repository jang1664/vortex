#include "common.h"
#include "../kv_cache_common/kv_cache_w4a16.h"
#include "bench_util.h"
#include <vortex.h>
#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

vx_device_h device = nullptr;
vx_buffer_h krnl_buffer = nullptr;
vx_buffer_h args_buffer = nullptr;
vx_buffer_h src_buffer = nullptr;
vx_buffer_h dst_buffer = nullptr;
vx_buffer_h scale_buffer = nullptr;
vx_buffer_h zero_buffer = nullptr;

#define RT_CHECK(_expr)                                                     \
  do {                                                                      \
    int _ret = _expr;                                                       \
    if (0 == _ret)                                                          \
      break;                                                                \
    printf("Error: '%s' returned %d!\n", #_expr, (int)_ret);                \
    cleanup();                                                              \
    exit(-1);                                                               \
  } while (false)

static void cleanup() {
  if (src_buffer) vx_mem_free(src_buffer);
  if (dst_buffer) vx_mem_free(dst_buffer);
  if (scale_buffer) vx_mem_free(scale_buffer);
  if (zero_buffer) vx_mem_free(zero_buffer);
  if (krnl_buffer) vx_mem_free(krnl_buffer);
  if (args_buffer) vx_mem_free(args_buffer);
  if (device) vx_dev_close(device);
}

int main(int argc, char *argv[]) {
  auto bench = vx_bench::parse(argc, argv);
  if (vx_bench::report_parse_error(bench)) {
    return -1;
  }
  uint32_t K = 128;
  uint32_t N = 128;
  uint32_t QBLK = 32;
  uint32_t QDIR = 0;
  uint32_t WTRANS = 0;
  for (int i = 1; i < argc; ++i) {
    if (strcmp(argv[i], "-k") == 0) K = atoi(argv[++i]);
    else if (strcmp(argv[i], "-n") == 0) N = atoi(argv[++i]);
    else if (strcmp(argv[i], "-q") == 0) QBLK = atoi(argv[++i]);
    else if (strcmp(argv[i], "-d") == 0) QDIR = atoi(argv[++i]);
    else if (strcmp(argv[i], "-t") == 0) WTRANS = atoi(argv[++i]);
    else if (strcmp(argv[i], "-h") == 0 || strcmp(argv[i], "--help") == 0) {
      printf("Usage: %s [--warmup=N] [--iterations=N] [--csv] "
             "[--output=PATH] [--output-append] "
             "[-k K] [-n N] [-q QBLK] [-d QDIR] [-t WTRANS]\n", argv[0]);
      return 0;
    }
  }

  const size_t dst_elems = (size_t)K * N;
  const size_t packed_bytes = dst_elems / 2;
  const size_t qparam_elems = kv_qparam_count(K, N, QBLK, QDIR);
  std::vector<uint8_t> h_packed(packed_bytes, 0x84);
  std::vector<fp16_t> h_scales(qparam_elems, float_to_fp16(0.125f));
  std::vector<int16_t> h_zeros(qparam_elems, 3);

  RT_CHECK(vx_dev_open(&device));
  RT_CHECK(vx_upload_kernel_file(device, "kernel.vxbin", &krnl_buffer));
  RT_CHECK(vx_mem_alloc(device, packed_bytes, VX_MEM_READ, &src_buffer));
  RT_CHECK(vx_mem_alloc(device, dst_elems * sizeof(fp16_t), VX_MEM_WRITE, &dst_buffer));
  RT_CHECK(vx_mem_alloc(device, qparam_elems * sizeof(fp16_t), VX_MEM_READ, &scale_buffer));
  RT_CHECK(vx_mem_alloc(device, qparam_elems * sizeof(int16_t), VX_MEM_READ, &zero_buffer));
  RT_CHECK(vx_copy_to_dev(src_buffer, h_packed.data(), 0, packed_bytes));
  RT_CHECK(vx_copy_to_dev(scale_buffer, h_scales.data(), 0, qparam_elems * sizeof(fp16_t)));
  RT_CHECK(vx_copy_to_dev(zero_buffer, h_zeros.data(), 0, qparam_elems * sizeof(int16_t)));

  uint64_t num_cores = 0;
  uint64_t num_warps = 0;
  uint64_t num_threads = 0;
  RT_CHECK(vx_dev_caps(device, VX_CAPS_NUM_CORES, &num_cores));
  RT_CHECK(vx_dev_caps(device, VX_CAPS_NUM_WARPS, &num_warps));
  RT_CHECK(vx_dev_caps(device, VX_CAPS_NUM_THREADS, &num_threads));
  uint32_t tpb = std::min(256u, (uint32_t)(num_warps * num_threads));
  uint32_t blocks = std::min(
      (uint32_t)((dst_elems + tpb - 1) / tpb),
      std::max(1u, (uint32_t)num_cores * 4u));

  kernel_arg_t arg = {};
  arg.kernel_id = KERNEL_KV_CACHE_DEQUANT_W4A16;
  arg.grid_dim[0] = blocks;
  arg.grid_dim[1] = 1;
  arg.grid_dim[2] = 1;
  arg.block_dim[0] = tpb;
  arg.block_dim[1] = 1;
  arg.block_dim[2] = 1;
  RT_CHECK(vx_mem_address(src_buffer, &arg.src_addr));
  RT_CHECK(vx_mem_address(dst_buffer, &arg.dst_addr));
  RT_CHECK(vx_mem_address(scale_buffer, &arg.scale_addr));
  RT_CHECK(vx_mem_address(zero_buffer, &arg.zero_addr));
  arg.K = K;
  arg.N = N;
  arg.QBLK = QBLK;
  arg.QDIR = QDIR;
  arg.WTRANS = WTRANS;
  RT_CHECK(vx_upload_bytes(device, &arg, sizeof(arg), &args_buffer));

  printf("Warmup Start\n"); fflush(stdout);
  for (int i = 0; i < bench.warmup; ++i) {
    RT_CHECK(vx_start(device, krnl_buffer, args_buffer));
    RT_CHECK(vx_ready_wait(device, VX_MAX_TIMEOUT));
    printf("Warmup iteration %0d/%0d\n", i+1, bench.warmup); fflush(stdout);
  }

  vx_bench::Stats stats;
  printf("Start latency measurement.\n"); fflush(stdout);
  for (int i = 0; i < bench.iterations; ++i) {
    vx_bench::Stopwatch sw;
    sw.start();
    RT_CHECK(vx_start(device, krnl_buffer, args_buffer));
    RT_CHECK(vx_ready_wait(device, VX_MAX_TIMEOUT));
    stats.record(sw.stop_us());
    vx_bench::dump_iteration_perf(device, bench, i);
    printf("iteration %0d/%0d, elapsed:%f\n", i+1, bench.iterations, stats.last()); fflush(stdout);
  }
  stats.report("kv_cache_dequant_w4a16", bench);

  if (!vx_bench::run_power_measurement(
          "kv_cache_dequant_w4a16", bench, device, krnl_buffer, args_buffer)) {
    cleanup();
    return -1;
  }
  cleanup();
  return 0;
}
