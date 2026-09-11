`timescale 1ns/1ps
`include "VX_define.vh"

module tb_VX_gemm_dma_ctrl_naive_pipeline;
  import VX_gpu_pkg::*;

  localparam int CLK_PERIOD_NS = 10;
  localparam int DMA_DATA_SIZE = 64;
  localparam int DMA_NUM_LANES = 1;
  localparam int REGS_PER_LANE = DMA_DATA_SIZE / 4;
  localparam int DMA_NUM_REGS = `DMA_CFG_REG_NUM;
  localparam int DMA_ENTRY_STRIDE_BYTES = DMA_NUM_REGS * 4;
  localparam int LSU_ADDR_SHIFT = `CLOG2(DMA_DATA_SIZE);

  localparam int DMA_R_DST_BASE_LO = 1;
  localparam int DMA_R_DST_BASE_HI = 2;
  localparam int DMA_R_SRC_BASE_LO = 3;
  localparam int DMA_R_SRC_BASE_HI = 4;
  localparam int DMA_R_SRC_ST0 = 5;
  localparam int DMA_R_DST_ST0 = 6;
  localparam int DMA_R_BND0 = 11;
  localparam int DMA_R_BND1 = 12;
  localparam int DMA_R_BND2 = 13;
  localparam int DMA_R_SEG_SIZE = 14;
  localparam int DMA_R_PAD = 15;
  localparam int DMA_R_DIR = 16;

  localparam logic [7:0] OP_DMA_LD = 8'h10;
  localparam logic [7:0] OP_DMA_ST = 8'h11;
  localparam logic [DMA_DATA_SIZE-1:0] KICK_BYTEEN = {
    {(DMA_DATA_SIZE-4){1'b0}}, 4'hf
  };

  logic clk;
  logic reset;
  logic write_ready;
  wire store_done;

  initial clk = 1'b0;
  always #(CLK_PERIOD_NS/2) clk = ~clk;

  VX_gemm_dma_ctrl_naive_if gemm_dma_ctrl_if();
  VX_gemm_sync_if gemm_sync_if();
  VX_lsu_mem_if #(
    .NUM_LANES(DMA_NUM_LANES),
    .DATA_SIZE(DMA_DATA_SIZE),
    .TAG_WIDTH(8)
  ) dma_if();

  VX_gemm_dma_ctrl_naive #(
    .INSTANCE_ID("pipeline_tb"),
    .DMA_CFG_BASE_ADDR(64'd0),
    .DMA_ENTRY_STRIDE_BYTES(DMA_ENTRY_STRIDE_BYTES),
    .POLL_GAP_CYCLES(1),
    .ALLOC_RETRY_GAP_CYCLES(0)
  ) dut (
    .clk(clk),
    .reset(reset),
    .gemm_dma_ctrl_if(gemm_dma_ctrl_if),
    .gemm_sync_if(gemm_sync_if),
    .dma_if(dma_if.master),
    .store_done(store_done)
  );

  assign gemm_sync_if.ready = 1'b1;
  assign dma_if.req_ready = !dma_if.req_data.rw || write_ready;

  // Minimal allocator/poll response model. Allocation is deliberately delayed
  // so the decoded snapshot must survive independently of the response timing.
  logic rsp_pending_q;
  logic [31:0] rsp_word_q;
  int rsp_delay_q;

  function automatic logic [31:0] alloc_response();
    logic [31:0] value;
    begin
      value = '0;
      value[`JOB_MMIO_ALLOC_SUCC_BIT] = 1'b1;
      value[`JOB_MMIO_ALLOC_ENTRY_LSB +: `JOB_MMIO_ALLOC_ENTRY_BITS] = '0;
      value[`JOB_MMIO_ALLOC_OWNER_LSB +: `JOB_MMIO_ALLOC_OWNER_BITS] = 4'd1;
      value[`JOB_MMIO_ALLOC_GEN_LSB +: `JOB_MMIO_ALLOC_GEN_BITS] = 16'd7;
      return value;
    end
  endfunction

  always_ff @(posedge clk) begin
    if (reset) begin
      dma_if.rsp_valid <= 1'b0;
      dma_if.rsp_data <= '0;
      rsp_pending_q <= 1'b0;
      rsp_word_q <= '0;
      rsp_delay_q <= 0;
    end else begin
      if (dma_if.rsp_valid && dma_if.rsp_ready)
        dma_if.rsp_valid <= 1'b0;

      if (!rsp_pending_q && !dma_if.rsp_valid
       && dma_if.req_valid && dma_if.req_ready && !dma_if.req_data.rw) begin
        rsp_pending_q <= 1'b1;
        if (dma_if.req_data.addr[0] == '0) begin
          rsp_word_q <= alloc_response();
          rsp_delay_q <= 4;
        end else begin
          // An all-zero CONTROL word means the backend has released the entry.
          rsp_word_q <= 32'd0;
          rsp_delay_q <= 1;
        end
      end else if (rsp_pending_q) begin
        if (rsp_delay_q != 0) begin
          rsp_delay_q <= rsp_delay_q - 1;
        end else begin
          dma_if.rsp_valid <= 1'b1;
          dma_if.rsp_data <= '0;
          dma_if.rsp_data.mask[0] <= 1'b1;
          dma_if.rsp_data.data[0][31:0] <= rsp_word_q;
          rsp_pending_q <= 1'b0;
        end
      end
    end
  end

  logic [DMA_NUM_REGS-1:0][31:0] descriptor_regs_q;
  int descriptor_write_count_q;
  logic clear_scoreboard;

  wire write_fire = dma_if.req_valid && dma_if.req_ready
                 && dma_if.req_data.rw && dma_if.req_data.mask[0];
  wire kick_write = write_fire
                 && (dma_if.req_data.byteen[0] == KICK_BYTEEN)
                 && dma_if.req_data.data[0][`JOB_MMIO_CTRL_VALID_BIT];

  always_ff @(posedge clk) begin
    if (reset || clear_scoreboard) begin
      descriptor_regs_q <= '0;
      descriptor_write_count_q <= 0;
    end else if (write_fire && !kick_write) begin
      longint unsigned byte_addr;
      int base_idx;
      byte_addr = longint'(dma_if.req_data.addr[0]) << LSU_ADDR_SHIFT;
      base_idx = (byte_addr - DMA_DATA_SIZE) / 4;

      for (int w = 0; w < REGS_PER_LANE; ++w) begin
        int idx;
        idx = base_idx + w;
        if ((idx < DMA_NUM_REGS)
         && (dma_if.req_data.byteen[0][w*4 +: 4] == 4'hf)) begin
          descriptor_regs_q[idx] <= dma_if.req_data.data[0][w*32 +: 32];
        end
      end
      descriptor_write_count_q <= descriptor_write_count_q + 1;
    end
  end

  task automatic init_command_inputs();
    gemm_dma_ctrl_if.start = 1'b0;
    gemm_dma_ctrl_if.cmd = '0;
    gemm_dma_ctrl_if.M_orig = 32'd0;
    gemm_dma_ctrl_if.N_orig = 32'd0;
    gemm_dma_ctrl_if.K_orig = 32'd0;
    gemm_dma_ctrl_if.qblk_orig = 32'd0;
    gemm_dma_ctrl_if.M_target = 32'd0;
    gemm_dma_ctrl_if.N_target = 32'd0;
    gemm_dma_ctrl_if.K_target = 32'd0;
    gemm_dma_ctrl_if.wtrans_tot = 32'd0;
    gemm_dma_ctrl_if.qdir_tot = 32'd0;
    gemm_dma_ctrl_if.entry_id = 32'd0;
  endtask

  task automatic pulse_start();
    while (!gemm_dma_ctrl_if.idle)
      @(posedge clk);
    gemm_dma_ctrl_if.start <= 1'b1;
    @(posedge clk);
    gemm_dma_ctrl_if.start <= 1'b0;
  endtask

  task automatic reset_scoreboard();
    clear_scoreboard <= 1'b1;
    @(posedge clk);
    clear_scoreboard <= 1'b0;
  endtask

  task automatic check_stalled_descriptor(input int cycles);
    logic [$bits(dma_if.req_data)-1:0] held_req;
    int waited;
    waited = 0;
    while (!(dma_if.req_valid && dma_if.req_data.rw) && (waited < 100)) begin
      @(negedge clk);
      waited++;
    end
    if (waited == 100)
      $fatal(1, "timeout waiting for stalled descriptor request");

    held_req = dma_if.req_data;
    repeat (cycles) begin
      @(negedge clk);
      if (!dma_if.req_valid)
        $fatal(1, "descriptor req_valid dropped under backpressure");
      if (dma_if.req_data !== held_req)
        $fatal(1, "descriptor request changed under backpressure");
    end
  endtask

  task automatic wait_descriptor(input int expected_writes);
    int waited;
    waited = 0;
    while ((descriptor_write_count_q < expected_writes) && (waited < 100)) begin
      @(posedge clk);
      waited++;
    end
    if (descriptor_write_count_q < expected_writes)
      $fatal(1, "timeout waiting for descriptor writes");
    @(negedge clk);
  endtask

  task automatic wait_done();
    int waited;
    waited = 0;
    while (!gemm_dma_ctrl_if.done && (waited < 200)) begin
      @(posedge clk);
      waited++;
    end
    if (!gemm_dma_ctrl_if.done)
      $fatal(1, "timeout waiting for controller done");
    @(posedge clk);
  endtask

  task automatic expect_reg(input int idx, input logic [31:0] expected);
    if (descriptor_regs_q[idx] !== expected) begin
      $fatal(1, "descriptor[%0d] mismatch: got=0x%08x expected=0x%08x",
             idx, descriptor_regs_q[idx], expected);
    end
  endtask

  initial begin
    gemm_unified_cmd_t command;

    reset = 1'b1;
    write_ready = 1'b0;
    clear_scoreboard = 1'b0;
    init_command_inputs();
    repeat (5) @(posedge clk);
    reset = 1'b0;
    repeat (2) @(posedge clk);

    // Exact input tile: both layouts are contiguous, so 128 rows of 256
    // bytes must collapse into one 32768-byte segment.
    command = '0;
    command.instr = {24'd0, OP_DMA_LD};
    command.rd = '0;
    command.rs1_data = 64'h0000_0000_0000_1000;
    command.rs2_data = 64'h0000_0000_0000_8000;
    gemm_dma_ctrl_if.cmd = command;
    gemm_dma_ctrl_if.M_orig = 32'd128;
    gemm_dma_ctrl_if.N_orig = 32'd128;
    gemm_dma_ctrl_if.K_orig = 32'd128;
    gemm_dma_ctrl_if.qblk_orig = 32'd32;
    gemm_dma_ctrl_if.M_target = 32'd128;
    gemm_dma_ctrl_if.N_target = 32'd128;
    gemm_dma_ctrl_if.K_target = 32'd128;

    pulse_start();
    check_stalled_descriptor(5);

    // Change every live input while the descriptor request is stalled. The
    // registered snapshot and packed request must remain the first command.
    gemm_dma_ctrl_if.cmd = '1;
    gemm_dma_ctrl_if.M_orig = 32'hffff_ffff;
    gemm_dma_ctrl_if.N_orig = 32'hffff_ffff;
    gemm_dma_ctrl_if.K_orig = 32'hffff_ffff;
    write_ready = 1'b1;
    wait_descriptor(2);

    expect_reg(DMA_R_DST_BASE_LO, 32'h0000_1000);
    expect_reg(DMA_R_DST_BASE_HI, 32'd0);
    expect_reg(DMA_R_SRC_BASE_LO, 32'h0000_8000);
    expect_reg(DMA_R_SRC_BASE_HI, 32'd0);
    expect_reg(DMA_R_SRC_ST0, 32'd256);
    expect_reg(DMA_R_DST_ST0, 32'd256);
    expect_reg(DMA_R_BND0, 32'd1);
    expect_reg(DMA_R_BND1, 32'd1);
    expect_reg(DMA_R_BND2, 32'd1);
    expect_reg(DMA_R_SEG_SIZE, 32'd32768);
    expect_reg(DMA_R_PAD, 32'd0);
    expect_reg(DMA_R_DIR, 32'd0);
    wait_done();

    // Edge output store: LMEM and DRAM strides differ from the compact
    // four-byte row, so dimension 0 must remain uncoalesced.
    reset_scoreboard();
    command = '0;
    command.instr = {24'd0, OP_DMA_ST};
    command.rd = 4;
    command.rs1 = 1;
    command.rs2 = 1;
    command.eff_mt = 2;
    command.rs1_data = 64'h0000_0000_0000_9000;
    command.rs2_data = 64'h0000_0000_0000_2000;
    gemm_dma_ctrl_if.cmd = command;
    gemm_dma_ctrl_if.M_orig = 32'd130;
    gemm_dma_ctrl_if.N_orig = 32'd130;
    gemm_dma_ctrl_if.K_orig = 32'd128;
    gemm_dma_ctrl_if.qblk_orig = 32'd32;
    gemm_dma_ctrl_if.M_target = 32'd130;
    gemm_dma_ctrl_if.N_target = 32'd130;
    gemm_dma_ctrl_if.K_target = 32'd128;

    pulse_start();
    wait_descriptor(2);
    expect_reg(DMA_R_DST_BASE_LO, 32'h0000_9000);
    expect_reg(DMA_R_SRC_BASE_LO, 32'h0000_2000);
    expect_reg(DMA_R_SRC_ST0, 32'd256);
    expect_reg(DMA_R_DST_ST0, 32'd260);
    expect_reg(DMA_R_BND0, 32'd2);
    expect_reg(DMA_R_SEG_SIZE, 32'd4);
    expect_reg(DMA_R_PAD, 32'd0);
    expect_reg(DMA_R_DIR, 32'd1);
    wait_done();

    $display("TEST PASSED: coherent coalesced descriptor snapshot");
    #20;
    $finish;
  end

endmodule
