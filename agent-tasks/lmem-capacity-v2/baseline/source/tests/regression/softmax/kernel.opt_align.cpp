#include "common.h"
#include "../vector_common/fp16.h"
#include <vx_spawn.h>
#include <vx_intrinsics.h>
#include <vx_math.h>
#include <VX_config.h>

#ifndef SOFTMAX_SERIAL_BLOCK_DMA
#define SOFTMAX_SERIAL_BLOCK_DMA 0
#endif

// Type aliases
using data_t = fp16_t;

static inline uint32_t float_to_bits(float value) {
  union {
    float f;
    uint32_t u;
  } v;
  v.f = value;
  return v.u;
}

static inline float bits_to_float(uint32_t value) {
  union {
    uint32_t u;
    float f;
  } v;
  v.u = value;
  return v.f;
}

static inline float shfl_down_float(float value, uint32_t offset) {
  uint32_t bits = float_to_bits(value);
  return bits_to_float((uint32_t)vx_shfl_down(bits, offset, NUM_THREADS - 1, 0));
}

static inline float shfl_idx_float(float value, uint32_t index) {
  uint32_t bits = float_to_bits(value);
  return bits_to_float((uint32_t)vx_shfl_idx(bits, index, NUM_THREADS - 1, 0));
}

static inline uint32_t bitfield_mask(uint32_t bits) {
  return (bits >= 32) ? 0xffffffffu : ((1u << bits) - 1u);
}

static inline uint32_t align_up_u32(uint32_t value, uint32_t align) {
  return (value + align - 1u) & ~(align - 1u);
}

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

static constexpr uint64_t kDmaRegBaseAddr = 0x1480ull;
static constexpr uint32_t kDmaNumRegs32 = 18u;
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

static inline void dma_copy_1d(uint64_t dst_addr, uint64_t src_addr, uint32_t bytes, uint32_t direction) {
  uint32_t eid, generation;
  dma_alloc(eid, generation);

  dma_write_reg64(eid, 1u, dst_addr);
  dma_write_reg64(eid, 3u, src_addr);
  dma_write_reg32(eid, 5u, 0u);
  dma_write_reg32(eid, 6u, 0u);
  dma_write_reg32(eid, 7u, 0u);
  dma_write_reg32(eid, 8u, 0u);
  dma_write_reg32(eid, 9u, 0u);
  dma_write_reg32(eid, 10u, 0u);
  dma_write_reg32(eid, 11u, 1u);
  dma_write_reg32(eid, 12u, 1u);
  dma_write_reg32(eid, 13u, 1u);
  dma_write_reg32(eid, 14u, bytes);
  dma_write_reg32(eid, 15u, 0u);
  dma_write_reg32(eid, 16u, direction);
  dma_write_reg32(eid, 17u, 0u);
  dma_write_reg32(eid, 0u, 1u);

  dma_wait_done(eid, generation);
}

///////////////////////////////////////////////////////////////////////////////
// Softmax Kernel for Attention
// 
// Formula: softmax(x) = exp(x - max(x)) / sum(exp(x - max(x)))
// 
// Input: [batch, num_heads, seq_len_q, seq_len_k]
// Output: [batch, num_heads, seq_len_q, seq_len_k]
// 
// Each thread block processes a strided set of row tiles (softmax over seq_len_k)
// Strategy:
//   1. Assign one row to each warp in the block
//   2. Stage scaled input rows in local memory
//   3. Reduce max/sum independently per row
//   4. Normalize from cached exp values and store output
//
// Each row only communicates among lanes of the same warp, so row slots are
// independent and do not need block-wide barriers.
///////////////////////////////////////////////////////////////////////////////

