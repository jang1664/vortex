#include "common.h"
#include "../layout_fused_common/layout_fused_layouts.h"
#include "../vector_common/fp16.h"
#include <vx_spawn.h>
#include <vx_intrinsics.h>
#include <vx_math.h>
#include <VX_config.h>

using data_t = fp16_t;

// softmax_layout_fused, modified variant with VX_dma_node staging.
//
// Keeps the two compute optimizations of the original modified kernel:
//   - causal clamp: only columns k <= q contribute, so the work range stops at
//     k_end and the per-iteration `k > q` branch is dropped;
//   - single exp(): scaled scores are cached in local memory so exp() runs once
//     and is reused across the sum and normalize passes.
// In addition, the input row is bulk-moved DRAM->local-memory and the output
// row local-memory->DRAM through the core's VX_dma_node (MMIO descriptor at
// DMA_REG_BASE_ADDR) instead of per-element LSU loads/stores. This is the
// CPU-side DMA path (NOT the GEMM tensor-memory VX_dma_engine).
//
// Tiled-row geometry (layout_fused_layouts.h): for a fixed q, a row's columns
// live as ceil(K/mxu_nt) segments of mxu_nt contiguous elements, each segment
// separated by cm*mxu_nt elements. That maps onto one 2D DMA descriptor:
// seg_size = mxu_nt*2 bytes, bound0 = #segments, src/dst strides as below. On
// the LMEM side each tile lands in its own beat-aligned slot (pitch =
// align_up(seg, NUM_THREADS*LSU_WORD_SIZE)); the writeback reverses direction
// into the GEMM-A tiled layout. mxu_kt == mxu_nt in the deployed configs, so
// input and output share the per-row base/stride geometry.
//
// Global-side bases/strides/segments are multiples of mxu_nt*2 = 64 bytes; the
// LMEM-side base/stride are multiples of the DMA's local beat (NUM_THREADS*8 B),
// satisfying the aligned-only datapath (VX_core instantiates VX_dma_node with
// ENABLE_MISALIGN=0). For NUM_THREADS=8 the beat is 64 B so each slot is exactly
// one tile (fully packed); wider SIMD pads each slot up to the beat. The input
// DMA stages only the causal range; the output
// DMA writes the full padded row (masked/padding columns emitted as 0). Rows
// whose padded footprint exceeds the local-memory cap fall back to the
// per-element global recompute path.

///////////////////////////////////////////////////////////////////////////////
// VX_dma_node MMIO descriptor helpers
// (ported from tests/regression/softmax/kernel.opt.cpp; dma_copy_2d added for
//  the strided tiled-row transfer)
///////////////////////////////////////////////////////////////////////////////

static inline uint32_t mmio_read32(uint64_t addr) {
  return *reinterpret_cast<volatile uint32_t *>(addr);
}

static inline void mmio_write32(uint64_t addr, uint32_t value) {
  *reinterpret_cast<volatile uint32_t *>(addr) = value;
}

static inline void split_u64(uint64_t value, uint32_t &lo, uint32_t &hi) {
  lo = uint32_t(value & 0xffffffffull);
  hi = uint32_t(value >> 32);
}

static inline uint32_t bitfield_mask(uint32_t bits) {
  return (bits >= 32) ? 0xffffffffu : ((1u << bits) - 1u);
}

static constexpr uint64_t kDmaRegBaseAddr = 0x1480ull;       // = DMA_REG_BASE_ADDR
static constexpr uint32_t kDmaNumRegs32 = 18u;               // = DMA_CFG_REG_NUM
static constexpr uint32_t kMmioBeatBytes = 8u;
static constexpr uint32_t kWordsPerBeat = kMmioBeatBytes / 4u;
static constexpr uint32_t kDmaEntryStrideBytes =
    ((kDmaNumRegs32 + kWordsPerBeat - 1u) / kWordsPerBeat) * kMmioBeatBytes;
static constexpr uint32_t kDmaGlobalAllocBytes = kMmioBeatBytes;

