#include "common.h"
#include "../kv_cache_common/kv_cache_w4a16.h"
#include "../kv_cache_dequant_w4a16/host_variant.h"
#include "bench_util.h"
#include <vortex.h>
#include <algorithm>
#include <cinttypes>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <limits>
#include <string>
#include <vector>

namespace {

static constexpr uint64_t kBufferAlignment = 512;
static constexpr uint64_t kDefaultPowerWorkingSetMiB = 256;

vx_device_h device = nullptr;
vx_buffer_h krnl_buffer = nullptr;
vx_buffer_h args_buffer = nullptr;
vx_buffer_h src_buffer = nullptr;
vx_buffer_h dst_buffer = nullptr;
vx_buffer_h scale_buffer = nullptr;
vx_buffer_h zero_buffer = nullptr;

void cleanup() {
  if (src_buffer) vx_mem_free(src_buffer);
  if (dst_buffer) vx_mem_free(dst_buffer);
  if (scale_buffer) vx_mem_free(scale_buffer);
  if (zero_buffer) vx_mem_free(zero_buffer);
  if (krnl_buffer) vx_mem_free(krnl_buffer);
  if (args_buffer) vx_mem_free(args_buffer);
  if (device) vx_dev_close(device);
  src_buffer = nullptr;
  dst_buffer = nullptr;
  scale_buffer = nullptr;
  zero_buffer = nullptr;
  krnl_buffer = nullptr;
  args_buffer = nullptr;
  device = nullptr;
}

#define RT_CHECK(_expr)                                                     \
  do {                                                                      \
    int _ret = (_expr);                                                     \
    if (_ret == 0) break;                                                   \
    std::fprintf(stderr, "Error: '%s' returned %d!\n", #_expr, _ret);       \
    cleanup();                                                              \
    return -1;                                                              \
  } while (false)

uint64_t align_up(uint64_t value, uint64_t alignment) {
  return (value + alignment - 1u) / alignment * alignment;
}

bool checked_multiply(uint64_t lhs, uint64_t rhs, uint64_t* result) {
  if (lhs != 0 && rhs > std::numeric_limits<uint64_t>::max() / lhs) {
    return false;
  }
  *result = lhs * rhs;
  return true;
}

const char* mode_name(uint32_t mode) {
  switch (mode) {
  case DEQUANT_HBM_FULL:
    return "full";
  case DEQUANT_HBM_MEMORY:
    return "memory";
  case DEQUANT_HBM_COMPUTE:
    return "compute";
  case DEQUANT_HBM_CONTROL:
    return "control";
  default:
    return "invalid";
  }
}

uint32_t parse_mode(const char* value) {
  if (std::strcmp(value, "full") == 0) return DEQUANT_HBM_FULL;
  if (std::strcmp(value, "memory") == 0
      || std::strcmp(value, "memory_only") == 0) {
    return DEQUANT_HBM_MEMORY;
  }
  if (std::strcmp(value, "compute") == 0
      || std::strcmp(value, "compute_only") == 0) {
    return DEQUANT_HBM_COMPUTE;
  }
  if (std::strcmp(value, "control") == 0) return DEQUANT_HBM_CONTROL;
  return UINT32_MAX;
}

uint32_t memory_mix(uint8_t packed,
                    fp16_t scale0,
                    uint16_t zero0,
                    fp16_t scale1,
                    uint16_t zero1) {
  uint32_t value = (uint32_t)packed;
  value ^= (uint32_t)scale0 << 8;
  value ^= (uint32_t)zero0 << 16;
  value ^= ((uint32_t)scale1 << 1) | ((uint32_t)scale1 >> 15);
  return value ^ ((uint32_t)zero1 << 17) ^ ((uint32_t)zero1 >> 15);
}

#if defined(DEQUANT_HBM_ARITH_FP16)
using host_arith_t = _Float16;

host_arith_t host_scale_from_bits(fp16_t bits) {
  return kv_fp16_from_bits(bits);
}

fp16_t host_result_to_bits(host_arith_t value) {
  return kv_fp16_to_bits(value);
}

const char* arithmetic_name() {
  return "fp16";
}
#else
using host_arith_t = float;

host_arith_t host_scale_from_bits(fp16_t bits) {
  return fp16_to_float(bits);
}

fp16_t host_result_to_bits(host_arith_t value) {
  return float_to_fp16(value);
}

const char* arithmetic_name() {
  return "fp32";
}
#endif

int32_t decode_int4(uint8_t bits, uint32_t quant_mode) {
  return quant_mode == KV_QUANT_LEGACY_UINT4_ASYMMETRIC
      ? (int32_t)bits
      : (int32_t)kv_signed_int4(bits);
}

int32_t decode_zero(uint16_t bits, uint32_t quant_mode) {
  return quant_mode == KV_QUANT_SPINQUANT_SIGNED_SYMMETRIC
      ? 0
      : kv_signed_int16(bits);
}

uint32_t dequantize_pair(uint8_t packed,
                         fp16_t scale0_bits,
                         uint16_t zero0_bits,
                         fp16_t scale1_bits,
                         uint16_t zero1_bits,
                         uint32_t quant_mode) {
  const int32_t q0 = decode_int4(packed & 0x0fu, quant_mode);
  const int32_t q1 = decode_int4(packed >> 4, quant_mode);
  const int32_t zero0 = decode_zero(zero0_bits, quant_mode);
  const int32_t zero1 = decode_zero(zero1_bits, quant_mode);
  const host_arith_t scale0 = host_scale_from_bits(scale0_bits);
  const host_arith_t scale1 = host_scale_from_bits(scale1_bits);
  const fp16_t out0 = host_result_to_bits(
      (host_arith_t)(q0 - zero0) * scale0);
  const fp16_t out1 = host_result_to_bits(
      (host_arith_t)(q1 - zero1) * scale1);
  return (uint32_t)out0 | ((uint32_t)out1 << 16);
}

void initialize_inputs(std::vector<uint8_t>* packed,
                       std::vector<fp16_t>* scales,
                       std::vector<uint16_t>* zeros,
                       uint32_t K,
                       uint32_t N,
                       uint32_t quant_mode) {
  for (uint32_t k = 0; k < K; ++k) {
    for (uint32_t n = 0; n < N; n += 2) {
      const uint8_t q0 = (uint8_t)((k * 3u + n) & 0x0fu);
      const uint8_t q1 = (uint8_t)((k * 5u + n + 7u) & 0x0fu);
      (*packed)[(uint64_t)k * (N >> 1) + (n >> 1)] =
          q0 | (uint8_t)(q1 << 4);
    }
  }
  for (uint64_t qidx = 0; qidx < scales->size(); ++qidx) {
    (*scales)[qidx] = float_to_fp16(
        0.125f + (float)(qidx % 7u) * 0.03125f);
    const int32_t zero =
        quant_mode == KV_QUANT_SPINQUANT_SIGNED_SYMMETRIC
            ? 0
            : (quant_mode == KV_QUANT_LEGACY_UINT4_ASYMMETRIC
                   ? (int32_t)(qidx % 5u)
                   : (int32_t)(qidx % 5u) - 2);
    (*zeros)[qidx] = (uint16_t)(int16_t)zero;
  }
}

void build_expected(std::vector<uint32_t>* expected,
                    const std::vector<uint8_t>& packed,
                    const std::vector<fp16_t>& scales,
                    const std::vector<uint16_t>& zeros,
                    uint32_t K,
                    uint32_t N,
                    uint32_t QBLK,
                    uint32_t QDIR,
                    uint32_t quant_mode,
                    uint32_t mode) {
  const uint32_t row_pairs = N >> 1;
  for (uint32_t k = 0; k < K; ++k) {
    for (uint32_t n_pair = 0; n_pair < row_pairs; ++n_pair) {
      const uint32_t n0 = n_pair << 1;
      const uint32_t n1 = n0 + 1u;
      const uint64_t qidx0 = kv_qparam_index(k, n0, K, N, QBLK, QDIR);
      const uint64_t qidx1 = kv_qparam_index(k, n1, K, N, QBLK, QDIR);
      const uint8_t packed_value = packed[(uint64_t)k * row_pairs + n_pair];
      const uint64_t pair_idx = (uint64_t)k * row_pairs + n_pair;
      if (mode == DEQUANT_HBM_FULL) {
        (*expected)[pair_idx] = dequantize_pair(
            packed_value,
            scales[qidx0], zeros[qidx0],
            scales[qidx1], zeros[qidx1],
            quant_mode);
      } else {
        (*expected)[pair_idx] = memory_mix(
            packed_value,
            scales[qidx0], zeros[qidx0],
            scales[qidx1], zeros[qidx1]);
      }
    }
  }
}

void print_usage(const char* argv0) {
  std::printf(
      "Usage: %s [bench options] -k K -n N -q QBLK -d QDIR "
      "--mode full|memory|compute|control "
      "[--working-set-mb MiB] [--buffer-copies N] "
      "[--power-measure-latency[=on|off]] "
      "[--quant-mode legacy_uint4_asymmetric|signed_int4_asymmetric|"
      "signed_int4_symmetric]\n",
      argv0);
}

} // namespace

int main(int argc, char* argv[]) {
  auto bench = vx_bench::parse(argc, argv);
  if (vx_bench::report_parse_error(bench)) {
    return -1;
  }

  uint32_t K = 128;
  uint32_t N = 128;
  uint32_t QBLK = 32;
  uint32_t QDIR = 0;
  uint32_t quant_mode = KV_QUANT_LEGACY_UINT4_ASYMMETRIC;
  uint32_t mode = DEQUANT_HBM_FULL;
  uint64_t working_set_mib = vx_bench::power_enabled(bench)
      ? kDefaultPowerWorkingSetMiB
      : 0;
  uint32_t requested_buffer_copies = 0;

  for (int i = 1; i < argc; ++i) {
    if (std::strcmp(argv[i], "-k") == 0 && i + 1 < argc) {
      K = (uint32_t)std::strtoul(argv[++i], nullptr, 0);
    } else if (std::strcmp(argv[i], "-n") == 0 && i + 1 < argc) {
      N = (uint32_t)std::strtoul(argv[++i], nullptr, 0);
    } else if (std::strcmp(argv[i], "-q") == 0 && i + 1 < argc) {
      QBLK = (uint32_t)std::strtoul(argv[++i], nullptr, 0);
    } else if (std::strcmp(argv[i], "-d") == 0 && i + 1 < argc) {
      QDIR = (uint32_t)std::strtoul(argv[++i], nullptr, 0);
    } else if (std::strcmp(argv[i], "--mode") == 0 && i + 1 < argc) {
      mode = parse_mode(argv[++i]);
    } else if (std::strncmp(argv[i], "--mode=", 7) == 0) {
      mode = parse_mode(argv[i] + 7);
    } else if (std::strcmp(argv[i], "--working-set-mb") == 0
               && i + 1 < argc) {
      working_set_mib = std::strtoull(argv[++i], nullptr, 0);
    } else if (std::strncmp(argv[i], "--working-set-mb=", 17) == 0) {
      working_set_mib = std::strtoull(argv[i] + 17, nullptr, 0);
    } else if (std::strcmp(argv[i], "--buffer-copies") == 0
               && i + 1 < argc) {
      requested_buffer_copies =
          (uint32_t)std::strtoul(argv[++i], nullptr, 0);
    } else if (std::strncmp(argv[i], "--buffer-copies=", 16) == 0) {
      requested_buffer_copies =
          (uint32_t)std::strtoul(argv[i] + 16, nullptr, 0);
    } else if (std::strcmp(argv[i], "--quant-mode") == 0
               && i + 1 < argc) {
      quant_mode = parse_kv_cache_dequant_mode(argv[++i]);
    } else if (std::strncmp(argv[i], "--quant-mode=", 13) == 0) {
      quant_mode = parse_kv_cache_dequant_mode(argv[i] + 13);
    } else if (std::strcmp(argv[i], "-h") == 0
               || std::strcmp(argv[i], "--help") == 0) {
      print_usage(argv[0]);
      return 0;
    } else {
      std::fprintf(stderr, "ERROR: unknown argument: %s\n", argv[i]);
      print_usage(argv[0]);
      return 1;
    }
  }

  if (K == 0 || N == 0 || (N & 1u) != 0
      || !kv_cache_dequant_qblk_supported(QBLK)
      || QDIR > 1
      || quant_mode > KV_QUANT_SPINQUANT_SIGNED_SYMMETRIC
      || mode > DEQUANT_HBM_CONTROL) {
    std::fprintf(stderr,
        "ERROR: require K>0, positive even N, QBLK in {32,64,128}, "
        "QDIR in {0,1}, and valid mode/quant-mode\n");
    return 1;
  }

  uint64_t elements = 0;
  if (!checked_multiply(K, N, &elements)
      || elements > std::numeric_limits<size_t>::max()) {
    std::fprintf(stderr, "ERROR: K*N overflows host size_t\n");
    return 1;
  }
  const uint64_t packed_bytes = elements / 2u;
  const uint64_t dst_bytes = elements * sizeof(fp16_t);
  const uint64_t qparam_elems = kv_qparam_count(K, N, QBLK, QDIR);
  const uint64_t scale_bytes = qparam_elems * sizeof(fp16_t);
  const uint64_t zero_bytes = qparam_elems * sizeof(uint16_t);

  const uint64_t src_stride = align_up(packed_bytes, kBufferAlignment);
  const uint64_t dst_stride = align_up(dst_bytes, kBufferAlignment);
  const uint64_t scale_stride = align_up(scale_bytes, kBufferAlignment);
  const uint64_t zero_stride = align_up(zero_bytes, kBufferAlignment);
  const uint64_t bytes_per_copy =
      src_stride + dst_stride + scale_stride + zero_stride;

  uint32_t buffer_copies = 1;
  if (mode == DEQUANT_HBM_FULL || mode == DEQUANT_HBM_MEMORY) {
    if (requested_buffer_copies != 0) {
      buffer_copies = requested_buffer_copies;
    } else if (working_set_mib != 0) {
      const uint64_t working_set_bytes = working_set_mib << 20;
      const uint64_t copies64 =
          (working_set_bytes + bytes_per_copy - 1u) / bytes_per_copy;
      if (copies64 > UINT32_MAX) {
        std::fprintf(stderr, "ERROR: requested working set needs too many copies\n");
        return 1;
      }
      buffer_copies = std::max(1u, (uint32_t)copies64);
    }
  }

  uint64_t src_total = 0;
  uint64_t dst_total = 0;
  uint64_t scale_total = 0;
  uint64_t zero_total = 0;
  if (!checked_multiply(src_stride, buffer_copies, &src_total)
      || !checked_multiply(dst_stride, buffer_copies, &dst_total)
      || !checked_multiply(scale_stride, buffer_copies, &scale_total)
      || !checked_multiply(zero_stride, buffer_copies, &zero_total)) {
    std::fprintf(stderr, "ERROR: working-set allocation size overflow\n");
    return 1;
  }
  if (src_total > std::numeric_limits<size_t>::max()
      || dst_total > std::numeric_limits<size_t>::max()
      || scale_total > std::numeric_limits<size_t>::max()
      || zero_total > std::numeric_limits<size_t>::max()) {
    std::fprintf(stderr, "ERROR: working-set allocation exceeds host size_t\n");
    return 1;
  }

  const uint64_t logical_read_bytes = packed_bytes + scale_bytes
      + (quant_mode == KV_QUANT_SPINQUANT_SIGNED_SYMMETRIC ? 0 : zero_bytes);
  const uint64_t logical_write_bytes = dst_bytes;
  std::printf(
      "dequant_hbm_energy mode=%s arithmetic=%s K=%u N=%u QBLK=%u "
      "QDIR=%u quant_mode=%s\n",
      mode_name(mode), arithmetic_name(), K, N, QBLK, QDIR,
      kv_cache_dequant_mode_name(quant_mode));
  std::printf(
      "equivalent_traffic elements=%" PRIu64 " qparams=%" PRIu64
      " read_bytes=%" PRIu64 " write_bytes=%" PRIu64
      " total_bytes=%" PRIu64 "\n",
      elements, qparam_elems, logical_read_bytes, logical_write_bytes,
      logical_read_bytes + logical_write_bytes);
  std::printf(
      "working_set copies=%u bytes_per_copy=%" PRIu64
      " allocated_bytes=%" PRIu64 "\n",
      buffer_copies, bytes_per_copy,
      src_total + dst_total + scale_total + zero_total);

  std::vector<uint8_t> h_packed((size_t)packed_bytes);
  std::vector<fp16_t> h_scales((size_t)qparam_elems);
  std::vector<uint16_t> h_zeros((size_t)qparam_elems);
  std::vector<uint32_t> h_output((size_t)(elements / 2u));
  std::vector<uint32_t> h_expected((size_t)(elements / 2u));
  initialize_inputs(&h_packed, &h_scales, &h_zeros, K, N, quant_mode);
  if (mode == DEQUANT_HBM_FULL || mode == DEQUANT_HBM_MEMORY) {
    build_expected(
        &h_expected, h_packed, h_scales, h_zeros,
        K, N, QBLK, QDIR, quant_mode, mode);
  }

  vx_bench::LatencyPowerMeasurement latency_power(bench);
  if (!latency_power.prestart()) {
    return -1;
  }

  RT_CHECK(vx_dev_open(&device));
  RT_CHECK(vx_upload_kernel_file(device, "kernel.vxbin", &krnl_buffer));
  RT_CHECK(vx_mem_alloc(device, src_total, VX_MEM_READ, &src_buffer));
  RT_CHECK(vx_mem_alloc(device, dst_total, VX_MEM_READ_WRITE, &dst_buffer));
  RT_CHECK(vx_mem_alloc(device, scale_total, VX_MEM_READ, &scale_buffer));
  RT_CHECK(vx_mem_alloc(device, zero_total, VX_MEM_READ, &zero_buffer));

  {
    std::vector<uint8_t> src_upload((size_t)src_total, 0);
    std::vector<uint8_t> scale_upload((size_t)scale_total, 0);
    std::vector<uint8_t> zero_upload((size_t)zero_total, 0);
    for (uint32_t copy = 0; copy < buffer_copies; ++copy) {
      std::memcpy(
          src_upload.data() + (uint64_t)copy * src_stride,
          h_packed.data(), (size_t)packed_bytes);
      std::memcpy(
          scale_upload.data() + (uint64_t)copy * scale_stride,
          h_scales.data(), (size_t)scale_bytes);
      std::memcpy(
          zero_upload.data() + (uint64_t)copy * zero_stride,
          h_zeros.data(), (size_t)zero_bytes);
    }
    RT_CHECK(vx_copy_to_dev(
        src_buffer, src_upload.data(), 0, src_total));
    RT_CHECK(vx_copy_to_dev(
        scale_buffer, scale_upload.data(), 0, scale_total));
    RT_CHECK(vx_copy_to_dev(
        zero_buffer, zero_upload.data(), 0, zero_total));
  }

  uint64_t num_cores = 0;
  uint64_t num_warps = 0;
  uint64_t num_threads = 0;
  RT_CHECK(vx_dev_caps(device, VX_CAPS_NUM_CORES, &num_cores));
  RT_CHECK(vx_dev_caps(device, VX_CAPS_NUM_WARPS, &num_warps));
  RT_CHECK(vx_dev_caps(device, VX_CAPS_NUM_THREADS, &num_threads));
  const uint32_t threads_per_block = kv_cache_dequant_threads_per_block(
      num_warps, num_threads);
  const uint32_t work_items = kv_cache_dequant_work_items(
      K, N, QBLK, QDIR, (uint32_t)num_threads);
  const uint32_t blocks = kv_cache_dequant_blocks(
      work_items, threads_per_block, num_cores, num_warps);

  kernel_arg_t arg = {};
  arg.kernel_id = KERNEL_DEQUANT_HBM_ENERGY;
  arg.grid_dim[0] = blocks;
  arg.grid_dim[1] = 1;
  arg.grid_dim[2] = 1;
  arg.block_dim[0] = threads_per_block;
  arg.block_dim[1] = 1;
  arg.block_dim[2] = 1;
  RT_CHECK(vx_mem_address(src_buffer, &arg.src_addr));
  RT_CHECK(vx_mem_address(dst_buffer, &arg.dst_addr));
  RT_CHECK(vx_mem_address(scale_buffer, &arg.scale_addr));
  RT_CHECK(vx_mem_address(zero_buffer, &arg.zero_addr));
  arg.src_stride = src_stride;
  arg.dst_stride = dst_stride;
  arg.scale_stride = scale_stride;
  arg.zero_stride = zero_stride;
  arg.K = K;
  arg.N = N;
  arg.QBLK = QBLK;
  arg.QDIR = QDIR;
  arg.quant_mode = quant_mode;
  arg.mode = mode;
  arg.buffer_copies = buffer_copies;
  arg.power_kernel_iterations = 1;
  RT_CHECK(vx_upload_bytes(device, &arg, sizeof(arg), &args_buffer));

  std::printf("Warmup Start\n");
  std::fflush(stdout);
  for (int i = 0; i < bench.warmup; ++i) {
    RT_CHECK(vx_start(device, krnl_buffer, args_buffer));
    RT_CHECK(vx_ready_wait(device, VX_MAX_TIMEOUT));
  }

  vx_bench::Stats stats;
  double first_latency_us = 0.0;
  vx_bench::IterationPerf first_iter_perf;
  if (!latency_power.begin_latency_window()) {
    cleanup();
    return -1;
  }
  for (int i = 0; i < bench.iterations; ++i) {
    vx_bench::Stopwatch stopwatch;
    stopwatch.start();
    RT_CHECK(vx_start(device, krnl_buffer, args_buffer));
    RT_CHECK(vx_ready_wait(device, VX_MAX_TIMEOUT));
    const double elapsed_us = stopwatch.stop_us();
    stats.record(elapsed_us);
    const auto iteration_perf =
        vx_bench::dump_iteration_perf(device, bench, i);
    if (i == 0) {
      first_latency_us = elapsed_us;
      first_iter_perf = iteration_perf;
    }
  }
  if (!latency_power.finish(stats.summary(), first_iter_perf)) {
    cleanup();
    return -1;
  }

  stats.report("dequant_hbm_energy", bench);

  if (mode == DEQUANT_HBM_FULL || mode == DEQUANT_HBM_MEMORY) {
    RT_CHECK(vx_copy_from_dev(
        h_output.data(), dst_buffer, 0, dst_bytes));
    size_t errors = 0;
    for (size_t index = 0; index < h_output.size(); ++index) {
      if (h_output[index] != h_expected[index]) {
        if (errors < 8) {
          std::fprintf(stderr,
              "mismatch[%zu]: got=0x%08x expected=0x%08x\n",
              index, h_output[index], h_expected[index]);
        }
        ++errors;
      }
    }
    if (errors != 0) {
      std::fprintf(stderr, "FAILED: %zu output mismatches\n", errors);
      cleanup();
      return 1;
    }
  }

  if (!vx_bench::prepare_power_kernel_iterations(
          bench, arg, args_buffer, first_latency_us, first_iter_perf,
          "dequant_hbm_energy")) {
    cleanup();
    return -1;
  }

  if (vx_bench::power_enabled(bench)
      && (mode == DEQUANT_HBM_FULL || mode == DEQUANT_HBM_MEMORY)
      && arg.power_kernel_iterations < buffer_copies) {
    arg.power_kernel_iterations = buffer_copies;
    bench.power_kernel_iterations = (int)buffer_copies;
    std::fprintf(stderr,
        "[power] raising kernel iterations to %u for one complete "
        "working-set sweep\n",
        buffer_copies);
    RT_CHECK(vx_copy_to_dev(args_buffer, &arg, 0, sizeof(arg)));
  }

  if (!vx_bench::run_power_measurement(
          "dequant_hbm_energy", bench, device, krnl_buffer, args_buffer,
          bench.power_measure_latency)) {
    cleanup();
    return -1;
  }

  cleanup();
  std::printf("PASSED!\n");
  return 0;
}
