#include "common.h"
#include <vx_spawn.h>
#include <vx_intrinsics.h>

///////////////////////////////////////////////////////////////////////////////
// tile_weight_w4a16 — fast version (3D grid + 16-B per thread)
//
// Reorders packed-int4 weight from row-major [K, N/2] to the tile-major
// layout the fpint_gemm_ffn_hw kernel expects in DRAM. Mirrors
// fpint_gemm_ffn_hw/main.cpp::convert_weight_tiled:
//
//   WTRANS=0:
//   for kt:   for nt:   for kb:   for k_in_sub:   for pair:
//     dst[idx++] = src[ (kt*DMA_KT + kb*MXU_KT + k_in_sub) * (N/2)
//                       + nt*pair_per_sub + pair ]
//
//   WTRANS=1:
//   for kt:   for nt:   for kb:   for n_in_sub:   for k_pair:
//     dst[idx++] = pack(src[kt/kb/k_pair*2, nt/n], src[kt/kb/k_pair*2+1, nt/n])
//
// Grid layout (3D — avoids ALL runtime divisions):
//   blockIdx.z = kt                                   ∈ [0, k_tiles)
//   blockIdx.y = nt                                   ∈ [0, n_tiles)
//   blockIdx.x * blockDim.x + threadIdx.x = cnk       ∈ [0, cur_kb*MXU_KT)
//
// Each thread copies ONE 16-byte chunk (the inner "pair" loop, flattened).
// Inside-block divisions are by MXU_KT (compile-time = 32 → shift).
///////////////////////////////////////////////////////////////////////////////

