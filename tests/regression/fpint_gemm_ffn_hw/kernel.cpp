#include "common.h"
#include <vx_spawn.h>
#include <vx_intrinsics.h>
#ifdef GEMM_PARTITION_LOG
#include <vx_print.h>
#endif

const int LSU_WORD_SIZE = 8; // bytes per beat for global alloc and per-entry beats

static constexpr uint64_t kGemmRegOffset = 0x0000000000001080ull;
static uint64_t gGemmRegBaseAddr = kGemmRegOffset;

static constexpr uint32_t kTileM = 128u;
static constexpr uint32_t kTileN = 128u;

struct tb_partition_t {
  bool has_work;
  uint32_t m_start;
  uint32_t n_start;
  uint32_t target_M;
  uint32_t target_N;
};

static inline uint32_t mmio_read32(uint64_t addr) {
  return *reinterpret_cast<volatile uint32_t*>(addr);
}

static inline void mmio_write32(uint64_t addr, uint32_t value) {
  *reinterpret_cast<volatile uint32_t*>(addr) = value;
}

static inline uint32_t bitfield_mask(uint32_t bits) {
  return (bits >= 32) ? 0xFFFFFFFFu : ((1u << bits) - 1u);
}

static inline uint32_t min_u32(uint32_t a, uint32_t b) {
  return (a < b) ? a : b;
}

static inline uint32_t ceil_div_u32(uint32_t a, uint32_t b) {
  return (a + b - 1u) / b;
}

static tb_partition_t compute_partition(uint32_t core_id, uint32_t num_tbs, uint32_t M, uint32_t N) {
  tb_partition_t part = {false, 0u, 0u, 0u, 0u};

  if (num_tbs == 0 || M == 0 || N == 0)
    return part;

  uint32_t mt_dim = ceil_div_u32(M, kTileM);
  uint32_t nt_dim = ceil_div_u32(N, kTileN);
  if (mt_dim == 0 || nt_dim == 0)
    return part;

  uint32_t bn = min_u32(num_tbs, nt_dim);
  if (bn == 0)
    return part;

  uint32_t bm = ceil_div_u32(num_tbs, bn);
  uint32_t grid_tbs = bm * bn;
  if (core_id >= grid_tbs)
    return part;

  uint32_t tb_n = core_id % bn;
  uint32_t tb_m = core_id / bn;
  if (tb_m >= bm)
    return part;

  uint32_t nt_base = nt_dim / bn;
  uint32_t nt_rem  = nt_dim % bn;
  uint32_t nt_cnt  = nt_base + ((tb_n < nt_rem) ? 1u : 0u);
  uint32_t nt0     = tb_n * nt_base + min_u32(tb_n, nt_rem);

  uint32_t mt_base = mt_dim / bm;
  uint32_t mt_rem  = mt_dim % bm;
  uint32_t mt_cnt  = mt_base + ((tb_m < mt_rem) ? 1u : 0u);
  uint32_t mt0     = tb_m * mt_base + min_u32(tb_m, mt_rem);

  if (mt_cnt == 0 || nt_cnt == 0)
    return part;

  uint32_t m_start = mt0 * kTileM;
  uint32_t n_start = nt0 * kTileN;
  if (m_start >= M || n_start >= N)
    return part;

  uint32_t m_tiles_span = mt_cnt * kTileM;
  uint32_t n_tiles_span = nt_cnt * kTileN;

  part.has_work = true;
  part.m_start = m_start;
  part.n_start = n_start;
  part.target_M = min_u32(M - m_start, m_tiles_span);
  part.target_N = min_u32(N - n_start, n_tiles_span);
  return part;
}

static constexpr uint32_t kMaxPollIters = 100000000u;
static constexpr uint32_t kPoisonWord = 0xBAADF00Du;

static inline void split_u64(uint64_t value, uint32_t& lo, uint32_t& hi) {
  lo = uint32_t(value & 0xFFFFFFFFull);
  hi = uint32_t(value >> 32);
}

static inline uint32_t log2_pow2_u32(uint32_t x) {
  uint32_t s = 0;
  while ((1u << s) != x) ++s;
  return s;
}

