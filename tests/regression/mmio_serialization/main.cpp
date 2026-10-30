#include "common.h"
#include <vx_sram_fusion.h>
#include <vortex.h>
#include <cstdio>
#include <initializer_list>

static vx_device_h device = nullptr;
static vx_buffer_h kernel = nullptr, arguments = nullptr, output = nullptr;
static void cleanup() {
  for (auto buffer : {output, arguments, kernel})
    if (buffer) vx_mem_free(buffer);
  if (device) vx_dev_close(device);
}
#define RT_CHECK(call) do { const int rc = (call); if (rc) { \
  std::printf("ERROR: %s returned %d\n", #call, rc); cleanup(); return 1; \
} } while (false)

int main() {
  RT_CHECK(vx_dev_open(&device));
  RT_CHECK(vx_mem_alloc(device, sizeof(mmio_report_t), VX_MEM_READ_WRITE, &output));
  RT_CHECK(vx_mem_alloc(device, sizeof(kernel_arg_t), VX_MEM_READ_WRITE, &arguments));
  RT_CHECK(vx_upload_kernel_file(device, "kernel.vxbin", &kernel));
  kernel_arg_t arg = {};
  mmio_report_t report = {};
  RT_CHECK(vx_mem_address(output, &arg.output));
  RT_CHECK(vx_copy_to_dev(output, &report, 0, sizeof(report)));
  RT_CHECK(vx_copy_to_dev(arguments, &arg, 0, sizeof(arg)));
  RT_CHECK(vx_start(device, kernel, arguments));
  RT_CHECK(vx_ready_wait(device, 1800000));
  RT_CHECK(vx_copy_from_dev(&arg, arguments, 0, sizeof(arg)));
  RT_CHECK(vx_copy_from_dev(&report, output, 0, sizeof(report)));
  uint32_t errors = 0, successes = 0, entries = 0;
  for (uint32_t lane = 0; lane < kLanes; ++lane) {
    const uint32_t alloc = report.allocation[lane];
    if (alloc & (1u << JOB_MMIO_ALLOC_SUCC_BIT)) {
      const uint32_t entry = (alloc >> JOB_MMIO_ALLOC_ENTRY_LSB)
          & ((1u << JOB_MMIO_ALLOC_ENTRY_BITS) - 1u);
      ++successes;
      if (entry >= JOB_MMIO_NUM_ENTRIES || (entries & (1u << entry))) ++errors;
      entries |= 1u << entry;
    }
    const uint32_t expected_unique = 0x12341000u + lane;
    const uint32_t expected_partial = (expected_unique & ~0xff00u) | 0xaa00u;
    if (report.unique[lane] != expected_unique || report.partial[lane] != expected_partial
     || report.shared[lane] != 0xabc00000u + kLanes - 1u
     || report.capability[lane] != vortex::sram_fusion::kCapability
     || report.published[lane] != 1u
     || !(report.control[lane] & (1u << JOB_MMIO_CTRL_OCCUPY_BIT))
     || (report.control[lane] & ((1u << JOB_MMIO_CTRL_VALID_BIT) | (1u << JOB_MMIO_CTRL_WORKING_BIT)))) {
      std::printf("MISMATCH lane=%u unique=%08x partial=%08x shared=%08x caps=%08x publish=%08x control=%08x\n",
          lane, report.unique[lane], report.partial[lane], report.shared[lane],
          report.capability[lane], report.published[lane], report.control[lane]);
      ++errors;
    }
  }
  if (successes != JOB_MMIO_NUM_ENTRIES || entries != (1u << JOB_MMIO_NUM_ENTRIES) - 1u) ++errors;
  std::printf("MMIO_SERIALIZATION lanes=%u allocations=%u entries=%x cycles=%llu errors=%u\n",
      kLanes, successes, entries, static_cast<unsigned long long>(arg.cycles), errors);
  cleanup();
  std::printf("%s\n", errors ? "FAILED" : "PASSED");
  return errors ? 1 : 0;
}
