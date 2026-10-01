#include <cstdio>
#include <vector>
#include <vortex.h>
#include "common.h"
int main() {
  static_assert(XLEN == 64, "capacity regression requires XLEN64");
  vx_device_h device = nullptr;
  vx_buffer_h output = nullptr, kernel = nullptr, args = nullptr;
  auto cleanup = [&]() {
    if (args) vx_mem_free(args);
    if (kernel) vx_mem_free(kernel);
    if (output) vx_mem_free(output);
    if (device) vx_dev_close(device);
  };
#define CHECK(expr) do { int rc = (expr); if (rc) { \
  std::fprintf(stderr, "%s failed: %d\n", #expr, rc); cleanup(); return 1; } } while (0)
  CHECK(vx_dev_open(&device));
  uint64_t size = 0;
  CHECK(vx_dev_caps(device, VX_CAPS_LOCAL_MEM_SIZE, &size));
  std::printf("LMEM capacity: runtime=%llu compiled=%llu bytes\n",
              static_cast<unsigned long long>(size),
              static_cast<unsigned long long>(LMEM_SIZE));
  if (size != LMEM_SIZE) { cleanup(); return 1; }
  kernel_arg_t arg = {};
  CHECK(vx_mem_alloc(device, kSamples * sizeof(uint64_t), VX_MEM_WRITE, &output));
  CHECK(vx_mem_address(output, &arg.output));
  CHECK(vx_upload_kernel_file(device, "kernel.vxbin", &kernel));
  CHECK(vx_upload_bytes(device, &arg, sizeof(arg), &args));
  CHECK(vx_start(device, kernel, args));
  CHECK(vx_ready_wait(device, VX_MAX_TIMEOUT));
  std::vector<uint64_t> results(kSamples);
  CHECK(vx_copy_from_dev(results.data(), output, 0, kSamples * sizeof(uint64_t)));
  unsigned failures = 0;
  for (uint32_t i = 0; i < kSamples; ++i) {
    uint64_t expected = (sample_pattern(i) & ~0xff000000ull) | 0x5a000000ull;
    if (results[i] != expected) {
      std::fprintf(stderr, "LMEM offset 0x%llx: got %016llx expected %016llx\n",
          (unsigned long long)sample_offset(i), (unsigned long long)results[i],
          (unsigned long long)expected);
      ++failures;
    }
  }
  cleanup();
  std::puts(failures ? "TEST FAILED" : "TEST PASSED");
  return failures ? 1 : 0;
}
