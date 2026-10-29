#include "common.h"
#include "../layout_fused_common/layout_fused_layouts.h"
#include <vortex.h>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <initializer_list>

static vx_device_h device = nullptr;
static vx_buffer_h kernel = nullptr, arguments = nullptr, diagnostics = nullptr;

static void cleanup() {
  for (auto buffer : {diagnostics, arguments, kernel})
    if (buffer) vx_mem_free(buffer);
  if (device) vx_dev_close(device);
}

#define RT_CHECK(call) do { const int result = (call); if (result) { \
  std::printf("ERROR: %s returned %d\n", #call, result); cleanup(); return 1; \
} } while (false)

static uint32_t log2_width(uint32_t value) {
  uint32_t result = 0;
  while ((1u << result) != value) ++result;
  return result;
}

int main(int argc, char **argv) {
  uint32_t rows = MASK_MAX_ROWS;
  if (argc == 3 && !std::strcmp(argv[1], "-m")
      && (!std::strcmp(argv[2], "1") || !std::strcmp(argv[2], "4"))) {
    rows = uint32_t(argv[2][0] - '0');
  } else if (argc != 1) {
    std::printf("Usage: %s [-m 1|4]\n", argv[0]);
    return 1;
  }
  kernel_arg_t arg = {};
  arg.query_rows = rows;
  arg.query_rows_pad = MASK_PAD_ROWS;
  arg.kv_tile = arg.head_dim = MASK_WIDTH;
  arg.resident = arg.output_fp32 = 1u;
  arg.attention_scale = 1.0f;
  uint64_t cursor = uint64_t(LMEM_BASE_ADDR);
  auto reserve = [&](uint64_t bytes) {
    const uint64_t address = cursor;
    cursor += (bytes + 31u) & ~uint64_t(31u);
    return address;
  };
  arg.score_base = arg.partial_base = reserve(MASK_PAD_ROWS * MASK_WIDTH * sizeof(float));
  arg.probability_base = reserve(MASK_PAD_ROWS * MASK_WIDTH * sizeof(fp16_t));
  arg.accumulator_base = reserve(rows * MASK_WIDTH * sizeof(float));
  arg.row_max_base = reserve(rows * sizeof(float));
  arg.row_sum_base = reserve(rows * sizeof(float));
  arg.row_alpha_base = reserve(rows * sizeof(float));
  arg.output_base = reserve(rows * MASK_WIDTH * sizeof(fp16_t));
  if (cursor - uint64_t(LMEM_BASE_ADDR) > uint64_t(LMEM_SIZE) / 2u) {
    std::printf("ERROR: mask-test arena exceeds reserved LMEM\n");
    return 1;
  }
  RT_CHECK(vx_dev_open(&device));
  RT_CHECK(vx_mem_alloc(device, sizeof(mask_report_t), VX_MEM_READ_WRITE, &diagnostics));
  RT_CHECK(vx_mem_address(diagnostics, &arg.debug_score_base));
  mask_report_t report;
  std::memset(&report, 0xa5, sizeof(report));
  RT_CHECK(vx_copy_to_dev(diagnostics, &report, 0, sizeof(report)));
  RT_CHECK(vx_upload_kernel_file(device, "kernel.vxbin", &kernel));
  RT_CHECK(vx_mem_alloc(device, sizeof(arg), VX_MEM_READ_WRITE, &arguments));
  RT_CHECK(vx_copy_to_dev(arguments, &arg, 0, sizeof(arg)));
  std::printf("MASK_WORKER_TEST rows=%u phases=all-empty,empty-to-valid diagnostic_exports=1 production_traffic_proof=0 timeout_ms=1800000\n", rows);
  RT_CHECK(vx_start(device, kernel, arguments));
  RT_CHECK(vx_ready_wait(device, 1800000));
  RT_CHECK(vx_copy_from_dev(&arg, arguments, 0, sizeof(arg)));
  RT_CHECK(vx_copy_from_dev(&report, diagnostics, 0, sizeof(report)));
  uint32_t errors = 0, checks = 0;
  auto check = [&](bool condition, const char *name, uint32_t phase, uint32_t index) {
    ++checks;
    if (!condition) {
      if (errors < 16u) std::printf("MISMATCH phase=%u name=%s index=%u\n", phase, name, index);
      ++errors;
    }
  };
  check(arg.status == FLASH_STATUS_OK, "status", 0, arg.status);
  check(report.magic == MASK_REPORT_MAGIC && report.completed_phases == 2u, "completion", 0, report.completed_phases);
  check(arg.later_max_updates == 1u, "first-valid-max-update", 1, arg.later_max_updates);
  for (uint32_t phase = 0; phase < 2u; ++phase) {
    const auto &snapshot = report.phases[phase];
    for (uint32_t row = 0; row < rows; ++row) {
      check(phase ? snapshot.row_max[row] == double(row + 1u) / 4.0
                  : std::isinf(snapshot.row_max[row]) && snapshot.row_max[row] < 0,
            "m", phase, row);
      check(snapshot.row_sum[row] == (phase ? 128.0f : 0.0f), "l", phase, row);
      check(snapshot.row_alpha[row] == 0.0f, "alpha", phase, row);
      for (uint32_t col = 0; col < MASK_WIDTH; ++col) {
        const uint32_t index = row * MASK_WIDTH + col;
        const double partial = phase ? double(int32_t(col % 9u) - 4) * double(row + 1u) : 0.0;
        check(std::isfinite(snapshot.accumulator[index]) && snapshot.accumulator[index] == partial,
              "U", phase, index);
        const double output = fp16_to_float(snapshot.output[index]);
        check(std::isfinite(output) && output == partial / 128.0, "O", phase, index);
      }
    }
    for (uint32_t row = 0; row < MASK_PAD_ROWS; ++row) {
      for (uint32_t col = 0; col < MASK_WIDTH; ++col) {
        const uint64_t offset = gemm_a_tiled_elem_offset(row, col, MASK_PAD_ROWS,
            MASK_WIDTH, 7u, log2_width(FLASH_MXU_KT));
        const fp16_t expected = phase && row < rows ? fp16_t(0x3c00u) : fp16_t(0u);
        check(snapshot.probabilities[offset] == expected, "P-including-padding", phase, uint32_t(offset));
      }
    }
  }
  std::printf("MASK_WORKER_TEST checks=%u errors=%u\n", checks, errors);
  cleanup();
  std::printf("%s\n", errors ? "FAILED" : "PASSED");
  return errors ? 1 : 0;
}
