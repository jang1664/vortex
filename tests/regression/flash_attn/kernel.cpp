#include "common.h"
#include "../layout_fused_common/layout_fused_layouts.h"
#include "../vector_common/fp16.h"

#include <vx_intrinsics.h>
#include <vx_math.h>
#include <vx_spawn.h>

static constexpr uint64_t kGemmRegBase = 0x1080ull;
static constexpr uint32_t kMmioBeatBytes = 8u;
static constexpr uint32_t kWordsPerBeat = kMmioBeatBytes / 4u;
static constexpr uint32_t kNumBeats =
    (GEMM_JOB_NUM_REGS32 + kWordsPerBeat - 1u) / kWordsPerBeat;
static constexpr uint32_t kEntryStrideBytes = kNumBeats * kMmioBeatBytes;
static constexpr uint32_t kPollLimit = 100000000u;

struct gemm_job_t {
  uint64_t input_base;
  uint64_t weight_base;
  uint64_t scale_base;
  uint64_t zero_base;
  uint64_t output_base;
  uint32_t m;
  uint32_t n;
  uint32_t k;
};

struct active_job_t {
  uint32_t eid;
  uint32_t generation;
  uint32_t expected_progress;
};

static inline uint32_t bitfield_mask(uint32_t bits) {
  return bits >= 32u ? 0xffffffffu : ((1u << bits) - 1u);
}

static inline uint32_t ceil_div_u32(uint32_t value, uint32_t divisor) {
  return (value + divisor - 1u) / divisor;
}

static inline uint32_t log2_pow2_u32(uint32_t value) {
  uint32_t result = 0;
  while ((1u << result) != value)
    ++result;
  return result;
}

static inline float shfl_down_float(float value, uint32_t offset) {
  return fp32_from_bits(uint32_t(vx_shfl_down(
      fp32_bits(value), offset, NUM_THREADS - 1, 0)));
}

static inline float shfl_idx_float(float value, uint32_t index) {
  return fp32_from_bits(uint32_t(vx_shfl_idx(
      fp32_bits(value), index, NUM_THREADS - 1, 0)));
}

static inline uint32_t mmio_read32(uint64_t addr) {
  return *reinterpret_cast<volatile uint32_t *>(addr);
}

static inline void mmio_write32(uint64_t addr, uint32_t value) {
  *reinterpret_cast<volatile uint32_t *>(addr) = value;
}

static inline uint64_t job_reg_addr(uint32_t eid, uint32_t reg) {
  const uint32_t beat = reg / kWordsPerBeat;
  const uint32_t word = reg % kWordsPerBeat;
  return kGemmRegBase + kMmioBeatBytes
       + uint64_t(eid) * kEntryStrideBytes
       + uint64_t(beat) * kMmioBeatBytes
       + uint64_t(word) * 4u;
}

static inline uint32_t job_read32(uint32_t eid, uint32_t reg) {
  return mmio_read32(job_reg_addr(eid, reg));
}

static inline void job_write32(uint32_t eid, uint32_t reg, uint32_t value) {
  mmio_write32(job_reg_addr(eid, reg), value);
}

static inline void job_write64(uint32_t eid, uint32_t lo_reg, uint64_t value) {
  job_write32(eid, lo_reg, uint32_t(value));
  job_write32(eid, lo_reg + 1u, uint32_t(value >> 32));
}

static bool allocate_job(active_job_t &active) {
  for (uint32_t poll = 0; poll < kPollLimit; ++poll) {
    const uint32_t response = mmio_read32(kGemmRegBase);
    if (((response >> JOB_MMIO_ALLOC_SUCC_BIT) & 1u) == 0u)
      continue;
    active.eid = (response >> JOB_MMIO_ALLOC_ENTRY_LSB)
               & bitfield_mask(JOB_MMIO_ALLOC_ENTRY_BITS);
    active.generation = (response >> JOB_MMIO_ALLOC_GEN_LSB)
                      & bitfield_mask(JOB_MMIO_ALLOC_GEN_BITS);
    return active.eid < GEMM_JOB_NUM_ENTRIES;
  }
  return false;
}

