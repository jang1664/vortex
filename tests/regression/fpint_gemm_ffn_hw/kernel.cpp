#include "common.h"
#include <vx_spawn.h>
#include <vx_intrinsics.h>

static constexpr uint64_t kGemmRegOffset = 0x0000000000001080ull;
static uint64_t gGemmRegBaseAddr = kGemmRegOffset;

static inline uint32_t mmio_read32(uint64_t addr) {
  return *reinterpret_cast<volatile uint32_t *>(addr);
}

static inline void mmio_write32(uint64_t addr, uint32_t value) {
  *reinterpret_cast<volatile uint32_t *>(addr) = value;
}

static inline uint32_t bitfield_mask(uint32_t bits) {
  return (bits >= 32) ? 0xFFFFFFFFu : ((1u << bits) - 1u);
}

static constexpr uint32_t kMaxPollIters = 2000000u;
static constexpr uint32_t kPoisonWord = 0xBAADF00Du;

static inline uint64_t reg64_to_u64(uint32_t lo, uint32_t hi) {
  return (uint64_t(hi) << 32) | uint64_t(lo);
}

static inline void split_u64(uint64_t value, uint32_t& lo, uint32_t& hi) {
  lo = uint32_t(value & 0xFFFFFFFFull);
  hi = uint32_t(value >> 32);
}

static constexpr uint32_t kMmioBeatBytes = 8u;
static constexpr uint32_t kWordsPerBeat = kMmioBeatBytes / 4u;
static constexpr uint32_t kNumBeats = (GEMM_JOB_NUM_REGS32 + kWordsPerBeat - 1u) / kWordsPerBeat;
static constexpr uint32_t kEntryStrideBytes = kNumBeats * kMmioBeatBytes;
static constexpr uint32_t kGlobalAllocBytes = kMmioBeatBytes;

static inline uint32_t mmio_read32_word(uint64_t beat_addr, uint32_t word_in_beat) {
  volatile uint64_t* ptr = reinterpret_cast<volatile uint64_t*>(beat_addr);
  uint64_t beat = *ptr;
  uint32_t shift = word_in_beat * 32u;
  return uint32_t((beat >> shift) & uint64_t(0xFFFFFFFFu));
}

static inline void mmio_write32_word(uint64_t beat_addr, uint32_t word_in_beat, uint32_t value) {
  volatile uint64_t* ptr = reinterpret_cast<volatile uint64_t*>(beat_addr);
  uint64_t beat = *ptr;
  uint32_t shift = word_in_beat * 32u;
  uint64_t mask = uint64_t(0xFFFFFFFFull) << shift;
  beat = (beat & ~mask) | (uint64_t(value) << shift);
  *ptr = beat;
}

static uint64_t job_entry_beat_addr(uint32_t eid, uint32_t beat_idx) {
  constexpr uint32_t data_size = kMmioBeatBytes;
  constexpr uint32_t words_per_beat = data_size / 4;
  constexpr uint32_t num_beats = (GEMM_JOB_NUM_REGS32 + words_per_beat - 1) / words_per_beat;
  constexpr uint32_t entry_stride_b = num_beats * data_size;
  constexpr uint32_t global_alloc_b = data_size;

  return gGemmRegBaseAddr
       + uint64_t(global_alloc_b)
       + uint64_t(eid) * uint64_t(entry_stride_b)
       + uint64_t(beat_idx) * uint64_t(data_size);
}

static inline void job_write_reg32(uint32_t eid, uint32_t reg_idx32, uint32_t value) {
  uint32_t beat_idx = reg_idx32 / kWordsPerBeat;
  uint32_t word_in_beat = reg_idx32 % kWordsPerBeat;
  mmio_write32_word(job_entry_beat_addr(eid, beat_idx), word_in_beat, value);
}

static inline uint32_t job_read_reg32(uint32_t eid, uint32_t reg_idx32) {
  uint32_t beat_idx = reg_idx32 / kWordsPerBeat;
  uint32_t word_in_beat = reg_idx32 % kWordsPerBeat;
  return mmio_read32_word(job_entry_beat_addr(eid, beat_idx), word_in_beat);
}

static inline void job_write_reg64(uint32_t eid, uint32_t reg_lo_idx, uint64_t value) {
  uint32_t lo, hi;
  split_u64(value, lo, hi);
  job_write_reg32(eid, reg_lo_idx, lo);
  job_write_reg32(eid, reg_lo_idx + 1, hi);
}

static inline void decode_alloc_rsp(uint32_t r, uint32_t& eid, uint32_t& generation) {
  eid = (r >> JOB_MMIO_ALLOC_ENTRY_LSB) & bitfield_mask(JOB_MMIO_ALLOC_ENTRY_BITS);
  generation = (r >> JOB_MMIO_ALLOC_GEN_LSB) & bitfield_mask(JOB_MMIO_ALLOC_GEN_BITS);
}

static bool job_alloc_at(uint64_t base_addr, uint32_t& eid, uint32_t& generation, uint32_t& raw_rsp) {
  uint32_t r = mmio_read32_word(base_addr, 0);
  raw_rsp = r;
  if (((r >> JOB_MMIO_ALLOC_SUCC_BIT) & 1u) == 0)
    return false;

  decode_alloc_rsp(r, eid, generation);
  return true;
}

