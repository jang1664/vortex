#include "common.h"
#include <vortex.h>
#include <cstdio>
#include <cstdlib>
#include <vector>
#include <unistd.h>

int main(int argc, char** argv) {
  kernel_arg_t arg = {};
  arg.rows = 128; arg.row_bytes = 64; arg.stride = 7168; arg.tiles = 32; arg.column_tiles = 1;
  arg.repeats = 1;
  int option;
  while ((option = getopt(argc, argv, "r:b:s:t:n:p:")) != -1) {
    uint32_t value = uint32_t(std::strtoul(optarg, nullptr, 0));
    switch (option) {
    case 'r': arg.rows = value; break;
    case 'b': arg.row_bytes = value; break;
    case 's': arg.stride = value; break;
    case 't': arg.tiles = value; break;
    case 'n': arg.column_tiles = value; break;
    case 'p': arg.repeats = value; break;
    default: return 2;
    }
  }
  uint64_t bytes = uint64_t(arg.rows) * arg.stride * arg.tiles;
  if (!arg.rows || !arg.row_bytes || !arg.tiles || arg.tiles > 4096 || !arg.column_tiles
      || uint64_t(arg.column_tiles) * arg.row_bytes > arg.stride
      || !arg.repeats || arg.repeats > 16
      || uint64_t(arg.column_tiles) * arg.tiles * arg.repeats > 65536
      || arg.row_bytes > arg.stride || (arg.row_bytes % 64) || (arg.stride % 64)
      || uint64_t(arg.rows) * arg.row_bytes > 32768 || bytes > (256ull << 20)) {
    std::fprintf(stderr, "Invalid profile dimensions (64B alignment, <=32KiB tile, <=256MiB source)\n");
    return 2;
  }
  vx_device_h device = nullptr;
  vx_buffer_h input = nullptr, output = nullptr, kernel = nullptr, args = nullptr;
  auto cleanup = [&]() {
    if (args) vx_mem_free(args);
    if (kernel) vx_mem_free(kernel);
    if (output) vx_mem_free(output);
    if (input) vx_mem_free(input);
    if (device) vx_dev_close(device);
  };
#define CHECK(expr) do { int rc = (expr); if (rc) { \
  std::fprintf(stderr, "%s failed: %d\n", #expr, rc); cleanup(); return 1; } } while (0)
  CHECK(vx_dev_open(&device));
  uint64_t local_bytes = 0;
  CHECK(vx_dev_caps(device, VX_CAPS_LOCAL_MEM_SIZE, &local_bytes));
  if (local_bytes < 98304) { cleanup(); return 2; }
  // Match the usual K4096 GEMM input allocation before its weight buffer.
  const uint64_t prefix = 8192;
  CHECK(vx_mem_alloc(device, prefix + bytes, VX_MEM_READ, &input));
  CHECK(vx_mem_address(input, &arg.source));
  arg.source += prefix;
  std::vector<uint64_t> data(bytes / 8);
  for (uint64_t i = 0; i < data.size(); ++i) data[i] = profile_pattern(i);
  CHECK(vx_copy_to_dev(input, data.data(), prefix, bytes));
  CHECK(vx_mem_alloc(device, arg.tiles * arg.column_tiles * arg.repeats * sizeof(tile_result_t), VX_MEM_WRITE, &output));
  CHECK(vx_mem_address(output, &arg.results));
  CHECK(vx_upload_kernel_file(device, "kernel.vxbin", &kernel));
  CHECK(vx_upload_bytes(device, &arg, sizeof(arg), &args));
  CHECK(vx_start(device, kernel, args));
  CHECK(vx_ready_wait(device, VX_MAX_TIMEOUT));
  std::vector<tile_result_t> results(arg.tiles * arg.column_tiles * arg.repeats);
  CHECK(vx_copy_from_dev(results.data(), output, 0, results.size() * sizeof(tile_result_t)));
  std::printf("DMA_PROFILE rows=%u row_bytes=%u stride=%u tiles=%u column_tiles=%u repeats=%u source=0x%llx\n",
              arg.rows, arg.row_bytes, arg.stride, arg.tiles, arg.column_tiles, arg.repeats, (unsigned long long)arg.source);
  std::puts("sample,setup_cycles,kick_to_done_cycles,errors,status");
  uint64_t errors = 0;
  for (uint32_t t = 0; t < results.size(); ++t) {
    auto r = results[t]; errors += r.errors + r.status;
    std::printf("%u,%llu,%llu,%llu,%llu\n", t,
                (unsigned long long)r.setup_cycles, (unsigned long long)r.wait_cycles,
                (unsigned long long)r.errors, (unsigned long long)r.status);
  }
  cleanup();
  std::puts(errors ? "FAILED" : "PASSED");
  return errors ? 1 : 0;
}
