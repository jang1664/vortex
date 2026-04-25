// bench_harness.h — latency measurement helper for Vortex regression tests.
//
// Usage in a test's main.cpp:
//
//   #include "bench_harness.h"
//
//   int main(int argc, char** argv) {
//     vx_bench::BenchOpts bench = vx_bench::parse_bench_opts(argc, argv);
//     parse_args(argc, argv);  // existing test-specific parser
//     ...
//     if (bench.enabled) {
//       vx_bench::BenchRunner runner(bench);
//       runner.run([&]{
//         vx_start(device, krnl_buffer, args_buffer);
//         vx_ready_wait(device, VX_MAX_TIMEOUT);
//       });
//       runner.report();
//       // validation is skipped in bench mode
//     } else {
//       vx_start(...); vx_ready_wait(...);
//       // normal validation path
//     }
//   }
//
// CLI flags recognized (and stripped from argv):
//   --bench              enable bench mode
//   --iters N            number of timed iterations (default 20)
//   --warmup N           number of un-timed warmup iterations (default 3)
//   --csv <path>         append per-iteration samples to this CSV file
//   --label <str>        identifier for this run (appears in output and CSV)

#pragma once

#include <chrono>
#include <cstdio>
#include <string>
#include <vector>

namespace vx_bench {

struct BenchOpts {
  bool        enabled = false;
  int         warmup  = 3;
  int         iters   = 20;
  std::string csv_path;   // append-mode; empty = no CSV
  std::string label;      // identifier for this run, e.g. "softmax@xclbin_v3"
};

// Parse --bench/--iters/--warmup/--csv/--label from argv. Matched flags are
// removed in-place so the test's own parser sees only its own args.
BenchOpts parse_bench_opts(int& argc, char** argv);

class BenchRunner {
public:
  explicit BenchRunner(const BenchOpts& opts) : opts_(opts) {}

  // Runs warmup_ iterations (not recorded) then iters_ timed iterations.
  // launch() should perform a single vx_start + vx_ready_wait pair.
  // Any return value / error handling is the caller's responsibility.
  template <class F>
  void run(F&& launch) {
    samples_ms_.clear();
    samples_ms_.reserve(opts_.iters);
    for (int i = 0; i < opts_.warmup; ++i) {
      launch();
    }
    for (int i = 0; i < opts_.iters; ++i) {
      auto t0 = std::chrono::high_resolution_clock::now();
      launch();
      auto t1 = std::chrono::high_resolution_clock::now();
      double ms = std::chrono::duration<double, std::milli>(t1 - t0).count();
      samples_ms_.push_back(ms);
    }
  }

  // Print summary to `out`. If csv_path is set, append per-iteration samples
  // (long format: label,iter,latency_ms).
  // `label_suffix` is appended to opts_.label with "/" — useful for
  // multi-kernel tests (e.g. "gemm_fpint" + "kernel_1" -> "gemm_fpint/kernel_1").
  void report(FILE* out = stdout, const std::string& label_suffix = "");

  const std::vector<double>& samples_ms() const { return samples_ms_; }

private:
  BenchOpts            opts_;
  std::vector<double>  samples_ms_;
};

} // namespace vx_bench
