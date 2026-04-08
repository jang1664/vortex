#include "common.h"
#include <vx_spawn.h>
#include <vx_intrinsics.h>

// ---------------------------------------------------------------------------
// HW tile dimensions (from VX_config.h)
// ---------------------------------------------------------------------------
static constexpr uint32_t DMA_MT     = GEMM_FSM_MT;      // 128
static constexpr uint32_t DMA_KT     = GEMM_FSM_KT;      // 128
static constexpr uint32_t DMA_MXU_KT = GEMM_FSM_MXU_KT;  // 32
static constexpr uint32_t DMA_MXU_NT = GEMM_FSM_MXU_NT;   // 32

// ---------------------------------------------------------------------------
// MMIO / stream addresses
// Note: GEMM_REG_BASE_ADDR macro uses Verilog underscore hex which is
//       invalid in C++, so we define a C-compatible constant here.
// ---------------------------------------------------------------------------
#ifdef XLEN_64
static constexpr uint64_t GEMM_BASE        = 0x0000000000001080ULL;
#else
static constexpr uint64_t GEMM_BASE        = 0x0000FFFF00000000ULL;
#endif
static constexpr uint64_t GEMM_STREAM_ADDR = GEMM_BASE + 8;

// ---------------------------------------------------------------------------
// Raw opcodes (must match VX_cmd_constructor.sv)
// ---------------------------------------------------------------------------
static constexpr uint64_t OP_DMA_LOAD         = 1;
static constexpr uint64_t OP_DMA_STORE        = 2;
static constexpr uint64_t OP_NOTIFY           = 3;
static constexpr uint64_t OP_WAIT             = 4;
static constexpr uint64_t OP_MXU_LOAD_WEIGHT  = 5;
static constexpr uint64_t OP_MXU_LOAD_QPARAM  = 6;
static constexpr uint64_t OP_MXU_LOAD_INPUT   = 7;
static constexpr uint64_t OP_MXU_STORE_OUTPUT = 8;
static constexpr uint64_t OP_CLEAR            = 9;

// ---------------------------------------------------------------------------
// Sync register IDs (must match testbench convention)
// ---------------------------------------------------------------------------
static constexpr uint32_t RID_LD  = 0;   // DMA LOAD
static constexpr uint32_t RID_W   = 2;   // MXU LOAD_WEIGHT
static constexpr uint32_t RID_SZ  = 4;   // MXU LOAD_QPARAM
static constexpr uint32_t RID_G   = 6;   // MXU LOAD_INPUT (GEMM)
static constexpr uint32_t RID_O   = 8;   // MXU STORE_OUTPUT
static constexpr uint32_t RID_ST  = 10;  // DMA STORE

// ---------------------------------------------------------------------------
// MMIO helpers
// ---------------------------------------------------------------------------
static inline uint32_t mmio_read32(uint64_t addr) {
  return *reinterpret_cast<volatile uint32_t*>(addr);
}

static inline void stream_write64(uint64_t value) {
  *reinterpret_cast<volatile uint64_t*>(GEMM_STREAM_ADDR) = value;
}

// ---------------------------------------------------------------------------
// Command word builders
// ---------------------------------------------------------------------------

// DMA_LOAD / DMA_STORE: 3 words
static inline void cmd_dma(uint64_t op, uint32_t tmem_base24, uint64_t dram_base36,
                           uint16_t tmem_stride, uint16_t dram_stride,
                           uint16_t bound, uint32_t seg_size) {
  uint64_t w0 = (uint64_t(tmem_base24 & 0xFFFFFF) << 40)
              | (uint64_t(dram_base36 & 0xFFFFFFFFFull) << 4)
              | (op & 0xF);
  uint64_t w1 = (uint64_t(tmem_stride) << 32)
              | (uint64_t(dram_stride) << 16)
              | uint64_t(bound);
  uint64_t w2 = uint64_t(seg_size);
  stream_write64(w0);
  stream_write64(w1);
  stream_write64(w2);
}

// NOTIFY: 1 word
static inline void cmd_notify(bool set_mode, uint32_t value, uint32_t reg_id) {
  uint64_t w = (uint64_t(set_mode ? 1 : 0) << 41)
             | (uint64_t(value & 0xFFFFFFFF) << 9)
             | (uint64_t(reg_id & 0x1F) << 4)
             | OP_NOTIFY;
  stream_write64(w);
}

// WAIT: 1 word
static inline void cmd_wait(uint32_t value, uint32_t reg_id) {
  uint64_t w = (uint64_t(value & 0xFFFFFFFF) << 9)
             | (uint64_t(reg_id & 0x1F) << 4)
             | OP_WAIT;
  stream_write64(w);
}

