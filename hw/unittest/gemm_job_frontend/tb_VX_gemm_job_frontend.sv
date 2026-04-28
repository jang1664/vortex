`timescale 1ns/1ps
`include "VX_define.vh"

// Focused testbench for VX_gemm_job_frontend.
// Drives synthetic mmio_if traffic to exercise:
//   - mask=0xFF full burst (push 8 words / cycle)
//   - mask=0x0F partial burst (push 4 words / cycle)
//   - mask=0x01 single-thread fallback (bit-identical to legacy stream_send)
//   - FIFO near-full backpressure: req_ready deasserts and re-asserts
//     correctly when downstream is held off.
//   - Pop order: lane-id order (lane 0 first, lane 7 last) regardless of
//     mask shape.

module tb_VX_gemm_job_frontend;
  import VX_gpu_pkg::*;

  localparam int NUM_MASTERS  = 1;
  localparam int TB_NUM_LANES = `NUM_LSU_LANES;
  localparam int TB_DATA_SIZE = LSU_WORD_SIZE;
  localparam int TB_TAG_WIDTH = LSU_TAG_WIDTH;
  localparam int TB_FIFO_DEPTH = 16;

  localparam logic [63:0] TB_CFG_BASE_ADDR = 64'h0000_0000_0000_1080;

  // RTL offsets must match VX_gemm_job_frontend.
  localparam logic [63:0] STREAM_OFF_B  = 64'd8;
  localparam logic [63:0] STATE_OFF_B   = 64'd128;

  logic clk, reset;

  initial clk = 1'b0;
  always #5 clk = ~clk;

  VX_lsu_mem_if #(
    .NUM_LANES (TB_NUM_LANES),
    .DATA_SIZE (TB_DATA_SIZE),
    .TAG_WIDTH (TB_TAG_WIDTH)
  ) mmio_if[NUM_MASTERS]();

  VX_instruction_if #(
    .DW (TB_DATA_SIZE * 8)
  ) issue_if();

  VX_gemm_node_done_if done_if();

  // RSP backpressure handle.
  logic mmio_rsp_ready_q;
  assign mmio_if[0].rsp_ready = mmio_rsp_ready_q;

  // DUT instantiation.
  VX_gemm_job_frontend #(
    .INSTANCE_ID  ("tb_gemm_job_frontend"),
    .NUM_MASTERS  (NUM_MASTERS),
    .CFG_BASE_ADDR(TB_CFG_BASE_ADDR),
    .FIFO_DEPTH   (TB_FIFO_DEPTH)
  ) dut (
    .clk     (clk),
    .reset   (reset),
    .mmio_if (mmio_if),
    .issue_if(issue_if.master),
    .done_if (done_if.slave)
  );

  // ------------------------------------------------------------------
  // Issue capture (DUT -> testbench): consumes 1 word/cycle when
  // issue_ready_q is high, records sequence into issue_q for checking.
  // ------------------------------------------------------------------
  logic                       issue_ready_q;
  logic [TB_DATA_SIZE*8-1:0]  issue_q [$];

  assign issue_if.ready = issue_ready_q;

  always_ff @(posedge clk) begin
    if (reset) begin
      issue_q.delete();
    end else begin
      if (issue_if.valid && issue_if.ready) begin
        issue_q.push_back(issue_if.inst);
        $display("[%0t] ISSUE word=0x%016h (q.size=%0d)",
                 $time, issue_if.inst, issue_q.size());
      end
    end
  end

  // ------------------------------------------------------------------
  // Helpers
  // ------------------------------------------------------------------

  function automatic logic [mmio_if[0].ADDR_WIDTH-1:0] byte_to_addr(input logic [63:0] byte_addr);
    return mmio_if[0].ADDR_WIDTH'(byte_addr >> `CLOG2(TB_DATA_SIZE));
  endfunction

  task automatic do_reset();
    begin
      reset            = 1'b1;
      mmio_if[0].req_valid = 1'b0;
      mmio_if[0].req_data  = '0;
      mmio_rsp_ready_q     = 1'b1;
      issue_ready_q        = 1'b0;
      done_if.valid        = 1'b0;
      repeat (5) @(posedge clk);
      reset = 1'b0;
      repeat (2) @(posedge clk);
    end
  endtask

  // Read a single 64-bit MMIO word from lane 0 (used for ALLOC).
  task automatic mmio_read_lane0(
    input  logic [63:0]              byte_addr,
    output logic [TB_DATA_SIZE*8-1:0] data
  );
    int guard;
    begin
      mmio_if[0].req_data         = '0;
      mmio_if[0].req_data.rw      = 1'b0;
      mmio_if[0].req_data.mask    = '0;
      mmio_if[0].req_data.mask[0] = 1'b1;
      mmio_if[0].req_data.addr[0] = byte_to_addr(byte_addr);

      @(negedge clk);
      mmio_if[0].req_valid = 1'b1;
      guard = 0;
      while (!(mmio_if[0].req_valid && mmio_if[0].req_ready)) begin
        @(posedge clk);
        guard++;
        if (guard > 200) $fatal(1, "mmio_read_lane0 timeout waiting req_ready");
      end
      @(negedge clk);
      mmio_if[0].req_valid = 1'b0;

      guard = 0;
      while (!mmio_if[0].rsp_valid) begin
        @(posedge clk);
        guard++;
        if (guard > 200) $fatal(1, "mmio_read_lane0 timeout waiting rsp_valid");
      end
      data = mmio_if[0].rsp_data.data[0];
      @(posedge clk);
    end
  endtask

  // Issue one MMIO write with a per-lane mask + per-lane data.
  // Each active lane k targets byte address (STREAM_OFF_B + 8*k) within
  // CFG_BASE.  Returns the cycle the handshake fires.
  task automatic mmio_burst_write(
    input  logic [TB_NUM_LANES-1:0]                          lane_mask,
    input  logic [TB_NUM_LANES-1:0][TB_DATA_SIZE*8-1:0]      lane_data,
    output int                                                fire_cycle
  );
    int guard;
    int t0;
    begin
      for (int k = 0; k < TB_NUM_LANES; k++) begin
        mmio_if[0].req_data.addr[k]   = byte_to_addr(TB_CFG_BASE_ADDR
                                                   + STREAM_OFF_B
                                                   + 64'(k) * 64'(TB_DATA_SIZE));
        mmio_if[0].req_data.data[k]   = lane_data[k];
        mmio_if[0].req_data.byteen[k] = '1;
        mmio_if[0].req_data.flags[k]  = '0;
      end
      mmio_if[0].req_data.mask = lane_mask;
      mmio_if[0].req_data.rw   = 1'b1;
      mmio_if[0].req_data.tag  = '0;

      @(negedge clk);
      mmio_if[0].req_valid = 1'b1;
      t0 = 0;
      guard = 0;
      while (!(mmio_if[0].req_valid && mmio_if[0].req_ready)) begin
        @(posedge clk);
        guard++;
        t0++;
        if (guard > 1000) $fatal(1, "mmio_burst_write timeout waiting req_ready");
      end
      fire_cycle = t0;
      @(negedge clk);
      mmio_if[0].req_valid = 1'b0;
      @(posedge clk);
    end
  endtask

  // Drain the FIFO via issue_if and check the captured words match `expected`
  // in order, allowing up to `max_cycles` to drain.
  task automatic drain_and_check(
    input  logic [TB_DATA_SIZE*8-1:0] expected[$],
    input  int                        max_cycles
  );
    int c;
    begin
      issue_q.delete();
      @(negedge clk);
      issue_ready_q = 1'b1;
      c = 0;
      while (issue_q.size() < expected.size()) begin
        @(posedge clk);
        c++;
        if (c > max_cycles) begin
          $fatal(1, "drain timeout: got %0d / %0d words", issue_q.size(), expected.size());
        end
      end
      @(negedge clk);
      issue_ready_q = 1'b0;
      @(posedge clk);
      // Validate
      if (issue_q.size() !== expected.size()) begin
        $fatal(1, "drain count mismatch: got=%0d exp=%0d",
               issue_q.size(), expected.size());
      end
      for (int i = 0; i < expected.size(); i++) begin
        if (issue_q[i] !== expected[i]) begin
          $fatal(1, "drain[%0d] data mismatch: got=0x%016h exp=0x%016h",
                 i, issue_q[i], expected[i]);
        end
      end
    end
  endtask

  // ------------------------------------------------------------------
  // Test body
  // ------------------------------------------------------------------
  initial begin : test_main
    logic [TB_NUM_LANES-1:0]                    lane_mask;
    logic [TB_NUM_LANES-1:0][TB_DATA_SIZE*8-1:0] lane_data;
    logic [TB_DATA_SIZE*8-1:0]                  alloc_rd;
    logic [TB_DATA_SIZE*8-1:0]                  expected[$];
    int   fire_cycle;
    int   pushes_done;