static void program_job(uint32_t eid, const kernel_arg_t *arg,
                        const gemm_job_t &job) {
  job_write64(eid, REG_INPUT_BASE_LO, job.input_base);
  job_write64(eid, REG_WEIGHT_BASE_LO, job.weight_base);
  job_write64(eid, REG_OUTPUT_BASE_LO, job.output_base);
  job_write64(eid, REG_SCALE_BASE_LO, job.scale_base);
  job_write64(eid, REG_ZP_BASE_LO, job.zero_base);

  job_write64(eid, REG_LMEM_IBUF0_LO, arg->lmem_ibuf[0]);
  job_write64(eid, REG_LMEM_IBUF1_LO, arg->lmem_ibuf[1]);
  job_write64(eid, REG_LMEM_WBUF0_LO, arg->lmem_wbuf[0]);
  job_write64(eid, REG_LMEM_WBUF1_LO, arg->lmem_wbuf[1]);
  job_write64(eid, REG_LMEM_SCBUF0_LO, arg->lmem_scbuf[0]);
  job_write64(eid, REG_LMEM_SCBUF1_LO, arg->lmem_scbuf[1]);
  job_write64(eid, REG_LMEM_ZPBUF0_LO, arg->lmem_zpbuf[0]);
  job_write64(eid, REG_LMEM_ZPBUF1_LO, arg->lmem_zpbuf[1]);
  job_write64(eid, REG_LMEM_OBUF_LO, arg->lmem_obuf);

  job_write32(eid, REG_M_ORIG, job.m);
  job_write32(eid, REG_N_ORIG, job.n);
  job_write32(eid, REG_K_ORIG, job.k);
  job_write32(eid, REG_QBLK_ORIG, log2_pow2_u32(FLASH_QBLK));
  job_write32(eid, REG_M_TARGET, job.m);
  job_write32(eid, REG_N_TARGET, job.n);
  job_write32(eid, REG_K_TARGET, job.k);
  job_write32(eid, REG_M_START, 0u);
  job_write32(eid, REG_N_START, 0u);
  job_write32(eid, REG_WTRANS, 0u);
  job_write32(eid, REG_QDIR, 0u);
  job_write32(eid, REG_LOG2_DMA_MT, log2_pow2_u32(FLASH_DMA_MT));
  job_write32(eid, REG_LOG2_DMA_KT, log2_pow2_u32(FLASH_DMA_KT));
  job_write32(eid, REG_LOG2_DMA_NT, log2_pow2_u32(FLASH_DMA_NT));
  job_write32(eid, REG_CONTROL, 1u);
}

static bool start_job(const kernel_arg_t *arg, const gemm_job_t &job,
                      active_job_t &active) {
  if (!allocate_job(active))
    return false;
  active.expected_progress = ceil_div_u32(job.m, FLASH_DMA_MT)
                           * ceil_div_u32(job.n, FLASH_MXU_NT);
  program_job(active.eid, arg, job);
  return true;
}

static bool job_is_retired(const active_job_t &active) {
  const uint32_t control = job_read32(active.eid, REG_CONTROL);
  const uint32_t generation =
      (control >> JOB_MMIO_CTRL_GEN_LSB) & bitfield_mask(JOB_MMIO_GEN_W);
  const bool occupied =
      ((control >> JOB_MMIO_CTRL_OCCUPY_BIT) & 1u) != 0u;
  const bool working =
      ((control >> JOB_MMIO_CTRL_WORKING_BIT) & 1u) != 0u;
  return generation != active.generation || (!occupied && !working);
}

static bool wait_progress_tile(const active_job_t &active, uint32_t target) {
  for (uint32_t poll = 0; poll < kPollLimit; ++poll) {
    if (job_read32(active.eid, REG_OUTPUT_PROGRESS) >= target
        || job_is_retired(active))
      return true;
  }
  return false;
}

static bool wait_job_done(const active_job_t &active) {
  for (uint32_t poll = 0; poll < kPollLimit; ++poll) {
    if (job_is_retired(active))
      return true;
  }
  return false;
}

static void initialize_state_worker() {
  auto *arg = reinterpret_cast<kernel_arg_t *>(csr_read(VX_CSR_MSCRATCH));
  auto *accumulator = reinterpret_cast<float *>(arg->accumulator_base);
  auto *row_max = reinterpret_cast<float *>(arg->row_max_base);
  auto *row_sum = reinterpret_cast<float *>(arg->row_sum_base);
  const uint32_t worker = uint32_t(vx_hart_id());
  const uint32_t workers = uint32_t(vx_num_warps() * vx_num_threads());

  for (uint32_t row = worker; row < arg->query_rows; row += workers) {
    row_max[row] = VX_NEG_INF;
    row_sum[row] = 0.0f;
  }
  for (uint64_t index = worker;
       index < uint64_t(arg->query_rows) * arg->head_dim;
       index += workers) {
    accumulator[index] = 0.0f;
  }
}