// MXU_LOAD_WEIGHT: 1 word
static inline void cmd_mxu_load_weight(bool wtrans, bool reg_idx,
                                       uint16_t bound, uint16_t stride,
                                       uint32_t tmem_base24) {
  uint64_t w = (uint64_t(wtrans ? 1 : 0) << 61)
             | (uint64_t(reg_idx ? 1 : 0) << 60)
             | (uint64_t(bound) << 44)
             | (uint64_t(stride) << 28)
             | (uint64_t(tmem_base24 & 0xFFFFFF) << 4)
             | OP_MXU_LOAD_WEIGHT;
  stream_write64(w);
}

// MXU_LOAD_QPARAM: 2 words
static inline void cmd_mxu_load_qparam(uint32_t mxu_base24, uint32_t tmem_base24,
                                       uint16_t tmem_stride, uint16_t mxu_stride,
                                       uint16_t bound) {
  uint64_t w0 = (uint64_t(mxu_base24 & 0xFFFFFF) << 28)
              | (uint64_t(tmem_base24 & 0xFFFFFF) << 4)
              | OP_MXU_LOAD_QPARAM;
  uint64_t w1 = (uint64_t(tmem_stride) << 32)
              | (uint64_t(mxu_stride) << 16)
              | uint64_t(bound);
  stream_write64(w0);
  stream_write64(w1);
}

// MXU_LOAD_INPUT: 2 words
static inline void cmd_mxu_load_input(bool is_accum, bool is_last,
                                      bool wreg_idx, bool sreg_idx, bool zreg_idx,
                                      bool qdir, uint32_t tmem_base24,
                                      uint32_t acc_mem_base24,
                                      uint32_t acc_cnt,
                                      uint16_t stride, uint16_t bound) {
  uint64_t w0 = (uint64_t(is_accum ? 1 : 0) << 57)
              | (uint64_t(is_last ? 1 : 0) << 56)
              | (uint64_t(wreg_idx ? 1 : 0) << 55)
              | (uint64_t(sreg_idx ? 1 : 0) << 54)
              | (uint64_t(zreg_idx ? 1 : 0) << 53)
              | (uint64_t(qdir ? 1 : 0) << 52)
              | (uint64_t(tmem_base24 & 0xFFFFFF) << 28)
              | (uint64_t(acc_mem_base24 & 0xFFFFFF) << 4)
              | OP_MXU_LOAD_INPUT;
  uint64_t w1 = (uint64_t(acc_cnt) << 32)
              | (uint64_t(stride) << 16)
              | uint64_t(bound);
  stream_write64(w0);
  stream_write64(w1);
}

// MXU_STORE_OUTPUT: 2 words
static inline void cmd_mxu_store_output(uint32_t tmem_base24, uint32_t acc_mem_base24,
                                        uint16_t stride, uint16_t bound) {
  uint64_t w0 = (uint64_t(tmem_base24 & 0xFFFFFF) << 28)
              | (uint64_t(acc_mem_base24 & 0xFFFFFF) << 4)
              | OP_MXU_STORE_OUTPUT;
  uint64_t w1 = (uint64_t(stride) << 16)
              | uint64_t(bound);
  stream_write64(w0);
  stream_write64(w1);
}

// CLEAR: 1 word
static inline void cmd_clear() {
  stream_write64(OP_CLEAR);
}

// ---------------------------------------------------------------------------
// Utility
// ---------------------------------------------------------------------------
static inline uint32_t min_u32(uint32_t a, uint32_t b) { return (a < b) ? a : b; }
static inline uint32_t ceil_div_u32(uint32_t a, uint32_t b) { return (a + b - 1u) / b; }
static inline uint32_t bitfield_mask(uint32_t bits) {
  return (bits >= 32) ? 0xFFFFFFFFu : ((1u << bits) - 1u);
}

// ---------------------------------------------------------------------------
// Job alloc (read doorbell at GEMM_BASE + 0)
// ---------------------------------------------------------------------------
static bool gemm_job_alloc(uint32_t& eid) {
  uint32_t r = mmio_read32(GEMM_BASE);
  if (r == 0xBAADF00Du)
    return false;
  if (((r >> JOB_MMIO_ALLOC_SUCC_BIT) & 1u) == 0)
    return false;
  eid = (r >> JOB_MMIO_ALLOC_ENTRY_LSB) & bitfield_mask(JOB_MMIO_ALLOC_ENTRY_BITS);
  return (eid < GEMM_JOB_NUM_ENTRIES);
}

