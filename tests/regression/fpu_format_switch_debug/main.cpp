#include <vortex.h>

#include <array>
#include <cstdint>
#include <cstdio>

#include "common.h"

#define RT_CHECK(expr)                                                   \
  do {                                                                   \
    const int status = (expr);                                           \
    if (status != 0) {                                                   \
      std::printf("Error: '%s' returned %d\n", #expr, status);           \
      cleanup();                                                         \
      return 1;                                                          \
    }                                                                    \
  } while (false)

namespace {

vx_device_h device = nullptr;
vx_buffer_h input_buffer = nullptr;
vx_buffer_h output_buffer = nullptr;
vx_buffer_h kernel_buffer = nullptr;
vx_buffer_h args_buffer = nullptr;

void cleanup() {
  if (input_buffer) vx_mem_free(input_buffer);
  if (output_buffer) vx_mem_free(output_buffer);
  if (kernel_buffer) vx_mem_free(kernel_buffer);
  if (args_buffer) vx_mem_free(args_buffer);
  if (device) vx_dev_close(device);
}

}  // namespace

int main() {
  // FP16: 1.5, 2.0. FP32: 1.5, 2.0.
  constexpr std::array<uint32_t, 4> input = {
      0x00003e00, 0x00004000, 0x3fc00000, 0x40000000};
  constexpr result_t expected = {
      0x4300, 0x4200, 1, 0x40600000, 0x40400000, 1};

  kernel_arg_t args = {};
  RT_CHECK(vx_dev_open(&device));
  RT_CHECK(vx_mem_alloc(device, sizeof(input), VX_MEM_READ, &input_buffer));
  RT_CHECK(vx_mem_alloc(device, sizeof(result_t), VX_MEM_WRITE, &output_buffer));
  RT_CHECK(vx_mem_address(input_buffer, &args.input_addr));
  RT_CHECK(vx_mem_address(output_buffer, &args.output_addr));
  RT_CHECK(vx_copy_to_dev(input_buffer, input.data(), 0, sizeof(input)));
  RT_CHECK(vx_upload_kernel_file(device, "kernel.vxbin", &kernel_buffer));
  RT_CHECK(vx_upload_bytes(device, &args, sizeof(args), &args_buffer));
  RT_CHECK(vx_start(device, kernel_buffer, args_buffer));
  RT_CHECK(vx_ready_wait(device, VX_MAX_TIMEOUT));

  result_t got = {};
  RT_CHECK(vx_copy_from_dev(&got, output_buffer, 0, sizeof(got)));
  cleanup();

  const bool pass =
      got.h_add == expected.h_add && got.h_mul == expected.h_mul
      && got.h_cmp == expected.h_cmp && got.s_add == expected.s_add
      && got.s_mul == expected.s_mul && got.s_cmp == expected.s_cmp;
  std::printf(
      "FP16 add=%04x mul=%04x cmp=%u; FP32 add=%08x mul=%08x cmp=%u: %s\n",
      got.h_add, got.h_mul, got.h_cmp, got.s_add, got.s_mul, got.s_cmp,
      pass ? "PASSED" : "FAILED");
  return pass ? 0 : 1;
}
