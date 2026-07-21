#include "common.h"
#include "../vector_common/fp16.h"
#include <vx_intrinsics.h>
#include <vx_math.h>
#include <vx_spawn.h>

using data_t = fp16_t;

#include "../softmax_common/kernel.simt_cached.h"

struct RowMajorAccessor {
  data_t *input;
  data_t *output;

  data_t load(uint32_t k) const {
    return input[k];
  }

  void store(uint32_t k, data_t value) const {
    output[k] = value;
  }
};

void kernel_softmax(kernel_arg_t *__UNIFORM__ arg) {
  const uint32_t rows_total =
      arg->batch_size * arg->num_heads * arg->seq_len_q;
  auto input_base = reinterpret_cast<uint8_t *>(arg->input_addr);
  auto output_base = reinterpret_cast<uint8_t *>(arg->output_addr);

  for (uint32_t row_idx = blockIdx.x;
       row_idx < rows_total;
       row_idx += gridDim.x) {
    RowMajorAccessor accessor = {
        reinterpret_cast<data_t *>(input_base + row_idx * arg->row_pitch_bytes),
        reinterpret_cast<data_t *>(output_base + row_idx * arg->row_pitch_bytes),
    };

    const uint32_t q = row_idx % arg->seq_len_q;
    softmax_simt_cached(accessor,
                        arg->seq_len_k,
                        arg->row_pitch_bytes / (uint32_t)sizeof(data_t),
                        q,
                        arg->use_mask,
                        arg->scale,
                        threadIdx.x,
                        blockDim.x);
  }
}

void kernel_dispatcher(kernel_arg_t *__UNIFORM__ arg) {
  if (arg->kernel_id == KERNEL_SOFTMAX) {
    kernel_softmax(arg);
  }
}

static inline uint32_t effective_power_kernel_iterations(const kernel_arg_t *arg) {
  return (arg->power_kernel_iterations == 0u) ? 1u : arg->power_kernel_iterations;
}

void kernel_dispatcher_power(kernel_arg_t *__UNIFORM__ arg) {
  const uint32_t repeat = effective_power_kernel_iterations(arg);
  for (uint32_t power_iter = 0; power_iter < repeat; ++power_iter) {
    kernel_dispatcher(arg);
  }
}

int main() {
  auto arg = reinterpret_cast<kernel_arg_t *>(csr_read(VX_CSR_MSCRATCH));
  return vx_spawn_threads(1, arg->grid_dim, arg->block_dim,
                          (vx_kernel_func_cb)kernel_dispatcher_power, arg);
}