// ---------------------------------------------------------------------------
// Tile partitioning (same as before)
// ---------------------------------------------------------------------------
struct partition_t {
  bool     has_work;
  uint32_t m_start;
  uint32_t n_start;
  uint32_t target_M;
  uint32_t target_N;
};

static partition_t compute_partition(uint32_t core_id, uint32_t num_tbs,
                                    uint32_t M, uint32_t N) {
  partition_t part = {false, 0, 0, 0, 0};
  if (num_tbs == 0 || M == 0 || N == 0) return part;

  uint32_t mt_dim = ceil_div_u32(M, DMA_MT);
  uint32_t nt_dim = ceil_div_u32(N, DMA_MXU_NT);
  if (mt_dim == 0 || nt_dim == 0) return part;

  uint32_t bn = min_u32(num_tbs, nt_dim);
  if (bn == 0) return part;
  uint32_t bm = ceil_div_u32(num_tbs, bn);
  if (core_id >= bm * bn) return part;

  uint32_t tb_n = core_id % bn;
  uint32_t tb_m = core_id / bn;
  if (tb_m >= bm) return part;

  uint32_t nt_base = nt_dim / bn;
  uint32_t nt_rem  = nt_dim % bn;
  uint32_t nt_cnt  = nt_base + ((tb_n < nt_rem) ? 1u : 0u);
  uint32_t nt0     = tb_n * nt_base + min_u32(tb_n, nt_rem);

  uint32_t mt_base = mt_dim / bm;
  uint32_t mt_rem  = mt_dim % bm;
  uint32_t mt_cnt  = mt_base + ((tb_m < mt_rem) ? 1u : 0u);
  uint32_t mt0     = tb_m * mt_base + min_u32(tb_m, mt_rem);

  if (mt_cnt == 0 || nt_cnt == 0) return part;

  uint32_t m_start = mt0 * DMA_MT;
  uint32_t n_start = nt0 * DMA_MXU_NT;
  if (m_start >= M || n_start >= N) return part;

  part.has_work = true;
  part.m_start  = m_start;
  part.n_start  = n_start;
  part.target_M = min_u32(M - m_start, mt_cnt * DMA_MT);
  part.target_N = min_u32(N - n_start, nt_cnt * DMA_MXU_NT);
  return part;
}

