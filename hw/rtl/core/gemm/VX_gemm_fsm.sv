`include "VX_define.vh"

module VX_gemm_fsm import VX_gpu_pkg::*; #(
    parameter `STRING INSTANCE_ID = ""
) (
    input  wire              clk,
    input  wire              reset,

    VX_config_reg_if.slave   cfg_reg_if,
    VX_gemm_fsm_if.master    gemm_fsm_if,
    output logic gemm_start_o
);

  /*
  gemm_node cfg_reg 레지스터 맵 (32b regs):
    [ 0] CONTROL (bit0=start)
    [ 1] INPUT_BASE_LO
    [ 2] INPUT_BASE_HI
    [ 3] WEIGHT_BASE_LO
    [ 4] WEIGHT_BASE_HI
    [ 5] OUTPUT_BASE_LO
    [ 6] OUTPUT_BASE_HI
    [ 7] SCALE_BASE_LO
    [ 8] SCALE_BASE_HI
    [ 9] ZP_BASE_LO
    [10] ZP_BASE_HI

    [11] LMEM_IBUF0_BASE_LO
    [12] LMEM_IBUF0_BASE_HI
    [13] LMEM_IBUF1_BASE_LO
    [14] LMEM_IBUF1_BASE_HI
    [15] LMEM_WBUF0_BASE_LO
    [16] LMEM_WBUF0_BASE_HI
    [17] LMEM_WBUF1_BASE_LO
    [18] LMEM_WBUF1_BASE_HI
    [19] LMEM_SCBUF0_BASE_LO
    [20] LMEM_SCBUF0_BASE_HI
    [21] LMEM_SCBUF1_BASE_LO
    [22] LMEM_SCBUF1_BASE_HI
    [23] LMEM_ZPBUF0_BASE_LO
    [24] LMEM_ZPBUF0_BASE_HI
    [25] LMEM_ZPBUF1_BASE_LO
    [26] LMEM_ZPBUF1_BASE_HI
    [27] LMEM_OBUF_BASE_LO
    [28] LMEM_OBUF_BASE_HI

    [29] M_ORIG (32b)
    [30] N_ORIG (32b)
    [31] K_ORIG (32b)
    [32] QBLK_ORIG (32b)
    [33] M_TARGET (32b)
    [34] N_TARGET (32b)
    [35] K_TARGET (32b)
    [36] M_START (32b)
    [37] N_START (32b)
  
  ================================================================================
  VX_gemm_fsm.sv — Bring-up FSM Assumptions / Contract
  ================================================================================

  [1] Scope / Feature gating (bring-up fixed)
  - Quantization direction(QDIR_COL) = column-wise 로 "고정" (QDIR_COL=0).
  - weight transpose는 cfg register(CFG_R_WTRANS)로 제어.
  - bias 사용하지 않음 (IS_BIAS_FIXED=0), bias DMA/LDMA 경로 없음.
  - activation = fp16, weight = int4(packed), scale = fp16, zp = int16 를 가정.

  [2] Tiling parameters are compile-time constants
  - DMA tile: MT=128, NT=128, KT=128 로 고정.
  - MXU micro tile: MXU_KT=32, MXU_NT=32 로 고정. (바뀔수도 있지만 컴파일 타임에 고정됨)
  - KT는 MXU_KT로 정확히 나누어떨어진다고 가정 (kt_mxu_dim = kt_eff_cur / MXU_KT, remainder 미지원).
  - NT 역시 MXU_NT 단위로 쪼개되며 마지막 N-tile은 nt_eff로 처리.

  [3] Memory map / base addresses are fixed and valid
  - LMEM의 double-buffer base 주소(IBUF0,1/WBUF0,1/SCBUF0,1/ZPBUF0,1/OBUF)는 config register로부터 들어온다고 가정.
    (LMEM_*_BASE 값들이 서로 겹치지 않고, 각 영역 크기가 충분하다고 가정)
  - SZBUF는 "scale 영역 + zp 영역"이 한 덩어리로 배치됨:
    - SZBUF[0 .. groups_full*NT*2 - 1]      : scale(fp16) 저장
    - SZBUF[groups_full*NT*2 .. ]           : zp(int16) 저장
    - 여기서 groups_full = ceil_div(KT, qblk)

  [4] DRAM layout/stride assumptions
  - DRAM 타일 주소 계산은 "full-tile stride" 기반으로 고정:
    input_tile_addr : input_base + tile_idx*(MT*KT*2)      (fp16)
    weight_tile_addr: weight_base+ tile_idx*((KT*NT)/2)    (int4 packed)
    scale_tile_addr : scale_base + tile_idx*(groups_full*NT*2) (fp16)
    zp_tile_addr    : zp_base    + tile_idx*(groups_full*NT*2) (int16)
    out_tile_addr   : output_base+ tile_idx*(MT*NT*2)       (fp16)
  - 즉, 마지막 타일이 부분타일이어도 "DRAM 상 stride(다음 타일 시작 주소 간격)"는 full tile 기준이며,
    DMA size만 kt_eff/nt_eff/mt_eff로 줄여 읽고/쓴다.

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
  - RID_* 레지스터 할당은 일단 9개이며, buf_sel(0/1)에 따라 reg_id가 분리됨.
  - DMA tile preload done은 "SINGLE notify after ZP"로 표시
    (즉, input/weight/scale/zp 4단계 ldma 후에 한 번만 notify).
  - output 쪽은 rid_o를 (2*gen)으로 set 후 acc2lmem done(+1), lmem2dram done(+1)로 총 2번 add하여
    (2*gen+2)에 도달하는 시퀀스를 가정.

  [8] GEMM completion 모델 가정
  - gemm 연산이 끝나면 레지스터 set, 이후 notify 커맨드가 들어오면 sync 모듈로 끝났다는 신호를 보낸다.
  - 즉 i_l_dma에서 sync_if 가 나가는 길이 gemm 연산이 끝났다는 신호라고 가정.

  ================================================================================
  */
  /*
    추가 수정
      - (mt, nt) 타일을 잡고 kt(=K-tile)를 끝까지 누적한 다음,
        마지막 kt 타일에서만 acc2lmem + lmem2dram STORE를 1번 수행한다.
      - ACCUM_BASE scratch는 (mt,nt)마다 분리하지 않고, 순차 실행으로 재사용한다.
      - 따라서 rid_o로 "buf reuse"를 막는 wait는 필요 없음.
  */

  // ----------------------------
  // cfg reg indices (32-bit)
  // ----------------------------
  localparam int CFG_R_CONTROL          = 0;

  localparam int CFG_R_INPUT_BASE_LO    = 1;
  localparam int CFG_R_INPUT_BASE_HI    = 2;
  localparam int CFG_R_WEIGHT_BASE_LO   = 3;
  localparam int CFG_R_WEIGHT_BASE_HI   = 4;
  localparam int CFG_R_OUTPUT_BASE_LO   = 5;
  localparam int CFG_R_OUTPUT_BASE_HI   = 6;
  localparam int CFG_R_SCALE_BASE_LO    = 7;
  localparam int CFG_R_SCALE_BASE_HI    = 8;
  localparam int CFG_R_ZP_BASE_LO       = 9;
  localparam int CFG_R_ZP_BASE_HI       = 10;

  localparam int CFG_R_LMEM_IBUF0_LO    = 11;
  localparam int CFG_R_LMEM_IBUF0_HI    = 12;
  localparam int CFG_R_LMEM_IBUF1_LO    = 13;
  localparam int CFG_R_LMEM_IBUF1_HI    = 14;
  localparam int CFG_R_LMEM_WBUF0_LO    = 15;
  localparam int CFG_R_LMEM_WBUF0_HI    = 16;
  localparam int CFG_R_LMEM_WBUF1_LO    = 17;
  localparam int CFG_R_LMEM_WBUF1_HI    = 18;
  localparam int CFG_R_LMEM_SCBUF0_LO   = 19;
  localparam int CFG_R_LMEM_SCBUF0_HI   = 20;
  localparam int CFG_R_LMEM_SCBUF1_LO   = 21;
  localparam int CFG_R_LMEM_SCBUF1_HI   = 22;
  localparam int CFG_R_LMEM_ZPBUF0_LO   = 23;
  localparam int CFG_R_LMEM_ZPBUF0_HI   = 24;
  localparam int CFG_R_LMEM_ZPBUF1_LO   = 25;
  localparam int CFG_R_LMEM_ZPBUF1_HI   = 26;
  localparam int CFG_R_LMEM_OBUF_LO     = 27;
  localparam int CFG_R_LMEM_OBUF_HI     = 28;

  localparam int CFG_R_M_ORIG           = 29;
  localparam int CFG_R_N_ORIG           = 30;
  localparam int CFG_R_K_ORIG           = 31;
  localparam int CFG_R_QBLK_ORIG        = 32;

  localparam int CFG_R_M_TARGET         = 33;
  localparam int CFG_R_N_TARGET         = 34;
  localparam int CFG_R_K_TARGET         = 35;

  localparam int CFG_R_M_START          = 36;
  localparam int CFG_R_N_START          = 37;

  localparam int CFG_R_WTRANS          = 38;
  localparam int CFG_R_QDIR            = 39;
  localparam int CFG_R_LOG2_DMA_MT     = 40;
  localparam int CFG_R_LOG2_DMA_KT     = 41;
  localparam int CFG_R_LOG2_DMA_NT     = 42;
  localparam int CFG_R_TOTAL           = CFG_R_LOG2_DMA_NT + 1;

  function automatic logic [63:0] cfg_get_u64(input int lo_idx, input int hi_idx);
    cfg_get_u64 = {cfg_reg_if.regs[hi_idx][31:0], cfg_reg_if.regs[lo_idx][31:0]};
  endfunction

  function automatic logic [31:0] cfg_get_u32_or(input int idx, input logic [31:0] fallback);
    begin
      if ((idx >= 0) && (idx < `GEMM_CFG_REG_NUM)) begin
        cfg_get_u32_or = cfg_reg_if.regs[idx][31:0];
      end else begin
        cfg_get_u32_or = fallback;
      end
    end
  endfunction

  // --------------------------------------------------------------------------
  // Bring-up fixed
  // --------------------------------------------------------------------------
  localparam logic QDIR_COL        = `QDIR_COL;
  localparam logic IS_BIAS_FIXED   = 1'b0;

  // Default DMA tile sizes are used only if an older cfg producer omits regs
  // 40..42. The active software path programs the log2 values explicitly.
  localparam int MT_DEFAULT = 128;
  localparam int NT_DEFAULT = 128;
  localparam int KT_DEFAULT = 128;

  // MXU micro tile sizes
  localparam int MXU_KT = `MXU_ROW;
  localparam int MXU_NT = `MXU_COL;

  // scratch accum base (global/local independent)
  localparam logic [63:0] ACCUM_BASE = 64'd0;
  localparam int ACC_DBUF_STRIDE = `GEMM_ACC_MEM_DEPTH * (4 * 2 * MXU_NT);

  localparam int FP32_BYTES  = 4;
  localparam int FP16_BYTES  = 2;
  localparam int INT16_BYTES = 2;
  localparam int INT4_BYTES  = 2; // packed: bytes = elems/2  => divide by 2

  typedef logic [31:0] u32_t;
  localparam int MM_DIM_W           = `MM_MAX_LOG_DIM + 1;
  localparam int MM_TILE_SZ_W       = `MM_MAX_LOG_TILEDIM + 1;
  localparam int MM_RID_W           = 4;
  localparam int MM_MXU_NT_DIM_MAX  = ((1 << `MM_MAX_LOG_TILEDIM) + MXU_NT - 1) >> `CLOG2(MXU_NT);
  localparam int MM_MXU_KT_DIM_MAX  = ((1 << `MM_MAX_LOG_TILEDIM) + MXU_KT - 1) >> `CLOG2(MXU_KT);
  localparam int MM_MXU_DIM_W       = `CLOG2(`MAX(MM_MXU_NT_DIM_MAX, MM_MXU_KT_DIM_MAX) + 1);
  localparam int MM_MXU_LINEAR_W    = `CLOG2((MM_MXU_NT_DIM_MAX * MM_MXU_KT_DIM_MAX) + 1);
  localparam int MM_GROUP_W         = MM_TILE_SZ_W;
  localparam int MM_BYTE_CNT_W      = (2 * MM_TILE_SZ_W) + 2;

  typedef logic [MM_DIM_W-1:0]        mm_dim_t;
  typedef logic [MM_TILE_SZ_W-1:0]    mm_tile_sz_t;
  typedef logic [MM_RID_W-1:0]        mm_rid_t;
  typedef logic [MM_MXU_DIM_W-1:0]    mm_mxu_dim_t;
  typedef logic [MM_MXU_LINEAR_W-1:0] mm_mxu_linear_t;
  typedef logic [MM_GROUP_W-1:0]      mm_group_t;
  typedef logic [MM_BYTE_CNT_W-1:0]   mm_bytecnt_t;

  // --------------------------------------------------------------------------
  // Job/config
  // --------------------------------------------------------------------------
  typedef struct packed {
    logic [63:0] input_base;  // dram
    logic [63:0] weight_base;
    logic [63:0] output_base;
    logic [63:0] scale_base;
    logic [63:0] zp_base;

    logic [63:0] lmem_ibuf0_base;  // lmem
    logic [63:0] lmem_ibuf1_base;
    logic [63:0] lmem_wbuf0_base;
    logic [63:0] lmem_wbuf1_base;
    logic [63:0] lmem_scbuf0_base;
    logic [63:0] lmem_scbuf1_base;
    logic [63:0] lmem_zpbuf0_base;
    logic [63:0] lmem_zpbuf1_base;
    logic [63:0] lmem_obuf_base;

    logic [31:0] target_M, target_N, target_K;
    logic [31:0] orig_M, orig_N, orig_K, orig_qblk;
    logic [31:0] m_start, n_start;
    logic [5:0]  log2_dma_mt, log2_dma_kt, log2_dma_nt;
    logic        wtrans;
    logic        qdir;     // 0=QDIR_COL, 1=QDIR_ROW
  } job_t;

  job_t job_q, job_d;

  // Tile dims and last sizes (latched at start)
  mm_dim_t     mt_dim_q, nt_dim_q, kt_dim_q;
  mm_tile_sz_t m_last_q, n_last_q, k_last_q;
  mm_tile_sz_t MT_q, NT_q, KT_q;
  logic [5:0]  LOG2_MT_q, LOG2_NT_q, LOG2_KT_q;

  // totals exported (debug/host)
  logic [31:0] M_orig, N_orig, K_orig, qblk_orig;
  logic [31:0] M_target, N_target, K_target;
  logic [31:0] wtrans_tot, qdir_tot;
  logic [31:0] entry_id;

  // ------------------------------------------------------------------------
  // Job-scope pre-computed strides (latched once per job in S_INIT_STRIDE_*
  // states). Eliminates 64-bit multiplier cascades from the cmd payload
  // combinational path into u_parent_cmd_queue.
  // ------------------------------------------------------------------------
  logic [31:0] mt_base_q;            // (m_start >> log2_dma_mt)
  logic [31:0] nt_base_q;            // (n_start >> log2_dma_nt)
  logic [63:0] I_MT_STRIDE_q;        // MT * orig_K * FP16
  logic [63:0] I_KT_STRIDE_FULL_q;   // MT * KT * FP16   (cm = MT)
  logic [63:0] I_KT_STRIDE_LAST_q;   // align8(m_last)*KT*FP16 (cm = m_last)
  logic [63:0] W_KT_STRIDE_q;        // (KT * orig_N) / 2
  logic [63:0] W_NT_STRIDE_FULL_q;   // (KT * NT) / 2  (ck = KT)
  logic [63:0] W_NT_STRIDE_LAST_q;   // (k_last * NT) / 2 (ck = k_last)
  logic [63:0] O_MT_STRIDE_q;        // MT * orig_N * FP16 (per dma mt-tile)
  logic [63:0] O_BASE_OFF_q;         // (m_start*orig_N + n_start) * FP16
  logic [63:0] SCALE_FK_FN_q;        // scale_slot_bytes(KT,    NT)
  logic [63:0] SCALE_FK_PN_q;        // scale_slot_bytes(KT,    n_last)
  logic [63:0] SCALE_PK_FN_q;        // scale_slot_bytes(k_last,NT)
  logic [63:0] SCALE_PER_KT_FULL_K_q;// (nt_dim-1)*FK_FN + FK_PN

  // --------------------------------------------------------------------------
  // LMEM base helpers (DMA tile level ping-pong)
  // --------------------------------------------------------------------------
  function automatic logic [63:0] ibuf_base(input logic buf_sel);
    return buf_sel ? job_q.lmem_ibuf1_base : job_q.lmem_ibuf0_base;
  endfunction
  function automatic logic [63:0] wbuf_base(input logic buf_sel);
    return buf_sel ? job_q.lmem_wbuf1_base : job_q.lmem_wbuf0_base;
  endfunction
  function automatic logic [63:0] scbuf_base(input logic buf_sel);
    return buf_sel ? job_q.lmem_scbuf1_base : job_q.lmem_scbuf0_base;
  endfunction
  function automatic logic [63:0] zpbuf_base(input logic buf_sel);
    return buf_sel ? job_q.lmem_zpbuf1_base : job_q.lmem_zpbuf0_base;
  endfunction

  // --------------------------------------------------------------------------
  // Unified opcode map
  // --------------------------------------------------------------------------
  localparam logic [3:0] OP_DMA_LD        = 4'd1;
  localparam logic [3:0] OP_DMA_ST        = 4'd2;
  localparam logic [3:0] OP_NOTIFY        = 4'd3;
  localparam logic [3:0] OP_WAIT          = 4'd4;
  localparam logic [3:0] OP_W_LDMA_MXU    = 4'd5;
  localparam logic [3:0] OP_SZ_LDMA_MXU   = 4'd6;
  localparam logic [3:0] OP_SC_LDMA_MXU   = OP_SZ_LDMA_MXU;
  localparam logic [3:0] OP_ZP_LDMA_MXU   = OP_SZ_LDMA_MXU;
  localparam logic [3:0] OP_I_LDMA_ARM    = 4'd7;
  localparam logic [3:0] OP_O_ACC2LMEM    = 4'd8;
  localparam logic [3:0] OP_CLEAR         = 4'd9;

  // --------------------------------------------------------------------------
  // Sync register assignment
  // --------------------------------------------------------------------------
  localparam int RID_T0  = 0, RID_W0  = 1, RID_SZ0 = 2, RID_G0 = 3, RID_O = 4;
  localparam int RID_T1  = 5, RID_W1  = 6, RID_SZ1 = 7, RID_G1 = 8;
  // Global sync sequence stride per DMA tile.
  // Edge tiles may use fewer MXU steps, but fixed stride preserves monotonicity.
  localparam int MXU_N_PER_TILE_MAX = ((1 << `MM_MAX_LOG_TILEDIM) + MXU_NT - 1) >> `CLOG2(MXU_NT);
  localparam int MXU_K_PER_TILE_MAX = ((1 << `MM_MAX_LOG_TILEDIM) + MXU_KT - 1) >> `CLOG2(MXU_KT);
  localparam int MXU_PER_TILE_MAX   = MXU_N_PER_TILE_MAX * MXU_K_PER_TILE_MAX;

  function automatic mm_rid_t rid_tile   (input logic buf_sel);  return mm_rid_t'(buf_sel ? RID_T1  : RID_T0);  endfunction
  function automatic mm_rid_t rid_w_mxu  (input logic mxu_buf);  return mm_rid_t'(mxu_buf ? RID_W1  : RID_W0);  endfunction
  function automatic mm_rid_t rid_sz_mxu (input logic mxu_buf);  return mm_rid_t'(mxu_buf ? RID_SZ1 : RID_SZ0); endfunction
  function automatic mm_rid_t rid_g_mxu  (input logic mxu_buf);  return mm_rid_t'(mxu_buf ? RID_G1  : RID_G0);  endfunction

  mm_rid_t rid_o = mm_rid_t'(RID_O);  // output sequencing (local to store stage only)
  u32_t o_store_issue_q, o_store_issue_d;
  // --------------------------------------------------------------------------
  // Small helpers
  // --------------------------------------------------------------------------


  // buf generation (kept for DMA flags only)
  function automatic u32_t buf_gen(input u32_t t);
    return (t >> 1) + 1;
  endfunction

  function automatic logic [31:0] make_instr(input logic [3:0] op, input int unsigned size_bytes);
    make_instr = {size_bytes[27:0], op};
  endfunction

  function automatic gemm_unified_cmd_t make_wait_cmd(input mm_rid_t reg_id, input u32_t target);
    gemm_unified_cmd_t t;
    begin
      t = '0;
      t.instr    = {24'd0, OP_WAIT};
      t.rs1_data  = {{(`XLEN-MM_RID_W){1'b0}}, reg_id};
      t.rs2_data  = {{(`XLEN-32){1'b0}}, target[31:0]};
      return t;
    end
  endfunction

  function automatic gemm_unified_cmd_t make_notify_cmd(input mm_rid_t reg_id, input u32_t value, input logic set_mode);
    gemm_unified_cmd_t t;
    begin
      t = '0;
      t.instr   = {24'd0, OP_NOTIFY};
      t.rs1_data = {{(`XLEN-MM_RID_W){1'b0}}, reg_id};
      t.rs2_data = {{(`XLEN-32){1'b0}}, set_mode, value[30:0]};
      return t;
    end
  endfunction

  function automatic gemm_unified_cmd_t make_dma_ld(
    input logic [`XLEN-1:0] lmem_dst,
    input logic [`XLEN-1:0] dram_src,
    input u32_t size_bytes,
    input logic buf_sel,
    input u32_t gen
  );
    gemm_unified_cmd_t c;
    logic [7:0] flags;
    begin
      c = '0;
      flags    = {gen[6:0], buf_sel};
      c.flags  = flags;
      c.instr  = make_instr(OP_DMA_LD, size_bytes);
      c.rs1_data = lmem_dst;
      c.rs2_data = dram_src;
      c.bound    = 16'd1;
      c.stride   = '0;
      return c;
    end
  endfunction

  function automatic gemm_unified_cmd_t make_dma_st(
    input logic [`XLEN-1:0] dram_dst,
    input logic [`XLEN-1:0] lmem_src,
    input u32_t size_bytes,
    input logic buf_sel,
    input u32_t gen
  );
    gemm_unified_cmd_t c;
    logic [7:0] flags;
    begin
      c = '0;
      flags    = {gen[6:0], buf_sel};
      c.flags  = flags;
      c.instr  = make_instr(OP_DMA_ST, size_bytes);
      c.rs1_data = dram_dst;
      c.rs2_data = lmem_src;
      c.bound    = 16'd1;
      c.stride   = '0;
      return c;
    end
  endfunction

  // Tile scan order: kt fastest -> nt -> mt, matching the tiled host layout.
  // This avoids divide/mod decode from a scalar tile index.
  task automatic tile_next_coords(
    input  mm_dim_t nt_i,
    input  mm_dim_t mt_i,
    input  mm_dim_t kt_i,
    output logic has_next,
    output mm_dim_t nt_o,
    output mm_dim_t mt_o,
    output mm_dim_t kt_o
  );
    begin
      nt_o = nt_i;
      mt_o = mt_i;
      kt_o = kt_i;
      has_next = 1'b0;

      if (kt_i + 1 < kt_dim_q) begin
        kt_o = kt_i + 1;
        has_next = 1'b1;
      end else if (nt_i + 1 < nt_dim_q) begin
        kt_o = '0;
        nt_o = nt_i + 1;
        has_next = 1'b1;
      end else if (mt_i + 1 < mt_dim_q) begin
        kt_o = '0;
        nt_o = '0;
        mt_o = mt_i + 1;
        has_next = 1'b1;
      end
    end
  endtask

  task automatic tile_eff_sizes(
    input  mm_dim_t nt,
    input  mm_dim_t mt,
    input  mm_dim_t kt,
    output mm_tile_sz_t mt_eff,
    output mm_tile_sz_t nt_eff,
    output mm_tile_sz_t kt_eff
  );
    begin
      mt_eff = (mt == mt_dim_q-1) ? m_last_q : MT_q;
      nt_eff = (nt == nt_dim_q-1) ? n_last_q : NT_q;
      kt_eff = (kt == kt_dim_q-1) ? k_last_q : KT_q;
    end
  endtask

  // --------------------------------------------------------------------------
  // DRAM address helpers for the host-side tiled buffer layout.
  // --------------------------------------------------------------------------
  function automatic logic [63:0] align512(input logic [63:0] value);
    begin
      align512 = (value + 64'd511) & ~64'd511;
    end
  endfunction

  function automatic u32_t align8_u32(input u32_t value);
    begin
      align8_u32 = (value + 32'd7) & ~32'd7;
    end
  endfunction

  function automatic logic [63:0] scale_slot_bytes(input job_t j, input u32_t ck, input u32_t cn);
    logic [63:0] actual;
    u32_t nb_per_nt;
    u32_t ng_per_mxu_nt;
    begin
      nb_per_nt     = cn >> `CLOG2(MXU_NT);
      ng_per_mxu_nt = ceil_div_log2(MXU_NT, j.orig_qblk[5:0]);

      if (!j.qdir) begin
        // QCOL slot body: [nb][ceil(KT/qblk)][MXU_NT] fp16.
        actual = 64'(div_log2(ck, j.orig_qblk[5:0])) * 64'(cn) * FP16_BYTES;
      end else begin
        // QROW slot body: [nb][KT][ceil(MXU_NT/qblk)] fp16.
        actual = 64'(nb_per_nt) * 64'(ck) * 64'(ng_per_mxu_nt) * FP16_BYTES;
      end

      scale_slot_bytes = align512(actual);
    end
  endfunction

  function automatic u32_t qrow_qparam_tile_bytes(input u32_t ck, input u32_t cn, input u32_t elem_bytes);
    u32_t nb_per_nt;
    u32_t ng_per_mxu_nt;
    begin
      nb_per_nt     = cn >> `CLOG2(MXU_NT);
      ng_per_mxu_nt = ceil_div_log2(MXU_NT, job_q.orig_qblk[5:0]);
      // QROW LMEM layout is per 32-wide MXU N microtile, even when multiple
      // microtiles share one logical QBLK group (e.g. QBLK=64 or 128).
      qrow_qparam_tile_bytes = ck * nb_per_nt * ng_per_mxu_nt * elem_bytes;
    end
  endfunction

  function automatic logic [63:0] scale_slot_offset(input job_t j, input mm_dim_t nt, input mm_dim_t kt);
    logic [63:0] slot_full_N;
    u32_t nt_idx;
    u32_t kt_idx;
    begin
      // SCALE_FK_FN_q / SCALE_PK_FN_q / SCALE_PER_KT_FULL_K_q are
      // pre-computed in S_INIT_STRIDE_0/1; argument j is unused but kept
      // for backward-compatible callers.
      nt_idx = u32_t'(nt);
      kt_idx = u32_t'(kt);

      slot_full_N = (kt == kt_dim_q - 1) ? SCALE_PK_FN_q : SCALE_FK_FN_q;

      scale_slot_offset = 64'(kt_idx) * SCALE_PER_KT_FULL_K_q
                        + 64'(nt_idx) * slot_full_N;
    end
  endfunction

  function automatic logic [63:0] input_tile_addr(input job_t j, input mm_dim_t mt, input mm_dim_t kt);
    u32_t mt_idx;
    u32_t kt_idx;
    logic [63:0] kt_stride;
    begin
      // mt_base_q = (j.m_start >> j.log2_dma_mt), pre-computed.
      mt_idx    = mt_base_q + u32_t'(mt);
      kt_idx    = u32_t'(kt);
      kt_stride = (mt == mt_dim_q - 1) ? I_KT_STRIDE_LAST_q : I_KT_STRIDE_FULL_q;

      input_tile_addr = j.input_base
                      + 64'(mt_idx) * I_MT_STRIDE_q
                      + 64'(kt_idx) * kt_stride;
    end
  endfunction

  function automatic logic [63:0] weight_tile_addr(input job_t j, input mm_dim_t nt, input mm_dim_t kt);
    u32_t nt_idx;
    u32_t kt_idx;
    logic [63:0] nt_stride;
    begin
      // nt_base_q = (j.n_start >> j.log2_dma_nt), pre-computed.
      nt_idx    = nt_base_q + u32_t'(nt);
      kt_idx    = u32_t'(kt);
      nt_stride = (kt == kt_dim_q - 1) ? W_NT_STRIDE_LAST_q : W_NT_STRIDE_FULL_q;

      weight_tile_addr = j.weight_base
                       + 64'(kt_idx) * W_KT_STRIDE_q
                       + 64'(nt_idx) * nt_stride;
    end
  endfunction

  function automatic logic [63:0] scale_tile_addr(input job_t j, input mm_dim_t nt, input mm_dim_t kt);
    begin
      scale_tile_addr = j.scale_base + scale_slot_offset(j, nt, kt);
    end
  endfunction

  function automatic logic [63:0] zp_tile_addr(input job_t j, input mm_dim_t nt, input mm_dim_t kt);
    begin
      zp_tile_addr = j.zp_base + scale_slot_offset(j, nt, kt);
    end
  endfunction

  function automatic logic [63:0] out_tile_addr(input job_t j, input mm_dim_t mt, input mm_dim_t nt);
    // output: [M, N] fp16
    //   addr = output_base
    //        + (m_start*orig_N + n_start) * FP16   ← O_BASE_OFF_q
    //        + mt * (MT * orig_N) * FP16           ← mt * O_MT_STRIDE_q
    //        + nt * (NT * FP16)                    ← nt * (NT_q << 1)
    begin
      out_tile_addr = j.output_base
                    + O_BASE_OFF_q
                    + 64'(u32_t'(mt)) * O_MT_STRIDE_q
                    + ((64'(u32_t'(nt)) * 64'(u32_t'(NT_q))) << 1);
    end
  endfunction

  // Scale/Zero register address map
  localparam SCALE_REG_SIZE  = `MAX(`MXU_ROW, `MXU_COL) * (`SCALE_WIDTH >> 3); // in bytes, 64bytes
  localparam ZP_REG_SIZE     = `MAX(`MXU_ROW, `MXU_COL) * (`ZP_WIDTH >> 3); // in bytes
  localparam SCALE_REG0_BASE = 0;
  localparam SCALE_REG1_BASE = SCALE_REG_SIZE;
  localparam ZP_REG0_BASE    = SCALE_REG_SIZE * 2;
  localparam ZP_REG1_BASE    = SCALE_REG_SIZE * 2 + ZP_REG_SIZE;

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
    S_IDLE, // 0

    // job-scope stride pre-compute (1+1 = 2 cycles after cfg latch)
    S_INIT_STRIDE_0, S_INIT_STRIDE_1,

    // kickoff: preload tile0 and optionally tile1 (single notify per tile)
    S_PRE0_LD_I, S_PRE0_LD_W, S_PRE0_LD_SC, S_PRE0_LD_ZP, S_PRE0_LD_DONE_NTF, // 5
    S_PRE1_LD_I, S_PRE1_LD_W, S_PRE1_LD_SC, S_PRE1_LD_ZP, S_PRE1_LD_DONE_NTF, // 10

    // wait current tile preload complete
    S_WAIT_CUR_TILE_READY, // 11

    // MXU preload current W/SZ
    S_MXU_PRE_CUR_W,  S_MXU_PRE_CUR_W_NTF, // 13
    S_MXU_PRE_CUR_SC, S_MXU_PRE_CUR_ZP, S_MXU_PRE_CUR_SZ_NTF, // 16
    S_MXU_WAIT_CUR_W, // 17
    S_MXU_WAIT_CUR_SZ, // 18

    // preload next MXU tile (ping-pong)
    S_MXU_PRE_NEXT_W, S_MXU_PRE_NEXT_W_NTF, // 20
    S_MXU_PRE_NEXT_SC, S_MXU_PRE_NEXT_ZP, S_MXU_PRE_NEXT_SZ_NTF, // 23

    // ARM + GEMM done
    S_MXU_ARM_GEMM, S_MXU_ARM_GEMM_NTF, S_MXU_WAIT_GEMM_DONE, // 26

    // output stage (only when last-kt tile for this (mt,nt))
    S_O_WAIT_LMEM2DRAM_DONE, S_O_ACC2LMEM, S_O_ACC2LMEM_NTF, // 29
    S_O_WAIT_ACC2LMEM_DONE, // 30
    S_O_LMEM2DRAM, S_O_LMEM2DRAM_NTF, // 32

    // advance + optionally preload next tile
    S_ADVANCE_TILES, S_O_WAIT_LMEM2DRAM_FINAL, S_FINAL_CLEAR, // 35

    S_PRE_NEXT_LD_I, S_PRE_NEXT_LD_W, S_PRE_NEXT_LD_SC, S_PRE_NEXT_LD_ZP, S_PRE_NEXT_LD_DONE_NTF // 39
  } state_t;

  state_t state_q, state_d;

  // tile pipeline registers
  u32_t tile_cur_q, tile_cur_d;
  u32_t tile_pre_q, tile_pre_d;   // next tile being/been preloaded
  mm_dim_t tile_cur_nt_q, tile_cur_nt_d;
  mm_dim_t tile_cur_mt_q, tile_cur_mt_d;
  mm_dim_t tile_cur_kt_q, tile_cur_kt_d;
  mm_dim_t tile_pre_nt_q, tile_pre_nt_d;
  mm_dim_t tile_pre_mt_q, tile_pre_mt_d;
  mm_dim_t tile_pre_kt_q, tile_pre_kt_d;
  logic        pre_valid_q, pre_valid_d; // whether tile_pre exists

  // mxu loop regs for current tile
  mm_mxu_dim_t nt_mxu_q, nt_mxu_d;
  mm_mxu_dim_t kt_mxu_q, kt_mxu_d;
  logic        mxu_buf_q, mxu_buf_d;
  mm_mxu_dim_t o_nt_mxu_q, o_nt_mxu_d;

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
      MT_q <= mm_tile_sz_t'(MT_DEFAULT);
      NT_q <= mm_tile_sz_t'(NT_DEFAULT);
      KT_q <= mm_tile_sz_t'(KT_DEFAULT);
      LOG2_MT_q <= `CLOG2(MT_DEFAULT);
      LOG2_NT_q <= `CLOG2(NT_DEFAULT);
      LOG2_KT_q <= `CLOG2(KT_DEFAULT);

      tile_cur_q <= 0;
      tile_pre_q <= 0;
      tile_cur_nt_q <= '0;
      tile_cur_mt_q <= '0;
      tile_cur_kt_q <= '0;
      tile_pre_nt_q <= '0;
      tile_pre_mt_q <= '0;
      tile_pre_kt_q <= '0;
      pre_valid_q <= 1'b0;

      nt_mxu_q <= 0;
      kt_mxu_q <= 0;
      mxu_buf_q <= 1'b0;
      o_nt_mxu_q <= 0;
      o_store_issue_q <= '0;

      mt_base_q <= '0;
      nt_base_q <= '0;
      I_MT_STRIDE_q        <= '0;
      I_KT_STRIDE_FULL_q   <= '0;
      I_KT_STRIDE_LAST_q   <= '0;
      W_KT_STRIDE_q        <= '0;
      W_NT_STRIDE_FULL_q   <= '0;
      W_NT_STRIDE_LAST_q   <= '0;
      O_MT_STRIDE_q        <= '0;
      O_BASE_OFF_q         <= '0;
      SCALE_FK_FN_q        <= '0;
      SCALE_FK_PN_q        <= '0;
      SCALE_PK_FN_q        <= '0;
      SCALE_PER_KT_FULL_K_q<= '0;
    end else begin
      state_q <= state_d;
      job_q   <= job_d;

      tile_cur_q  <= tile_cur_d;
      tile_pre_q  <= tile_pre_d;
      tile_cur_nt_q <= tile_cur_nt_d;
      tile_cur_mt_q <= tile_cur_mt_d;
      tile_cur_kt_q <= tile_cur_kt_d;
      tile_pre_nt_q <= tile_pre_nt_d;
      tile_pre_mt_q <= tile_pre_mt_d;
      tile_pre_kt_q <= tile_pre_kt_d;
      pre_valid_q <= pre_valid_d;

      nt_mxu_q  <= nt_mxu_d;
      kt_mxu_q  <= kt_mxu_d;
      mxu_buf_q <= mxu_buf_d;
      o_nt_mxu_q <= o_nt_mxu_d;
      o_store_issue_q <= o_store_issue_d;

      if (state_q == S_IDLE && cfg_reg_if.regs[CFG_R_CONTROL][0] && cfg_reg_if.valid && cfg_reg_if.ready) begin
        mm_dim_t mt_dim_n;
        mm_dim_t nt_dim_n;
        mm_dim_t kt_dim_n;
        mm_tile_sz_t mt_rem;
        mm_tile_sz_t nt_rem;
        mm_tile_sz_t kt_rem;
        logic [5:0] log2_mt_n;
        logic [5:0] log2_nt_n;
        logic [5:0] log2_kt_n;
        mm_tile_sz_t mt_n;
        mm_tile_sz_t nt_n;
        mm_tile_sz_t kt_n;

        log2_mt_n = cfg_reg_if.regs[CFG_R_LOG2_DMA_MT][5:0];
        log2_kt_n = cfg_reg_if.regs[CFG_R_LOG2_DMA_KT][5:0];
        log2_nt_n = cfg_reg_if.regs[CFG_R_LOG2_DMA_NT][5:0];
        mt_n = mm_tile_sz_t'(32'd1 << log2_mt_n);
        kt_n = mm_tile_sz_t'(32'd1 << log2_kt_n);
        nt_n = mm_tile_sz_t'(32'd1 << log2_nt_n);

        mt_dim_n = mm_dim_t'(ceil_div_log2(job_d.target_M, log2_mt_n));
        nt_dim_n = mm_dim_t'(ceil_div_log2(job_d.target_N, log2_nt_n));
        kt_dim_n = mm_dim_t'(ceil_div_log2(job_d.target_K, log2_kt_n));

        mt_dim_q <= mt_dim_n;
        nt_dim_q <= nt_dim_n;
        kt_dim_q <= kt_dim_n;
        MT_q <= mt_n;
        NT_q <= nt_n;
        KT_q <= kt_n;
        LOG2_MT_q <= log2_mt_n;
        LOG2_NT_q <= log2_nt_n;
        LOG2_KT_q <= log2_kt_n;

        mt_rem = mm_tile_sz_t'(job_d.target_M & (u32_t'(mt_n) - 1));
        nt_rem = mm_tile_sz_t'(job_d.target_N & (u32_t'(nt_n) - 1));
        kt_rem = mm_tile_sz_t'(job_d.target_K & (u32_t'(kt_n) - 1));

        m_last_q <= (mt_rem == 0) ? mt_n : mt_rem;
        n_last_q <= (nt_rem == 0) ? nt_n : nt_rem;
        k_last_q <= (kt_rem == 0) ? kt_n : kt_rem;
      end

      // Stride pre-compute stage 0: latch from job_q / *_q registers.
      // All inputs are register-sourced; single-cycle multiplier per stride.
      if (state_q == S_INIT_STRIDE_0) begin
        mt_base_q <= job_q.m_start >> job_q.log2_dma_mt;
        nt_base_q <= job_q.n_start >> job_q.log2_dma_nt;

        I_MT_STRIDE_q       <= 64'(u32_t'(MT_q)) * 64'(job_q.orig_K) * FP16_BYTES;
        I_KT_STRIDE_FULL_q  <= 64'(align8_u32(u32_t'(MT_q)))     * 64'(u32_t'(KT_q)) * FP16_BYTES;
        I_KT_STRIDE_LAST_q  <= 64'(align8_u32(u32_t'(m_last_q))) * 64'(u32_t'(KT_q)) * FP16_BYTES;

        W_KT_STRIDE_q       <= (64'(u32_t'(KT_q))     * 64'(job_q.orig_N)) >> 1;
        W_NT_STRIDE_FULL_q  <= (64'(u32_t'(KT_q))     * 64'(u32_t'(NT_q))) >> 1;
        W_NT_STRIDE_LAST_q  <= (64'(u32_t'(k_last_q)) * 64'(u32_t'(NT_q))) >> 1;

        O_MT_STRIDE_q <= (64'(u32_t'(MT_q)) * 64'(job_q.orig_N)) << 1;
        O_BASE_OFF_q  <= (64'(job_q.m_start) * 64'(job_q.orig_N)
                         + 64'(job_q.n_start)) << 1;

        SCALE_FK_FN_q <= scale_slot_bytes(job_q, u32_t'(KT_q),     u32_t'(NT_q));
        SCALE_FK_PN_q <= scale_slot_bytes(job_q, u32_t'(KT_q),     u32_t'(n_last_q));
        SCALE_PK_FN_q <= scale_slot_bytes(job_q, u32_t'(k_last_q), u32_t'(NT_q));
      end

      // Stride pre-compute stage 1: combine stage-0 registers (no fresh
      // 64-bit multiplier chain on this cycle).
      if (state_q == S_INIT_STRIDE_1) begin
        SCALE_PER_KT_FULL_K_q <= 64'(u32_t'(nt_dim_q - 1)) * SCALE_FK_FN_q
                              +  SCALE_FK_PN_q;
      end
    end
  end

  always_ff @(posedge clk) begin
    if (reset) begin
      M_orig <= 32'd0;
      N_orig <= 32'd0;
      K_orig <= 32'd0;
      qblk_orig <= 32'd0;
      wtrans_tot <= 32'd0;
      qdir_tot <= 32'd0;
      M_target <= 32'd0;
      N_target <= 32'd0;
      K_target <= 32'd0;
      entry_id   <= 32'd0;
    end else begin
      if (cfg_reg_if.regs[CFG_R_CONTROL][0] && cfg_reg_if.valid && cfg_reg_if.ready) begin
        M_orig <= cfg_reg_if.regs[CFG_R_M_ORIG][31:0];
        N_orig <= cfg_reg_if.regs[CFG_R_N_ORIG][31:0];
        K_orig <= cfg_reg_if.regs[CFG_R_K_ORIG][31:0];
        qblk_orig <= cfg_reg_if.regs[CFG_R_QBLK_ORIG][31:0];
        wtrans_tot <= cfg_reg_if.regs[CFG_R_WTRANS][31:0];
        qdir_tot <= cfg_reg_if.regs[CFG_R_QDIR][31:0];
        M_target <= cfg_reg_if.regs[CFG_R_M_TARGET][31:0];
        N_target <= cfg_reg_if.regs[CFG_R_N_TARGET][31:0];
        K_target <= cfg_reg_if.regs[CFG_R_K_TARGET][31:0];
        entry_id   <= cfg_reg_if.entry_id;
      end
    end
  end

  // --------------------------------------------------------------------------
  // combinational
  // --------------------------------------------------------------------------
  always_comb begin
    // defaults
    logic can_emit;

    mm_dim_t nt_cur, mt_cur, kt_cur;
    mm_dim_t nt1_init, mt1_init, kt1_init;
    mm_tile_sz_t mt_eff_cur, nt_eff_cur, kt_eff_cur;
    logic        buf_cur;
    logic        has_tile1_init;
    u32_t gen_cur;

    u32_t tile_total;

    u32_t in_ready_target_cur;

    // mxu dims
    mm_mxu_dim_t nt_mxu_dim, kt_mxu_dim;
    mm_mxu_linear_t mxu_linear;
    mm_mxu_dim_t n_nt_mxu, n_kt_mxu;
    logic        has_next_mxu;
    mm_mxu_linear_t next_mxu_linear;
    u32_t        tile_mxu_base;
    u32_t        global_mxu_seq;
    u32_t        next_global_mxu_seq;

    // gemm control
    u32_t global_k;
    logic is_accum, is_last;   // per microtile
    logic last_kt_tile;        // per DMA tile (kt_cur)
    u32_t gemm_done_target;

    // LMEM addresses
    logic [63:0] lmem_in_mxu, lmem_out_slice;
    logic [63:0] lmem_w_mxu, lmem_sc_mxu, lmem_zp_mxu;
    logic [63:0] lmem_w_mxu_next, lmem_sc_mxu_next, lmem_zp_mxu_next;
    mm_group_t groups_tile, groups_mxu;
    mm_group_t ng_mxu;  // QROW: ceil(MXU_NT/qblk)
    mm_group_t groups_eff_cur;
    u32_t weight_nb_stride;
    u32_t scale_nb_stride;
    u32_t qparam_kb_offset;
    u32_t w_seg_bytes;

    mm_tile_sz_t k0_in;      // col in K for input tile
    mm_tile_sz_t n0_out;     // col in N for output/accum tile
    mm_tile_sz_t w_row0;     // row index in weight tile
    mm_tile_sz_t w_col0_bytes; // byte col index in weight tile
    mm_tile_sz_t w_row_stride_bytes;
    mm_group_t g0;           // group row offset inside (kt tile)
    mm_tile_sz_t k0_in_n, n0_out_n, w_row0_n, w_col0_bytes_n;
    mm_group_t g0_n;

    // output
    mm_bytecnt_t out_bytes_acc;
    mm_bytecnt_t out_bytes_fp16;
    mm_mxu_dim_t output_nt_mxu_dim;
    u32_t dma_nt_mxu_dim;
    u32_t acc_nb_stride;
    u32_t acc_group_base;
    u32_t acc_base_nb;
    u32_t output_nb_bytes;
    u32_t output_nb_stride_bytes;
    logic [63:0] lmem_obuf_nb;
    logic [63:0] dram_out_nb;

    groups_tile = mm_group_t'(ceil_div_log2(u32_t'(KT_q), job_q.orig_qblk[5:0]));
    groups_mxu  = mm_group_t'(ceil_div_log2(MXU_KT, job_q.orig_qblk[5:0]));
    ng_mxu      = mm_group_t'(ceil_div_log2(MXU_NT, job_q.orig_qblk[5:0]));

    // regs next
    state_d = state_q;
    job_d   = job_q;

    tile_cur_d  = tile_cur_q;
    tile_pre_d  = tile_pre_q;
    tile_cur_nt_d = tile_cur_nt_q;
    tile_cur_mt_d = tile_cur_mt_q;
    tile_cur_kt_d = tile_cur_kt_q;
    tile_pre_nt_d = tile_pre_nt_q;
    tile_pre_mt_d = tile_pre_mt_q;
    tile_pre_kt_d = tile_pre_kt_q;
    pre_valid_d = pre_valid_q;

    nt_mxu_d  = nt_mxu_q;
    kt_mxu_d  = kt_mxu_q;
    mxu_buf_d = mxu_buf_q;
    o_nt_mxu_d = o_nt_mxu_q;

    out_cmd_d   = '0;
    out_start_d = 1'b0;
    o_store_issue_d = o_store_issue_q;

    can_emit = gemm_fsm_if.flag.idle;

    // tile totals (after start latch mt_dim_q/.. valid)
    tile_total = mt_dim_q * nt_dim_q * kt_dim_q;

    // current tile coords are tracked explicitly
    nt_cur = tile_cur_nt_q;
    mt_cur = tile_cur_mt_q;
    kt_cur = tile_cur_kt_q;
    tile_next_coords('0, '0, '0, has_tile1_init, nt1_init, mt1_init, kt1_init);

    mt_eff_cur = (mt_cur == mt_dim_q-1) ? m_last_q : MT_q;
    nt_eff_cur = (nt_cur == nt_dim_q-1) ? n_last_q : NT_q;
    kt_eff_cur = (kt_cur == kt_dim_q-1) ? k_last_q : KT_q;

    buf_cur = tile_cur_q[0];
    gen_cur = buf_gen(tile_cur_q);

    last_kt_tile = (kt_cur == kt_dim_q-1);

    // preload done marker (single notify after ZP)
    in_ready_target_cur = 4*gen_cur + 4;

    // MXU dims within current DMA tile
    nt_mxu_dim = mm_mxu_dim_t'(ceil_div_log2(u32_t'(nt_eff_cur), $clog2(MXU_NT)));
    kt_mxu_dim = mm_mxu_dim_t'(div_log2(u32_t'(kt_eff_cur), $clog2(MXU_KT))); // assume divisible

    mxu_linear = mm_mxu_linear_t'((mm_mxu_linear_t'(nt_mxu_q) * mm_mxu_linear_t'(kt_mxu_dim))
                             +  mm_mxu_linear_t'(kt_mxu_q));

    // next mxu indices: kb fastest within each 32-wide N microtile.
    n_kt_mxu = (kt_mxu_q + 1 == kt_mxu_dim) ? 0 : (kt_mxu_q + 1);
    n_nt_mxu = (kt_mxu_q + 1 == kt_mxu_dim) ? (nt_mxu_q + 1) : nt_mxu_q;

    has_next_mxu     = (n_nt_mxu < nt_mxu_dim);
    next_mxu_linear  = mm_mxu_linear_t'((mm_mxu_linear_t'(n_nt_mxu) * mm_mxu_linear_t'(kt_mxu_dim))
                                   +  mm_mxu_linear_t'(n_kt_mxu));
    tile_mxu_base      = tile_cur_q * u32_t'(MXU_PER_TILE_MAX);
    global_mxu_seq     = tile_mxu_base + u32_t'(mxu_linear) + 32'd1;
    next_global_mxu_seq = tile_mxu_base + u32_t'(next_mxu_linear) + 32'd1;

    // global_k determines accumulate/last for microtile
    global_k = (u32_t'(kt_cur) << LOG2_KT_q) + kt_mxu_q * MXU_KT;
    is_accum = (global_k != 0);
    is_last  = (global_k + MXU_KT >= job_q.target_K);

    // ------------------------------------------------------------------------
    // LMEM offsets for current microtile (ROW-MAJOR within each DMA tile buffer)
    // ------------------------------------------------------------------------
    // Assumption:
    //   IBUF  stores [MT x KT] fp16 row-major, row-stride = KT*2 bytes
    //   WBUF  stores [KT x (NT/2)] bytes row-major, row-stride = (NT/2) bytes
    //   SCBUF stores [groups_tile x NT] fp16 row-major, row-stride = NT*2 bytes
    //   ZPBUF stores [groups_tile x NT] int16 row-major, row-stride = NT*2 bytes
    //   ACCUM_BASE stores [MT x NT] fp32 row-major, row-stride = NT*4 bytes

    // input microtile starts at K = kt_mxu_q*MXU_KT (within tile)
    k0_in  = mm_tile_sz_t'(kt_mxu_q * MXU_KT);

    // output/accum microtile starts at N = nt_mxu_q*MXU_NT (within tile)
    n0_out = mm_tile_sz_t'(nt_mxu_q * MXU_NT);

    // weight microtile:
    //  wtrans=0: [KT, NT] tile, row=kt_mxu_q*MXU_KT, col(bytes)=(nt_mxu_q*MXU_NT)/2
    //  wtrans=1: [NT, KT] tile, row=nt_mxu_q*MXU_NT, col(bytes)=(kt_mxu_q*MXU_KT)/2
    w_row0            = job_q.wtrans ? mm_tile_sz_t'(nt_mxu_q * MXU_NT)
                                     : mm_tile_sz_t'(kt_mxu_q * MXU_KT);
    w_col0_bytes      = job_q.wtrans ? mm_tile_sz_t'((kt_mxu_q * MXU_KT) >> 1)
                                     : mm_tile_sz_t'((nt_mxu_q * MXU_NT) >> 1);
    w_row_stride_bytes = job_q.wtrans ? mm_tile_sz_t'(KT_q >> 1)
                                      : mm_tile_sz_t'(NT_q >> 1);

    // group row offset inside this KT tile
    g0 = mm_group_t'(div_log2((kt_mxu_q * MXU_KT), job_q.orig_qblk[5:0]));
    groups_eff_cur   = mm_group_t'(ceil_div_log2(u32_t'(kt_eff_cur), job_q.orig_qblk[5:0]));
    weight_nb_stride = u32_t'(kt_eff_cur) * u32_t'(MXU_NT >> 1);
    scale_nb_stride  = job_q.qdir ? (u32_t'(kt_eff_cur) * u32_t'(ng_mxu) * u32_t'(FP16_BYTES))
                                  : (u32_t'(groups_eff_cur) * u32_t'(MXU_NT) * u32_t'(FP16_BYTES));
    qparam_kb_offset = job_q.qdir ? (u32_t'(MXU_KT) * u32_t'(ng_mxu) * u32_t'(FP16_BYTES)) : 32'd0;
    w_seg_bytes      = u32_t'(MXU_KT * (MXU_NT >> 1));

    // Input tile layout is [kb][m][MXU_KT]. Each kb slice contains all M rows,
    // so the microtile offset scales by the effective M, not just by K.
    lmem_in_mxu = ibuf_base(buf_cur)
                + 64'(kt_mxu_q) * 64'(mt_eff_cur) * 64'(MXU_KT * FP16_BYTES);

    dma_nt_mxu_dim   = u32_t'(NT_q) >> `CLOG2(MXU_NT);
    acc_nb_stride    = u32_t'(ACC_DBUF_STRIDE) >> (LOG2_NT_q - `CLOG2(MXU_NT));
    acc_group_base   = ((u32_t'(tile_cur_nt_q) + (u32_t'(nt_dim_q) * u32_t'(tile_cur_mt_q))) & 32'd1)
                     ? u32_t'(ACC_DBUF_STRIDE) : 32'd0;
    acc_base_nb      = acc_group_base + (u32_t'(nt_mxu_q) * acc_nb_stride);

    // Accum/output slice base. Each 32-wide N microtile accumulates in its own
    // disjoint acc-memory region, matching the cmd-stream reference path.
    lmem_out_slice = 64'(acc_base_nb);

    // Weight tile layout is [nb][kb][MXU_KT][MXU_NT/2].
    lmem_w_mxu = wbuf_base(buf_cur)
               + 64'(nt_mxu_q) * 64'(weight_nb_stride)
               + 64'(kt_mxu_q) * 64'(w_seg_bytes);

    // Scale/ZP slice base
    if (!job_q.qdir) begin
      // QCOL: [nb][groups_per_kt][MXU_NT], shared across kb.
      lmem_sc_mxu = scbuf_base(buf_cur) + 64'(nt_mxu_q) * 64'(scale_nb_stride);
      lmem_zp_mxu = zpbuf_base(buf_cur) + 64'(nt_mxu_q) * 64'(scale_nb_stride);
    end else begin
      // QROW: [nb][KT][ng_per_mxu_nt], differs per (nb, kb).
      lmem_sc_mxu = scbuf_base(buf_cur)
                  + 64'(nt_mxu_q) * 64'(scale_nb_stride)
                  + 64'(kt_mxu_q) * 64'(qparam_kb_offset);
      lmem_zp_mxu = zpbuf_base(buf_cur)
                  + 64'(nt_mxu_q) * 64'(scale_nb_stride)
                  + 64'(kt_mxu_q) * 64'(qparam_kb_offset);
    end

    // next microtile addresses (for preload next)
    k0_in_n      = mm_tile_sz_t'(n_kt_mxu * MXU_KT);
    n0_out_n     = mm_tile_sz_t'(n_nt_mxu * MXU_NT);
    w_row0_n     = job_q.wtrans ? mm_tile_sz_t'(n_nt_mxu * MXU_NT)
                                : mm_tile_sz_t'(n_kt_mxu * MXU_KT);
    w_col0_bytes_n = job_q.wtrans ? mm_tile_sz_t'((n_kt_mxu * MXU_KT) >> 1)
                                  : mm_tile_sz_t'((n_nt_mxu * MXU_NT) >> 1);
    g0_n         = mm_group_t'(div_log2((n_kt_mxu * MXU_KT), job_q.orig_qblk[5:0]));

    lmem_w_mxu_next = wbuf_base(buf_cur)
                    + 64'(n_nt_mxu) * 64'(weight_nb_stride)
                    + 64'(n_kt_mxu) * 64'(w_seg_bytes);

    if (!job_q.qdir) begin
      lmem_sc_mxu_next = scbuf_base(buf_cur) + 64'(n_nt_mxu) * 64'(scale_nb_stride);
      lmem_zp_mxu_next = zpbuf_base(buf_cur) + 64'(n_nt_mxu) * 64'(scale_nb_stride);
    end else begin
      lmem_sc_mxu_next = scbuf_base(buf_cur)
                       + 64'(n_nt_mxu) * 64'(scale_nb_stride)
                       + 64'(n_kt_mxu) * 64'(qparam_kb_offset);
      lmem_zp_mxu_next = zpbuf_base(buf_cur)
                       + 64'(n_nt_mxu) * 64'(scale_nb_stride)
                       + 64'(n_kt_mxu) * 64'(qparam_kb_offset);
    end


    gemm_done_target = global_mxu_seq;

    out_bytes_acc  = mm_bytecnt_t'(mt_eff_cur * nt_eff_cur * FP32_BYTES);
    out_bytes_fp16 = mm_bytecnt_t'(mt_eff_cur * nt_eff_cur * FP16_BYTES);
    output_nt_mxu_dim = nt_mxu_dim;
    output_nb_bytes = u32_t'(mt_eff_cur) * u32_t'(MXU_NT * FP16_BYTES);
    output_nb_stride_bytes = align8_u32(u32_t'(mt_eff_cur)) * u32_t'(MXU_NT * FP16_BYTES);
    lmem_obuf_nb = job_q.lmem_obuf_base + 64'(o_nt_mxu_q) * 64'(output_nb_stride_bytes);
    dram_out_nb = job_q.output_base
                + 64'(mt_cur) * 64'(MT_q) * 64'(job_q.orig_N) * FP16_BYTES
                + 64'((u32_t'(nt_cur) * dma_nt_mxu_dim) + u32_t'(o_nt_mxu_q))
                  * 64'(output_nb_stride_bytes);

    gemm_start_o = 1'b0;

    unique case (state_q)

      // ----------------------------------------------------------------------
      // IDLE
      // ----------------------------------------------------------------------
      S_IDLE: begin
        tile_cur_d  = 0;
        tile_pre_d  = 0;
        tile_cur_nt_d = '0;
        tile_cur_mt_d = '0;
        tile_cur_kt_d = '0;
        tile_pre_nt_d = '0;
        tile_pre_mt_d = '0;
        tile_pre_kt_d = '0;
        pre_valid_d = 1'b0;
        nt_mxu_d    = 0;
        kt_mxu_d    = 0;
        mxu_buf_d   = 1'b0;
        o_nt_mxu_d  = 0;
        o_store_issue_d = 0;

        if (cfg_reg_if.regs[CFG_R_CONTROL][0] && cfg_reg_if.valid && cfg_reg_if.ready) begin
          job_d.input_base  = cfg_get_u64(CFG_R_INPUT_BASE_LO,  CFG_R_INPUT_BASE_HI);
          job_d.weight_base = cfg_get_u64(CFG_R_WEIGHT_BASE_LO, CFG_R_WEIGHT_BASE_HI);
          job_d.output_base = cfg_get_u64(CFG_R_OUTPUT_BASE_LO, CFG_R_OUTPUT_BASE_HI);
          job_d.scale_base  = cfg_get_u64(CFG_R_SCALE_BASE_LO,  CFG_R_SCALE_BASE_HI);
          job_d.zp_base     = cfg_get_u64(CFG_R_ZP_BASE_LO,     CFG_R_ZP_BASE_HI);

          job_d.lmem_ibuf0_base  = cfg_get_u64(CFG_R_LMEM_IBUF0_LO,  CFG_R_LMEM_IBUF0_HI);
          job_d.lmem_ibuf1_base  = cfg_get_u64(CFG_R_LMEM_IBUF1_LO,  CFG_R_LMEM_IBUF1_HI);
          job_d.lmem_wbuf0_base  = cfg_get_u64(CFG_R_LMEM_WBUF0_LO,  CFG_R_LMEM_WBUF0_HI);
          job_d.lmem_wbuf1_base  = cfg_get_u64(CFG_R_LMEM_WBUF1_LO,  CFG_R_LMEM_WBUF1_HI);
          job_d.lmem_scbuf0_base = cfg_get_u64(CFG_R_LMEM_SCBUF0_LO, CFG_R_LMEM_SCBUF0_HI);
          job_d.lmem_scbuf1_base = cfg_get_u64(CFG_R_LMEM_SCBUF1_LO, CFG_R_LMEM_SCBUF1_HI);
          job_d.lmem_zpbuf0_base = cfg_get_u64(CFG_R_LMEM_ZPBUF0_LO, CFG_R_LMEM_ZPBUF0_HI);
          job_d.lmem_zpbuf1_base = cfg_get_u64(CFG_R_LMEM_ZPBUF1_LO, CFG_R_LMEM_ZPBUF1_HI);
          job_d.lmem_obuf_base   = cfg_get_u64(CFG_R_LMEM_OBUF_LO,   CFG_R_LMEM_OBUF_HI);

          job_d.orig_M    = cfg_reg_if.regs[CFG_R_M_ORIG][31:0];
          job_d.orig_N    = cfg_reg_if.regs[CFG_R_N_ORIG][31:0];
          job_d.orig_K    = cfg_reg_if.regs[CFG_R_K_ORIG][31:0];
          job_d.orig_qblk = cfg_reg_if.regs[CFG_R_QBLK_ORIG][31:0];

          job_d.target_M = cfg_reg_if.regs[CFG_R_M_TARGET][31:0];
          job_d.target_N = cfg_reg_if.regs[CFG_R_N_TARGET][31:0];
          job_d.target_K = cfg_reg_if.regs[CFG_R_K_TARGET][31:0];
          job_d.m_start  = cfg_reg_if.regs[CFG_R_M_START][31:0];
          job_d.n_start  = cfg_reg_if.regs[CFG_R_N_START][31:0];
          job_d.log2_dma_mt = cfg_reg_if.regs[CFG_R_LOG2_DMA_MT][5:0];
          job_d.log2_dma_kt = cfg_reg_if.regs[CFG_R_LOG2_DMA_KT][5:0];
          job_d.log2_dma_nt = cfg_reg_if.regs[CFG_R_LOG2_DMA_NT][5:0];
          job_d.wtrans   = cfg_reg_if.regs[CFG_R_WTRANS][0];
          job_d.qdir     = cfg_reg_if.regs[CFG_R_QDIR][0];

          gemm_start_o = 1'b1;

          state_d = S_INIT_STRIDE_0;
        end
      end

      // ----------------------------------------------------------------------
      // Job-scope stride pre-compute (latched in always_ff). 2 cycles total.
      // No cmd emit; just hold while stride_q registers settle.
      // ----------------------------------------------------------------------
      S_INIT_STRIDE_0: begin
        state_d = S_INIT_STRIDE_1;
      end

      S_INIT_STRIDE_1: begin
        state_d = S_PRE0_LD_I;
      end

      // ----------------------------------------------------------------------
      // Warmup preload tile0 (buf0): I/W/SC/ZP then notify rid_tile(buf0)
      // ----------------------------------------------------------------------
      S_PRE0_LD_I: begin
        if (can_emit) begin
          mm_dim_t nt0, mt0, kt0;
          mm_tile_sz_t mt_eff0, nt_eff0, kt_eff0;
          nt0 = '0;
          mt0 = '0;
          kt0 = '0;
          tile_eff_sizes(nt0, mt0, kt0, mt_eff0, nt_eff0, kt_eff0);

          out_cmd_d   = make_dma_ld(job_q.lmem_ibuf0_base,
                                   input_tile_addr(job_q, mt0, kt0),
                                   (mt_eff0*kt_eff0*FP16_BYTES),
                                   1'b0, 1);
          out_cmd_d.rs1 = mt0;
          out_cmd_d.rs2 = kt0;
          out_cmd_d.rd  = 0;
          out_start_d = 1'b1;
          state_d     = S_PRE0_LD_W;
        end
      end

      S_PRE0_LD_W: begin
        if (can_emit) begin
          mm_dim_t nt0, mt0, kt0;
          mm_tile_sz_t mt_eff0, nt_eff0, kt_eff0;
          nt0 = '0;
          mt0 = '0;
          kt0 = '0;
          tile_eff_sizes(nt0, mt0, kt0, mt_eff0, nt_eff0, kt_eff0);

          out_cmd_d   = make_dma_ld(job_q.lmem_wbuf0_base,
                                   weight_tile_addr(job_q, nt0, kt0),
                                   (kt_eff0 * ceil_div_log2(nt_eff0, `CLOG2(INT4_BYTES))),
                                   1'b0, 1);
          out_cmd_d.rs1 = kt0;
          out_cmd_d.rs2 = nt0;
          out_cmd_d.rd  = 1;
          out_start_d = 1'b1;
          state_d     = S_PRE0_LD_SC;
        end
      end

      S_PRE0_LD_SC: begin
        if (can_emit) begin
          mm_dim_t nt0, mt0, kt0;
          mm_tile_sz_t mt_eff0, nt_eff0, kt_eff0;
          mm_group_t groups_eff;
          nt0 = '0;
          mt0 = '0;
          kt0 = '0;
          tile_eff_sizes(nt0, mt0, kt0, mt_eff0, nt_eff0, kt_eff0);

          if (!job_q.qdir) begin
            groups_eff = ceil_div_log2(u32_t'(kt_eff0), job_q.orig_qblk[5:0]);
            out_cmd_d = make_dma_ld(job_q.lmem_scbuf0_base,
                                    scale_tile_addr(job_q, nt0, kt0),
                                    (groups_eff*nt_eff0*FP16_BYTES),
                                    1'b0, 1);
            out_cmd_d.groups_eff = groups_eff;
          end else begin
            out_cmd_d = make_dma_ld(job_q.lmem_scbuf0_base,
                                    scale_tile_addr(job_q, nt0, kt0),
                                    qrow_qparam_tile_bytes(u32_t'(kt_eff0), u32_t'(nt_eff0), FP16_BYTES),
                                    1'b0, 1);
            out_cmd_d.groups_eff = kt_eff0;
          end
          out_cmd_d.rs2 = nt0;
          out_cmd_d.rd  = 2;
          out_start_d = 1'b1;
          state_d     = S_PRE0_LD_ZP;
        end
      end

      S_PRE0_LD_ZP: begin
        if (can_emit) begin
          mm_dim_t nt0, mt0, kt0;
          mm_tile_sz_t mt_eff0, nt_eff0, kt_eff0;
          mm_group_t groups_eff, groups_full;

          nt0 = '0;
          mt0 = '0;
          kt0 = '0;
          tile_eff_sizes(nt0, mt0, kt0, mt_eff0, nt_eff0, kt_eff0);

          groups_full = ceil_div_log2(u32_t'(KT_q), job_q.orig_qblk[5:0]);

          if (!job_q.qdir) begin
            groups_eff = ceil_div_log2(u32_t'(kt_eff0), job_q.orig_qblk[5:0]);
            out_cmd_d = make_dma_ld(job_q.lmem_zpbuf0_base,
                                    zp_tile_addr(job_q, nt0, kt0),
                                    (groups_eff*nt_eff0*INT16_BYTES),
                                    1'b0, 1);
            out_cmd_d.groups_eff = groups_eff;
          end else begin
            out_cmd_d = make_dma_ld(job_q.lmem_zpbuf0_base,
                                    zp_tile_addr(job_q, nt0, kt0),
                                    qrow_qparam_tile_bytes(u32_t'(kt_eff0), u32_t'(nt_eff0), INT16_BYTES),
                                    1'b0, 1);
            out_cmd_d.groups_eff = kt_eff0;
          end
          out_cmd_d.rs2 = nt0;
          out_cmd_d.rd  = 3;
          out_start_d = 1'b1;
          state_d     = S_PRE0_LD_DONE_NTF;
        end
      end

      S_PRE0_LD_DONE_NTF: begin
        if (can_emit) begin
          out_cmd_d   = make_notify_cmd(rid_tile(1'b0), (4*1 + 4), 1'b1);
          out_start_d = 1'b1;
          tile_cur_d  = 0;
          tile_cur_nt_d = '0;
          tile_cur_mt_d = '0;
          tile_cur_kt_d = '0;
          if (has_tile1_init && (tile_total > 1)) begin
            tile_pre_d  = 1;
            tile_pre_nt_d = nt1_init;
            tile_pre_mt_d = mt1_init;
            tile_pre_kt_d = kt1_init;
            pre_valid_d = 1'b1;
            state_d     = S_PRE1_LD_I;
          end else begin
            tile_pre_d  = 0;
            tile_pre_nt_d = '0;
            tile_pre_mt_d = '0;
            tile_pre_kt_d = '0;
            pre_valid_d = 1'b0;
            state_d     = S_WAIT_CUR_TILE_READY;
          end
        end
      end

      // ----------------------------------------------------------------------
      // Warmup preload tile1 (buf1)
      // ----------------------------------------------------------------------
      S_PRE1_LD_I: begin
        if (can_emit) begin
          mm_dim_t nt1, mt1, kt1;
          mm_tile_sz_t mt_eff1, nt_eff1, kt_eff1;
          nt1 = nt1_init;
          mt1 = mt1_init;
          kt1 = kt1_init;
          tile_eff_sizes(nt1, mt1, kt1, mt_eff1, nt_eff1, kt_eff1);

          out_cmd_d   = make_dma_ld(job_q.lmem_ibuf1_base,
                                   input_tile_addr(job_q, mt1, kt1),
                                   (mt_eff1*kt_eff1*FP16_BYTES),
                                   1'b1, 1);
          out_cmd_d.rs1 = mt1;
          out_cmd_d.rs2 = kt1;
          out_cmd_d.rd  = 0;
          out_start_d = 1'b1;
          state_d     = S_PRE1_LD_W;
        end
      end

      S_PRE1_LD_W: begin
        if (can_emit) begin
          mm_dim_t nt1, mt1, kt1;
          mm_tile_sz_t mt_eff1, nt_eff1, kt_eff1;
          nt1 = nt1_init;
          mt1 = mt1_init;
          kt1 = kt1_init;
          tile_eff_sizes(nt1, mt1, kt1, mt_eff1, nt_eff1, kt_eff1);

          out_cmd_d   = make_dma_ld(job_q.lmem_wbuf1_base,
                                   weight_tile_addr(job_q, nt1, kt1),
                                   (kt_eff1 * ceil_div_log2(nt_eff1, `CLOG2(INT4_BYTES))),
                                   1'b1, 1);
          out_cmd_d.rs1 = kt1;
          out_cmd_d.rs2 = nt1;
          out_cmd_d.rd  = 1;
          out_start_d = 1'b1;
          state_d     = S_PRE1_LD_SC;
        end
      end

      S_PRE1_LD_SC: begin
        if (can_emit) begin
          mm_dim_t nt1, mt1, kt1;
          mm_tile_sz_t mt_eff1, nt_eff1, kt_eff1;
          mm_group_t groups_eff;
          nt1 = nt1_init;
          mt1 = mt1_init;
          kt1 = kt1_init;
          tile_eff_sizes(nt1, mt1, kt1, mt_eff1, nt_eff1, kt_eff1);

          if (!job_q.qdir) begin
            groups_eff = ceil_div_log2(u32_t'(kt_eff1), job_q.orig_qblk[5:0]);
            out_cmd_d = make_dma_ld(job_q.lmem_scbuf1_base,
                                    scale_tile_addr(job_q, nt1, kt1),
                                    (groups_eff*nt_eff1*FP16_BYTES),
                                    1'b1, 1);
            out_cmd_d.groups_eff = groups_eff;
          end else begin
            out_cmd_d = make_dma_ld(job_q.lmem_scbuf1_base,
                                    scale_tile_addr(job_q, nt1, kt1),
                                    qrow_qparam_tile_bytes(u32_t'(kt_eff1), u32_t'(nt_eff1), FP16_BYTES),
                                    1'b1, 1);
            out_cmd_d.groups_eff = kt_eff1;
          end
          out_cmd_d.rs2 = nt1;
          out_cmd_d.rd  = 2;
          out_start_d = 1'b1;
          state_d     = S_PRE1_LD_ZP;
        end
      end

      S_PRE1_LD_ZP: begin
        if (can_emit) begin
          mm_dim_t nt1, mt1, kt1;
          mm_tile_sz_t mt_eff1, nt_eff1, kt_eff1;
          mm_group_t groups_eff, groups_full;

          nt1 = nt1_init;
          mt1 = mt1_init;
          kt1 = kt1_init;
          tile_eff_sizes(nt1, mt1, kt1, mt_eff1, nt_eff1, kt_eff1);

          groups_full = ceil_div_log2(u32_t'(KT_q), job_q.orig_qblk[5:0]);

          if (!job_q.qdir) begin
            groups_eff = ceil_div_log2(u32_t'(kt_eff1), job_q.orig_qblk[5:0]);
            out_cmd_d = make_dma_ld(job_q.lmem_zpbuf1_base,
                                    zp_tile_addr(job_q, nt1, kt1),
                                    (groups_eff*nt_eff1*INT16_BYTES),
                                    1'b1, 1);
            out_cmd_d.groups_eff = groups_eff;
          end else begin
            out_cmd_d = make_dma_ld(job_q.lmem_zpbuf1_base,
                                    zp_tile_addr(job_q, nt1, kt1),
                                    qrow_qparam_tile_bytes(u32_t'(kt_eff1), u32_t'(nt_eff1), INT16_BYTES),
                                    1'b1, 1);
            out_cmd_d.groups_eff = kt_eff1;
          end
          out_cmd_d.rs2 = nt1;
          out_cmd_d.rd  = 3;
          out_start_d = 1'b1;
          state_d     = S_PRE1_LD_DONE_NTF;
        end
      end

      S_PRE1_LD_DONE_NTF: begin
        if (can_emit) begin
          out_cmd_d   = make_notify_cmd(rid_tile(1'b1), (4*1 + 4), 1'b1);
          out_start_d = 1'b1;

          tile_cur_d  = 0;
          tile_cur_nt_d = '0;
          tile_cur_mt_d = '0;
          tile_cur_kt_d = '0;
          if (has_tile1_init) begin
            tile_pre_d  = 1;
            tile_pre_nt_d = nt1_init;
            tile_pre_mt_d = mt1_init;
            tile_pre_kt_d = kt1_init;
            pre_valid_d = 1'b1;
          end else begin
            tile_pre_d  = 0;
            tile_pre_nt_d = '0;
            tile_pre_mt_d = '0;
            tile_pre_kt_d = '0;
            pre_valid_d = 1'b0;
          end

          state_d     = S_WAIT_CUR_TILE_READY;
        end
      end

      // ----------------------------------------------------------------------
      // Wait current tile preload complete (rid_o reuse wait 제거)
      // ----------------------------------------------------------------------
      S_WAIT_CUR_TILE_READY: begin
        if (can_emit) begin
          out_cmd_d   = make_wait_cmd(rid_tile(buf_cur), in_ready_target_cur);
          out_start_d = 1'b1;

          nt_mxu_d  = 0;
          kt_mxu_d  = 0;
          mxu_buf_d = 1'b0;
          o_nt_mxu_d = 0;

          state_d   = S_MXU_PRE_CUR_W;
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

          // VX_gemm_node maps weight flags[1:0] to {load_dir, wr_idx}.
          flags      = {6'd0, job_q.wtrans, mxu_buf_q};
          c.flags    = flags;
          c.instr    = make_instr(OP_W_LDMA_MXU, (MXU_KT * (MXU_NT >> 1)));
          c.rs1_data = {63'd0, mxu_buf_q};
          c.rs2_data = lmem_w_mxu;
          c.bound    = 16'd1;

          out_cmd_d   = c;
          out_start_d = 1'b1;
          state_d     = S_MXU_PRE_CUR_W_NTF;
        end
      end

      S_MXU_PRE_CUR_W_NTF: begin
        if (can_emit) begin
          out_cmd_d   = make_notify_cmd(rid_w_mxu(mxu_buf_q), global_mxu_seq, 1'b1);
          out_start_d = 1'b1;
          state_d     = S_MXU_PRE_CUR_SC;
        end
      end

      // ----------------------------------------------------------------------
      // CUR SZ split: SC then ZP
      // ----------------------------------------------------------------------
      S_MXU_PRE_CUR_SC: begin
        if (can_emit) begin
          gemm_unified_cmd_t c;
          logic [7:0] flags;
          mm_bytecnt_t sc_bytes;

          c = '0;
          sc_bytes = job_q.qdir ? (MXU_KT * ng_mxu * FP16_BYTES)
                                : (groups_mxu * MXU_NT * FP16_BYTES);

          flags      = {5'd0, job_q.qdir, mxu_buf_q, buf_cur};
          c.flags    = flags;
          c.instr    = make_instr(OP_SC_LDMA_MXU, sc_bytes);
          c.rs1_data  = mxu_buf_q ? SCALE_REG1_BASE : SCALE_REG0_BASE;
          c.rs2_data  = lmem_sc_mxu;
          c.bound     = 16'd1;

          out_cmd_d   = c;
          out_start_d = 1'b1;
          state_d     = S_MXU_PRE_CUR_ZP;
        end
      end

      S_MXU_PRE_CUR_ZP: begin
        if (can_emit) begin
          gemm_unified_cmd_t c;
          logic [7:0] flags;
          mm_bytecnt_t zp_bytes;

          c = '0;
          zp_bytes = job_q.qdir ? (MXU_KT * ng_mxu * INT16_BYTES)
                                : (groups_mxu * MXU_NT * INT16_BYTES);

          flags      = {5'd0, job_q.qdir, mxu_buf_q, buf_cur};
          c.flags    = flags;
          c.instr    = make_instr(OP_ZP_LDMA_MXU, zp_bytes);
          c.rs1_data  = mxu_buf_q ? ZP_REG1_BASE : ZP_REG0_BASE;
          c.rs2_data  = lmem_zp_mxu;
          c.bound     = 16'd1;

          out_cmd_d   = c;
          out_start_d = 1'b1;
          state_d     = S_MXU_PRE_CUR_SZ_NTF;
        end
      end

      S_MXU_PRE_CUR_SZ_NTF: begin
        if (can_emit) begin
          out_cmd_d   = make_notify_cmd(rid_sz_mxu(mxu_buf_q), global_mxu_seq, 1'b1);
          out_start_d = 1'b1;
          state_d     = S_MXU_WAIT_CUR_W;
        end
      end

      S_MXU_WAIT_CUR_W: begin
        if (can_emit) begin
          out_cmd_d   = make_wait_cmd(rid_w_mxu(mxu_buf_q), global_mxu_seq);
          out_start_d = 1'b1;
          state_d     = S_MXU_WAIT_CUR_SZ;
        end
      end

      S_MXU_WAIT_CUR_SZ: begin
        if (can_emit) begin
          out_cmd_d   = make_wait_cmd(rid_sz_mxu(mxu_buf_q), global_mxu_seq);
          out_start_d = 1'b1;
          state_d     = S_MXU_PRE_NEXT_W;
        end
      end

      // ----------------------------------------------------------------------
      // NEXT W preload into next mxu_buf
      // ----------------------------------------------------------------------
      S_MXU_PRE_NEXT_W: begin
        if (can_emit) begin
          if (has_next_mxu) begin
            logic next_mxu_buf;
            gemm_unified_cmd_t c;
            logic [7:0] flags;

            next_mxu_buf = ~mxu_buf_q;
            c = '0;

            // VX_gemm_node maps weight flags[1:0] to {load_dir, wr_idx}.
            flags      = {6'd0, job_q.wtrans, next_mxu_buf};
            c.flags    = flags;
            c.instr    = make_instr(OP_W_LDMA_MXU, (MXU_KT * (MXU_NT >> 1)));
            c.rs1_data  = {63'd0, next_mxu_buf};
            c.rs2_data  = lmem_w_mxu_next;
            c.bound     = 16'd1;

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
          out_cmd_d   = make_notify_cmd(rid_w_mxu(~mxu_buf_q), next_global_mxu_seq, 1'b1);
          out_start_d = 1'b1;
          state_d     = S_MXU_PRE_NEXT_SC;
        end
      end

      // ----------------------------------------------------------------------
      // NEXT SZ split: SC then ZP
      // ----------------------------------------------------------------------
      S_MXU_PRE_NEXT_SC: begin
        if (can_emit) begin
          if (has_next_mxu) begin
            logic next_mxu_buf;
            gemm_unified_cmd_t c;
            logic [7:0] flags;
            mm_bytecnt_t sc_bytes;

            next_mxu_buf = ~mxu_buf_q;
            c = '0;
            sc_bytes = job_q.qdir ? (MXU_KT * ng_mxu * FP16_BYTES)
                                  : (groups_mxu * MXU_NT * FP16_BYTES);

            flags      = {5'd0, job_q.qdir, next_mxu_buf, buf_cur};
            c.flags    = flags;
            c.instr    = make_instr(OP_SC_LDMA_MXU, sc_bytes);
            c.rs1_data  = next_mxu_buf ? SCALE_REG1_BASE : SCALE_REG0_BASE;
            c.rs2_data  = lmem_sc_mxu_next;
            c.bound     = 16'd1;

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
          mm_bytecnt_t zp_bytes;

          next_mxu_buf = ~mxu_buf_q;
          c = '0;
          zp_bytes = job_q.qdir ? (MXU_KT * ng_mxu * INT16_BYTES)
                                : (groups_mxu * MXU_NT * INT16_BYTES);

          flags      = {5'd0, job_q.qdir, next_mxu_buf, buf_cur};
          c.flags    = flags;
          c.instr    = make_instr(OP_ZP_LDMA_MXU, zp_bytes);
          c.rs1_data  = next_mxu_buf ? ZP_REG1_BASE : ZP_REG0_BASE;
          c.rs2_data  = lmem_zp_mxu_next;
          c.bound     = 16'd1;

          out_cmd_d   = c;
          out_start_d = 1'b1;
          state_d     = S_MXU_PRE_NEXT_SZ_NTF;
        end
      end

      S_MXU_PRE_NEXT_SZ_NTF: begin
        if (can_emit) begin
          if (has_next_mxu) begin
            out_cmd_d   = make_notify_cmd(rid_sz_mxu(~mxu_buf_q), next_global_mxu_seq, 1'b1);
            out_start_d = 1'b1;
          end
          state_d     = S_MXU_ARM_GEMM;
        end
      end

      // ----------------------------------------------------------------------
      // ARM: Input LDMA triggers GEMM
      // ----------------------------------------------------------------------
      S_MXU_ARM_GEMM: begin
        if (can_emit) begin
          gemm_unified_cmd_t c;
          logic [7:0] flags;
          mm_bytecnt_t in_bytes;

          c = '0;

          // VX_gemm_node consumes:
          //   flags[5]=quant_dir, flags[3]=!is_load, flags[2:0]=w/s/z reg idx.
          flags     = {2'd0, job_q.qdir, 1'b0, is_accum, mxu_buf_q, mxu_buf_q, mxu_buf_q};
          in_bytes  = mt_eff_cur * MXU_KT * FP16_BYTES;

          c.flags   = flags;
          // VX_gemm_unit interprets instr[31:4] as acc_cnt, not byte count.
          // The input LDMA byte count is carried by bound * fixed seg_size in VX_gemm_node.
          c.instr   = make_instr(OP_I_LDMA_ARM, mt_eff_cur);
          c.rs1_data = lmem_out_slice;
          c.rs2_data = lmem_in_mxu;
          c.eff_mt   = mt_eff_cur;
          c.bound    = mt_eff_cur;
          c.stride   = MXU_KT * FP16_BYTES;

          out_cmd_d   = c;
          out_start_d = 1'b1;

          state_d     = S_MXU_ARM_GEMM_NTF;
        end
      end

      S_MXU_ARM_GEMM_NTF: begin
        if (can_emit) begin
          out_cmd_d   = make_notify_cmd(rid_g_mxu(mxu_buf_q), gemm_done_target, 1'b1);
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
            // MXU loop done for this DMA tile
            // 마지막 kt tile에서만 STORE
            if (last_kt_tile) begin
              o_nt_mxu_d = 0;
              state_d = S_O_WAIT_LMEM2DRAM_DONE;
            end else begin
              state_d = S_ADVANCE_TILES;
            end
          end
        end
      end

      // ----------------------------------------------------------------------
      // Output (only at last-kt tile): acc->lmem then lmem->dram
      // rid_o는 "이 store 2단계 순서"만 보장하는 용도로만 사용
      // ----------------------------------------------------------------------
      S_O_WAIT_LMEM2DRAM_DONE: begin
        if (can_emit) begin
          out_cmd_d   = make_wait_cmd(rid_o, 2*o_store_issue_q);
          out_start_d = 1'b1;
          state_d     = S_O_ACC2LMEM;
        end
      end
      
      S_O_ACC2LMEM: begin
        if (can_emit) begin
          gemm_unified_cmd_t c;
          logic [7:0] flags;

          c = '0;
          flags      = {7'd0, buf_cur};

          c.flags    = flags;
          c.instr    = make_instr(OP_O_ACC2LMEM, output_nb_bytes);
          c.rs1_data  = lmem_obuf_nb;              // dst
          c.rs2_data  = 64'(acc_group_base + (u32_t'(o_nt_mxu_q) * acc_nb_stride)) >> 1; // src
          c.bound     = mt_eff_cur;
          c.eff_mt    = mt_eff_cur;
          c.groups_eff = MXU_NT;

          out_cmd_d   = c;
          out_start_d = 1'b1;
          state_d     = S_O_ACC2LMEM_NTF;
        end
      end

      S_O_ACC2LMEM_NTF: begin
        if (can_emit) begin
          // stage1 완료 마커: rid_o = 1 (set)
          out_cmd_d   = make_notify_cmd(rid_o, 2*o_store_issue_q + 1, 1'b1);
          out_start_d = 1'b1;
          state_d     = S_O_WAIT_ACC2LMEM_DONE;
        end
      end

      S_O_WAIT_ACC2LMEM_DONE: begin
        if (can_emit) begin
          out_cmd_d   = make_wait_cmd(rid_o, 2*o_store_issue_q + 1);
          out_start_d = 1'b1;
          state_d     = S_O_LMEM2DRAM;
        end
      end

      S_O_LMEM2DRAM: begin
        if (can_emit) begin
          out_cmd_d   = make_dma_st(dram_out_nb,
                                    lmem_obuf_nb,
                                    output_nb_bytes,
                                    buf_cur, gen_cur);
          out_cmd_d.rs1 = mt_cur;
          out_cmd_d.rs2 = o_nt_mxu_q;
          out_cmd_d.rd  = 4;
          out_start_d = 1'b1;
          state_d     = S_O_LMEM2DRAM_NTF;
        end
      end

      S_O_LMEM2DRAM_NTF: begin
        if (can_emit) begin
          // stage2 완료 마커: rid_o += 1 (=> 2)
          out_cmd_d   = make_notify_cmd(rid_o, 1, 1'b0);
          out_start_d = 1'b1;
          o_store_issue_d = o_store_issue_q + 1;
          if (o_nt_mxu_q + 1 < output_nt_mxu_dim) begin
            o_nt_mxu_d = o_nt_mxu_q + 1;
            state_d = S_O_WAIT_LMEM2DRAM_DONE;
          end else begin
            state_d = S_ADVANCE_TILES;
          end
        end
      end

      // ----------------------------------------------------------------------
      // Advance tiles
      // ----------------------------------------------------------------------
      S_ADVANCE_TILES: begin
        nt_mxu_d  = 0;
        kt_mxu_d  = 0;
        mxu_buf_d = 1'b0;
        o_nt_mxu_d = 0;

        if (pre_valid_q) begin
          u32_t next_tile;
          logic has_next_tile;
          mm_dim_t nt_next, mt_next, kt_next;

          tile_cur_d = tile_pre_q;
          tile_cur_nt_d = tile_pre_nt_q;
          tile_cur_mt_d = tile_pre_mt_q;
          tile_cur_kt_d = tile_pre_kt_q;
          next_tile = tile_pre_q + 1;
          tile_next_coords(tile_pre_nt_q, tile_pre_mt_q, tile_pre_kt_q,
                           has_next_tile, nt_next, mt_next, kt_next);

          if (has_next_tile && (next_tile < tile_total)) begin
            tile_pre_d = next_tile;
            tile_pre_nt_d = nt_next;
            tile_pre_mt_d = mt_next;
            tile_pre_kt_d = kt_next;
            pre_valid_d = 1'b1;
            state_d = S_PRE_NEXT_LD_I;
          end else begin
            pre_valid_d = 1'b0;
            state_d = S_WAIT_CUR_TILE_READY;
          end
        end else begin
          // no prefetched tile exists: done
          state_d = S_O_WAIT_LMEM2DRAM_FINAL;
        end
      end

      S_O_WAIT_LMEM2DRAM_FINAL: begin
        if (can_emit) begin
          out_cmd_d   = make_wait_cmd(rid_o, 2*o_store_issue_q);
          out_start_d = 1'b1;
          state_d     = S_FINAL_CLEAR;
        end
      end

      S_FINAL_CLEAR: begin
        if (can_emit) begin
          gemm_unified_cmd_t c;
          c = '0;
          c.instr = make_instr(OP_CLEAR, 0);
          out_cmd_d = c;
          out_start_d = 1'b1;
          state_d = S_IDLE;
        end
      end
      // ----------------------------------------------------------------------
      // Preload next tile into freed buffer (single notify after ZP)
      // ----------------------------------------------------------------------
      S_PRE_NEXT_LD_I: begin
        if (can_emit) begin
          mm_dim_t ntp, mtp, ktp;
          mm_tile_sz_t mt_effp, nt_effp, kt_effp;
          logic buf_pre;
          u32_t gen_pre;

          ntp = tile_pre_nt_q;
          mtp = tile_pre_mt_q;
          ktp = tile_pre_kt_q;
          tile_eff_sizes(ntp, mtp, ktp, mt_effp, nt_effp, kt_effp);
          buf_pre = tile_pre_q[0];
          gen_pre = buf_gen(tile_pre_q);

          out_cmd_d   = make_dma_ld(ibuf_base(buf_pre),
                                    input_tile_addr(job_q, mtp, ktp),
                                    (mt_effp*kt_effp*FP16_BYTES),
                                    buf_pre, gen_pre);
          out_cmd_d.rs1 = mtp;
          out_cmd_d.rs2 = ktp;
          out_cmd_d.rd  = 0;
          out_start_d = 1'b1;
          state_d     = S_PRE_NEXT_LD_W;
        end
      end

      S_PRE_NEXT_LD_W: begin
        if (can_emit) begin
          mm_dim_t ntp, mtp, ktp;
          mm_tile_sz_t mt_effp, nt_effp, kt_effp;
          logic buf_pre;
          u32_t gen_pre;

          ntp = tile_pre_nt_q;
          mtp = tile_pre_mt_q;
          ktp = tile_pre_kt_q;
          tile_eff_sizes(ntp, mtp, ktp, mt_effp, nt_effp, kt_effp);
          buf_pre = tile_pre_q[0];
          gen_pre = buf_gen(tile_pre_q);

          out_cmd_d   = make_dma_ld(wbuf_base(buf_pre),
                                    weight_tile_addr(job_q, ntp, ktp),
                                    (kt_effp * ceil_div_log2(nt_effp, `CLOG2(INT4_BYTES))),
                                    buf_pre, gen_pre);
          out_cmd_d.rs1 = ktp;
          out_cmd_d.rs2 = ntp;
          out_cmd_d.rd  = 1;
          out_start_d = 1'b1;
          state_d     = S_PRE_NEXT_LD_SC;
        end
      end

      S_PRE_NEXT_LD_SC: begin
        if (can_emit) begin
          mm_dim_t ntp, mtp, ktp;
          mm_tile_sz_t mt_effp, nt_effp, kt_effp;
          logic buf_pre;
          u32_t gen_pre;
          mm_group_t groups_eff;

          ntp = tile_pre_nt_q;
          mtp = tile_pre_mt_q;
          ktp = tile_pre_kt_q;
          tile_eff_sizes(ntp, mtp, ktp, mt_effp, nt_effp, kt_effp);
          buf_pre = tile_pre_q[0];
          gen_pre = buf_gen(tile_pre_q);

          if (!job_q.qdir) begin
            groups_eff = ceil_div_log2(u32_t'(kt_effp), job_q.orig_qblk[5:0]);
            out_cmd_d = make_dma_ld(scbuf_base(buf_pre),
                                    scale_tile_addr(job_q, ntp, ktp),
                                    (groups_eff*nt_effp*FP16_BYTES),
                                    buf_pre, gen_pre);
            out_cmd_d.groups_eff = groups_eff;
          end else begin
            out_cmd_d = make_dma_ld(scbuf_base(buf_pre),
                                    scale_tile_addr(job_q, ntp, ktp),
                                    qrow_qparam_tile_bytes(u32_t'(kt_effp), u32_t'(nt_effp), FP16_BYTES),
                                    buf_pre, gen_pre);
            out_cmd_d.groups_eff = kt_effp;
          end
          out_cmd_d.rs2 = ntp;
          out_cmd_d.rd  = 2;
          out_start_d = 1'b1;
          state_d     = S_PRE_NEXT_LD_ZP;
        end
      end

      S_PRE_NEXT_LD_ZP: begin
        if (can_emit) begin
          mm_dim_t ntp, mtp, ktp;
          mm_tile_sz_t mt_effp, nt_effp, kt_effp;
          logic buf_pre;
          u32_t gen_pre;
          mm_group_t groups_eff, groups_full;

          ntp = tile_pre_nt_q;
          mtp = tile_pre_mt_q;
          ktp = tile_pre_kt_q;
          tile_eff_sizes(ntp, mtp, ktp, mt_effp, nt_effp, kt_effp);
          buf_pre = tile_pre_q[0];
          gen_pre = buf_gen(tile_pre_q);

          groups_full = ceil_div_log2(u32_t'(KT_q), job_q.orig_qblk[5:0]);

          if (!job_q.qdir) begin
            groups_eff = ceil_div_log2(u32_t'(kt_effp), job_q.orig_qblk[5:0]);
            out_cmd_d = make_dma_ld(zpbuf_base(buf_pre),
                                    zp_tile_addr(job_q, ntp, ktp),
                                    (groups_eff*nt_effp*INT16_BYTES),
                                    buf_pre, gen_pre);
            out_cmd_d.groups_eff = groups_eff;
          end else begin
            out_cmd_d = make_dma_ld(zpbuf_base(buf_pre),
                                    zp_tile_addr(job_q, ntp, ktp),
                                    qrow_qparam_tile_bytes(u32_t'(kt_effp), u32_t'(nt_effp), INT16_BYTES),
                                    buf_pre, gen_pre);
            out_cmd_d.groups_eff = kt_effp;
          end
          out_cmd_d.rs2 = ntp;
          out_cmd_d.rd  = 3;
          out_start_d = 1'b1;
          state_d     = S_PRE_NEXT_LD_DONE_NTF;
        end
      end

      S_PRE_NEXT_LD_DONE_NTF: begin
        if (can_emit) begin
          logic buf_pre;
          u32_t gen_pre;

          buf_pre = tile_pre_q[0];
          gen_pre = buf_gen(tile_pre_q);

          out_cmd_d   = make_notify_cmd(rid_tile(buf_pre), (4*gen_pre + 4), 1'b1);
          out_start_d = 1'b1;
          state_d     = S_WAIT_CUR_TILE_READY;
        end
      end

      default: state_d = S_IDLE;
    endcase

  end

`ifdef CHIPSCOPE
`ifdef DBG_SCOPE_GEMM
  localparam int DBG_BIT_W      = $bits(logic);
  localparam int DBG_U32_W      = $bits(u32_t);
  localparam int DBG_STATE_W    = $bits(state_t);
  localparam int DBG_INSTR8_W   = $bits(out_cmd_d.instr[7:0]);
  localparam int DBG_INSTR_W    = $bits(out_cmd_d.instr);
  localparam int DBG_FLAGS_W    = $bits(out_cmd_d.flags);
  localparam int DBG_XLEN_W     = $bits(out_cmd_d.rs1_data);
  localparam int DBG_REG_W      = $bits(out_cmd_d.rs1);
  localparam int DBG_EFF_MT_W   = $bits(out_cmd_d.eff_mt);

  localparam int DBG_GEMM_P0_PAYLOAD_W = (10 * DBG_BIT_W) + (2 * DBG_STATE_W) + DBG_INSTR8_W + DBG_FLAGS_W;
  localparam int DBG_GEMM_P1_PAYLOAD_W = (10 * DBG_U32_W) + DBG_BIT_W;
  localparam int DBG_GEMM_P2_PAYLOAD_W = DBG_INSTR_W + (2 * DBG_XLEN_W) + DBG_FLAGS_W + DBG_EFF_MT_W + DBG_U32_W + (3 * DBG_REG_W);

  localparam int DBG_GEMM_P0_W = (2 * DBG_U32_W);
  localparam int DBG_GEMM_P1_W = (12 * DBG_U32_W);
  localparam int DBG_GEMM_P2_W = (8 * DBG_U32_W);
  localparam int DBG_GEMM_P3_W = (10 * DBG_U32_W);

  localparam int DBG_GEMM_P0_PAD_W = DBG_GEMM_P0_W - DBG_GEMM_P0_PAYLOAD_W;
  localparam int DBG_GEMM_P1_PAD_W = DBG_GEMM_P1_W - DBG_GEMM_P1_PAYLOAD_W;
  localparam int DBG_GEMM_P2_PAD_W = DBG_GEMM_P2_W - DBG_GEMM_P2_PAYLOAD_W;

  `VX_STATIC_ASSERT(DBG_GEMM_P0_PAD_W >= 0, ("DBG_GEMM_P0 width underflow"));
  `VX_STATIC_ASSERT(DBG_GEMM_P1_PAD_W >= 0, ("DBG_GEMM_P1 width underflow"));
  `VX_STATIC_ASSERT(DBG_GEMM_P2_PAD_W >= 0, ("DBG_GEMM_P2 width underflow"));

  (* keep = "true", mark_debug = "true" *) wire [DBG_GEMM_P0_W-1:0] dbg_gemm_probe0 = {
      {DBG_GEMM_P0_PAD_W{1'b0}},
      reset,
      cfg_reg_if.valid,
      cfg_reg_if.ready,
      cfg_reg_if.regs[CFG_R_CONTROL][0],
      gemm_start_o,
      out_start_d,
      gemm_fsm_if.flag.idle,
      gemm_fsm_if.flag.done,
      pre_valid_q,
      mxu_buf_q,
      state_q,
      state_d,
      out_cmd_d.instr[7:0],
      out_cmd_d.flags
  };
  (* keep = "true", mark_debug = "true" *) wire [DBG_GEMM_P1_W-1:0] dbg_gemm_probe1 = {
      {DBG_GEMM_P1_PAD_W{1'b0}},
      tile_cur_q,
      tile_pre_q,
      u32_t'(tile_cur_nt_q),
      u32_t'(tile_cur_mt_q),
      u32_t'(tile_cur_kt_q),
      u32_t'(tile_pre_nt_q),
      u32_t'(tile_pre_mt_q),
      u32_t'(tile_pre_kt_q),
      u32_t'(nt_mxu_q),
      u32_t'(kt_mxu_q),
      o_store_issue_q
  };
  (* keep = "true", mark_debug = "true" *) wire [DBG_GEMM_P2_W-1:0] dbg_gemm_probe2 = {
      {DBG_GEMM_P2_PAD_W{1'b0}},
      out_cmd_d.instr,
      out_cmd_d.rs1_data,
      out_cmd_d.rs2_data,
      out_cmd_d.flags,
      out_cmd_d.eff_mt,
      out_cmd_d.groups_eff,
      out_cmd_d.rs1,
      out_cmd_d.rs2,
      out_cmd_d.rd
  };
  (* keep = "true", mark_debug = "true" *) wire [DBG_GEMM_P3_W-1:0] dbg_gemm_probe3 = {
      entry_id,
      M_orig,
      N_orig,
      K_orig,
      qblk_orig,
      M_target,
      N_target,
      K_target,
      wtrans_tot,
      qdir_tot
  };

  ila_gemm ila_gemm_inst (
    .clk    (clk),
    .probe0 (dbg_gemm_probe0),
    .probe1 (dbg_gemm_probe1),
    .probe2 (dbg_gemm_probe2),
    .probe3 (dbg_gemm_probe3)
  );
`endif
`endif

`ifndef SYNTHESIS
  task automatic log_tile_progress(
    input u32_t tile_i,
    input u32_t tile_total_i,
    input mm_dim_t nt_i,
    input mm_dim_t mt_i,
    input mm_dim_t kt_i,
    input logic has_next_i,
    input u32_t next_tile_i
  );
    u32_t tile_pct;
    u32_t nt_pct;
    u32_t mt_pct;
    u32_t kt_pct;
    begin
      tile_pct = (tile_total_i != 0) ? ((tile_i + 1) * 100) / tile_total_i : 0;
      nt_pct   = (nt_dim_q != 0) ? ((u32_t'(nt_i) + 1) * 100) / u32_t'(nt_dim_q) : 0;
      mt_pct   = (mt_dim_q != 0) ? ((u32_t'(mt_i) + 1) * 100) / u32_t'(mt_dim_q) : 0;
      kt_pct   = (kt_dim_q != 0) ? ((u32_t'(kt_i) + 1) * 100) / u32_t'(kt_dim_q) : 0;

      `TRACE(2, ("%m : [%0t] | GEMM_FSM_TILE_ADVANCE | {inst=%s, tile=%0d/%0d(%0d%%), loop_nt=%0d/%0d(%0d%%), loop_mt=%0d/%0d(%0d%%), loop_kt=%0d/%0d(%0d%%), has_next=%0d, next_tile=%0d}\n",
                $time, INSTANCE_ID,
                (tile_i + 1), tile_total_i, tile_pct,
                (u32_t'(nt_i) + 1), nt_dim_q, nt_pct,
                (u32_t'(mt_i) + 1), mt_dim_q, mt_pct,
                (u32_t'(kt_i) + 1), kt_dim_q, kt_pct,
                has_next_i, next_tile_i))
    end
  endtask

  function automatic string op_to_str(input logic [3:0] op);
    case (op)
      OP_WAIT:          return "WAIT";
      OP_NOTIFY:        return "NOTIFY";
      OP_DMA_LD:        return "DMA_LD";
      OP_DMA_ST:        return "DMA_ST";
      OP_W_LDMA_MXU:    return "W_LDMA_MXU";
      OP_SZ_LDMA_MXU:   return "SZ_LDMA_MXU";
      OP_I_LDMA_ARM:    return "I_LDMA_ARM";
      OP_O_ACC2LMEM:    return "O_ACC2LMEM";
      OP_CLEAR:         return "CLEAR";
      default:          return "UNKNOWN";
    endcase
  endfunction

  task automatic log_gemm_cmd_handshake(
    input state_t state_i,
    input gemm_unified_cmd_t cmd_i
  );
    logic [3:0]  op;
    logic [27:0] size_bytes;
    begin
      op         = cmd_i.instr[3:0];
      size_bytes = cmd_i.instr[31:4];

      `TRACE(2, ("%m : [%0t] | GEMM_FSM_CMD_ISSUE | {inst=%s, state=%0d, op=%s, op_raw=0x%02h, size=%0d, flags=0x%02h, rd=%0d, rs1_data=0x%0h, rs2_data=0x%0h, eff_mt=%0d, dbg_rs1=%0d, dbg_rs2=%0d, dbg_rd=%0d}\n",
                $time, INSTANCE_ID, state_i, op_to_str(op), op, size_bytes, cmd_i.flags, cmd_i.rd, cmd_i.rs1_data, cmd_i.rs2_data, cmd_i.eff_mt, cmd_i.rs1, cmd_i.rs2, cmd_i.rd))

      unique case (op)
        OP_WAIT: begin
          `TRACE(3, ("%m : [%0t] | GEMM_FSM_CMD_WAIT | {inst=%s, state=%0d, reg_id=%0d, target=%0d}\n",
                    $time, INSTANCE_ID, state_i, cmd_i.rs1_data[MM_RID_W-1:0], cmd_i.rs2_data[31:0]))
        end

        OP_NOTIFY: begin
          `TRACE(3, ("%m : [%0t] | GEMM_FSM_CMD_NOTIFY | {inst=%s, state=%0d, reg_id=%0d, set_mode=%0d, value=%0d}\n",
                    $time, INSTANCE_ID, state_i, cmd_i.rs1_data[MM_RID_W-1:0], cmd_i.rs2_data[31], cmd_i.rs2_data[30:0]))
        end

        OP_DMA_LD: begin
          `TRACE(3, ("%m : [%0t] | GEMM_FSM_CMD_DMA_LD | {inst=%s, state=%0d, lmem_dst=0x%0h, dram_src=0x%0h, tile_buf=%0d, gen=%0d, dbg_rs1=%0d, dbg_rs2=%0d, dbg_rd=%0d}\n",
                    $time, INSTANCE_ID, state_i, cmd_i.rs1_data, cmd_i.rs2_data, cmd_i.flags[0], cmd_i.flags[7:1], cmd_i.rs1, cmd_i.rs2, cmd_i.rd))
        end

        OP_DMA_ST: begin
          `TRACE(3, ("%m : [%0t] | GEMM_FSM_CMD_DMA_ST | {inst=%s, state=%0d, dram_dst=0x%0h, lmem_src=0x%0h, tile_buf=%0d, gen=%0d, dbg_rs1=%0d, dbg_rs2=%0d, dbg_rd=%0d}\n",
                    $time, INSTANCE_ID, state_i, cmd_i.rs1_data, cmd_i.rs2_data, cmd_i.flags[0], cmd_i.flags[7:1], cmd_i.rs1, cmd_i.rs2, cmd_i.rd))
        end

        OP_W_LDMA_MXU, OP_SZ_LDMA_MXU: begin
          `TRACE(3, ("%m : [%0t] | GEMM_FSM_CMD_MXU_LD | {inst=%s, state=%0d, op=%s, lmem_src=0x%0h, data_sel=0x%0h, qdir=%0d, wtrans=%0d, mxu_buf=%0d, tile_buf=%0d}\n",
                    $time, INSTANCE_ID, state_i, op_to_str(op), cmd_i.rs1_data, cmd_i.rs2_data, cmd_i.flags[4], cmd_i.flags[2], cmd_i.flags[1], cmd_i.flags[0]))
        end

        OP_I_LDMA_ARM: begin
          `TRACE(3, ("%m : [%0t] | GEMM_FSM_CMD_I_ARM | {inst=%s, state=%0d, accum_dst=0x%0h, input_src=0x%0h, qdir=%0d, is_last=%0d, is_accum=%0d, mxu_buf=%0d, tile_buf=%0d, eff_mt=%0d}\n",
                    $time, INSTANCE_ID, state_i, cmd_i.rs1_data, cmd_i.rs2_data, cmd_i.flags[4], cmd_i.flags[3], cmd_i.flags[2], cmd_i.flags[1], cmd_i.flags[0], cmd_i.eff_mt))
        end

        OP_O_ACC2LMEM: begin
          `TRACE(3, ("%m : [%0t] | GEMM_FSM_CMD_O_ACC2LMEM | {inst=%s, state=%0d, lmem_dst=0x%0h, accum_src=0x%0h, tile_buf=%0d}\n",
                    $time, INSTANCE_ID, state_i, cmd_i.rs1_data, cmd_i.rs2_data, cmd_i.flags[0]))
        end

        default: begin
          `TRACE(3, ("%m : [%0t] | GEMM_FSM_CMD_RAW | {inst=%s, state=%0d, instr=0x%08h, flags=0x%02h, rs1_data=0x%0h, rs2_data=0x%0h, eff_mt=%0d}\n",
                    $time, INSTANCE_ID, state_i, cmd_i.instr, cmd_i.flags, cmd_i.rs1_data, cmd_i.rs2_data, cmd_i.eff_mt))
        end
      endcase
    end
  endtask

`ifdef DBG_TRACE_GEMM_FSM
  always_ff @(posedge clk) begin
    if (!reset) begin
      if (out_start_d && gemm_fsm_if.flag.idle) begin
        log_gemm_cmd_handshake(state_q, out_cmd_d);
      end

      if ((state_q == S_ADVANCE_TILES) && pre_valid_q) begin
        mm_dim_t nt_next;
        mm_dim_t mt_next;
        mm_dim_t kt_next;
        u32_t tile_total_next;
        u32_t next_tile;
        logic has_next_tile;

        tile_total_next = u32_t'(mt_dim_q) * u32_t'(nt_dim_q) * u32_t'(kt_dim_q);
        next_tile       = tile_pre_q + 1;
        has_next_tile   = (next_tile < tile_total_next);
        nt_next = tile_pre_nt_q;
        mt_next = tile_pre_mt_q;
        kt_next = tile_pre_kt_q;

        log_tile_progress(tile_pre_q, tile_total_next, nt_next, mt_next, kt_next, has_next_tile, next_tile);
      end
    end
  end
`endif
`endif

endmodule
