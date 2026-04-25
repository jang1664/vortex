// test_main.cpp — functional test for the softmax kernel.
//
// Builds the `softmax` host binary. Runs the kernel once on the device and
// compares the output against the CPU golden (reference.h). No bench mode —
// for latency measurement, use `softmax_bench` (bench_main.cpp).

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>
#include <vortex.h>

#include "driver.h"
#include "reference.h"

namespace {

void initialize_random(std::vector<float>& vec) {
  for (auto& val : vec) {
    val = static_cast<float>(rand()) / RAND_MAX * 4.0f - 2.0f;  // [-2, 2]
  }
}

void show_usage(const char* prog) {
  std::printf(
    "Usage: %s [-batch N] [-heads H] [-seqq Q] [-seqk K] [-mask 0|1] [-scale S]\n",
    prog);
}

bool parse_args(int argc, char** argv, SoftmaxConfig& cfg) {
  for (int i = 1; i < argc; ++i) {
    if (std::strcmp(argv[i], "-batch") == 0 && i + 1 < argc) {
      cfg.batch_size = std::atoi(argv[++i]);
    } else if (std::strcmp(argv[i], "-heads") == 0 && i + 1 < argc) {
      cfg.num_heads = std::atoi(argv[++i]);
    } else if (std::strcmp(argv[i], "-seqq") == 0 && i + 1 < argc) {
      cfg.seq_len_q = std::atoi(argv[++i]);
    } else if (std::strcmp(argv[i], "-seqk") == 0 && i + 1 < argc) {
      cfg.seq_len_k = std::atoi(argv[++i]);
    } else if (std::strcmp(argv[i], "-mask") == 0 && i + 1 < argc) {
      cfg.use_mask = std::atoi(argv[++i]);
    } else if (std::strcmp(argv[i], "-scale") == 0 && i + 1 < argc) {
      cfg.scale = std::atof(argv[++i]);
    } else if (std::strcmp(argv[i], "-h") == 0
            || std::strcmp(argv[i], "--help") == 0) {
      show_usage(argv[0]);
      return false;
    }
  }
  return true;
}

constexpr int MAX_REPORTED_ERRORS = 10;

} // namespace

int main(int argc, char** argv) {
  SoftmaxConfig cfg;
  // Default scale assumes head_dim=64 (typical attention setup).
  cfg.scale = 1.0f / std::sqrt(64.0f);

  if (!parse_args(argc, argv, cfg)) return 0;

  std::printf("Softmax Test Configuration:\n");
  std::printf("  Batch Size:   %u\n", cfg.batch_size);
  std::printf("  Num Heads:    %u\n", cfg.num_heads);
  std::printf("  Seq Len Q:    %u\n", cfg.seq_len_q);
  std::printf("  Seq Len K:    %u\n", cfg.seq_len_k);
  std::printf("  Use Mask:     %u\n", cfg.use_mask);
  std::printf("  Scale:        %.6f\n", cfg.scale);

  vx_device_h device = nullptr;
  if (vx_dev_open(&device) != 0) {
    std::fprintf(stderr, "vx_dev_open failed\n");
    return -1;
  }

  uint64_t num_cores = 0, num_warps = 0, num_threads = 0;
  vx_dev_caps(device, VX_CAPS_NUM_CORES,   &num_cores);
  vx_dev_caps(device, VX_CAPS_NUM_WARPS,   &num_warps);
  vx_dev_caps(device, VX_CAPS_NUM_THREADS, &num_threads);
  std::printf("Device Caps: cores=%lu, warps=%lu, threads=%lu\n",
              num_cores, num_warps, num_threads);

  {
    SoftmaxDriver drv(device, cfg);

    const size_t n = drv.input_size_elems();
    std::vector<float> h_input(n);
    std::vector<float> h_output_gpu(n);
    std::vector<float> h_output_cpu(n);

    std::srand(42);
    initialize_random(h_input);

    std::printf("Running CPU reference...\n");
    softmax_cpu(h_input, h_output_cpu,
                cfg.batch_size, cfg.num_heads,
                cfg.seq_len_q, cfg.seq_len_k,
                cfg.use_mask != 0, cfg.scale);

    drv.upload_inputs(h_input.data());
    std::printf("Uploading kernel...\n");
    drv.upload_kernel();
    std::printf("Running kernel...\n");
    drv.launch();
    drv.download(h_output_gpu.data());

    std::printf("\n[Performance]\n");
    vx_dump_perf(device, stdout);

    std::printf("Verifying results...\n");

    int   errors        = 0;
    float max_diff      = 0.0f;
    float max_rel_error = 0.0f;

    for (uint32_t b = 0; b < cfg.batch_size; ++b) {
      for (uint32_t h = 0; h < cfg.num_heads; ++h) {
        for (uint32_t q = 0; q < cfg.seq_len_q; ++q) {
          uint32_t row_offset =
              ((b * cfg.num_heads + h) * cfg.seq_len_q + q) * cfg.seq_len_k;

          float sum_gpu = 0.0f;

          for (uint32_t k = 0; k < cfg.seq_len_k; ++k) {
            uint32_t idx = row_offset + k;
            float diff = std::abs(h_output_gpu[idx] - h_output_cpu[idx]);
            max_diff = std::max(max_diff, diff);

            sum_gpu += h_output_gpu[idx];

            float abs_threshold = 1e-5f;
            float rel_threshold = std::abs(h_output_cpu[idx]) * 0.01f;  // 1%
            float threshold     = std::max(abs_threshold, rel_threshold);

            if (diff > threshold) {
              if (errors < MAX_REPORTED_ERRORS) {
                float rel_error = (h_output_cpu[idx] != 0.0f)
                    ? diff / std::abs(h_output_cpu[idx]) : 0.0f;
                max_rel_error = std::max(max_rel_error, rel_error);
                std::printf(
                  "Error at [%u,%u,%u,%u]: GPU=%.6f, CPU=%.6f, diff=%.6f, rel_err=%.2f%%\n",
                  b, h, q, k,
                  h_output_gpu[idx], h_output_cpu[idx], diff, rel_error * 100.0f);
              }
              ++errors;
            }
          }

          if (std::abs(sum_gpu - 1.0f) > 1e-4f) {
            if (errors < MAX_REPORTED_ERRORS) {
              std::printf("Row sum error at [%u,%u,%u]: GPU sum=%.6f (expected ~1.0)\n",
                          b, h, q, sum_gpu);
            }
            ++errors;
          }
        }
      }
    }

    std::printf("  Max absolute diff:  %.6f\n", max_diff);
    std::printf("  Max relative error: %.2f%%\n", max_rel_error * 100.0f);

    if (errors == 0) {
      std::printf("PASSED!\n");
    } else {
      std::printf("FAILED! (%d errors)\n", errors);
    }

    if (errors != 0) {
      vx_dev_close(device);
      return -1;
    }
  } // SoftmaxDriver dtor releases buffers before vx_dev_close

  vx_dev_close(device);
  return 0;
}
