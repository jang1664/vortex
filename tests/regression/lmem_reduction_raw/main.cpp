#include "common.h"
#include <vortex.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cerrno>
#include <vector>

static vx_device_h device = nullptr;
static vx_buffer_h output_buffer = nullptr, kernel_buffer = nullptr, args_buffer = nullptr;

static void cleanup() {
  if (output_buffer) vx_mem_free(output_buffer);
  if (kernel_buffer) vx_mem_free(kernel_buffer);
  if (args_buffer) vx_mem_free(args_buffer);
  if (device) vx_dev_close(device);
}

#define RT_CHECK(expr) do { const int rc = (expr); if (rc) { \
  std::printf("Error: %s returned %d\n", #expr, rc); cleanup(); return 1; } } while (false)

static void usage(const char* name) {
  std::printf("Usage: %s [--mode int|fp32|fp16|warp|lmem-warp|peer|tree|exchange] [--iterations N]\n"
      "  [--groups N] [--active N] [--stride N] [--gap 0|8] [--fence 0|1] [--warps 1|2]\n"
      "Defaults: fp32, 128 iterations, 12 groups, active=0 (vary masks), stride=1, gap=0, fence=0.\n", name);
}

int main(int argc, char** argv) {
  const char* modes[] = {"int", "fp32", "fp16", "warp", "lmem-warp", "peer", "tree", "exchange"};
  kernel_arg_t arg = {};
  arg.mode = RAW_FP32; arg.iterations = 128; arg.groups = 12; arg.stride = 1;
  arg.warps = 1;
  for (int i = 1; i < argc; ++i) {
    if (!std::strcmp(argv[i], "--help")) { usage(argv[0]); return 0; }
    if (i + 1 >= argc) { usage(argv[0]); return 1; }
    const char* option = argv[i++];
    const char* value = argv[i];
    if (!std::strcmp(option, "--mode")) {
      bool found = false;
      for (uint32_t m = 0; m < 8; ++m)
        if (!std::strcmp(value, modes[m])) { arg.mode = m; found = true; }
      if (!found) { usage(argv[0]); return 1; }
      continue;
    }
    char* end = nullptr; errno = 0;
    const unsigned long parsed = std::strtoul(value, &end, 10);
    if (errno || *end || end == value || value[0] == '-' || parsed > UINT32_MAX) {
      usage(argv[0]); return 1;
    }
    uint32_t* target = nullptr;
    if (!std::strcmp(option, "--iterations")) target = &arg.iterations;
    else if (!std::strcmp(option, "--groups")) target = &arg.groups;
    else if (!std::strcmp(option, "--active")) target = &arg.active;
    else if (!std::strcmp(option, "--stride")) target = &arg.stride;
    else if (!std::strcmp(option, "--gap")) target = &arg.gap;
    else if (!std::strcmp(option, "--fence")) target = &arg.fence;
    else if (!std::strcmp(option, "--warps")) target = &arg.warps;
    if (!target) { usage(argv[0]); return 1; }
    *target = parsed;
  }
  if (!arg.iterations || arg.iterations > 4096 || !arg.groups || arg.groups > 4096
      || !arg.stride || (arg.gap != 0 && arg.gap != 8) || arg.fence > 1
      || (arg.warps != 1 && arg.warps != 2)
      || (arg.mode < RAW_PEER && arg.warps != 1)
      || (arg.mode == RAW_EXCHANGE && arg.warps != 1)
      || (arg.mode >= RAW_PEER && arg.active != 0)) {
    usage(argv[0]); return 1;
  }
  RT_CHECK(vx_dev_open(&device));
  uint64_t threads, warps, local_bytes;
  RT_CHECK(vx_dev_caps(device, VX_CAPS_NUM_THREADS, &threads));
  RT_CHECK(vx_dev_caps(device, VX_CAPS_NUM_WARPS, &warps));
  RT_CHECK(vx_dev_caps(device, VX_CAPS_LOCAL_MEM_SIZE, &local_bytes));
  const uint64_t width = threads * arg.warps;
  if (!threads || threads > 64 || (threads & (threads - 1)) || !warps
      || warps % arg.warps || arg.active > threads
      || ((width - 1) * arg.stride + 1) * sizeof(float) > local_bytes / (warps / arg.warps)) {
    std::printf("Unsupported launch or local-memory footprint\n"); cleanup(); return 1;
  }
  arg.threads = threads;
  std::printf("LMEM RAW: mode=%s threads=%u warps=%u groups=%u iterations=%u active=%u stride=%u gap=%u fence=%u\n",
      modes[arg.mode], arg.threads, arg.warps, arg.groups, arg.iterations, arg.active, arg.stride, arg.gap, arg.fence);
  const uint64_t bytes = uint64_t(arg.groups) * width * sizeof(float);
  RT_CHECK(vx_mem_alloc(device, bytes, VX_MEM_WRITE, &output_buffer));
  RT_CHECK(vx_mem_address(output_buffer, &arg.output_addr));
  RT_CHECK(vx_upload_kernel_file(device, "kernel.vxbin", &kernel_buffer));
  RT_CHECK(vx_upload_bytes(device, &arg, sizeof(arg), &args_buffer));
  RT_CHECK(vx_start(device, kernel_buffer, args_buffer));
  RT_CHECK(vx_ready_wait(device, VX_MAX_TIMEOUT));
  std::vector<float> got(arg.groups * width);
  RT_CHECK(vx_copy_from_dev(got.data(), output_buffer, 0, bytes));
  uint32_t errors = 0;
  for (uint32_t group = 0; group < arg.groups; ++group) {
    const uint32_t count = active_lanes(group, threads, arg.active);
    for (uint32_t lane = 0; lane < width; ++lane) {
      float expected = 0;
      if (arg.mode == RAW_EXCHANGE)
        expected = float(arg.iterations * ((lane ^ (width / 2)) + 1)
            + arg.iterations * (arg.iterations - 1) / 2);
      else if (arg.mode == RAW_PEER)
        expected = float(arg.iterations * ((lane ^ (width / 2)) + 1) + arg.iterations / 2);
      else if (arg.mode == RAW_TREE)
        expected = float(arg.iterations * (width * (width + 1) / 2) + (arg.iterations / 2) * width);
      else if (arg.mode == RAW_WARP || arg.mode == RAW_LMEM_WARP)
        expected = float(arg.iterations * (count * (count + 1) / 2)
            + (arg.iterations / 2) * count);
      else if (lane < count)
        expected = arg.mode == RAW_FP16
            ? float(arg.iterations / 2) + 0.5f * float((arg.iterations + 1) / 2)
                + float(arg.iterations) * float(lane & 15u) / 32.0f
            : float(arg.iterations * (lane + 1));
      const float actual = got[group * width + lane];
      if (actual != expected) {
        if (errors < 16)
          std::printf("MISMATCH group=%u lane=%u active=%u expected=%.9g actual=%.9g diff=%.9g\n",
              group, lane, count, expected, actual, actual - expected);
        ++errors;
      }
    }
  }
  std::printf("Checked %llu lane results; errors=%u\n",
      static_cast<unsigned long long>(arg.groups) * width, errors);
  cleanup();
  std::printf("%s\n", errors ? "FAILED" : "PASSED");
  return errors ? 1 : 0;
}
