#include "common.h"
#include <vx_spawn.h>
#include <vx_intrinsics.h>
#include <vx_math.h>

///////////////////////////////////////////////////////////////////////////////
// tile_input_a — row-major fp16 A -> GEMM input tile layout.
//
// The kernel writes two fp16 elements per thread as one aligned 32-bit store.
// Destination addressing matches docs/layout_transform/layout.md's mt-aware
// input layout and zero-fills padded rows.
//
// Grid (3D):
//   blockIdx.z = kt                       ∈ [0, k_tiles)
//   blockIdx.y = kb                       ∈ [0, k_micros)
//   blockIdx.x*blockDim.x + threadIdx.x   = cidx ∈ [0, M_pad*CHUNKS_PER_ROW)
//
// CHUNK = 2 fp16 elements = 4 bytes / thread.
// Pad rows (m >= M_real) are zero-filled (still required for downstream GEMM).
///////////////////////////////////////////////////////////////////////////////

void kernel_tile_input_a(kernel_arg_t *__UNIFORM__ arg) {
  auto src = reinterpret_cast<uint8_t *>(arg->src_addr);
  auto dst = reinterpret_cast<uint8_t *>(arg->dst_addr);
  const uint32_t M_real = arg->M_real;
  const uint32_t M_pad  = arg->M_pad;
  const uint32_t K_real = arg->K_real;
  const uint32_t K_pad  = arg->K_pad;
  const uint32_t log2_mt     = arg->log2_mt;
  const uint32_t log2_kt     = arg->log2_kt;
  const uint32_t log2_mxu_kt = arg->log2_mxu_kt;

  constexpr uint32_t CHUNK_ELEMS     = 2;                        // 2 fp16
  constexpr uint32_t CHUNK_BYTES     = CHUNK_ELEMS * 2;          // 4 B
  const uint32_t mt          = 1u << log2_mt;
  const uint32_t mt_mask     = (1u << log2_mt) - 1u;
  const uint32_t kt          = 1u << log2_kt;
  const uint32_t mxu_kt      = 1u << log2_mxu_kt;
  const uint32_t mxu_kt_mask = mxu_kt - 1u;
  const uint32_t chunks_per_row = mxu_kt / CHUNK_ELEMS;
  const uint32_t log2_chunks_per_row = log2_mxu_kt - 1u;
  const uint32_t chunks_per_row_mask = chunks_per_row - 1u;

  const uint32_t ktile = blockIdx.z;
  const uint32_t kb   = blockIdx.y;
  const uint32_t cidx = blockIdx.x * blockDim.x + threadIdx.x;

  if (cidx >= M_pad * chunks_per_row) return;

  const uint32_t m       = cidx >> log2_chunks_per_row;
  const uint32_t k_chunk = cidx & chunks_per_row_mask;
  const uint32_t k_base  = (ktile << log2_kt) + (kb << log2_mxu_kt)
                         + k_chunk * CHUNK_ELEMS;
  if (k_base >= K_pad) return;

  const uint32_t mt_idx = m >> log2_mt;
  const uint32_t m0 = m & mt_mask;
  const uint32_t cm = ((M_pad - (mt_idx << log2_mt)) < mt)
                    ? (M_pad - (mt_idx << log2_mt))
                    : mt;
  const uint32_t km = k_base >> log2_mxu_kt;
  const uint32_t k0 = k_base & mxu_kt_mask;
  const uint64_t out_elem_off =
      (uint64_t)mt_idx * mt * K_pad
    + (uint64_t)km * cm * mxu_kt
    + (uint64_t)m0 * mxu_kt
    + k0;
  const uint64_t out_byte_off = out_elem_off * TILE_ELEM_BYTES;

  uint32_t v = 0;
  if (m < M_real && k_base < K_real) {
    const uint64_t src_elem_off = (uint64_t)m * K_real + k_base;
    if (k_base + 1u < K_real) {
      v = *reinterpret_cast<const uint32_t *>(src + src_elem_off * TILE_ELEM_BYTES);
    } else {
      v = *reinterpret_cast<const uint16_t *>(src + src_elem_off * TILE_ELEM_BYTES);
    }
  }
  *reinterpret_cast<uint32_t *>(dst + out_byte_off) = v;
}

void kernel_dispatcher(kernel_arg_t *__UNIFORM__ arg) {
  kernel_tile_input_a(arg);
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
  return vx_spawn_threads(3, arg->grid_dim, arg->block_dim,
                          (vx_kernel_func_cb)kernel_dispatcher_power, arg);
}
