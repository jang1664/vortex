#include "common.h"
#include <vx_intrinsics.h>

// MMIO addresses for GEMM instruction stream frontend
static constexpr uint64_t GEMM_BASE        = 0x0000000000001080ULL;
static constexpr uint64_t GEMM_STREAM_ADDR = GEMM_BASE + 8ULL;

static inline uint32_t mmio_read32(uint64_t addr) {
  return *reinterpret_cast<volatile uint32_t*>(addr);
}

static inline void stream_send(uint64_t word) {
  *reinterpret_cast<volatile uint64_t*>(GEMM_STREAM_ADDR) = word;
}

// ============================================================================
// Instruction word builders (matching tb_VX_gemm_node_improve encoding)
// ============================================================================

static inline uint64_t make_notify(uint32_t set_mode, uint32_t value, uint32_t reg_id) {
  uint64_t w = 0;
  w |= (uint64_t(set_mode & 1u) << 41);
  w |= (uint64_t(value) << 9);
  w |= (uint64_t(reg_id & 0x1Fu) << 4);
  w |= RAW_OP_NOTIFY;
  return w;
}

static inline uint64_t make_wait(uint32_t value, uint32_t reg_id) {
  uint64_t w = 0;
  w |= (uint64_t(value) << 9);
  w |= (uint64_t(reg_id & 0x1Fu) << 4);
  w |= RAW_OP_WAIT;
  return w;
}

static inline uint64_t make_clear() {
  return uint64_t(RAW_OP_CLEAR);
}

// DMA command: 3-word instruction
static inline uint64_t make_dma_word0(uint32_t tmem_base, uint64_t dram_base, uint32_t op) {
  uint64_t w = 0;
  w |= (uint64_t(tmem_base & 0xFFFFFFu) << 40);
  w |= ((dram_base & 0xFFFFFFFFFULL) << 4);
  w |= (op & 0xFu);
  return w;
}

static inline uint64_t make_dma_word1(uint32_t tmem_stride, uint32_t dram_stride, uint32_t bound) {
  uint64_t w = 0;
  w |= (uint64_t(tmem_stride & 0xFFFFu) << 32);
  w |= (uint64_t(dram_stride & 0xFFFFu) << 16);
  w |= (bound & 0xFFFFu);
  return w;
}

static inline uint64_t make_dma_word2(uint32_t seg_size) {
  return uint64_t(seg_size);
}

static void send_dma_cmd(uint32_t op, uint32_t tmem_base, uint64_t dram_base,
                         uint32_t tmem_stride, uint32_t dram_stride,
                         uint32_t bound, uint32_t seg_size) {
  stream_send(make_dma_word0(tmem_base, dram_base, op));
  stream_send(make_dma_word1(tmem_stride, dram_stride, bound));
  stream_send(make_dma_word2(seg_size));
}

// MXU_LOAD_WEIGHT: 1-word instruction
static inline uint64_t make_mxu_load_weight(uint32_t wtrans, uint32_t reg_idx,
                                             uint32_t bound, uint32_t stride,
                                             uint32_t tmem_base) {
  uint64_t w = 0;
  w |= (uint64_t(wtrans & 1u) << 61);
  w |= (uint64_t(reg_idx & 1u) << 60);
  w |= (uint64_t(bound & 0xFFFFu) << 44);
  w |= (uint64_t(stride & 0xFFFFu) << 28);
  w |= (uint64_t(tmem_base & 0xFFFFFFu) << 4);
  w |= RAW_OP_MXU_LOAD_WEIGHT;
  return w;
}

// MXU_LOAD_QPARAM: 2-word instruction
static void send_mxu_qparam(uint32_t mxu_base, uint32_t tmem_base,
                             uint32_t tmem_stride, uint32_t mxu_stride,
                             uint32_t bound) {
  uint64_t w0 = 0;
  w0 |= (uint64_t(mxu_base & 0xFFFFFFu) << 28);
  w0 |= (uint64_t(tmem_base & 0xFFFFFFu) << 4);
  w0 |= RAW_OP_MXU_LOAD_QPARAM;
  stream_send(w0);

  uint64_t w1 = 0;
  w1 |= (uint64_t(tmem_stride & 0xFFFFu) << 32);
  w1 |= (uint64_t(mxu_stride & 0xFFFFu) << 16);
  w1 |= (bound & 0xFFFFu);
  stream_send(w1);
}