static void online_softmax_worker() {
  auto *arg = reinterpret_cast<kernel_arg_t *>(csr_read(VX_CSR_MSCRATCH));
  auto *scores = reinterpret_cast<const fp16_t *>(arg->score_base);
  auto *probabilities = reinterpret_cast<fp16_t *>(arg->probability_base);
  auto *row_max = reinterpret_cast<float *>(arg->row_max_base);
  auto *row_sum = reinterpret_cast<float *>(arg->row_sum_base);

  const uint32_t lane = uint32_t(vx_thread_id());
  const uint32_t warp = uint32_t(vx_warp_id());
  const uint32_t warps = uint32_t(vx_num_warps());
  const uint32_t log2_mxu_nt = log2_pow2_u32(FLASH_MXU_NT);
  const uint32_t log2_mxu_kt = log2_pow2_u32(FLASH_MXU_KT);
  const uint32_t tile = arg->current_kv_tile;
  const uint32_t key_base = tile * arg->kv_tile;
  const uint32_t output_tiles = ceil_div_u32(arg->kv_tile, FLASH_MXU_NT);
  const active_job_t qk_active = {
      arg->qk_eid, arg->qk_generation, output_tiles};

  for (uint32_t row = warp; row < arg->query_rows; row += warps) {
    for (uint32_t output_tile = 0; output_tile < output_tiles; ++output_tile) {
      uint32_t ready = 0u;
      if (lane == 0u)
        ready = wait_progress_tile(qk_active, output_tile + 1u) ? 1u : 0u;
      ready = uint32_t(vx_shfl_idx(ready, 0u, NUM_THREADS - 1u, 0u));
      if (ready == 0u) {
        if (lane == 0u)
          arg->status = FLASH_STATUS_PROGRESS_TIMEOUT;
        return;
      }

      const uint32_t col_begin = output_tile * FLASH_MXU_NT;
      const uint32_t col_end = min_u32(col_begin + FLASH_MXU_NT, arg->kv_tile);
      float block_max = VX_NEG_INF;
      for (uint32_t col = col_begin + lane; col < col_end;
           col += NUM_THREADS) {
        const uint32_t key = key_base + col;
        const bool valid = key < arg->kv_length
                        && (!arg->causal
                            || key <= arg->query_position_base + row);
        if (valid) {
          const uint64_t offset = gemm_c_tiled_elem_offset(
              row, col, arg->query_rows_pad, arg->kv_tile,
              log2_pow2_u32(FLASH_DMA_MT), log2_mxu_nt);
          const float score = fp16_to_float(scores[offset])
                            * arg->attention_scale;
          if (score > block_max)
            block_max = score;
        }
      }
      for (uint32_t shift = NUM_THREADS / 2u; shift > 0u; shift >>= 1u) {
        const float other = shfl_down_float(block_max, shift);
        if (lane + shift < NUM_THREADS && other > block_max)
          block_max = other;
      }
      block_max = shfl_idx_float(block_max, 0u);

      float old_max = lane == 0u ? row_max[row] : 0.0f;
      float old_sum = lane == 0u ? row_sum[row] : 0.0f;
      old_max = shfl_idx_float(old_max, 0u);
      old_sum = shfl_idx_float(old_sum, 0u);
      const float new_max = block_max > old_max ? block_max : old_max;
      const float alpha = old_max == VX_NEG_INF
                        ? 0.0f : vx_expf(old_max - new_max);

      if (new_max > old_max) {
        for (uint32_t col = lane; col < col_begin; col += NUM_THREADS) {
          const uint64_t offset = gemm_a_tiled_elem_offset(
              row, col, arg->query_rows_pad, arg->kv_tile,
              log2_pow2_u32(FLASH_DMA_MT), log2_mxu_kt);
          probabilities[offset] = float_to_fp16(
              fp16_to_float(probabilities[offset]) * alpha);
        }
        if (lane == 0u && row == 0u && output_tile > 0u)
          arg->later_max_updates += 1u;
      }

      float local_sum = 0.0f;
      for (uint32_t col = col_begin + lane; col < col_end;
           col += NUM_THREADS) {
        const uint32_t key = key_base + col;
        const bool valid = key < arg->kv_length
                        && (!arg->causal
                            || key <= arg->query_position_base + row);
        float probability = 0.0f;
        if (valid) {
          const uint64_t input_offset = gemm_c_tiled_elem_offset(
              row, col, arg->query_rows_pad, arg->kv_tile,
              log2_pow2_u32(FLASH_DMA_MT), log2_mxu_nt);
          const float score = fp16_to_float(scores[input_offset])
                            * arg->attention_scale;
          probability = vx_expf(score - new_max);
        }
        const uint64_t output_offset = gemm_a_tiled_elem_offset(
            row, col, arg->query_rows_pad, arg->kv_tile,
            log2_pow2_u32(FLASH_DMA_MT), log2_mxu_kt);
        probabilities[output_offset] = float_to_fp16(probability);
        local_sum += probability;
      }
      for (uint32_t shift = NUM_THREADS / 2u; shift > 0u; shift >>= 1u) {
        const float other = shfl_down_float(local_sum, shift);
        if (lane + shift < NUM_THREADS)
          local_sum += other;
      }
      const float block_sum = shfl_idx_float(local_sum, 0u);
      if (lane == 0u) {
        row_max[row] = new_max;
        row_sum[row] = alpha * old_sum + block_sum;
        if (row == 0u)
          arg->qk_progress_events += 1u;
      }
    }
  }

}

