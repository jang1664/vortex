#include "common.h"
#include <vx_intrinsics.h>

// MMIO addresses for GEMM instruction stream frontend
static constexpr uint64_t GEMM_BASE        = 0x0000000000001080ULL;
static constexpr uint64_t GEMM_STREAM_ADDR = GEMM_BASE + 8ULL;
static constexpr uint64_t GEMM_STATE_ADDR  = GEMM_BASE + 16ULL;

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
// RID helpers for double-buffered sync registers
// ============================================================================
static inline uint32_t rid_tile(uint32_t b)   { return b ? RID_LD1 : RID_LD0; }
static inline uint32_t rid_weight(uint32_t b) { return b ? RID_W1  : RID_W0;  }
static inline uint32_t rid_scale(uint32_t b)  { return b ? RID_SZ1 : RID_SZ0; }
static inline uint32_t rid_gemm(uint32_t b)   { return b ? RID_G1  : RID_G0;  }
static inline uint32_t rid_output(uint32_t b) { return b ? RID_O1  : RID_O0;  }

// ============================================================================
// Tiled GEMM with 3-level double buffering (DMA tile / MXU microtile / output)
// Follows fi_gemm.c pattern with per-buffer monotonic SET-mode targets.
// ============================================================================
static void run_tiled_gemm(const kernel_arg_t* arg) {
  const uint32_t M      = arg->M;
  const uint32_t N      = arg->N;
  const uint32_t K      = arg->K;
  const uint32_t qblk   = arg->QBLK;
  const uint32_t wtrans = arg->WTRANS;
  const uint32_t qdir   = arg->QDIR;

  const uint32_t m_tiles    = (M + DMA_MT - 1u) / DMA_MT;
  const uint32_t n_tiles    = N / DMA_MXU_NT;
  const uint32_t k_tiles    = (K + DMA_KT - 1u) / DMA_KT;
  const uint32_t tile_total = m_tiles * n_tiles * k_tiles;

  const uint32_t ng_per_nt     = (DMA_MXU_NT + qblk - 1u) / qblk;

  // Full-tile byte sizes (used for DRAM stride between K-tiles)
  const uint32_t full_weight_kt_bytes = DMA_KT * (DMA_MXU_NT / 2u);
  uint32_t full_scale_kt_bytes, full_zp_kt_bytes, qparam_kb_offset;
  if (qdir == 0) {
    uint32_t full_groups_per_kt = DMA_KT / qblk;
    full_scale_kt_bytes = full_groups_per_kt * DMA_MXU_NT * 2u;
    full_zp_kt_bytes    = full_groups_per_kt * DMA_MXU_NT * 2u;
    qparam_kb_offset    = 0;
  } else {
    full_scale_kt_bytes = DMA_KT * ng_per_nt * 2u;
    full_zp_kt_bytes    = DMA_KT * ng_per_nt * 2u;
    qparam_kb_offset    = DMA_MXU_KT * ng_per_nt * 2u;
  }

  const uint32_t w_seg_bytes = DMA_MXU_KT * (DMA_MXU_NT / 2u);

  // Double-buffered LMEM addresses (24-bit local offsets)
  const uint32_t ibuf[2]  = { uint32_t(arg->lmem_ibuf[0]  & 0xFFFFFFu),
                               uint32_t(arg->lmem_ibuf[1]  & 0xFFFFFFu) };
  const uint32_t wbuf[2]  = { uint32_t(arg->lmem_wbuf[0]  & 0xFFFFFFu),
                               uint32_t(arg->lmem_wbuf[1]  & 0xFFFFFFu) };
  const uint32_t scbuf[2] = { uint32_t(arg->lmem_scbuf[0] & 0xFFFFFFu),
                               uint32_t(arg->lmem_scbuf[1] & 0xFFFFFFu) };
  const uint32_t zpbuf[2] = { uint32_t(arg->lmem_zpbuf[0] & 0xFFFFFFu),
                               uint32_t(arg->lmem_zpbuf[1] & 0xFFFFFFu) };
  const uint32_t obuf[2]  = { uint32_t(arg->lmem_obuf[0]  & 0xFFFFFFu),
                               uint32_t(arg->lmem_obuf[1]  & 0xFFFFFFu) };

  // qparam_src_stride must be same for both buffers (ensured by paired LMEM layout)
  const uint32_t qparam_src_stride = uint32_t(arg->lmem_zpbuf[0] - arg->lmem_scbuf[0]);
  const uint32_t qparam_dst_stride = DMA_MXU_NT * 4u;

  // Per-physical-buffer monotonic sync targets (SET-mode safe because targets
  // strictly increase per buffer, so stale register < new target).
  uint32_t tile_target[2]        = {0, 0};
  uint32_t w_target[2]           = {0, 0};
  uint32_t sz_target[2]          = {0, 0};
  uint32_t g_target[2]           = {0, 0};
  uint32_t o_target[2]           = {0, 0};
  uint32_t store_reuse_target[2] = {0, 0};
  uint32_t store_done_target     = 0;

  // ---- Helper: issue 4 DMA loads for a tile into buffer b ----
  auto dma_preload_tile = [&](uint32_t b, uint32_t _mt, uint32_t _nt, uint32_t _kt) {
    const uint32_t cm = ((M - _mt * DMA_MT) < DMA_MT) ? (M - _mt * DMA_MT) : DMA_MT;
    const uint32_t ck = ((K - _kt * DMA_KT) < DMA_KT) ? (K - _kt * DMA_KT) : DMA_KT;
    const uint32_t in_bytes = cm * ck * 2u;

    // Current tile byte sizes (may be smaller for the last K-tile)
    const uint32_t cur_weight_kt_bytes = ck * (DMA_MXU_NT / 2u);
    uint32_t cur_scale_kt_bytes, cur_zp_kt_bytes;
    if (qdir == 0) {
      cur_scale_kt_bytes = (ck / qblk) * DMA_MXU_NT * 2u;
      cur_zp_kt_bytes    = (ck / qblk) * DMA_MXU_NT * 2u;
    } else {
      cur_scale_kt_bytes = ck * ng_per_nt * 2u;
      cur_zp_kt_bytes    = ck * ng_per_nt * 2u;
    }

    // DRAM offsets: kt stride uses full-tile sizes, nt stride uses current-tile sizes
    const uint64_t d_in = arg->dram_in_base
      + uint64_t(_mt) * uint64_t(DMA_MT * K * 2u)
      + uint64_t(_kt) * uint64_t(cm * DMA_KT * 2u);
    const uint64_t d_w = arg->dram_w_base
      + uint64_t(_kt) * uint64_t(n_tiles * full_weight_kt_bytes)
      + uint64_t(_nt) * uint64_t(cur_weight_kt_bytes);
    const uint64_t d_sc = arg->dram_sc_base
      + uint64_t(_kt) * uint64_t(n_tiles * full_scale_kt_bytes)
      + uint64_t(_nt) * uint64_t(cur_scale_kt_bytes);
    const uint64_t d_zp = arg->dram_zp_base
      + uint64_t(_kt) * uint64_t(n_tiles * full_zp_kt_bytes)
      + uint64_t(_nt) * uint64_t(cur_zp_kt_bytes);

    send_dma_cmd(RAW_OP_DMA_LOAD, ibuf[b],  d_in, 0, 0, 1, in_bytes);
    stream_send(make_notify(0, 1, rid_tile(b)));
    send_dma_cmd(RAW_OP_DMA_LOAD, wbuf[b],  d_w,  0, 0, 1, cur_weight_kt_bytes);
    stream_send(make_notify(0, 1, rid_tile(b)));
    send_dma_cmd(RAW_OP_DMA_LOAD, scbuf[b], d_sc, 0, 0, 1, cur_scale_kt_bytes);
    stream_send(make_notify(0, 1, rid_tile(b)));
    send_dma_cmd(RAW_OP_DMA_LOAD, zpbuf[b], d_zp, 0, 0, 1, cur_zp_kt_bytes);
    stream_send(make_notify(0, 1, rid_tile(b)));

    tile_target[b] += 4;
  };

  // ---- Helper: compute next tile indices (kt fastest → nt → mt) ----
  auto next_tile_coords = [&](uint32_t _mt, uint32_t _nt, uint32_t _kt,
                              uint32_t& nmt, uint32_t& nnt, uint32_t& nkt) {
    nkt = (_kt + 1 < k_tiles) ? _kt + 1 : 0;
    nnt = (nkt == 0) ? ((_nt + 1 < n_tiles) ? _nt + 1 : 0) : _nt;
    nmt = (nkt == 0 && nnt == 0) ? _mt + 1 : _mt;
  };

  // ======== Initial preload: tile[0] → buf0 ========
  {
    // First tile: (mt=0, nt=0, kt=0)
    dma_preload_tile(0, 0, 0, 0);
  }

  // ======== Main tile loop ========
  uint32_t tile_idx = 0;
  for (uint32_t mt = 0; mt < m_tiles; mt++) {
    const uint32_t cur_m = ((M - mt * DMA_MT) < DMA_MT) ? (M - mt * DMA_MT) : DMA_MT;
    const uint32_t cur_output_tile_bytes = cur_m * DMA_MXU_NT * 2u;

    for (uint32_t nt = 0; nt < n_tiles; nt++) {
      const uint32_t output_tile_idx = nt + n_tiles * mt;
      const uint32_t output_buf = output_tile_idx & 1;

      const uint64_t dram_out_tile = arg->dram_out_base
        + uint64_t(mt) * uint64_t(n_tiles) * uint64_t(DMA_MT * DMA_MXU_NT * 2u)
        + uint64_t(nt) * uint64_t(cur_output_tile_bytes);

      for (uint32_t kt = 0; kt < k_tiles; kt++, tile_idx++) {
        const uint32_t tile_buf = tile_idx & 1;
        const uint32_t cur_k = ((K - kt * DMA_KT) < DMA_KT) ? (K - kt * DMA_KT) : DMA_KT;
        const uint32_t cur_kb_per_kt = cur_k / DMA_MXU_KT;

        // ---- Preload NEXT tile into opposite buffer (overlap with compute) ----
        uint32_t nmt, nnt, nkt;
        next_tile_coords(mt, nt, kt, nmt, nnt, nkt);
        const uint32_t next_tile_idx = tile_idx + 1;
        if (next_tile_idx < tile_total) {
          dma_preload_tile(tile_buf ^ 1, nmt, nnt, nkt);
        }

        // ---- Wait for current tile DMA to complete ----
        stream_send(make_wait(tile_target[tile_buf], rid_tile(tile_buf)));

        // ---- MXU microtile loop with double buffering (weight + qparam) ----
        // MXU internal qparam register layout:
        //   SCALE_REG0=0x00, SCALE_REG1=0x40, ZP_REG0=0x80, ZP_REG1=0xC0
        //   qparam_dst_stride=0x80 so: mxu_base=0x00 → scale@0x00,zp@0x80
        //                              mxu_base=0x40 → scale@0x40,zp@0xC0
        static constexpr uint32_t QPARAM_MXU_BASE[2] = {0x00, 0x40};

        uint32_t mxu_buf = 0;

        // Initial preload into mxu_buf=0: weight + qparam
        w_target[0] += 1;
        stream_send(make_mxu_load_weight(wtrans, 0, 1, 0, wbuf[tile_buf]));
        stream_send(make_notify(1, w_target[0], rid_weight(0)));

        sz_target[0] += 1;
        if (qdir == 0) {
          send_mxu_qparam(QPARAM_MXU_BASE[0], scbuf[tile_buf],
                          qparam_src_stride, qparam_dst_stride, 2);
        } else {
          send_mxu_qparam(QPARAM_MXU_BASE[0], scbuf[tile_buf],
                          qparam_src_stride, qparam_dst_stride, 2);
        }
        stream_send(make_notify(1, sz_target[0], rid_scale(0)));

        for (uint32_t kb = 0; kb < cur_kb_per_kt; kb++) {
          const bool is_first_kb = (kt == 0 && kb == 0);
          const bool is_last_kb  = (kt == k_tiles - 1u && kb == cur_kb_per_kt - 1u);

          // ---- Preload NEXT microtile into opposite MXU buffer ----
          const uint32_t next_kb = kb + 1;
          if (next_kb < cur_kb_per_kt) {
            const uint32_t nmxu_buf = mxu_buf ^ 1;
            const uint32_t next_w_lmem = wbuf[tile_buf] + next_kb * w_seg_bytes;

            w_target[nmxu_buf] += 1;
            stream_send(make_mxu_load_weight(wtrans, nmxu_buf, 1, 0, next_w_lmem));
            stream_send(make_notify(1, w_target[nmxu_buf], rid_weight(nmxu_buf)));

            sz_target[nmxu_buf] += 1;
            if (qdir == 0) {
              // QCOL: same qparam for all kb, load into opposite reg set
              send_mxu_qparam(QPARAM_MXU_BASE[nmxu_buf], scbuf[tile_buf],
                              qparam_src_stride, qparam_dst_stride, 2);
            } else {
              // QROW: different qparam per kb
              const uint32_t sc_off = scbuf[tile_buf] + next_kb * qparam_kb_offset;
              send_mxu_qparam(QPARAM_MXU_BASE[nmxu_buf], sc_off,
                              qparam_src_stride, qparam_dst_stride, 2);
            }
            stream_send(make_notify(1, sz_target[nmxu_buf], rid_scale(nmxu_buf)));
          }

          // ---- Wait for current microtile weight & qparam ----
          stream_send(make_wait(w_target[mxu_buf], rid_weight(mxu_buf)));
          stream_send(make_wait(sz_target[mxu_buf], rid_scale(mxu_buf)));

          // ---- GEMM compute (wreg, sreg, zreg all use mxu_buf) ----
          const uint32_t i_src = ibuf[tile_buf] + kb * cur_m * DMA_MXU_KT * 2u;
          send_mxu_input(
            is_first_kb ? 0u : 1u,   // is_accum
            is_last_kb  ? 1u : 0u,   // is_last
            mxu_buf, mxu_buf, mxu_buf, qdir,
            i_src, 0,
            cur_m,
            DMA_MXU_KT * 2u,
            cur_m
          );
          g_target[mxu_buf] += 1;
          stream_send(make_notify(1, g_target[mxu_buf], rid_gemm(mxu_buf)));
          stream_send(make_wait(g_target[mxu_buf], rid_gemm(mxu_buf)));

          // ---- Output store (only on last k-block) ----
          if (is_last_kb) {
            stream_send(make_wait(store_reuse_target[output_buf], RID_ST));

            send_mxu_store_output(obuf[output_buf], 0, 0, cur_m);
            o_target[output_buf] += 1;
            stream_send(make_notify(1, o_target[output_buf], rid_output(output_buf)));
          }

          mxu_buf ^= 1;
        }
      }

      // ---- DMA store output LMEM → DRAM ----
      stream_send(make_wait(o_target[output_buf], rid_output(output_buf)));

      store_done_target += 1;
      store_reuse_target[output_buf] = store_done_target;

      send_dma_cmd(RAW_OP_DMA_STORE, obuf[output_buf], dram_out_tile,
                   0, 0, 1, cur_output_tile_bytes);
      stream_send(make_notify(1, store_done_target, RID_ST));
    }
  }

  // Wait for last DMA store to complete
  stream_send(make_wait(store_done_target, RID_ST));

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
  uint32_t alloc_gen = r >> 1;

  arg->status = STATUS_INIT;

  // Submit tiled GEMM instruction stream
  run_tiled_gemm(arg);

  // Poll STATE register until GEMM node completes our work
  while (true) {
    uint32_t state = mmio_read32(GEMM_STATE_ADDR);
    bool occupied = state & 1u;
    uint32_t gen = state >> 1;
    if (!occupied || gen != alloc_gen) break;
  }

  arg->status = STATUS_OK;
  return 0;
}
