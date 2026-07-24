#include "host_common.h"
#include "bench_util.h"
#include <vortex.h>
#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

#ifndef KV_CACHE_QUANT_LAYOUT_FUSED_VARIANT_TAG
#define KV_CACHE_QUANT_LAYOUT_FUSED_VARIANT_TAG 0
#endif

vx_device_h device = nullptr;
vx_buffer_h krnl_buffer = nullptr;
vx_buffer_h args_buffer = nullptr;
vx_buffer_h src_buffer = nullptr;
vx_buffer_h weight_buffer = nullptr;
vx_buffer_h scale_buffer = nullptr;
vx_buffer_h zero_buffer = nullptr;
vx_buffer_h logical_scale_buffer = nullptr;
vx_buffer_h logical_zero_buffer = nullptr;

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
  if (weight_buffer) vx_mem_free(weight_buffer);
  if (scale_buffer) vx_mem_free(scale_buffer);
  if (zero_buffer) vx_mem_free(zero_buffer);
  if (logical_scale_buffer) vx_mem_free(logical_scale_buffer);
  if (logical_zero_buffer) vx_mem_free(logical_zero_buffer);
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
  uint32_t DMA_MT = DEFAULT_DMA_MT;
  uint32_t DMA_KT = DEFAULT_DMA_KT;
  uint32_t DMA_NT = DEFAULT_DMA_NT;
  uint32_t QDIR = 0;
  uint32_t WTRANS = 1;
  uint32_t GEMM_QDIR = 0;
  uint32_t SOURCE_TRANSPOSED = 0;
  uint32_t quant_mode = KV_QUANT_LEGACY_UINT4_ASYMMETRIC;
  uint32_t source_total_n = 0;
  uint32_t head_col_offset = 0;
  bool emit_correction_qparams = false;
  bool append_update = false;
  uint32_t cache_capacity = 0;
  uint32_t cache_position = 0;
  bool gemm_qdir_set = false;
  uint32_t src_layout = SRC_LAYOUT_ROW_MAJOR;
  for (int i = 1; i < argc; ++i) {
    if (strcmp(argv[i], "-k") == 0) K = atoi(argv[++i]);
    else if (strcmp(argv[i], "-n") == 0) N = atoi(argv[++i]);
    else if (strcmp(argv[i], "-q") == 0) QBLK = atoi(argv[++i]);
    else if (strcmp(argv[i], "-d") == 0) QDIR = atoi(argv[++i]);
    else if (strcmp(argv[i], "-t") == 0) WTRANS = atoi(argv[++i]);
    else if (strcmp(argv[i], "--mt") == 0) DMA_MT = atoi(argv[++i]);
    else if (strncmp(argv[i], "--mt=", 5) == 0) DMA_MT = atoi(argv[i] + 5);
    else if (strcmp(argv[i], "--kt") == 0) DMA_KT = atoi(argv[++i]);
    else if (strncmp(argv[i], "--kt=", 5) == 0) DMA_KT = atoi(argv[i] + 5);
    else if (strcmp(argv[i], "--nt") == 0) DMA_NT = atoi(argv[++i]);
    else if (strncmp(argv[i], "--nt=", 5) == 0) DMA_NT = atoi(argv[i] + 5);
    else if (strcmp(argv[i], "--gemm-qdir") == 0) {
      GEMM_QDIR = atoi(argv[++i]);
      gemm_qdir_set = true;
    }
    else if (strncmp(argv[i], "--gemm-qdir=", 13) == 0) {
      GEMM_QDIR = atoi(argv[i] + 13);
      gemm_qdir_set = true;
    }
    else if (strcmp(argv[i], "--source-transposed") == 0) SOURCE_TRANSPOSED = 1;
    else if (strcmp(argv[i], "--quant-mode") == 0) quant_mode = parse_quant_mode(argv[++i]);
    else if (strncmp(argv[i], "--quant-mode=", 13) == 0) quant_mode = parse_quant_mode(argv[i] + 13);
    else if (strcmp(argv[i], "--source-total-n") == 0) source_total_n = atoi(argv[++i]);
    else if (strncmp(argv[i], "--source-total-n=", 17) == 0) source_total_n = atoi(argv[i] + 17);
    else if (strcmp(argv[i], "--head-col-offset") == 0) head_col_offset = atoi(argv[++i]);
    else if (strncmp(argv[i], "--head-col-offset=", 18) == 0) head_col_offset = atoi(argv[i] + 18);
    else if (strcmp(argv[i], "--emit-correction-qparams") == 0) emit_correction_qparams = true;
    else if (strcmp(argv[i], "--cache-update") == 0) {
      const char* mode = argv[++i];
      if (strcmp(mode, "full") == 0) append_update = false;
      else if (strcmp(mode, "append") == 0) append_update = true;
      else {
        printf("ERROR: --cache-update must be full or append\n");
        return 1;
      }
    }
    else if (strncmp(argv[i], "--cache-update=", 15) == 0) {
      const char* mode = argv[i] + 15;
      if (strcmp(mode, "full") == 0) append_update = false;
      else if (strcmp(mode, "append") == 0) append_update = true;
      else {
        printf("ERROR: --cache-update must be full or append\n");
        return 1;
      }
    }
    else if (strcmp(argv[i], "--cache-capacity") == 0) cache_capacity = atoi(argv[++i]);
    else if (strncmp(argv[i], "--cache-capacity=", 17) == 0) cache_capacity = atoi(argv[i] + 17);
    else if (strcmp(argv[i], "--cache-position") == 0) cache_position = atoi(argv[++i]);
    else if (strncmp(argv[i], "--cache-position=", 17) == 0) cache_position = atoi(argv[i] + 17);
    else if (strcmp(argv[i], "--layout-from") == 0) src_layout = parse_src_layout(argv[++i]);
    else if (strncmp(argv[i], "--layout-from=", 14) == 0) src_layout = parse_src_layout(argv[i] + 14);
    else if (strcmp(argv[i], "-h") == 0 || strcmp(argv[i], "--help") == 0) {
      printf("Usage: %s [--warmup=N] [--iterations=N] [--csv] "
             "[--output=PATH] [--output-append] [--power-measure-latency[=on|off]] "
             "[-k K] [-n N] [-q QBLK] [-d QDIR] [-t WTRANS] "
             "[--mt MT] [--kt KT] [--nt NT] "
             "[--gemm-qdir QDIR] [--source-transposed] "
             "[--layout-from row_major_fp16|gemm_c_tiled] "
             "[--quant-mode legacy_uint4_asymmetric|spinquant_signed_asymmetric|spinquant_signed_symmetric] "
             "[--source-total-n N] [--head-col-offset N] [--emit-correction-qparams] "
             "[--cache-update full|append] [--cache-capacity K] [--cache-position K]\n",
             argv[0]);
      return 0;
    }
  }
  if (!gemm_qdir_set) GEMM_QDIR = QDIR;
  if (source_total_n == 0) source_total_n = N;
  if (append_update
      && (K != 1 || QDIR != 1 || QBLK < N
          || cache_capacity == 0 || cache_position >= cache_capacity)) {
    printf("ERROR: append requires K=1, QDIR=1, one source quant group "
           "(QBLK>=N), and cache-position < non-zero cache-capacity\n");
    return 1;
  }
  if (!valid_fused_quant_shape(K, N, QBLK, QDIR, WTRANS, GEMM_QDIR,
                               SOURCE_TRANSPOSED, quant_mode,
                               source_total_n, head_col_offset)) {
    printf("ERROR: require non-zero K/N, even N, pow2 QBLK, "
           "source_QDIR/GEMM_QDIR/WTRANS in {0,1}, and source-transposed requires WTRANS=1\n");
    return 1;
  }
  if (!is_pow2_u32(DMA_MT) || !is_pow2_u32(DMA_KT) || !is_pow2_u32(DMA_NT) ||
      (DMA_KT & (TILE_DMA_MXU_KT - 1u)) != 0 ||
      (DMA_NT & (TILE_DMA_MXU_NT - 1u)) != 0 ||
      (GEMM_QDIR == 0 && DMA_KT < QBLK)) {
    printf("ERROR: MT/KT/NT must be powers of two, KT%%MXU_KT=0, "
           "NT%%MXU_NT=0, and GEMM_QDIR=0 requires KT>=QBLK\n");
    return 1;
  }

  const size_t src_elems = (size_t)K * source_total_n;
  const uint32_t output_K = append_update ? cache_capacity : K;
  const size_t weight_bytes = weight_total_bytes_host(
      output_K, N, SOURCE_TRANSPOSED);
  const size_t scale_bytes = scale_total_bytes_host(
      output_K, N, QBLK, GEMM_QDIR,
      SOURCE_TRANSPOSED, DMA_KT, DMA_NT);
  std::vector<fp16_t> h_src((size_t)K * N);
  init_src(h_src);
  std::vector<fp16_t> h_src_combined(src_elems, 0);
  for (uint32_t k = 0; k < K; ++k) {
    std::copy_n(h_src.begin() + (uint64_t)k * N, N,
                h_src_combined.begin() + (uint64_t)k * source_total_n + head_col_offset);
  }
  std::vector<fp16_t> h_src_device(src_elems);
  pack_src_for_layout(h_src_combined, h_src_device, K, source_total_n,
                      src_layout, DMA_MT);
  std::vector<uint8_t> initial_weight(weight_bytes, 0);
  std::vector<uint8_t> initial_scale(scale_bytes, 0);
  std::vector<uint8_t> initial_zero(scale_bytes, 0);

  vx_bench::LatencyPowerMeasurement latency_power(bench);
  if (!latency_power.prestart()) {
    return -1;
  }

  RT_CHECK(vx_dev_open(&device));
  RT_CHECK(vx_upload_kernel_file(device, "kernel.vxbin", &krnl_buffer));
  RT_CHECK(vx_mem_alloc(device, src_elems * sizeof(fp16_t), VX_MEM_READ, &src_buffer));
  const uint32_t output_mem_flags =
      append_update ? VX_MEM_READ_WRITE : VX_MEM_WRITE;
  RT_CHECK(vx_mem_alloc(device, weight_bytes, output_mem_flags, &weight_buffer));
  RT_CHECK(vx_mem_alloc(device, scale_bytes, output_mem_flags, &scale_buffer));
  RT_CHECK(vx_mem_alloc(device, scale_bytes, output_mem_flags, &zero_buffer));
  if (emit_correction_qparams) {
    const size_t logical_bytes =
        kv_qparam_count(output_K, N, QBLK, QDIR) * sizeof(fp16_t);
    RT_CHECK(vx_mem_alloc(
        device, logical_bytes, output_mem_flags, &logical_scale_buffer));
    RT_CHECK(vx_mem_alloc(
        device, logical_bytes, output_mem_flags, &logical_zero_buffer));
  }
  RT_CHECK(vx_copy_to_dev(src_buffer, h_src_device.data(), 0, src_elems * sizeof(fp16_t)));
  if (append_update) {
    RT_CHECK(vx_copy_to_dev(
        weight_buffer, initial_weight.data(), 0, weight_bytes));
    RT_CHECK(vx_copy_to_dev(
        scale_buffer, initial_scale.data(), 0, scale_bytes));
    RT_CHECK(vx_copy_to_dev(
        zero_buffer, initial_zero.data(), 0, scale_bytes));
  }

  uint64_t num_cores = 0;
  uint64_t num_warps = 0;
  uint64_t num_threads = 0;
  RT_CHECK(vx_dev_caps(device, VX_CAPS_NUM_CORES, &num_cores));
  RT_CHECK(vx_dev_caps(device, VX_CAPS_NUM_WARPS, &num_warps));
  RT_CHECK(vx_dev_caps(device, VX_CAPS_NUM_THREADS, &num_threads));
  const uint32_t tpb =
      append_update && KV_CACHE_QUANT_LAYOUT_FUSED_VARIANT_TAG >= 2
          ? (uint32_t)num_threads
          : std::min(256u, (uint32_t)(num_warps * num_threads));

  kernel_arg_t arg = {};
  const uint32_t max_slot_elems = max_scale_slot_bytes_host(output_K, N, QBLK, GEMM_QDIR,
                                                            SOURCE_TRANSPOSED, DMA_KT, DMA_NT)
                                / TILE_ELEM_BYTES;
  const uint32_t out_K = padded_qparam_K_host(
      output_K, N, QBLK, GEMM_QDIR, SOURCE_TRANSPOSED);
  const uint32_t out_N = padded_qparam_N_host(
      output_K, N, QBLK, GEMM_QDIR, SOURCE_TRANSPOSED);
  const uint32_t n_dma_tiles = ceil_div_pow2_u32(out_N, DMA_NT);
  const uint32_t k_tiles = ceil_div_pow2_u32(out_K, DMA_KT);
  const uint32_t qparam_work = k_tiles * n_dma_tiles * max_slot_elems;
  const uint32_t full_work_items =
      std::max((uint32_t)weight_bytes, qparam_work);
  const uint32_t append_work_items =
      std::max(N >> 1, GEMM_QDIR == 0 ? 1u : N >> 5);
  const uint32_t work_items =
      append_update ? append_work_items : full_work_items;
  const uint32_t blocks =
      append_update && KV_CACHE_QUANT_LAYOUT_FUSED_VARIANT_TAG >= 2
          ? 1u
          : std::min(
                (work_items + tpb - 1u) / tpb,
                std::max(1u, (uint32_t)num_cores * 4u));
  if (!init_kernel_arg(arg, output_K, N, QBLK, QDIR, WTRANS, GEMM_QDIR,
                       SOURCE_TRANSPOSED, src_layout, DMA_MT, DMA_KT, DMA_NT,
                       blocks, tpb, quant_mode, source_total_n, head_col_offset)) {
    printf("ERROR: failed to initialize kernel args\n");
    cleanup();
    return 1;
  }
  if (append_update) {
    arg.K = 1;
    arg.src_total_K = 1;
    arg.persistent_mode = 1;
    arg.cache_capacity = cache_capacity;
    arg.cache_position = cache_position;
  }
  RT_CHECK(vx_mem_address(src_buffer, &arg.src_addr));
  RT_CHECK(vx_mem_address(weight_buffer, &arg.weight_addr));
  RT_CHECK(vx_mem_address(scale_buffer, &arg.scale_addr));
  RT_CHECK(vx_mem_address(zero_buffer, &arg.zero_addr));
  if (emit_correction_qparams) {
    RT_CHECK(vx_mem_address(logical_scale_buffer, &arg.logical_scale_addr));
    RT_CHECK(vx_mem_address(logical_zero_buffer, &arg.logical_zero_addr));
  }
  arg.power_kernel_iterations = 1;
  RT_CHECK(vx_upload_bytes(device, &arg, sizeof(arg), &args_buffer));

  printf("cache_update=%s cache_capacity=%u cache_position=%u\n",
         append_update ? "append" : "full", output_K, cache_position);
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
    vx_bench::Stopwatch sw;
    sw.start();
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

  stats.report("kv_cache_quant_layout_fused_w4a16", bench);

  if (!vx_bench::prepare_power_kernel_iterations(
          bench, arg, args_buffer, first_latency_us, first_iter_perf,
          "kv_cache_quant_layout_fused_w4a16")) {
    cleanup();
    return -1;
  }

  if (!vx_bench::run_power_measurement(
          "kv_cache_quant_layout_fused_w4a16", bench, device, krnl_buffer, args_buffer, bench.power_measure_latency)) {
    cleanup();
    return -1;
  }
  cleanup();
  return 0;
}