static void accumulate_partial_worker() {
  auto *arg = reinterpret_cast<kernel_arg_t *>(csr_read(VX_CSR_MSCRATCH));
  auto *partial = reinterpret_cast<const fp16_t *>(arg->partial_base);
  auto *accumulator = reinterpret_cast<float *>(arg->accumulator_base);
  const uint32_t worker = uint32_t(vx_hart_id());
  const uint32_t workers = uint32_t(vx_num_warps() * vx_num_threads());
  const uint32_t log2_mxu_nt = log2_pow2_u32(FLASH_MXU_NT);

  for (uint64_t index = worker;
       index < uint64_t(arg->query_rows) * arg->head_dim;
       index += workers) {
    const uint32_t row = uint32_t(index / arg->head_dim);
    const uint32_t col = uint32_t(index - uint64_t(row) * arg->head_dim);
    const uint64_t tiled = gemm_c_tiled_elem_offset(
        row, col, arg->query_rows_pad, arg->head_dim,
        log2_pow2_u32(FLASH_DMA_MT), log2_mxu_nt);
    accumulator[index] += fp16_to_float(partial[tiled]);
  }
}

static void finalize_worker() {
  auto *arg = reinterpret_cast<kernel_arg_t *>(csr_read(VX_CSR_MSCRATCH));
  auto *accumulator = reinterpret_cast<const float *>(arg->accumulator_base);
  auto *row_sum = reinterpret_cast<const float *>(arg->row_sum_base);
  auto *output = reinterpret_cast<fp16_t *>(arg->output_base);
  const uint32_t worker = uint32_t(vx_hart_id());
  const uint32_t workers = uint32_t(vx_num_warps() * vx_num_threads());

  for (uint64_t index = worker;
       index < uint64_t(arg->query_rows) * arg->head_dim;
       index += workers) {
    const uint32_t row = uint32_t(index / arg->head_dim);
    const float sum = row_sum[row];
    output[index] = float_to_fp16(sum > 0.0f ? accumulator[index] / sum : 0.0f);
  }
}

static void initialize_state_stub() {
  vx_tmc(-1);
  initialize_state_worker();
  vx_tmc_zero();
}

static void online_softmax_stub() {
  vx_tmc(-1);
  online_softmax_worker();
  vx_tmc_zero();
}

static void accumulate_partial_stub() {
  vx_tmc(-1);
  accumulate_partial_worker();
  vx_tmc_zero();
}

static void finalize_stub() {
  vx_tmc(-1);
  finalize_worker();
  vx_tmc_zero();
}

static void run_initialize() {
  vx_wspawn(vx_num_warps(), initialize_state_stub);
  vx_tmc(-1);
  initialize_state_worker();
  vx_tmc_one();
  vx_wspawn(1, nullptr);
}

static void run_online_softmax() {
  vx_wspawn(vx_num_warps(), online_softmax_stub);
  vx_tmc(-1);
  online_softmax_worker();
  vx_tmc_one();
  vx_wspawn(1, nullptr);
}