// ----------------------------------------------------------------------------
// 32-bit MMIO layout helpers
//
// HW(VX_job_desc_mmio_regs) layout:
//   [base + 0 .. base + DATA_SIZE-1] : global alloc "beat"
//   [base + DATA_SIZE .. ]           : per-entry beats (each beat is DATA_SIZE bytes)
//
// Here we *still* compute beat boundaries using LSU_WORD_SIZE (DATA_SIZE),
// but access within a beat using 32-bit addresses (byte offset).
// ----------------------------------------------------------------------------
static constexpr uint32_t kMmioBeatBytes = LSU_WORD_SIZE;      // usually 8
static constexpr uint32_t kWordsPerBeat  = kMmioBeatBytes / 4; // usually 2
static constexpr uint32_t kNumBeats      = (GEMM_JOB_NUM_REGS32 + kWordsPerBeat - 1u) / kWordsPerBeat;
static constexpr uint32_t kEntryStrideBytes = kNumBeats * kMmioBeatBytes;
static constexpr uint32_t kGlobalAllocBytes = kMmioBeatBytes;

// Return byte address of regs32[eid][reg_idx32]
static inline uint64_t job_entry_reg32_addr(uint32_t eid, uint32_t reg_idx32) {
  uint32_t beat_idx      = reg_idx32 / kWordsPerBeat;
  uint32_t word_in_beat  = reg_idx32 % kWordsPerBeat;

  return gGemmRegBaseAddr
       + uint64_t(kGlobalAllocBytes)                 // skip global alloc beat
       + uint64_t(eid) * uint64_t(kEntryStrideBytes) // entry stride
       + uint64_t(beat_idx) * uint64_t(kMmioBeatBytes)
       + uint64_t(word_in_beat) * 4ull;              // 32-bit lane inside beat
}

static inline void job_write_reg32(uint32_t eid, uint32_t reg_idx32, uint32_t value) {
  mmio_write32(job_entry_reg32_addr(eid, reg_idx32), value);
}

static inline uint32_t job_read_reg32(uint32_t eid, uint32_t reg_idx32) {
  return mmio_read32(job_entry_reg32_addr(eid, reg_idx32));
}

static inline void job_write_reg64(uint32_t eid, uint32_t reg_lo_idx, uint64_t value) {
  uint32_t lo, hi;
  split_u64(value, lo, hi);
  job_write_reg32(eid, reg_lo_idx,     lo);
  job_write_reg32(eid, reg_lo_idx + 1, hi);
}

static inline void decode_alloc_rsp(uint32_t r, uint32_t& eid, uint32_t& generation) {
  eid = (r >> JOB_MMIO_ALLOC_ENTRY_LSB) & bitfield_mask(JOB_MMIO_ALLOC_ENTRY_BITS);
  generation = (r >> JOB_MMIO_ALLOC_GEN_LSB) & bitfield_mask(JOB_MMIO_ALLOC_GEN_BITS);
}

// Read alloc response from lane0 word0 (base + 0) as 32-bit
static bool gemm_job_alloc_fixed(uint32_t& eid, uint32_t& generation, uint32_t& raw_rsp) {
  const uint64_t base = kGemmRegOffset; // fixed base
  gGemmRegBaseAddr = base;

  uint32_t r = mmio_read32(base); // <<---- 32-bit read, not beat read
  raw_rsp = r;

  if (r == kPoisonWord)
    return false;

  if (((r >> JOB_MMIO_ALLOC_SUCC_BIT) & 1u) == 0)
    return false;

  decode_alloc_rsp(r, eid, generation);

  if (eid >= GEMM_JOB_NUM_ENTRIES)
    return false;

  return true;
}

