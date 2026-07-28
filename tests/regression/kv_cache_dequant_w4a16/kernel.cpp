#include "common.h"
#include "../kv_cache_common/kv_cache_w4a16.h"
#include <vx_intrinsics.h>
#include <vx_spawn.h>

void kernel_kv_cache_dequant(kernel_arg_t *__UNIFORM__ arg) {
  auto src = reinterpret_cast<uint8_t *>(arg->src_addr);
  auto dst = reinterpret_cast<fp16_t *>(arg->dst_addr);
  auto scales = reinterpret_cast<fp16_t *>(arg->scale_addr);
  auto zeros = reinterpret_cast<uint16_t *>(arg->zero_addr);

  const uint32_t K = arg->K;
  const uint32_t N = arg->N;
  const uint32_t QBLK = arg->QBLK;
  const uint32_t QDIR = arg->QDIR;
  const uint32_t quant_mode = arg->quant_mode;
  const uint32_t total = K * N;
  const uint32_t total_threads = gridDim.x * blockDim.x;
  const uint32_t thread_id = blockIdx.x * blockDim.x + threadIdx.x;
  (void)arg->WTRANS;

  for (uint32_t idx = thread_id; idx < total; idx += total_threads) {
    const uint32_t k = idx / N;
    const uint32_t n = idx - k * N;
    const uint8_t q_bits = kv_get_nibble(src, K, N, k, n);
    const int32_t q = quant_mode == KV_QUANT_LEGACY_UINT4_ASYMMETRIC
        ? (int32_t)q_bits
        : (int32_t)kv_signed_int4(q_bits);
    const uint64_t qidx = kv_qparam_index(k, n, K, N, QBLK, QDIR);
    const _Float16 scale = kv_fp16_from_bits(scales[qidx]);
    const int32_t zp = kv_signed_int16(zeros[qidx]);
    const int32_t q_minus_zp = q - zp;
    dst[idx] = kv_fp16_to_bits((_Float16)q_minus_zp * scale);
  }
}

void kernel_dispatcher(kernel_arg_t *__UNIFORM__ arg) {
  switch (arg->kernel_id) {
    case KERNEL_KV_CACHE_DEQUANT_W4A16:
      kernel_kv_cache_dequant(arg);
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
