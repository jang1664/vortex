#include "../vector_common/fp16.h"
#include "common.h"

#include <vx_intrinsics.h>
#include <vx_spawn.h>

using data_t = fp16_t;

void kernel_hadamard_base(kernel_arg_t *__UNIFORM__ arg) {
  auto input = reinterpret_cast<const data_t *>(arg->input_addr);
  auto matrix = reinterpret_cast<const data_t *>(arg->matrix_addr);
  auto output = reinterpret_cast<data_t *>(arg->output_addr);
  const uint32_t total = arg->rows * arg->base_k * arg->width;
  const uint32_t index = blockIdx.x * blockDim.x + threadIdx.x;
  if (index >= total)
    return;

  const uint32_t col = index % arg->width;
  const uint32_t out_k = (index / arg->width) % arg->base_k;
  const uint32_t row = index / (arg->width * arg->base_k);
  const uint64_t row_base = (uint64_t)row * arg->base_k * arg->width;
  float sum = 0.0f;
  for (uint32_t in_k = 0; in_k < arg->base_k; ++in_k) {
    const float coefficient =
        fp16_to_float(matrix[(uint64_t)out_k * arg->base_k + in_k]);
    const float value =
        fp16_to_float(input[row_base + (uint64_t)in_k * arg->width + col]);
    sum += coefficient * value;
  }
  output[index] = float_to_fp16(sum);
}

void kernel_dispatcher(kernel_arg_t *__UNIFORM__ arg) {
  if (arg->kernel_id == KERNEL_HADAMARD_BASE)
    kernel_hadamard_base(arg);
}

void kernel_dispatcher_power(kernel_arg_t *__UNIFORM__ arg) {
  const uint32_t repeat =
      (arg->power_kernel_iterations == 0) ? 1 : arg->power_kernel_iterations;
  for (uint32_t iteration = 0; iteration < repeat; ++iteration)
    kernel_dispatcher(arg);
}

int main() {
  auto arg = reinterpret_cast<kernel_arg_t *>(csr_read(VX_CSR_MSCRATCH));
  return vx_spawn_threads(1, arg->grid_dim, arg->block_dim,
                          reinterpret_cast<vx_kernel_func_cb>(kernel_dispatcher_power), arg);
}