`ifdef VCS
    $fsdbDumpfile("wave.fsdb");
    $fsdbDumpvars(0, "+all", "+parameter", "+functions");
`else
    $dumpfile("wave.fst");
    $dumpvars(0, tb_VX_gemm_job_frontend);
`endif

    do_reset();

    if (TB_DATA_SIZE != 8)
      $fatal(1, "expected LSU word size=64b (TB_DATA_SIZE=8). Build with XLEN_64.");
    if (TB_NUM_LANES != 8)
      $fatal(1, "expected NUM_LSU_LANES==8 for burst tests, got %0d", TB_NUM_LANES);

    // ---------------------------------------------------------------
    // Step 1: ALLOC stream — required before stream writes are accepted
    // (frontend asserts req_ready=0 for stream writes when ~occupied_q).
    // ---------------------------------------------------------------
    mmio_read_lane0(TB_CFG_BASE_ADDR, alloc_rd);
    if (alloc_rd[0] !== 1'b1)
      $fatal(1, "stream alloc failed (rd=0x%016h)", alloc_rd);
    $display("[%0t] ALLOC ok rd=0x%016h", $time, alloc_rd);

    // ---------------------------------------------------------------
    // Step 2: mask=0x01 — single-thread fallback, bit-identical to today
    // ---------------------------------------------------------------
    $display("[TEST] mask=0x01 single-lane stream_send");
    lane_mask = '0;
    lane_mask[0] = 1'b1;
    for (int k = 0; k < TB_NUM_LANES; k++)
      lane_data[k] = (TB_DATA_SIZE*8)'(64'h1111_0000_0000_0000 | 64'(k));
    mmio_burst_write(lane_mask, lane_data, fire_cycle);
    expected.delete();
    expected.push_back(lane_data[0]);
    drain_and_check(expected, 32);
    $display("[PASS] mask=0x01");

    // ---------------------------------------------------------------
    // Step 3: mask=0x0F — partial burst (4 words / cycle)
    // ---------------------------------------------------------------
    $display("[TEST] mask=0x0F partial burst (4 words)");
    lane_mask = 8'h0F;
    for (int k = 0; k < TB_NUM_LANES; k++)
      lane_data[k] = (TB_DATA_SIZE*8)'(64'h2222_0000_0000_0000 | 64'(k));
    mmio_burst_write(lane_mask, lane_data, fire_cycle);
    expected.delete();
    for (int k = 0; k < TB_NUM_LANES; k++) begin
      if (lane_mask[k]) expected.push_back(lane_data[k]);
    end
    if (expected.size() != 4)
      $fatal(1, "expected size for 0x0F should be 4, got %0d", expected.size());
    drain_and_check(expected, 32);
    $display("[PASS] mask=0x0F");

    // ---------------------------------------------------------------
    // Step 4: mask=0xFF — full burst (8 words pushed in 1 handshake)
    // ---------------------------------------------------------------
    $display("[TEST] mask=0xFF full burst (8 words)");
    lane_mask = 8'hFF;
    for (int k = 0; k < TB_NUM_LANES; k++)
      lane_data[k] = (TB_DATA_SIZE*8)'(64'h3333_0000_0000_0000 | 64'(k));
    mmio_burst_write(lane_mask, lane_data, fire_cycle);
    expected.delete();
    for (int k = 0; k < TB_NUM_LANES; k++) begin
      if (lane_mask[k]) expected.push_back(lane_data[k]);
    end
    if (expected.size() != 8)
      $fatal(1, "expected size for 0xFF should be 8, got %0d", expected.size());
    drain_and_check(expected, 32);
    $display("[PASS] mask=0xFF");

    // ---------------------------------------------------------------
    // Step 5: lane order check with sparse mask (bits 0,2,5)
    // ---------------------------------------------------------------
    $display("[TEST] sparse mask=0b00100101 (lanes 0,2,5)");
    lane_mask = 8'b0010_0101;
    for (int k = 0; k < TB_NUM_LANES; k++)
      lane_data[k] = (TB_DATA_SIZE*8)'(64'h4444_0000_0000_0000 | 64'(k));
    mmio_burst_write(lane_mask, lane_data, fire_cycle);
    expected.delete();
    expected.push_back(lane_data[0]);
    expected.push_back(lane_data[2]);
    expected.push_back(lane_data[5]);
    drain_and_check(expected, 32);
    $display("[PASS] sparse mask order");

    // ---------------------------------------------------------------
    // Step 6: FIFO near-full backpressure
    //   Hold issue_if.ready=0, push masks=0xFF until the FIFO has
    //   filled to TB_FIFO_DEPTH (== 16).  Then attempt one more 0xFF
    //   push and verify req_ready is held off until we drain enough
    //   slots to fit the popcount.
    // ---------------------------------------------------------------
    $display("[TEST] FIFO near-full backpressure");
    issue_ready_q = 1'b0;
    expected.delete();
    issue_q.delete();

    // Push two 0xFF bursts back-to-back: 8 + 8 = 16 (fills the FIFO).
    pushes_done = 0;
    while (pushes_done < 2) begin
      lane_mask = 8'hFF;
      for (int k = 0; k < TB_NUM_LANES; k++)
        lane_data[k] = (TB_DATA_SIZE*8)'(64'h5555_0000_0000_0000
                                        | (64'(pushes_done) << 32)
                                        | 64'(k));
      mmio_burst_write(lane_mask, lane_data, fire_cycle);
      for (int k = 0; k < TB_NUM_LANES; k++) expected.push_back(lane_data[k]);
      pushes_done++;
    end

    // Now request a third 0xFF push. The FIFO has 0 free slots so
    // req_ready must be 0 until issue_if drains.  Drive req_valid
    // and watch that req_ready stays low for several cycles.
    begin
      logic seen_low;
      int   wait_cycles;
      seen_low = 1'b0;
      wait_cycles = 0;

      // Set up the request signals but do NOT use mmio_burst_write's
      // blocking wait (we want to observe req_ready=0).
      lane_mask = 8'hFF;
      for (int k = 0; k < TB_NUM_LANES; k++)
        lane_data[k] = (TB_DATA_SIZE*8)'(64'h6666_0000_0000_0000 | 64'(k));
      for (int k = 0; k < TB_NUM_LANES; k++) begin
        mmio_if[0].req_data.addr[k]   = byte_to_addr(TB_CFG_BASE_ADDR
                                                   + STREAM_OFF_B
                                                   + 64'(k) * 64'(TB_DATA_SIZE));
        mmio_if[0].req_data.data[k]   = lane_data[k];
        mmio_if[0].req_data.byteen[k] = '1;
        mmio_if[0].req_data.flags[k]  = '0;
      end
      mmio_if[0].req_data.mask = lane_mask;
      mmio_if[0].req_data.rw   = 1'b1;
      @(negedge clk);
      mmio_if[0].req_valid = 1'b1;

      // Watch for 4 cycles: req_ready must remain 0 since FIFO is full.
      for (int c = 0; c < 4; c++) begin
        @(posedge clk);
        if (mmio_if[0].req_valid && !mmio_if[0].req_ready) seen_low = 1'b1;
        if (mmio_if[0].req_valid && mmio_if[0].req_ready)
          $fatal(1, "FIFO full but req_ready high at cycle %0d", c);
      end
      if (!seen_low)
        $fatal(1, "did not observe req_ready=0 while FIFO full");
      $display("[PASS] FIFO full backpressure observed");

      // Now drain the FIFO and confirm the third burst eventually fires.
      @(negedge clk);
      issue_ready_q = 1'b1;
      wait_cycles = 0;
      while (!(mmio_if[0].req_valid && mmio_if[0].req_ready)) begin
        @(posedge clk);
        wait_cycles++;
        if (wait_cycles > 200)
          $fatal(1, "third burst never fired after drain");
      end
      // Capture the third burst's expected words.
      for (int k = 0; k < TB_NUM_LANES; k++) expected.push_back(lane_data[k]);
      @(negedge clk);
      mmio_if[0].req_valid = 1'b0;
    end

    // Wait for total 24 words to drain.
    begin
      int c;
      c = 0;
      while (issue_q.size() < expected.size()) begin
        @(posedge clk);
        c++;
        if (c > 200)
          $fatal(1, "final drain timeout: got=%0d exp=%0d",
                 issue_q.size(), expected.size());
      end
      issue_ready_q = 1'b0;
      if (issue_q.size() !== expected.size())
        $fatal(1, "final size mismatch");
      for (int i = 0; i < expected.size(); i++) begin
        if (issue_q[i] !== expected[i])
          $fatal(1, "final[%0d] mismatch got=0x%016h exp=0x%016h",
                 i, issue_q[i], expected[i]);
      end
    end
    $display("[PASS] FIFO near-full + drain ordering");

    $display("====================================");
    $display("PASS: tb_VX_gemm_job_frontend");
    $display("====================================");

    #20;
`ifdef VCS
    $fsdbDumpoff();
`else
    $dumpoff();
`endif
    $finish;
  end

  // Watchdog
  initial begin
    #500000;
    $fatal(1, "global timeout");
  end

endmodule
