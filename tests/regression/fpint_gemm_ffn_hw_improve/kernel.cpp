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
static constexpr uint32_t DMA_MT     = GEMM_MT;      // 128
static constexpr uint32_t DMA_NT     = GEMM_NT;      // 128 (DMA N-tile: 128 wide)
static constexpr uint32_t DMA_KT     = GEMM_KT;      // 128
static constexpr uint32_t DMA_MXU_KT = GEMM_MXU_KT;  // 32
static constexpr uint32_t DMA_MXU_NT = GEMM_MXU_NT;  // 32 (MXU micro N-tile)
static constexpr uint32_t NB_PER_NT  = DMA_NT / DMA_MXU_NT;  // 4 N-microtiles per DMA tile
static constexpr uint32_t ACC_DBUF_STRIDE =
  GEMM_ACC_MEM_DEPTH * (4u * 2u * MXU_COL);
// Within one acc DBuf group, 4 disjoint regions hold per-nb partial sums.
static constexpr uint32_t ACC_NB_STRIDE = ACC_DBUF_STRIDE / NB_PER_NT;

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
  // Host passes the real (unpadded) M. Internally pad up to multiple of 8 so
  // DMA byte counts stay aligned to the 8-channel TMEM stripe (8*64B=512B).
  // MXU compute bound stays at the real M; padded rows are skipped.
  const uint32_t M_real = arg->M;
  const uint32_t M      = (M_real + 7u) & ~7u;
  const uint32_t N      = arg->N;
  const uint32_t K      = arg->K;
  const uint32_t qblk   = arg->QBLK;
  const uint32_t wtrans = arg->WTRANS;
  const uint32_t qdir   = arg->QDIR;

  const uint32_t m_tiles    = (M + DMA_MT - 1u) / DMA_MT;
  const uint32_t n_tiles    = (N + DMA_NT - 1u) / DMA_NT;   // ceil: last tile may be partial
  const uint32_t k_tiles    = (K + DMA_KT - 1u) / DMA_KT;
  const uint32_t tile_total = m_tiles * n_tiles * k_tiles;

  // N-groups per MXU micro-tile (32-wide); used for QROW qparam addressing.
  const uint32_t ng_per_nt  = (DMA_MXU_NT + qblk - 1u) / qblk;

  // Weight stride: N directly (weight tile bytes are naturally 512-aligned for
  // supported configs).
  const uint64_t kt_w_stride = uint64_t(DMA_KT) * uint64_t(N) / 2u;
  const uint32_t qparam_kb_offset = (qdir == 0) ? 0u
                                                 : (DMA_MXU_KT * ng_per_nt * 2u);

  // Scale/zp slot-based DRAM layout. Each (kt, nt_dma) reserves
  // align_up(actual_bytes, 512) bytes; this keeps the DMA src/dst channel-slot
  // invariant (bits [8:6] match) while minimising padding. Slot size varies
  // with (ck, cn), but since partial-K only exists at kt == k_tiles-1 and
  // partial-N only at nt == n_tiles-1, the offset reduces to O(1):
  //   kt_off = kt_idx * per_kt_full_K     (all prior kt rows are full-K)
  //   nt_off = nt_dma_idx * slot_full_N   (all prior nt within kt are full-N)
  const uint32_t ck_last = ((K - (k_tiles - 1u) * DMA_KT) < DMA_KT)
                             ? (K - (k_tiles - 1u) * DMA_KT) : DMA_KT;
  const uint32_t cn_last = ((N - (n_tiles - 1u) * DMA_NT) < DMA_NT)
                             ? (N - (n_tiles - 1u) * DMA_NT) : DMA_NT;

  auto sc_slot_bytes = [&](uint32_t _ck, uint32_t _cn) -> uint64_t {
    uint64_t actual = (qdir == 0)
                        ? (uint64_t(_ck / qblk) * _cn * 2u)
                        : (uint64_t(_cn / DMA_MXU_NT) * _ck * ng_per_nt * 2u);
    return (actual + 511u) & ~uint64_t(511u);
  };

  const uint64_t slot_fk_fn = sc_slot_bytes(DMA_KT, DMA_NT);
  const uint64_t slot_fk_pn = sc_slot_bytes(DMA_KT, cn_last);
  const uint64_t slot_pk_fn = sc_slot_bytes(ck_last, DMA_NT);

  // Per full-K-tile row total (n_tiles slots: n_tiles-1 full-N + possibly one
  // partial-N at the end).
  const uint64_t per_kt_full_K = uint64_t(n_tiles - 1u) * slot_fk_fn + slot_fk_pn;

  auto sc_dram_offset = [&](uint32_t kt_idx, uint32_t nt_dma_idx) -> uint64_t {
    const bool is_last_kt = (kt_idx == k_tiles - 1u);
    const uint64_t kt_off = uint64_t(kt_idx) * per_kt_full_K;
    const uint64_t slot_full_N = is_last_kt ? slot_pk_fn : slot_fk_fn;
    return kt_off + uint64_t(nt_dma_idx) * slot_full_N;
  };

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

  // qparam_src_stride must be same for both buffers. Current TMEM layout places
  // scbuf[0], scbuf[1], zpbuf[0], zpbuf[1] consecutively (with equal scbuf/zpbuf
  // sizes), so zpbuf[i] - scbuf[i] is the same for i=0,1.
  const uint32_t qparam_src_stride = uint32_t(arg->lmem_zpbuf[0] - arg->lmem_scbuf[0]);
  const uint32_t qparam_dst_stride = DMA_MXU_NT * 4u;

  // Per-physical-buffer monotonic sync targets (SET-mode safe because targets
  // strictly increase per buffer, so stale register < new target).
  uint32_t tile_target[2]        = {0, 0};
  uint32_t w_target[2]           = {0, 0};
  uint32_t sz_target[2]          = {0, 0};
  uint32_t g_target[2]           = {0, 0};
  uint32_t o_target[2]           = {0, 0};
  uint32_t acc_reuse_target[2]   = {0, 0};
  uint32_t store_reuse_target[2] = {0, 0};
  uint32_t store_done_target     = 0;

  // ---- Helper: issue 4 DMA loads for one DMA tile into buffer b ----
  // Host DRAM layout is tiled by 32-wide N micro-tiles (nt_32). Up to NB_PER_NT
  // consecutive nt_32 slices for a given (mt, kt) are contiguous in DRAM, so a
  // single DMA LOAD per category fetches the current (possibly partial) 128-wide
  // tile for (mt, nt_dma, kt).
  auto dma_preload_tile = [&](uint32_t b, uint32_t _mt, uint32_t _nt_dma, uint32_t _kt) {
    const uint32_t cm = ((M - _mt * DMA_MT) < DMA_MT) ? (M - _mt * DMA_MT) : DMA_MT;
    const uint32_t ck = ((K - _kt * DMA_KT) < DMA_KT) ? (K - _kt * DMA_KT) : DMA_KT;
    const uint32_t cn = ((N - _nt_dma * DMA_NT) < DMA_NT) ? (N - _nt_dma * DMA_NT) : DMA_NT;
    const uint32_t cur_nb_per_nt = cn / DMA_MXU_NT;
    const uint32_t in_bytes = cm * ck * 2u;

    // Current tile byte sizes (may be smaller for the last K- or N-tile)
    const uint32_t cur_weight_kt_bytes = ck * (cn / 2u);
    uint32_t cur_scale_kt_bytes, cur_zp_kt_bytes;
    if (qdir == 0) {
      cur_scale_kt_bytes = (ck / qblk) * cn * 2u;
      cur_zp_kt_bytes    = (ck / qblk) * cn * 2u;
    } else {
      cur_scale_kt_bytes = ck * ng_per_nt * 2u * cur_nb_per_nt;
      cur_zp_kt_bytes    = ck * ng_per_nt * 2u * cur_nb_per_nt;
    }

    // DRAM offsets: kt stride uses full-K-tile sizes; nt_dma stride uses the
    // full 128-wide step (prior nt_dma's are always full-width).
    const uint64_t d_in = arg->dram_in_base
      + uint64_t(_mt) * uint64_t(DMA_MT * K * 2u)
      + uint64_t(_kt) * uint64_t(cm * DMA_KT * 2u);

    const uint64_t nt_dma_w_off = uint64_t(_nt_dma) * uint64_t(ck) * uint64_t(DMA_NT) / 2u;

    const uint64_t d_w  = arg->dram_w_base  + uint64_t(_kt) * kt_w_stride  + nt_dma_w_off;
    const uint64_t sc_off = sc_dram_offset(_kt, _nt_dma);
    const uint64_t d_sc = arg->dram_sc_base + sc_off;
    const uint64_t d_zp = arg->dram_zp_base + sc_off;

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
  // Tile DMA unit : 128 x 128 (mt, nt_dma, kt)
  // MXU unit     : 128 x 32  (nb within tile, kb within kt)
  uint32_t tile_idx = 0;
  for (uint32_t mt = 0; mt < m_tiles; mt++) {
    const uint32_t cur_m = ((M - mt * DMA_MT) < DMA_MT) ? (M - mt * DMA_MT) : DMA_MT;
    // Real-M-bounded compute size for this tile. Used only as MXU bound so
    // padded rows never enter the accumulator or the output store.
    const uint32_t mt_off = mt * DMA_MT;
    const uint32_t cur_m_compute =
        (mt_off >= M_real) ? 0u
        : (((M_real - mt_off) < DMA_MT) ? (M_real - mt_off) : DMA_MT);
    const uint32_t per_nb_output_bytes = cur_m * DMA_MXU_NT * 2u;   // one 32-wide sub-output

    for (uint32_t nt_dma = 0; nt_dma < n_tiles; nt_dma++) {
      const uint32_t cur_n = ((N - nt_dma * DMA_NT) < DMA_NT) ? (N - nt_dma * DMA_NT) : DMA_NT;
      const uint32_t cur_nb_per_nt = cur_n / DMA_MXU_NT;

      const uint32_t output_tile_idx = nt_dma + n_tiles * mt;
      const uint32_t output_buf = output_tile_idx & 1;
      const uint32_t acc_group = output_tile_idx & 1;
      const uint32_t acc_group_base = acc_group ? ACC_DBUF_STRIDE : 0u;

      // Per-mt DRAM base for output (mt stride uses full DMA_MT × N).
      const uint64_t dram_out_mt_base = arg->dram_out_base
        + uint64_t(mt) * uint64_t(DMA_MT) * uint64_t(N) * 2u;

      // Reuse acc banks (all NB_PER_NT regions within the group) only after the
      // previous MXU_STORE_OUTPUTs on this acc group have completed.
      stream_send(make_wait(acc_reuse_target[acc_group], rid_output(acc_group)));

      for (uint32_t kt = 0; kt < k_tiles; kt++, tile_idx++) {
        const uint32_t tile_buf = tile_idx & 1;
        const uint32_t cur_k = ((K - kt * DMA_KT) < DMA_KT) ? (K - kt * DMA_KT) : DMA_KT;
        const uint32_t cur_kb_per_kt = cur_k / DMA_MXU_KT;

        // Per-tile TMEM strides between 32-wide nb slices within the 128-wide tile.
        const uint32_t weight_nb_stride = cur_k * (DMA_MXU_NT / 2u);
        const uint32_t scale_nb_stride  = (qdir == 0)
                                          ? ((cur_k / qblk) * DMA_MXU_NT * 2u)
                                          : (cur_k * ng_per_nt * 2u);

        // ---- Preload NEXT tile into opposite buffer (overlap with compute) ----
        uint32_t nmt, nnt_dma, nkt;
        next_tile_coords(mt, nt_dma, kt, nmt, nnt_dma, nkt);
        const uint32_t next_tile_idx = tile_idx + 1;
        if (next_tile_idx < tile_total) {
          dma_preload_tile(tile_buf ^ 1, nmt, nnt_dma, nkt);
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

        // Initial preload into mxu_buf=0: microtile (nb=0, kb=0)
        w_target[0] += 1;
        stream_send(make_mxu_load_weight(wtrans, 0, 1, 0, wbuf[tile_buf]));
        stream_send(make_notify(1, w_target[0], rid_weight(0)));

        sz_target[0] += 1;
        // Split qparam load into two bound=1 commands: scale first, zp second.
        send_mxu_qparam(QPARAM_MXU_BASE[0], scbuf[tile_buf],
                        0, 0, 1);
        send_mxu_qparam(QPARAM_MXU_BASE[0] + qparam_dst_stride, zpbuf[tile_buf],
                        0, 0, 1);
        stream_send(make_notify(1, sz_target[0], rid_scale(0)));

        // Flatten (nb, kb) into one stream of microtiles so MXU DBuf alternates
        // cleanly across the nb boundary. Loop bounded by current tile's cur_nb.
        for (uint32_t nb = 0; nb < cur_nb_per_nt; nb++) {
          for (uint32_t kb = 0; kb < cur_kb_per_kt; kb++) {
            const bool is_first_k = (kt == 0 && kb == 0);
            const bool is_last_k  = (kt == k_tiles - 1u && kb == cur_kb_per_kt - 1u);

            // ---- Preload NEXT microtile (within this kt) into opposite MXU buf ----
            uint32_t next_nb = 0, next_kb = 0;
            bool has_next_within_kt = false;
            if (kb + 1 < cur_kb_per_kt) {
              next_nb = nb; next_kb = kb + 1; has_next_within_kt = true;
            } else if (nb + 1 < cur_nb_per_nt) {
              next_nb = nb + 1; next_kb = 0; has_next_within_kt = true;
            }

            if (has_next_within_kt) {
              const uint32_t nmxu_buf = mxu_buf ^ 1;
              const uint32_t next_w_lmem = wbuf[tile_buf]
                                         + next_nb * weight_nb_stride
                                         + next_kb * w_seg_bytes;

              w_target[nmxu_buf] += 1;
              stream_send(make_mxu_load_weight(wtrans, nmxu_buf, 1, 0, next_w_lmem));
              stream_send(make_notify(1, w_target[nmxu_buf], rid_weight(nmxu_buf)));

              sz_target[nmxu_buf] += 1;
              uint32_t next_sc_lmem;
              if (qdir == 0) {
                // QCOL: qparam shared across kb, differs per nb
                next_sc_lmem = scbuf[tile_buf] + next_nb * scale_nb_stride;
              } else {
                // QROW: qparam differs per (nb, kb)
                next_sc_lmem = scbuf[tile_buf]
                             + next_nb * scale_nb_stride
                             + next_kb * qparam_kb_offset;
              }
              const uint32_t next_zp_lmem = next_sc_lmem + qparam_src_stride;
              // Split qparam load into two bound=1 commands: scale first, zp second.
              send_mxu_qparam(QPARAM_MXU_BASE[nmxu_buf], next_sc_lmem,
                              0, 0, 1);
              send_mxu_qparam(QPARAM_MXU_BASE[nmxu_buf] + qparam_dst_stride,
                              next_zp_lmem, 0, 0, 1);
              stream_send(make_notify(1, sz_target[nmxu_buf], rid_scale(nmxu_buf)));
            }

            // ---- Wait for current microtile weight & qparam ----
            stream_send(make_wait(w_target[mxu_buf], rid_weight(mxu_buf)));
            stream_send(make_wait(sz_target[mxu_buf], rid_scale(mxu_buf)));

            // ---- GEMM compute (each nb accumulates into its own acc region) ----
            const uint32_t acc_mem_base_nb = acc_group_base + nb * ACC_NB_STRIDE;
            // i_src offset uses the padded cur_m because that's how the input
            // buffer is laid out (DMA loaded cur_m rows per kb chunk).
            const uint32_t i_src = ibuf[tile_buf] + kb * cur_m * DMA_MXU_KT * 2u;
            send_mxu_input(
              is_first_k ? 0u : 1u,   // is_accum (false only for first k-block)
              is_last_k  ? 1u : 0u,   // is_last  (true  only for last  k-block)
              mxu_buf, mxu_buf, mxu_buf, qdir,
              i_src, acc_mem_base_nb,
              cur_m_compute,           // acc_cnt: only real rows accumulate
              DMA_MXU_KT * 2u,
              cur_m_compute            // bound:  MXU iterates real rows only
            );
            g_target[mxu_buf] += 1;
            stream_send(make_notify(1, g_target[mxu_buf], rid_gemm(mxu_buf)));
            stream_send(make_wait(g_target[mxu_buf], rid_gemm(mxu_buf)));

            // ---- Output store (only on last k-block) ----
            // Per-nb pattern: each nb does its own MXU_STORE → DMA_STORE pair
            // (32-wide × cur_m). Cumulative across nb's = cur_n × cur_m.
            if (is_last_k) {
              // obuf reuse wait: once per (mt, nt_dma), before the first nb store
              if (nb == 0) {
                stream_send(make_wait(store_reuse_target[output_buf], RID_ST));
              }

              // MXU_STORE: acc[nb] → obuf at nb-specific offset.
              // obuf slot stride uses padded cur_m (matches output DMA layout);
              // store bound is real cur_m_compute so padded rows in obuf retain
              // stale data, which is fine because the host discards them.
              const uint32_t obuf_nb = obuf[output_buf] + nb * per_nb_output_bytes;
              const uint32_t acc_store_base_nb = acc_mem_base_nb >> 1;
              send_mxu_store_output(obuf_nb, acc_store_base_nb, 0, cur_m_compute);
              o_target[output_buf] += 1;
              stream_send(make_notify(1, o_target[output_buf], rid_output(output_buf)));

              // Wait MXU_STORE done before DMA_STORE reads obuf
              stream_send(make_wait(o_target[output_buf], rid_output(output_buf)));

              // DMA_STORE: obuf[nb slice] → DRAM[absolute nt_32 = nt_dma*4+nb]
              const uint64_t dram_out_nb = dram_out_mt_base
                + uint64_t(nt_dma * NB_PER_NT + nb) * uint64_t(cur_m)
                                                   * uint64_t(DMA_MXU_NT) * 2u;
              store_done_target += 1;
              send_dma_cmd(RAW_OP_DMA_STORE, obuf_nb, dram_out_nb,
                           0, 0, 1, per_nb_output_bytes);
              stream_send(make_notify(1, store_done_target, RID_ST));
            }

            mxu_buf ^= 1;
          }
        }
      }

      // ---- End of (mt, nt_dma) ----
      // Per-nb MXU_STORE+DMA_STORE pairs were already issued inside the inner
      // loop. Just snapshot the latest sync targets so the next iteration on
      // the same acc_group / output_buf can reuse them safely.
      acc_reuse_target[acc_group]    = o_target[output_buf];
      store_reuse_target[output_buf] = store_done_target;
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
  if (vx_warp_id() != 0) {                                                                                                                                                                              
    vx_tmc_zero();                                                                                                                                                                                      
  }                                                                                                                                                                                                     
                                                                                                                                                                                                          
  vx_tmc_one();

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
