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
// (ported from tests/regression/softmax/kernel.opt.cpp; dma_copy_3d kept for
//  aligned row-batch transfers)
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

static inline void dma_memory_fence() {
  __asm__ volatile ("fence iorw, iorw" ::: "memory");
}

// Aligned strided copy. The optimized softmax path uses it as a 2D row-batch
// transfer (bound1/bound2 == 1) for each K-tile group, keeping every segment
// exactly 64B and every source/destination stride beat-aligned.
// Descriptor word layout (VX_dma_unit_misal):
//   1-2 dst_base, 3-4 src_base, 5/6 src/dst_stride0, 7..10 stride1/2 (=0),
//   11-13 bound0..2, 14 seg_size, 16 dir[0], 0 control[0]=start.
static inline void dma_copy_3d(uint64_t dst_addr, uint64_t src_addr,
                               uint32_t seg_bytes,
                               uint32_t bound0, uint32_t bound1, uint32_t bound2,
                               uint32_t src_stride0, uint32_t dst_stride0,
                               uint32_t src_stride1, uint32_t dst_stride1,
                               uint32_t src_stride2, uint32_t dst_stride2,
                               uint32_t direction) {
  uint32_t eid, generation;
  dma_alloc(eid, generation);

  dma_write_reg64(eid, 1u, dst_addr);   // dst_base
  dma_write_reg64(eid, 3u, src_addr);   // src_base
  dma_write_reg32(eid, 5u, src_stride0);
  dma_write_reg32(eid, 6u, dst_stride0);
  dma_write_reg32(eid, 7u, src_stride1);
  dma_write_reg32(eid, 8u, dst_stride1);
  dma_write_reg32(eid, 9u, src_stride2);
  dma_write_reg32(eid, 10u, dst_stride2);
  dma_write_reg32(eid, 11u, bound0);
  dma_write_reg32(eid, 12u, bound1);
  dma_write_reg32(eid, 13u, bound2);
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

// Max dense fp16 columns cached across all row slots in one full-core block.
// The target hw config uses NUM_THREADS=32, NUM_WARPS=4, LMEM_LOG_SIZE=20:
// seqk=128 consumes 128*128 score elems and stays on the DMA path, while very
// wide rows fall back before a full-block local-memory request can overflow.
static constexpr uint32_t SOFTMAX_LMEM_TILE_ELEMS_MAX = 32768;

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
static inline uint32_t div_up_u32(uint32_t value, uint32_t divisor) {
  return (value + divisor - 1u) / divisor;
}

static inline uint32_t softmax_io_idx(uint32_t row_slot,
                                      uint32_t k,
                                      uint32_t rows_per_block) {
  return (k / kSoftmaxMxu) * rows_per_block * kSoftmaxSlotElems
       + row_slot * kSoftmaxSlotElems
       + (k % kSoftmaxMxu);
}

void kernel_softmax_layout_fused(kernel_arg_t *__UNIFORM__ arg) {
  auto input = reinterpret_cast<data_t *>(arg->input_addr);
  auto output = reinterpret_cast<data_t *>(arg->output_addr);

  const uint32_t batch_size = arg->batch_size;
  const uint32_t num_heads = arg->num_heads;
  const uint32_t seq_len_q = arg->seq_len_q;
  const uint32_t seq_len_k = arg->seq_len_k;
  const uint32_t seq_len_k_pad = arg->seq_len_k_pad;
  const uint32_t M_pad = arg->M_pad;
  const uint32_t use_mask = arg->use_mask;
  const float scale = arg->scale;

  const uint32_t tid = threadIdx.x;
  const uint32_t block_size = blockDim.x;
  const uint32_t rows_per_block = block_size;

  const uint32_t mt     = 1u << arg->log2_mt;       // M tile rows (128)
  const uint32_t mxu_nt = 1u << arg->log2_mxu_nt;   // GEMM-C inner N tile (32)
  const uint32_t mxu_kt = 1u << arg->log2_mxu_kt;   // GEMM-A inner K tile (32)
  const uint32_t out_groups = (seq_len_k + mxu_kt - 1u) >> arg->log2_mxu_kt;
  const uint32_t row_elems   = out_groups << arg->log2_mxu_kt;   // == seq_len_k_pad

  const uint32_t matrices_total = batch_size * num_heads;
  if (matrices_total == 0 || seq_len_q == 0 || seq_len_k == 0) {
    return;
  }

  const uint32_t full_mt_chunks = seq_len_q >> arg->log2_mt;
  const uint32_t tail_rows = seq_len_q - (full_mt_chunks << arg->log2_mt);
  const uint32_t tiles_per_full_mt = div_up_u32(mt, rows_per_block);
  const uint32_t tail_tiles = tail_rows ? div_up_u32(tail_rows, rows_per_block) : 0;
  const uint32_t row_tiles_per_matrix = full_mt_chunks * tiles_per_full_mt + tail_tiles;
  const uint32_t total_row_tiles = matrices_total * row_tiles_per_matrix;
  if (row_tiles_per_matrix == 0 || total_row_tiles == 0) {
    return;
  }

  const uint32_t io_bytes = out_groups * rows_per_block * kSoftmaxSlotBytes;
  const uint32_t score_elems = rows_per_block * row_elems;
  const uint32_t score_bytes = score_elems * (uint32_t)sizeof(float);
  const uint32_t cached_lmem_bytes =
      (io_bytes + score_bytes + kSoftmaxLmemBeat - 1u) & ~(kSoftmaxLmemBeat - 1u);
  const uint32_t lmem_capacity =
      (LMEM_LOG_SIZE >= 31) ? 0x7fffffffu : (1u << LMEM_LOG_SIZE);
  const bool cached = (score_elems <= SOFTMAX_LMEM_TILE_ELEMS_MAX)
                   && (cached_lmem_bytes <= lmem_capacity);

  auto smem = reinterpret_cast<uint8_t *>(
      __local_mem(cached ? cached_lmem_bytes : kSoftmaxLmemBeat));
  data_t *io_lmem = reinterpret_cast<data_t *>(smem);
  float *scores = reinterpret_cast<float *>(smem + io_bytes);

  for (uint32_t tile_id = blockIdx.x;
       tile_id < total_row_tiles;
       tile_id += gridDim.x) {
    const uint32_t matrix_idx = tile_id / row_tiles_per_matrix;
    const uint32_t tile_in_matrix = tile_id - matrix_idx * row_tiles_per_matrix;
    const uint32_t full_tile_count = full_mt_chunks * tiles_per_full_mt;

    uint32_t mt_idx;
    uint32_t tile_in_mt;
    uint32_t chunk_rows;
    if (tile_in_matrix < full_tile_count) {
      mt_idx = tile_in_matrix / tiles_per_full_mt;
      tile_in_mt = tile_in_matrix - mt_idx * tiles_per_full_mt;
      chunk_rows = mt;
    } else {
      mt_idx = full_mt_chunks;
      tile_in_mt = tile_in_matrix - full_tile_count;
      chunk_rows = tail_rows;
    }

    const uint32_t q0 = (mt_idx << arg->log2_mt) + tile_in_mt * rows_per_block;
    const uint32_t rows_left_in_chunk = chunk_rows - tile_in_mt * rows_per_block;
    const uint32_t rows_in_tile = min_u32(rows_per_block, rows_left_in_chunk);
    const uint32_t m0 = q0 & (mt - 1u);
    const uint32_t cm = min_u32(M_pad - (mt_idx << arg->log2_mt), mt);
    const uint64_t matrix_elems = (uint64_t)M_pad * seq_len_k_pad;
    const uint64_t base = batched_matrix_base(matrix_idx, matrix_elems);

    if (!cached) {
      for (uint32_t row_slot = tid; row_slot < rows_in_tile; row_slot += block_size) {
        const uint32_t q = q0 + row_slot;
        const uint32_t k_end = use_mask ? min_u32(q + 1u, seq_len_k) : seq_len_k;

        float local_max = VX_NEG_INF;
        for (uint32_t k = 0; k < k_end; ++k) {
          const uint64_t in_off = base + gemm_c_tiled_elem_offset(
              q, k, M_pad, seq_len_k_pad, arg->log2_mt, arg->log2_mxu_nt);
          const float v = fp16_to_float(input[in_off]) * scale;
          if (v > local_max) local_max = v;
        }

        float local_sum = 0.0f;
        for (uint32_t k = 0; k < k_end; ++k) {
          const uint64_t in_off = base + gemm_c_tiled_elem_offset(
              q, k, M_pad, seq_len_k_pad, arg->log2_mt, arg->log2_mxu_nt);
          const float v = fp16_to_float(input[in_off]) * scale;
          local_sum += vx_expf(v - local_max);
        }

        const float inv_sum = 1.0f / local_sum;
        for (uint32_t k = 0; k < k_end; ++k) {
          const uint64_t in_off = base + gemm_c_tiled_elem_offset(
              q, k, M_pad, seq_len_k_pad, arg->log2_mt, arg->log2_mxu_nt);
          const uint64_t out_off = base + gemm_a_tiled_elem_offset(
              q, k, M_pad, seq_len_k_pad, arg->log2_mt, arg->log2_mxu_kt);
          const float v = fp16_to_float(input[in_off]) * scale;
          output[out_off] = float_to_fp16(vx_expf(v - local_max) * inv_sum);
        }
        for (uint32_t k = k_end; k < row_elems; ++k) {
          const uint64_t out_off = base + gemm_a_tiled_elem_offset(
              q, k, M_pad, seq_len_k_pad, arg->log2_mt, arg->log2_mxu_kt);
          output[out_off] = float_to_fp16(0.0f);
        }
      }
      continue;
    }

    const uint32_t max_k_end = use_mask ? min_u32(q0 + rows_in_tile, seq_len_k) : seq_len_k;
    const uint32_t in_groups = div_up_u32(max_k_end, mxu_nt);
    const uint64_t base_q_in  = base + (uint64_t)mt_idx * mt * seq_len_k_pad
                                     + (uint64_t)m0 * mxu_nt;
    const uint64_t base_q_out = base + (uint64_t)mt_idx * mt * seq_len_k_pad
                                     + (uint64_t)m0 * mxu_kt;
    const uint32_t global_tile_stride = cm * kSoftmaxSegBytes;
    const uint32_t local_group_stride = rows_per_block * kSoftmaxSlotBytes;

    if (tid == 0) {
      for (uint32_t g = 0; g < in_groups; ++g) {
        dma_copy_3d(reinterpret_cast<uint64_t>(io_lmem) + (uint64_t)g * local_group_stride,
                    reinterpret_cast<uint64_t>(input + base_q_in) + (uint64_t)g * global_tile_stride,
                    kSoftmaxSegBytes,
                    rows_in_tile, 1u, 1u,
                    kSoftmaxSegBytes, kSoftmaxSlotBytes,
                    0u, 0u,
                    0u, 0u,
                    0u /* G2L */);
      }
    }
    __syncthreads();

    for (uint32_t row_slot = tid; row_slot < rows_in_tile; row_slot += block_size) {
      const uint32_t q = q0 + row_slot;
      const uint32_t k_end = use_mask ? min_u32(q + 1u, seq_len_k) : seq_len_k;
      float *row_scores = scores + row_slot * row_elems;

      float local_max = VX_NEG_INF;
      for (uint32_t k = 0; k < k_end; ++k) {
        const float v = fp16_to_float(
            io_lmem[softmax_io_idx(row_slot, k, rows_per_block)]) * scale;
        row_scores[k] = v;
        if (v > local_max) local_max = v;
      }

      float local_sum = 0.0f;
      for (uint32_t k = 0; k < k_end; ++k) {
        const float e = vx_expf(row_scores[k] - local_max);
        row_scores[k] = e;
        local_sum += e;
      }

      const float inv_sum = 1.0f / local_sum;
      for (uint32_t k = 0; k < row_elems; ++k) {
        const float p = (k < k_end) ? (row_scores[k] * inv_sum) : 0.0f;
        io_lmem[softmax_io_idx(row_slot, k, rows_per_block)] = float_to_fp16(p);
      }
    }
    dma_memory_fence();
    __syncthreads();

    if (tid == 0) {
      for (uint32_t g = 0; g < out_groups; ++g) {
        dma_copy_3d(reinterpret_cast<uint64_t>(output + base_q_out) + (uint64_t)g * global_tile_stride,
                    reinterpret_cast<uint64_t>(io_lmem) + (uint64_t)g * local_group_stride,
                    kSoftmaxSegBytes,
                    rows_in_tile, 1u, 1u,
                    kSoftmaxSlotBytes, kSoftmaxSegBytes,
                    0u, 0u,
                    0u, 0u,
                    1u /* L2G */);
      }
    }
    __syncthreads();
  }
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
