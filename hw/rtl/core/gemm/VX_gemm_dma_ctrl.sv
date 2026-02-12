`include "VX_define.vh"

// ------------------------------------------------------------
// VX_gemm_dma_ctrl (데이터 타입 반영 버전)
//  - input  : fp16  (2B)
//  - weight : int4  (0.5B)  => N 방향 2개 packed => bytes_per_elem = 1/2
//  - scale  : fp16  (2B)
//  - zp     : int16 (2B)
//  - output : fp16  (2B)
// ------------------------------------------------------------
// DMA 레지스터 맵 (32-bit 단위)
//  - DMA 엔트리의 레지스터는 32-bit 단위
//  - src_base/dst_base만 64-bit (LO/HI 2개 레지스터로 분리)
//  - stride도 src/dst 각각 32-bit 레지스터로 분리 (총 32-bit regs)
// ------------------------------------------------------------

module VX_gemm_dma_ctrl import VX_gpu_pkg::*; #(
    parameter `STRING INSTANCE_ID = "",

    parameter logic [63:0] DMA_CFG_BASE_ADDR      = 64'h0,
    parameter int          DMA_CFG_STRIDE_BYTES   = 4,        // 32-bit regs
    parameter int          DMA_ENTRY_STRIDE_BYTES = 16 * 4,   // 16 regs * 4 bytes = 64 bytes/entry
    parameter int          ENTRYID_W              = 8,

    parameter int          POLL_GAP_CYCLES        = 1,
    parameter int          ALLOC_RETRY_GAP_CYCLES = 0
) (
    input  wire                   clk,
    input  wire                   reset,

    VX_config_entry_alloc_if.master alloc_if,
    VX_gemm_dma_ctrl_if.slave       gemm_dma_ctrl_if,
    VX_gemm_sync_if.master          gemm_sync_if,
    VX_lsu_mem_if.master            dma_if
);

  // ============================================================
  // Packing parameters
  // ============================================================
  localparam int REGS_PER_LANE = (dma_if.DATA_SIZE / DMA_CFG_STRIDE_BYTES);

  initial begin
    if ((dma_if.DATA_SIZE % DMA_CFG_STRIDE_BYTES) != 0) begin
      $fatal(1, "%s: dma_if.DATA_SIZE(%0d) must be multiple of %0d",
             INSTANCE_ID, dma_if.DATA_SIZE, DMA_CFG_STRIDE_BYTES);
    end
    if (REGS_PER_LANE <= 0) begin
      $fatal(1, "%s: REGS_PER_LANE must be >= 1 (DATA_SIZE=%0d)",
             INSTANCE_ID, dma_if.DATA_SIZE);
    end
  end

  // ============================================================
  // Opcodes
  // ============================================================
  localparam logic [7:0] OP_NOTIFY  = 8'hF1;
  localparam logic [7:0] OP_DMA_LD  = 8'h10;
  localparam logic [7:0] OP_DMA_ST  = 8'h11;

  // ============================================================
  // 엔트리 내부 레지스터 인덱스 (32-bit regs)
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

  localparam int DMA_R_LAST        = DMA_R_PAD;

  localparam int DMA_CTRL_START_BIT = 0;
  localparam int DMA_CTRL_DIR_BIT   = 1;

  // ============================================================
  // 타일 크기
  // ============================================================
  localparam int MT = 128;
  localparam int NT = 128;
  localparam int KT = 128;

  // ============================================================
  // 주소 헬퍼
  // ============================================================
  function automatic logic [63:0] entry_reg_byte_addr(
      input logic [ENTRYID_W-1:0] entry_id,
      input int                   reg_idx
  );
    return DMA_CFG_BASE_ADDR
         + 64'(entry_id) * 64'(DMA_ENTRY_STRIDE_BYTES)
         + 64'(reg_idx * DMA_CFG_STRIDE_BYTES);
  endfunction

  localparam int LSU_ADDR_SHIFT = `CLOG2(dma_if.DATA_SIZE);

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

  // ============================================================
  // 래치
  // ============================================================
  gemm_unified_cmd_t cmd_q;
  wire logic [7:0] cmd_op = cmd_q.instr[7:0];

  logic [31:0] M_tot_q, N_tot_q, K_tot_q;
  logic [31:0] M_tot_d, N_tot_d, K_tot_d;
  logic [31:0] owner_warp_q, owner_warp_d;

  // ============================================================
  // DMA 주소 매핑
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
  // 텐서 선택
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
  // 타일 인덱스/그룹
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
      T_ZP:     begin groups_eff = cmd_q.rs1; nt_idx = cmd_q.rs2; end
      default: ;
    endcase
  end

  // ============================================================
  // 마지막 타일 축소
  // ============================================================
  logic [31:0] mt_eff, nt_eff, kt_eff;

  always_comb begin
    if (M_tot_q == 0) mt_eff = MT;
    else             mt_eff = min_u32(MT, sat_sub_u32(M_tot_q, mt_idx * MT));

    if (N_tot_q == 0) nt_eff = NT;
    else             nt_eff = min_u32(NT, sat_sub_u32(N_tot_q, nt_idx * NT));

    if (K_tot_q == 0) kt_eff = KT;
    else             kt_eff = min_u32(KT, sat_sub_u32(K_tot_q, kt_idx * KT));

    if (mt_eff == 0) mt_eff = 32'd1;
    if (nt_eff == 0) nt_eff = 32'd1;
    if (kt_eff == 0) kt_eff = 32'd1;
  end

  // ============================================================
  // DRAM 레이아웃(바이트 단위)
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

        dram_s0  = K_tot_q * BPE_FP16; // 다음 row(M 방향)로 넘어가는 stride
        dram_b0  = mt_eff;             // row 개수
      end

      // WEIGHT: int4, shape [K, N] (N방향 2개 packed => N/2 bytes per row)
      T_WEIGHT: begin
        seg_size = (NT >> 1);
        padding  = ((NT - nt_eff) >> 1);

        dram_s0  = (N_tot_q >> 1);
        dram_b0  = kt_eff;
      end

      // SCALE: fp16
      T_SCALE: begin
        seg_size = NT * BPE_FP16;
        padding  = (NT - nt_eff) * BPE_FP16;

        dram_s0  = N_tot_q * BPE_FP16;
        dram_b0  = groups_eff;
      end

      // ZP: int16
      T_ZP: begin
        seg_size = NT * BPE_INT16;
        padding  = (NT - nt_eff) * BPE_INT16;

        dram_s0  = N_tot_q * BPE_INT16;
        dram_b0  = groups_eff;
      end

      // OUTPUT: fp16, shape [M, N]
      T_OUTPUT: begin
        dram_s0  = N_tot_q * BPE_FP16;
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
  // LMEM 레이아웃(바이트 단위)
  // ============================================================
  logic [31:0] lmem_s0, lmem_s1, lmem_s2;

  always_comb begin
    lmem_s0 = 0; lmem_s1 = 0; lmem_s2 = 0;
    unique case (tensor_sel)
      T_INPUT:  lmem_s0 = KT * BPE_FP16;
      T_WEIGHT: lmem_s0 = (NT >> 1);
      T_SCALE:  lmem_s0 = NT * BPE_FP16;
      T_ZP:     lmem_s0 = NT * BPE_INT16;
      T_OUTPUT: lmem_s0 = NT * BPE_FP16;  //lmem에는 padding 포함
      default: ;
    endcase
  end

  // ============================================================
  // 최종 src/dst stride + bounds
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

  // ============================================================
  // NOTIFY
  // ============================================================
  wire logic [7:0]  notify_rid   = cmd_q.rs1_data[7:0];
  wire logic [31:0] notify_value = cmd_q.rs2_data[31:0];

  // ============================================================
  // MMIO write 데이터 생성 (32-bit regs)
  // ============================================================
  function automatic logic [31:0] prog_w_data(input int idx);
    logic [31:0] v32;
    begin
      v32 = 32'd0;
      unique case (idx)
        DMA_R_CONTROL:     v32 = 32'd0; // bundle에서는 0으로 한번 써도 OK (실제 kick은 S_KICK_W)
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

        DMA_R_BND0:        v32 = bnd0;
        DMA_R_BND1:        v32 = bnd1;
        DMA_R_BND2:        v32 = bnd2;
        DMA_R_SEG_SIZE:    v32 = seg_size;
        DMA_R_PAD:         v32 = padding;

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

  assign gemm_dma_ctrl_if.idle = (state_q == S_IDLE);
  assign gemm_dma_ctrl_if.done = (state_q == S_DONE);

  // ============================================================
  // Comb
  // ============================================================
  always_comb begin
    state_d      = state_q;
    wr_idx_d     = wr_idx_q;
    poll_gap_d   = poll_gap_q;
    alloc_gap_d  = alloc_gap_q;
    entry_id_d   = entry_id_q;

    owner_warp_d = owner_warp_q;
    M_tot_d      = M_tot_q;
    N_tot_d      = N_tot_q;
    K_tot_d      = K_tot_q;

    // dma_if 기본값
    dma_if.req_valid = 1'b0;
    dma_if.req_data  = '0;
    dma_if.rsp_ready = 1'b1;

    dma_if.req_data.mask      = '0;
    dma_if.req_data.flags     = '0;
    dma_if.req_data.byteen    = '0;
    dma_if.req_data.addr      = '0;
    dma_if.req_data.data      = '0;

    // gemm_sync 기본값
    gemm_sync_if.valid   = 1'b0;
    gemm_sync_if.reg_idx = 32'd0;
    gemm_sync_if.value   = 32'd0;

    // alloc_if 기본값
    alloc_if.valid      = 1'b0;
    alloc_if.owner_warp = 32'd0;

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
        alloc_if.valid      = 1'b1;
        alloc_if.owner_warp = owner_warp_q;

        if (alloc_if.ready) begin
          entry_id_d = alloc_if.entry_id[ENTRYID_W-1:0];

          // IMPORTANT: 0부터 시작해서 항상 DATA_SIZE 정렬 번들로 write
          wr_idx_d   = DMA_R_CONTROL;

          state_d    = S_PROG_W;
        end else if (ALLOC_RETRY_GAP_CYCLES > 0) begin
          alloc_gap_d = ALLOC_RETRY_GAP_CYCLES;
          state_d     = S_ALLOC_WAIT_GAP;
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

      // 레지스터 번들 write (NUM_LANES 병렬, lane당 DATA_SIZE 바이트를 꽉 채워서 씀)
      S_PROG_W: begin
        int base_idx;
        base_idx = wr_idx_q;

        dma_if.req_valid   = 1'b1;
        dma_if.req_data.rw = 1'b1;

        dma_if.req_data.mask   = '0;
        dma_if.req_data.byteen = '0;
        dma_if.req_data.addr   = '0;
        dma_if.req_data.data   = '0;

        // lane 한 개가 한 번에 쓸 수 있는 바이트(DATA_SIZE)를 32-bit regs로 꽉 채움
        for (int l = 0; l < dma_if.NUM_LANES; l++) begin
          int idx0;
          idx0 = base_idx + (l * REGS_PER_LANE);

          if (idx0 <= DMA_R_LAST) begin
            dma_if.req_data.mask[l] = 1'b1;

            // addr는 lane이 담당하는 "첫 32-bit reg"의 주소 (여기서 idx0는 항상 정렬됨)
            dma_if.req_data.addr[l] = to_lsu_addr(entry_reg_byte_addr(entry_id_q, idx0));

            // pack: idx0 -> data[31:0], idx0+1 -> data[63:32], ...
            for (int w = 0; w < REGS_PER_LANE; w++) begin
              int idx;
              idx = idx0 + w;

              if (idx <= DMA_R_LAST) begin
                dma_if.req_data.data[l][(w*32) +: 32] = prog_w_data(idx);

                // enable 해당 4바이트
                dma_if.req_data.byteen[l][(w*4) +: 4] = 4'b1111;
              end
            end
          end
        end

        if (dma_if.req_valid && dma_if.req_ready) begin
          int next_base;
          next_base = base_idx + (dma_if.NUM_LANES * REGS_PER_LANE);

          if (next_base > DMA_R_LAST) state_d = S_KICK_W;
          else                        wr_idx_d = next_base;
        end
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

        // 32-bit only (CONTROL은 32-bit reg)
        dma_if.req_data.byteen[0][3:0] = 4'b1111;

        dma_if.req_data.addr[0] = to_lsu_addr(entry_reg_byte_addr(entry_id_q, DMA_R_CONTROL));

        ctrl = 64'd0;
        ctrl[DMA_CTRL_DIR_BIT]   = dir_is_st;
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
          rdata = dma_if.rsp_data.data[0];

          if (rdata[DMA_CTRL_START_BIT] == 1'b0) begin
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

      owner_warp_q <= 32'd0;
      M_tot_q      <= 32'd0;
      N_tot_q      <= 32'd0;
      K_tot_q      <= 32'd0;
    end else begin
      state_q      <= state_d;
      wr_idx_q     <= wr_idx_d;
      poll_gap_q   <= poll_gap_d;
      alloc_gap_q  <= alloc_gap_d;
      entry_id_q   <= entry_id_d;

      owner_warp_q <= owner_warp_d;
      M_tot_q      <= M_tot_d;
      N_tot_q      <= N_tot_d;
      K_tot_q      <= K_tot_d;

      if (state_q == S_IDLE && gemm_dma_ctrl_if.start) begin
        cmd_q        <= gemm_dma_ctrl_if.cmd;

        M_tot_q      <= gemm_dma_ctrl_if.M_tot;
        N_tot_q      <= gemm_dma_ctrl_if.N_tot;
        K_tot_q      <= gemm_dma_ctrl_if.K_tot;
        owner_warp_q <= gemm_dma_ctrl_if.wid;
      end
    end
  end

endmodule
