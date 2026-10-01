#include <vortex.h>

#include <array>
#include <cstdint>
#include <cstdio>

#include "common.h"

#define RT_CHECK(expr)                                                     \
  do {                                                                     \
    const int status = (expr);                                             \
    if (status != 0) {                                                     \
      std::printf("Error: '%s' returned %d!\n", #expr, status);           \
      cleanup();                                                           \
      return 1;                                                            \
    }                                                                      \
  } while (false)

namespace {

constexpr uint32_t kNumPoints = 32;
constexpr uint32_t kNumActivePoints = NUM_THREADS;
static_assert(kNumActivePoints <= kNumPoints,
              "debug input only contains 32 points");

constexpr std::array<uint16_t, 4> kInput = {
    0xbe70,  // -1.609375: first failing quant group's minimum
    0x3f90,  //  1.890625: first failing quant group's maximum
    0x4b80,  // 15.0
    0x3800,  //  0.5
};

constexpr std::array<uint16_t, kNumPoints> kReductionInput = {
    0xbc70, 0x38c0, 0xbed0, 0x0000, 0x3ed0, 0xb8c0, 0x3c70, 0xbcc0,
    0x3820, 0xbf20, 0xad00, 0x3e80, 0xb960, 0x3c20, 0xbd10, 0x3700,
    0xbf70, 0xb100, 0x3e30, 0xba00, 0x3ba0, 0xbd60, 0x35c0, 0xbfc0,
    0xb380, 0x3de0, 0xbaa0, 0x3b00, 0xbdb0, 0x3480, 0x3ff0, 0xb500,
};

struct expected_step_t {
  const char* name;
  uint16_t expected;
};

vx_device_h device = nullptr;
vx_buffer_h input_buffer = nullptr;
vx_buffer_h output_buffer = nullptr;
vx_buffer_h reduction_input_buffer = nullptr;
vx_buffer_h reduction_output_buffer = nullptr;
vx_buffer_h kernel_buffer = nullptr;
vx_buffer_h args_buffer = nullptr;

void cleanup() {
  if (input_buffer) vx_mem_free(input_buffer);
  if (output_buffer) vx_mem_free(output_buffer);
  if (reduction_input_buffer) vx_mem_free(reduction_input_buffer);
  if (reduction_output_buffer) vx_mem_free(reduction_output_buffer);
  if (kernel_buffer) vx_mem_free(kernel_buffer);
  if (args_buffer) vx_mem_free(args_buffer);
  if (device) vx_dev_close(device);
  device = nullptr;
}

}  // namespace

int main() {
  static_assert(sizeof(fp16_quant_debug_result_t) == 32,
                "unexpected debug result layout");

  kernel_arg_t args = {};
  args.grid_dim[0] = 1;
  args.block_dim[0] = kNumActivePoints;
  RT_CHECK(vx_dev_open(&device));
  RT_CHECK(vx_mem_alloc(
      device, sizeof(kInput), VX_MEM_READ, &input_buffer));
  RT_CHECK(vx_mem_alloc(
      device, sizeof(fp16_quant_debug_result_t) * kNumPoints, VX_MEM_WRITE,
      &output_buffer));
  RT_CHECK(vx_mem_alloc(
      device, sizeof(kReductionInput), VX_MEM_READ,
      &reduction_input_buffer));
  RT_CHECK(vx_mem_alloc(
      device, sizeof(fp16_quant_reduction_result_t), VX_MEM_WRITE,
      &reduction_output_buffer));
  RT_CHECK(vx_mem_address(input_buffer, &args.input_addr));
  RT_CHECK(vx_mem_address(output_buffer, &args.output_addr));
  RT_CHECK(vx_mem_address(
      reduction_input_buffer, &args.reduction_input_addr));
  RT_CHECK(vx_mem_address(
      reduction_output_buffer, &args.reduction_output_addr));
  RT_CHECK(vx_copy_to_dev(
      input_buffer, kInput.data(), 0, sizeof(kInput)));
  RT_CHECK(vx_copy_to_dev(
      reduction_input_buffer, kReductionInput.data(), 0,
      sizeof(kReductionInput)));
  RT_CHECK(vx_upload_kernel_file(
      device, "kernel.vxbin", &kernel_buffer));
  RT_CHECK(vx_upload_bytes(
      device, &args, sizeof(args), &args_buffer));
  RT_CHECK(vx_start(device, kernel_buffer, args_buffer));
  RT_CHECK(vx_ready_wait(device, VX_MAX_TIMEOUT));

  std::array<fp16_quant_debug_result_t, kNumPoints> results = {};
  RT_CHECK(vx_copy_from_dev(
      results.data(), output_buffer, 0, sizeof(results)));

  const std::array<expected_step_t, 8> expected = {{
      {"range", 0x4300},
      {"scale", 0x3377},
      {"direct_ratio", 0x46e6},
      {"direct_biased", 0x4766},
      {"reciprocal", 0x4449},
      {"reciprocal_product", 0x46e5},
      {"reciprocal_biased", 0x4765},
      {"integer_as_half", 0x4700},
  }};
  uint32_t errors = 0;
  for (uint32_t point = 0; point < kNumActivePoints; ++point) {
    const auto& result = results[point];
    const std::array<uint16_t, 8> got = {{
        result.range,
        result.scale,
        result.direct_ratio,
        result.direct_biased,
        result.reciprocal,
        result.reciprocal_product,
        result.reciprocal_biased,
        result.integer_as_half,
    }};
    for (size_t i = 0; i < expected.size(); ++i) {
      if (got[i] != expected[i].expected) {
        std::printf(
            "thread=%u %-20s got=0x%04x expected=0x%04x FAIL\n",
            point, expected[i].name, got[i], expected[i].expected);
        ++errors;
      }
    }
    if (result.direct_integer != 7
        || result.reciprocal_integer != 7
        || result.integer_as_half_to_int64 != 7) {
      std::printf(
          "thread=%u integers direct=%d reciprocal=%d half_to_i64=%ld expected=7 FAIL\n",
          point, result.direct_integer, result.reciprocal_integer,
          static_cast<long>(result.integer_as_half_to_int64));
      ++errors;
    }
  }
  if (errors == 0) {
    std::printf("all %u concurrent threads matched every step\n",
                kNumActivePoints);
  }

  fp16_quant_reduction_result_t reduction = {};
  RT_CHECK(vx_copy_from_dev(
      &reduction, reduction_output_buffer, 0, sizeof(reduction)));
#if NUM_THREADS == 8
  const std::array<expected_step_t, 6> reduction_expected = {{
      {"reduction_minimum", 0xbed0},
      {"reduction_maximum", 0x3ed0},
      {"reduction_range", 0x42d0},
      {"reduction_scale", 0x3344},
      {"reduction_ratio", 0x4780},
      {"reduction_biased", 0x4800},
  }};
  constexpr int32_t kReductionInteger = 8;
#elif NUM_THREADS == 32
  const std::array<expected_step_t, 6> reduction_expected = {{
      {"reduction_minimum", 0xbfc0},
      {"reduction_maximum", 0x3ff0},
      {"reduction_range", 0x43d8},
      {"reduction_scale", 0x342f},
      {"reduction_ratio", 0x4769},
      {"reduction_biased", 0x47e9},
  }};
  constexpr int32_t kReductionInteger = 7;
#else
#error "fp16_quant_debug reduction expectations require NUM_THREADS=8 or 32"
#endif
  const std::array<uint16_t, 6> reduction_got = {{
      reduction.minimum,
      reduction.maximum,
      reduction.range,
      reduction.scale,
      reduction.ratio,
      reduction.biased,
  }};
  for (size_t i = 0; i < reduction_expected.size(); ++i) {
    const bool match =
        reduction_got[i] == reduction_expected[i].expected;
    std::printf("%-20s got=0x%04x expected=0x%04x %s\n",
                reduction_expected[i].name, reduction_got[i],
                reduction_expected[i].expected,
                match ? "PASS" : "FAIL");
    errors += !match;
  }
  std::printf("reduction_integer    got=%d expected=%d %s\n",
              reduction.integer, kReductionInteger,
              reduction.integer == kReductionInteger ? "PASS" : "FAIL");
  errors += reduction.integer != kReductionInteger;
  std::printf("helper_integer       got=%d expected=%d %s\n",
              reduction.helper_integer, kReductionInteger,
              reduction.helper_integer == kReductionInteger ? "PASS" : "FAIL");
  errors += reduction.helper_integer != kReductionInteger;
  const std::array<int32_t, 4> gap_integers = {{
      reduction.gap1_integer,
      reduction.gap2_integer,
      reduction.gap3_integer,
      reduction.gap4_integer,
  }};
  for (size_t gap = 0; gap < gap_integers.size(); ++gap) {
    std::printf("gap%zu_integer         got=%d expected=%d %s\n",
                gap + 1, gap_integers[gap], kReductionInteger,
                gap_integers[gap] == kReductionInteger ? "PASS" : "FAIL");
    errors += gap_integers[gap] != kReductionInteger;
  }

  cleanup();
  if (errors != 0) {
    std::printf("REPRODUCED: %u mismatching quant arithmetic steps\n",
                errors);
    return 1;
  }
  std::printf("PASSED\n");
  return 0;
}