static bool resolve_gemm_mmio_base(uint32_t& eid, uint32_t& generation, uint32_t& raw_rsp) {
  uint64_t local_mem_base = csr_read(VX_CSR_LOCAL_MEM_BASE);
  const uint64_t candidates[2] = {
    kGemmRegOffset,
    local_mem_base + kGemmRegOffset,
  };

  uint32_t probe_eid = 0;
  uint32_t probe_gen = 0;
  uint32_t probe_raw = 0;

  for (uint32_t i = 0; i < 2; ++i) {
    uint64_t base = candidates[i];
    if (!job_alloc_at(base, probe_eid, probe_gen, probe_raw))
      continue;

    if (probe_raw == kPoisonWord)
      continue;

    if (probe_eid < GEMM_JOB_NUM_ENTRIES) {
      gGemmRegBaseAddr = base;
      eid = probe_eid;
      generation = probe_gen;
      raw_rsp = probe_raw;
      return true;
    }
  }

  raw_rsp = mmio_read32_word(kGemmRegOffset, 0);
  decode_alloc_rsp(raw_rsp, eid, generation);
  return false;
}

static void program_job_regs(uint32_t eid, const kernel_arg_t* arg) {
  job_write_reg64(eid, REG_INPUT_BASE_LO,  arg->input_base);
  job_write_reg64(eid, REG_WEIGHT_BASE_LO, arg->weight_base);
  job_write_reg64(eid, REG_OUTPUT_BASE_LO, arg->output_base);
  job_write_reg64(eid, REG_SCALE_BASE_LO,  arg->scale_base);
  job_write_reg64(eid, REG_ZP_BASE_LO,     arg->zp_base);

  job_write_reg64(eid, REG_LMEM_IBUF0_LO,  arg->lmem_ibuf0_base);
  job_write_reg64(eid, REG_LMEM_IBUF1_LO,  arg->lmem_ibuf1_base);
  job_write_reg64(eid, REG_LMEM_WBUF0_LO,  arg->lmem_wbuf0_base);
  job_write_reg64(eid, REG_LMEM_WBUF1_LO,  arg->lmem_wbuf1_base);
  job_write_reg64(eid, REG_LMEM_SCBUF0_LO, arg->lmem_scbuf0_base);
  job_write_reg64(eid, REG_LMEM_SCBUF1_LO, arg->lmem_scbuf1_base);
  job_write_reg64(eid, REG_LMEM_ZPBUF0_LO, arg->lmem_zpbuf0_base);
  job_write_reg64(eid, REG_LMEM_ZPBUF1_LO, arg->lmem_zpbuf1_base);
  job_write_reg64(eid, REG_LMEM_OBUF_LO,   arg->lmem_obuf_base);

  job_write_reg32(eid, REG_M, arg->M);
  job_write_reg32(eid, REG_N, arg->N);
  job_write_reg32(eid, REG_K, arg->K);
  job_write_reg32(eid, REG_QBLK, arg->QBLK);

  job_write_reg32(eid, REG_CONTROL, 1u);
}

static bool wait_job_done(uint32_t eid, uint32_t generation, uint32_t& last_ctrl) {
  for (uint32_t iter = 0; iter < kMaxPollIters; ++iter) {
    uint32_t ctrl = job_read_reg32(eid, REG_CONTROL);
    uint32_t curr_gen = (ctrl >> JOB_MMIO_CTRL_GEN_LSB) & bitfield_mask(JOB_MMIO_GEN_W);
    uint32_t valid = (ctrl >> JOB_MMIO_CTRL_VALID_BIT) & 1u;
    last_ctrl = ctrl;

    if ((generation < curr_gen) || (valid == 0u))
      return true;
  }
  return false;
}

void kernel_mmio_driver(kernel_arg_t *__UNIFORM__ arg) {
  arg->status = MMIO_STATUS_INIT;
  arg->last_ctrl = 0;

  uint32_t eid = 0, generation = 0;
  uint32_t alloc_raw = 0;
  if (!resolve_gemm_mmio_base(eid, generation, alloc_raw)) {
    arg->last_ctrl = alloc_raw;
    if (((alloc_raw >> JOB_MMIO_ALLOC_SUCC_BIT) & 1u) == 0) {
      arg->status = MMIO_STATUS_ALLOC_FAIL;
    } else {
      arg->job_eid = eid;
      arg->job_generation = generation;
      arg->status = MMIO_STATUS_BAD_EID;
    }
    return;
  }

  arg->last_ctrl = alloc_raw;

  if (eid >= GEMM_JOB_NUM_ENTRIES) {
    arg->job_eid = eid;
    arg->job_generation = generation;
    arg->status = MMIO_STATUS_BAD_EID;
    return;
  }

  arg->job_eid = eid;
  arg->job_generation = generation;

  program_job_regs(eid, arg);

  if (!wait_job_done(eid, generation, arg->last_ctrl)) {
    arg->status = MMIO_STATUS_WAIT_STUCK;
    return;
  }

  arg->status = MMIO_STATUS_OK;
}

int main() {
  if (vx_core_id() != 0 || vx_warp_id() != 0 || vx_thread_id() != 0) {
    return 0;
  }

  auto arg = reinterpret_cast<kernel_arg_t *>(csr_read(VX_CSR_MSCRATCH));
  kernel_mmio_driver(arg);
  return 0;
}
