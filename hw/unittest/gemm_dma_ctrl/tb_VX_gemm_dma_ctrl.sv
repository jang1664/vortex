`timescale 1ns/1ps
`include "VX_define.vh"

// -----------------------------------------------------------------------------
// tb_VX_gemm_dma_ctrl.sv
//
// - alloc_if: TB가 allocator(slave)로서 ready/entry_id를 구동
// - dma_if  : DUT가 master, TB가 slave로서 req를 받아 MMIO 메모리 모델링
// - gemm_dma_ctrl_if: TB가 master처럼 start/cmd/...를 구동 (DUT는 slave)
//
// 이 TB는 아래를 검증:
//  1) S_PROG_W에서 "DATA_SIZE 바이트" 단위 packed write가 실제 32-bit reg 공간에
//     올바르게 반영되는지 (mem_byte 기반으로 reg32 읽어서 체크)
//  2) S_KICK_W의 CONTROL(start=1) write 이후, POLL read에서 start bit이 0이 될 때까지
//     기다리는 흐름이 정상인지 (TB가 LAT_DMA_DONE 후 start bit clear)
//  3) OP_NOTIFY가 gemm_sync_if로 나가는지(ready=1로 sink)
//
// NOTE: gemm_sync_if 인터페이스 정의는 여기서 제공되지 않았으니,
//       아래에서 gemm_sync_if.valid/reg_idx/value/ready 가 있다고 가정.
//       만약 필드명이 다르면 그 3~4줄만 바꿔주면 됨.
//
// IMPORTANT (VCS ICPD 방지):
//  - always_ff로 구동되는 변수(saw_notify, done_ev.* 등)는
//    다른 프로세스(initial/task/다른 always_ff)에서 절대 쓰지 않음.
//  - 필요한 경우 "요청 신호(clear_notify_req)"는 initial에서만 구동하고,
//    always_ff에서는 그 신호를 읽기만 함.
// -----------------------------------------------------------------------------