void kernel_tile_weight_w4a16(kernel_arg_t *__UNIFORM__ arg) {
  auto src = reinterpret_cast<uint8_t *>(arg->src_addr);
  auto dst = reinterpret_cast<uint8_t *>(arg->dst_addr);
  const uint32_t K = arg->K;
  const uint32_t N = arg->N;
  const uint32_t WTRANS = arg->WTRANS;
  const uint32_t SOURCE_TRANSPOSED = arg->SOURCE_TRANSPOSED;
  const uint32_t log2_kt = arg->log2_kt;
  const uint32_t log2_mxu_kt = arg->log2_mxu_kt;
  const uint32_t log2_mxu_nt = arg->log2_mxu_nt;

  const uint32_t kt_size = 1u << log2_kt;
  const uint32_t mxu_kt = 1u << log2_mxu_kt;
  const uint32_t mxu_nt = 1u << log2_mxu_nt;
  const uint32_t mxu_kt_mask = mxu_kt - 1u;
  const uint32_t pair_per_n_sub = mxu_nt >> 1;              // WTRANS=0
  const uint32_t pair_per_k_sub = mxu_kt >> 1;              // WTRANS=1

  const uint32_t src_row_bytes = N / 2;

  if (SOURCE_TRANSPOSED != 0) {
    if (WTRANS == 0) return;

    const uint32_t logical_K = N;
    const uint32_t logical_N = K;
    const uint32_t logical_row_bytes = logical_N >> 1;
    const uint32_t kt  = blockIdx.z;
    const uint32_t nt  = blockIdx.y;
    const uint32_t tid = blockIdx.x * blockDim.x + threadIdx.x;

    const uint32_t kt_start = kt << log2_kt;
    const uint32_t ck = ((logical_K - kt_start) < kt_size) ? (logical_K - kt_start) : kt_size;
    const uint32_t cur_kb = ck >> log2_mxu_kt;
    const uint32_t bytes_per_nt_kt = cur_kb * mxu_nt * pair_per_k_sub;
    if (tid >= bytes_per_nt_kt) return;

    const uint32_t log2_micro_bytes = log2_mxu_nt + log2_mxu_kt - 1u;
    const uint32_t micro_bytes = 1u << log2_micro_bytes;
    const uint32_t kb = tid >> log2_micro_bytes;
    const uint32_t in_micro = tid & (micro_bytes - 1u);
    const uint32_t n_in_sub = in_micro >> (log2_mxu_kt - 1u);
    const uint32_t k_pair = in_micro & (pair_per_k_sub - 1u);

    const uint32_t logical_k0 = kt_start + (kb << log2_mxu_kt) + (k_pair << 1);
    const uint32_t logical_k1 = logical_k0 + 1;
    const uint32_t logical_n = (nt << log2_mxu_nt) + n_in_sub;

    const uint8_t b0 = src[(uint64_t)logical_n * src_row_bytes + (logical_k0 >> 1)];
    const uint8_t b1 = src[(uint64_t)logical_n * src_row_bytes + (logical_k1 >> 1)];
    const uint8_t w0 = (logical_k0 & 1u) ? (b0 >> 4) : (b0 & 0x0f);
    const uint8_t w1 = (logical_k1 & 1u) ? (b1 >> 4) : (b1 & 0x0f);

    const uint64_t kt_base = (uint64_t)kt * kt_size * logical_row_bytes;
    const uint64_t nt_base = (uint64_t)nt * ck * pair_per_n_sub;
    const uint64_t dst_off = kt_base + nt_base + (uint64_t)tid;
    dst[dst_off] = (w0 & 0x0f) | (uint8_t)((w1 & 0x0f) << 4);
    return;
  }

  const uint32_t row_bytes = src_row_bytes;

  const uint32_t kt  = blockIdx.z;
  const uint32_t nt  = blockIdx.y;
  const uint32_t tid = blockIdx.x * blockDim.x + threadIdx.x;

  const uint32_t kt_start = kt << log2_kt;
  const uint32_t ck = ((K - kt_start) < kt_size) ? (K - kt_start) : kt_size;
  const uint32_t cur_kb = ck >> log2_mxu_kt;
  const uint64_t kt_base = (uint64_t)kt * kt_size * row_bytes;
  const uint64_t nt_base = (uint64_t)nt * ck * pair_per_n_sub;

  if (WTRANS == 0) {
    const uint32_t chunks_per_nt_kt = cur_kb << log2_mxu_kt;
    if (tid >= chunks_per_nt_kt) return;

    const uint32_t kb       = tid >> log2_mxu_kt;
    const uint32_t k_in_sub = tid & mxu_kt_mask;
    const uint32_t gk = kt_start + (kb << log2_mxu_kt) + k_in_sub;
    const uint64_t src_off = (uint64_t)gk * row_bytes + (uint64_t)nt * pair_per_n_sub;

    const uint64_t dst_off = kt_base + nt_base + (uint64_t)tid * pair_per_n_sub;

    // 16-byte copy: two 64-bit loads/stores (src/dst are both 16-B aligned).
    uint64_t* sp = reinterpret_cast<uint64_t*>(src + src_off);
    uint64_t* dp = reinterpret_cast<uint64_t*>(dst + dst_off);
    dp[0] = sp[0];
    dp[1] = sp[1];
    return;
  }

  const uint32_t bytes_per_nt_kt = cur_kb * mxu_nt * pair_per_k_sub;
  if (tid >= bytes_per_nt_kt) return;

  const uint32_t log2_micro_bytes = log2_mxu_nt + log2_mxu_kt - 1u;
  const uint32_t micro_bytes = 1u << log2_micro_bytes;
  const uint32_t kb = tid >> log2_micro_bytes;
  const uint32_t in_micro = tid & (micro_bytes - 1u);
  const uint32_t n_in_sub = in_micro >> (log2_mxu_kt - 1u);
  const uint32_t k_pair = in_micro & (pair_per_k_sub - 1u);

  const uint32_t gk0 = kt_start + (kb << log2_mxu_kt) + (k_pair << 1);
  const uint32_t gk1 = gk0 + 1;
  const uint32_t gn = (nt << log2_mxu_nt) + n_in_sub;

  const uint8_t b0 = src[(uint64_t)gk0 * row_bytes + (gn >> 1)];
  const uint8_t b1 = src[(uint64_t)gk1 * row_bytes + (gn >> 1)];
  const uint8_t w0 = (gn & 1u) ? (b0 >> 4) : (b0 & 0x0f);
  const uint8_t w1 = (gn & 1u) ? (b1 >> 4) : (b1 & 0x0f);

  const uint64_t dst_off = kt_base + nt_base + (uint64_t)tid;
  dst[dst_off] = (w0 & 0x0f) | (uint8_t)((w1 & 0x0f) << 4);
}

void kernel_dispatcher(kernel_arg_t *__UNIFORM__ arg) {
  kernel_tile_weight_w4a16(arg);
}

int main() {
  auto arg = (kernel_arg_t *)csr_read(VX_CSR_MSCRATCH);
  return vx_spawn_threads(3, arg->grid_dim, arg->block_dim,
                          (vx_kernel_func_cb)kernel_dispatcher, arg);
}
