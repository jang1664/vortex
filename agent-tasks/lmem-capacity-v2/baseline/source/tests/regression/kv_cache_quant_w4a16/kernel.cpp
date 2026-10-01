#include "common.h"
#include "../kv_cache_common/kv_cache_w4a16.h"
#include <vx_intrinsics.h>
#include <vx_spawn.h>

static void compute_params(const fp16_t* src,
                           uint32_t K,
                           uint32_t N,
                           uint32_t QBLK,
                           uint32_t QDIR,
                           uint32_t k,
                           uint32_t n,
                           _Float16* scale_out,
                           int16_t* zp_out) {
  _Float16 min_v = kv_fp16_from_bits(src[(uint64_t)k * N + n]);
  _Float16 max_v = min_v;

  if (QDIR == 0) {
    const uint32_t k0 = (k / QBLK) * QBLK;
    const uint32_t k1 = ((k0 + QBLK) < K) ? (k0 + QBLK) : K;
    for (uint32_t kk = k0; kk < k1; ++kk) {
      _Float16 v = kv_fp16_from_bits(src[(uint64_t)kk * N + n]);
      if (v < min_v) min_v = v;
      if (v > max_v) max_v = v;
    }
  } else {
    const uint32_t n0 = (n / QBLK) * QBLK;
    const uint32_t n1 = ((n0 + QBLK) < N) ? (n0 + QBLK) : N;
    for (uint32_t nn = n0; nn < n1; ++nn) {
      _Float16 v = kv_fp16_from_bits(src[(uint64_t)k * N + nn]);
      if (v < min_v) min_v = v;
      if (v > max_v) max_v = v;
    }
  }

  const _Float16 range = max_v - min_v;
  _Float16 scale = 1.0f;
  if (range != 0.0f) {
    scale = range / 15.0f;
  }
  int32_t zp = kv_round_half_away_from_zero_fp16(-min_v / scale);
  if (zp < 0) zp = 0;
  if (zp > 15) zp = 15;
  *scale_out = scale;
  *zp_out = (int16_t)zp;
}

void kernel_kv_cache_quant(kernel_arg_t *__UNIFORM__ arg) {
  auto src = reinterpret_cast<fp16_t *>(arg->src_addr);
  auto dst = reinterpret_cast<uint8_t *>(arg->dst_addr);
  auto scales = reinterpret_cast<fp16_t *>(arg->scale_addr);
  auto zeros = reinterpret_cast<int16_t *>(arg->zero_addr);

  const uint32_t K = arg->K;
  const uint32_t N = arg->N;
  const uint32_t QBLK = arg->QBLK;
  const uint32_t QDIR = arg->QDIR;
  const uint32_t total_bytes = K * (N >> 1);
  const uint32_t total_threads = gridDim.x * blockDim.x;
  const uint32_t thread_id = blockIdx.x * blockDim.x + threadIdx.x;
  (void)arg->WTRANS;

  for (uint32_t byte_idx = thread_id; byte_idx < total_bytes; byte_idx += total_threads) {
    const uint32_t k = byte_idx / (N >> 1);
    const uint32_t n_pair = byte_idx - k * (N >> 1);
    const uint32_t n0 = n_pair << 1;
    const uint32_t n1 = n0 + 1;

    _Float16 scale0 = 1.0f;
    _Float16 scale1 = 1.0f;
    int16_t zp0 = 0;
    int16_t zp1 = 0;
    compute_params(src, K, N, QBLK, QDIR, k, n0, &scale0, &zp0);
    compute_params(src, K, N, QBLK, QDIR, k, n1, &scale1, &zp1);

    const uint64_t qidx0 = kv_qparam_index(k, n0, K, N, QBLK, QDIR);
    const uint64_t qidx1 = kv_qparam_index(k, n1, K, N, QBLK, QDIR);
    const fp16_t scale_bits0 = kv_fp16_to_bits(scale0);
    const fp16_t scale_bits1 = kv_fp16_to_bits(scale1);
    const _Float16 stored_scale0 = kv_fp16_from_bits(scale_bits0);
    const _Float16 stored_scale1 = kv_fp16_from_bits(scale_bits1);
    scales[qidx0] = scale_bits0;
    scales[qidx1] = scale_bits1;
    zeros[qidx0] = zp0;
    zeros[qidx1] = zp1;

    const _Float16 x0 = kv_fp16_from_bits(src[(uint64_t)k * N + n0]);
    const _Float16 x1 = kv_fp16_from_bits(src[(uint64_t)k * N + n1]);
    const uint8_t q0 = kv_quantize_value_scale_fp16(x0, stored_scale0, zp0);
    const uint8_t q1 = kv_quantize_value_scale_fp16(x1, stored_scale1, zp1);
    kv_store_npair(dst, N, k, n_pair, q0, q1);
  }
}

void kernel_dispatcher(kernel_arg_t *__UNIFORM__ arg) {
  switch (arg->kernel_id) {
    case KERNEL_KV_CACHE_QUANT_W4A16:
      kernel_kv_cache_quant(arg);
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