void kernel_softmax(kernel_arg_t *__UNIFORM__ arg) {
  auto pInput = reinterpret_cast<uint8_t *>(arg->input_addr);
  auto pOutput = reinterpret_cast<uint8_t *>(arg->output_addr);
  auto pMask = reinterpret_cast<data_t *>(arg->mask_addr);
  
  uint32_t batch_size = arg->batch_size;
  uint32_t num_heads = arg->num_heads;
  uint32_t seq_len_q = arg->seq_len_q;
  uint32_t seq_len_k = arg->seq_len_k;
  uint32_t row_pitch_bytes = arg->row_pitch_bytes;
  uint32_t use_mask = arg->use_mask;
  float scale = arg->scale;
  
  // Rows are (batch_idx, head_idx, q_idx). A block handles one tile of rows
  // at a time, with each warp owning one row inside the tile.
  uint32_t rows_total = batch_size * num_heads * seq_len_q;
  uint32_t tid = threadIdx.x;
  uint32_t block_size = blockDim.x;

  constexpr uint32_t threads_per_row = NUM_THREADS;
  uint32_t rows_per_block = block_size / threads_per_row;
  if (rows_per_block == 0) {
    rows_per_block = 1;
  }

  uint32_t row_slot = tid / threads_per_row;
  uint32_t lane = tid - row_slot * threads_per_row;

  uint32_t row_bytes = seq_len_k * sizeof(data_t);
  uint32_t dma_row_pitch_bytes = align_up_u32(row_pitch_bytes, 64u);
  uint32_t row_cache_elems = rows_per_block * seq_len_k;
  uint32_t dma_input_offset = 0;
  uint32_t dma_output_offset = dma_input_offset + rows_per_block * dma_row_pitch_bytes;
  uint32_t input_offset = align_up_u32(dma_output_offset + rows_per_block * dma_row_pitch_bytes, 64u);
  uint32_t exp_offset = input_offset + row_cache_elems * sizeof(float);
  uint32_t local_bytes = align_up_u32(exp_offset + row_cache_elems * sizeof(float), 64u);

  auto local_base = (uint8_t *)__local_mem(local_bytes);
  auto dma_input_cache = local_base + dma_input_offset;
  auto dma_output_cache = local_base + dma_output_offset;
  auto input_cache = (float *)(local_base + input_offset);
  auto exp_cache = (float *)(local_base + exp_offset);

  uint32_t row_stride = gridDim.x * rows_per_block;

  for (uint32_t tile_base = blockIdx.x * rows_per_block;
       tile_base < rows_total;
       tile_base += row_stride) {
    uint32_t row_idx = tile_base + row_slot;
    bool active = (row_idx < rows_total);

    uint32_t b = active ? row_idx / (num_heads * seq_len_q) : 0;
    uint32_t remainder = active ? row_idx % (num_heads * seq_len_q) : 0;
    uint32_t h = remainder / seq_len_q;
    uint32_t q = remainder % seq_len_q;
    uint32_t row_offset = (b * num_heads + h) * seq_len_q + q;
    data_t *input_row = reinterpret_cast<data_t *>(pInput + row_offset * row_pitch_bytes);
    data_t *output_row = reinterpret_cast<data_t *>(pOutput + row_offset * row_pitch_bytes);
    data_t *row_dma_input = reinterpret_cast<data_t *>(dma_input_cache + row_slot * dma_row_pitch_bytes);
    data_t *row_dma_output = reinterpret_cast<data_t *>(dma_output_cache + row_slot * dma_row_pitch_bytes);
    float *row_input_cache = input_cache + row_slot * seq_len_k;
    float *row_exp_cache = exp_cache + row_slot * seq_len_k;

    //=========================================================================
    // Step 0: DMA input row tile to local memory
    //=========================================================================
#if SOFTMAX_SERIAL_BLOCK_DMA
    if (tid == 0) {
      for (uint32_t slot = 0; slot < rows_per_block; ++slot) {
        uint32_t dma_row_idx = tile_base + slot;
        if (dma_row_idx < rows_total) {
          auto src = pInput + dma_row_idx * row_pitch_bytes;
          auto dst = dma_input_cache + slot * dma_row_pitch_bytes;
          dma_copy_1d(reinterpret_cast<uint64_t>(dst),
                      reinterpret_cast<uint64_t>(src),
                      row_bytes,
                      0u);
        }
      }
    }
#else
    if (active && lane == 0) {
      dma_copy_1d(reinterpret_cast<uint64_t>(row_dma_input),
                  reinterpret_cast<uint64_t>(input_row),
                  row_bytes,
                  0u);
    }
#endif

    __syncthreads();

    for (uint32_t k = lane; k < seq_len_k; k += threads_per_row) {
      float val = VX_NEG_INF;
      if (active && !(use_mask && k > q)) {
        val = fp16_to_float(row_dma_input[k]) * scale;
      }
      row_input_cache[k] = val;
    }

    //=========================================================================
    // Step 1: Find max value (for numerical stability)
    //=========================================================================
    float local_max = VX_NEG_INF;

    for (uint32_t k = lane; k < seq_len_k; k += threads_per_row) {
      float val = row_input_cache[k];

      if (val > local_max) {
        local_max = val;
      }
    }

    // Reduction to find global max
    for (uint32_t s = threads_per_row / 2; s > 0; s >>= 1) {
      float other = shfl_down_float(local_max, s);
      if (lane + s < threads_per_row && other > local_max) {
        local_max = other;
      }
    }

    // Broadcast max to all threads
    float global_max = shfl_idx_float(local_max, 0);

    //=========================================================================
    // Step 2: Compute exp(x - max) once and sum
    //=========================================================================
    float local_sum = 0.0f;

    for (uint32_t k = lane; k < seq_len_k; k += threads_per_row) {
      float val = row_input_cache[k];
      float exp_val = 0.0f;

      if (val != VX_NEG_INF) {
        exp_val = vx_expf(val - global_max);
      }

      row_exp_cache[k] = exp_val;
      local_sum += exp_val;
    }

    // Reduction to find global sum
    for (uint32_t s = threads_per_row / 2; s > 0; s >>= 1) {
      float other = shfl_down_float(local_sum, s);
      if (lane + s < threads_per_row) {
        local_sum += other;
      }
    }

    // Broadcast sum to all threads
    float global_sum = shfl_idx_float(local_sum, 0);

    //=========================================================================
    // Step 3: Normalize using cached exp values
    //=========================================================================
    float inv_sum = 1.0f / global_sum;

    if (active) {
      for (uint32_t k = lane; k < seq_len_k; k += threads_per_row) {
        row_dma_output[k] = float_to_fp16(row_exp_cache[k] * inv_sum);
      }
    }

    __syncthreads();

#if SOFTMAX_SERIAL_BLOCK_DMA
    if (tid == 0) {
      for (uint32_t slot = 0; slot < rows_per_block; ++slot) {
        uint32_t dma_row_idx = tile_base + slot;
        if (dma_row_idx < rows_total) {
          auto dst = pOutput + dma_row_idx * row_pitch_bytes;
          auto src = dma_output_cache + slot * dma_row_pitch_bytes;
          dma_copy_1d(reinterpret_cast<uint64_t>(dst),
                      reinterpret_cast<uint64_t>(src),
                      row_bytes,
                      1u);
        }
      }
    }
#else
    if (active && lane == 0) {
      dma_copy_1d(reinterpret_cast<uint64_t>(output_row),
                  reinterpret_cast<uint64_t>(row_dma_output),
                  row_bytes,
                  1u);
    }
#endif

    __syncthreads();
  }
}

///////////////////////////////////////////////////////////////////////////////
// Kernel dispatch
///////////////////////////////////////////////////////////////////////////////
void kernel_dispatcher(kernel_arg_t *__UNIFORM__ arg) {
  switch (arg->kernel_id) {
    case KERNEL_SOFTMAX:
      kernel_softmax(arg);
      break;
    default:
      break;
  }
}

///////////////////////////////////////////////////////////////////////////////
// Main entry point
///////////////////////////////////////////////////////////////////////////////
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
