#include "common.h"
#include "../kv_cache_common/kv_cache_w4a16.h"
#include <vx_intrinsics.h>
#include <vx_spawn.h>

void kernel_kv_cache_dequant(kernel_arg_t *__UNIFORM__ arg) {
  auto src = reinterpret_cast<uint8_t *>(arg->src_addr);
  auto dst = reinterpret_cast<fp16_t *>(arg->dst_addr);
  auto scales = reinterpret_cast<fp16_t *>(arg->scale_addr);
  auto zeros = reinterpret_cast<int16_t *>(arg->zero_addr);

  const uint32_t K = arg->K;
  const uint32_t N = arg->N;
  const uint32_t QBLK = arg->QBLK;
  const uint32_t QDIR = arg->QDIR;
  const uint32_t total = K * N;
  const uint32_t total_threads = gridDim.x * blockDim.x;
  const uint32_t thread_id = blockIdx.x * blockDim.x + threadIdx.x;
  (void)arg->WTRANS;

  for (uint32_t idx = thread_id; idx < total; idx += total_threads) {
    const uint32_t k = idx / N;
    const uint32_t n = idx - k * N;
    const uint8_t q = kv_get_nibble(src, K, N, k, n);
    const uint64_t qidx = kv_qparam_index(k, n, K, N, QBLK, QDIR);
    const float scale = fp16_to_float(scales[qidx]);
    const int16_t zp = zeros[qidx];
    dst[idx] = float_to_fp16(((float)q - (float)zp) * scale);
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

int main() {
  auto arg = (kernel_arg_t *)csr_read(VX_CSR_MSCRATCH);
  return vx_spawn_threads(1, arg->grid_dim, arg->block_dim,
                          (vx_kernel_func_cb)kernel_dispatcher, arg);
}
