#include "common.h"
#include "../kv_cache_common/kv_cache_w4a16.h"
#include <vx_intrinsics.h>
#include <vx_spawn.h>

void kernel_kv_cache_dequant(kernel_arg_t *__UNIFORM__ arg) {
  auto src = reinterpret_cast<uint8_t *>(arg->src_addr);
  auto dst = reinterpret_cast<uint32_t *>(arg->dst_addr);
  auto scales = reinterpret_cast<fp16_t *>(arg->scale_addr);
  auto zeros = reinterpret_cast<uint16_t *>(arg->zero_addr);

  const uint32_t K = arg->K;
  const uint32_t N = arg->N;
  const uint32_t quant_mode = arg->quant_mode;
  const uint32_t row_bytes = N >> 1;
  const uint32_t total_bytes = K * row_bytes;
  const uint32_t total_threads = gridDim.x * blockDim.x;
  const uint32_t thread_id = blockIdx.x * blockDim.x + threadIdx.x;
  (void)arg->WTRANS;

  for (uint32_t byte_idx = thread_id; byte_idx < total_bytes; byte_idx += total_threads) {
    const uint32_t k = byte_idx / row_bytes;
    const uint32_t n_pair = byte_idx - k * row_bytes;
    const uint32_t n0 = n_pair << 1;
    const uint32_t n1 = n0 + 1u;
    const uint8_t packed = src[byte_idx];
    const uint8_t q0_bits = packed & 0x0fu;
    const uint8_t q1_bits = packed >> 4;
    int32_t q0 = (int32_t)q0_bits;
    int32_t q1 = (int32_t)q1_bits;
    if (quant_mode != KV_QUANT_LEGACY_UINT4_ASYMMETRIC) {
      q0 = kv_signed_int4(q0_bits);
      q1 = kv_signed_int4(q1_bits);
    }
    const uint64_t qidx0 = kv_qparam_index(k, n0, K, N, arg->QBLK, arg->QDIR);
    const uint64_t qidx1 = kv_qparam_index(k, n1, K, N, arg->QBLK, arg->QDIR);

    const float scale0 = fp16_to_float(scales[qidx0]);
    const int32_t zp0 = kv_signed_int16(zeros[qidx0]);
    float scale1 = scale0;
    int32_t zp1 = zp0;
    if (qidx1 != qidx0) {
      scale1 = fp16_to_float(scales[qidx1]);
      zp1 = kv_signed_int16(zeros[qidx1]);
    }

    const int32_t q0_minus_zp = q0 - zp0;
    const int32_t q1_minus_zp = q1 - zp1;
    const fp16_t out0 = float_to_fp16((float)q0_minus_zp * scale0);
    const fp16_t out1 = float_to_fp16((float)q1_minus_zp * scale1);
    dst[byte_idx] = (uint32_t)out0 | ((uint32_t)out1 << 16);
  }
}

void kernel_dispatcher(kernel_arg_t *__UNIFORM__ arg) {
  if (arg->kernel_id == KERNEL_KV_CACHE_DEQUANT_W4A16) kernel_kv_cache_dequant(arg);
}

static inline uint32_t effective_power_kernel_iterations(const kernel_arg_t* arg) {
  return (arg->power_kernel_iterations == 0u) ? 1u : arg->power_kernel_iterations;
}

void kernel_dispatcher_power(kernel_arg_t *__UNIFORM__ arg) {
  const uint32_t repeat = effective_power_kernel_iterations(arg);
  for (uint32_t power_iter = 0; power_iter < repeat; ++power_iter) kernel_dispatcher(arg);
}

int main() {
  auto arg = (kernel_arg_t *)csr_read(VX_CSR_MSCRATCH);
  return vx_spawn_threads(1, arg->grid_dim, arg->block_dim,
                          (vx_kernel_func_cb)kernel_dispatcher_power, arg);
}