static inline uint64_t dma_entry_reg32_addr(uint32_t eid, uint32_t reg_idx32) {
  uint32_t beat_idx = reg_idx32 / kWordsPerBeat;
  uint32_t word_in_beat = reg_idx32 % kWordsPerBeat;
  return kDmaRegBaseAddr
       + uint64_t(kDmaGlobalAllocBytes)
       + uint64_t(eid) * uint64_t(kDmaEntryStrideBytes)
       + uint64_t(beat_idx) * uint64_t(kMmioBeatBytes)
       + uint64_t(word_in_beat) * 4ull;
}

static inline void dma_write_reg32(uint32_t eid, uint32_t reg_idx32, uint32_t value) {
  mmio_write32(dma_entry_reg32_addr(eid, reg_idx32), value);
}

static inline uint32_t dma_read_reg32(uint32_t eid, uint32_t reg_idx32) {
  return mmio_read32(dma_entry_reg32_addr(eid, reg_idx32));
}

static inline void dma_write_reg64(uint32_t eid, uint32_t reg_lo_idx, uint64_t value) {
  uint32_t lo, hi;
  split_u64(value, lo, hi);
  dma_write_reg32(eid, reg_lo_idx, lo);
  dma_write_reg32(eid, reg_lo_idx + 1u, hi);
}

static inline void dma_decode_alloc_rsp(uint32_t rsp, uint32_t &eid, uint32_t &generation) {
  eid = (rsp >> JOB_MMIO_ALLOC_ENTRY_LSB) & bitfield_mask(JOB_MMIO_ALLOC_ENTRY_BITS);
  generation = (rsp >> JOB_MMIO_ALLOC_GEN_LSB) & bitfield_mask(JOB_MMIO_ALLOC_GEN_BITS);
}

static inline void dma_alloc(uint32_t &eid, uint32_t &generation) {
  for (;;) {
    uint32_t rsp = mmio_read32(kDmaRegBaseAddr);
    if (((rsp >> JOB_MMIO_ALLOC_SUCC_BIT) & 1u) != 0) {
      dma_decode_alloc_rsp(rsp, eid, generation);
      return;
    }
  }
}

static inline void dma_wait_done(uint32_t eid, uint32_t generation) {
  for (;;) {
    uint32_t ctrl = dma_read_reg32(eid, 0u);
    uint32_t curr_gen = (ctrl >> JOB_MMIO_CTRL_GEN_LSB) & bitfield_mask(JOB_MMIO_GEN_W);
    uint32_t valid = (ctrl >> JOB_MMIO_CTRL_VALID_BIT) & 1u;
    if ((generation < curr_gen) || (valid == 0u)) {
      return;
    }
  }
}

// One-dimensional strided copy: `count` segments of `seg_bytes`, advancing the
// source by `src_stride` and the destination by `dst_stride` between segments.
// direction: 0 = global->local (G2L), 1 = local->global (L2G).
// Descriptor word layout (VX_dma_unit_misal):
//   1-2 dst_base, 3-4 src_base, 5/6 src/dst_stride0, 7..10 stride1/2 (=0),
//   11-13 bound0..2, 14 seg_size, 16 dir[0], 0 control[0]=start.
static inline void dma_copy_2d(uint64_t dst_addr, uint64_t src_addr,
                               uint32_t seg_bytes, uint32_t count,
                               uint32_t src_stride, uint32_t dst_stride,
                               uint32_t direction) {
  uint32_t eid, generation;
  dma_alloc(eid, generation);

  dma_write_reg64(eid, 1u, dst_addr);   // dst_base
  dma_write_reg64(eid, 3u, src_addr);   // src_base
  dma_write_reg32(eid, 5u, src_stride); // src_stride0
  dma_write_reg32(eid, 6u, dst_stride); // dst_stride0
  dma_write_reg32(eid, 7u, 0u);         // src_stride1
  dma_write_reg32(eid, 8u, 0u);         // dst_stride1
  dma_write_reg32(eid, 9u, 0u);         // src_stride2
  dma_write_reg32(eid, 10u, 0u);        // dst_stride2
  dma_write_reg32(eid, 11u, count);     // bound0
  dma_write_reg32(eid, 12u, 1u);        // bound1
  dma_write_reg32(eid, 13u, 1u);        // bound2
  dma_write_reg32(eid, 14u, seg_bytes); // seg_size
  dma_write_reg32(eid, 15u, 0u);        // padding
  dma_write_reg32(eid, 16u, direction); // dir
  dma_write_reg32(eid, 17u, 0u);        // reserved
  dma_write_reg32(eid, 0u, 1u);         // control: start

  dma_wait_done(eid, generation);
}

