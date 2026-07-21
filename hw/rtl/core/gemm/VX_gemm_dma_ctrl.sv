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
//  - stride도 src/dst 각각 32-bit 레지스터로 분리 (총 18개 regs)
// ------------------------------------------------------------

module VX_gemm_dma_ctrl import VX_gpu_pkg::*; #(
    parameter `STRING INSTANCE_ID = "",

    parameter logic [63:0] DMA_CFG_BASE_ADDR      = 64'h0,
    parameter int          DMA_CFG_STRIDE_BYTES   = 4,        // 32-bit regs
    parameter int          DMA_ENTRY_STRIDE_BYTES = (`DMA_CFG_REG_NUM * 4),
    parameter int          ENTRYID_W              = `JOB_MMIO_ENTRYID_W, // 엔트리 구분을 위한 ID 폭 (몇 개 엔트리까지 구분할 수 있나)
    parameter int          CTRL_OWNER_W           = `JOB_MMIO_OWNER_W,
    parameter int          CTRL_GEN_W             = `JOB_MMIO_GEN_W,

    parameter int          POLL_GAP_CYCLES        = 1,
    parameter int          ALLOC_RETRY_GAP_CYCLES = 0
) (
    input  wire                   clk,
    input  wire                   reset,

    VX_gemm_dma_ctrl_if.slave       gemm_dma_ctrl_if,
    VX_gemm_sync_if.master          gemm_sync_if,
    VX_lsu_mem_if.master            dma_if
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
  localparam logic [3:0] OP_DMA_LD  = 4'd1;
  localparam logic [3:0] OP_DMA_ST  = 4'd2;
  localparam logic [3:0] OP_NOTIFY  = 4'd3;

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
  // 주소 헬퍼
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

  gemm_unified_cmd_t cmd_q;
  wire logic [3:0] cmd_op = cmd_q.instr[3:0];

  // ============================================================
  // Direct command mapping
  //   - rs2_data: source base
  //   - rs1_data: destination base
  //   - stride[31:16]: DRAM-side stride0
  //   - stride[15:0] : LMEM-side stride0
  //   - bound       : bound0
  //   - instr[31:4] : seg_size
  // ============================================================
  logic [63:0] src_base, dst_base;
  logic        dir_is_st;
  logic [15:0] dram_stride0, lmem_stride0;
  logic [31:0] src_s0, src_s1, src_s2;
  logic [31:0] dst_s0, dst_s1, dst_s2;
  logic [31:0] bnd0, bnd1, bnd2;
  logic [31:0] seg_size;
  logic [31:0] padding;

  always_comb begin
    dir_is_st = 1'b0;
    src_base  = 64'd0;
    dst_base  = 64'd0;
    dram_stride0 = cmd_q.stride[31:16];
    lmem_stride0 = cmd_q.stride[15:0];

    src_s0 = 0; src_s1 = 0; src_s2 = 0;
    dst_s0 = 0; dst_s1 = 0; dst_s2 = 0;
    bnd0 = 1; bnd1 = 1; bnd2 = 1;
    seg_size = 0;
    padding  = 0;

    if (cmd_op == OP_DMA_LD || cmd_op == OP_DMA_ST) begin
      dir_is_st = (cmd_op == OP_DMA_ST);
      src_base  = cmd_q.rs2_data;
      dst_base  = cmd_q.rs1_data;
      bnd0      = {16'd0, cmd_q.bound};
      seg_size  = {4'd0, cmd_q.instr[31:4]};

      if (cmd_op == OP_DMA_LD) begin
        src_s0 = {16'd0, dram_stride0};
        dst_s0 = {16'd0, lmem_stride0};
      end else begin
        src_s0 = {16'd0, lmem_stride0};
        dst_s0 = {16'd0, dram_stride0};
      end
    end
  end

  // ============================================================
  // NOTIFY
  // ============================================================
  wire logic [4:0]  notify_rid   = cmd_q.rs1_data[4:0];
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

            // IMPORTANT: 0부터 시작해서 항상 DATA_SIZE 정렬 번들로 write
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
        gemm_sync_if.reg_idx = {27'd0, notify_rid};
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
        for (int l = 0; l < DMA_NUM_LANES; l++) begin
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
          next_base = base_idx + (DMA_NUM_LANES * REGS_PER_LANE);

          if (next_base > DMA_R_LAST) state_d = S_KICK_W;
          else                        wr_idx_d = next_base;
        end
      end

      // CONTROL write (start)
      S_KICK_W: begin
        logic [63:0] ctrl;

        dma_if.req_valid   = 1'b1;
        dma_if.req_data.rw = 1'b1;

        dma_if.req_data.mask    = '0;
        dma_if.req_data.byteen  = '0;
        dma_if.req_data.addr    = '0;
        dma_if.req_data.data    = '0;

        dma_if.req_data.mask[0] = 1'b1;

        // 32-bit only (CONTROL은 32-bit reg)
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

        dma_if.req_data.mask    = '0;
        dma_if.req_data.byteen  = '0;
        dma_if.req_data.addr    = '0;
        dma_if.req_data.data    = '0;

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
      state_q       <= S_IDLE;
      wr_idx_q      <= 0;
      poll_gap_q    <= 0;
      alloc_gap_q   <= 0;
      cmd_q         <= '0;
      entry_id_q    <= '0;
      alloc_owner_q <= '0;
      alloc_gen_q   <= '0;
    end else begin
      state_q       <= state_d;
      wr_idx_q      <= wr_idx_d;
      poll_gap_q    <= poll_gap_d;
      alloc_gap_q   <= alloc_gap_d;
      entry_id_q    <= entry_id_d;
      alloc_owner_q <= alloc_owner_d;
      alloc_gen_q   <= alloc_gen_d;

      if (state_q == S_IDLE && gemm_dma_ctrl_if.start) begin
        cmd_q        <= gemm_dma_ctrl_if.cmd;
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
      src_base[31:0],
      src_base[63:32],
      dst_base[31:0],
      dst_base[63:32],
      src_s0,
      dst_s0,
      bnd0,
      seg_size,
      padding
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
