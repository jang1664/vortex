#include "common.h"
#include "../vector_common/fp16.h"

#include <vx_intrinsics.h>

static constexpr uint64_t kGemmRegBase = 0x1080ull;
static constexpr uint32_t kMmioBeatBytes = 8;
static constexpr uint32_t kWordsPerBeat = kMmioBeatBytes / 4;
static constexpr uint32_t kNumBeats =
    (GEMM_JOB_NUM_REGS32 + kWordsPerBeat - 1) / kWordsPerBeat;
static constexpr uint32_t kEntryStrideBytes = kNumBeats * kMmioBeatBytes;

struct partition_t {
  bool has_work;
  uint32_t m_start;
  uint32_t n_start;
  uint32_t target_m;
  uint32_t target_n;
};

static inline uint32_t min_u32(uint32_t a, uint32_t b) {
  return a < b ? a : b;
}

static inline uint32_t ceil_div_u32(uint32_t a, uint32_t b) {
  return (a + b - 1) / b;
}

static inline uint32_t bitfield_mask(uint32_t bits) {
  return bits >= 32 ? 0xffffffffu : ((1u << bits) - 1u);
}

static inline uint32_t log2_pow2_u32(uint32_t value) {
  uint32_t result = 0;
  while ((1u << result) != value)
    ++result;
  return result;
}

static partition_t compute_partition(uint32_t core_id, uint32_t num_cores,
                                     uint32_t m, uint32_t n) {
  partition_t part = {false, 0, 0, 0, 0};
  const uint32_t mt_dim = ceil_div_u32(m, GEMM_MT);
  const uint32_t nt_dim = ceil_div_u32(n, GEMM_NT);
  const uint32_t grid_n = min_u32(num_cores, nt_dim);
  const uint32_t grid_m = ceil_div_u32(num_cores, grid_n);
  const uint32_t core_n = core_id % grid_n;
  const uint32_t core_m = core_id / grid_n;
  if (core_m >= grid_m)
    return part;

  const uint32_t nt_base = nt_dim / grid_n;
  const uint32_t nt_rem = nt_dim % grid_n;
  const uint32_t nt_count = nt_base + (core_n < nt_rem ? 1u : 0u);
  const uint32_t nt_first = core_n * nt_base + min_u32(core_n, nt_rem);

  const uint32_t mt_base = mt_dim / grid_m;
  const uint32_t mt_rem = mt_dim % grid_m;
  const uint32_t mt_count = mt_base + (core_m < mt_rem ? 1u : 0u);
  const uint32_t mt_first = core_m * mt_base + min_u32(core_m, mt_rem);
  if (mt_count == 0 || nt_count == 0)
    return part;

  part.m_start = mt_first * GEMM_MT;
  part.n_start = nt_first * GEMM_NT;
  if (part.m_start >= m || part.n_start >= n)
    return part;

  part.has_work = true;
  part.target_m = min_u32(m - part.m_start, mt_count * GEMM_MT);
  part.target_n = min_u32(n - part.n_start, nt_count * GEMM_NT);
  return part;
}

static inline uint32_t mmio_read32(uint64_t addr) {
  return *reinterpret_cast<volatile uint32_t*>(addr);
}

static inline void mmio_write32(uint64_t addr, uint32_t value) {
  *reinterpret_cast<volatile uint32_t*>(addr) = value;
}

static inline uint64_t job_reg_addr(uint32_t eid, uint32_t reg) {
  const uint32_t beat = reg / kWordsPerBeat;
  const uint32_t word = reg % kWordsPerBeat;
  return kGemmRegBase + kMmioBeatBytes
       + uint64_t(eid) * kEntryStrideBytes
       + uint64_t(beat) * kMmioBeatBytes
       + uint64_t(word) * 4;
}

static inline uint32_t job_read32(uint32_t eid, uint32_t reg) {
  return mmio_read32(job_reg_addr(eid, reg));
}

static inline void job_write32(uint32_t eid, uint32_t reg, uint32_t value) {
  mmio_write32(job_reg_addr(eid, reg), value);
}

static inline void job_write64(uint32_t eid, uint32_t lo_reg, uint64_t value) {
  job_write32(eid, lo_reg, uint32_t(value));
  job_write32(eid, lo_reg + 1, uint32_t(value >> 32));
}

static bool allocate_job(uint32_t& eid, uint32_t& generation) {
  const uint32_t response = mmio_read32(kGemmRegBase);
  if (((response >> JOB_MMIO_ALLOC_SUCC_BIT) & 1u) == 0)
    return false;
  eid = (response >> JOB_MMIO_ALLOC_ENTRY_LSB)
      & bitfield_mask(JOB_MMIO_ALLOC_ENTRY_BITS);
  generation = (response >> JOB_MMIO_ALLOC_GEN_LSB)
             & bitfield_mask(JOB_MMIO_ALLOC_GEN_BITS);
  return eid < GEMM_JOB_NUM_ENTRIES;
}