///////////////////////////////////////////////////////////////////////////////
// Kernel
///////////////////////////////////////////////////////////////////////////////

// Max padded fp16 columns staged per row. The cached path holds one fp16
// in/out buffer (aliased) plus one float score cache, so the per-group local
// footprint is ~6 bytes/elem; this bound keeps groups_per_core x footprint
// inside the LMEM region (LMEM_LOG_SIZE=19 -> 512 KiB). Rows whose padded
// width exceeds this fall back to the per-element global recompute path.
static constexpr uint32_t SOFTMAX_LMEM_CACHE_MAX = 4096;

// CPU-side DMA LMEM-side slot geometry. NUM_THREADS and the mxu tile size are
// build-time constants, so these fold at compile time: the LMEM bus beat is
// NUM_THREADS*LSU_WORD_SIZE(8). The aligned-only datapath (ENABLE_MISALIGN=0)
// folds the in-beat byte lane to 0, so every LMEM-side DMA base/stride must be a
// multiple of the beat. Each mxu tile therefore occupies one beat-aligned slot
// of kSoftmaxSlotBytes. For NUM_THREADS=8 the beat equals the 64 B tile, so a
// slot holds exactly one tile (packed) and softmax_io_idx(k) folds to plain k;
// wider SIMD pads each slot up to the beat (only its first tile carries data).
static constexpr uint32_t kSoftmaxMxu       = TILE_DMA_MXU_NT;  // == TILE_DMA_MXU_KT
static constexpr uint32_t kSoftmaxLmemBeat  = (uint32_t)NUM_THREADS * 8u;  // bytes
static constexpr uint32_t kSoftmaxSegBytes  = kSoftmaxMxu * (uint32_t)sizeof(data_t);  // 64 B
static constexpr uint32_t kSoftmaxSlotBytes =
    (kSoftmaxSegBytes + kSoftmaxLmemBeat - 1u) & ~(kSoftmaxLmemBeat - 1u);  // beat-aligned
static constexpr uint32_t kSoftmaxSlotElems = kSoftmaxSlotBytes / (uint32_t)sizeof(data_t);

// Column k -> io_lmem element index. /,% by power-of-two constants compile to
// shift/mask, and the whole expression folds to `k` when slot == tile (8 lanes).
static inline uint32_t softmax_io_idx(uint32_t k) {
  return (k / kSoftmaxMxu) * kSoftmaxSlotElems + (k % kSoftmaxMxu);
}

