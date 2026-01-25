`include "VX_define.vh"

module VX_gemm_fsm import VX_gpu_pkg::*; #(
    parameter `STRING INSTANCE_ID = ""
) (
    input  wire              clk,
    input  wire              reset,

    VX_config_reg_if.slave   cfg_reg_if,
    VX_gemm_fsm_if.master    gemm_fsm_if
);

  // --------------------------------------------------------------------------
  // Bring-up fixed (as requested)
  // --------------------------------------------------------------------------
  localparam logic QDIR_COL_FIXED  = 1'b1;
  localparam logic W_TP_FIXED      = 1'b0; // unused in this bring-up stream
  localparam logic IS_BIAS_FIXED   = 1'b0; // unused in this bring-up stream

  // DMA tile sizes
  localparam int MT = 128;
  localparam int NT = 128;
  localparam int KT = 128;

  // MXU micro tile sizes (kernel: 32x128)
  localparam int MXU_KT = 32;
  localparam int MXU_NT = 128;

  // --------------------------------------------------------------------------
  // LMEM base addresses (DMA tile double buffering)
  // --------------------------------------------------------------------------
  localparam logic [63:0] LMEM_IBUF0_BASE = 64'h0010_0000;
  localparam logic [63:0] LMEM_IBUF1_BASE = 64'h0018_0000;

  localparam logic [63:0] LMEM_WBUF0_BASE = 64'h0020_0000;
  localparam logic [63:0] LMEM_WBUF1_BASE = 64'h0028_0000;

  localparam logic [63:0] LMEM_OBUF0_BASE = 64'h0030_0000;
  localparam logic [63:0] LMEM_OBUF1_BASE = 64'h0038_0000;

  localparam logic [63:0] LMEM_PBUF0_BASE = 64'h0040_0000; // scale + zp pack region
  localparam logic [63:0] LMEM_PBUF1_BASE = 64'h0048_0000;

  function automatic logic [63:0] ibuf_base(input logic buf_sel); return buf_sel ? LMEM_IBUF1_BASE : LMEM_IBUF0_BASE; endfunction
  function automatic logic [63:0] wbuf_base(input logic buf_sel); return buf_sel ? LMEM_WBUF1_BASE : LMEM_WBUF0_BASE; endfunction
  function automatic logic [63:0] obuf_base(input logic buf_sel); return buf_sel ? LMEM_OBUF1_BASE : LMEM_OBUF0_BASE; endfunction
  function automatic logic [63:0] pbuf_base(input logic buf_sel); return buf_sel ? LMEM_PBUF1_BASE : LMEM_PBUF0_BASE; endfunction

  // --------------------------------------------------------------------------
  // Unified opcode map (parent -> sync -> child queues)
  // --------------------------------------------------------------------------
  localparam logic [7:0] OP_WAIT          = 8'hF0;
  localparam logic [7:0] OP_NOTIFY        = 8'hF1;

  // DRAM<->LMEM DMA (dma_cmd_queue)
  localparam logic [7:0] OP_DMA_LD        = 8'h10; // DRAM -> LMEM
  localparam logic [7:0] OP_DMA_ST        = 8'h11; // LMEM -> DRAM

  // LMEM -> GEMM local DMA queues
  localparam logic [7:0] OP_W_LDMA_MXU    = 8'h20; // LMEM(WBUF) -> GEMM weight buf[mxu_buf]
  // split scale / zp into separate commands (same SZ cmd_queue)
  localparam logic [7:0] OP_SC_LDMA_MXU   = 8'h21; // LMEM(PBUF scale) -> GEMM scale buf[mxu_buf]
  localparam logic [7:0] OP_ZP_LDMA_MXU   = 8'h24; // LMEM(PBUF zp)    -> GEMM zp buf[mxu_buf]

  localparam logic [7:0] OP_I_LDMA_ARM    = 8'h22; // LMEM(IBUF) -> GEMM input + GEMM start/config
  localparam logic [7:0] OP_O_ACC2LMEM    = 8'h23; // GEMM acc_mem -> LMEM(OBUF)

  // --------------------------------------------------------------------------
  // Sync register assignment (10 regs; per DMA buf)
  // --------------------------------------------------------------------------
  localparam int RID_T0  = 0, RID_W0  = 1, RID_SZ0 = 2, RID_G0 = 3, RID_O0 = 4;
  localparam int RID_T1  = 5, RID_W1  = 6, RID_SZ1 = 7, RID_G1 = 8, RID_O1 = 9;

  function automatic int rid_tile (input logic buf_sel);  return buf_sel ? RID_T1  : RID_T0;  endfunction  // dma tile preload done
  function automatic int rid_w    (input logic buf_sel);  return buf_sel ? RID_W1  : RID_W0;  endfunction  // mxu weight preload done
  function automatic int rid_sz   (input logic buf_sel);  return buf_sel ? RID_SZ1 : RID_SZ0; endfunction  // mxu scale/zp preload done (after ZP cmd)
  function automatic int rid_g    (input logic buf_sel);  return buf_sel ? RID_G1  : RID_G0;  endfunction  // gemm done marker (per microtile)
  function automatic int rid_o    (input logic buf_sel);  return buf_sel ? RID_O1  : RID_O0;  endfunction  // output store done marker
  
  // buf generation: buf0 for tile 0,2,4.. => gen 1,2,3..
  //                 buf1 for tile 1,3,5.. => gen 1,2,3..
  function automatic int unsigned buf_gen(input int unsigned t);
    return (t >> 1) + 1;
  endfunction

  function automatic int unsigned ceil_div(input int unsigned a, input int unsigned b);
    return (a + b - 1) / b;
  endfunction


  function automatic logic [31:0] make_instr(input logic [7:0] op, input logic [7:0] flags, input int unsigned size_bytes);
    // [7:0]=op, [15:8]=flags, [31:16]=size (16b)
    make_instr = {size_bytes[15:0], flags, op};
  endfunction

  function automatic gemm_unified_cmd_t make_wait_cmd(input int unsigned reg_id, input int unsigned target);
    gemm_unified_cmd_t t;
    begin
      t = '0;
      t.instr   = {24'd0, OP_WAIT};
      t.rs1_data = {{(`XLEN-8){1'b0}}, reg_id[7:0]};
      t.rs2_data = {{(`XLEN-32){1'b0}}, target[31:0]}; // semantics: reg >= target
      return t;
    end
  endfunction

  function automatic gemm_unified_cmd_t make_notify_cmd(input int unsigned reg_id, input int unsigned value, input logic set_mode);
    // set_mode=1: reg = value
    // set_mode=0: reg += value
    gemm_unified_cmd_t t;
    begin
      t = '0;
      t.instr   = {24'd0, OP_NOTIFY};
      t.rs1_data = {{(`XLEN-9){1'b0}}, set_mode, reg_id[7:0]};
      t.rs2_data = {{(`XLEN-32){1'b0}}, value[31:0]};
      return t;
    end
  endfunction

  function automatic gemm_unified_cmd_t make_dma_ld(
    input logic [63:0] lmem_dst,
    input logic [63:0] dram_src,
    input int unsigned size_bytes,
    input logic buf_sel,
    input int unsigned gen
  );
    gemm_unified_cmd_t c;
    logic [7:0] flags;
    begin
      c = '0;
      flags = {gen[6:0], buf_sel};
      c.instr   = make_instr(OP_DMA_LD, flags, size_bytes);
      c.rs1_data = lmem_dst; // dst LMEM
      c.rs2_data = dram_src; // src DRAM
      return c;
    end
  endfunction

  function automatic gemm_unified_cmd_t make_dma_st(
    input logic [63:0] dram_dst,
    input logic [63:0] lmem_src,
    input int unsigned size_bytes,
    input logic buf_sel,
    input int unsigned gen
  );
    gemm_unified_cmd_t c;
    logic [7:0] flags;
    begin
      c = '0;
      flags = {gen[6:0], buf_sel};
      c.instr   = make_instr(OP_DMA_ST, flags, size_bytes);
      c.rs1_data = dram_dst; // dst DRAM
      c.rs2_data = lmem_src; // src LMEM
      return c;
    end
  endfunction

  // --------------------------------------------------------------------------
  // Job/config
  // --------------------------------------------------------------------------
  typedef struct packed {
    logic [63:0] input_base;
    logic [63:0] weight_base;
    logic [63:0] output_base;
    logic [63:0] scale_base;
    logic [63:0] zp_base;
    logic [31:0] M, N, K;
    logic [31:0] qblk;
  } job_t;

  job_t job_q, job_d;

  int unsigned mt_dim_q, nt_dim_q, kt_dim_q;
  int unsigned m_last_q, n_last_q, k_last_q;
  int unsigned tile_total_q;

  // linear tile index: tile = ((nt * mt_dim) + mt) * kt_dim + kt
  task automatic tile_decode(
    input int unsigned tile,
    input int unsigned mt_dim,
    input int unsigned kt_dim,
    output int unsigned nt,
    output int unsigned mt,
    output int unsigned kt
  );
    int unsigned tmp;
    begin
      kt  = tile % kt_dim;
      tmp = tile / kt_dim;
      mt  = tmp % mt_dim;
      nt  = tmp / mt_dim;
    end
  endtask

  // --------------------------------------------------------------------------
  // DRAM address helpers
  // --------------------------------------------------------------------------
  function automatic logic [63:0] input_tile_addr(input job_t j, input int unsigned mt, input int unsigned kt);
    int unsigned tile_idx;
    begin
      tile_idx = kt + mt * kt_dim_q;
      input_tile_addr = j.input_base + tile_idx * (MT*KT*2); // fp16
    end
  endfunction

  function automatic logic [63:0] weight_tile_addr(input job_t j, input int unsigned nt, input int unsigned kt);
    int unsigned tile_idx;
    begin
      // weight_transposed=0 fixed
      tile_idx = nt + kt * nt_dim_q;
      weight_tile_addr = j.weight_base + tile_idx * ((KT*NT)/2); // int4 packed
    end
  endfunction

  function automatic logic [63:0] scale_tile_addr(input job_t j, input int unsigned nt, input int unsigned kt);
    int unsigned tile_idx;
    int unsigned groups;
    begin
      groups = ceil_div(KT, j.qblk);
      tile_idx = nt + kt * nt_dim_q;
      scale_tile_addr = j.scale_base + tile_idx * (groups*NT*4); // fp32
    end
  endfunction

  function automatic logic [63:0] zp_tile_addr(input job_t j, input int unsigned nt, input int unsigned kt);
    int unsigned tile_idx;
    int unsigned groups;
    begin
      groups = ceil_div(KT, j.qblk);
      tile_idx = nt + kt * nt_dim_q;
      zp_tile_addr = j.zp_base + tile_idx * (groups*NT*1); // int8
    end
  endfunction

  function automatic logic [63:0] out_tile_addr(input job_t j, input int unsigned mt, input int unsigned nt);
    int unsigned tile_idx;
    begin
      tile_idx = mt * nt_dim_q + nt;
      out_tile_addr = j.output_base + tile_idx * (MT*NT*2); // fp16
    end
  endfunction

  // --------------------------------------------------------------------------
  // Output interface driving (pulse start)
  // --------------------------------------------------------------------------
  gemm_unified_cmd_t out_cmd_d;
  logic              out_start_d;

  always_comb begin
    gemm_fsm_if.ctrl.cmd   = out_cmd_d;
    gemm_fsm_if.ctrl.start = out_start_d;
  end

  // --------------------------------------------------------------------------
  // FSM
  // --------------------------------------------------------------------------
  typedef enum logic [7:0] {
    S_IDLE,

    // kickoff: preload first two tiles (pipeline warmup) - single notify per tile
    S_PRE0_LD_I,
    S_PRE0_LD_W,
    S_PRE0_LD_SC,
    S_PRE0_LD_ZP,
    S_PRE0_LD_DONE_NTF,

    S_PRE1_LD_I,
    S_PRE1_LD_W,
    S_PRE1_LD_SC,
    S_PRE1_LD_ZP,
    S_PRE1_LD_DONE_NTF,

    // wait current tile ready
    S_WAIT_CUR_TILE_READY,

    // MXU: preload W/SZ for current then steady-state
    S_MXU_PRE_CUR_W,  S_MXU_PRE_CUR_W_NTF,

    // split SZ: SC then ZP (same SZ cmd_queue)
    S_MXU_PRE_CUR_SC,
    S_MXU_PRE_CUR_ZP,
    S_MXU_PRE_CUR_SZ_NTF,

    S_MXU_WAIT_CUR_W,
    S_MXU_WAIT_CUR_SZ,

    S_MXU_PRE_NEXT_W,
    S_MXU_PRE_NEXT_W_NTF,

    // split NEXT SZ
    S_MXU_PRE_NEXT_SC,
    S_MXU_PRE_NEXT_ZP,
    S_MXU_PRE_NEXT_SZ_NTF,

    // ARM triggers input ldma; GEMM completion via rid_g (notify+wait)
    S_MXU_ARM_GEMM,
    S_MXU_ARM_GEMM_NTF,
    S_MXU_WAIT_GEMM_DONE,

    // output 2-stage: acc->lmem then lmem->dram (with wait between)
    S_O_KICK_SET,
    S_O_ACC2LMEM,      S_O_ACC2LMEM_NTF,
    S_O_WAIT_ACC2LMEM_DONE,
    S_O_LMEM2DRAM,     S_O_LMEM2DRAM_NTF,

    // advance tiles and trigger preload for next tile into freed buffer
    S_ADVANCE_TILES,

    // preload next tile into freed buffer - single notify per tile
    S_PRE_NEXT_WAIT_REUSE,
    S_PRE_NEXT_LD_I,
    S_PRE_NEXT_LD_W,
    S_PRE_NEXT_LD_SC,
    S_PRE_NEXT_LD_ZP,
    S_PRE_NEXT_LD_DONE_NTF
  } state_t;

  state_t state_q, state_d;

  // tile pipeline registers
  int unsigned tile_cur_q, tile_cur_d;
  int unsigned tile_pre_q, tile_pre_d;   // next tile being/been preloaded
  logic        pre_valid_q, pre_valid_d; // whether tile_pre exists

  // mxu loop regs for current tile
  int unsigned nt_mxu_q, nt_mxu_d;
  int unsigned kt_mxu_q, kt_mxu_d;
  logic        mxu_buf_q, mxu_buf_d;

  // reuse-wait sequencing flag (for current tile)
  logic waited_reuse_q, waited_reuse_d;

  // cfg only in idle
  always_comb begin
    cfg_reg_if.ready = (state_q == S_IDLE);
  end

  // --------------------------------------------------------------------------
  // sequential
  // --------------------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (reset) begin
      state_q <= S_IDLE;

      job_q <= '0;
      mt_dim_q <= 0; nt_dim_q <= 0; kt_dim_q <= 0;
      m_last_q <= 0; n_last_q <= 0; k_last_q <= 0;
      tile_total_q <= 0;

      tile_cur_q <= 0;
      tile_pre_q <= 0;
      pre_valid_q <= 1'b0;

      nt_mxu_q <= 0;
      kt_mxu_q <= 0;
      mxu_buf_q <= 1'b0;

      waited_reuse_q <= 1'b0;
    end else begin
      state_q <= state_d;
      job_q   <= job_d;

      tile_cur_q  <= tile_cur_d;
      tile_pre_q  <= tile_pre_d;
      pre_valid_q <= pre_valid_d;

      nt_mxu_q  <= nt_mxu_d;
      kt_mxu_q  <= kt_mxu_d;
      mxu_buf_q <= mxu_buf_d;

      waited_reuse_q <= waited_reuse_d;

      if (state_q == S_IDLE && cfg_reg_if.valid && cfg_reg_if.ready) begin
        mt_dim_q <= ceil_div(job_d.M, MT);
        nt_dim_q <= ceil_div(job_d.N, NT);
        kt_dim_q <= ceil_div(job_d.K, KT);

        m_last_q <= job_d.M - (ceil_div(job_d.M, MT)-1) * MT;
        n_last_q <= job_d.N - (ceil_div(job_d.N, NT)-1) * NT;
        k_last_q <= job_d.K - (ceil_div(job_d.K, KT)-1) * KT;

        tile_total_q <= ceil_div(job_d.N, NT) * ceil_div(job_d.M, MT) * ceil_div(job_d.K, KT);
      end
    end
  end

  // --------------------------------------------------------------------------
  // combinational
  // --------------------------------------------------------------------------
  always_comb begin
    // ----------------
    // defaults
    // ----------------
    logic can_emit;
    int unsigned nt_cur, mt_cur, kt_cur;
    int unsigned mt_eff_cur, nt_eff_cur, kt_eff_cur;
    logic buf_cur;
    int unsigned gen_cur;
    int unsigned in_ready_target_cur;
    int unsigned reuse_target_prev_cur;
    logic [63:0] IBASE_cur, WBASE_cur, OBASE_cur, PBASE_cur;
    int unsigned nt_mxu_dim, kt_mxu_dim;
    int unsigned mxu_linear;
    int unsigned n_nt_mxu, n_kt_mxu;
    logic has_next_mxu;
    int unsigned next_mxu_linear;
    int unsigned global_k;
    logic is_accum, is_last;
    logic [63:0] lmem_in_mxu, lmem_out_slice, lmem_w_mxu, lmem_sc_mxu, lmem_zp_mxu;
    int unsigned groups_tile, groups_mxu;
    logic [63:0] lmem_w_mxu_next, lmem_sc_mxu_next, lmem_zp_mxu_next;
    int unsigned gemm_done_target;

    state_d = state_q;
    job_d   = job_q;

    tile_cur_d  = tile_cur_q;
    tile_pre_d  = tile_pre_q;
    pre_valid_d = pre_valid_q;

    nt_mxu_d  = nt_mxu_q;
    kt_mxu_d  = kt_mxu_q;
    mxu_buf_d = mxu_buf_q;

    out_cmd_d   = '0;
    out_start_d = 1'b0;

    waited_reuse_d = waited_reuse_q;

    // NOTE: command emission is gated by parent queue "idle"
    can_emit = gemm_fsm_if.flag.idle;

    // -------------------------------
    // decode current tile
    // -------------------------------
    tile_decode(tile_cur_q, mt_dim_q, kt_dim_q, nt_cur, mt_cur, kt_cur);

    mt_eff_cur = (mt_cur == mt_dim_q-1) ? m_last_q : MT;
    nt_eff_cur = (nt_cur == nt_dim_q-1) ? n_last_q : NT;
    kt_eff_cur = (kt_cur == kt_dim_q-1) ? k_last_q : KT;

    buf_cur = tile_cur_q[0];

    gen_cur = buf_gen(tile_cur_q);

    // targets for current tile readiness / reuse
    in_ready_target_cur = 4*gen_cur + 4; // preload done marker (single notify sets this)

    reuse_target_prev_cur = (gen_cur > 1) ? (2*(gen_cur-1) + 2) : 0;

    // LMEM bases for cur
    IBASE_cur = ibuf_base(buf_cur);
    WBASE_cur = wbuf_base(buf_cur);
    OBASE_cur = obuf_base(buf_cur);
    PBASE_cur = pbuf_base(buf_cur);

    // MXU dims within current DMA tile
    nt_mxu_dim = ceil_div(nt_eff_cur, MXU_NT);
    kt_mxu_dim = (kt_eff_cur / MXU_KT); // assume divisible

    mxu_linear = kt_mxu_q * nt_mxu_dim + nt_mxu_q;

    // next mxu indices
    n_nt_mxu = (nt_mxu_q + 1 == nt_mxu_dim) ? 0 : (nt_mxu_q + 1);
    n_kt_mxu = (nt_mxu_q + 1 == nt_mxu_dim) ? (kt_mxu_q + 1) : kt_mxu_q;

    has_next_mxu = (n_kt_mxu < kt_mxu_dim);

    next_mxu_linear = n_kt_mxu * nt_mxu_dim + n_nt_mxu;

    // global_k determines accumulate/last
    global_k = kt_cur * KT + kt_mxu_q * MXU_KT;

    is_accum = (global_k != 0);
    is_last  = (global_k + MXU_KT >= job_q.K);

    // LMEM offsets for current microtile
    lmem_in_mxu    = IBASE_cur + (kt_mxu_q * (mt_eff_cur * MXU_KT * 2));
    lmem_out_slice = OBASE_cur + (nt_mxu_q * (mt_eff_cur * MXU_NT * 2));
    lmem_w_mxu     = WBASE_cur + (mxu_linear * (MXU_KT * (MXU_NT/2)));

    groups_tile = ceil_div(KT, job_q.qblk);
    groups_mxu  = ceil_div(MXU_KT, job_q.qblk);

    lmem_sc_mxu = PBASE_cur + mxu_linear * (groups_mxu * MXU_NT * 4);
    lmem_zp_mxu = PBASE_cur + (groups_tile * NT * 4) + mxu_linear * (groups_mxu * MXU_NT * 1);

    // next microtile addresses (for preload next)
    lmem_w_mxu_next  = WBASE_cur + (next_mxu_linear * (MXU_KT * (MXU_NT/2)));
    lmem_sc_mxu_next = PBASE_cur + next_mxu_linear * (groups_mxu * MXU_NT * 4);
    lmem_zp_mxu_next = PBASE_cur + (groups_tile * NT * 4) + next_mxu_linear * (groups_mxu * MXU_NT * 1);

    // gemm done target for this microtile
    gemm_done_target = (mxu_linear + 1);

    // ------------------------------------------------------------------------
    // CLEAN POLICY (one-way, consistent):
    // - mxu_buf selection is carried ONLY in flags (for W/SC/ZP/I ops)
    // - rs1_data/rs2_data carry addresses/params only (no "buffer index" piggyback)
    //
    // For OP_W/OP_SC/OP_ZP:
    //   - rs2_data = src LMEM address
    //   - rs1_data = 0 (reserved)
    //
    // So child nodes should use flags.mxu_buf to select destination ping/pong.
    // ------------------------------------------------------------------------

    unique case (state_q)

      // ----------------------------------------------------------------------
      // IDLE
      // ----------------------------------------------------------------------
      S_IDLE: begin
        tile_cur_d  = 0;
        tile_pre_d  = 0;
        pre_valid_d = 1'b0;
        nt_mxu_d    = 0;
        kt_mxu_d    = 0;
        mxu_buf_d   = 1'b0;
        waited_reuse_d = 1'b0;

        if (cfg_reg_if.valid) begin
          job_d.input_base  = cfg_reg_if.regs[0];
          job_d.weight_base = cfg_reg_if.regs[1];
          job_d.output_base = cfg_reg_if.regs[2];
          job_d.scale_base  = cfg_reg_if.regs[3];
          job_d.zp_base     = cfg_reg_if.regs[4];

          job_d.M           = cfg_reg_if.regs[6][31:0];
          job_d.N           = cfg_reg_if.regs[6][63:32];
          job_d.K           = cfg_reg_if.regs[7][31:0];
          job_d.qblk        = cfg_reg_if.regs[7][63:32];

          state_d = S_PRE0_LD_I;
        end
      end

      // ----------------------------------------------------------------------
      // Warmup preload tile0 (buf0) - SINGLE notify after ZP
      // ----------------------------------------------------------------------
      S_PRE0_LD_I: begin
        if (can_emit) begin
          out_cmd_d   = make_dma_ld(ibuf_base(1'b0),
                                   input_tile_addr(job_q, /*mt*/0, /*kt*/0),
                                   (MT*KT*2),
                                   1'b0, 1);
          out_start_d = 1'b1;
          state_d     = S_PRE0_LD_W;
        end
      end

      S_PRE0_LD_W: begin
        if (can_emit) begin
          out_cmd_d   = make_dma_ld(wbuf_base(1'b0),
                                   weight_tile_addr(job_q, 0, 0),
                                   ((KT*NT)/2),
                                   1'b0, 1);
          out_start_d = 1'b1;
          state_d     = S_PRE0_LD_SC;
        end
      end

      S_PRE0_LD_SC: begin
        if (can_emit) begin
          int unsigned groups;
          groups = ceil_div(KT, job_q.qblk);
          //$display("[PRE0_SC] qblk=%0d groups=%0d sc_bytes=%0d", job_q.qblk, groups, groups*NT*4);
          out_cmd_d   = make_dma_ld(pbuf_base(1'b0),
                                   scale_tile_addr(job_q, 0, 0),
                                   (groups*NT*4),
                                   1'b0, 1);
          out_start_d = 1'b1;
          state_d     = S_PRE0_LD_ZP;
        end
      end

      S_PRE0_LD_ZP: begin
        if (can_emit) begin
          int unsigned groups;
          logic [63:0] zp_dst;
          groups = ceil_div(KT, job_q.qblk);
          zp_dst = pbuf_base(1'b0) + (groups * NT * 4);
          //$display("[PRE0_ZP] qblk=%0d groups=%0d zp_bytes=%0d", job_q.qblk, groups, groups*NT*1);

          out_cmd_d   = make_dma_ld(zp_dst,
                                   zp_tile_addr(job_q, 0, 0),
                                   (groups*NT*1),
                                   1'b0, 1);
          out_start_d = 1'b1;
          state_d     = S_PRE0_LD_DONE_NTF;
        end
      end

      S_PRE0_LD_DONE_NTF: begin
        if (can_emit) begin
          out_cmd_d   = make_notify_cmd(rid_tile(1'b0), (4*1 + 4), 1'b1 /*set*/);
          out_start_d = 1'b1;
          if (tile_total_q > 1)
            state_d   = S_PRE1_LD_I;
          else begin
            tile_cur_d  = 0;
            pre_valid_d = 1'b0;
            waited_reuse_d = 1'b0;
            state_d     = S_WAIT_CUR_TILE_READY;
          end
        end
      end

      // ----------------------------------------------------------------------
      // Warmup preload tile1 (buf1) - SINGLE notify after ZP
      // ----------------------------------------------------------------------
      S_PRE1_LD_I: begin
        if (can_emit) begin
          int unsigned nt1, mt1, kt1;
          tile_decode(1, mt_dim_q, kt_dim_q, nt1, mt1, kt1);
          out_cmd_d   = make_dma_ld(ibuf_base(1'b1),
                                   input_tile_addr(job_q, mt1, kt1),
                                   (MT*KT*2),
                                   1'b1, 1);
          out_start_d = 1'b1;
          state_d     = S_PRE1_LD_W;
        end
      end

      S_PRE1_LD_W: begin
        if (can_emit) begin
          int unsigned nt1, mt1, kt1;
          tile_decode(1, mt_dim_q, kt_dim_q, nt1, mt1, kt1);
          out_cmd_d   = make_dma_ld(wbuf_base(1'b1),
                                   weight_tile_addr(job_q, nt1, kt1),
                                   ((KT*NT)/2),
                                   1'b1, 1);
          out_start_d = 1'b1;
          state_d     = S_PRE1_LD_SC;
        end
      end

      S_PRE1_LD_SC: begin
        if (can_emit) begin
          int unsigned nt1, mt1, kt1;
          int unsigned groups;
          groups = ceil_div(KT, job_q.qblk);

          tile_decode(1, mt_dim_q, kt_dim_q, nt1, mt1, kt1);
          out_cmd_d   = make_dma_ld(pbuf_base(1'b1),
                                   scale_tile_addr(job_q, nt1, kt1),
                                   (groups*NT*4),
                                   1'b1, 1);
          out_start_d = 1'b1;
          state_d     = S_PRE1_LD_ZP;
        end
      end

      S_PRE1_LD_ZP: begin
        if (can_emit) begin
          int unsigned nt1, mt1, kt1;
          int unsigned groups;
          logic [63:0] zp_dst;
          
          groups = ceil_div(KT, job_q.qblk);
          zp_dst = pbuf_base(1'b1) + (groups * NT * 4);

          tile_decode(1, mt_dim_q, kt_dim_q, nt1, mt1, kt1);
          out_cmd_d   = make_dma_ld(zp_dst,
                                   zp_tile_addr(job_q, nt1, kt1),
                                   (groups*NT*1),
                                   1'b1, 1);
          out_start_d = 1'b1;
          state_d     = S_PRE1_LD_DONE_NTF;
        end
      end

      S_PRE1_LD_DONE_NTF: begin
        if (can_emit) begin
          out_cmd_d   = make_notify_cmd(rid_tile(1'b1), (4*1 + 4), 1'b1 /*set*/);
          out_start_d = 1'b1;

          tile_cur_d  = 0;
          tile_pre_d  = 1;
          pre_valid_d = 1'b1;

          waited_reuse_d = 1'b0;

          state_d     = S_WAIT_CUR_TILE_READY;
        end
      end

      // ----------------------------------------------------------------------
      // Wait current tile ready:
      //  1) if gen_cur>1: wait prev store done for buf reuse (RID_O) (1-shot)
      //  2) wait preload complete (RID_T reaches 4*gen+4)
      // ----------------------------------------------------------------------
      S_WAIT_CUR_TILE_READY: begin
        if (can_emit) begin
          if ((gen_cur > 1) && !waited_reuse_q) begin
            out_cmd_d      = make_wait_cmd(rid_o(buf_cur), reuse_target_prev_cur);
            out_start_d    = 1'b1;
            waited_reuse_d = 1'b1;
            state_d        = S_WAIT_CUR_TILE_READY;
          end else begin
            out_cmd_d      = make_wait_cmd(rid_tile(buf_cur), in_ready_target_cur);
            out_start_d    = 1'b1;

            waited_reuse_d = 1'b0;

            nt_mxu_d  = 0;
            kt_mxu_d  = 0;
            mxu_buf_d = 1'b0;

            state_d   = S_MXU_PRE_CUR_W;
          end
        end
      end

      // ----------------------------------------------------------------------
      // MXU preload current W
      // ----------------------------------------------------------------------
      S_MXU_PRE_CUR_W: begin
        if (can_emit) begin
          gemm_unified_cmd_t c;
          logic [7:0] flags;
          c = '0;

          // flags: [.. mxu_buf .. buf_cur]
          // keep same "shape" as your prior W flags: {6'd0, mxu_buf, buf_cur}
          flags     = {6'd0, 1'b0 /*mxu_buf*/, buf_cur};

          c.instr   = make_instr(OP_W_LDMA_MXU, flags, (MXU_KT*(MXU_NT/2)));
          c.rs1_data = 64'd0;         // reserved (no buf index piggyback)
          c.rs2_data = lmem_w_mxu;     // src LMEM
          out_cmd_d   = c;
          out_start_d = 1'b1;
          state_d     = S_MXU_PRE_CUR_W_NTF;
        end
      end

      S_MXU_PRE_CUR_W_NTF: begin
        if (can_emit) begin
          out_cmd_d   = make_notify_cmd(rid_w(buf_cur), (mxu_linear+1), 1'b1 /*set*/);
          out_start_d = 1'b1;
          state_d     = S_MXU_PRE_CUR_SC;
        end
      end

      // ----------------------------------------------------------------------
      // CUR SZ split: SC cmd then ZP cmd (same SZ cmd_queue assumed)
      // ----------------------------------------------------------------------
      S_MXU_PRE_CUR_SC: begin
        if (can_emit) begin
          gemm_unified_cmd_t c;
          logic [7:0] flags;
          int unsigned sc_bytes;

          c = '0;
          sc_bytes = groups_mxu * MXU_NT * 4;

          // put mxu_buf only in flags
          flags     = {5'd0, QDIR_COL_FIXED, 1'b0 /*mxu_buf*/, buf_cur};

          c.instr   = make_instr(OP_SC_LDMA_MXU, flags, sc_bytes);
          c.rs1_data = 64'd0;
          c.rs2_data = lmem_sc_mxu;   // src LMEM scale
          out_cmd_d   = c;
          out_start_d = 1'b1;
          state_d     = S_MXU_PRE_CUR_ZP;
        end
      end

      S_MXU_PRE_CUR_ZP: begin
        if (can_emit) begin
          gemm_unified_cmd_t c;
          logic [7:0] flags;
          int unsigned zp_bytes;

          c = '0;
          zp_bytes = groups_mxu * MXU_NT * 1;

          flags     = {5'd0, QDIR_COL_FIXED, 1'b0 /*mxu_buf*/, buf_cur};

          c.instr   = make_instr(OP_ZP_LDMA_MXU, flags, zp_bytes);
          c.rs1_data = 64'd0;
          c.rs2_data = lmem_zp_mxu;   // src LMEM zp
          out_cmd_d   = c;
          out_start_d = 1'b1;
          state_d     = S_MXU_PRE_CUR_SZ_NTF;
        end
      end

      S_MXU_PRE_CUR_SZ_NTF: begin
        if (can_emit) begin
          // notify after ZP cmd (=> scale cmd is earlier in same queue)
          out_cmd_d   = make_notify_cmd(rid_sz(buf_cur), (mxu_linear+1), 1'b1 /*set*/);
          out_start_d = 1'b1;
          state_d     = S_MXU_WAIT_CUR_W;
        end
      end

      S_MXU_WAIT_CUR_W: begin
        if (can_emit) begin
          out_cmd_d   = make_wait_cmd(rid_w(buf_cur), (mxu_linear+1));
          out_start_d = 1'b1;
          state_d     = S_MXU_WAIT_CUR_SZ;
        end
      end

      S_MXU_WAIT_CUR_SZ: begin
        if (can_emit) begin
          out_cmd_d   = make_wait_cmd(rid_sz(buf_cur), (mxu_linear+1));
          out_start_d = 1'b1;
          state_d     = S_MXU_PRE_NEXT_W;
        end
      end

      // ----------------------------------------------------------------------
      // NEXT W preload into next mxu_buf (ping-pong)
      // ----------------------------------------------------------------------
      S_MXU_PRE_NEXT_W: begin
        if (can_emit) begin
          if (has_next_mxu) begin
            logic next_mxu_buf;
            gemm_unified_cmd_t c;
            logic [7:0] flags;

            next_mxu_buf = ~mxu_buf_q;
            c = '0;

            // **CLEAN**: mxu_buf only in flags, NOT in rs1_data
            flags     = {6'd0, next_mxu_buf, buf_cur};

            c.instr   = make_instr(OP_W_LDMA_MXU, flags, (MXU_KT*(MXU_NT/2)));
            c.rs1_data = 64'd0;
            c.rs2_data = lmem_w_mxu_next;  // src LMEM
            out_cmd_d   = c;
            out_start_d = 1'b1;
            state_d     = S_MXU_PRE_NEXT_W_NTF;
          end else begin
            state_d     = S_MXU_ARM_GEMM;
          end
        end
      end

      S_MXU_PRE_NEXT_W_NTF: begin
        if (can_emit) begin
          out_cmd_d   = make_notify_cmd(rid_w(buf_cur), (next_mxu_linear+1), 1'b1 /*set*/);
          out_start_d = 1'b1;
          state_d     = S_MXU_PRE_NEXT_SC;
        end
      end

      // ----------------------------------------------------------------------
      // NEXT SZ split: SC cmd then ZP cmd (same SZ cmd_queue assumed)
      // ----------------------------------------------------------------------
      S_MXU_PRE_NEXT_SC: begin
        if (can_emit) begin
          if (has_next_mxu) begin
            logic next_mxu_buf;
            gemm_unified_cmd_t c;
            logic [7:0] flags;
            int unsigned sc_bytes;

            next_mxu_buf = ~mxu_buf_q;
            c = '0;
            sc_bytes = groups_mxu * MXU_NT * 4;

            flags     = {5'd0, QDIR_COL_FIXED, next_mxu_buf, buf_cur};

            c.instr   = make_instr(OP_SC_LDMA_MXU, flags, sc_bytes);
            c.rs1_data = 64'd0;
            c.rs2_data = lmem_sc_mxu_next;
            out_cmd_d   = c;
            out_start_d = 1'b1;
            state_d     = S_MXU_PRE_NEXT_ZP;
          end else begin
            state_d = S_MXU_ARM_GEMM;
          end
        end
      end

      S_MXU_PRE_NEXT_ZP: begin
        if (can_emit) begin
          logic next_mxu_buf;
          gemm_unified_cmd_t c;
          logic [7:0] flags;
          int unsigned zp_bytes;

          next_mxu_buf = ~mxu_buf_q;
          c = '0;
          zp_bytes = groups_mxu * MXU_NT * 1;

          flags     = {5'd0, QDIR_COL_FIXED, next_mxu_buf, buf_cur};

          c.instr   = make_instr(OP_ZP_LDMA_MXU, flags, zp_bytes);
          c.rs1_data = 64'd0;
          c.rs2_data = lmem_zp_mxu_next;
          out_cmd_d   = c;
          out_start_d = 1'b1;
          state_d     = S_MXU_PRE_NEXT_SZ_NTF;
        end
      end

      S_MXU_PRE_NEXT_SZ_NTF: begin
        if (can_emit) begin
          if (has_next_mxu) begin
            out_cmd_d   = make_notify_cmd(rid_sz(buf_cur), (next_mxu_linear+1), 1'b1 /*set*/);
            out_start_d = 1'b1;
          end
          state_d     = S_MXU_ARM_GEMM;
        end
      end

      // ----------------------------------------------------------------------
      // ARM: Input LDMA triggers GEMM
      // GEMM completion via rid_g (notify+wait)
      // ----------------------------------------------------------------------
      S_MXU_ARM_GEMM: begin
        if (can_emit) begin
          gemm_unified_cmd_t c;
          logic [7:0] flags;
          int unsigned in_bytes;

          c = '0;

          // flags = {3'd0, QDIR_COL_FIXED, is_last, is_accum, mxu_buf_q, buf_cur};
          flags    = {3'd0, QDIR_COL_FIXED, is_last, is_accum, mxu_buf_q, buf_cur};
          in_bytes = mt_eff_cur * MXU_KT * 2;

          c.instr   = make_instr(OP_I_LDMA_ARM, flags, in_bytes);
          c.rs1_data = lmem_out_slice; // dst/output slice base (or param for GEMM node)
          c.rs2_data = lmem_in_mxu;    // src input
          out_cmd_d   = c;
          out_start_d = 1'b1;

          state_d     = S_MXU_ARM_GEMM_NTF;
        end
      end

      S_MXU_ARM_GEMM_NTF: begin
        if (can_emit) begin
          // routed to same node as OP_I_LDMA_ARM (i_cmd_queue),
          // should occur after GEMM micro-op completes
          out_cmd_d   = make_notify_cmd(rid_g(buf_cur), gemm_done_target, 1'b1 /*set*/);
          out_start_d = 1'b1;
          state_d     = S_MXU_WAIT_GEMM_DONE;
        end
      end

      S_MXU_WAIT_GEMM_DONE: begin
        if (can_emit) begin
          out_cmd_d   = make_wait_cmd(rid_g(buf_cur), gemm_done_target);
          out_start_d = 1'b1;

          if (has_next_mxu) begin
            nt_mxu_d  = n_nt_mxu;
            kt_mxu_d  = n_kt_mxu;
            mxu_buf_d = ~mxu_buf_q;
            state_d   = S_MXU_WAIT_CUR_W;
          end else begin
            state_d   = S_O_KICK_SET;
          end
        end
      end

      // ----------------------------------------------------------------------
      // Output: acc->lmem then lmem->dram
      // ----------------------------------------------------------------------
      S_O_KICK_SET: begin
        if (can_emit) begin
          // rid_o(buf) bookkeeping: base = 2*gen
          // +1 after acc2lmem done, +1 after lmem2dram done
          out_cmd_d   = make_notify_cmd(rid_o(buf_cur), (2*gen_cur), 1'b1 /*set*/);
          out_start_d = 1'b1;
          state_d     = S_O_ACC2LMEM;
        end
      end

      S_O_ACC2LMEM: begin
        if (can_emit) begin
          gemm_unified_cmd_t c;
          logic [7:0] flags;
          int unsigned out_bytes;

          c = '0;
          flags = {7'd0, buf_cur};

          out_bytes = mt_eff_cur * nt_eff_cur * 2;

          c.instr   = make_instr(OP_O_ACC2LMEM, flags, out_bytes);
          c.rs1_data = OBASE_cur;  // LMEM dst base for output tile
          c.rs2_data = 64'd0;

          out_cmd_d   = c;
          out_start_d = 1'b1;
          state_d     = S_O_ACC2LMEM_NTF;
        end
      end

      S_O_ACC2LMEM_NTF: begin
        if (can_emit) begin
          out_cmd_d   = make_notify_cmd(rid_o(buf_cur), 1, 1'b0 /*add*/); // rid_o == 2*gen+1 when done
          out_start_d = 1'b1;
          state_d     = S_O_WAIT_ACC2LMEM_DONE;
        end
      end

      S_O_WAIT_ACC2LMEM_DONE: begin
        if (can_emit) begin
          out_cmd_d   = make_wait_cmd(rid_o(buf_cur), (2*gen_cur + 1));
          out_start_d = 1'b1;
          state_d     = S_O_LMEM2DRAM;
        end
      end

      S_O_LMEM2DRAM: begin
        if (can_emit) begin
          int unsigned out_bytes;
          out_bytes   = mt_eff_cur * nt_eff_cur * 2;
          out_cmd_d   = make_dma_st(out_tile_addr(job_q, mt_cur, nt_cur), OBASE_cur, out_bytes, buf_cur, gen_cur);
          out_start_d = 1'b1;
          state_d     = S_O_LMEM2DRAM_NTF;
        end
      end

      S_O_LMEM2DRAM_NTF: begin
        if (can_emit) begin
          out_cmd_d   = make_notify_cmd(rid_o(buf_cur), 1, 1'b0 /*add*/); // rid_o == 2*gen+2 when done
          out_start_d = 1'b1;
          state_d     = S_ADVANCE_TILES;
        end
      end

      // ----------------------------------------------------------------------
      // Advance tiles
      // ----------------------------------------------------------------------
      S_ADVANCE_TILES: begin
        waited_reuse_d = 1'b0;

        nt_mxu_d  = 0;
        kt_mxu_d  = 0;
        mxu_buf_d = 1'b0;

        if (pre_valid_q) begin
          int unsigned next_tile;

          tile_cur_d = tile_pre_q;
          
          next_tile = tile_pre_q + 1;

          if (next_tile < tile_total_q) begin
            tile_pre_d  = next_tile;
            pre_valid_d = 1'b1;
            state_d     = S_PRE_NEXT_WAIT_REUSE;
          end else begin
            pre_valid_d = 1'b0;
            state_d     = S_WAIT_CUR_TILE_READY;
          end
        end else begin
          state_d = S_IDLE;
        end
      end

      // ----------------------------------------------------------------------
      // Preload next tile into freed buffer (single notify after ZP)
      // ----------------------------------------------------------------------
      S_PRE_NEXT_WAIT_REUSE: begin
        if (can_emit) begin
          logic buf_pre;
          int unsigned gen_pre;

          buf_pre = tile_pre_d[0];
          gen_pre = buf_gen(tile_pre_d);

          if (gen_pre > 1) begin
            int unsigned reuse_target_prev_pre;
            reuse_target_prev_pre = 2*(gen_pre-1) + 2;

            out_cmd_d   = make_wait_cmd(rid_o(buf_pre), reuse_target_prev_pre);
            out_start_d = 1'b1;
          end
          state_d     = S_PRE_NEXT_LD_I;
        end
      end

      S_PRE_NEXT_LD_I: begin
        if (can_emit) begin
          int unsigned ntp, mtp, ktp;
          logic buf_pre;
          int unsigned gen_pre;

          tile_decode(tile_pre_d, mt_dim_q, kt_dim_q, ntp, mtp, ktp);
          buf_pre = tile_pre_d[0];
          gen_pre = buf_gen(tile_pre_d);

          out_cmd_d   = make_dma_ld(ibuf_base(buf_pre), input_tile_addr(job_q, mtp, ktp), (MT*KT*2), buf_pre, gen_pre);
          out_start_d = 1'b1;
          state_d     = S_PRE_NEXT_LD_W;
        end
      end

      S_PRE_NEXT_LD_W: begin
        if (can_emit) begin
          int unsigned ntp, mtp, ktp;
          logic buf_pre;
          int unsigned gen_pre;

          tile_decode(tile_pre_d, mt_dim_q, kt_dim_q, ntp, mtp, ktp);
          buf_pre = tile_pre_d[0];
          gen_pre = buf_gen(tile_pre_d);

          out_cmd_d   = make_dma_ld(wbuf_base(buf_pre), weight_tile_addr(job_q, ntp, ktp), ((KT*NT)/2), buf_pre, gen_pre);
          out_start_d = 1'b1;
          state_d     = S_PRE_NEXT_LD_SC;
        end
      end

      S_PRE_NEXT_LD_SC: begin
        if (can_emit) begin
          int unsigned ntp, mtp, ktp;
          logic buf_pre;
          int unsigned gen_pre;
          int unsigned groups;

          tile_decode(tile_pre_d, mt_dim_q, kt_dim_q, ntp, mtp, ktp);
          buf_pre = tile_pre_d[0];
          gen_pre = buf_gen(tile_pre_d);

          groups = ceil_div(KT, job_q.qblk);
          out_cmd_d   = make_dma_ld(pbuf_base(buf_pre), scale_tile_addr(job_q, ntp, ktp), (groups*NT*4), buf_pre, gen_pre);
          out_start_d = 1'b1;
          state_d     = S_PRE_NEXT_LD_ZP;
        end
      end

      S_PRE_NEXT_LD_ZP: begin
        if (can_emit) begin
          int unsigned ntp, mtp, ktp;
          logic buf_pre;
          int unsigned gen_pre;
          int unsigned groups;
          logic [63:0] zp_dst;

          tile_decode(tile_pre_d, mt_dim_q, kt_dim_q, ntp, mtp, ktp);
          buf_pre = tile_pre_d[0];
          gen_pre = buf_gen(tile_pre_d);

          groups = ceil_div(KT, job_q.qblk);
          zp_dst = pbuf_base(buf_pre) + (groups * NT * 4);

          out_cmd_d   = make_dma_ld(zp_dst, zp_tile_addr(job_q, ntp, ktp), (groups*NT*1), buf_pre, gen_pre);
          out_start_d = 1'b1;
          state_d     = S_PRE_NEXT_LD_DONE_NTF;
        end
      end

      S_PRE_NEXT_LD_DONE_NTF: begin
        if (can_emit) begin
          logic buf_pre;
          int unsigned gen_pre;

          buf_pre = tile_pre_d[0];
          gen_pre = buf_gen(tile_pre_d);

          // SINGLE notify meaning: "this preload fully done"
          out_cmd_d   = make_notify_cmd(rid_tile(buf_pre), (4*gen_pre + 4), 1'b1 /*set*/);
          out_start_d = 1'b1;
          state_d     = S_WAIT_CUR_TILE_READY;
        end
      end

      default: state_d = S_IDLE;

    endcase
  end

endmodule