// MXU_LOAD_INPUT: 2-word instruction (triggers GEMM compute)
static void send_mxu_input(uint32_t is_accum, uint32_t is_last,
                            uint32_t wreg_idx, uint32_t sreg_idx, uint32_t zreg_idx,
                            uint32_t qdir, uint32_t tmem_base, uint32_t acc_mem_base,
                            uint32_t acc_cnt, uint32_t stride, uint32_t bound) {
  uint64_t w0 = 0;
  w0 |= (uint64_t(is_accum & 1u) << 57);
  w0 |= (uint64_t(is_last & 1u) << 56);
  w0 |= (uint64_t(wreg_idx & 1u) << 55);
  w0 |= (uint64_t(sreg_idx & 1u) << 54);
  w0 |= (uint64_t(zreg_idx & 1u) << 53);
  w0 |= (uint64_t(qdir & 1u) << 52);
  w0 |= (uint64_t(tmem_base & 0xFFFFFFu) << 28);
  w0 |= (uint64_t(acc_mem_base & 0xFFFFFFu) << 4);
  w0 |= RAW_OP_MXU_LOAD_INPUT;
  stream_send(w0);

  uint64_t w1 = 0;
  w1 |= (uint64_t(acc_cnt) << 32);
  w1 |= (uint64_t(stride & 0xFFFFu) << 16);
  w1 |= (bound & 0xFFFFu);
  stream_send(w1);
}

// MXU_STORE_OUTPUT: 2-word instruction
static void send_mxu_store_output(uint32_t tmem_base, uint32_t acc_mem_base,
                                   uint32_t stride, uint32_t bound) {
  uint64_t w0 = 0;
  w0 |= (uint64_t(tmem_base & 0xFFFFFFu) << 28);
  w0 |= (uint64_t(acc_mem_base & 0xFFFFFFu) << 4);
  w0 |= RAW_OP_MXU_STORE_OUTPUT;
  stream_send(w0);

  uint64_t w1 = 0;
  w1 |= (uint64_t(stride & 0xFFFFu) << 16);
  w1 |= (bound & 0xFFFFu);
  stream_send(w1);
}

// ============================================================================
// Tile constants
// ============================================================================
static constexpr uint32_t DMA_MT     = GEMM_FSM_MT;      // 128
static constexpr uint32_t DMA_KT     = GEMM_FSM_KT;      // 128
static constexpr uint32_t DMA_MXU_KT = GEMM_FSM_MXU_KT;  // 32
static constexpr uint32_t DMA_MXU_NT = GEMM_FSM_MXU_NT;   // 32

