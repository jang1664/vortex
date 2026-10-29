#include "common.h"
#include <vortex.h>
#include <cstdio>
#include <initializer_list>
#include <vector>

static vx_device_h device = nullptr;
static vx_buffer_h kernel = nullptr, arguments = nullptr, output = nullptr;

static void cleanup() {
  for (auto buffer : {output, arguments, kernel})
    if (buffer) vx_mem_free(buffer);
  if (device) vx_dev_close(device);
}

#define RT_CHECK(call) do { const int result = (call); if (result) { \
  std::printf("ERROR: %s returned %d\n", #call, result); cleanup(); return 1; \
} } while (false)

int main() {
  static_assert(kDestination + kCopyBytes <= uint64_t(LMEM_BASE_ADDR) + LMEM_SIZE,
                "early-return test requires sufficient LMEM");
  static_assert(kCopyBytes <= NUM_TMEM_BANKS * TMEM_BANK_SIZE,
                "early-return test requires sufficient TMEM");
  RT_CHECK(vx_dev_open(&device));
  RT_CHECK(vx_mem_alloc(device, kCopyBytes, VX_MEM_READ_WRITE, &output));
  RT_CHECK(vx_mem_alloc(device, sizeof(kernel_arg_t), VX_MEM_READ_WRITE, &arguments));
  RT_CHECK(vx_upload_kernel_file(device, "kernel.vxbin", &kernel));
  kernel_arg_t arg = {};
  RT_CHECK(vx_mem_address(output, &arg.output));
  std::vector<uint64_t> data(kCopyWords, 0xdeadbeefdeadbeefull);
  RT_CHECK(vx_copy_to_dev(output, data.data(), 0, kCopyBytes));
  for (arg.phase = 0; arg.phase < 2; ++arg.phase) {
    arg.status = -99;
    RT_CHECK(vx_copy_to_dev(arguments, &arg, 0, sizeof(arg)));
    std::printf("SRAM_EARLY_RETURN launch=%u bytes=%u\n", arg.phase, kCopyBytes);
    RT_CHECK(vx_start(device, kernel, arguments));
    RT_CHECK(vx_ready_wait(device, 1800000));
    RT_CHECK(vx_copy_from_dev(&arg, arguments, 0, sizeof(arg)));
    if (arg.status) {
      std::printf("ERROR: launch=%u kernel status=%d\n", arg.phase, arg.status);
      cleanup();
      return 1;
    }
    std::printf("SRAM_EARLY_RETURN launch=%u host_done=1\n", arg.phase);
  }
  RT_CHECK(vx_copy_from_dev(data.data(), output, 0, kCopyBytes));
  uint32_t errors = 0;
  for (uint32_t i = 0; i < kCopyWords; ++i) {
    if (data[i] != pattern(i)) {
      if (errors < 8u)
        std::printf("MISMATCH word=%u actual=%016llx expected=%016llx\n", i,
            static_cast<unsigned long long>(data[i]),
            static_cast<unsigned long long>(pattern(i)));
      ++errors;
    }
  }
  std::printf("SRAM_EARLY_RETURN exact_bytes=%u errors=%u\n", kCopyBytes, errors);
  cleanup();
  std::printf("%s\n", errors ? "FAILED" : "PASSED");
  return errors ? 1 : 0;
}