static void program_job(uint32_t eid, const kernel_arg_t* arg,
                        const partition_t& part) {
  job_write64(eid, REG_INPUT_BASE_LO, arg->dram_in_base);
  job_write64(eid, REG_WEIGHT_BASE_LO, arg->dram_w_base);
  job_write64(eid, REG_OUTPUT_BASE_LO, arg->dram_out_base);
  job_write64(eid, REG_SCALE_BASE_LO, arg->dram_sc_base);
  job_write64(eid, REG_ZP_BASE_LO, arg->dram_zp_base);

  job_write64(eid, REG_LMEM_IBUF0_LO, arg->lmem_ibuf[0]);
  job_write64(eid, REG_LMEM_IBUF1_LO, arg->lmem_ibuf[1]);
  job_write64(eid, REG_LMEM_WBUF0_LO, arg->lmem_wbuf[0]);
  job_write64(eid, REG_LMEM_WBUF1_LO, arg->lmem_wbuf[1]);
  job_write64(eid, REG_LMEM_SCBUF0_LO, arg->lmem_scbuf[0]);
  job_write64(eid, REG_LMEM_SCBUF1_LO, arg->lmem_scbuf[1]);
  job_write64(eid, REG_LMEM_ZPBUF0_LO, arg->lmem_zpbuf[0]);
  job_write64(eid, REG_LMEM_ZPBUF1_LO, arg->lmem_zpbuf[1]);
  job_write64(eid, REG_LMEM_OBUF_LO, arg->lmem_obuf[0]);

  job_write32(eid, REG_M_ORIG, arg->M);
  job_write32(eid, REG_N_ORIG, arg->N);
  job_write32(eid, REG_K_ORIG, arg->K);
  job_write32(eid, REG_QBLK_ORIG, log2_pow2_u32(arg->QBLK));
  job_write32(eid, REG_M_TARGET, part.target_m);
  job_write32(eid, REG_N_TARGET, part.target_n);
  job_write32(eid, REG_K_TARGET, arg->K);
  job_write32(eid, REG_M_START, part.m_start);
  job_write32(eid, REG_N_START, part.n_start);
  job_write32(eid, REG_WTRANS, arg->WTRANS);
  job_write32(eid, REG_QDIR, arg->QDIR);
  job_write32(eid, REG_LOG2_DMA_MT, log2_pow2_u32(GEMM_MT));
  job_write32(eid, REG_LOG2_DMA_KT, log2_pow2_u32(GEMM_KT));
  job_write32(eid, REG_LOG2_DMA_NT, log2_pow2_u32(GEMM_NT));
  job_write32(eid, REG_CONTROL, 1);
}

static void wait_job_done(uint32_t eid, uint32_t generation) {
  for (;;) {
    const uint32_t control = job_read32(eid, REG_CONTROL);
    const uint32_t current_generation =
        (control >> JOB_MMIO_CTRL_GEN_LSB) & bitfield_mask(JOB_MMIO_GEN_W);
    const bool valid = ((control >> JOB_MMIO_CTRL_VALID_BIT) & 1u) != 0;
    if (generation < current_generation || !valid)
      return;
  }
}

static void preprocess_worker() {
  auto* arg = reinterpret_cast<kernel_arg_t*>(csr_read(VX_CSR_MSCRATCH));
  const uint64_t worker_id = uint64_t(vx_hart_id());
  const uint64_t worker_count =
      uint64_t(vx_num_cores()) * vx_num_warps() * vx_num_threads();
  auto* input_lhs = reinterpret_cast<fp16_t*>(arg->dram_in_base);
  auto* input_rhs = reinterpret_cast<const fp16_t*>(arg->pre_input_rhs_base);

  for (uint64_t index = worker_id; index < arg->preprocess_elements;
       index += worker_count) {
    input_lhs[index] = float_to_fp16(
        fp16_to_float(input_lhs[index]) + fp16_to_float(input_rhs[index]));
  }
}

static void preprocess_worker_stub() {
  vx_tmc(-1);
  preprocess_worker();
  vx_tmc_zero();
}

static void run_preprocess() {
  vx_wspawn(vx_num_warps(), preprocess_worker_stub);
  vx_tmc(-1);
  preprocess_worker();
  vx_tmc_one();
  vx_wspawn(1, nullptr);

  // Every core flushes its share of the vector stores to HBM before any core
  // is allowed to submit a GEMM descriptor that consumes the input.
  vx_fence();
  if (vx_num_cores() > 1)
    vx_barrier(0x80000000, vx_num_cores());
}

