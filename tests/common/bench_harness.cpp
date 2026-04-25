#include "bench_harness.h"

#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <sys/stat.h>

namespace vx_bench {

namespace {

void remove_argv(int& argc, char** argv, int from, int count) {
  for (int i = from; i + count < argc; ++i) {
    argv[i] = argv[i + count];
  }
  argc -= count;
}

double percentile(std::vector<double> v, double p) {
  if (v.empty()) return 0.0;
  std::sort(v.begin(), v.end());
  double idx = p * (static_cast<double>(v.size()) - 1.0);
  auto lo = static_cast<size_t>(std::floor(idx));
  auto hi = static_cast<size_t>(std::ceil(idx));
  if (lo == hi) return v[lo];
  double frac = idx - static_cast<double>(lo);
  return v[lo] * (1.0 - frac) + v[hi] * frac;
}

bool csv_needs_header(const std::string& path) {
  struct stat st;
  if (stat(path.c_str(), &st) != 0) return true;
  return st.st_size == 0;
}

} // namespace

BenchOpts parse_bench_opts(int& argc, char** argv) {
  BenchOpts opts;
  int i = 1;
  while (i < argc) {
    const char* a = argv[i];
    if (std::strcmp(a, "--bench") == 0) {
      opts.enabled = true;
      remove_argv(argc, argv, i, 1);
    } else if (std::strcmp(a, "--iters") == 0 && i + 1 < argc) {
      opts.iters = std::max(1, std::atoi(argv[i + 1]));
      remove_argv(argc, argv, i, 2);
    } else if (std::strcmp(a, "--warmup") == 0 && i + 1 < argc) {
      opts.warmup = std::max(0, std::atoi(argv[i + 1]));
      remove_argv(argc, argv, i, 2);
    } else if (std::strcmp(a, "--csv") == 0 && i + 1 < argc) {
      opts.csv_path = argv[i + 1];
      remove_argv(argc, argv, i, 2);
    } else if (std::strcmp(a, "--label") == 0 && i + 1 < argc) {
      opts.label = argv[i + 1];
      remove_argv(argc, argv, i, 2);
    } else {
      ++i;
    }
  }
  return opts;
}

void BenchRunner::report(FILE* out, const std::string& label_suffix) {
  std::string label = opts_.label;
  if (!label_suffix.empty()) {
    label = label.empty() ? label_suffix : label + "/" + label_suffix;
  }
  if (label.empty()) label = "bench";

  if (samples_ms_.empty()) {
    std::fprintf(out, "\n[bench] label=%s: no samples collected\n", label.c_str());
    return;
  }

  auto sorted = samples_ms_;
  std::sort(sorted.begin(), sorted.end());
  double min_ms = sorted.front();
  double max_ms = sorted.back();
  double median = percentile(samples_ms_, 0.5);
  double p95    = percentile(samples_ms_, 0.95);

  double sum = 0.0;
  for (double v : samples_ms_) sum += v;
  double mean = sum / static_cast<double>(samples_ms_.size());

  double var = 0.0;
  for (double v : samples_ms_) var += (v - mean) * (v - mean);
  double stddev = std::sqrt(var / static_cast<double>(samples_ms_.size()));

  std::fprintf(out, "\n[bench] label=%s iters=%d warmup=%d\n",
               label.c_str(), opts_.iters, opts_.warmup);
  std::fprintf(out,
    "[bench]   min=%.4f  median=%.4f  mean=%.4f  p95=%.4f  max=%.4f  stddev=%.4f  (ms)\n",
    min_ms, median, mean, p95, max_ms, stddev);

  if (!opts_.csv_path.empty()) {
    bool need_header = csv_needs_header(opts_.csv_path);
    FILE* fp = std::fopen(opts_.csv_path.c_str(), "a");
    if (!fp) {
      std::fprintf(out, "[bench] WARNING: could not open csv: %s\n",
                   opts_.csv_path.c_str());
      return;
    }
    if (need_header) {
      std::fprintf(fp, "label,iter,latency_ms\n");
    }
    for (size_t i = 0; i < samples_ms_.size(); ++i) {
      std::fprintf(fp, "%s,%zu,%.6f\n", label.c_str(), i, samples_ms_[i]);
    }
    std::fclose(fp);
  }
}

} // namespace vx_bench
