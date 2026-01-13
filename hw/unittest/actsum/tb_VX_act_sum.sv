`timescale 1ns / 1ps

`include "VX_define.vh"

module tb_VX_act_sum;
  parameter string tb_name = "tb_VX_act_sum";
  parameter real PERIOD = 10.0;

`ifndef TB_PIPELINE_STAGES
`define TB_PIPELINE_STAGES 2
`endif

`ifndef TB_DLY_CYCLES
`define TB_DLY_CYCLES 1
`endif

  localparam int IN_DW      = `SEL_BLOCK_WIDTH;
  localparam int ALIGNED_DW = `SIGNED_ALIGNED_MAN_FULL_WIDTH;
  localparam int OUT_DW     = `SAMF_SUM_WIDTH;
  localparam int NUM_UNIT   = `MXU_ROW;
  localparam int BLOCK_SIZE = `BLOCK_SIZE;
  localparam int BLK_BITW   = `BLOCK_IDX_WIDTH;

  // Keep DUT params and TB checks consistent
  localparam int DUT_PIPELINE_STAGES = `TB_PIPELINE_STAGES; // bitmask, see VX_reduce_tree_pipelined
  localparam int DUT_DLY_CYCLES      = `TB_DLY_CYCLES;

  logic clk_i;
  logic resetn_i;

  logic valid_i;
  logic ready_o;
  logic [NUM_UNIT-1:0][IN_DW-1:0] data_i;
  logic [NUM_UNIT-1:0][BLK_BITW-1:0] blk_idx_i;

  logic [OUT_DW-1:0] sum_act_o;
  logic valid_o;

  VX_act_sum #(
    .IN_DW(IN_DW),
    .ALIGNED_DW(ALIGNED_DW),
    .OUT_DW(OUT_DW),
    .NUM_UNIT(NUM_UNIT),
    .BLOCK_SIZE(BLOCK_SIZE),
    .PIPELINE_STAGES(DUT_PIPELINE_STAGES),
    .DLY_CYCLES(DUT_DLY_CYCLES)
  ) dut (
    .clk_i(clk_i),
    .resetn_i(resetn_i),
    .valid_i(valid_i),
    .ready_o(ready_o),
    .data_i(data_i),
    .blk_idx_i(blk_idx_i),
    .sum_act_o(sum_act_o),
    .valid_o(valid_o)
  );

  // clock
  initial clk_i = 1'b0;
  always #(PERIOD/2.0) clk_i = ~clk_i;

  // wave/log paths (mxu TB 스타일)
  string name;
  string fsdb_file_path;
  string fst_file_path;
  string rpt_file_path;
  string log_file_path;
  integer rpt_fd;
  integer log_fd;

  initial begin
    $timeformat(-9, 0, "ns", 0);

    $sformat(name, "%s", tb_name);
    $sformat(fsdb_file_path, "./reports/%s.fsdb", name);
    $sformat(fst_file_path,  "./reports/%s.fst",  name);
    $sformat(log_file_path,  "./logs/%s.log",     name);
    $sformat(rpt_file_path,  "./reports/%s.rpt",  name);

`ifdef VCS
    $fsdbDumpfile(fsdb_file_path);
    $fsdbDumpvars(0, "+all", "+parameter", "+functions");
`else
    $dumpfile(fst_file_path);
    $dumpvars(0, tb_VX_act_sum);
