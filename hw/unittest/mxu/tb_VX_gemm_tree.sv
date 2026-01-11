`timescale 1ns / 1ps

`include "VX_define.vh"

`define MAX_INPUT_CYCLES 8

module tb_VX_gemm_tree import VX_gpu_pkg::*;();
  parameter string tb_name = "tb_VX_gemm_tree";

  parameter PERIOD = 10.0;
  parameter FREQ = 100;
  parameter string OBJ = "func";
  parameter string FILE_POSTFIX = "func";

  localparam int IN_DW              = `IFP_WIDTH;
  localparam int WEIGHT_DW          = `W_BIT_WIDTH;
  localparam int OUT_DW             = `O_BIT_WIDTH;
  localparam int BLOCK_SIZE         = `BLOCK_SIZE;
  localparam int BLOCK_NUM          = `BLOCK_NUM;
  localparam int SEL_BLOCK_NUM      = `SEL_BLOCK_NUM;
  localparam int ROW_SIZE           = 4;
  localparam int COL_SIZE           = 4;
  localparam int TILE_COL_SIZE      = 4;
  localparam int WEIGHT_LOAD_ROW_NUM = 1;
  localparam int WEIGHT_LOAD_COL_NUM = 1;
  localparam int BLK_BITW           = `BLOCK_IDX_WIDTH;

  logic resetn;

  logic clk_i;
  logic [ROW_SIZE-1:0][IN_DW-1:0] ifmap_i;
  logic [COL_SIZE-1:0][WEIGHT_LOAD_ROW_NUM-1:0][WEIGHT_DW-1:0] weight_i;
  logic in_weight_sel_i;
  logic out_weight_sel_i;
  logic ready_weight_i;
  logic [WEIGHT_LOAD_ROW_NUM-1:0][$clog2(ROW_SIZE)-1:0] weight_dst_i;
  logic input_valid_i;
  logic weight_load_dir_i;
  logic [ROW_SIZE-1:0][BLK_BITW-1:0] blk_sidx_i;
  logic [COL_SIZE-1:0][OUT_DW-1:0] ps_o;
  logic [COL_SIZE/TILE_COL_SIZE-1:0] output_valid_o;

  logic test_5_active;

  VX_gemm_tree #(
      .IN_DW              (IN_DW),
      .WEIGHT_DW          (WEIGHT_DW),
      .OUT_DW             (OUT_DW),
      .BLOCK_SIZE         (BLOCK_SIZE),
      .BLOCK_NUM          (BLOCK_NUM),
      .SEL_BLOCK_NUM      (SEL_BLOCK_NUM),
      .ROW_SIZE           (ROW_SIZE),
      .COL_SIZE           (COL_SIZE),
      .TILE_COL_SIZE      (TILE_COL_SIZE),
      .WEIGHT_LOAD_ROW_NUM(WEIGHT_LOAD_ROW_NUM),
      .WEIGHT_LOAD_COL_NUM(WEIGHT_LOAD_COL_NUM)
  ) u_gemm_tree (
      .clk_i            (clk_i),
      .resetn_i         (resetn),
      .ifmap_i          (ifmap_i),
      .weight_i         (weight_i),
      .in_weight_sel_i  (in_weight_sel_i),
      .out_weight_sel_i (out_weight_sel_i),
      .ready_weight_i   (ready_weight_i),
      .weight_dst_i     (weight_dst_i),
      .input_valid_i    (input_valid_i),
      .weight_load_dir_i(weight_load_dir_i),
      .blk_sidx_i       (blk_sidx_i),
      .ps_o             (ps_o),
      .output_valid_o   (output_valid_o)
  );

  VX_stream_intf #(
    .DATA_WIDTH(TILE_COL_SIZE*OUT_DW)
  ) output_in [COL_SIZE/TILE_COL_SIZE](
    .clk(clk_i)
  );
  VX_stream_intf #(
    .DATA_WIDTH(TILE_COL_SIZE*OUT_DW)
  ) output_out [COL_SIZE/TILE_COL_SIZE](
    .clk(clk_i)
  );
  virtual VX_stream_slave_always_ready_dbg_if #(
    .DATA_WIDTH(TILE_COL_SIZE*OUT_DW)
  ) fifo_dbg_vif [COL_SIZE/TILE_COL_SIZE];

  generate
    for(genvar i=0; i<COL_SIZE/TILE_COL_SIZE; i=i+1) begin : gen_output_fifo
      VX_stream_slave_always_ready #(
        .DATA_WIDTH(COL_SIZE*OUT_DW)
      ) u_fifo (
        .clk_i(clk_i),
        .rst_ni(resetn),
        .clear_i('0),
        .flags_o(/*unused*/),
        .push_i(output_in[i]),
        .pop_o(output_out[i])
      );
      assign output_out[i].ready=1'b0;
      assign output_in[i].data = ps_o[i*(TILE_COL_SIZE*OUT_DW) +: TILE_COL_SIZE*OUT_DW];
      assign output_in[i].strb = '1;
      assign output_in[i].valid = output_valid_o[i] & test_5_active;

      initial begin
        fifo_dbg_vif[i] = u_fifo.dbg_if;
      end
    end
  endgenerate

  integer rpt_fd;
  integer log_fd;
  
  // Debug: Monitor queue pushes
  always @(posedge clk_i) begin
    for(int i=0; i<COL_SIZE/TILE_COL_SIZE; i=i+1) begin
      if (output_valid_o[i] && test_5_active) begin
        $display("@%0t: Queue %0d push - ps_o=%h, valid=%b", $time, i, ps_o[i*TILE_COL_SIZE +: TILE_COL_SIZE], output_valid_o[i]);
      end
    end
  end

  string fsdb_file_path;
  string fst_file_path;
  string rpt_file_path;
  string log_file_path;
  string name;

  initial clk_i = 0;
  always #(PERIOD / 2) clk_i = ~clk_i;

  initial begin
    // time setting
    $timeformat(-9, 0, "ns", 0);

    // file name setting
    $sformat(name, "%s.%s", tb_name, FILE_POSTFIX);
    $sformat(fsdb_file_path, "./reports/%s.fsdb", name);
    $sformat(fst_file_path, "./reports/%s.fst", name);
    $sformat(log_file_path, "./logs/%s.log", name);
    $sformat(rpt_file_path, "./reports/%s.rpt", name);

    // fsdb setting
`ifdef VCS
    $fsdbDumpfile(fsdb_file_path);
    $fsdbDumpvars(0, "+all", "+parameter", "+functions");
`else
    $dumpfile(fst_file_path);
    $dumpvars(0, tb_VX_gemm_tree);
`endif

    // open result files
    rpt_fd = $fopen(rpt_file_path, "w");
    log_fd = $fopen(log_file_path, "w");
  end

  generate
    localparam string OBJ_ = OBJ;
    initial begin
      if (OBJ_ == "power") begin
        sim_power();
      end else if (OBJ_ == "func") begin
        sim_func();
      end else begin
        $display("please set proper objective of the simulation");
      end

      // close resources
`ifdef VCS
      $fsdbDumpoff();
`else
      $dumpoff();
`endif
      $fclose(rpt_fd);
      $fclose(log_fd);
      $finish;
    end
  endgenerate

  task sim_func();
    $display("=====================================================================");
    $display("=======================  START SIMULATION  ==========================");
    $display("=====================================================================");
    $display("BLOCK_SIZE    : %0d", BLOCK_SIZE);
    $display("BLOCK_NUM     : %0d", BLOCK_NUM);
    $display("SEL_BLOCK_NUM : %0d", SEL_BLOCK_NUM);
    $display("ROW_SIZE      : %0d", ROW_SIZE);
    $display("COL_SIZE      : %0d", COL_SIZE);
    $display("IN_DW         : %0d", IN_DW);
    $display("WEIGHT_DW     : %0d", WEIGHT_DW);
    $display("OUT_DW        : %0d", OUT_DW);
    $display("GEMM_LATENCY  : %0d cycles", calc_gemm_latency());

    resetn = 0;
    `WAIT_POSEDGE(clk_i, PERIOD);
    resetn = 1;
    
    test_weight_load(0); // Row direction
    test_weight_load(1); // Column direction
    /*
    // Test 0: Reference function verification
    test_reference_verification();
    
    // Test 1: Simple all-ones test
    test_all_ones();
    
    // Test 2: Identity-like test  
    test_identity();
    
    // Test 3: Block index alignment test
    test_block_alignment();
    
    // Test 4: Different weight values
    test_different_weights();
    */

    // Test 6: Random test with multiple input vectors
    test_random_matrix(1);
    
    $display("=====================================================================");
    $display("=====================  ALL TESTS COMPLETED  =========================");
    $display("=====================================================================");
  endtask

  // Test 0: Reference function verification
  task test_reference_verification();
    automatic logic [`MAX_INPUT_CYCLES-1:0][ROW_SIZE-1:0][IN_DW-1:0] ifmap_history;
    automatic logic [COL_SIZE-1:0][ROW_SIZE-1:0][WEIGHT_DW-1:0] weight_ref;
    automatic logic [`MAX_INPUT_CYCLES-1:0][ROW_SIZE-1:0][BLK_BITW-1:0] blk_idx_history;
    automatic logic [`MAX_INPUT_CYCLES-1:0][COL_SIZE-1:0][OUT_DW-1:0] expected_output;
    
    $display("\n[TEST 0] Reference Function Verification");
    
    // Test Case 1: Simple 2x2 with all ones
    $display("\n--- Test Case 1: All ones (2 input cycles) ---");
    for (int cycle = 0; cycle < 2; cycle++) begin
      for (int row = 0; row < ROW_SIZE; row++) begin
        ifmap_history[cycle][row] = 1;
        blk_idx_history[cycle][row] = 0; // No shift
      end
    end
    
    for (int col = 0; col < COL_SIZE; col++) begin
      for (int row = 0; row < ROW_SIZE; row++) begin
        weight_ref[col][row] = 1;
      end
    end
    
    // Print inputs
    $display("Input matrices:");
    for (int cycle = 0; cycle < 2; cycle++) begin
      $display("  Cycle %0d ifmap: %p", cycle, ifmap_history[cycle]);
    end
    $display("Weight matrix (col x row):");
    for (int col = 0; col < COL_SIZE; col++) begin
      $display("  Col %0d: %p", col, weight_ref[col]);
    end
    
    calc_gemm_reference(ifmap_history, weight_ref, blk_idx_history, 2, expected_output);
    
    $display("Expected outputs:");
    for (int cycle = 0; cycle < 2; cycle++) begin
      $display("  Cycle %0d: %p", cycle, expected_output[cycle]);
      for (int col = 0; col < COL_SIZE; col++) begin
        $display("    Col[%0d] = %0d (should be %0d)", col, $signed(expected_output[cycle][col]), ROW_SIZE);
      end
    end
    
    // Test Case 2: Identity-like with incremental values
    $display("\n--- Test Case 2: Incremental values (1 input cycle) ---");
    for (int row = 0; row < ROW_SIZE; row++) begin
      ifmap_history[0][row] = row + 1; // 1, 2, 3, 4
      blk_idx_history[0][row] = 0;
    end
    
    for (int col = 0; col < COL_SIZE; col++) begin
      for (int row = 0; row < ROW_SIZE; row++) begin
        weight_ref[col][row] = 2; // All weights = 2
      end
    end
    
    $display("Input:");
    $display("  Cycle 0 ifmap: %p", ifmap_history[0]);
    $display("Weight matrix (all 2s):");
    for (int col = 0; col < COL_SIZE; col++) begin
      $display("  Col %0d: %p", col, weight_ref[col]);
    end
    
    calc_gemm_reference(ifmap_history, weight_ref, blk_idx_history, 1, expected_output);
    
    $display("Expected output:");
    $display("  Cycle 0: %p", expected_output[0]);
    for (int col = 0; col < COL_SIZE; col++) begin
      automatic int expected_val = 2 * (1 + 2 + 3 + 4); // 2 * 10 = 20
      $display("    Col[%0d] = %0d (should be %0d)", col, $signed(expected_output[0][col]), expected_val);
    end
    
    $display("\n--- Reference Function Verification Complete ---\n");
  endtask

  // Test 1: All ones - simplest case
  // Expected: Each output = ROW_SIZE (32)
  task test_all_ones();
    automatic logic [`MAX_INPUT_CYCLES-1:0][ROW_SIZE-1:0][IN_DW-1:0] ifmap_history;
    automatic logic [COL_SIZE-1:0][ROW_SIZE-1:0][WEIGHT_DW-1:0] weight_ref;
    automatic logic [`MAX_INPUT_CYCLES-1:0][ROW_SIZE-1:0][BLK_BITW-1:0] blk_idx_history;
    automatic logic [`MAX_INPUT_CYCLES-1:0][COL_SIZE-1:0][OUT_DW-1:0] expected_output;
    automatic int pass_count, fail_count;
    
    $display("\n[TEST 1] All Ones Test");
    
    // reset
    ifmap_i = '0;
    weight_i = '0;
    in_weight_sel_i = '0;
    out_weight_sel_i = '0;
    input_valid_i = '0;
    ready_weight_i = '0;
    weight_dst_i = '0;
    weight_load_dir_i = '0;
    blk_sidx_i = '0;
    
    `WAIT_POSEDGE(clk_i, PERIOD);
    
    // Load weights (all 1s)
    $display("Loading weights (all 1s)...");
    in_weight_sel_i = 0;
    ready_weight_i = 1;
    for (int i = 0; i < ROW_SIZE; i++) begin
      for (int j = 0; j < COL_SIZE; j++) begin
        for (int k = 0; k < WEIGHT_LOAD_ROW_NUM; k++) begin
          weight_i[j][k] = 1;
          weight_dst_i[k] = i;  // Set destination to current row index
        end
      end
      `WAIT_POSEDGE(clk_i, PERIOD);
    end
    ready_weight_i = 0;
    out_weight_sel_i = in_weight_sel_i;
    
    // Set input (all 1s)
    $display("Setting inputs (all 1s)...");
    for (int i = 0; i < ROW_SIZE; i++) begin
      ifmap_i[i] = 1;
      blk_sidx_i[i] = 0;
      ifmap_history[0][i] = 1;
      blk_idx_history[0][i] = 0;
    end
    
    // Set weight reference (all 1s)
    for (int col = 0; col < COL_SIZE; col++) begin
      for (int row = 0; row < ROW_SIZE; row++) begin
        weight_ref[col][row] = 1;
      end
    end
    
    // Start computation
    input_valid_i = 1;
    repeat (calc_gemm_latency()) `WAIT_POSEDGE(clk_i, PERIOD);
    
    // Calculate expected output
    calc_gemm_reference(ifmap_history, weight_ref, blk_idx_history, 1, expected_output);
    
    // Check results
    $display("Results:");
    pass_count = 0;
    fail_count = 0;
    for (int j = 0; j < COL_SIZE; j++) begin
      automatic logic match = ($signed(ps_o[j]) == $signed(expected_output[0][j]));
      $display("  ps_o[%0d] = %0d (expected: %0d) %s", 
               j, $signed(ps_o[j]), $signed(expected_output[0][j]),
               match ? "PASS" : "FAIL");
      $fdisplay(log_fd, "[TEST1] ps_o[%0d] = %0d (expected: %0d)", j, $signed(ps_o[j]), $signed(expected_output[0][j]));
      if (match) pass_count++; else fail_count++;
    end
    $display("Summary: %0d PASS, %0d FAIL out of %0d outputs", pass_count, fail_count, COL_SIZE);
    
    input_valid_i = 0;
    `WAIT_POSEDGE(clk_i, PERIOD);
  endtask

  // Test 2: Identity-like test with incremental values
  // ifmap = [1, 2, 3, ..., 32]
  // weight = [1, 1, 1, ...] for each column
  // Expected: ps_o[i] = sum(1..32) = 528
  task test_identity();
    automatic logic [`MAX_INPUT_CYCLES-1:0][ROW_SIZE-1:0][IN_DW-1:0] ifmap_history;
    automatic logic [COL_SIZE-1:0][ROW_SIZE-1:0][WEIGHT_DW-1:0] weight_ref;
    automatic logic [`MAX_INPUT_CYCLES-1:0][ROW_SIZE-1:0][BLK_BITW-1:0] blk_idx_history;
    automatic logic [`MAX_INPUT_CYCLES-1:0][COL_SIZE-1:0][OUT_DW-1:0] expected_output;
    automatic int pass_count, fail_count;
    
    $display("\n[TEST 2] Identity Test");
    
    // reset
    ifmap_i = '0;
    weight_i = '0;
    input_valid_i = '0;
    ready_weight_i = '0;
    weight_dst_i = '0;
    blk_sidx_i = '0;
    
    `WAIT_POSEDGE(clk_i, PERIOD);
    
    // Load weights (all 1s)
    $display("Loading weights (all 1s)...");
    in_weight_sel_i = ~in_weight_sel_i;
    ready_weight_i = 1;
    for (int i = 0; i < ROW_SIZE; i++) begin
      for (int j = 0; j < COL_SIZE; j++) begin
        for (int k = 0; k < WEIGHT_LOAD_ROW_NUM; k++) begin
          weight_i[j][k] = 1;
          weight_dst_i[k] = i;  // Set destination to current row index
        end
      end
      `WAIT_POSEDGE(clk_i, PERIOD);
    end
    ready_weight_i = 0;
    out_weight_sel_i = in_weight_sel_i;
    
    // Set input (incremental: 1, 2, 3, ..., 32)
    $display("Setting inputs (1..%0d)...", ROW_SIZE);
    for (int i = 0; i < ROW_SIZE; i++) begin
      ifmap_i[i] = i + 1;
      blk_sidx_i[i] = 0;
      ifmap_history[0][i] = i + 1;
      blk_idx_history[0][i] = 0;
    end
    
    // Set weight reference (all 1s)
    for (int col = 0; col < COL_SIZE; col++) begin
      for (int row = 0; row < ROW_SIZE; row++) begin
        weight_ref[col][row] = 1;
      end
    end
    
    // Start computation
    input_valid_i = 1;
    repeat (calc_gemm_latency()) `WAIT_POSEDGE(clk_i, PERIOD);
    
    // Calculate expected output
    calc_gemm_reference(ifmap_history, weight_ref, blk_idx_history, 1, expected_output);
    
    // Check results
    $display("Results:");
    pass_count = 0;
    fail_count = 0;
    for (int j = 0; j < COL_SIZE; j++) begin
      automatic logic match = ($signed(ps_o[j]) == $signed(expected_output[0][j]));
      $display("  ps_o[%0d] = %0d (expected: %0d) %s", 
               j, $signed(ps_o[j]), $signed(expected_output[0][j]),
               match ? "PASS" : "FAIL");
      $fdisplay(log_fd, "[TEST2] ps_o[%0d] = %0d (expected: %0d)", j, $signed(ps_o[j]), $signed(expected_output[0][j]));
      if (match) pass_count++; else fail_count++;
    end
    $display("Summary: %0d PASS, %0d FAIL out of %0d outputs", pass_count, fail_count, COL_SIZE);
    
    input_valid_i = 0;
    `WAIT_POSEDGE(clk_i, PERIOD);
  endtask

  // Test 3: Block alignment test
  // Test different block indices for alignment
  task test_block_alignment();
    automatic logic [`MAX_INPUT_CYCLES-1:0][ROW_SIZE-1:0][IN_DW-1:0] ifmap_history;
    automatic logic [COL_SIZE-1:0][ROW_SIZE-1:0][WEIGHT_DW-1:0] weight_ref;
    automatic logic [`MAX_INPUT_CYCLES-1:0][ROW_SIZE-1:0][BLK_BITW-1:0] blk_idx_history;
    automatic logic [`MAX_INPUT_CYCLES-1:0][COL_SIZE-1:0][OUT_DW-1:0] expected_output;
    
    $display("\n[TEST 3] Block Alignment Test");
    
    // reset
    ifmap_i = '0;
    weight_i = '0;
    input_valid_i = '0;
    ready_weight_i = '0;
    weight_dst_i = '0;
    blk_sidx_i = '0;
    
    `WAIT_POSEDGE(clk_i, PERIOD);
    
    // Load weights (all 1s)
    in_weight_sel_i = ~in_weight_sel_i;
    ready_weight_i = 1;
    for (int i = 0; i < ROW_SIZE; i++) begin
      for (int j = 0; j < COL_SIZE; j++) begin
        for (int k = 0; k < WEIGHT_LOAD_ROW_NUM; k++) begin
          weight_i[j][k] = 1;
          weight_dst_i[k] = i;  // Set destination to current row index
        end
      end
      `WAIT_POSEDGE(clk_i, PERIOD);
    end
    ready_weight_i = 0;
    out_weight_sel_i = in_weight_sel_i;
    
    // Set weight reference (all 1s)
    for (int col = 0; col < COL_SIZE; col++) begin
      for (int row = 0; row < ROW_SIZE; row++) begin
        weight_ref[col][row] = 1;
      end
    end
    
    // Set input (all 2s for easy calculation)
    for (int i = 0; i < ROW_SIZE; i++) begin
      ifmap_i[i] = 2;
      ifmap_history[0][i] = 2;
    end
    
    input_valid_i = 1;
    
    // Test different block indices
    for (int blk_idx = 0; blk_idx < 3; blk_idx++) begin
      $display("  Testing block_idx = %0d (shift = %0d)", blk_idx, BLOCK_SIZE * blk_idx);
      
      blk_sidx_i = {ROW_SIZE{BLK_BITW'(blk_idx)}};
      for (int i = 0; i < ROW_SIZE; i++) begin
        blk_idx_history[0][i] = blk_idx;
      end
      
      repeat (calc_gemm_latency()) `WAIT_POSEDGE(clk_i, PERIOD);
      
      // Calculate expected output
      calc_gemm_reference(ifmap_history, weight_ref, blk_idx_history, 1, expected_output);
      
      $display("    ps_o[0] = %0d (expected: %0d) %s", 
               $signed(ps_o[0]), $signed(expected_output[0][0]),
               ($signed(ps_o[0]) == $signed(expected_output[0][0])) ? "PASS" : "FAIL");
      $fdisplay(log_fd, "[TEST3] blk_idx=%0d, ps_o[0] = %0d (expected: %0d)", 
                blk_idx, $signed(ps_o[0]), $signed(expected_output[0][0]));
    end
    
    input_valid_i = 0;
    `WAIT_POSEDGE(clk_i, PERIOD);
  endtask

  // Test 4: Different weight values per column
  // weight[j] = j+1, ifmap = all 1s
  // Expected: ps_o[j] = (j+1) * ROW_SIZE, but with 4-bit signed weight overflow
  task test_different_weights();
    automatic logic [`MAX_INPUT_CYCLES-1:0][ROW_SIZE-1:0][IN_DW-1:0] ifmap_history;
    automatic logic [COL_SIZE-1:0][ROW_SIZE-1:0][WEIGHT_DW-1:0] weight_ref;
    automatic logic [`MAX_INPUT_CYCLES-1:0][ROW_SIZE-1:0][BLK_BITW-1:0] blk_idx_history;
    automatic logic [`MAX_INPUT_CYCLES-1:0][COL_SIZE-1:0][OUT_DW-1:0] expected_output;
    automatic int pass_count, fail_count;
    
    $display("\n[TEST 4] Different Weights Test");
    
    // reset
    ifmap_i = '0;
    weight_i = '0;
    input_valid_i = '0;
    ready_weight_i = '0;
    weight_dst_i = '0;
    blk_sidx_i = '0;
    
    `WAIT_POSEDGE(clk_i, PERIOD);
    
    // Load weights (weight[j] = j+1)
    $display("Loading weights (weight[j] = j+1)...");
    in_weight_sel_i = ~in_weight_sel_i;
    ready_weight_i = 1;
    for (int i = 0; i < ROW_SIZE; i++) begin
      for (int j = 0; j < COL_SIZE; j++) begin
        for (int k = 0; k < WEIGHT_LOAD_ROW_NUM; k++) begin
          automatic logic [WEIGHT_DW-1:0] w_val = (j + 1) & ((1 << WEIGHT_DW) - 1);
          weight_i[j][k] = w_val;
          weight_dst_i[k] = i;  // Set destination to current row index
          weight_ref[j][ROW_SIZE-1-i-k] = $signed(w_val);
        end
      end
      `WAIT_POSEDGE(clk_i, PERIOD);
    end
    ready_weight_i = 0;
    out_weight_sel_i = in_weight_sel_i;
    
    // Set input (all 1s)
    $display("Setting inputs (all 1s)...");
    for (int i = 0; i < ROW_SIZE; i++) begin
      ifmap_i[i] = 1;
      blk_sidx_i[i] = 0;
      ifmap_history[0][i] = 1;
      blk_idx_history[0][i] = 0;
    end
    
    // Start computation
    input_valid_i = 1;
    repeat (calc_gemm_latency()) `WAIT_POSEDGE(clk_i, PERIOD);
    
    // Calculate expected output
    calc_gemm_reference(ifmap_history, weight_ref, blk_idx_history, 1, expected_output);
    
    // Check results
    $display("Results:");
    pass_count = 0;
    fail_count = 0;
    for (int j = 0; j < COL_SIZE; j++) begin
      automatic logic match = ($signed(ps_o[j]) == $signed(expected_output[0][j]));
      $display("  ps_o[%0d] = %0d (expected: %0d) %s", 
               j, $signed(ps_o[j]), $signed(expected_output[0][j]),
               match ? "PASS" : "FAIL");
      $fdisplay(log_fd, "[TEST4] ps_o[%0d] = %0d (expected: %0d)", j, $signed(ps_o[j]), $signed(expected_output[0][j]));
      if (match) pass_count++; else fail_count++;
    end
    $display("Summary: %0d PASS, %0d FAIL out of %0d outputs", pass_count, fail_count, COL_SIZE);
    
    input_valid_i = 0;
    `WAIT_POSEDGE(clk_i, PERIOD);
  endtask

  // Test 5: Random test with multiple input vectors
  task test_random_matrix(input int random=1);
    localparam int NUM_INPUT_VECTORS = `MAX_INPUT_CYCLES; // Process MAX input vectors
    automatic logic [`MAX_INPUT_CYCLES-1:0][ROW_SIZE-1:0][IN_DW-1:0] ifmap_history;
    automatic logic [COL_SIZE-1:0][ROW_SIZE-1:0][WEIGHT_DW-1:0] weight_ref;
    automatic logic [`MAX_INPUT_CYCLES-1:0][ROW_SIZE-1:0][BLK_BITW-1:0] blk_idx_history;
    automatic logic [`MAX_INPUT_CYCLES-1:0][COL_SIZE-1:0][OUT_DW-1:0] expected_output;
    automatic int seed = 12345;
    automatic int pass_count;
    automatic int fail_count;

    test_5_active = 1;
    
    $display("\n[TEST 6] Random Test");
    $display("Processing %0d input vectors (MAX_INPUT_CYCLES=%0d)", NUM_INPUT_VECTORS, `MAX_INPUT_CYCLES);
    
    // reset
    ifmap_i = '0;
    weight_i = '0;
    input_valid_i = '0;
    ready_weight_i = '0;
    weight_dst_i = '0;
    blk_sidx_i = '0;
    `WAIT_POSEDGE(clk_i, PERIOD);
    
    // Generate random weights (constrained to 4-bit signed range: -8 to +7)
    $display("Loading random weights...");
    in_weight_sel_i = 0;
    ready_weight_i = 1;
    weight_load_dir_i = 0;
    for (int i = 0; i < ROW_SIZE; i++) begin
      for (int j = 0; j < COL_SIZE; j++) begin
        for (int k = 0; k < WEIGHT_LOAD_ROW_NUM; k++) begin
          automatic int w_val = 0;
          if(random) begin
            w_val = $urandom_range(0, 15) & ((1 << WEIGHT_DW) - 1);
          end else begin
            w_val = 1;
          end
          weight_i[j][k] = w_val;
          weight_dst_i[k] = i;  // Set destination to current row index
          weight_ref[j][ROW_SIZE-1-i-k] = $signed(w_val[WEIGHT_DW-1:0]);
        end
      end
      `WAIT_POSEDGE(clk_i, PERIOD);
    end
    ready_weight_i = 0;
    out_weight_sel_i = in_weight_sel_i;
    
    // Wait for weight loading to settle
    repeat (2) `WAIT_POSEDGE(clk_i, PERIOD);
    
    // Generate and process random input vectors
    $display("Processing %0d random input vectors...", NUM_INPUT_VECTORS);
    input_valid_i = 1;
    for (int vec_idx = 0; vec_idx < NUM_INPUT_VECTORS; vec_idx++) begin
      if (vec_idx < 2) $display("  Input vector %0d:", vec_idx);
      // Generate random input vector
      for (int i = 0; i < ROW_SIZE; i++) begin
        automatic int ifmap_val = $urandom_range(0, 255);
        automatic int blk_idx = $urandom_range(0, 2);
        if(random) begin
          ifmap_val = $urandom_range(0, 255);
          blk_idx = $urandom_range(0, 2);
        end else begin
          ifmap_val = 1;
          blk_idx = 0;
        end
        
        ifmap_i[i] = ifmap_val;
        blk_sidx_i[i] = blk_idx;
        
        // Store for reference calculation
        ifmap_history[vec_idx][i] = ifmap_val;
        blk_idx_history[vec_idx][i] = blk_idx;
        
        if (vec_idx < 2) $display("    ifmap[%0d]=%0d, blk_idx=%0d", i, ifmap_val, blk_idx);
      end
      
      `WAIT_POSEDGE(clk_i, PERIOD);
    end
    input_valid_i = 0;
    
    // Wait for pipeline to produce all outputs
    repeat (calc_gemm_latency()) `WAIT_POSEDGE(clk_i, PERIOD);
    
    // Calculate expected output using reference function
    calc_gemm_reference(ifmap_history, weight_ref, blk_idx_history, NUM_INPUT_VECTORS, expected_output);
    
    test_5_active = 0;
    `WAIT_POSEDGE(clk_i, PERIOD);
    
    // Check queue size
    for(int i=0; i<COL_SIZE/TILE_COL_SIZE; i=i+1) begin
      if (fifo_dbg_vif[i].get_queue_size() != NUM_INPUT_VECTORS) begin
        $display("Error: Output FIFO %0d size = %0d, expected %0d", 
                 i, fifo_dbg_vif[i].get_queue_size(), NUM_INPUT_VECTORS);
      end
    end
    
    // Validate all outputs from queue
    pass_count = 0;
    fail_count = 0;
    
    for (int cycle = 0; cycle < NUM_INPUT_VECTORS; cycle++) begin
      automatic logic [COL_SIZE*OUT_DW-1:0] queue_out;
      for(int i=0; i<COL_SIZE/TILE_COL_SIZE; i=i+1) begin
        queue_out[i*(TILE_COL_SIZE*OUT_DW) +: TILE_COL_SIZE*OUT_DW] = fifo_dbg_vif[i].get_queue_data(cycle);
      end
      for (int j = 0; j < COL_SIZE; j++) begin
        automatic logic [OUT_DW-1:0] hw_output;
        automatic logic match;
        
        // Extract individual column output
        hw_output = queue_out;
        match = ($signed(hw_output) == $signed(expected_output[cycle][j]));
        
        $display("  [Cycle %0d] ps_o[%0d] = %0d (expected: %0d) %s", 
                  cycle, j, $signed(hw_output), $signed(expected_output[cycle][j]),
                  match ? "PASS" : "FAIL");
        
        if (match) begin
          pass_count++;
        end else begin
          fail_count++;
        end
        
        $fdisplay(log_fd, "[TEST6] cycle%0d col[%0d] = %0d (expected: %0d) %s", 
                  cycle, j, $signed(hw_output), $signed(expected_output[cycle][j]),
                  match ? "PASS" : "FAIL");
      end
      
      `WAIT_POSEDGE(clk_i, PERIOD);
    end
    
    $display("Summary: %0d PASS, %0d FAIL out of %0d total outputs (%0d cycles x %0d cols)", 
             pass_count, fail_count, NUM_INPUT_VECTORS * COL_SIZE, NUM_INPUT_VECTORS, COL_SIZE);
    
    input_valid_i = 0;
    `WAIT_POSEDGE(clk_i, PERIOD);
  endtask

  // Test 6: Column direction weight loading
  task test_weight_load(input int direction);
    automatic logic [`MAX_INPUT_CYCLES-1:0][ROW_SIZE-1:0][IN_DW-1:0] ifmap_history;
    automatic logic [COL_SIZE-1:0][ROW_SIZE-1:0][WEIGHT_DW-1:0] weight_ref;
    automatic logic [`MAX_INPUT_CYCLES-1:0][ROW_SIZE-1:0][BLK_BITW-1:0] blk_idx_history;
    automatic logic [`MAX_INPUT_CYCLES-1:0][COL_SIZE-1:0][OUT_DW-1:0] expected_output;
    automatic int pass_count, fail_count;
    automatic integer loop_dim, inner_dim, vec_num;
    
    $display("\nWeight Loading Test. DIR : %0d", direction);
    
    // Clear all signals and wait for pipeline to flush
    ifmap_i = '0;
    weight_i = '0;
    input_valid_i = '0;
    ready_weight_i = '0;
    weight_dst_i = '0;
    blk_sidx_i = '0;
    weight_load_dir_i = ~direction;
    in_weight_sel_i = 1;

    for(int r=0; r<ROW_SIZE; r++) begin
      for(int c=0; c<COL_SIZE; c++) begin
        weight_ref[c][r] = (c + r*COL_SIZE)%4;
      end
    end
    
    // Wait for pipeline to flush completely
    repeat (20) `WAIT_POSEDGE(clk_i, PERIOD);
    
    // Set column direction BEFORE starting weight load
    loop_dim = (direction == 0) ? ROW_SIZE : COL_SIZE;
    inner_dim = (direction == 0) ? COL_SIZE : ROW_SIZE;
    vec_num = (direction == 0) ? WEIGHT_LOAD_ROW_NUM : WEIGHT_LOAD_COL_NUM;

    weight_load_dir_i = direction;  // Column direction!
    in_weight_sel_i = ~in_weight_sel_i;
    ready_weight_i = 1;
    for(int i=0; i<(loop_dim/vec_num); i=i+1) begin
      for(int j=0; j<inner_dim; j=j+1) begin
        for(int k=0; k<vec_num; k=k+1) begin
          if (direction == 0) begin
            weight_i[j][k] = weight_ref[j][i*vec_num + k];
          end else begin
            weight_i[j][k] = weight_ref[i*vec_num + k][j];
          end
          weight_dst_i[k] = i*vec_num + k;
        end
      end
      `WAIT_POSEDGE(clk_i, PERIOD);
    end
    ready_weight_i = 0;
    
    // Wait extra cycles for weight shifting to complete
    repeat (loop_dim/vec_num) `WAIT_POSEDGE(clk_i, PERIOD);

    // check weights
    for(int r=0; r<ROW_SIZE; r++) begin
      for(int c=0; c<COL_SIZE; c++) begin
        automatic logic [WEIGHT_DW-1:0] loaded_weight;
        loaded_weight = u_gemm_tree.u_weight_regs.mem[r][c][0];
        if (loaded_weight !== weight_ref[c][r]) begin
          $display("Weight Mismatch at Row %0d Col %0d : Loaded %0d, Expected %0d", 
                   r, c, $signed(loaded_weight), $signed(weight_ref[c][r]));
        end
      end
    end
    
    `WAIT_POSEDGE(clk_i, PERIOD);
  endtask

  function int ceil_div(int a, int b);
    return (a + b - 1) / b;
  endfunction

  // Calculate GEMM tree latency in cycles
  // Latency = (ROW_SIZE/TILE_ROW_SIZE) * PE_latency
  // PE_latency = 1 (input reg) + PIPE_MULT + PIPE_ALIGN_EXTRA + NUM_ADDER_STAGES + 1 (output reg)
  // where PIPE_ALIGN_EXTRA = (PIPE_ALIGN && !PIPE_MULT) ? 1 : 0
  //       NUM_ADDER_STAGES = number of bits set in PIPELINE_STAGES
  function int calc_gemm_latency();
    int num_pe_rows;
    int pe_latency;
    int num_adder_stages;
    int pipe_align_extra;
    int pipeline_stages;
    int num_stages;
    
    // Number of PE rows
    num_pe_rows = ROW_SIZE / ROW_SIZE;  // TILE_ROW_SIZE = ROW_SIZE
    
    // Calculate number of adder tree stages
    num_stages = $clog2(ROW_SIZE) + 1;
    
    // Calculate PIPELINE_STAGES bitmask (from get_pipe_stage function)
    pipeline_stages = 0;
    for (int i = 0; i < num_stages; i++) begin
      if (i % 1 == 0) begin  // PIPE_INTERVAL = 1
        pipeline_stages = pipeline_stages | (1 << i);
      end
    end
    
    // Count number of pipeline stages in adder tree
    num_adder_stages = 0;
    for (int i = 0; i < num_stages; i++) begin
      if ((pipeline_stages & (1 << i)) != 0) begin
        num_adder_stages++;
      end
    end
    
    // Calculate PIPE_ALIGN extra cycle
    pipe_align_extra = (1 && !1) ? 1 : 0;  // PIPE_ALIGN=1, PIPE_MULT=1
    
    // PE latency = input_reg + PIPE_MULT + PIPE_ALIGN_EXTRA + NUM_ADDER_STAGES + output_reg
    pe_latency = 1 + 1 + pipe_align_extra + num_adder_stages + 1;
    
    // Total latency
    return num_pe_rows * pe_latency;
  endfunction

  // Reference calculation for GEMM operation
  // Computes: output[col] = sum over (k, row): ifmap_history[k][row] * weight[col][row] << blk_idx[k][row]
  // Parameters:
  //   - ifmap_history: stored input vectors from multiple cycles [MAX_INPUT_CYCLES][ROW_SIZE][IN_DW]
  //   - weight_ref: weight matrix [COL_SIZE][ROW_SIZE][WEIGHT_DW]
  //   - blk_idx_history: block indices from multiple cycles [MAX_INPUT_CYCLES][ROW_SIZE][BLK_BITW]
  //   - num_cycles: number of input cycles to process
  //   - expected_output: computed reference output [COL_SIZE][OUT_DW]
  task calc_gemm_reference(
    input logic [`MAX_INPUT_CYCLES-1:0][ROW_SIZE-1:0][IN_DW-1:0] ifmap_history,
    input logic [COL_SIZE-1:0][ROW_SIZE-1:0][WEIGHT_DW-1:0] weight_ref,
    input logic [`MAX_INPUT_CYCLES-1:0][ROW_SIZE-1:0][BLK_BITW-1:0] blk_idx_history,
    input int num_cycles,
    output logic [`MAX_INPUT_CYCLES-1:0][COL_SIZE-1:0][OUT_DW-1:0] expected_output
  );
    automatic longint signed temp_result[COL_SIZE];
    
    // Process each column independently
    for (int k = 0; k < num_cycles; k++) begin // input matrix rows
      for (int col = 0; col < COL_SIZE; col++) begin
        temp_result[col] = 0;
      end
      for (int col = 0; col < COL_SIZE; col++) begin // output matrix cols
        // Accumulate over row dim
        for (int row = 0; row < ROW_SIZE; row++) begin // input matrix columns, weight matrix row
          automatic logic signed [IN_DW-1:0] ifmap_val;
          automatic logic signed [WEIGHT_DW-1:0] weight_val;
          automatic logic [BLK_BITW-1:0] blk_idx;
          automatic longint signed product;
          
          ifmap_val = $signed(ifmap_history[k][row]);
          weight_val = $signed(weight_ref[col][row]);
          blk_idx = blk_idx_history[k][row];
          
          // MAC with block alignment
          product = ifmap_val * weight_val;
          product = product <<< blk_idx;
          temp_result[col] += product;
        end
        // Truncate to OUT_DW bits
        expected_output[k][col] = temp_result[col] & ((longint'(1) <<< OUT_DW) - 1);
      end
    end
  endtask
  
  task sim_power();
    localparam N = 128;
    localparam K = 128;
    localparam M = 128;
    localparam CYCLE = N * ceil_div(K, ROW_SIZE) * ceil_div(M, COL_SIZE);
    localparam INTERVAL = N;

    ifmap_i = '0;
    weight_i = '0;
    in_weight_sel_i = '0;
    out_weight_sel_i = '0;
    ready_weight_i = '0;
    weight_dst_i = '0;
    input_valid_i = '0;
    weight_load_dir_i = '0;

    fork
      // write weight to mxu
      begin : write_weight_to_mxu
        in_weight_sel_i = 1'b0;
        while (1) begin
          ready_weight_i = 1'b1;
          for (int i = 0; i < ROW_SIZE; i++) begin
            std::randomize(weight_i);
            for (int k = 0; k < WEIGHT_LOAD_ROW_NUM; k++) begin
              weight_dst_i[k] = i;  // Set destination to current row index
            end
            `WAIT_POSEDGE(clk_i, PERIOD);
          end
          out_weight_sel_i = in_weight_sel_i;
          ready_weight_i   = 1'b0;
          in_weight_sel_i  = ~in_weight_sel_i;
          for (int w = 0; w < INTERVAL; w++) begin
            `WAIT_POSEDGE(clk_i, PERIOD);
          end
        end
      end

      begin
        input_valid_i = '1;
        while (1) begin
          std::randomize(ifmap_i);
          for (int k = 0; k < ROW_SIZE; k++) begin
            blk_sidx_i[k] = $urandom() % (BLOCK_NUM - SEL_BLOCK_NUM + 1);
          end
          `WAIT_POSEDGE(clk_i, PERIOD);
        end
      end
    join_none

    repeat (CYCLE) begin
      `WAIT_POSEDGE(clk_i, PERIOD);
    end
  endtask

endmodule
