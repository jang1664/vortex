// bench_main.cpp — latency benchmark for the softmax kernel.
//
// Builds the `softmax_bench` host binary. Runs the kernel many times under
// the bench_harness (warmup + iters), reports min/median/p95/max/stddev, and
// (optionally) appends per-iteration samples to a CSV file for downstream
// aggregation.
//
// Bench-only flags (consumed by parse_bench_opts and stripped from argv):
//   --iters N           timed iterations (default 20)
//   --warmup N          warmup iterations (default 3)
//   --csv  <path>       append per-iter samples
//   --label <str>       identifier (e.g. "softmax@xclbin_v3")
//
// Workload-shape flags (parsed locally, same as test_main.cpp):
//   -batch N -heads H -seqq Q -seqk K -mask 0|1 -scale S

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>
#include <vortex.h>

#include "bench_harness.h"
#include "driver.h"

namespace {

void initialize_random(std::vector<float>& vec) {
  for (auto& val : vec) {
    val = static_cast<float>(rand()) / RAND_MAX * 4.0f - 2.0f;  // [-2, 2]
  }
}

bool parse_workload_args(int argc, char** argv, SoftmaxConfig& cfg) {
  for (int i = 1; i < argc; ++i) {
    if      (std::strcmp(argv[i], "-batch") == 0 && i + 1 < argc) cfg.batch_size = std::atoi(argv[++i]);
    else if (std::strcmp(argv[i], "-heads") == 0 && i + 1 < argc) cfg.num_heads  = std::atoi(argv[++i]);
    else if (std::strcmp(argv[i], "-seqq")  == 0 && i + 1 < argc) cfg.seq_len_q  = std::atoi(argv[++i]);
    else if (std::strcmp(argv[i], "-seqk")  == 0 && i + 1 < argc) cfg.seq_len_k  = std::atoi(argv[++i]);
    else if (std::strcmp(argv[i], "-mask")  == 0 && i + 1 < argc) cfg.use_mask   = std::atoi(argv[++i]);
    else if (std::strcmp(argv[i], "-scale") == 0 && i + 1 < argc) cfg.scale      = std::atof(argv[++i]);
    else if (std::strcmp(argv[i], "-h") == 0 || std::strcmp(argv[i], "--help") == 0) {
      std::printf(
        "Usage: %s [bench-flags] [-batch N] [-heads H] [-seqq Q] [-seqk K] [-mask 0|1] [-scale S]\n"
        "Bench flags: --iters N --warmup N --csv <path> --label <str>\n",
        argv[0]);
      return false;
    }
  }
  return true;
}

} // namespace

int main(int argc, char** argv) {
  // Strip bench flags first so the workload parser sees only its own args.
  vx_bench::BenchOpts bench = vx_bench::parse_bench_opts(argc, argv);

  SoftmaxConfig cfg;
  cfg.scale = 1.0f / std::sqrt(64.0f);
  if (!parse_workload_args(argc, argv, cfg)) return 0;

  std::printf("Softmax Bench Configuration:\n");
  std::printf("  Batch=%u Heads=%u SeqQ=%u SeqK=%u Mask=%u Scale=%.6f\n",
              cfg.batch_size, cfg.num_heads, cfg.seq_len_q, cfg.seq_len_k,
              cfg.use_mask, cfg.scale);
  std::printf("  Bench: warmup=%d iters=%d label=%s csv=%s\n",
              bench.warmup, bench.iters,
              bench.label.empty() ? "(none)" : bench.label.c_str(),
              bench.csv_path.empty() ? "(none)" : bench.csv_path.c_str());

  vx_device_h device = nullptr;
  if (vx_dev_open(&device) != 0) {
    std::fprintf(stderr, "vx_dev_open failed\n");
    return -1;
  }

  {
    SoftmaxDriver drv(device, cfg);

    std::vector<float> h_input(drv.input_size_elems());
    std::srand(42);
    initialize_random(h_input);   // non-zero data — exercises expf path

    drv.upload_inputs(h_input.data());
    drv.upload_kernel();

    // Force enabled even if the user forgot --bench (this binary IS the bench).
    bench.enabled = true;
    vx_bench::BenchRunner runner(bench);
    runner.run([&]{ drv.launch(); });
    runner.report();

    // One extra launch to dump HW counters without polluting timed iterations.
    drv.launch();
    std::printf("\n[Performance — last iteration]\n");
    vx_dump_perf(device, stdout);
  } // SoftmaxDriver dtor releases buffers before vx_dev_close

  vx_dev_close(device);
  return 0;
}