static void program_job_regs(uint32_t eid, const kernel_arg_t* arg, const tb_partition_t& part) {
  // Global/DRAM bases
  job_write_reg64(eid, REG_INPUT_BASE_LO,  arg->input_base);
  job_write_reg64(eid, REG_WEIGHT_BASE_LO, arg->weight_base);
  job_write_reg64(eid, REG_OUTPUT_BASE_LO, arg->output_base);
  job_write_reg64(eid, REG_SCALE_BASE_LO,  arg->scale_base);
  job_write_reg64(eid, REG_ZP_BASE_LO,     arg->zp_base);

  // LMEM scratch bases
  job_write_reg64(eid, REG_LMEM_IBUF0_LO,  arg->lmem_ibuf0_base);
  job_write_reg64(eid, REG_LMEM_IBUF1_LO,  arg->lmem_ibuf1_base);
  job_write_reg64(eid, REG_LMEM_WBUF0_LO,  arg->lmem_wbuf0_base);
  job_write_reg64(eid, REG_LMEM_WBUF1_LO,  arg->lmem_wbuf1_base);
  job_write_reg64(eid, REG_LMEM_SCBUF0_LO, arg->lmem_scbuf0_base);
  job_write_reg64(eid, REG_LMEM_SCBUF1_LO, arg->lmem_scbuf1_base);
  job_write_reg64(eid, REG_LMEM_ZPBUF0_LO, arg->lmem_zpbuf0_base);
  job_write_reg64(eid, REG_LMEM_ZPBUF1_LO, arg->lmem_zpbuf1_base);
  job_write_reg64(eid, REG_LMEM_OBUF_LO,   arg->lmem_obuf_base);

  // Original problem sizes
  job_write_reg32(eid, REG_M_ORIG, arg->M);
  job_write_reg32(eid, REG_N_ORIG, arg->N);
  job_write_reg32(eid, REG_K_ORIG, arg->K);
  job_write_reg32(eid, REG_QBLK_ORIG, log2_pow2_u32(arg->QBLK));

  // Partition sizes/offsets for this job
  job_write_reg32(eid, REG_M_TARGET, part.target_M);
  job_write_reg32(eid, REG_N_TARGET, part.target_N);
  job_write_reg32(eid, REG_K_TARGET, arg->K);
  job_write_reg32(eid, REG_M_START, part.m_start);
  job_write_reg32(eid, REG_N_START, part.n_start);

  // WTRANS/QDIR flags
  job_write_reg32(eid, REG_WTRANS, arg->WTRANS);
  job_write_reg32(eid, REG_QDIR, arg->QDIR);

  // Start (valid=1)
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
  uint32_t core_id = vx_core_id();
  uint32_t num_cores = vx_num_cores();
  bool reporter = (core_id == 0);

  if (reporter) {
    arg->status = MMIO_STATUS_INIT;
    arg->last_ctrl = 0;
  }

  // Poll-only baseline mode: spin on a GEMM MMIO read for arg->K iterations
  // without launching any GEMM job. Triggered by QDIR == 0xDEAD. Lets the
  // host measure pure Vortex-core polling overhead so HW-GEMM ΔP can be
  // separated from polling baseline.
  if (arg->QDIR == 0xDEAD) {
    volatile uint32_t sink = 0;
    const uint64_t addr = kGemmRegOffset;
    for (uint32_t i = 0; i < arg->K; ++i) {
      sink ^= *reinterpret_cast<volatile uint32_t*>(addr);
    }
    if (reporter) {
      arg->last_ctrl = sink;
      arg->status = MMIO_STATUS_OK;
    }
    return;
  }

  uint32_t num_tbs = arg->grid_dim[0] * arg->grid_dim[1];
  if (num_tbs == 0)
    num_tbs = num_cores;

  tb_partition_t part = compute_partition(core_id, num_tbs, arg->M, arg->N);
#ifdef GEMM_PARTITION_LOG
  vx_printf("[gemm-part] cid=%u/%u tbs=%u has_work=%u m_start=%u n_start=%u target_M=%u target_N=%u K=%u\n",
            core_id, num_cores, num_tbs,
            part.has_work ? 1u : 0u,
            part.m_start, part.n_start,
            part.target_M, part.target_N,
            arg->K);
#endif

  if (!part.has_work) {
    if (reporter)
      arg->status = MMIO_STATUS_OK;
    return;
  }

  uint32_t eid = 0, generation = 0;
  uint32_t alloc_raw = 0;

  if (!gemm_job_alloc_fixed(eid, generation, alloc_raw)) {
    if (reporter) {
      arg->last_ctrl = alloc_raw;
      if (alloc_raw == kPoisonWord) {
        arg->status = MMIO_STATUS_ALLOC_FAIL;
      } else if (((alloc_raw >> JOB_MMIO_ALLOC_SUCC_BIT) & 1u) == 0) {
        arg->status = MMIO_STATUS_ALLOC_FAIL;
      } else {
        arg->job_eid = eid;
        arg->job_generation = generation;
        arg->status = MMIO_STATUS_BAD_EID;
      }
    }
    return;
  }

  if (reporter) {
    arg->last_ctrl = alloc_raw;
    arg->job_eid = eid;
    arg->job_generation = generation;
  }

  program_job_regs(eid, arg, part);

  uint32_t last_ctrl = 0;
  if (!wait_job_done(eid, generation, last_ctrl)) {
    if (reporter) {
      arg->last_ctrl = last_ctrl;
      arg->status = MMIO_STATUS_WAIT_STUCK;
    }
    return;
  }

  if (reporter) {
    arg->last_ctrl = last_ctrl;
    arg->status = MMIO_STATUS_OK;
  }
}

int main() {
  if (vx_warp_id() != 0 || vx_thread_id() != 0) {
    return 0;
  }

  auto arg = reinterpret_cast<kernel_arg_t*>(csr_read(VX_CSR_MSCRATCH));
  kernel_mmio_driver(arg);
  return 0;
}