`include "VX_define.vh"

module VX_gemm_fsm import VX_gpu_pkg::*; #(
    parameter `STRING INSTANCE_ID = ""
) (
    input  wire              clk,
    input  wire              reset,

    VX_config_reg_if.slave   cfg_reg_if,
    VX_gemm_fsm_if.master    gemm_fsm_if
);

  /*
  cfg_reg 레지스터
    [0] : control reg (LSB가 start bit)
    [1] : INPUT_BASE (DRAM)
    [2] : WEIGHT_BASE (DRAM)
    [3] : OUTPUT_BASE (DRAM)
    [4] : SCALE_BASE (DRAM)
    [5] : ZP_BASE (DRAM)
    [6] : {N, M}
    [7] : {qblk, K}
    [8] : {input stride0, input bnd0} (DRAM 쪽 레이아웃)
    [9] : {input stride1, input bnd1}
    [10]: {input stride2, input bnd2}
    [11]: {weight stride0, weight bnd0}
    [12]: {weight stride1, weight bnd1}
    [13]: {weight stride2, weight bnd2}
    [14]: {output stride0, output bnd0}
    [15]: {output stride1, output bnd1}
    [16]: {output stride2, output bnd2}
    [17]: {scale stride0, zp stride0}  //weight bnd0 공유
    [18]: {scale stride1, zp stride1}  //weight bnd1 공유
    [19]: {scale stride2, zp stride2}  //weight bnd2 공유
  */
  
  /*
  ================================================================================
  VX_gemm_fsm.sv — Bring-up FSM Assumptions / Contract
  ================================================================================

  [1] Scope / Feature gating (bring-up fixed)
  - Quantization direction(QDIR_COL) = column-wise 로 "고정" (QDIR_COL=1).
  - weight transpose 기능은 사용하지 않음 (W_TP_FIXED=0), 관련 address/layout 분기 없음.
  - bias 사용하지 않음 (IS_BIAS_FIXED=0), bias DMA/LDMA 경로 없음.
  - activation = fp16, weight = int4(packed), scale = fp32, zp = int8 를 가정.

  [2] Tiling parameters are compile-time constants
  - DMA tile: MT=128, NT=128, KT=128 로 고정.
  - MXU micro tile: MXU_KT=32, MXU_NT=128 로 고정. (바뀔수도 있지만 컴파일 타임에 고정됨)
  - KT는 MXU_KT로 정확히 나누어떨어진다고 가정 (kt_mxu_dim = kt_eff_cur / MXU_KT, remainder 미지원).
  - NT 역시 MXU_NT 단위로 쪼개되며 마지막 N-tile은 nt_eff로 처리.

  [3] Memory map / base addresses are fixed and valid
  - LMEM의 double-buffer base 주소(IBUF/WBUF/OBUF/PBUF)는 localparam으로 "고정"되어 있다고 가정.
    (LMEM_*_BASE 값들이 서로 겹치지 않고, 각 영역 크기가 충분하며, alignment 요구사항도 만족)
  - PBUF는 "scale 영역 + zp 영역"이 한 덩어리로 배치됨:
    - PBUF[0 .. groups_full*NT*4 - 1]      : scale(fp32) 저장
    - PBUF[groups_full*NT*4 .. ]           : zp(int8) 저장
    - 여기서 groups_full = ceil_div(KT, qblk) (stride/packing 기준은 항상 full KT)

  [4] DRAM layout/stride assumptions
  - DRAM 타일 주소 계산은 "full-tile stride" 기반으로 고정:
    input_tile_addr : input_base + tile_idx*(MT*KT*2)      (fp16)
    weight_tile_addr: weight_base+ tile_idx*((KT*NT)/2)    (int4 packed)
    scale_tile_addr : scale_base + tile_idx*(groups_full*NT*4) (fp32)
    zp_tile_addr    : zp_base    + tile_idx*(groups_full*NT*1) (int8)
    out_tile_addr   : output_base+ tile_idx*(MT*NT*2)       (fp16)
  - 즉, 마지막 타일이 부분타일이어도 "DRAM 상 stride(다음 타일 시작 주소 간격)"는 full tile 기준이며,
    DMA size만 kt_eff/nt_eff/mt_eff로 줄여 읽고/쓴다. (padding/compact layout은 미지원)

  [5] Quantization block(qblk) 관련 가정
  - MXU 단에서는 groups_mxu = ceil_div(MXU_KT, qblk)를 사용하며,
    일반적으로 qblk=32, MXU_KT=32 => groups_mxu=1을 기대.
  - PBUF 내 scale/zp 오프셋은 "mxu_linear(= MXU_NT × MXU_KT) 단위로 연속 배치"된다고 가정.

  [6] Command interface / backpressure model
  - gemm_fsm_if.flag.idle 이 "1이면 한 사이클에 1개의 cmd를 안전하게 발행 가능"하다고 가정.
    (즉, ready/valid 형태가 아니라 idle-based gating으로 구현됨)

  [7] Sync semantics (WAIT/NOTIFY contract)
  - Sync 모듈/레지스터 파일이 존재하며, 다음 semantics를 가정:
    - WAIT(reg_id, target): sync_reg[reg_id] >= target 일 때 통과
    - NOTIFY(reg_id, value, set_mode):
        set_mode=1 => sync_reg[reg_id] = value
        set_mode=0 => sync_reg[reg_id] += value
  - RID_* 레지스터 할당은 일단 10개이며, buf_sel(0/1)에 따라 reg_id가 분리됨.
  - DMA tile preload done은 "SINGLE notify after ZP"로 표시
    (즉, input/weight/scale/zp 4단계 ldma 후에 한 번만 notify).
  - output 쪽은 rid_o(buf)를
    (2*gen)으로 set 후 acc2lmem done(+1), lmem2dram done(+1)로 총 2번 add하여
    (2*gen+2)에 도달하는 시퀀스를 가정.

  [8] GEMM completion 모델 가정
  - gemm 연산이 끝나면 sync 모듈로 끝났다는 신호를 보낸다.
  - 즉 i_l_dma에서 sync_if 가 나가는 길이 gemm 연산이 끝났다는 신호라고 가정.

  ================================================================================
  */

  // --------------------------------------------------------------------------
  // Bring-up fixed (QDIR_COL, weight transpose 없음, is_bias 없음)
  // --------------------------------------------------------------------------
  localparam logic QDIR_COL  = 1'b1;
  localparam logic W_TP_FIXED      = 1'b0; // unused in this bring-up stream
  localparam logic IS_BIAS_FIXED   = 1'b0; // unused in this bring-up stream

  // DMA tile sizes
  localparam int MT = 128;
  localparam int NT = 128;
  localparam int KT = 128;

  // MXU micro tile sizes (kernel: 32x32)
  localparam int MXU_KT = 32;
  localparam int MXU_NT = 32;

  // --------------------------------------------------------------------------
  // LMEM base addresses (DMA tile double buffering), 고정이라고 가정
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
  // Sync register assignment (10 regs; per DMA buf), sync 레지스터 번호
  // --------------------------------------------------------------------------
  localparam int RID_T0  = 0, RID_W0  = 1, RID_SZ0 = 2, RID_G0 = 3, RID_O0 = 4;
  localparam int RID_T1  = 5, RID_W1  = 6, RID_SZ1 = 7, RID_G1 = 8, RID_O1 = 9;

  function automatic int rid_tile   (input logic buf_sel);  return buf_sel ? RID_T1  : RID_T0;  endfunction  // dma tile preload done
  function automatic int rid_w_mxu  (input logic mxu_buf);  return mxu_buf ? RID_W1  : RID_W0;  endfunction  // mxu weight preload done
  function automatic int rid_sz_mxu (input logic mxu_buf);  return mxu_buf ? RID_SZ1 : RID_SZ0; endfunction  // mxu scale/zp preload done (after ZP cmd)
  function automatic int rid_g_mxu  (input logic mxu_buf);  return mxu_buf ? RID_G1  : RID_G0;  endfunction  // gemm done marker (per microtile)
  function automatic int rid_o      (input logic buf_sel);  return buf_sel ? RID_O1  : RID_O0;  endfunction  // output store done marker

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
      t.rs1_data = {{(`XLEN-8){1'b0}}, reg_id[7:0]};
      t.rs2_data = {{(`XLEN-32){1'b0}}, set_mode, value[30:0]};
      return t;
    end
  endfunction

  function automatic gemm_unified_cmd_t make_dma_ld(
    input logic [`XLEN-1:0] lmem_dst,
    input logic [`XLEN-1:0] dram_src,
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
    input logic [`XLEN-1:0] dram_dst,
    input logic [`XLEN-1:0] lmem_src,
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
  // **NEW**: per-tile effective sizes (use kt_eff for DMA sizes)
  // --------------------------------------------------------------------------
  task automatic tile_eff_sizes(
    input  int unsigned nt,
    input  int unsigned mt,
    input  int unsigned kt,
    output int unsigned mt_eff,
    output int unsigned nt_eff,
    output int unsigned kt_eff
  );
    begin
      mt_eff = (mt == mt_dim_q-1) ? m_last_q : MT;
      nt_eff = (nt == nt_dim_q-1) ? n_last_q : NT;
      kt_eff = (kt == kt_dim_q-1) ? k_last_q : KT;
    end
  endtask

  // --------------------------------------------------------------------------
  // DRAM address helpers (stride kept at full-tile layout, like your C code)
  // --------------------------------------------------------------------------
  function automatic logic [63:0] input_tile_addr(input job_t j, input int unsigned mt, input int unsigned kt);
    int unsigned tile_idx;
    begin
      tile_idx = kt + mt * kt_dim_q;
      input_tile_addr = j.input_base + tile_idx * (MT*KT*2); // fp16, fixed stride
    end
  endfunction

  function automatic logic [63:0] weight_tile_addr(input job_t j, input int unsigned nt, input int unsigned kt);
    int unsigned tile_idx;
    begin
      // weight_transposed=0 fixed
      tile_idx = nt + kt * nt_dim_q;
      weight_tile_addr = j.weight_base + tile_idx * ((KT*NT)/2); // int4 packed, fixed stride
    end
  endfunction

  function automatic logic [63:0] scale_tile_addr(input job_t j, input int unsigned nt, input int unsigned kt);
    int unsigned tile_idx;
    int unsigned groups_full;
    begin
      groups_full = ceil_div(KT, j.qblk);              // fixed stride per KT-tile (C code style)
      tile_idx    = nt + kt * nt_dim_q;
      scale_tile_addr = j.scale_base + tile_idx * (groups_full*NT*4); // fp32
    end
  endfunction

  function automatic logic [63:0] zp_tile_addr(input job_t j, input int unsigned nt, input int unsigned kt);
    int unsigned tile_idx;
    int unsigned groups_full;
    begin
      groups_full = ceil_div(KT, j.qblk);              // fixed stride per KT-tile (C code style)
      tile_idx    = nt + kt * nt_dim_q;
      zp_tile_addr = j.zp_base + tile_idx * (groups_full*NT*1); // int8
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

  assign tile_total_q = ceil_div(job_d.N, NT) * ceil_div(job_d.M, MT) * ceil_div(job_d.K, KT);
  
  // --------------------------------------------------------------------------
  // sequential
  // --------------------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (reset) begin
      state_q <= S_IDLE;

      job_q <= '0;
      mt_dim_q <= 0; nt_dim_q <= 0; kt_dim_q <= 0;
      m_last_q <= 0; n_last_q <= 0; k_last_q <= 0;

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

      if (state_q == S_IDLE && cfg_reg_if.regs[0][0] && cfg_reg_if.valid && cfg_reg_if.ready) begin
        mt_dim_q <= ceil_div(job_d.M, MT);
        nt_dim_q <= ceil_div(job_d.N, NT);
        kt_dim_q <= ceil_div(job_d.K, KT);

        m_last_q <= job_d.M - (ceil_div(job_d.M, MT)-1) * MT;
        n_last_q <= job_d.N - (ceil_div(job_d.N, NT)-1) * NT;
        k_last_q <= job_d.K - (ceil_div(job_d.K, KT)-1) * KT;
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

    // NOTE:
    // - groups_tile uses full KT stride (like C code's zp_shared offset).
    // - groups_mxu is per-microtile group count; for qblk=32 & MXU_KT=32 => 1.
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

        if (cfg_reg_if.regs[0][0] && cfg_reg_if.valid) begin
          job_d.input_base  = cfg_reg_if.regs[1];
          job_d.weight_base = cfg_reg_if.regs[2];
          job_d.output_base = cfg_reg_if.regs[3];
          job_d.scale_base  = cfg_reg_if.regs[4];
          job_d.zp_base     = cfg_reg_if.regs[5];

          job_d.M           = cfg_reg_if.regs[6][31:0];
          job_d.N           = cfg_reg_if.regs[6][63:32];
          job_d.K           = cfg_reg_if.regs[7][31:0];
          job_d.qblk        = cfg_reg_if.regs[7][63:32];

          state_d = S_PRE0_LD_I;
        end
      end

      // ----------------------------------------------------------------------
      // Warmup preload tile0 (buf0) - SINGLE notify after ZP
      // use kt_eff for DMA sizes (but keep DRAM stride addresses)
      // ----------------------------------------------------------------------
      S_PRE0_LD_I: begin
        if (can_emit) begin
          int unsigned nt0, mt0, kt0;
          int unsigned mt_eff0, nt_eff0, kt_eff0;
          tile_decode(0, mt_dim_q, kt_dim_q, nt0, mt0, kt0);
          tile_eff_sizes(nt0, mt0, kt0, mt_eff0, nt_eff0, kt_eff0);

          out_cmd_d   = make_dma_ld(ibuf_base(1'b0),
                                   input_tile_addr(job_q, /*mt*/mt0, /*kt*/kt0),
                                   (mt_eff0*kt_eff0*2),
                                   1'b0, 1);
          out_start_d = 1'b1;
          state_d     = S_PRE0_LD_W;
        end
      end

      S_PRE0_LD_W: begin
        if (can_emit) begin
          int unsigned nt0, mt0, kt0;
          int unsigned mt_eff0, nt_eff0, kt_eff0;
          tile_decode(0, mt_dim_q, kt_dim_q, nt0, mt0, kt0);
          tile_eff_sizes(nt0, mt0, kt0, mt_eff0, nt_eff0, kt_eff0);

          out_cmd_d   = make_dma_ld(wbuf_base(1'b0),
                                   weight_tile_addr(job_q, nt0, kt0),
                                   (kt_eff0*(nt_eff0/2)),
                                   1'b0, 1);
          out_start_d = 1'b1;
          state_d     = S_PRE0_LD_SC;
        end
      end

      S_PRE0_LD_SC: begin
        if (can_emit) begin
          int unsigned nt0, mt0, kt0;
          int unsigned mt_eff0, nt_eff0, kt_eff0;
          int unsigned groups_eff, groups_full;
          tile_decode(0, mt_dim_q, kt_dim_q, nt0, mt0, kt0);
          tile_eff_sizes(nt0, mt0, kt0, mt_eff0, nt_eff0, kt_eff0);

          groups_eff  = ceil_div(kt_eff0, job_q.qblk);
          groups_full = ceil_div(KT,     job_q.qblk);  // stride / zp packing

          out_cmd_d   = make_dma_ld(pbuf_base(1'b0),
                                   scale_tile_addr(job_q, nt0, kt0),
                                   (groups_eff*nt_eff0*4),
                                   1'b0, 1);
          out_start_d = 1'b1;
          state_d     = S_PRE0_LD_ZP;
        end
      end

      S_PRE0_LD_ZP: begin
        if (can_emit) begin
          int unsigned nt0, mt0, kt0;
          int unsigned mt_eff0, nt_eff0, kt_eff0;
          int unsigned groups_eff, groups_full;
          logic [63:0] zp_dst;
          tile_decode(0, mt_dim_q, kt_dim_q, nt0, mt0, kt0);
          tile_eff_sizes(nt0, mt0, kt0, mt_eff0, nt_eff0, kt_eff0);

          groups_eff  = ceil_div(kt_eff0, job_q.qblk);
          groups_full = ceil_div(KT,     job_q.qblk);  // keep zp after full-scale region
          zp_dst      = pbuf_base(1'b0) + (groups_full * NT * 4);

          out_cmd_d   = make_dma_ld(zp_dst,
                                   zp_tile_addr(job_q, nt0, kt0),
                                   (groups_eff*nt_eff0*1),
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
      // use kt_eff for DMA sizes (and nt_eff for last-N tile)
      // ----------------------------------------------------------------------
      S_PRE1_LD_I: begin
        if (can_emit) begin
          int unsigned nt1, mt1, kt1;
          int unsigned mt_eff1, nt_eff1, kt_eff1;
          tile_decode(1, mt_dim_q, kt_dim_q, nt1, mt1, kt1);
          tile_eff_sizes(nt1, mt1, kt1, mt_eff1, nt_eff1, kt_eff1);

          out_cmd_d   = make_dma_ld(ibuf_base(1'b1),
                                   input_tile_addr(job_q, mt1, kt1),
                                   (mt_eff1*kt_eff1*2),
                                   1'b1, 1);
          out_start_d = 1'b1;
          state_d     = S_PRE1_LD_W;
        end
      end

      S_PRE1_LD_W: begin
        if (can_emit) begin
          int unsigned nt1, mt1, kt1;
          int unsigned mt_eff1, nt_eff1, kt_eff1;
          tile_decode(1, mt_dim_q, kt_dim_q, nt1, mt1, kt1);
          tile_eff_sizes(nt1, mt1, kt1, mt_eff1, nt_eff1, kt_eff1);

          out_cmd_d   = make_dma_ld(wbuf_base(1'b1),
                                   weight_tile_addr(job_q, nt1, kt1),
                                   (kt_eff1*(nt_eff1/2)),
                                   1'b1, 1);
          out_start_d = 1'b1;
          state_d     = S_PRE1_LD_SC;
        end
      end

      S_PRE1_LD_SC: begin
        if (can_emit) begin
          int unsigned nt1, mt1, kt1;
          int unsigned mt_eff1, nt_eff1, kt_eff1;
          int unsigned groups_eff, groups_full;
          tile_decode(1, mt_dim_q, kt_dim_q, nt1, mt1, kt1);
          tile_eff_sizes(nt1, mt1, kt1, mt_eff1, nt_eff1, kt_eff1);

          groups_eff  = ceil_div(kt_eff1, job_q.qblk);
          groups_full = ceil_div(KT,     job_q.qblk);

          out_cmd_d   = make_dma_ld(pbuf_base(1'b1),
                                   scale_tile_addr(job_q, nt1, kt1),
                                   (groups_eff*nt_eff1*4),
                                   1'b1, 1);
          out_start_d = 1'b1;
          state_d     = S_PRE1_LD_ZP;
        end
      end

      S_PRE1_LD_ZP: begin
        if (can_emit) begin
          int unsigned nt1, mt1, kt1;
          int unsigned mt_eff1, nt_eff1, kt_eff1;
          int unsigned groups_eff, groups_full;
          logic [63:0] zp_dst;

          tile_decode(1, mt_dim_q, kt_dim_q, nt1, mt1, kt1);
          tile_eff_sizes(nt1, mt1, kt1, mt_eff1, nt_eff1, kt_eff1);

          groups_eff  = ceil_div(kt_eff1, job_q.qblk);
          groups_full = ceil_div(KT,     job_q.qblk);
          zp_dst      = pbuf_base(1'b1) + (groups_full * NT * 4);

          out_cmd_d   = make_dma_ld(zp_dst,
                                   zp_tile_addr(job_q, nt1, kt1),
                                   (groups_eff*nt_eff1*1),
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

          flags     = {6'd0, mxu_buf_q, buf_cur};

          c.instr   = make_instr(OP_W_LDMA_MXU, flags, (MXU_KT*(MXU_NT/2)));
          c.rs1_data = 64'd0;
          c.rs2_data = lmem_w_mxu;
          out_cmd_d   = c;
          out_start_d = 1'b1;
          state_d     = S_MXU_PRE_CUR_W_NTF;
        end
      end

      S_MXU_PRE_CUR_W_NTF: begin
        if (can_emit) begin
          out_cmd_d   = make_notify_cmd(rid_w_mxu(mxu_buf_q), (mxu_linear+1), 1'b1 /*set*/);
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

          flags     = {5'd0, QDIR_COL, mxu_buf_q, buf_cur};

          c.instr   = make_instr(OP_SC_LDMA_MXU, flags, sc_bytes);
          c.rs1_data = 64'd0;
          c.rs2_data = lmem_sc_mxu;
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

          flags     = {5'd0, QDIR_COL, mxu_buf_q, buf_cur};

          c.instr   = make_instr(OP_ZP_LDMA_MXU, flags, zp_bytes);
          c.rs1_data = 64'd0;
          c.rs2_data = lmem_zp_mxu;
          out_cmd_d   = c;
          out_start_d = 1'b1;
          state_d     = S_MXU_PRE_CUR_SZ_NTF;
        end
      end

      S_MXU_PRE_CUR_SZ_NTF: begin
        if (can_emit) begin
          out_cmd_d   = make_notify_cmd(rid_sz_mxu(mxu_buf_q), (mxu_linear+1), 1'b1 /*set*/);
          out_start_d = 1'b1;
          state_d     = S_MXU_WAIT_CUR_W;
        end
      end

      S_MXU_WAIT_CUR_W: begin
        if (can_emit) begin
          out_cmd_d   = make_wait_cmd(rid_w_mxu(mxu_buf_q), (mxu_linear+1));
          out_start_d = 1'b1;
          state_d     = S_MXU_WAIT_CUR_SZ;
        end
      end

      S_MXU_WAIT_CUR_SZ: begin
        if (can_emit) begin
          out_cmd_d   = make_wait_cmd(rid_sz_mxu(mxu_buf_q), (mxu_linear+1));
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

            flags     = {6'd0, next_mxu_buf, buf_cur};

            c.instr   = make_instr(OP_W_LDMA_MXU, flags, (MXU_KT*(MXU_NT/2)));
            c.rs1_data = 64'd0;
            c.rs2_data = lmem_w_mxu_next;
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
          out_cmd_d   = make_notify_cmd(rid_w_mxu(~mxu_buf_q), (next_mxu_linear+1), 1'b1 /*set*/);
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

            flags     = {5'd0, QDIR_COL, next_mxu_buf, buf_cur};

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

          flags     = {5'd0, QDIR_COL, next_mxu_buf, buf_cur};

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
            out_cmd_d   = make_notify_cmd(rid_sz_mxu(~mxu_buf_q), (next_mxu_linear+1), 1'b1 /*set*/);
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

          flags    = {3'd0, QDIR_COL, is_last, is_accum, mxu_buf_q, buf_cur};
          in_bytes = mt_eff_cur * MXU_KT * 2;

          c.instr   = make_instr(OP_I_LDMA_ARM, flags, in_bytes);
          c.rs1_data = lmem_out_slice;
          c.rs2_data = lmem_in_mxu;
          out_cmd_d   = c;
          out_start_d = 1'b1;

          state_d     = S_MXU_ARM_GEMM_NTF;
        end
      end

      S_MXU_ARM_GEMM_NTF: begin
        if (can_emit) begin
          out_cmd_d   = make_notify_cmd(rid_g_mxu(mxu_buf_q), gemm_done_target, 1'b1 /*set*/);
          out_start_d = 1'b1;
          state_d     = S_MXU_WAIT_GEMM_DONE;
        end
      end

      S_MXU_WAIT_GEMM_DONE: begin
        if (can_emit) begin
          out_cmd_d   = make_wait_cmd(rid_g_mxu(mxu_buf_q), gemm_done_target);
          out_start_d = 1'b1;

          if (has_next_mxu) begin
            nt_mxu_d  = n_nt_mxu;
            kt_mxu_d  = n_kt_mxu;
            mxu_buf_d = ~mxu_buf_q;
            state_d   = S_MXU_WAIT_CUR_W;
          end else begin
            state_d   = S_O_ACC2LMEM;
          end
        end
      end

      // ----------------------------------------------------------------------
      // Output: acc->lmem then lmem->dram
      // ----------------------------------------------------------------------

      S_O_ACC2LMEM: begin
        if (can_emit) begin
          gemm_unified_cmd_t c;
          logic [7:0] flags;
          int unsigned out_bytes;

          c = '0;
          flags = {7'd0, buf_cur};

          out_bytes = mt_eff_cur * nt_eff_cur * 2;

          c.instr   = make_instr(OP_O_ACC2LMEM, flags, out_bytes);
          c.rs1_data = OBASE_cur;
          c.rs2_data = 64'd0;

          out_cmd_d   = c;
          out_start_d = 1'b1;
          state_d     = S_O_ACC2LMEM_NTF;
        end
      end

      S_O_ACC2LMEM_NTF: begin
        if (can_emit) begin
          out_cmd_d   = make_notify_cmd(rid_o(buf_cur), (2*gen_cur + 1), 1'b1 /*set*/);
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
          out_cmd_d   = make_notify_cmd(rid_o(buf_cur), 1, 1'b0 /*add*/);
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
      // use kt_eff for DMA sizes
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
          int unsigned mt_effp, nt_effp, kt_effp;
          logic buf_pre;
          int unsigned gen_pre;

          tile_decode(tile_pre_d, mt_dim_q, kt_dim_q, ntp, mtp, ktp);
          tile_eff_sizes(ntp, mtp, ktp, mt_effp, nt_effp, kt_effp);
          buf_pre = tile_pre_d[0];
          gen_pre = buf_gen(tile_pre_d);

          out_cmd_d   = make_dma_ld(ibuf_base(buf_pre), input_tile_addr(job_q, mtp, ktp), (mt_effp*kt_effp*2), buf_pre, gen_pre);
          out_start_d = 1'b1;
          state_d     = S_PRE_NEXT_LD_W;
        end
      end

      S_PRE_NEXT_LD_W: begin
        if (can_emit) begin
          int unsigned ntp, mtp, ktp;
          int unsigned mt_effp, nt_effp, kt_effp;
          logic buf_pre;
          int unsigned gen_pre;

          tile_decode(tile_pre_d, mt_dim_q, kt_dim_q, ntp, mtp, ktp);
          tile_eff_sizes(ntp, mtp, ktp, mt_effp, nt_effp, kt_effp);
          buf_pre = tile_pre_d[0];
          gen_pre = buf_gen(tile_pre_d);

          out_cmd_d   = make_dma_ld(wbuf_base(buf_pre), weight_tile_addr(job_q, ntp, ktp), (kt_effp*(nt_effp/2)), buf_pre, gen_pre);
          out_start_d = 1'b1;
          state_d     = S_PRE_NEXT_LD_SC;
        end
      end

      S_PRE_NEXT_LD_SC: begin
        if (can_emit) begin
          int unsigned ntp, mtp, ktp;
          int unsigned mt_effp, nt_effp, kt_effp;
          logic buf_pre;
          int unsigned gen_pre;
          int unsigned groups_eff;

          tile_decode(tile_pre_d, mt_dim_q, kt_dim_q, ntp, mtp, ktp);
          tile_eff_sizes(ntp, mtp, ktp, mt_effp, nt_effp, kt_effp);
          buf_pre = tile_pre_d[0];
          gen_pre = buf_gen(tile_pre_d);

          groups_eff = ceil_div(kt_effp, job_q.qblk);

          out_cmd_d   = make_dma_ld(pbuf_base(buf_pre), scale_tile_addr(job_q, ntp, ktp), (groups_eff*nt_effp*4), buf_pre, gen_pre);
          out_start_d = 1'b1;
          state_d     = S_PRE_NEXT_LD_ZP;
        end
      end

      S_PRE_NEXT_LD_ZP: begin
        if (can_emit) begin
          int unsigned ntp, mtp, ktp;
          int unsigned mt_effp, nt_effp, kt_effp;
          logic buf_pre;
          int unsigned gen_pre;
          int unsigned groups_eff, groups_full;
          logic [63:0] zp_dst;

          tile_decode(tile_pre_d, mt_dim_q, kt_dim_q, ntp, mtp, ktp);
          tile_eff_sizes(ntp, mtp, ktp, mt_effp, nt_effp, kt_effp);
          buf_pre = tile_pre_d[0];
          gen_pre = buf_gen(tile_pre_d);

          groups_eff  = ceil_div(kt_effp, job_q.qblk);
          groups_full = ceil_div(KT,     job_q.qblk);
          zp_dst      = pbuf_base(buf_pre) + (groups_full * NT * 4);

          out_cmd_d   = make_dma_ld(zp_dst, zp_tile_addr(job_q, ntp, ktp), (groups_eff*nt_effp*1), buf_pre, gen_pre);
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

          out_cmd_d   = make_notify_cmd(rid_tile(buf_pre), (4*gen_pre + 4), 1'b1 /*set*/);
          out_start_d = 1'b1;
          state_d     = S_WAIT_CUR_TILE_READY;
        end
      end

      default: state_d = S_IDLE;

    endcase
  end

endmodule