`endif

    rpt_fd = $fopen(rpt_file_path, "w");
    log_fd = $fopen(log_file_path, "w");
  end

  // timeout
  initial begin
    #(200000);
    $display("TIMEOUT");
    $finish;
  end

  int error_count = 0;
  int sent_count = 0;
  int recv_count = 0;
  int drain_cycles = 0;

  // negedge 기준 cycle counter (output은 negedge에서 샘플링)
  int neg_cyc = 0;
  int cur_neg_cyc = 0;

  // expected queues: sum + due cycle
  logic signed [OUT_DW-1:0] expected_sum_q[$];
  int expected_due_q[$];

  function automatic int popcount_int(input int v);
    int cnt;
    cnt = 0;
    for (int i = 0; i < 32; i++) begin
      if (((v >> i) & 1) != 0)
        cnt++;
    end
    return cnt;
  endfunction

  localparam int TOTAL_DELAY = popcount_int(DUT_PIPELINE_STAGES) + DUT_DLY_CYCLES;

  function automatic logic signed [OUT_DW-1:0] calc_expected(
    input logic [NUM_UNIT-1:0][IN_DW-1:0] data,
    input logic [NUM_UNIT-1:0][BLK_BITW-1:0] idx
  );
    logic signed [OUT_DW-1:0] acc;
    acc = '0;
    for (int i = 0; i < NUM_UNIT; i++) begin
      logic signed [ALIGNED_DW-1:0] ext;
      logic signed [ALIGNED_DW-1:0] sh;
      ext = $signed(ALIGNED_DW'(data[i]));
      sh  = ext <<< (BLOCK_SIZE * idx[i]);
      acc = acc + $signed(sh);
    end
    return acc;
  endfunction

  task automatic drive_one(
    input logic [NUM_UNIT-1:0][IN_DW-1:0] data,
    input logic [NUM_UNIT-1:0][BLK_BITW-1:0] idx,
    input int gap_cycles
  );
    logic signed [OUT_DW-1:0] exp;

    repeat (gap_cycles) @(posedge clk_i);

    exp = calc_expected(data, idx);

    // Drive on negedge to avoid race with DUT sampling on posedge (VCS 안정화)
    @(negedge clk_i);
    valid_i <= 1'b1;
    data_i <= data;
    blk_idx_i <= idx;

    // wait handshake
    while (!(valid_i && ready_o)) @(posedge clk_i);

    // Handshake happened at this posedge; due is measured in negedge-cycles.
    // The next negedge increments neg_cyc, so accept_cyc = neg_cyc + 1.
    expected_sum_q.push_back(exp);
    expected_due_q.push_back((neg_cyc + 1) + TOTAL_DELAY);
    sent_count++;

    // Deassert on negedge as well (keep setup/hold away from posedge)
    @(negedge clk_i);
    valid_i <= 1'b0;
  endtask

  // Sample/check output on negedge to avoid same-edge ordering issues with drive_one
  // (task resumes on posedge; always@posedge could run before expected_q push in VCS)
  always @(negedge clk_i) begin
    if (!resetn_i) begin
      neg_cyc <= 0;
      cur_neg_cyc = 0;
    end else begin
      // NOTE: neg_cyc is updated with NBA, so use a blocking shadow for comparisons
      cur_neg_cyc = neg_cyc + 1;
      neg_cyc <= cur_neg_cyc;
      if (valid_o) begin
        if (expected_sum_q.size() == 0) begin
          $display("ERROR: output with empty expected queue: got=0x%0h", sum_act_o);
          error_count++;
        end else begin
          logic signed [OUT_DW-1:0] exp;
          int due;
          exp = expected_sum_q[0];
          due = expected_due_q[0];
          expected_sum_q.pop_front();
          expected_due_q.pop_front();
          recv_count++;

          if (cur_neg_cyc !== due) begin
            $display("ERROR: latency mismatch at recv %0d", recv_count);
            $display("  expected due neg_cyc = %0d (TOTAL_DELAY=%0d)", due, TOTAL_DELAY);
            $display("  got      neg_cyc     = %0d", cur_neg_cyc);
            error_count++;
          end

          if ($signed(sum_act_o) !== exp) begin
            $display("ERROR: mismatch at recv %0d", recv_count);
            $display("  expected = 0x%0h (%0d)", exp, exp);
            $display("  got      = 0x%0h (%0d)", sum_act_o, $signed(sum_act_o));
            error_count++;
          end
        end
      end
    end
  end

  task automatic test_directed();
    logic [NUM_UNIT-1:0][IN_DW-1:0] d;
    logic [NUM_UNIT-1:0][BLK_BITW-1:0] idx;

    // all zero
    d = '0;
    idx = '0;
    drive_one(d, idx, 0);

    // single lane positive, shift 0
    d = '0;
    idx = '0;
    d[0] = IN_DW'(5);
    drive_one(d, idx, 1);

    // single lane negative, shift 1
    d = '0;
    idx = '0;
    d[3] = IN_DW'(-7);
    idx[3] = BLK_BITW'(1);
    drive_one(d, idx, 2);

    // mixed
    d = '0;
    idx = '0;
    d[0] = IN_DW'(3);
    d[1] = IN_DW'(-2);
    d[2] = IN_DW'(1);
    idx[0] = BLK_BITW'(0);
    idx[1] = BLK_BITW'(2);
    idx[2] = BLK_BITW'(1);
    drive_one(d, idx, 0);
  endtask

  task automatic test_random(int n);
    for (int t = 0; t < n; t++) begin
      logic [NUM_UNIT-1:0][IN_DW-1:0] d;
      logic [NUM_UNIT-1:0][BLK_BITW-1:0] idx;
      int gap;

      for (int i = 0; i < NUM_UNIT; i++) begin
        d[i] = $urandom();
        idx[i] = $urandom();
      end

      gap = $urandom_range(0, 5);
      drive_one(d, idx, gap);
    end
  endtask

  initial begin
    $display("======================================");
    $display("  VX_act_sum Testbench");
    $display("  IN_DW=%0d ALIGNED_DW=%0d OUT_DW=%0d NUM_UNIT=%0d BLOCK_SIZE=%0d", IN_DW, ALIGNED_DW, OUT_DW, NUM_UNIT, BLOCK_SIZE);
    $display("  PIPELINE_STAGES=0x%0h (popcount=%0d) DLY_CYCLES=%0d => TOTAL_DELAY=%0d", DUT_PIPELINE_STAGES, popcount_int(DUT_PIPELINE_STAGES), DUT_DLY_CYCLES, TOTAL_DELAY);
    $display("======================================");

    valid_i = 1'b0;
    data_i = '0;
    blk_idx_i = '0;

    resetn_i = 1'b0;
    repeat (5) @(posedge clk_i);
    resetn_i = 1'b1;
    repeat (5) @(posedge clk_i);

    test_directed();
    test_random(200);

    // drain
    drain_cycles = 0;
    while ((expected_sum_q.size() != 0) && (drain_cycles < 20000)) begin
      @(posedge clk_i);
      drain_cycles++;
    end

    $display("======================================");
    $display("  Test Summary");
    $display("======================================");
    $display("  Sent:   %0d", sent_count);
    $display("  Recv:   %0d", recv_count);
    $display("  Pending expected: %0d", expected_sum_q.size());
    $display("  Failed: %0d", error_count);

    if (error_count == 0 && expected_sum_q.size() == 0) begin
      $display("\n*** ALL TESTS PASSED ***");
    end else begin
      $display("\n*** TESTS FAILED ***");
    end

`ifdef VCS
    $fsdbDumpoff();
`else
    $dumpoff();
`endif
    $fclose(rpt_fd);
    $fclose(log_fd);

    $finish;
  end

endmodule
