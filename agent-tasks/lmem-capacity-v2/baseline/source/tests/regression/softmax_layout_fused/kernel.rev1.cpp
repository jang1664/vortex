#include "common.h"
#include "../layout_fused_common/layout_fused_layouts.h"
#include "../vector_common/fp16.h"
#include <vx_spawn.h>
#include <vx_intrinsics.h>
#include <vx_math.h>

using data_t = fp16_t;

void kernel_softmax_layout_fused(kernel_arg_t *__UNIFORM__ arg) {
  auto input = reinterpret_cast<data_t *>(arg->input_addr);
  auto output = reinterpret_cast<data_t *>(arg->output_addr);

  const uint32_t num_heads = arg->num_heads;
  const uint32_t seq_len_q = arg->seq_len_q;
  const uint32_t seq_len_k = arg->seq_len_k;
  const uint32_t input_k_pad = arg->seq_len_k_pad;
  const uint32_t output_k_pad = arg->output_k_pad;
  const uint32_t M_pad = arg->M_pad;
  const uint32_t use_mask = arg->use_mask;
  const float scale = arg->scale;

  const uint32_t rows_total = arg->batch_size * num_heads * seq_len_q;
  const uint32_t row_idx = blockIdx.x;
  if (row_idx >= rows_total) return;

  const uint32_t b = row_idx / (num_heads * seq_len_q);
  const uint32_t rem = row_idx - b * num_heads * seq_len_q;
  const uint32_t h = rem / seq_len_q;
  const uint32_t q = rem - h * seq_len_q;
  const uint32_t matrix_idx = b * num_heads + h;
  const uint64_t input_base = batched_matrix_base(
      matrix_idx, (uint64_t)M_pad * input_k_pad);
  const uint64_t output_base = batched_matrix_base(
      matrix_idx, (uint64_t)M_pad * output_k_pad);

  const uint32_t tid = threadIdx.x;
  const uint32_t block_size = blockDim.x;
  auto cache = reinterpret_cast<float *>(__local_mem(block_size * sizeof(float)));

  float local_max = VX_NEG_INF;
  for (uint32_t k = tid; k < seq_len_k; k += block_size) {
    const uint64_t in_off = input_base + gemm_c_tiled_elem_offset(
        q, k, M_pad, input_k_pad, arg->log2_mt, arg->log2_mxu_nt);
    float v = fp16_to_float(input[in_off]) * scale;
    if (use_mask && k > q) {
      v = VX_NEG_INF;
    }
    if (v > local_max) {
      local_max = v;
    }
  }
  cache[tid] = local_max;
  __syncthreads();

  for (uint32_t s = block_size >> 1; s > 0; s >>= 1) {
    if (tid < s && cache[tid + s] > cache[tid]) {
      cache[tid] = cache[tid + s];
    }
    __syncthreads();
  }
  const float global_max = cache[0];
  __syncthreads();

  float local_sum = 0.0f;
  for (uint32_t k = tid; k < seq_len_k; k += block_size) {
    const uint64_t in_off = input_base + gemm_c_tiled_elem_offset(
        q, k, M_pad, input_k_pad, arg->log2_mt, arg->log2_mxu_nt);
    float v = fp16_to_float(input[in_off]) * scale;
    if (use_mask && k > q) {
      v = VX_NEG_INF;
    }
    local_sum += vx_expf(v - global_max);
  }
  cache[tid] = local_sum;
  __syncthreads();

  for (uint32_t s = block_size >> 1; s > 0; s >>= 1) {
    if (tid < s) {
      cache[tid] += cache[tid + s];
    }
    __syncthreads();
  }
  const float inv_sum = 1.0f / cache[0];
  __syncthreads();

  for (uint32_t k = tid; k < seq_len_k; k += block_size) {
    const uint64_t in_off = input_base + gemm_c_tiled_elem_offset(
        q, k, M_pad, input_k_pad, arg->log2_mt, arg->log2_mxu_nt);
    const uint64_t out_off = output_base + gemm_a_tiled_elem_offset(
        q, k, M_pad, output_k_pad, arg->log2_mt, arg->log2_mxu_kt);
    float v = fp16_to_float(input[in_off]) * scale;
    if (use_mask && k > q) {
      v = VX_NEG_INF;
    }
    output[out_off] = float_to_fp16(vx_expf(v - global_max) * inv_sum);
  }

  for (uint32_t k = seq_len_k + tid; k < output_k_pad; k += block_size) {
    const uint64_t out_off = output_base + gemm_a_tiled_elem_offset(
        q, k, M_pad, output_k_pad, arg->log2_mt, arg->log2_mxu_kt);
    output[out_off] = float_to_fp16(0.0f);
  }
}

void kernel_dispatcher(kernel_arg_t *__UNIFORM__ arg) {
  switch (arg->kernel_id) {
    case KERNEL_SOFTMAX_LAYOUT_FUSED:
      kernel_softmax_layout_fused(arg);
      break;
    default:
      break;
  }
}

static inline uint32_t effective_power_kernel_iterations(const kernel_arg_t* arg) {
  return (arg->power_kernel_iterations == 0u) ? 1u : arg->power_kernel_iterations;
}

void kernel_dispatcher_power(kernel_arg_t *__UNIFORM__ arg) {
  const uint32_t repeat = effective_power_kernel_iterations(arg);
  for (uint32_t power_iter = 0; power_iter < repeat; ++power_iter) {
    kernel_dispatcher(arg);
  }
}

int main() {
  auto arg = (kernel_arg_t *)csr_read(VX_CSR_MSCRATCH);
  return vx_spawn_threads(1, arg->grid_dim, arg->block_dim,
                          (vx_kernel_func_cb)kernel_dispatcher_power, arg);
}