// ============================================================================
// Tiled GEMM instruction stream (mirrors tb_VX_gemm_node_improve logic)
// ============================================================================
static void run_tiled_gemm(const kernel_arg_t* arg) {
  const uint32_t M     = arg->M;
  const uint32_t N     = arg->N;
  const uint32_t K     = arg->K;
  const uint32_t qblk  = arg->QBLK;
  const uint32_t wtrans = arg->WTRANS;
  const uint32_t qdir  = arg->QDIR;

  const uint32_t m_tiles    = (M + DMA_MT - 1u) / DMA_MT;
  const uint32_t n_tiles    = N / DMA_MXU_NT;
  const uint32_t k_tiles    = K / DMA_KT;
  const uint32_t kb_per_kt  = DMA_KT / DMA_MXU_KT;
  const uint32_t groups_per_kt = DMA_KT / qblk;
  const uint32_t ng_per_nt  = (DMA_MXU_NT + qblk - 1u) / qblk;

  // Bytes per k-tile chunk
  const uint32_t weight_kt_bytes = DMA_KT * (DMA_MXU_NT / 2u);
  uint32_t scale_kt_bytes, zp_kt_bytes, qparam_kb_offset;
  if (qdir == 0) {
    scale_kt_bytes   = groups_per_kt * DMA_MXU_NT * 2u;
    zp_kt_bytes      = groups_per_kt * DMA_MXU_NT * 2u;
    qparam_kb_offset = 0;
  } else {
    scale_kt_bytes   = DMA_KT * ng_per_nt * 2u;
    zp_kt_bytes      = DMA_KT * ng_per_nt * 2u;
    qparam_kb_offset = DMA_MXU_KT * ng_per_nt * 2u;
  }

  const uint32_t qparam_src_stride = uint32_t(arg->lmem_zpbuf0 - arg->lmem_scbuf0);
  const uint32_t qparam_dst_stride = DMA_MXU_NT * 4u;

  // Truncate LMEM addresses to 24-bit local offsets
  const uint32_t lmem_ibuf0  = uint32_t(arg->lmem_ibuf0  & 0xFFFFFFu);
  const uint32_t lmem_wbuf0  = uint32_t(arg->lmem_wbuf0  & 0xFFFFFFu);
  const uint32_t lmem_scbuf0 = uint32_t(arg->lmem_scbuf0 & 0xFFFFFFu);
  const uint32_t lmem_obuf   = uint32_t(arg->lmem_obuf   & 0xFFFFFFu);

  const uint32_t w_seg_bytes = DMA_MXU_KT * (DMA_MXU_NT / 2u);

  // Cumulative counters for sync registers (never reset, always ADD).
  // This avoids a race where WAIT checks a stale register value before
  // the SET-mode NOTIFY (queued behind a slow DMA) has fired.
  uint32_t cum_ld0 = 0;
  uint32_t cum_w0  = 0;
  uint32_t cum_sz0 = 0;
  uint32_t cum_g0  = 0;
  uint32_t cum_o0  = 0;
  uint32_t cum_st  = 0;

  for (uint32_t mt = 0; mt < m_tiles; mt++) {
    const uint32_t cur_m = ((M - mt * DMA_MT) < DMA_MT) ? (M - mt * DMA_MT) : DMA_MT;
    const uint32_t cur_input_kt_bytes   = cur_m * DMA_KT * 2u;
    const uint32_t cur_output_tile_bytes = cur_m * DMA_MXU_NT * 2u;

    for (uint32_t nt = 0; nt < n_tiles; nt++) {
      const uint64_t dram_out_tile = arg->dram_out_base
        + uint64_t(mt) * uint64_t(n_tiles) * uint64_t(DMA_MT * DMA_MXU_NT * 2u)
        + uint64_t(nt) * uint64_t(cur_output_tile_bytes);

      // ---- K-tile loop ----
      for (uint32_t kt = 0; kt < k_tiles; kt++) {
        const uint64_t dram_in_tile = arg->dram_in_base
          + uint64_t(mt) * uint64_t(DMA_MT * K * 2u)
          + uint64_t(kt) * uint64_t(cur_input_kt_bytes);
        const uint64_t dram_w_tile = arg->dram_w_base
          + uint64_t(kt) * uint64_t(n_tiles * weight_kt_bytes)
          + uint64_t(nt) * uint64_t(weight_kt_bytes);
        const uint64_t dram_sc_tile = arg->dram_sc_base
          + uint64_t(kt) * uint64_t(n_tiles * scale_kt_bytes)
          + uint64_t(nt) * uint64_t(scale_kt_bytes);
        const uint64_t dram_zp_tile = arg->dram_zp_base
          + uint64_t(kt) * uint64_t(n_tiles * zp_kt_bytes)
          + uint64_t(nt) * uint64_t(zp_kt_bytes);

        // DMA LOAD: input, weight, scale, zp → LMEM
        // Use ADD-mode only (no SET) to avoid race with stale register values.
        send_dma_cmd(RAW_OP_DMA_LOAD, lmem_ibuf0, dram_in_tile,
                     0, 0, 1, cur_input_kt_bytes);
        stream_send(make_notify(0, 1, RID_LD0));

        send_dma_cmd(RAW_OP_DMA_LOAD, lmem_wbuf0, dram_w_tile,
                     0, 0, 1, weight_kt_bytes);
        stream_send(make_notify(0, 1, RID_LD0));

        send_dma_cmd(RAW_OP_DMA_LOAD, lmem_scbuf0, dram_sc_tile,
                     0, 0, 1, scale_kt_bytes);
        stream_send(make_notify(0, 1, RID_LD0));

        send_dma_cmd(RAW_OP_DMA_LOAD,
                     uint32_t(arg->lmem_zpbuf0 & 0xFFFFFFu),
                     dram_zp_tile, 0, 0, 1, zp_kt_bytes);
        stream_send(make_notify(0, 1, RID_LD0));

        cum_ld0 += 4;
        stream_send(make_wait(cum_ld0, RID_LD0));

        // ---- K-block loop within k-tile ----
        for (uint32_t kb = 0; kb < kb_per_kt; kb++) {
          const bool is_first_kb = (kt == 0 && kb == 0);
          const bool is_last_kb  = (kt == k_tiles - 1u && kb == kb_per_kt - 1u);

          // MXU weight load
          const uint32_t w_lmem = lmem_wbuf0 + kb * w_seg_bytes;
          stream_send(make_mxu_load_weight(wtrans, 0, 1, 0, w_lmem));
          ++cum_w0;
          stream_send(make_notify(0, 1, RID_W0));

          // MXU qparam load
          if (qdir == 0) {
            if (kb == 0) {
              send_mxu_qparam(0, lmem_scbuf0,
                              qparam_src_stride, qparam_dst_stride, 2);
              ++cum_sz0;
              stream_send(make_notify(0, 1, RID_SZ0));
            }
          } else {
            const uint32_t sc_off = lmem_scbuf0 + kb * qparam_kb_offset;
            send_mxu_qparam(0, sc_off,
                            qparam_src_stride, qparam_dst_stride, 2);
            ++cum_sz0;
            stream_send(make_notify(0, 1, RID_SZ0));
          }

          // Wait weight (+ qparam)
          stream_send(make_wait(cum_w0, RID_W0));
          if (qdir == 0) {
            if (kb == 0)
              stream_send(make_wait(cum_sz0, RID_SZ0));
          } else {
            stream_send(make_wait(cum_sz0, RID_SZ0));
          }

          // MXU input load + GEMM compute
          const uint32_t i_src = lmem_ibuf0 + kb * cur_m * DMA_MXU_KT * 2u;
          send_mxu_input(
            is_first_kb ? 0u : 1u,   // is_accum
            is_last_kb  ? 1u : 0u,   // is_last
            0, 0, 0, qdir,
            i_src, 0,
            cur_m,
            DMA_MXU_KT * 2u,         // stride (bytes per input row)
            cur_m                      // bound (number of rows)
          );
          ++cum_g0;
          stream_send(make_notify(0, 1, RID_G0));
          stream_send(make_wait(cum_g0, RID_G0));
        }
      }

      // ---- MXU store output → LMEM ----
      send_mxu_store_output(lmem_obuf, 0, 0, cur_m);
      ++cum_o0;
      stream_send(make_notify(0, 1, RID_O0));
      stream_send(make_wait(cum_o0, RID_O0));

      // ---- DMA store output LMEM → DRAM ----
      send_dma_cmd(RAW_OP_DMA_STORE, lmem_obuf, dram_out_tile,
                   0, 0, 1, cur_output_tile_bytes);
      ++cum_st;
      stream_send(make_notify(0, 1, RID_ST));
      stream_send(make_wait(cum_st, RID_ST));

    }
  }

  // Mark stream complete
  stream_send(make_clear());
}

// ============================================================================
// Entry point: only core 0, warp 0, thread 0
// ============================================================================
int main() {
  if (vx_warp_id() != 0 || vx_thread_id() != 0)
    return 0;

  auto arg = reinterpret_cast<kernel_arg_t*>(csr_read(VX_CSR_MSCRATCH));

  // Allocate instruction stream (MMIO read at base+0)
  uint32_t r = mmio_read32(GEMM_BASE);
  if (!(r & 1u)) {
    arg->status = STATUS_ALLOC_FAIL;
    return 0;
  }

  arg->status = STATUS_INIT;

  // Submit tiled GEMM instruction stream
  run_tiled_gemm(arg);

  arg->status = STATUS_OK;
  return 0;
}
