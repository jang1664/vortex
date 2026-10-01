#include "common.h"
#include <vx_spawn.h>
#include <vx_intrinsics.h>

///////////////////////////////////////////////////////////////////////////////
// detile_output — fast version (3D grid + per-element thread)
//
// Grid layout:
//   blockIdx.z = nt                              ∈ [0, n_tiles)
//   blockIdx.y = m                               ∈ [0, M)            (REAL rows)
//   blockIdx.x*blockDim.x + threadIdx.x = ncol   ∈ [0, MXU_NT)
//
// Each thread copies one 2-byte fp16 element. Decoding uses only compile-time
// MXU_NT — no runtime divisions inside the kernel.
//
// Source layout (kernel writes this — nt-major over M_pad rows):
//   src[ nt * (M_pad*MXU_NT) + m * MXU_NT + n_in_sub ]
// Destination layout (row-major, real M rows and real N columns only):
//   dst[ m * N_real + (nt*MXU_NT + n_in_sub) ]
///////////////////////////////////////////////////////////////////////////////

void kernel_detile_output(kernel_arg_t *__UNIFORM__ arg) {
  auto src = reinterpret_cast<uint8_t *>(arg->src_addr);
  auto dst = reinterpret_cast<uint8_t *>(arg->dst_addr);
  const uint32_t M     = arg->M;
  const uint32_t M_pad = arg->M_pad;
  const uint32_t N_real = arg->N_real;
  const uint32_t N_pad  = arg->N_pad;
  const uint32_t log2_mt     = arg->log2_mt;
  const uint32_t log2_mxu_nt = arg->log2_mxu_nt;

  const uint32_t mt      = 1u << log2_mt;
  const uint32_t mt_mask = mt - 1u;
  const uint32_t mxu_nt  = 1u << log2_mxu_nt;
  const uint32_t mxu_nt_mask = mxu_nt - 1u;

  const uint32_t nt32 = blockIdx.z;
  const uint32_t m    = blockIdx.y;
  const uint32_t ncol = blockIdx.x * blockDim.x + threadIdx.x;
  const uint32_t n    = (nt32 << log2_mxu_nt) + ncol;

  if (ncol >= mxu_nt) return;
  if (m    >= M)      return;
  if (n    >= N_real) return;

  const uint32_t mt_idx = m >> log2_mt;
  const uint32_t m0 = m & mt_mask;
  const uint32_t cm = ((M_pad - (mt_idx << log2_mt)) < mt)
                    ? (M_pad - (mt_idx << log2_mt))
                    : mt;
  const uint64_t src_byte_off =
      ((uint64_t)mt_idx * mt * N_pad
     + (uint64_t)nt32 * cm * mxu_nt
     + (uint64_t)m0 * mxu_nt
     + (ncol & mxu_nt_mask)) * TILE_ELEM_BYTES;

  // Destination: row-major [M, N_real]
  const uint64_t dst_byte_off =
      ((uint64_t)m * N_real + n) * TILE_ELEM_BYTES;

  *reinterpret_cast<uint16_t *>(dst + dst_byte_off) =
      *reinterpret_cast<const uint16_t *>(src + src_byte_off);
}

void kernel_dispatcher(kernel_arg_t *__UNIFORM__ arg) {
  kernel_detile_output(arg);
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