void kernel_softmax_layout_fused(kernel_arg_t *__UNIFORM__ arg) {
  auto input = reinterpret_cast<data_t *>(arg->input_addr);
  auto output = reinterpret_cast<data_t *>(arg->output_addr);

  const uint32_t num_heads = arg->num_heads;
  const uint32_t seq_len_q = arg->seq_len_q;
  const uint32_t seq_len_k = arg->seq_len_k;
  const uint32_t seq_len_k_pad = arg->seq_len_k_pad;
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
  const uint64_t matrix_elems = (uint64_t)M_pad * seq_len_k_pad;
  const uint64_t base = batched_matrix_base(matrix_idx, matrix_elems);

  const uint32_t tid = threadIdx.x;
  const uint32_t block_size = blockDim.x;

  // Causal mask: only columns k <= q contribute. Clamp the work range so masked
  // tiles are never touched and the per-iteration `k > q` branch is dropped.
  const uint32_t k_end = use_mask ? min_u32(q + 1u, seq_len_k) : seq_len_k;

  // Tile geometry for this row (uniform across the block: q is per-block).
  const uint32_t mt     = 1u << arg->log2_mt;       // M tile rows (128)
  const uint32_t mxu_nt = 1u << arg->log2_mxu_nt;   // GEMM-C inner N tile (32)
  const uint32_t mxu_kt = 1u << arg->log2_mxu_kt;   // GEMM-A inner K tile (32)
  const uint32_t mt_idx = q >> arg->log2_mt;
  const uint32_t m0     = q & (mt - 1u);
  const uint32_t cm     = min_u32(M_pad - (mt_idx << arg->log2_mt), mt);

  // Output must cover the full padded row (masked/padding columns -> 0); the
  // input DMA only needs the causal range.
  const uint32_t out_groups = (seq_len_k + mxu_kt - 1u) >> arg->log2_mxu_kt;
  const uint32_t row_elems   = out_groups << arg->log2_mxu_kt;   // == seq_len_k_pad
  const uint32_t in_groups   = (k_end + mxu_nt - 1u) >> arg->log2_mxu_nt;

  const bool cached = (row_elems <= SOFTMAX_LMEM_CACHE_MAX);

  // Local-memory request. io holds one beat-aligned slot per tile (see the
  // kSoftmax* slot geometry above). __local_mem(size) hands block g the region
  // LOCAL_MEM_BASE + g*size, so the whole request is padded up to the LMEM beat
  // too, keeping io_lmem (offset 0) beat-aligned for every co-resident block.
  const uint32_t io_bytes     = out_groups * kSoftmaxSlotBytes;  // one slot per tile
  const uint32_t score_bytes  = row_elems * (uint32_t)sizeof(float);
  const uint32_t reduce_bytes = block_size * (uint32_t)sizeof(float);
  const uint32_t lmem_bytes =
      cached ? (((io_bytes + score_bytes + reduce_bytes) + kSoftmaxLmemBeat - 1u)
                & ~(kSoftmaxLmemBeat - 1u))
             : reduce_bytes;
  auto smem = reinterpret_cast<uint8_t *>(__local_mem(lmem_bytes));

  if (!cached) {
    // ---- Fallback: per-element global recompute (causal-clamped, no caching).
    auto reduce = reinterpret_cast<float *>(smem);

    float local_max = VX_NEG_INF;
    for (uint32_t k = tid; k < k_end; k += block_size) {
      const uint64_t in_off = base + gemm_c_tiled_elem_offset(
          q, k, M_pad, seq_len_k_pad, arg->log2_mt, arg->log2_mxu_nt);
      float v = fp16_to_float(input[in_off]) * scale;
      if (v > local_max) local_max = v;
    }
    reduce[tid] = local_max;
    __syncthreads();
    for (uint32_t s = block_size >> 1; s > 0; s >>= 1) {
      if (tid < s && reduce[tid + s] > reduce[tid]) reduce[tid] = reduce[tid + s];
      __syncthreads();
    }
    const float global_max = reduce[0];
    __syncthreads();

    float local_sum = 0.0f;
    for (uint32_t k = tid; k < k_end; k += block_size) {
      const uint64_t in_off = base + gemm_c_tiled_elem_offset(
          q, k, M_pad, seq_len_k_pad, arg->log2_mt, arg->log2_mxu_nt);
      float v = fp16_to_float(input[in_off]) * scale;
      local_sum += vx_expf(v - global_max);
    }
    reduce[tid] = local_sum;
    __syncthreads();
    for (uint32_t s = block_size >> 1; s > 0; s >>= 1) {
      if (tid < s) reduce[tid] += reduce[tid + s];
      __syncthreads();
    }
    const float inv_sum = 1.0f / reduce[0];
    __syncthreads();

    for (uint32_t k = tid; k < k_end; k += block_size) {
      const uint64_t in_off = base + gemm_c_tiled_elem_offset(
          q, k, M_pad, seq_len_k_pad, arg->log2_mt, arg->log2_mxu_nt);
      const uint64_t out_off = base + gemm_a_tiled_elem_offset(
          q, k, M_pad, seq_len_k_pad, arg->log2_mt, arg->log2_mxu_kt);
      float v = fp16_to_float(input[in_off]) * scale;
      output[out_off] = float_to_fp16(vx_expf(v - global_max) * inv_sum);
    }
    // Masked columns (k > q) are probability 0; the reference fills them.
    for (uint32_t k = k_end + tid; k < seq_len_k; k += block_size) {
      const uint64_t out_off = base + gemm_a_tiled_elem_offset(
          q, k, M_pad, seq_len_k_pad, arg->log2_mt, arg->log2_mxu_kt);
      output[out_off] = float_to_fp16(0.0f);
    }
    return;
  }

  // ---- DMA-staged cached path ----------------------------------------------
  // Local-memory layout: [ io(out_groups beat-aligned slots) | scores(float) | reduce ].
  // `io` holds the staged input as one beat-aligned slot per tile; it is consumed
  // by pass 1 and then reused as the output buffer for the writeback. Column k
  // lives at slot (k>>log2_mxu), element (k & (mxu-1)): io_lmem index
  //   (k>>log2_mxu)*lmem_slot_elems + (k & (mxu-1)).
  data_t *io_lmem  = reinterpret_cast<data_t *>(smem);
  float  *scores   = reinterpret_cast<float *>(smem + io_bytes);
  float  *reduce   = reinterpret_cast<float *>(smem + io_bytes + score_bytes);

  // Element offset of (q, k=0). GEMM-C and GEMM-A share base_q here since
  // mxu_kt == mxu_nt and k_dim == n_dim == seq_len_k_pad.
  const uint64_t base_q_in  = base + (uint64_t)mt_idx * mt * seq_len_k_pad
                                   + (uint64_t)m0 * mxu_nt;
  const uint64_t base_q_out = base + (uint64_t)mt_idx * mt * seq_len_k_pad
                                   + (uint64_t)m0 * mxu_kt;
  // Stage only the causal range of the tiled row into the beat-aligned slots.
  if (tid == 0) {
    dma_copy_2d(reinterpret_cast<uint64_t>(io_lmem),
                reinterpret_cast<uint64_t>(input + base_q_in),
                kSoftmaxSegBytes,                        // 32 fp16 = 64 B
                in_groups,                               // causal-clamped segments
                cm * mxu_nt * (uint32_t)sizeof(data_t),  // src stride (tiled): cm*64 B
                kSoftmaxSlotBytes,                       // dst stride: LMEM beat-aligned slot
                0u /* G2L */);
  }
  __syncthreads();

  // Pass 1: scale the staged score, cache it (dense), compute local max.
  float local_max = VX_NEG_INF;
  for (uint32_t k = tid; k < k_end; k += block_size) {
    float v = fp16_to_float(io_lmem[softmax_io_idx(k)]) * scale;
    scores[k] = v;
    if (v > local_max) local_max = v;
  }
  reduce[tid] = local_max;
  __syncthreads();
  for (uint32_t s = block_size >> 1; s > 0; s >>= 1) {
    if (tid < s && reduce[tid + s] > reduce[tid]) reduce[tid] = reduce[tid + s];
    __syncthreads();
  }
  const float global_max = reduce[0];
  __syncthreads();

  // Pass 2: exp() once, store it back, accumulate the sum.
  float local_sum = 0.0f;
  for (uint32_t k = tid; k < k_end; k += block_size) {
    const float e = vx_expf(scores[k] - global_max);
    scores[k] = e;
    local_sum += e;
  }
  reduce[tid] = local_sum;
  __syncthreads();
  for (uint32_t s = block_size >> 1; s > 0; s >>= 1) {
    if (tid < s) reduce[tid] += reduce[tid + s];
    __syncthreads();
  }
  const float inv_sum = 1.0f / reduce[0];
  __syncthreads();

  // Pass 3: normalize cached exp into the slot-laid output buffer; masked/padding
  // columns [k_end, row_elems) emit 0. (io_lmem is reused as the output here.)
  for (uint32_t k = tid; k < row_elems; k += block_size) {
    float p = (k < k_end) ? (scores[k] * inv_sum) : 0.0f;
    io_lmem[softmax_io_idx(k)] = float_to_fp16(p);
  }
  __syncthreads();

  // Write the full padded row back into the GEMM-A tiled layout (L2G).
  if (tid == 0) {
    dma_copy_2d(reinterpret_cast<uint64_t>(output + base_q_out),
                reinterpret_cast<uint64_t>(io_lmem),
                kSoftmaxSegBytes,                         // 64 B
                out_groups,                               // full padded row
                kSoftmaxSlotBytes,                        // src stride: LMEM beat-aligned slot
                cm * mxu_kt * (uint32_t)sizeof(data_t),   // dst stride (tiled): cm*64 B
                1u /* L2G */);
  }
  __syncthreads();
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

int main() {
  auto arg = (kernel_arg_t *)csr_read(VX_CSR_MSCRATCH);
  return vx_spawn_threads(1, arg->grid_dim, arg->block_dim,
                          (vx_kernel_func_cb)kernel_dispatcher, arg);
}