static uint64_t tiled_output_index(const kernel_arg_t* arg,
                                   uint32_t gm, uint32_t gn) {
  const uint32_t m_pad = (arg->M + 7u) & ~7u;
  const uint32_t mt = gm / GEMM_MT;
  const uint32_t nt = gn / GEMM_MXU_NT;
  const uint32_t n_tiles = arg->N / GEMM_MXU_NT;
  uint64_t index = 0;
  for (uint32_t prior_mt = 0; prior_mt < mt; ++prior_mt) {
    const uint32_t prior_m = min_u32(m_pad - prior_mt * GEMM_MT, GEMM_MT);
    index += uint64_t(n_tiles) * prior_m * GEMM_MXU_NT;
  }
  const uint32_t current_m = min_u32(m_pad - mt * GEMM_MT, GEMM_MT);
  index += uint64_t(nt) * current_m * GEMM_MXU_NT;
  index += uint64_t(gm - mt * GEMM_MT) * GEMM_MXU_NT;
  index += gn % GEMM_MXU_NT;
  return index;
}

static void postprocess_worker() {
  auto* arg = reinterpret_cast<kernel_arg_t*>(csr_read(VX_CSR_MSCRATCH));
  const uint32_t core_id = vx_core_id();
  const partition_t part = compute_partition(core_id, vx_num_cores(), arg->M, arg->N);
  if (!part.has_work)
    return;

  const uint32_t warp_id = vx_warp_id();
  const uint32_t lane_id = vx_thread_id();
  const uint32_t num_warps = vx_num_warps();
  const uint32_t num_threads = vx_num_threads();
  const uint32_t tiles_per_mt = ceil_div_u32(part.target_n, GEMM_MXU_NT);
  const uint32_t tile_count = ceil_div_u32(part.target_m, GEMM_MT) * tiles_per_mt;
  auto* gemm_output = reinterpret_cast<const fp16_t*>(arg->dram_out_base);
  auto* residual = reinterpret_cast<const fp16_t*>(arg->residual_base);
  auto* fused_output = reinterpret_cast<fp16_t*>(arg->fused_out_base);

  for (uint32_t tile = warp_id; tile < tile_count; tile += num_warps) {
    if (arg->schedule == SCHEDULE_FUSED) {
      uint32_t progress = 0;
      do {
        if (lane_id == 0)
          progress = job_read32(arg->job_eid[core_id], REG_OUTPUT_PROGRESS);
        progress = vx_shfl_idx(progress, 0, num_threads - 1, 0);
      } while (progress < tile + 1);

      if (warp_id == 0 && lane_id == 0 && tile == 0) {
        arg->overlap_observed[core_id] = progress < tile_count;
      }
    }

    const uint32_t local_mt = tile / tiles_per_mt;
    const uint32_t local_nb = tile % tiles_per_mt;
    const uint32_t gm0 = part.m_start + local_mt * GEMM_MT;
    const uint32_t gn0 = part.n_start + local_nb * GEMM_MXU_NT;
    const uint32_t rows = min_u32(part.m_start + part.target_m - gm0, GEMM_MT);
    const uint32_t cols = min_u32(part.n_start + part.target_n - gn0, GEMM_MXU_NT);
    const uint32_t elements = rows * cols;

    for (uint32_t element = lane_id; element < elements; element += num_threads) {
      const uint32_t gm = gm0 + element / cols;
      const uint32_t gn = gn0 + element % cols;
      const uint64_t row_major = uint64_t(gm) * arg->N + gn;
      const uint64_t tiled = tiled_output_index(arg, gm, gn);
      fused_output[row_major] = float_to_fp16(
          fp16_to_float(gemm_output[tiled]) + fp16_to_float(residual[row_major]));
    }
  }
}

static void postprocess_worker_stub() {
  vx_tmc(-1);
  postprocess_worker();
  vx_tmc_zero();
}

int main() {
  if (vx_warp_id() != 0 || vx_thread_id() != 0)
    return 0;

  vx_tmc_one();
  auto* arg = reinterpret_cast<kernel_arg_t*>(csr_read(VX_CSR_MSCRATCH));
  const uint32_t core_id = vx_core_id();
  const partition_t part = compute_partition(core_id, vx_num_cores(), arg->M, arg->N);
  arg->core_status[core_id] = STATUS_INIT;
  arg->overlap_observed[core_id] = 0;

  run_preprocess();

  if (!part.has_work) {
    arg->core_status[core_id] = STATUS_OK;
    return 0;
  }

  uint32_t eid = 0;
  uint32_t generation = 0;
  if (!allocate_job(eid, generation)) {
    arg->core_status[core_id] = STATUS_ALLOC_FAIL;
    return 0;
  }

  arg->job_eid[core_id] = eid;
  arg->job_generation[core_id] = generation;
  program_job(eid, arg, part);

  if (arg->schedule == SCHEDULE_SEQUENTIAL)
    wait_job_done(eid, generation);

  vx_wspawn(vx_num_warps(), postprocess_worker_stub);
  vx_tmc(-1);
  postprocess_worker();
  vx_tmc_one();
  vx_wspawn(1, nullptr);

  wait_job_done(eid, generation);
  vx_fence();
  arg->core_status[core_id] = STATUS_OK;
  return 0;
}
