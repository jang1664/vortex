#include "common.h"
#include "../vector_common/fp16.h"
#include <VX_config.h>
#include <vx_intrinsics.h>
#include <vx_math.h>
#include <vx_spawn.h>

using data_t = fp16_t;

// This variant launches one warp per block, so all resident warps can own a
// local-memory partition concurrently.  Keep each partition within LMEM and
// align it to a full warp access.  Elements beyond the partition are
// recomputed from input instead of spilling through the LMEM address window.
static constexpr uint32_t kLocalScoreCapacity =
    (((1u << LMEM_LOG_SIZE) / NUM_WARPS / (uint32_t)sizeof(float))
      / NUM_THREADS) * NUM_THREADS;
static constexpr uint32_t kLocalScoreBytes =
    kLocalScoreCapacity * (uint32_t)sizeof(float);

static_assert(kLocalScoreCapacity != 0,
              "LMEM is too small for one warp of softmax scores");

static inline uint32_t float_to_bits(float value) {
  union {
    float f;
    uint32_t u;
  } bits;
  bits.f = value;
  return bits.u;
}

static inline float bits_to_float(uint32_t value) {
  union {
    uint32_t u;
    float f;
  } bits;
  bits.u = value;
  return bits.f;
}

static inline float shfl_down_float(float value, uint32_t offset) {
  return bits_to_float((uint32_t)vx_shfl_down(
      float_to_bits(value), offset, NUM_THREADS - 1, 0));
}

static inline float shfl_idx_float(float value, uint32_t index) {
  return bits_to_float((uint32_t)vx_shfl_idx(
      float_to_bits(value), index, NUM_THREADS - 1, 0));
}

static inline float warp_reduce_max(float value, uint32_t lane) {
  for (uint32_t offset = NUM_THREADS >> 1; offset > 0; offset >>= 1) {
    const float other = shfl_down_float(value, offset);
    if (lane + offset < NUM_THREADS && other > value)
      value = other;
  }
  return shfl_idx_float(value, 0);
}

static inline float warp_reduce_sum(float value, uint32_t lane) {
  for (uint32_t offset = NUM_THREADS >> 1; offset > 0; offset >>= 1) {
    const float other = shfl_down_float(value, offset);
    if (lane + offset < NUM_THREADS)
      value += other;
  }
  return shfl_idx_float(value, 0);
}

static inline void softmax_row_shuffle_grouped(
    data_t *input,
    data_t *output,
    uint32_t seq_len_k,
    uint32_t q,
    uint32_t use_mask,
    float scale,
    uint32_t lane) {
  const uint32_t k_end = use_mask && q + 1u < seq_len_k
      ? q + 1u
      : seq_len_k;
  auto scores = reinterpret_cast<float *>(
      __local_mem(kLocalScoreBytes));

  float local_max = VX_NEG_INF;
  if (lane < k_end) {
    data_t *load = input + lane;
    for (uint32_t k = lane; k < k_end; k += NUM_THREADS) {
      const float value = fp16_to_float(*load) * scale;
      if (k < kLocalScoreCapacity)
        scores[k] = value;
      if (value > local_max)
        local_max = value;
      load += NUM_THREADS;
    }
  }
  const float global_max = warp_reduce_max(local_max, lane);

  float local_sum = 0.0f;
  for (uint32_t k = lane; k < k_end; k += NUM_THREADS) {
    const float value = k < kLocalScoreCapacity
        ? scores[k]
        : fp16_to_float(input[k]) * scale;
    const float exp_value = vx_expf(value - global_max);
    if (k < kLocalScoreCapacity)
      scores[k] = exp_value;
    local_sum += exp_value;
  }
  const float inv_sum = 1.0f / warp_reduce_sum(local_sum, lane);

  if (lane < k_end) {
    data_t *store = output + lane;
    for (uint32_t k = lane; k < k_end; k += NUM_THREADS) {
      const float exp_value = k < kLocalScoreCapacity
          ? scores[k]
          : vx_expf(fp16_to_float(input[k]) * scale - global_max);
      *store = float_to_fp16(exp_value * inv_sum);
      store += NUM_THREADS;
    }
  }
  for (uint32_t k = k_end + lane; k < seq_len_k; k += NUM_THREADS) {
    output[k] = float_to_fp16(0.0f);
  }
}

void kernel_softmax(kernel_arg_t *__UNIFORM__ arg) {
  const uint32_t rows_total =
      arg->batch_size * arg->num_heads * arg->seq_len_q;
  auto input_base = reinterpret_cast<uint8_t *>(arg->input_addr);
  auto output_base = reinterpret_cast<uint8_t *>(arg->output_addr);

  for (uint32_t row_idx = blockIdx.x;
       row_idx < rows_total;
       row_idx += gridDim.x) {
    auto input = reinterpret_cast<data_t *>(
        input_base + row_idx * arg->row_pitch_bytes);
    auto output = reinterpret_cast<data_t *>(
        output_base + row_idx * arg->row_pitch_bytes);
    const uint32_t q = row_idx % arg->seq_len_q;

    softmax_row_shuffle_grouped(
        input, output, arg->seq_len_k,
        q, arg->use_mask, arg->scale, threadIdx.x);
  }
}

void kernel_dispatcher(kernel_arg_t *__UNIFORM__ arg) {
  if (arg->kernel_id == KERNEL_SOFTMAX)
    kernel_softmax(arg);
}

static inline uint32_t effective_power_kernel_iterations(
    const kernel_arg_t *arg) {
  return arg->power_kernel_iterations == 0u
      ? 1u : arg->power_kernel_iterations;
}

void kernel_dispatcher_power(kernel_arg_t *__UNIFORM__ arg) {
  const uint32_t repeat = effective_power_kernel_iterations(arg);
  for (uint32_t power_iter = 0; power_iter < repeat; ++power_iter)
    kernel_dispatcher(arg);
}

int main() {
  auto arg = reinterpret_cast<kernel_arg_t *>(csr_read(VX_CSR_MSCRATCH));
  return vx_spawn_threads(
      1, arg->grid_dim, arg->block_dim,
      reinterpret_cast<vx_kernel_func_cb>(kernel_dispatcher_power), arg);
}
