// Derived from origin/fpint_naive (ffb5aecb3); namespaced for dual-backend builds.
`include "VX_define.vh"

`ifdef GEMM_NAIVE

// ------------------------------------------------------------
//  - input  : fp16  (2B)
//  - scale  : fp16  (2B)
//  - zp     : int16 (2B)
//  - output : fp16  (2B)
// ------------------------------------------------------------
// ------------------------------------------------------------

module VX_gemm_dma_ctrl_naive import VX_gpu_pkg::*; #(
    parameter `STRING INSTANCE_ID = "",

    parameter logic [63:0] DMA_CFG_BASE_ADDR      = 64'h0,
    parameter int          DMA_CFG_STRIDE_BYTES   = 4,        // 32-bit regs
    parameter int          DMA_ENTRY_STRIDE_BYTES = (`DMA_CFG_REG_NUM * 4),
    parameter int          ENTRYID_W              = `JOB_MMIO_ENTRYID_W,
    parameter int          CTRL_OWNER_W           = `JOB_MMIO_OWNER_W,
    parameter int          CTRL_GEN_W             = `JOB_MMIO_GEN_W,

    parameter int          POLL_GAP_CYCLES        = 1,
    parameter int          ALLOC_RETRY_GAP_CYCLES = 0
) (
    input  wire                   clk,
    input  wire                   reset,

    VX_gemm_dma_ctrl_naive_if.slave       gemm_dma_ctrl_if,
    VX_gemm_sync_if.master          gemm_sync_if,
    VX_lsu_mem_if.master            dma_if,
    output wire                     store_done
);

  // ============================================================
  // Packing parameters
  // ============================================================
  localparam int DMA_NUM_LANES = int'(dma_if.NUM_LANES);
  localparam int DMA_DATA_SIZE = int'(dma_if.DATA_SIZE);
  localparam int DMA_CFG_STRIDE_SHIFT = `CLOG2(DMA_CFG_STRIDE_BYTES);
  localparam int REGS_PER_LANE = DMA_DATA_SIZE >> DMA_CFG_STRIDE_SHIFT;

  // ============================================================
  // Opcodes
  // ============================================================
  localparam logic [7:0] OP_NOTIFY  = 8'hF1;
  localparam logic [7:0] OP_DMA_LD  = 8'h10;
  localparam logic [7:0] OP_DMA_ST  = 8'h11;

  // ============================================================
  // ============================================================
  localparam int DMA_R_CONTROL     = 0;   // 32b
  localparam int DMA_R_DST_BASE_LO = 1;   // 32b
  localparam int DMA_R_DST_BASE_HI = 2;   // 32b
  localparam int DMA_R_SRC_BASE_LO = 3;   // 32b
  localparam int DMA_R_SRC_BASE_HI = 4;   // 32b

  localparam int DMA_R_SRC_ST0     = 5;   // 32b
  localparam int DMA_R_DST_ST0     = 6;   // 32b
  localparam int DMA_R_SRC_ST1     = 7;   // 32b
  localparam int DMA_R_DST_ST1     = 8;   // 32b
  localparam int DMA_R_SRC_ST2     = 9;   // 32b
  localparam int DMA_R_DST_ST2     = 10;  // 32b

  localparam int DMA_R_BND0        = 11;  // 32b
  localparam int DMA_R_BND1        = 12;  // 32b
  localparam int DMA_R_BND2        = 13;  // 32b
  localparam int DMA_R_SEG_SIZE    = 14;  // 32b
  localparam int DMA_R_PAD         = 15;  // 32b
  localparam int DMA_R_DIR         = 16;  // 32b, bit0 = direction (0: G->L, 1: L->G)
  localparam int DMA_R_RSVD        = 17;  // 32b, reserved

  localparam int DMA_R_LAST        = DMA_R_RSVD;

  localparam int DMA_CTRL_START_BIT   = `JOB_MMIO_CTRL_VALID_BIT;
  localparam int DMA_CTRL_OCCUPY_BIT  = `JOB_MMIO_CTRL_OCCUPY_BIT;
  localparam int DMA_CTRL_WORKING_BIT = `JOB_MMIO_CTRL_WORKING_BIT;
  localparam int DMA_CTRL_OWNER_LSB   = `JOB_MMIO_CTRL_OWNER_LSB;
  localparam int DMA_CTRL_GEN_LSB     = `JOB_MMIO_CTRL_GEN_LSB;

  localparam int ALLOC_SUCCESS_BIT = `JOB_MMIO_ALLOC_SUCC_BIT;
  localparam int ALLOC_ENTRY_LSB   = `JOB_MMIO_ALLOC_ENTRY_LSB;
  localparam int ALLOC_ENTRY_BITS  = `JOB_MMIO_ALLOC_ENTRY_BITS;
  localparam int ALLOC_OWNER_LSB   = `JOB_MMIO_ALLOC_OWNER_LSB;
  localparam int ALLOC_OWNER_BITS  = `JOB_MMIO_ALLOC_OWNER_BITS;
  localparam int ALLOC_GEN_LSB     = `JOB_MMIO_ALLOC_GEN_LSB;
  localparam int ALLOC_GEN_BITS    = `JOB_MMIO_ALLOC_GEN_BITS;
  localparam int ALLOC_ENTRY_COPY_BITS = (ALLOC_ENTRY_BITS < ENTRYID_W) ? ALLOC_ENTRY_BITS : ENTRYID_W;
  localparam int ALLOC_OWNER_COPY_BITS = (ALLOC_OWNER_BITS < CTRL_OWNER_W) ? ALLOC_OWNER_BITS : CTRL_OWNER_W;
  localparam int ALLOC_GEN_COPY_BITS   = (ALLOC_GEN_BITS < CTRL_GEN_W) ? ALLOC_GEN_BITS : CTRL_GEN_W;

  // ----------------------------------------------------
  // Parameter sanity checks
  // ----------------------------------------------------
  initial begin
    if ((DMA_DATA_SIZE % DMA_CFG_STRIDE_BYTES) != 0) begin
      $fatal(1, "%s: dma_if.DATA_SIZE(%0d) must be multiple of %0d",
             INSTANCE_ID, DMA_DATA_SIZE, DMA_CFG_STRIDE_BYTES);
    end
    if ((DMA_CFG_STRIDE_BYTES & (DMA_CFG_STRIDE_BYTES - 1)) != 0) begin
      $fatal(1, "%s: DMA_CFG_STRIDE_BYTES(%0d) must be power-of-two for shift-based division",
             INSTANCE_ID, DMA_CFG_STRIDE_BYTES);
    end
    if (REGS_PER_LANE <= 0) begin
      $fatal(1, "%s: REGS_PER_LANE must be >= 1 (DATA_SIZE=%0d)",
             INSTANCE_ID, DMA_DATA_SIZE);
    end
    if (CTRL_OWNER_W <= 0) begin
      $fatal(1, "%s: CTRL_OWNER_W must be >= 1", INSTANCE_ID);
    end
    if (CTRL_GEN_W <= 0) begin
      $fatal(1, "%s: CTRL_GEN_W must be >= 1", INSTANCE_ID);
    end
    if ((DMA_CTRL_GEN_LSB + CTRL_GEN_W) > 32) begin
      $fatal(1, "%s: CONTROL owner/gen field exceeds 32b", INSTANCE_ID);
    end
  end


  // ============================================================
  // ============================================================
  localparam int MT = `GEMM_FSM_MT;
  localparam int NT = `GEMM_FSM_NT;
  localparam int KT = `GEMM_FSM_KT;

  // ============================================================
  // ============================================================
  localparam int GLOBAL_ALLOC_B = DMA_DATA_SIZE;

  function automatic logic [63:0] entry_reg_byte_addr(
      input logic [ENTRYID_W-1:0] entry_id,
      input int                   reg_idx
  );
    return DMA_CFG_BASE_ADDR
         + 64'(GLOBAL_ALLOC_B)
         + 64'(entry_id) * 64'(DMA_ENTRY_STRIDE_BYTES)
         + 64'(reg_idx * DMA_CFG_STRIDE_BYTES);
  endfunction

  localparam int LSU_ADDR_SHIFT = `CLOG2(DMA_DATA_SIZE);

  function automatic logic [dma_if.ADDR_WIDTH-1:0] to_lsu_addr(input logic [63:0] byte_addr);
    logic [63:0] tmp;
    begin
      tmp = (byte_addr >> LSU_ADDR_SHIFT);
      return tmp[dma_if.ADDR_WIDTH-1:0];
    end
  endfunction

  function automatic logic [31:0] min_u32(input logic [31:0] a, input logic [31:0] b);
    return (a < b) ? a : b;
  endfunction

  function automatic logic [31:0] sat_sub_u32(input logic [31:0] a, input logic [31:0] b);
    return (a > b) ? (a - b) : 32'd0;
  endfunction

  // div_log2, ceil_div_log2 and is_pow2_u32 are in VX_gpu_pkg

  // ============================================================
  // ============================================================
  gemm_unified_cmd_t cmd_q;
  wire logic [7:0] cmd_op = cmd_q.instr[7:0];

  logic [31:0] M_orig_q, N_orig_q, K_orig_q, qblk_orig_q;
  logic [31:0] M_orig_d, N_orig_d, K_orig_d, qblk_orig_d;
  logic [31:0] M_target_q, N_target_q, K_target_q;
  logic [31:0] M_target_d, N_target_d, K_target_d;
  logic [31:0] wtrans_tot_q, qdir_tot_q;
  logic [31:0] wtrans_tot_d, qdir_tot_d;
  // ============================================================
  // ============================================================
  logic [63:0] src_base, dst_base;
  logic        dir_is_st;

  always_comb begin
    dir_is_st = (cmd_op == OP_DMA_ST);

    if (cmd_op == OP_DMA_LD) begin
      src_base = cmd_q.rs2_data; // DRAM src
      dst_base = cmd_q.rs1_data; // LMEM dst
    end else if (cmd_op == OP_DMA_ST) begin
      src_base = cmd_q.rs2_data; // LMEM src
      dst_base = cmd_q.rs1_data; // DRAM dst
    end else begin
      src_base = 64'd0;
      dst_base = 64'd0;
    end
  end

  // ============================================================
  // ============================================================
  typedef enum logic [2:0] {T_INPUT, T_WEIGHT, T_OUTPUT, T_SCALE, T_ZP, T_NOTIFY} tensor_t;
  tensor_t tensor_sel;

  always_comb begin
    if (cmd_op == OP_DMA_LD || cmd_op == OP_DMA_ST) begin
      unique case (cmd_q.rd)
        0: tensor_sel = T_INPUT;
        1: tensor_sel = T_WEIGHT;
        2: tensor_sel = T_SCALE;
        3: tensor_sel = T_ZP;
        4: tensor_sel = T_OUTPUT;
        default: tensor_sel = T_INPUT;
      endcase
    end else begin
      tensor_sel = T_NOTIFY;
    end
  end

  // ============================================================
  // ============================================================
  logic [31:0] mt_idx, nt_idx, kt_idx;
  logic [31:0] groups_eff;

  always_comb begin
    mt_idx = 0; nt_idx = 0; kt_idx = 0; groups_eff = 0;
    unique case (tensor_sel)
      T_INPUT:  begin mt_idx = cmd_q.rs1; kt_idx = cmd_q.rs2; end
      T_WEIGHT: begin kt_idx = cmd_q.rs1; nt_idx = cmd_q.rs2; end
      T_OUTPUT: begin mt_idx = cmd_q.rs1; nt_idx = cmd_q.rs2; end
      T_SCALE,
      T_ZP:     begin groups_eff = cmd_q.groups_eff; nt_idx = cmd_q.rs2; end
      default: ;
    endcase
  end

  // ============================================================
  // ============================================================
  logic [31:0] mt_eff, nt_eff, kt_eff;

  always_comb begin
    if (M_target_q == 0) mt_eff = MT;
    else                mt_eff = min_u32(MT, sat_sub_u32(M_target_q, mt_idx * MT));

    if (N_target_q == 0) nt_eff = NT;
    else                nt_eff = min_u32(NT, sat_sub_u32(N_target_q, nt_idx * NT));

    if (K_target_q == 0) kt_eff = KT;
    else                kt_eff = min_u32(KT, sat_sub_u32(K_target_q, kt_idx * KT));

    if (mt_eff == 0) mt_eff = 32'd1;
    if (nt_eff == 0) nt_eff = 32'd1;
    if (kt_eff == 0) kt_eff = 32'd1;
  end

  // ============================================================
  // QROW helpers: NG (number of groups along N dimension)
  // ============================================================
  logic [31:0] ng_tot, ng_tile, ng_eff;

  always_comb begin
    if (qblk_orig_q != 0) begin
      ng_tot  = ceil_div_log2(N_orig_q, qblk_orig_q);
      ng_tile = ceil_div_log2(NT, qblk_orig_q);
      ng_eff  = ceil_div_log2(nt_eff, qblk_orig_q);
    end else begin
      ng_tot  = 32'd1;
      ng_tile = 32'd1;
      ng_eff  = 32'd1;
    end
  end

  // ============================================================
  // ============================================================
  logic [31:0] dram_s0, dram_s1, dram_s2;
  logic [31:0] dram_b0, dram_b1, dram_b2;
  logic [31:0] seg_size;
  logic [31:0] padding;

  localparam int BPE_FP16  = 2;
  localparam int BPE_INT16 = 2;

  always_comb begin
    dram_s0 = 0; dram_s1 = 0; dram_s2 = 0;
    dram_b0 = 1; dram_b1 = 1; dram_b2 = 1;
    seg_size = 0; padding = 0;

    unique case (tensor_sel)
      // INPUT: fp16, shape [M, K]
      T_INPUT: begin
        seg_size = KT * BPE_FP16;
        padding  = (KT - kt_eff) * BPE_FP16;

        dram_s0  = K_orig_q * BPE_FP16;
        dram_b0  = mt_eff;
      end

      T_WEIGHT: begin
        if (wtrans_tot_q[0]) begin
          // wtrans=1: source is [N, K] packed row-major
          seg_size = (KT >> 1);
          padding  = ((KT - kt_eff) >> 1);

          dram_s0  = ((K_orig_q + 32'd1) >> 1);
          dram_b0  = nt_eff;
        end else begin
          // wtrans=0: source is [K, N] packed row-major
          seg_size = (NT >> 1);
          padding  = ((NT - nt_eff) >> 1);

          dram_s0  = ((N_orig_q + 32'd1) >> 1);
          dram_b0  = kt_eff;
        end
      end

      // SCALE: fp16
      T_SCALE: begin
        if (qdir_tot_q[0]) begin
          // QROW: scale layout [K, NG], tile [KT, NG_tile]
          seg_size = ng_tile * BPE_FP16;
          padding  = (ng_tile - ng_eff) * BPE_FP16;
          dram_s0  = ng_tot * BPE_FP16;
          dram_b0  = groups_eff;  // = kt_eff (from FSM rs1)
        end else begin
          // QCOL: scale layout [KG, N], tile [groups_tile, NT]
          seg_size = NT * BPE_FP16;
          padding  = (NT - nt_eff) * BPE_FP16;
          dram_s0  = N_orig_q * BPE_FP16;
          dram_b0  = groups_eff;
        end
      end

      // ZP: int16
      T_ZP: begin
        if (qdir_tot_q[0]) begin
          // QROW: zp layout [K, NG], tile [KT, NG_tile]
          seg_size = ng_tile * BPE_INT16;
          padding  = (ng_tile - ng_eff) * BPE_INT16;
          dram_s0  = ng_tot * BPE_INT16;
          dram_b0  = groups_eff;  // = kt_eff (from FSM rs1)
        end else begin
          // QCOL: zp layout [KG, N], tile [groups_tile, NT]
          seg_size = NT * BPE_INT16;
          padding  = (NT - nt_eff) * BPE_INT16;
          dram_s0  = N_orig_q * BPE_INT16;
          dram_b0  = groups_eff;
        end
      end

      // OUTPUT: fp16, shape [M, N]
      T_OUTPUT: begin
        dram_s0  = N_orig_q * BPE_FP16;
        dram_b0  = mt_eff;

        if (cmd_op == OP_DMA_LD) begin
          // G->L : LMEM row is padded to NT columns, so write full 256B and pad with zeros
          seg_size = NT * BPE_FP16;                 // 256
          padding  = (NT - nt_eff) * BPE_FP16;      // e.g., 2 when nt_eff=127
        end else if (cmd_op == OP_DMA_ST) begin
          // L->G : DO NOT write padding into compact GLOBAL (would overwrite next row)
          seg_size = nt_eff * BPE_FP16;             // e.g., 254
          padding  = 32'd0;
        end
      end

      default: ;
    endcase
  end

  // ============================================================
  // ============================================================
  logic [31:0] lmem_s0, lmem_s1, lmem_s2;

  always_comb begin
    lmem_s0 = 0; lmem_s1 = 0; lmem_s2 = 0;
    unique case (tensor_sel)
      T_INPUT:  lmem_s0 = KT * BPE_FP16;
      T_WEIGHT: lmem_s0 = wtrans_tot_q[0] ? (KT >> 1) : (NT >> 1);
      T_SCALE:  lmem_s0 = qdir_tot_q[0] ? (ng_tile * BPE_FP16)  : (NT * BPE_FP16);
      T_ZP:     lmem_s0 = qdir_tot_q[0] ? (ng_tile * BPE_INT16) : (NT * BPE_INT16);
      T_OUTPUT: lmem_s0 = NT * BPE_FP16;
      default: ;
    endcase
  end

  // ============================================================
  // ============================================================
  logic [31:0] src_s0, src_s1, src_s2;
  logic [31:0] dst_s0, dst_s1, dst_s2;
  logic [31:0] bnd0, bnd1, bnd2;

  always_comb begin
    src_s0 = 0; src_s1 = 0; src_s2 = 0;
    dst_s0 = 0; dst_s1 = 0; dst_s2 = 0;
    bnd0 = 1; bnd1 = 1; bnd2 = 1;

    if (cmd_op == OP_DMA_LD) begin
      src_s0 = dram_s0; src_s1 = dram_s1; src_s2 = dram_s2;
      dst_s0 = lmem_s0; dst_s1 = lmem_s1; dst_s2 = lmem_s2;
      bnd0   = dram_b0; bnd1   = dram_b1; bnd2   = dram_b2;
    end else if (cmd_op == OP_DMA_ST) begin
      src_s0 = lmem_s0; src_s1 = lmem_s1; src_s2 = lmem_s2;
      dst_s0 = dram_s0; dst_s1 = dram_s1; dst_s2 = dram_s2;
      bnd0   = dram_b0; bnd1   = dram_b1; bnd2   = dram_b2;
    end
  end

  // Collapse physically contiguous dimension-0 rows into one segment. The
  // common DMA aligns every segment independently to its bus width, so leaving
  // contiguous short rows split would repeatedly fetch or write the same wide
  // beat. Restrict the transform to descriptors whose source and destination
  // layouts are both provably contiguous and contain no per-row padding.
  wire [63:0] coalesced_seg_size = 64'(seg_size) * 64'(bnd0);
  wire can_coalesce_dim0 = (seg_size != 0)
                         && (padding == 0)
                         && (bnd0 > 1)
                         && (bnd1 == 1)
                         && (bnd2 == 1)
                         && (src_s0 == seg_size)
                         && (dst_s0 == seg_size)
                         && (coalesced_seg_size <= 64'h0000_0000_ffff_ffff);
  wire [31:0] desc_bnd0 = can_coalesce_dim0 ? 32'd1 : bnd0;
  wire [31:0] desc_seg_size = can_coalesce_dim0
                            ? coalesced_seg_size[31:0] : seg_size;

  // ============================================================
  // NOTIFY
  // ============================================================
  wire logic [7:0]  notify_rid   = cmd_q.rs1_data[7:0];
  wire logic [31:0] notify_value = cmd_q.rs2_data[31:0];

  // ============================================================
  // ============================================================
  function automatic logic [31:0] prog_w_data(input int idx);
    logic [31:0] v32;
    begin
      v32 = 32'd0;
      unique case (idx)
        DMA_R_CONTROL:     v32 = 32'd0;
        DMA_R_DST_BASE_LO: v32 = dst_base[31:0];
        DMA_R_DST_BASE_HI: v32 = dst_base[63:32];
        DMA_R_SRC_BASE_LO: v32 = src_base[31:0];
        DMA_R_SRC_BASE_HI: v32 = src_base[63:32];

        DMA_R_SRC_ST0:     v32 = src_s0;
        DMA_R_DST_ST0:     v32 = dst_s0;
        DMA_R_SRC_ST1:     v32 = src_s1;
        DMA_R_DST_ST1:     v32 = dst_s1;
        DMA_R_SRC_ST2:     v32 = src_s2;
        DMA_R_DST_ST2:     v32 = dst_s2;

        DMA_R_BND0:        v32 = desc_bnd0;
        DMA_R_BND1:        v32 = bnd1;
        DMA_R_BND2:        v32 = bnd2;
        DMA_R_SEG_SIZE:    v32 = desc_seg_size;
        DMA_R_PAD:         v32 = padding;
        DMA_R_DIR:         v32 = {31'd0, dir_is_st};
        DMA_R_RSVD:        v32 = 32'd0;

        default:           v32 = 32'd0;
      endcase
      return v32;
    end
  endfunction

  // ============================================================
  // FSM
  // ============================================================
  typedef enum logic [4:0] {
    S_IDLE,
    S_DECODE,
    S_ALLOC_REQ,
    S_ALLOC_R_WAIT,
    S_ALLOC_WAIT_GAP,
    S_NOTIFY,
    S_PROG_W,
    S_KICK_W,
    S_POLL_GAP,
    S_POLL_R_REQ,
    S_POLL_R_WAIT,
    S_DONE
  } state_t;

  state_t state_q, state_d;
  int     wr_idx_q, wr_idx_d;
  int     poll_gap_q, poll_gap_d;
  int     alloc_gap_q, alloc_gap_d;
  logic [ENTRYID_W-1:0] entry_id_q, entry_id_d;
  logic [CTRL_OWNER_W-1:0] alloc_owner_q, alloc_owner_d;
  logic [CTRL_GEN_W-1:0]   alloc_gen_q, alloc_gen_d;

  assign gemm_dma_ctrl_if.idle = (state_q == S_IDLE);
  assign gemm_dma_ctrl_if.done = (state_q == S_DONE);
  // The cache-path DMA descriptor has retired. This does not guarantee that
  // write-through traffic has reached HBM.
  assign store_done = (state_q == S_POLL_R_WAIT)
                   && (state_d == S_DONE)
                   && (cmd_op == OP_DMA_ST);

  // ============================================================
  // Comb
  // ============================================================
  always_comb begin
    state_d      = state_q;
    wr_idx_d     = wr_idx_q;
    poll_gap_d   = poll_gap_q;
    alloc_gap_d  = alloc_gap_q;
    entry_id_d   = entry_id_q;
    alloc_owner_d = alloc_owner_q;
    alloc_gen_d   = alloc_gen_q;

    M_orig_d      = M_orig_q;
    N_orig_d      = N_orig_q;
    K_orig_d      = K_orig_q;
    qblk_orig_d   = qblk_orig_q;
    M_target_d    = M_target_q;
    N_target_d    = N_target_q;
    K_target_d    = K_target_q;
    wtrans_tot_d  = wtrans_tot_q;
    qdir_tot_d    = qdir_tot_q;

    dma_if.req_valid = 1'b0;
    dma_if.req_data  = '0;
    dma_if.rsp_ready = 1'b1;

    dma_if.req_data.mask      = '0;
    dma_if.req_data.flags     = '0;
    dma_if.req_data.byteen    = '0;
    dma_if.req_data.addr      = '0;
    dma_if.req_data.data      = '0;

    gemm_sync_if.valid   = 1'b0;
    gemm_sync_if.reg_idx = 32'd0;
    gemm_sync_if.value   = 32'd0;

    unique case (state_q)
      S_IDLE: begin
        poll_gap_d  = 0;
        alloc_gap_d = 0;
        if (gemm_dma_ctrl_if.start) state_d = S_DECODE;
      end

      S_DECODE: begin
        if (cmd_op == OP_NOTIFY) state_d = S_NOTIFY;
        else                     state_d = S_ALLOC_REQ;
      end

      S_ALLOC_REQ: begin
        // Global alloc register read at DMA_CFG_BASE_ADDR + 0.
        dma_if.req_valid   = 1'b1;
        dma_if.req_data.rw = 1'b0;

        dma_if.req_data.mask   = '0;
        dma_if.req_data.byteen = '0;
        dma_if.req_data.addr   = '0;
        dma_if.req_data.data   = '0;

        dma_if.req_data.mask[0] = 1'b1;
        dma_if.req_data.addr[0] = to_lsu_addr(DMA_CFG_BASE_ADDR);

        if (dma_if.req_valid && dma_if.req_ready) begin
          state_d = S_ALLOC_R_WAIT;
        end
      end

      S_ALLOC_R_WAIT: begin
        if (dma_if.rsp_valid) begin
          logic [31:0] alloc_rsp_w;
          alloc_rsp_w = dma_if.rsp_data.data[0][31:0];

          if (alloc_rsp_w[ALLOC_SUCCESS_BIT]) begin
            entry_id_d = '0;
            alloc_owner_d = '0;
            alloc_gen_d   = '0;
            if (ALLOC_ENTRY_COPY_BITS > 0) begin
              entry_id_d[ALLOC_ENTRY_COPY_BITS-1:0] = alloc_rsp_w[ALLOC_ENTRY_LSB +: ALLOC_ENTRY_COPY_BITS];
            end
            if (ALLOC_OWNER_COPY_BITS > 0) begin
              alloc_owner_d[ALLOC_OWNER_COPY_BITS-1:0] = alloc_rsp_w[ALLOC_OWNER_LSB +: ALLOC_OWNER_COPY_BITS];
            end
            if (ALLOC_GEN_COPY_BITS > 0) begin
              alloc_gen_d[ALLOC_GEN_COPY_BITS-1:0] = alloc_rsp_w[ALLOC_GEN_LSB +: ALLOC_GEN_COPY_BITS];
            end

            wr_idx_d = DMA_R_CONTROL;
            state_d  = S_PROG_W;
          end else if (ALLOC_RETRY_GAP_CYCLES > 0) begin
            alloc_gap_d = ALLOC_RETRY_GAP_CYCLES;
            state_d     = S_ALLOC_WAIT_GAP;
          end else begin
            state_d = S_ALLOC_REQ;
          end
        end
      end

      S_ALLOC_WAIT_GAP: begin
        if (alloc_gap_q == 0) state_d = S_ALLOC_REQ;
        else                  alloc_gap_d = alloc_gap_q - 1;
      end

      S_NOTIFY: begin
        gemm_sync_if.valid   = 1'b1;
        gemm_sync_if.reg_idx = {24'd0, notify_rid};
        gemm_sync_if.value   = notify_value;
        if (gemm_sync_if.ready) state_d = S_DONE;
      end

      // Descriptor register programming. Default uses packed multi-lane writes
      // for control-plane latency; JOB_MMIO_DMA_DESC_ONE_LANE restricts this
      // path to lane0 so a one-lane DMA job frontend can be used.
      S_PROG_W: begin
        int base_idx;
        base_idx = wr_idx_q;

        dma_if.req_valid   = 1'b1;
        dma_if.req_data.rw = 1'b1;

        dma_if.req_data.mask   = '0;
        dma_if.req_data.byteen = '0;
        dma_if.req_data.addr   = '0;
        dma_if.req_data.data   = '0;

      `ifdef JOB_MMIO_DMA_DESC_ONE_LANE
        dma_if.req_data.mask[0] = 1'b1;
        dma_if.req_data.addr[0] = to_lsu_addr(entry_reg_byte_addr(entry_id_q, base_idx));

        for (int w = 0; w < REGS_PER_LANE; w++) begin
          int idx;
          idx = base_idx + w;

          if (idx <= DMA_R_LAST) begin
            dma_if.req_data.data[0][(w*32) +: 32] = prog_w_data(idx);
            dma_if.req_data.byteen[0][(w*4) +: 4] = 4'b1111;
          end
        end

        if (dma_if.req_valid && dma_if.req_ready) begin
          int next_base;
          next_base = base_idx + REGS_PER_LANE;

          if (next_base > DMA_R_LAST) state_d = S_KICK_W;
          else                        wr_idx_d = next_base;
        end
      `else
        for (int l = 0; l < DMA_NUM_LANES; l++) begin
          int idx0;
          idx0 = base_idx + (l * REGS_PER_LANE);

          if (idx0 <= DMA_R_LAST) begin
            dma_if.req_data.mask[l] = 1'b1;

            dma_if.req_data.addr[l] = to_lsu_addr(entry_reg_byte_addr(entry_id_q, idx0));

            // pack: idx0 -> data[31:0], idx0+1 -> data[63:32], ...
            for (int w = 0; w < REGS_PER_LANE; w++) begin
              int idx;
              idx = idx0 + w;

              if (idx <= DMA_R_LAST) begin
                dma_if.req_data.data[l][(w*32) +: 32] = prog_w_data(idx);

                dma_if.req_data.byteen[l][(w*4) +: 4] = 4'b1111;
              end
            end
          end
        end

        if (dma_if.req_valid && dma_if.req_ready) begin
          int next_base;
          next_base = base_idx + (DMA_NUM_LANES * REGS_PER_LANE);

          if (next_base > DMA_R_LAST) state_d = S_KICK_W;
          else                        wr_idx_d = next_base;
        end
      `endif
      end

      // CONTROL write (start)
      S_KICK_W: begin
        logic [63:0] ctrl;

        dma_if.req_valid   = 1'b1;
        dma_if.req_data.rw = 1'b1;

        dma_if.req_data.mask      = '0;
        dma_if.req_data.byteen    = '0;
        dma_if.req_data.addr      = '0;
        dma_if.req_data.data      = '0;

        dma_if.req_data.mask[0] = 1'b1;

        dma_if.req_data.byteen[0][3:0] = 4'b1111;

        dma_if.req_data.addr[0] = to_lsu_addr(entry_reg_byte_addr(entry_id_q, DMA_R_CONTROL));

        ctrl = 64'd0;
        ctrl[DMA_CTRL_START_BIT] = 1'b1;
        dma_if.req_data.data[0]  = ctrl;

        if (dma_if.req_valid && dma_if.req_ready) begin
          poll_gap_d = (POLL_GAP_CYCLES > 0) ? (POLL_GAP_CYCLES-1) : 0;
          state_d    = S_POLL_GAP;
        end
      end

      S_POLL_GAP: begin
        if (poll_gap_q == 0) state_d = S_POLL_R_REQ;
        else                 poll_gap_d = poll_gap_q - 1;
      end

      // CONTROL read
      S_POLL_R_REQ: begin
        dma_if.req_valid   = 1'b1;
        dma_if.req_data.rw = 1'b0;

        dma_if.req_data.mask      = '0;
        dma_if.req_data.byteen    = '0;
        dma_if.req_data.addr      = '0;
        dma_if.req_data.data      = '0;

        dma_if.req_data.mask[0] = 1'b1;
        dma_if.req_data.addr[0] = to_lsu_addr(entry_reg_byte_addr(entry_id_q, DMA_R_CONTROL));

        if (dma_if.req_valid && dma_if.req_ready) state_d = S_POLL_R_WAIT;
      end

      S_POLL_R_WAIT: begin
        if (dma_if.rsp_valid) begin
          logic [63:0] rdata;
          logic [CTRL_OWNER_W-1:0] ctrl_owner;
          logic [CTRL_GEN_W-1:0]   ctrl_gen;
          rdata = dma_if.rsp_data.data[0];
          ctrl_owner = '0;
          ctrl_gen   = '0;
          ctrl_owner = rdata[DMA_CTRL_OWNER_LSB +: CTRL_OWNER_W];
          ctrl_gen   = rdata[DMA_CTRL_GEN_LSB +: CTRL_GEN_W];

          // Completion condition:
          //   1) entry released by backend (occupy=0 && working=0), or
          //   2) token changed (another requester re-allocated same entry).
          if ((rdata[DMA_CTRL_OCCUPY_BIT] == 1'b0 && rdata[DMA_CTRL_WORKING_BIT] == 1'b0)
           || (ctrl_owner != alloc_owner_q)
           || (ctrl_gen   != alloc_gen_q)) begin
            state_d = S_DONE;
          end else begin
            poll_gap_d = (POLL_GAP_CYCLES > 0) ? (POLL_GAP_CYCLES-1) : 0;
            state_d    = S_POLL_GAP;
          end
        end
      end

      S_DONE: begin
        state_d = S_IDLE;
      end

      default: state_d = S_IDLE;
    endcase
  end

  // ============================================================
  // Sequential
  // ============================================================
  always_ff @(posedge clk) begin
    if (reset) begin
      state_q      <= S_IDLE;
      wr_idx_q     <= 0;
      poll_gap_q   <= 0;
      alloc_gap_q  <= 0;
      cmd_q        <= '0;
      entry_id_q   <= '0;
      alloc_owner_q <= '0;
      alloc_gen_q   <= '0;

      M_orig_q      <= 32'd0;
      N_orig_q      <= 32'd0;
      K_orig_q      <= 32'd0;
      qblk_orig_q   <= 32'd0;
      M_target_q    <= 32'd0;
      N_target_q    <= 32'd0;
      K_target_q    <= 32'd0;
      wtrans_tot_q  <= 32'd0;
      qdir_tot_q    <= 32'd0;
    end else begin
      state_q      <= state_d;
      wr_idx_q     <= wr_idx_d;
      poll_gap_q   <= poll_gap_d;
      alloc_gap_q  <= alloc_gap_d;
      entry_id_q   <= entry_id_d;
      alloc_owner_q <= alloc_owner_d;
      alloc_gen_q   <= alloc_gen_d;

      M_orig_q      <= M_orig_d;
      N_orig_q      <= N_orig_d;
      K_orig_q      <= K_orig_d;
      qblk_orig_q   <= qblk_orig_d;
      M_target_q    <= M_target_d;
      N_target_q    <= N_target_d;
      K_target_q    <= K_target_d;
      wtrans_tot_q  <= wtrans_tot_d;
      qdir_tot_q    <= qdir_tot_d;

      if (state_q == S_IDLE && gemm_dma_ctrl_if.start) begin
        /*
        if ((gemm_dma_ctrl_if.qblk_orig != 0) && !is_pow2_u32(gemm_dma_ctrl_if.qblk_orig)) begin
          $fatal(1, "%s: qblk_orig(%0d) must be power-of-two for shift-based division",
                 INSTANCE_ID, gemm_dma_ctrl_if.qblk_orig);
        end*/

        cmd_q        <= gemm_dma_ctrl_if.cmd;

        M_orig_q      <= gemm_dma_ctrl_if.M_orig;
        N_orig_q      <= gemm_dma_ctrl_if.N_orig;
        K_orig_q      <= gemm_dma_ctrl_if.K_orig;
        qblk_orig_q   <= gemm_dma_ctrl_if.qblk_orig;
        M_target_q    <= gemm_dma_ctrl_if.M_target;
        N_target_q    <= gemm_dma_ctrl_if.N_target;
        K_target_q    <= gemm_dma_ctrl_if.K_target;
        wtrans_tot_q  <= gemm_dma_ctrl_if.wtrans_tot;
        qdir_tot_q    <= gemm_dma_ctrl_if.qdir_tot;
      end
    end
  end

`ifdef CHIPSCOPE
`ifdef DBG_SCOPE_GEMM
  localparam int DBG_BIT_W   = $bits(logic);
  localparam int DBG_STATE_W = $bits(state_q);
  localparam int DBG_WORD_W  = $bits(logic [31:0]);
  localparam int DBG_XLEN_W  = $bits(cmd_q.rs1_data);

  localparam int DBG_GEMM_DMA_CTRL_P0_W = (11 * DBG_BIT_W) + (2 * DBG_STATE_W) + $bits(cmd_op);
  localparam int DBG_GEMM_DMA_CTRL_P1_W = (10 * DBG_WORD_W);
  localparam int DBG_GEMM_DMA_CTRL_P2_W = (5 * DBG_WORD_W) + (3 * DBG_XLEN_W) + DBG_BIT_W;
  localparam int DBG_GEMM_DMA_CTRL_P3_W = (9 * DBG_WORD_W);

  (* keep = "true", mark_debug = "true" *) wire [DBG_GEMM_DMA_CTRL_P0_W-1:0] dbg_gemm_dma_ctrl_probe0 = {
      reset,
      gemm_dma_ctrl_if.start,
      (state_q == S_IDLE),
      (state_q == S_DONE),
      dma_if.req_valid,
      dma_if.req_ready,
      dma_if.rsp_valid,
      dma_if.rsp_ready,
      gemm_sync_if.valid,
      gemm_sync_if.ready,
      state_q,
      state_d,
      cmd_op,
      dir_is_st
  };
  (* keep = "true", mark_debug = "true" *) wire [DBG_GEMM_DMA_CTRL_P1_W-1:0] dbg_gemm_dma_ctrl_probe1 = {
      32'(entry_id_q),
      32'(entry_id_d),
      32'(alloc_owner_q),
      32'(alloc_owner_d),
      32'(alloc_gen_q),
      32'(alloc_gen_d),
      32'(wr_idx_q),
      32'(wr_idx_d),
      32'(poll_gap_q),
      32'(alloc_gap_q)
  };
  (* keep = "true", mark_debug = "true" *) wire [DBG_GEMM_DMA_CTRL_P2_W-1:0] dbg_gemm_dma_ctrl_probe2 = {
      32'(dma_if.req_data.mask),
      dma_if.req_data.rw,
      32'(dma_if.req_data.addr[0]),
      32'(dma_if.req_data.byteen[0]),
      64'(dma_if.req_data.data[0]),
      64'(dma_if.rsp_data.data[0]),
      32'(gemm_sync_if.reg_idx),
      32'(gemm_sync_if.value),
      64'(cmd_q.instr)
  };
  (* keep = "true", mark_debug = "true" *) wire [DBG_GEMM_DMA_CTRL_P3_W-1:0] dbg_gemm_dma_ctrl_probe3 = {
      M_orig_q,
      N_orig_q,
      K_orig_q,
      qblk_orig_q,
      M_target_q,
      N_target_q,
      K_target_q,
      wtrans_tot_q,
      qdir_tot_q
  };

  ila_gemm_dma_ctrl ila_gemm_dma_ctrl_inst (
    .clk    (clk),
    .probe0 (dbg_gemm_dma_ctrl_probe0),
    .probe1 (dbg_gemm_dma_ctrl_probe1),
    .probe2 (dbg_gemm_dma_ctrl_probe2),
    .probe3 (dbg_gemm_dma_ctrl_probe3)
  );
`endif
`endif

endmodule

`endif // GEMM_NAIVE
