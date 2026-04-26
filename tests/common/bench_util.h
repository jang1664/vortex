#pragma once

// Minimal header-only benchmark helpers for tests/regression/<app>/bench_main.cpp.
//
// Usage sketch:
//   #include "bench_util.h"
//   int main(int argc, char** argv) {
//     auto bench = vx_bench::parse(argc, argv);   // strips --warmup/--iterations/--csv from argv
//     // ... existing setup, allocations, kernel arg upload ...
//     for (int i = 0; i < bench.warmup; ++i) {
//       vx_start(...); vx_ready_wait(...);
//     }
//     vx_bench::Stats stats;
//     for (int i = 0; i < bench.iterations; ++i) {
//       vx_bench::Stopwatch sw; sw.start();
//       vx_start(...); vx_ready_wait(...);
//       stats.record(sw.stop_us());
//     }
//     stats.report("softmax", stdout, bench.csv);
//   }

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

namespace vx_bench {

struct Args {
    int  warmup     = 3;
    int  iterations = 10;
    bool csv        = false;
};

// Parses --warmup=N / --iterations=N / --csv (and -warmup/-iterations forms)
// in place: matched flags are removed from argv and argc is decremented so the
// caller's existing argument parser sees only its own flags.
inline Args parse(int& argc, char** argv) {
    Args a;
    int  w = 1;
    for (int r = 1; r < argc; ++r) {
        const char* s = argv[r];
        if (std::strncmp(s, "--warmup=", 9) == 0) {
            a.warmup = std::atoi(s + 9);
        } else if (std::strncmp(s, "--iterations=", 13) == 0) {
            a.iterations = std::atoi(s + 13);
        } else if (std::strcmp(s, "--csv") == 0) {
            a.csv = true;
        } else if (std::strcmp(s, "--warmup") == 0 && r + 1 < argc) {
            a.warmup = std::atoi(argv[++r]);
        } else if (std::strcmp(s, "--iterations") == 0 && r + 1 < argc) {
            a.iterations = std::atoi(argv[++r]);
        } else {
            argv[w++] = argv[r];
        }
    }
    argc = w;
    if (a.warmup < 0)     a.warmup = 0;
    if (a.iterations < 1) a.iterations = 1;
    return a;
}

class Stopwatch {
public:
    void   start()    { t0_ = clock::now(); }
    double stop_us() {
        auto t1 = clock::now();
        return std::chrono::duration<double, std::micro>(t1 - t0_).count();
    }
private:
    using clock = std::chrono::steady_clock;
    clock::time_point t0_{};
};

class Stats {
public:
    void record(double us) { samples_.push_back(us); }

    void report(const char* label, FILE* out, bool csv) const {
        if (samples_.empty()) {
            std::fprintf(out, "[bench] %s: no samples\n", label);
            return;
        }
        std::vector<double> s = samples_;
        std::sort(s.begin(), s.end());
        const size_t n = s.size();
        double sum = 0.0;
        for (double v : s) sum += v;
        double avg = sum / static_cast<double>(n);
        double mn  = s.front();
        double mx  = s.back();
        double p50 = pct(s, 0.50);
        double p95 = pct(s, 0.95);

        if (csv) {
            // Header is emitted once externally if needed; we just print the row.
            std::fprintf(out,
                "%s,%zu,%.3f,%.3f,%.3f,%.3f,%.3f\n",
                label, n, mn, avg, mx, p50, p95);
        } else {
            std::fprintf(out,
                "[bench] %s  iters=%zu  min=%.3f  avg=%.3f  max=%.3f  "
                "p50=%.3f  p95=%.3f  (us)\n",
                label, n, mn, avg, mx, p50, p95);
        }
    }

private:
    static double pct(const std::vector<double>& sorted, double q) {
        // nearest-rank (no interpolation) — fine for our small N
        if (sorted.empty()) return 0.0;
        size_t idx = static_cast<size_t>(q * (sorted.size() - 1) + 0.5);
        if (idx >= sorted.size()) idx = sorted.size() - 1;
        return sorted[idx];
    }

    std::vector<double> samples_;
};

} // namespace vx_bench
