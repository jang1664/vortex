#include "common.h"
#include <vx_spawn.h>
#include <vx_intrinsics.h>
#include <vx_math.h>

///////////////////////////////////////////////////////////////////////////////
// tile_input_a — workaround patterned after silu_layout_fused
//
// The plain fp16 byte-copy version of this kernel was intermittently hanging
// on the c8c5d0d4f3 bitstream (likely partial-word store transactions). The
// fp32 silu kernel right next door ran reliably. This version copies that
// structure: 4-byte (uint32) stores per thread + a small dummy fp32 compute
// load to keep the pipeline pattern similar to silu_layout_fused. The math
// is intentionally throwaway (output values are wrong vs a pure copy) — this
// is a debug workaround for collecting Perfetto traces without hangs.
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
  const uint32_t K      = arg->K;

  constexpr uint32_t MXU_KT          = TILE_DMA_MXU_KT;        // 32
  constexpr uint32_t DMA_KT          = TILE_DMA_KT;             // 128
  constexpr uint32_t CHUNK_ELEMS     = 2;                        // 2 fp16
  constexpr uint32_t CHUNK_BYTES     = CHUNK_ELEMS * 2;          // 4 B
  constexpr uint32_t CHUNKS_PER_ROW  = MXU_KT / CHUNK_ELEMS;     // 16
  constexpr uint32_t LOG2_CHUNKS_PER_ROW = 4;                    // log2(16)
  constexpr uint32_t CHUNKS_PER_ROW_MASK = CHUNKS_PER_ROW - 1;   // 15

  const uint32_t kt   = blockIdx.z;
  const uint32_t kb   = blockIdx.y;
  const uint32_t cidx = blockIdx.x * blockDim.x + threadIdx.x;

  if (cidx >= M_pad * CHUNKS_PER_ROW) return;

  const uint32_t m       = cidx >> LOG2_CHUNKS_PER_ROW;
  const uint32_t k_chunk = cidx & CHUNKS_PER_ROW_MASK;

  // Destination offset (chunk-units = 4 bytes).
  const uint64_t chunks_per_kb_kt = (uint64_t)M_pad * CHUNKS_PER_ROW;
  const uint64_t chunks_per_kt    = (uint64_t)gridDim.y * chunks_per_kb_kt;
  const uint64_t chunk_idx_global =
      (uint64_t)kt * chunks_per_kt
    + (uint64_t)kb * chunks_per_kb_kt
    + (uint64_t)cidx;
  const uint64_t out_byte_off = chunk_idx_global * CHUNK_BYTES;

  uint32_t v = 0;
  if (m < M_real) {
    const uint32_t k_base = kt * DMA_KT + kb * MXU_KT + k_chunk * CHUNK_ELEMS;
    const uint64_t src_byte_off = ((uint64_t)m * K + (uint64_t)k_base) * 2;
    v = *reinterpret_cast<const uint32_t *>(src + src_byte_off);

    // Dummy fp32 compute (mimics silu_layout_fused's stable pipeline pattern).
    // Result is folded back into v but the math is intentionally lossy — this
    // is a debug workaround to avoid the partial-word hang while we collect
    // timing traces. Output VALUES will not match a pure copy.
    float lo_f = (float)(int)(v & 0xFFFF) * (1.0f / 32768.0f);
    float hi_f = (float)(int)((v >> 16) & 0xFFFF) * (1.0f / 32768.0f);
    lo_f = lo_f / (1.0f + vx_expf(-lo_f));
    hi_f = hi_f / (1.0f + vx_expf(-hi_f));
    uint32_t lo_b = (uint32_t)(int)(lo_f * 32768.0f) & 0xFFFF;
    uint32_t hi_b = (uint32_t)(int)(hi_f * 32768.0f) & 0xFFFF;
    v = (hi_b << 16) | lo_b;
  }
  *reinterpret_cast<uint32_t *>(dst + out_byte_off) = v;
}

void kernel_dispatcher(kernel_arg_t *__UNIFORM__ arg) {
  kernel_tile_input_a(arg);
}

int main() {
  auto arg = (kernel_arg_t *)csr_read(VX_CSR_MSCRATCH);
  return vx_spawn_threads(3, arg->grid_dim, arg->block_dim,
                          (vx_kernel_func_cb)kernel_dispatcher, arg);
}