static void run_accumulate_partial() {
  vx_wspawn(vx_num_warps(), accumulate_partial_stub);
  vx_tmc(-1);
  accumulate_partial_worker();
  vx_tmc_one();
  vx_wspawn(1, nullptr);
}

static void run_finalize() {
  vx_wspawn(vx_num_warps(), finalize_stub);
  vx_tmc(-1);
  finalize_worker();
  vx_tmc_one();
  vx_wspawn(1, nullptr);
}

static void run_fence() {
  vx_fence();
}

static bool run_pv_gemm(kernel_arg_t *arg) {
  gemm_job_t pv = {
      arg->probability_base,
      arg->v_weight_base,
      arg->v_scale_base,
      arg->k_zero_base,
      arg->partial_base,
      arg->query_rows,
      arg->head_dim,
      arg->kv_tile,
  };
  active_job_t pv_active = {};
  if (!start_job(arg, pv, pv_active)) {
    arg->status = FLASH_STATUS_ALLOC_FAIL;
    return false;
  }
  if (!wait_progress_tile(pv_active, pv_active.expected_progress)) {
    arg->status = FLASH_STATUS_PROGRESS_TIMEOUT;
    return false;
  }
  arg->pv_progress_events += pv_active.expected_progress;
  if (!wait_job_done(pv_active)) {
    arg->status = FLASH_STATUS_JOB_TIMEOUT;
    return false;
  }
  return true;
}

static bool run_attention(kernel_arg_t *arg) {
  run_initialize();
  run_fence();

  if (arg->pv_only != 0u) {
    if (!run_pv_gemm(arg))
      return false;
    run_accumulate_partial();
    run_fence();
    return true;
  }

  const uint32_t tile_count = ceil_div_u32(arg->kv_length, arg->kv_tile);
  for (uint32_t tile = 0; tile < tile_count; ++tile) {
    arg->current_kv_tile = tile;

    if (tile != 0u) {
      // Publish vector state before a future multi-tile QK overwrites reusable
      // scratch.
      run_fence();
    }

    gemm_job_t qk = {
        arg->q_base,
        arg->k_weight_base + uint64_t(tile) * arg->k_weight_tile_bytes,
        arg->k_scale_base + uint64_t(tile) * arg->k_scale_tile_bytes,
        arg->k_zero_base + uint64_t(tile) * arg->k_zero_tile_bytes,
        arg->score_base,
        arg->query_rows,
        arg->kv_tile,
        arg->head_dim,
    };
    active_job_t qk_active = {};
    if (!start_job(arg, qk, qk_active)) {
      arg->status = FLASH_STATUS_ALLOC_FAIL;
      return false;
    }
    arg->qk_eid = qk_active.eid;
    arg->qk_generation = qk_active.generation;
    run_online_softmax();
    if (arg->status != FLASH_STATUS_INIT)
      return false;
    if (!wait_job_done(qk_active)) {
      arg->status = FLASH_STATUS_JOB_TIMEOUT;
      return false;
    }

    // All softmax workers have joined. Flush every hart's probability stores
    // before submitting the temporally separate PV descriptor.
    run_fence();

    if (!run_pv_gemm(arg))
      return false;

    run_accumulate_partial();

    arg->completed_kv_tiles = tile + 1u;
  }

  run_finalize();
  run_fence();
  return true;
}

int main() {
  if (vx_core_id() != 0 || vx_warp_id() != 0 || vx_thread_id() != 0)
    return 0;

  vx_tmc_one();
  auto *arg = reinterpret_cast<kernel_arg_t *>(csr_read(VX_CSR_MSCRATCH));
  arg->status = FLASH_STATUS_INIT;
  arg->qk_progress_events = 0u;
  arg->pv_progress_events = 0u;
  arg->later_max_updates = 0u;
  arg->current_kv_tile = 0u;
  arg->completed_kv_tiles = 0u;

  if (arg->head_dim != 128u || arg->kv_tile != 128u
      || arg->query_rows == 0u || arg->query_rows > FLASH_DMA_MT
      || arg->query_rows_pad < arg->query_rows) {
    arg->status = FLASH_STATUS_BAD_DEVICE;
    return 0;
  }

  if (run_attention(arg))
    arg->status = FLASH_STATUS_OK;
  return 0;
}
