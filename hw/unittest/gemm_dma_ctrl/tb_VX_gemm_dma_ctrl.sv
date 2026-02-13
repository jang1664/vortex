`timescale 1ns/1ps
`include "VX_define.vh"

module tb_VX_gemm_dma_ctrl;
  import VX_gpu_pkg::*;

  localparam int CLK_PERIOD_NS = 10;
  localparam int LAT_BACKEND_DONE = 8;

  localparam int DMA_NUM_REGS = `DMA_CFG_REG_NUM;
  localparam longint unsigned DMA_CFG_BASE_ADDR_TB = 64'h0;
  localparam int DMA_CFG_STRIDE_BYTES_TB = 4;
  localparam int DMA_ENTRY_STRIDE_BYTES_TB = DMA_NUM_REGS * DMA_CFG_STRIDE_BYTES_TB;
  localparam int ENTRYID_W_TB = 8;
  localparam int NUM_MASTERS_TB = 1;
  localparam int NUM_ENTRIES_TB = 16;

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
  localparam int DMA_CTRL_DIR_BIT   = 3;
  localparam int CTRL_OWNER_W_TB    = (NUM_MASTERS_TB <= 1) ? 1 : `ARB_SEL_BITS(NUM_MASTERS_TB, 1);
  localparam int CTRL_GEN_W_TB      = 16;
  localparam int DMA_CTRL_OWNER_LSB = 4;
  localparam int DMA_CTRL_GEN_LSB   = DMA_CTRL_OWNER_LSB + CTRL_OWNER_W_TB;

  logic clk, reset;
  initial clk = 1'b0;
  always #(CLK_PERIOD_NS/2) clk = ~clk;

  VX_gemm_dma_ctrl_if gemm_dma_ctrl_if();
  VX_gemm_sync_if     gemm_sync_if();

  VX_lsu_mem_if #(
    .NUM_LANES(`NUM_LSU_LANES),
    .DATA_SIZE(LSU_WORD_SIZE),
    .TAG_WIDTH(LSU_TAG_WIDTH)
  ) mmio_if[NUM_MASTERS_TB]();

  VX_config_reg_if #(
    .NUM(DMA_NUM_REGS),
    .DW(32)
  ) issue_if();

  VX_node_done_if done_if();

  VX_gemm_dma_ctrl #(
    .INSTANCE_ID("tb"),
    .DMA_CFG_BASE_ADDR(DMA_CFG_BASE_ADDR_TB),
    .DMA_CFG_STRIDE_BYTES(DMA_CFG_STRIDE_BYTES_TB),
    .DMA_ENTRY_STRIDE_BYTES(DMA_ENTRY_STRIDE_BYTES_TB),
    .ENTRYID_W(ENTRYID_W_TB),
    .CTRL_OWNER_W(CTRL_OWNER_W_TB),
    .CTRL_GEN_W(CTRL_GEN_W_TB),
    .POLL_GAP_CYCLES(1),
    .ALLOC_RETRY_GAP_CYCLES(0)
  ) dut (
    .clk(clk),
    .reset(reset),
    .gemm_dma_ctrl_if(gemm_dma_ctrl_if),
    .gemm_sync_if(gemm_sync_if),
    .dma_if(mmio_if[0].master)
  );

  VX_job_frontend #(
    .INSTANCE_ID("tb_job_frontend"),
    .NUM_MASTERS(NUM_MASTERS_TB),
    .NUM_ENTRIES(NUM_ENTRIES_TB),
    .NUM_REGS32(DMA_NUM_REGS),
    .ENTRYID_W(ENTRYID_W_TB),
    .CFG_BASE_ADDR(DMA_CFG_BASE_ADDR_TB)
  ) u_job_frontend (
    .clk(clk),
    .reset(reset),
    .mmio_if(mmio_if),
    .issue_if(issue_if.master),
    .done_if(done_if.slave)
  );

  // --------------------------------------------------------------------------
  // Smoke backend model:
  //  - accepts issue_if job
  //  - waits LAT_BACKEND_DONE cycles
  //  - sends done_if(entry_id)
  // --------------------------------------------------------------------------

  logic backend_pending_q;
  logic [31:0] backend_pending_entry_q;
  int backend_countdown_q;

  assign issue_if.ready = ~backend_pending_q;

  always_ff @(posedge clk) begin
    if (reset) begin
      backend_pending_q       <= 1'b0;
      backend_pending_entry_q <= '0;
      backend_countdown_q     <= 0;
      done_if.valid           <= 1'b0;
      done_if.entry_id        <= '0;
    end else begin
      if (done_if.valid && done_if.ready) begin
        done_if.valid <= 1'b0;
      end

      if (issue_if.valid && issue_if.ready) begin
        backend_pending_q       <= 1'b1;
        backend_pending_entry_q <= issue_if.entry_id;
        backend_countdown_q     <= LAT_BACKEND_DONE;

        $display("[%0t] BACKEND: issue accepted entry_id=%0d", $time, issue_if.entry_id);
      end else if (backend_pending_q) begin
        if (backend_countdown_q > 0) begin
          backend_countdown_q <= backend_countdown_q - 1;
        end else if (!done_if.valid) begin
          done_if.valid    <= 1'b1;
          done_if.entry_id <= backend_pending_entry_q;
          backend_pending_q <= 1'b0;

          $display("[%0t] BACKEND: done entry_id=%0d", $time, backend_pending_entry_q);
        end
      end
    end
  end

  // --------------------------------------------------------------------------
  // Notify sink
  // --------------------------------------------------------------------------

  assign gemm_sync_if.ready = 1'b1;

  logic        saw_notify;
  logic [31:0] saw_notify_reg;
  logic [31:0] saw_notify_val;
  logic clear_notify_req;

  always_ff @(posedge clk) begin
    if (reset) begin
      saw_notify     <= 1'b0;
      saw_notify_reg <= '0;
      saw_notify_val <= '0;
    end else begin
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

  // --------------------------------------------------------------------------
  // Issue monitor + scoreboard
  // --------------------------------------------------------------------------

  logic issue_seen;
  int   issue_count;
  logic [31:0] last_issue_entry;
  logic [DMA_NUM_REGS-1:0][31:0] last_issue_regs;

  wire issue_fire = issue_if.valid && issue_if.ready;

  always_ff @(posedge clk) begin
    if (reset) begin
      issue_seen       <= 1'b0;
      issue_count      <= 0;
      last_issue_entry <= '0;
      last_issue_regs  <= '0;
    end else if (issue_fire) begin
      issue_seen       <= 1'b1;
      issue_count      <= issue_count + 1;
      last_issue_entry <= issue_if.entry_id;
      last_issue_regs  <= issue_if.regs;
    end
  end

  task automatic pulse_start();
    gemm_dma_ctrl_if.start <= 1'b1;
    @(posedge clk);
    gemm_dma_ctrl_if.start <= 1'b0;
  endtask

  task automatic wait_done_or_timeout(input int unsigned max_cycles, input string tag);
    int unsigned c;
    c = 0;

    while (gemm_dma_ctrl_if.idle && (c < max_cycles)) begin
      @(posedge clk);
      c++;
    end
    if (c >= max_cycles) $fatal(1, "[%s] timeout: never left idle", tag);

    while (!gemm_dma_ctrl_if.done && (c < max_cycles)) begin
      @(posedge clk);
      c++;
    end
    if (c >= max_cycles) $fatal(1, "[%s] timeout: done not asserted", tag);

    @(posedge clk);
  endtask

  task automatic wait_issue_count_or_timeout(input int exp_count, input int unsigned max_cycles, input string tag);
    int unsigned c;
    c = 0;
    while ((issue_count < exp_count) && (c < max_cycles)) begin
      @(posedge clk);
      c++;
    end
    if (issue_count < exp_count) begin
      $fatal(1, "[%s] timeout: issue_count=%0d exp=%0d", tag, issue_count, exp_count);
    end
  endtask

  task automatic expect_issue_reg(input int reg_idx, input logic [31:0] exp);
    logic [31:0] got;
    got = last_issue_regs[reg_idx];
    if (got !== exp) begin
      $fatal(1, "ISSUE REG MISMATCH reg[%0d]: got=0x%08x exp=0x%08x", reg_idx, got, exp);
    end else begin
      $display("[%0t] OK issue reg[%0d]=0x%08x", $time, reg_idx, got);
    end
  endtask

  localparam logic [7:0] OP_NOTIFY = 8'hF1;
  localparam logic [7:0] OP_DMA_LD = 8'h10;
  localparam logic [7:0] OP_DMA_ST = 8'h11;

  function automatic logic [31:0] make_instr(input logic [7:0] op);
    return {24'd0, op};
  endfunction

  function automatic logic [31:0] make_exp_ctrl(
    input logic dir,
    input logic [CTRL_OWNER_W_TB-1:0] owner,
    input logic [CTRL_GEN_W_TB-1:0] gen
  );
    logic [31:0] v;
    begin
      v = '0;
      v[0] = 1'b1; // valid
      v[1] = 1'b1; // occupy
      v[2] = 1'b0; // working
      v[DMA_CTRL_DIR_BIT] = dir;
      v[DMA_CTRL_OWNER_LSB +: CTRL_OWNER_W_TB] = owner;
      v[DMA_CTRL_GEN_LSB +: CTRL_GEN_W_TB] = gen;
      return v;
    end
  endfunction

  initial begin
    int issue_base;
    gemm_unified_cmd_t c;

    if ((DMA_CTRL_GEN_LSB + CTRL_GEN_W_TB) > 32)
      $fatal(1, "CONTROL owner/gen field width overflow: owner_w=%0d gen_w=%0d", CTRL_OWNER_W_TB, CTRL_GEN_W_TB);

    gemm_dma_ctrl_if.start <= 1'b0;
    gemm_dma_ctrl_if.cmd   <= '0;
    gemm_dma_ctrl_if.M_tot <= 32'd0;
    gemm_dma_ctrl_if.N_tot <= 32'd0;
    gemm_dma_ctrl_if.K_tot <= 32'd0;
    gemm_dma_ctrl_if.entry_id <= 32'd0;
    clear_notify_req       <= 1'b0;

    reset = 1'b1;
    repeat (5) @(posedge clk);
    reset = 1'b0;
    repeat (2) @(posedge clk);

    // ------------------------------------------------------------------------
    // Test #1: DMA_LD INPUT -> descriptor issue -> backend done -> dut done
    // ------------------------------------------------------------------------
    issue_base = issue_count;

    c = '0;
    c.instr    = make_instr(OP_DMA_LD);
    c.rd       = '0;   // T_INPUT
    c.rs1      = '0;   // mt_idx
    c.rs2      = '0;   // kt_idx
    c.rs1_data = 64'h0000_0000_0000_1000; // LMEM dst base
    c.rs2_data = 64'h0000_0000_0000_8000; // DRAM src base

    gemm_dma_ctrl_if.cmd   <= c;
    gemm_dma_ctrl_if.M_tot <= 32'd128;
    gemm_dma_ctrl_if.N_tot <= 32'd128;
    gemm_dma_ctrl_if.K_tot <= 32'd128;
    gemm_dma_ctrl_if.entry_id <= 32'd7;

    $display("[%0t] Send DMA_LD INPUT", $time);
    pulse_start();

    wait_issue_count_or_timeout(issue_base + 1, 2000, "DMA_LD issue");

    if (last_issue_entry !== 32'd0) begin
      $fatal(1, "first issue entry_id mismatch: got=%0d exp=0", last_issue_entry);
    end

    // Expected descriptor values (same math as VX_gemm_dma_ctrl)
    expect_issue_reg(DMA_R_DST_BASE_LO, 32'h0000_1000);
    expect_issue_reg(DMA_R_DST_BASE_HI, 32'h0000_0000);
    expect_issue_reg(DMA_R_SRC_BASE_LO, 32'h0000_8000);
    expect_issue_reg(DMA_R_SRC_BASE_HI, 32'h0000_0000);

    expect_issue_reg(DMA_R_SRC_ST0, 32'd256);
    expect_issue_reg(DMA_R_DST_ST0, 32'd256);
    expect_issue_reg(DMA_R_SRC_ST1, 32'd0);
    expect_issue_reg(DMA_R_DST_ST1, 32'd0);
    expect_issue_reg(DMA_R_SRC_ST2, 32'd0);
    expect_issue_reg(DMA_R_DST_ST2, 32'd0);

    expect_issue_reg(DMA_R_BND0, 32'd128);
    expect_issue_reg(DMA_R_BND1, 32'd1);
    expect_issue_reg(DMA_R_BND2, 32'd1);
    expect_issue_reg(DMA_R_SEG_SIZE, 32'd256);
    expect_issue_reg(DMA_R_PAD, 32'd0);

    // CONTROL includes token fields: owner(=0), generation(=1)
    expect_issue_reg(DMA_R_CONTROL, make_exp_ctrl(1'b0, '0, CTRL_GEN_W_TB'(1)));

    wait_done_or_timeout(4000, "DMA_LD done");
    $display("[%0t] DMA_LD done", $time);

    // ------------------------------------------------------------------------
    // Test #2: DMA_ST OUTPUT -> descriptor issue -> backend done -> dut done
    // ------------------------------------------------------------------------
    issue_base = issue_count;

    c = '0;
    c.instr    = make_instr(OP_DMA_ST);
    c.rd       = 32'd4; // T_OUTPUT
    c.rs1      = 32'd1; // mt_idx
    c.rs2      = 32'd1; // nt_idx
    c.rs1_data = 64'h0000_0000_0000_9000; // DRAM dst base
    c.rs2_data = 64'h0000_0000_0000_2000; // LMEM src base

    gemm_dma_ctrl_if.cmd   <= c;
    gemm_dma_ctrl_if.M_tot <= 32'd130; // mt_eff=2
    gemm_dma_ctrl_if.N_tot <= 32'd130; // nt_eff=2
    gemm_dma_ctrl_if.K_tot <= 32'd128;
    gemm_dma_ctrl_if.entry_id <= 32'd9;

    $display("[%0t] Send DMA_ST OUTPUT", $time);
    pulse_start();

    wait_issue_count_or_timeout(issue_base + 1, 2000, "DMA_ST issue");

    if (last_issue_entry !== 32'd1) begin
      $fatal(1, "second issue entry_id mismatch: got=%0d exp=1", last_issue_entry);
    end

    // Expected descriptor values (T_OUTPUT + DMA_ST)
    // src=lmem, dst=dram
    expect_issue_reg(DMA_R_DST_BASE_LO, 32'h0000_9000);
    expect_issue_reg(DMA_R_DST_BASE_HI, 32'h0000_0000);
    expect_issue_reg(DMA_R_SRC_BASE_LO, 32'h0000_2000);
    expect_issue_reg(DMA_R_SRC_BASE_HI, 32'h0000_0000);

    // OUTPUT:
    //   lmem_s0 = NT*2 = 256
    //   dram_s0 = N_tot*2 = 260
    //   bnd0    = mt_eff = 2
    //   seg     = nt_eff*2 = 4   (compact global write)
    //   pad     = 0
    expect_issue_reg(DMA_R_SRC_ST0, 32'd256);
    expect_issue_reg(DMA_R_DST_ST0, 32'd260);
    expect_issue_reg(DMA_R_SRC_ST1, 32'd0);
    expect_issue_reg(DMA_R_DST_ST1, 32'd0);
    expect_issue_reg(DMA_R_SRC_ST2, 32'd0);
    expect_issue_reg(DMA_R_DST_ST2, 32'd0);

    expect_issue_reg(DMA_R_BND0, 32'd2);
    expect_issue_reg(DMA_R_BND1, 32'd1);
    expect_issue_reg(DMA_R_BND2, 32'd1);
    expect_issue_reg(DMA_R_SEG_SIZE, 32'd4);
    expect_issue_reg(DMA_R_PAD, 32'd0);

    // CONTROL includes token fields: owner(=0), generation(=1)
    expect_issue_reg(DMA_R_CONTROL, make_exp_ctrl(1'b1, '0, CTRL_GEN_W_TB'(1)));

    wait_done_or_timeout(4000, "DMA_ST done");
    $display("[%0t] DMA_ST done", $time);

    // ------------------------------------------------------------------------
    // Test #3: NOTIFY
    // ------------------------------------------------------------------------
    clear_notify_req <= 1'b1;
    @(posedge clk);
    clear_notify_req <= 1'b0;

    c = '0;
    c.instr    = make_instr(OP_NOTIFY);
    c.rs1_data = 64'h0000_0000_0000_0003; // rid=3
    c.rs2_data = 64'h0000_0000_DEAD_BEEF; // value

    gemm_dma_ctrl_if.cmd <= c;
    $display("[%0t] Send NOTIFY", $time);
    pulse_start();
    wait_done_or_timeout(1000, "NOTIFY done");

    if (!saw_notify)                      $fatal(1, "Expected notify but no handshake");
    if (saw_notify_reg !== 32'd3)         $fatal(1, "notify reg mismatch: got %0d exp 3", saw_notify_reg);
    if (saw_notify_val !== 32'hDEAD_BEEF) $fatal(1, "notify val mismatch: got 0x%08x exp 0xDEADBEEF", saw_notify_val);

    $display("[%0t] ALL TESTS PASSED", $time);
    #50;
    $finish;
  end

endmodule