// ---------------------------------------------------------------------------
// Main GEMM command-stream driver
// ---------------------------------------------------------------------------
static void run_gemm_stream(const kernel_arg_t* arg, const partition_t& part) {
  const uint32_t M_part = part.target_M;
  const uint32_t N_part = part.target_N;
  const uint32_t K_full = arg->K;
  const uint32_t QBLK   = arg->QBLK;
  const bool     wtrans  = (arg->WTRANS != 0);
  const bool     qdir    = (arg->QDIR != 0);

  const uint32_t m_tiles  = ceil_div_u32(M_part, DMA_MT);
  const uint32_t n_tiles  = ceil_div_u32(N_part, DMA_MXU_NT);
  const uint32_t k_tiles  = K_full / DMA_KT;
  const uint32_t kb_per_kt = DMA_KT / DMA_MXU_KT;

  // Quantization group counts
  const uint32_t groups_per_kt = ceil_div_u32(DMA_KT, QBLK);
  const uint32_t ng_per_nt     = ceil_div_u32(DMA_MXU_NT, QBLK);

  // Segment sizes (bytes)
  const uint32_t w_seg_bytes  = DMA_MXU_KT * (DMA_MXU_NT / 2);

  // LMEM buffer bases (from host)
  const uint32_t ibuf_base  = uint32_t(arg->lmem_ibuf0_base);
  const uint32_t wbuf_base  = uint32_t(arg->lmem_wbuf0_base);
  const uint32_t scbuf_base = uint32_t(arg->lmem_scbuf0_base);
  const uint32_t zpbuf_base = uint32_t(arg->lmem_zpbuf0_base);
  const uint32_t obuf_base  = uint32_t(arg->lmem_obuf_base);

  // DRAM bases
  const uint64_t dram_in_base = arg->input_base;
  const uint64_t dram_w_base  = arg->weight_base;
  const uint64_t dram_sc_base = arg->scale_base;
  const uint64_t dram_zp_base = arg->zp_base;
  const uint64_t dram_out_base = arg->output_base;

  // QPARAM strides (for MXU_LOAD_QPARAM)
  const uint16_t qparam_src_stride = uint16_t(zpbuf_base - scbuf_base);
  const uint16_t qparam_dst_stride = uint16_t(DMA_MXU_NT * 4);  // scale+zp interleaved in MXU

  for (uint32_t mt = 0; mt < m_tiles; ++mt) {
    uint32_t cur_m = min_u32(M_part - mt * DMA_MT, DMA_MT);

    for (uint32_t nt = 0; nt < n_tiles; ++nt) {

      for (uint32_t kt = 0; kt < k_tiles; ++kt) {
        bool is_first_kt = (kt == 0);
        bool is_last_kt  = (kt == k_tiles - 1);

        // Compute DRAM tile addresses
        uint64_t dram_in_tile = dram_in_base
                              + uint64_t(part.m_start + mt * DMA_MT) * uint64_t(K_full) * 2
                              + uint64_t(kt) * uint64_t(cur_m) * uint64_t(DMA_KT) * 2;
        // Note: DRAM layout for input is row-major [M, K] in fp16
        // For tiled access: offset = m_start*K*2 + kt*DMA_KT*2 per row, but DMA reads cur_m*DMA_KT contiguous bytes
        // Simplification: assume tiled DRAM layout (from host)
        dram_in_tile = dram_in_base
                     + uint64_t(part.m_start + mt * DMA_MT) * uint64_t(K_full) * 2
                     + uint64_t(kt * DMA_KT) * 2;

        uint32_t weight_kt_bytes = DMA_KT * (DMA_MXU_NT / 2);
        uint64_t dram_w_tile = dram_w_base
                             + uint64_t(kt) * uint64_t(n_tiles) * uint64_t(weight_kt_bytes)
                             + uint64_t(nt) * uint64_t(weight_kt_bytes);

        uint32_t scale_kt_bytes, zp_kt_bytes;
        uint64_t dram_sc_tile, dram_zp_tile;
        if (!qdir) {
          // QCOL: scale/zp shape [groups_per_kt, N]
          scale_kt_bytes = groups_per_kt * DMA_MXU_NT * 2;
          zp_kt_bytes    = groups_per_kt * DMA_MXU_NT * 2;
          dram_sc_tile = dram_sc_base
                       + uint64_t(kt) * uint64_t(n_tiles) * uint64_t(scale_kt_bytes)
                       + uint64_t(nt) * uint64_t(scale_kt_bytes);
          dram_zp_tile = dram_zp_base
                       + uint64_t(kt) * uint64_t(n_tiles) * uint64_t(zp_kt_bytes)
                       + uint64_t(nt) * uint64_t(zp_kt_bytes);
        } else {
          // QROW: scale/zp shape [K, ng_per_nt]
          scale_kt_bytes = DMA_KT * ng_per_nt * 2;
          zp_kt_bytes    = DMA_KT * ng_per_nt * 2;
          dram_sc_tile = dram_sc_base
                       + uint64_t(kt) * uint64_t(n_tiles) * uint64_t(scale_kt_bytes)
                       + uint64_t(nt) * uint64_t(scale_kt_bytes);
          dram_zp_tile = dram_zp_base
                       + uint64_t(kt) * uint64_t(n_tiles) * uint64_t(zp_kt_bytes)
                       + uint64_t(nt) * uint64_t(zp_kt_bytes);
        }

        uint32_t cur_input_kt_bytes = cur_m * DMA_KT * 2;

        // ---------------------------------------------------------------
        // PHASE 1: DMA LOAD (input, weight, scale, zp)
        // ---------------------------------------------------------------
        cmd_dma(OP_DMA_LOAD, ibuf_base, uint64_t(dram_in_tile),
                0, 0, 1, cur_input_kt_bytes);
        cmd_notify(true, 1, RID_LD);  // SET rid_ld = 1

        cmd_dma(OP_DMA_LOAD, wbuf_base, uint64_t(dram_w_tile),
                0, 0, 1, weight_kt_bytes);
        cmd_notify(false, 1, RID_LD);  // ADD 1 → rid_ld = 2

        cmd_dma(OP_DMA_LOAD, scbuf_base, uint64_t(dram_sc_tile),
                0, 0, 1, scale_kt_bytes);
        cmd_notify(false, 1, RID_LD);  // ADD 1 → rid_ld = 3

        cmd_dma(OP_DMA_LOAD, zpbuf_base, uint64_t(dram_zp_tile),
                0, 0, 1, zp_kt_bytes);
        cmd_notify(false, 1, RID_LD);  // ADD 1 → rid_ld = 4

        cmd_wait(4, RID_LD);  // Wait until all 4 DMAs complete

        // ---------------------------------------------------------------
        // PHASE 2-5: K-block loop
        // ---------------------------------------------------------------
        for (uint32_t kb = 0; kb < kb_per_kt; ++kb) {
          bool is_first_kb = (is_first_kt && kb == 0);
          bool is_last_kb  = (is_last_kt && kb == kb_per_kt - 1);

          // PHASE 2: MXU LOAD_WEIGHT
          uint32_t w_lmem_base = wbuf_base + kb * w_seg_bytes;
          cmd_mxu_load_weight(wtrans, false, 1, 0, w_lmem_base);
          cmd_notify(kb == 0, 1, RID_W);

          // PHASE 3: MXU LOAD_QPARAM
          if (!qdir) {
            // QCOL: load once per K-tile (at kb==0)
            if (kb == 0) {
              cmd_mxu_load_qparam(0, scbuf_base,
                                  qparam_src_stride, qparam_dst_stride, 2);
              cmd_notify(true, 1, RID_SZ);
            }
          } else {
            // QROW: load every K-block
            uint32_t qparam_kb_offset = DMA_MXU_KT * ng_per_nt * 2;
            uint32_t sc_offset = scbuf_base + kb * qparam_kb_offset;
            cmd_mxu_load_qparam(0, sc_offset,
                                qparam_src_stride, qparam_dst_stride, 2);
            cmd_notify(kb == 0, 1, RID_SZ);
          }

          // PHASE 4: WAIT for weight + qparam
          cmd_wait(kb + 1, RID_W);
          if (!qdir) {
            if (kb == 0)
              cmd_wait(1, RID_SZ);
          } else {
            cmd_wait(kb + 1, RID_SZ);
          }

          // PHASE 5: MXU LOAD_INPUT + GEMM compute
          uint32_t i_src_base = ibuf_base + kb * cur_m * DMA_MXU_KT * 2;
          cmd_mxu_load_input(!is_first_kb, is_last_kb,
                             false, false, false,
                             qdir, i_src_base, 0,
                             cur_m,
                             uint16_t(DMA_MXU_KT * 2),
                             uint16_t(cur_m));
          cmd_notify(kb == 0, 1, RID_G);
          cmd_wait(kb + 1, RID_G);
        }

        // ---------------------------------------------------------------
        // PHASE 6: MXU STORE_OUTPUT (after all K-blocks in this K-tile)
        // ---------------------------------------------------------------
        cmd_mxu_store_output(obuf_base, 0, 0, uint16_t(cur_m));
        cmd_notify(true, 1, RID_O);
        cmd_wait(1, RID_O);
      }

      // -----------------------------------------------------------------
      // PHASE 7: DMA STORE output to DRAM (after all K-tiles)
      // -----------------------------------------------------------------
      uint32_t cur_output_tile_bytes = cur_m * DMA_MXU_NT * 2;
      uint64_t dram_out_tile = dram_out_base
                             + uint64_t(part.m_start + mt * DMA_MT) * uint64_t(N_part) * 2
                             + uint64_t(part.n_start + nt * DMA_MXU_NT) * 2;
      // TODO: verify DRAM output address calculation matches host layout

      cmd_dma(OP_DMA_STORE, obuf_base, uint64_t(dram_out_tile),
              0, 0, 1, cur_output_tile_bytes);
      cmd_notify(true, 1, RID_ST);
      cmd_wait(1, RID_ST);
    }
  }

  // CLEAR — signal job completion
  cmd_clear();
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------
void kernel_body(kernel_arg_t *__UNIFORM__ arg) {
  uint32_t core_id = vx_core_id();
  uint32_t num_cores = vx_num_cores();

  uint32_t num_tbs = arg->grid_dim[0] * arg->grid_dim[1];
  if (num_tbs == 0) num_tbs = num_cores;

  partition_t part = compute_partition(core_id, num_tbs, arg->M, arg->N);

  if (!part.has_work) {
    if (core_id == 0) arg->status = MMIO_STATUS_OK;
    return;
  }

  uint32_t eid = 0;
  if (!gemm_job_alloc(eid)) {
    if (core_id == 0) arg->status = MMIO_STATUS_ALLOC_FAIL;
    return;
  }

  if (core_id == 0) {
    arg->job_eid = eid;
  }

  run_gemm_stream(arg, part);

  if (core_id == 0) {
    arg->status = MMIO_STATUS_OK;
  }
}

int main() {
  if (vx_warp_id() != 0 || vx_thread_id() != 0)
    return 0;

  auto arg = reinterpret_cast<kernel_arg_t*>(csr_read(VX_CSR_MSCRATCH));
  kernel_body(arg);
  return 0;
}