module tb_VX_gemm_dma_ctrl;
  import VX_gpu_pkg::*;

  // -----------------------
  // TB parameters
  // -----------------------
  localparam int CLK_PERIOD_NS = 10;
  localparam int LAT_DMA_DONE  = 8;

  // DUT 파라미터와 맞춰야 함
  localparam longint unsigned DMA_CFG_BASE_ADDR_TB      = 64'h0;
  localparam int              DMA_CFG_STRIDE_BYTES_TB   = 4;
  localparam int              DMA_ENTRY_STRIDE_BYTES_TB = 16 * 4; // 64B

  // 엔트리 내부 레지스터 인덱스 (DUT와 동일)
  localparam int DMA_R_CONTROL     = 0;
  localparam int DMA_R_DST_BASE_LO = 1;
  localparam int DMA_R_DST_BASE_HI = 2;
  localparam int DMA_R_SRC_BASE_LO = 3;
  localparam int DMA_R_SRC_BASE_HI = 4;

  localparam int DMA_R_SRC_ST0     = 5;
  localparam int DMA_R_DST_ST0     = 6;
  localparam int DMA_R_SRC_ST1     = 7;
  localparam int DMA_R_DST_ST1     = 8;
  localparam int DMA_R_SRC_ST2     = 9;
  localparam int DMA_R_DST_ST2     = 10;

  localparam int DMA_R_BND0        = 11;
  localparam int DMA_R_BND1        = 12;
  localparam int DMA_R_BND2        = 13;
  localparam int DMA_R_SEG_SIZE    = 14;
  localparam int DMA_R_PAD         = 15;

  localparam int DMA_CTRL_START_BIT = 0;
  localparam int DMA_CTRL_DIR_BIT   = 1;

  // -----------------------
  // clock/reset
  // -----------------------
  logic clk, reset;
  initial clk = 1'b0;
  always #(CLK_PERIOD_NS/2) clk = ~clk;

  // -----------------------
  // Interfaces
  // -----------------------
  VX_config_entry_alloc_if alloc_if();
  VX_gemm_dma_ctrl_if      gemm_dma_ctrl_if();
  VX_gemm_sync_if          gemm_sync_if();
  VX_lsu_mem_if #(
    // 필요하면 프로젝트 기본값에 맞게 override
    .NUM_LANES(4),
    .DATA_SIZE(16),
    .TAG_WIDTH(1)
  ) dma_if();

  // -----------------------
  // DUT
  // -----------------------
  VX_gemm_dma_ctrl #(
    .INSTANCE_ID("tb"),
    .DMA_CFG_BASE_ADDR(DMA_CFG_BASE_ADDR_TB),
    .DMA_CFG_STRIDE_BYTES(DMA_CFG_STRIDE_BYTES_TB),
    .DMA_ENTRY_STRIDE_BYTES(DMA_ENTRY_STRIDE_BYTES_TB),
    .ENTRYID_W(8),
    .POLL_GAP_CYCLES(1),
    .ALLOC_RETRY_GAP_CYCLES(0)
  ) dut (
    .clk(clk),
    .reset(reset),

    .alloc_if(alloc_if),
    .gemm_dma_ctrl_if(gemm_dma_ctrl_if),
    .gemm_sync_if(gemm_sync_if),
    .dma_if(dma_if)
  );

  localparam int NUM_LANES = 4;
  localparam int DATA_SIZE = 16;
  localparam int SHIFT     = `CLOG2(DATA_SIZE);

  typedef struct packed {
      logic [0:0] uuid;
      logic [1:0] value;
  } tag_t;

  typedef struct packed {
      logic [NUM_LANES-1:0]                  mask;
      logic [NUM_LANES-1:0][DATA_SIZE*8-1:0] data;
      tag_t                                  tag;
  } rsp_data_t;

  // =============================================================================
  // 1) alloc_if model (TB = slave allocator)
  // =============================================================================
  logic [7:0] alloc_next_id;

  always_ff @(posedge clk) begin
    if (reset) begin
      alloc_next_id     <= 8'd1;
      alloc_if.ready    <= 1'b0;
      alloc_if.entry_id <= '0;
    end else begin
      alloc_if.ready <= 1'b1;

      if (alloc_if.valid && alloc_if.ready) begin
        alloc_if.entry_id <= alloc_next_id;
        $display("[%0t] ALLOC: owner_warp=%0d -> entry_id=%0d",
                 $time, alloc_if.owner_warp, alloc_next_id);
        alloc_next_id <= alloc_next_id + 8'd1;
      end
    end
  end

  // =============================================================================
  // 2) gemm_sync_if sink (always ready) + notify monitor
  // =============================================================================
  assign gemm_sync_if.ready = 1'b1;

  logic        saw_notify;
  logic [31:0] saw_notify_reg;
  logic [31:0] saw_notify_val;

  // clear 요청은 initial에서만 구동 (always_ff는 읽기만 함)
  logic clear_notify_req = 1'b0;

  always_ff @(posedge clk) begin
    if (reset) begin
      saw_notify     <= 1'b0;
      saw_notify_reg <= '0;
      saw_notify_val <= '0;
    end else begin
      // clear 요청 처리 (요청 신호 자체는 여기서 쓰지 않음!)
      if (clear_notify_req) begin
        saw_notify     <= 1'b0;
        saw_notify_reg <= '0;
        saw_notify_val <= '0;
      end

      if (gemm_sync_if.valid && gemm_sync_if.ready) begin
        saw_notify     <= 1'b1;
        saw_notify_reg <= gemm_sync_if.reg_idx;
        saw_notify_val <= gemm_sync_if.value;
        $display("[%0t] NOTIFY: reg=%0d val=0x%08x", $time, gemm_sync_if.reg_idx, gemm_sync_if.value);
      end
    end
  end

  // =============================================================================
  // 3) dma_if model (TB = slave)
  // =============================================================================

  // byte-addressable sparse memory
  typedef logic [7:0] byte_t;
  byte_t mem_byte [longint unsigned];

  // slave outputs we drive
  always_ff @(posedge clk) begin
    if (reset) begin
      dma_if.req_ready <= 1'b0;
    end else begin
      dma_if.req_ready <= 1'b1;
    end
  end

  // pending read response (hold until rsp_ready handshake)
  logic      pending_rsp;
  rsp_data_t pending_rsp_data;

  // CONTROL done event (단, done_ev는 "딱 한 always_ff"에서만 구동!)
  typedef struct packed {
    bit              valid;
    longint unsigned ctrl_base_ba; // aligned byte address (DATA_SIZE aligned)
    int              countdown;
  } done_ev_t;

  done_ev_t done_ev;

  function automatic longint unsigned lsu_addr_to_byte(input logic [dma_if.ADDR_WIDTH-1:0] a);
    longint unsigned ua;
    begin
      ua = $unsigned(a);
      return (ua << SHIFT);
    end
  endfunction

  task automatic mmio_write_lane(
    input longint unsigned base_ba,
    input logic [DATA_SIZE*8-1:0] wdata,
    input logic [DATA_SIZE-1:0]   byteen
  );
    for (int b = 0; b < DATA_SIZE; b++) begin
      if (byteen[b]) begin
        mem_byte[base_ba + b] = wdata[(8*b) +: 8];
      end
    end
  endtask

  function automatic logic [DATA_SIZE*8-1:0] mmio_read_lane(input longint unsigned base_ba);
    logic [DATA_SIZE*8-1:0] r;
    r = '0;
    for (int b = 0; b < DATA_SIZE; b++) begin
      if (mem_byte.exists(base_ba + b))
        r[(8*b) +: 8] = mem_byte[base_ba + b];
      else
        r[(8*b) +: 8] = 8'h00;
    end
    return r;
  endfunction

  // req 받아 처리 + read rsp 만들기 + done_ev countdown/clear까지 "한 always_ff"에서 처리
  always_ff @(posedge clk) begin
    if (reset) begin
      dma_if.rsp_valid    <= 1'b0;
      dma_if.rsp_data     <= '0;
      pending_rsp         <= 1'b0;
      pending_rsp_data    <= '0;

      done_ev.valid        <= 1'b0;
      done_ev.ctrl_base_ba <= '0;
      done_ev.countdown    <= 0;
    end else begin
      // -------------------------
      // (A) done_ev 진행/완료 처리
      // -------------------------
      if (done_ev.valid) begin
        if (done_ev.countdown > 0) begin
          done_ev.countdown <= done_ev.countdown - 1;
        end else begin
          // clear CONTROL start bit: byte0 bit0
          if (!mem_byte.exists(done_ev.ctrl_base_ba + 0))
            mem_byte[done_ev.ctrl_base_ba + 0] = 8'h00;
          else
            mem_byte[done_ev.ctrl_base_ba + 0] = mem_byte[done_ev.ctrl_base_ba + 0] & 8'hFE;

          $display("[%0t] DMA DONE: clear start bit @0x%0h", $time, done_ev.ctrl_base_ba);
          done_ev.valid <= 1'b0;
        end
      end

      // -------------------------
      // (B) rsp_valid handshake
      // -------------------------
      if (dma_if.rsp_valid && dma_if.rsp_ready) begin
        dma_if.rsp_valid <= 1'b0;
      end

      // pending rsp가 있고 아직 rsp_valid가 아니면 올려줌
      if (pending_rsp && !dma_if.rsp_valid) begin
        dma_if.rsp_valid <= 1'b1;
        dma_if.rsp_data  <= pending_rsp_data;
        pending_rsp      <= 1'b0;
      end

      // -------------------------
      // (C) request accept
      // -------------------------
      if (dma_if.req_valid && dma_if.req_ready) begin
        if (dma_if.req_data.rw) begin
          // WRITE
          for (int l = 0; l < NUM_LANES; l++) begin
            if (dma_if.req_data.mask[l]) begin
              longint unsigned ba;
              ba = lsu_addr_to_byte(dma_if.req_data.addr[l]);

              mmio_write_lane(ba, dma_if.req_data.data[l], dma_if.req_data.byteen[l]);

              // CONTROL kick 감지:
              // - start bit은 data의 byte0 bit0 (LSB)
              // - CONTROL reg0의 base byte addr는 entry_base + 0 이고,
              //   entry_base는 64B 단위이므로 (ba % 64 == 0)로 판별
              if ((ba % DMA_ENTRY_STRIDE_BYTES_TB) == 0) begin
                // byte0 enable + start bit 1이면 schedule done
                if (dma_if.req_data.byteen[l][0] && dma_if.req_data.data[l][0]) begin
                  done_ev.valid        <= 1'b1;
                  done_ev.ctrl_base_ba <= ba;
                  done_ev.countdown    <= LAT_DMA_DONE;
                  $display("[%0t] CONTROL START seen @0x%0h (done in %0d cycles)",
                           $time, ba, LAT_DMA_DONE);
                end
              end
            end
          end
        end else begin
          // READ -> rsp 생성해서 pending에 넣기
          rsp_data_t tmp_rsp;
          tmp_rsp = '0;
          tmp_rsp.mask = dma_if.req_data.mask;
          tmp_rsp.tag  = dma_if.req_data.tag;

          for (int l = 0; l < NUM_LANES; l++) begin
            if (dma_if.req_data.mask[l]) begin
              longint unsigned ba;
              ba = lsu_addr_to_byte(dma_if.req_data.addr[l]);
              tmp_rsp.data[l] = mmio_read_lane(ba);
            end else begin
              tmp_rsp.data[l] = '0;
            end
          end

          // rsp_valid가 비어있으면 바로 올리고, 아니면 pending에 적재
          if (!dma_if.rsp_valid && !pending_rsp) begin
            dma_if.rsp_valid <= 1'b1;
            dma_if.rsp_data  <= tmp_rsp;
          end else begin
            pending_rsp      <= 1'b1;
            pending_rsp_data <= tmp_rsp;
          end
        end
      end
    end
  end

  // =============================================================================
  // 4) TB stimulus helpers
  // =============================================================================
  localparam logic [7:0] OP_NOTIFY  = 8'hF1;
  localparam logic [7:0] OP_DMA_LD  = 8'h10;
  localparam logic [7:0] OP_DMA_ST  = 8'h11;

  function automatic logic [31:0] make_instr(input logic [7:0] op);
    return {24'd0, op};
  endfunction

  task automatic pulse_start();
    gemm_dma_ctrl_if.start <= 1'b1;
    @(posedge clk);
    gemm_dma_ctrl_if.start <= 1'b0;
  endtask

  task automatic wait_done();
    while (!gemm_dma_ctrl_if.done) @(posedge clk);
    @(posedge clk);
  endtask

  // =============================================================================
  // 5) Scoreboard: reg32 read helper from mem_byte
  // =============================================================================
  function automatic longint unsigned entry_reg_addr_byte(input int entry_id, input int reg_idx);
    int idx;
    idx = (entry_id > 0) ? (entry_id - 1) : 0;  // entry_id=1 -> idx=0
    return DMA_CFG_BASE_ADDR_TB
        + (64'(idx)     * DMA_ENTRY_STRIDE_BYTES_TB)
        + (64'(reg_idx) * DMA_CFG_STRIDE_BYTES_TB);
  endfunction

  function automatic logic [31:0] mmio_read_reg32(input int entry_id, input int reg_idx);
    longint unsigned a;
    logic [31:0] v;
    a = entry_reg_addr_byte(entry_id, reg_idx);
    v = '0;
    for (int b=0; b<4; b++) begin
      if (mem_byte.exists(a+b)) v[(8*b)+:8] = mem_byte[a+b];
      else                      v[(8*b)+:8] = 8'h00;
    end
    return v;
  endfunction

  task automatic expect_reg32(input int entry_id, input int reg_idx, input logic [31:0] exp);
    logic [31:0] got;
    got = mmio_read_reg32(entry_id, reg_idx);
    if (got !== exp) begin
      $fatal(1, "REG MISMATCH entry=%0d reg[%0d]: got=0x%08x exp=0x%08x",
             entry_id, reg_idx, got, exp);
    end else begin
      $display("[%0t] OK entry=%0d reg[%0d]=0x%08x", $time, entry_id, reg_idx, got);
    end
  endtask

  // =============================================================================
  // 6) Main test
  // =============================================================================
  initial begin
    int used_entry;
    gemm_unified_cmd_t c;

    // defaults
    gemm_dma_ctrl_if.start <= 1'b0;
    gemm_dma_ctrl_if.cmd   <= '0;
    gemm_dma_ctrl_if.M_tot <= 32'd0;
    gemm_dma_ctrl_if.N_tot <= 32'd0;
    gemm_dma_ctrl_if.K_tot <= 32'd0;
    gemm_dma_ctrl_if.wid   <= 32'd0;

    reset = 1'b1;
    repeat (5) @(posedge clk);
    reset = 1'b0;
    repeat (2) @(posedge clk);

    // -------------------------
    // Test #1: DMA_LD INPUT tile
    // -------------------------
    used_entry = 1; // alloc_next_id 초기값이 1이므로 첫 할당은 entry 1

    c = '0;
    c.instr    = make_instr(OP_DMA_LD);
    c.rd       = '0;   // T_INPUT 선택: rd==0
    c.rs1      = '0;   // mt_idx
    c.rs2      = '0;   // kt_idx
    c.rs1_data = 64'h0000_0000_0000_1000; // LMEM dst base
    c.rs2_data = 64'h0000_0000_0000_8000; // DRAM src base

    gemm_dma_ctrl_if.cmd   <= c;
    gemm_dma_ctrl_if.M_tot <= 32'd128;
    gemm_dma_ctrl_if.N_tot <= 32'd128;
    gemm_dma_ctrl_if.K_tot <= 32'd128;
    gemm_dma_ctrl_if.wid   <= 32'd7;

    $display("[%0t] Send DMA_LD INPUT", $time);
    pulse_start();
    wait_done();
    $display("[%0t] DMA_LD done", $time);

    // 기대값 (네 DUT의 always_comb 기준)
    // INPUT:
    //   seg_size = KT*2 = 256
    //   padding  = 0
    //   dram_s0  = K_tot*2 = 256
    //   dram_b0  = mt_eff = 128
    // LD:
    //   src_st0=256, dst_st0=256, bnd0=128, bnd1=1, bnd2=1
    expect_reg32(used_entry, DMA_R_DST_BASE_LO, 32'h0000_1000);
    expect_reg32(used_entry, DMA_R_DST_BASE_HI, 32'h0000_0000);
    expect_reg32(used_entry, DMA_R_SRC_BASE_LO, 32'h0000_8000);
    expect_reg32(used_entry, DMA_R_SRC_BASE_HI, 32'h0000_0000);

    expect_reg32(used_entry, DMA_R_SRC_ST0,   32'd256);
    expect_reg32(used_entry, DMA_R_DST_ST0,   32'd256);
    expect_reg32(used_entry, DMA_R_SRC_ST1,   32'd0);
    expect_reg32(used_entry, DMA_R_DST_ST1,   32'd0);
    expect_reg32(used_entry, DMA_R_SRC_ST2,   32'd0);
    expect_reg32(used_entry, DMA_R_DST_ST2,   32'd0);

    expect_reg32(used_entry, DMA_R_BND0,      32'd128);
    expect_reg32(used_entry, DMA_R_BND1,      32'd1);
    expect_reg32(used_entry, DMA_R_BND2,      32'd1);
    expect_reg32(used_entry, DMA_R_SEG_SIZE,  32'd256);
    expect_reg32(used_entry, DMA_R_PAD,       32'd0);

    // -------------------------
    // Test #2: NOTIFY
    // -------------------------
    // saw_notify는 always_ff에서만 구동되므로, clear 요청만 펄스로 넣어줌
    clear_notify_req <= 1'b1;
    @(posedge clk);
    clear_notify_req <= 1'b0;

    c = '0;
    c.instr    = make_instr(OP_NOTIFY);
    c.rs1_data = 64'h0000_0000_0000_0003; // rid=3 (low8)
    c.rs2_data = 64'h0000_0000_DEAD_BEEF; // value (low32)

    gemm_dma_ctrl_if.cmd <= c;
    $display("[%0t] Send NOTIFY", $time);
    pulse_start();
    wait_done();

    if (!saw_notify)                      $fatal(1, "Expected notify but did not see gemm_sync_if handshake");
    if (saw_notify_reg !== 32'd3)         $fatal(1, "notify reg mismatch: got %0d exp 3", saw_notify_reg);
    if (saw_notify_val !== 32'hDEAD_BEEF) $fatal(1, "notify val mismatch: got 0x%08x exp 0xDEADBEEF", saw_notify_val);

    $display("[%0t] ALL TESTS PASSED", $time);
    #50;
    $finish;
  end

endmodule
