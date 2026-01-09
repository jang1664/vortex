`timescale 1ns / 1ps

`include "VX_define.vh"

// Test configuration macros
`ifndef ENABLE_RANDOM_TEST
  `define ENABLE_RANDOM_TEST 1
`endif

`ifndef MAX_INPUT_CYCLES
  `define MAX_INPUT_CYCLES 8
`endif

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

  logic clk_i;
  logic [ROW_SIZE-1:0][IN_DW-1:0] ifmap_i;
  logic [COL_SIZE-1:0][WEIGHT_LOAD_ROW_NUM-1:0][WEIGHT_DW-1:0] weight_i;
  logic in_weight_sel_i;
  logic out_weight_sel_i;
  logic ready_weight_i;
  logic input_valid_i;
  logic weight_load_dir_i;
  logic [ROW_SIZE-1:0][BLK_BITW-1:0] blk_sidx_i;
  logic [COL_SIZE-1:0][OUT_DW-1:0] ps_o;

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
      .ifmap_i          (ifmap_i),
      .weight_i         (weight_i),
      .in_weight_sel_i  (in_weight_sel_i),
      .out_weight_sel_i (out_weight_sel_i),
      .ready_weight_i   (ready_weight_i),
      .input_valid_i    (input_valid_i),
      .weight_load_dir_i(weight_load_dir_i),
      .blk_sidx_i       (blk_sidx_i),
      .ps_o             (ps_o)
  );

  integer rpt_fd;
  integer log_fd;

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
    
    // Test 1: Simple all-ones test
    test_all_ones();
    
    // Test 2: Identity-like test  
    test_identity();
    
    // Test 3: Block index alignment test
    test_block_alignment();
    
    // Test 4: Different weight values
    test_different_weights();
    
`ifdef ENABLE_RANDOM_TEST
    // Test 5: Random test with multiple input vectors
    test_random_matrix();
`endif
    
    // Test 6: Column direction weight loading
    test_column_direction_loading();
    
    $display("=====================================================================");
    $display("=====================  ALL TESTS COMPLETED  =========================");
    $display("=====================================================================");
  endtask

  // Test 1: All ones - simplest case
  // Expected: Each output = ROW_SIZE (32)
  task test_all_ones();
    automatic longint signed expected;
    
    $display("\n[TEST 1] All Ones Test");
    expected = ROW_SIZE;  // 32 * 1 * 1 = 32
    $display("Expected: Each ps_o[i] = ROW_SIZE * 1 * 1 = %0d", expected);
    
    // reset
    ifmap_i = '0;
    weight_i = '0;
    in_weight_sel_i = '0;
    out_weight_sel_i = '0;
    input_valid_i = '0;
    ready_weight_i = '0;
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
    end
    
    // Set block index to 0 (no shift)
    blk_sidx_i = '0;
    
    // Start computation
    input_valid_i = 1;
    repeat (calc_gemm_latency()) `WAIT_POSEDGE(clk_i, PERIOD);
    
    // Check results
    $display("Results:");
    for (int j = 0; j < 4; j++) begin  // Print first 4 outputs
      $display("  ps_o[%0d] = %0d (expected: %0d) %s", 
               j, $signed(ps_o[j]), expected,
               ($signed(ps_o[j]) == expected) ? "PASS" : "FAIL");
      $fdisplay(log_fd, "[TEST1] ps_o[%0d] = %0d (expected: %0d)", j, $signed(ps_o[j]), expected);
    end
    
    input_valid_i = 0;
    `WAIT_POSEDGE(clk_i, PERIOD);
  endtask

  // Test 2: Identity-like test with incremental values
  // ifmap = [1, 2, 3, ..., 32]
  // weight = [1, 1, 1, ...] for each column
  // Expected: ps_o[i] = sum(1..32) = 528
  task test_identity();
    automatic longint signed expected;
    
    $display("\n[TEST 2] Identity Test");
    expected = ROW_SIZE*(ROW_SIZE+1)/2;  // 1+2+...+32 = 528
    $display("Expected: Each ps_o[i] = 1+2+...+%0d = %0d", ROW_SIZE, expected);
    
    // reset
    ifmap_i = '0;
    weight_i = '0;
    input_valid_i = '0;
    ready_weight_i = '0;
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
    end
    
    // Set block index to 0 (no shift)
    blk_sidx_i = '0;
    
    // Start computation
    input_valid_i = 1;
    repeat (calc_gemm_latency()) `WAIT_POSEDGE(clk_i, PERIOD);
    
    // Check results
    $display("Results:");
    for (int j = 0; j < 4; j++) begin
      $display("  ps_o[%0d] = %0d (expected: %0d) %s", 
               j, $signed(ps_o[j]), expected,
               ($signed(ps_o[j]) == expected) ? "PASS" : "FAIL");
      $fdisplay(log_fd, "[TEST2] ps_o[%0d] = %0d (expected: %0d)", j, $signed(ps_o[j]), expected);
    end
    
    input_valid_i = 0;
    `WAIT_POSEDGE(clk_i, PERIOD);
  endtask

  // Test 3: Block alignment test
  // Test different block indices for alignment
  task test_block_alignment();
    automatic longint signed expected;
    automatic int shift_amount;
    
    $display("\n[TEST 3] Block Alignment Test");
    
    // reset
    ifmap_i = '0;
    weight_i = '0;
    input_valid_i = '0;
    ready_weight_i = '0;
    blk_sidx_i = '0;
    
    `WAIT_POSEDGE(clk_i, PERIOD);
    
    // Load weights (all 1s)
    in_weight_sel_i = ~in_weight_sel_i;
    ready_weight_i = 1;
    for (int i = 0; i < ROW_SIZE; i++) begin
      for (int j = 0; j < COL_SIZE; j++) begin
        for (int k = 0; k < WEIGHT_LOAD_ROW_NUM; k++) begin
          weight_i[j][k] = 1;
        end
      end
      `WAIT_POSEDGE(clk_i, PERIOD);
    end
    ready_weight_i = 0;
    out_weight_sel_i = in_weight_sel_i;
    
    // Set input (all 2s for easy calculation)
    for (int i = 0; i < ROW_SIZE; i++) begin
      ifmap_i[i] = 2;
    end
    
    input_valid_i = 1;
    
    // Test different block indices
    for (int blk_idx = 0; blk_idx < 3; blk_idx++) begin
      $display("  Testing block_idx = %0d (shift = %0d)", blk_idx, BLOCK_SIZE * blk_idx);
      shift_amount = BLOCK_SIZE * blk_idx;
      expected = (2 * 1 * ROW_SIZE) << shift_amount;  // (ifmap * weight * ROW_SIZE) << shift
      expected = expected & ((longint'(1) <<< OUT_DW) - 1);  // Truncate to OUT_DW
      
      blk_sidx_i = {ROW_SIZE{BLK_BITW'(blk_idx)}};
      repeat (calc_gemm_latency()) `WAIT_POSEDGE(clk_i, PERIOD);
      
      $display("    ps_o[0] = %0d (expected: %0d) %s", 
               $signed(ps_o[0]), expected,
               ($signed(ps_o[0]) == expected) ? "PASS" : "FAIL");
      $fdisplay(log_fd, "[TEST3] blk_idx=%0d, ps_o[0] = %0d (expected: %0d)", 
                blk_idx, $signed(ps_o[0]), expected);
    end
    
    input_valid_i = 0;
    `WAIT_POSEDGE(clk_i, PERIOD);
  endtask

  // Test 4: Different weight values per column
  // weight[j] = j+1, ifmap = all 1s
  // Expected: ps_o[j] = (j+1) * ROW_SIZE, but with 4-bit signed weight overflow
  task test_different_weights();
    $display("\n[TEST 4] Different Weights Test");
    $display("Expected: ps_o[j] = (j+1) * ROW_SIZE, but watch for 4-bit signed overflow");
    $display("Note: 4-bit signed range is -8 to +7, so weight=8 wraps to -8");
    
    // reset
    ifmap_i = '0;
    weight_i = '0;
    input_valid_i = '0;
    ready_weight_i = '0;
    blk_sidx_i = '0;
    
    `WAIT_POSEDGE(clk_i, PERIOD);
    
    // Load weights (weight[j] = j+1)
    $display("Loading weights (weight[j] = j+1)...");
    in_weight_sel_i = ~in_weight_sel_i;
    ready_weight_i = 1;
    for (int i = 0; i < ROW_SIZE; i++) begin
      for (int j = 0; j < COL_SIZE; j++) begin
        for (int k = 0; k < WEIGHT_LOAD_ROW_NUM; k++) begin
          weight_i[j][k] = (j + 1);
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
    end
    
    // Set block index to 0
    blk_sidx_i = '0;
    
    // Start computation
    input_valid_i = 1;
    repeat (calc_gemm_latency()) `WAIT_POSEDGE(clk_i, PERIOD);
    
    // Check results
    $display("Results:");
    for (int j = 0; j < 8; j++) begin  // Print first 8 outputs
      automatic logic signed [WEIGHT_DW-1:0] w_signed;
      automatic longint signed expected;
      
      // Convert weight to 4-bit signed (this will cause overflow for j >= 7)
      w_signed = $signed((j + 1) & ((1 << WEIGHT_DW) - 1));
      // Expected = weight * ROW_SIZE (with signed weight)
      expected = $signed(w_signed) * ROW_SIZE;
      
      $display("  ps_o[%0d] = %0d (weight=%0d, expected: %0d) %s", 
               j, $signed(ps_o[j]), $signed(w_signed), expected, 
               ($signed(ps_o[j]) == expected) ? "PASS" : "FAIL");
      $fdisplay(log_fd, "[TEST4] ps_o[%0d] = %0d (expected: %0d)", j, $signed(ps_o[j]), expected);
    end
    
    input_valid_i = 0;
    `WAIT_POSEDGE(clk_i, PERIOD);
  endtask

  // Test 5: Random test with single input vector
  task test_random_matrix();
    localparam int NUM_INPUT_VECTORS = 1; // Process 1 input vector (accumulation only ROW_SIZE)
    automatic logic [`MAX_INPUT_CYCLES-1:0][ROW_SIZE-1:0][IN_DW-1:0] ifmap_history;
    automatic logic [COL_SIZE-1:0][ROW_SIZE-1:0][WEIGHT_DW-1:0] weight_ref;
    automatic logic [`MAX_INPUT_CYCLES-1:0][ROW_SIZE-1:0][BLK_BITW-1:0] blk_idx_history;
    automatic logic [COL_SIZE-1:0][OUT_DW-1:0] expected_output;
    automatic int seed = 12345;
    automatic int pass_count;
    automatic int fail_count;
    
    $display("\n[TEST 5] Random Test");
    $display("Processing %0d input vector (accumulation over ROW_SIZE)", NUM_INPUT_VECTORS);
    
    // reset
    ifmap_i = '0;
    weight_i = '0;
    input_valid_i = '0;
    ready_weight_i = '0;
    blk_sidx_i = '0;
    
    `WAIT_POSEDGE(clk_i, PERIOD);
    
    // Generate random weights (constrained to 4-bit signed range: -8 to +7)
    $display("Loading random weights...");
    in_weight_sel_i = ~in_weight_sel_i;
    ready_weight_i = 1;
    for (int i = 0; i < ROW_SIZE; i++) begin
      for (int j = 0; j < COL_SIZE; j++) begin
        for (int k = 0; k < WEIGHT_LOAD_ROW_NUM; k++) begin
          automatic int w_val = $urandom_range(0, 15) & ((1 << WEIGHT_DW) - 1); // 0-15, masked to 4 bits
          weight_i[j][k] = w_val;
          // Weight loading uses shift register: cycle i loads to mem[0], shifts down
          // After all cycles: mem[ROW_SIZE-1-i] contains cycle i's weight
          // So weight_ref[col][ROW_SIZE-1-i] should store cycle i's weight
          weight_ref[j][ROW_SIZE-1-i-k] = $signed(w_val[WEIGHT_DW-1:0]); // Store for reference
        end
      end
      `WAIT_POSEDGE(clk_i, PERIOD);
    end
    ready_weight_i = 0;
    out_weight_sel_i = in_weight_sel_i;
    
    // Debug: print first column weights
    $display("Debug: First column weights (weight_ref[0][row]):");
    for (int row = 0; row < ROW_SIZE; row++) begin
      $display("  weight_ref[0][%0d] = %0d", row, $signed(weight_ref[0][row]));
    end
    
    // Generate and process random input vectors
    $display("Processing random input vectors...");
    input_valid_i = 1;
    
    for (int vec_idx = 0; vec_idx < NUM_INPUT_VECTORS; vec_idx++) begin
      $display("  Input vector %0d:", vec_idx);
      // Generate random input vector
      for (int i = 0; i < ROW_SIZE; i++) begin
        automatic int ifmap_val = $urandom_range(0, 255); // Small values for easy verification
        automatic int blk_idx = $urandom_range(0, 2); // Block indices 0-2
        
        ifmap_i[i] = ifmap_val;
        blk_sidx_i[i] = blk_idx;
        
        // Store for reference calculation
        ifmap_history[vec_idx][i] = ifmap_val;
        blk_idx_history[vec_idx][i] = blk_idx;
        
        $display("    ifmap[%0d]=%0d, blk_idx=%0d", i, ifmap_val, blk_idx);
      end
      
      `WAIT_POSEDGE(clk_i, PERIOD);
    end
    
    // Wait for pipeline to complete
    repeat (calc_gemm_latency()) `WAIT_POSEDGE(clk_i, PERIOD);
    
    // Calculate expected output using reference function
    calc_gemm_reference(ifmap_history, weight_ref, blk_idx_history, NUM_INPUT_VECTORS, expected_output);
    
    // Debug: Manual calculation for column 0
    $display("Debug: Manual calculation for column 0:");
    begin
      automatic longint signed manual_sum = 0;
      automatic longint signed truncated;
      for (int row = 0; row < ROW_SIZE; row++) begin
        automatic longint signed product = $signed(ifmap_history[0][row]) * $signed(weight_ref[0][row]);
        automatic longint signed shifted = product <<< blk_idx_history[0][row];
        manual_sum += shifted;
        $display("  row%0d: %0d * %0d << %0d = %0d, sum=%0d", 
                 row, $signed(ifmap_history[0][row]), $signed(weight_ref[0][row]), 
                 blk_idx_history[0][row], shifted, manual_sum);
      end
      truncated = manual_sum & ((longint'(1) <<< OUT_DW) - 1);
      $display("  Final sum=%0d, truncated=%0d, expected_output[0]=%0d", 
               manual_sum, truncated, $signed(expected_output[0]));
    end
    
    // Check results
    $display("Results:");
    pass_count = 0;
    fail_count = 0;
    
    for (int j = 0; j < COL_SIZE; j++) begin
      automatic logic match = ($signed(ps_o[j]) == $signed(expected_output[j]));
      
      $display("  ps_o[%0d] = %0d (expected: %0d) %s", 
               j, $signed(ps_o[j]), $signed(expected_output[j]),
               match ? "PASS" : "FAIL");
      
      if (match) pass_count++;
      else fail_count++;
      
      $fdisplay(log_fd, "[TEST5] ps_o[%0d] = %0d (expected: %0d) %s", 
                j, $signed(ps_o[j]), $signed(expected_output[j]),
                match ? "PASS" : "FAIL");
    end
    
    $display("Summary: %0d PASS, %0d FAIL out of %0d outputs", pass_count, fail_count, COL_SIZE);
    
    input_valid_i = 0;
    `WAIT_POSEDGE(clk_i, PERIOD);
  endtask

  // Test 6: Column direction weight loading
  task test_column_direction_loading();
    logic [COL_SIZE-1:0][ROW_SIZE-1:0][WEIGHT_DW-1:0] weight_ref;
    logic [COL_SIZE-1:0][OUT_DW-1:0] expected_output;
    int pass_count, fail_count;
    
    $display("\n[TEST 6] Column Direction Weight Loading Test");
    $display("Testing weight_load_dir_i=1 (column direction)");
    $display("Expected: Each ps_o[i] = ROW_SIZE * 1 * 1 = %0d", ROW_SIZE);
    
    // Clear all signals and wait for pipeline to flush
    ifmap_i = '0;
    weight_i = '0;
    input_valid_i = '0;
    ready_weight_i = '0;
    blk_sidx_i = '0;
    weight_load_dir_i = 0;
    
    // Wait for pipeline to flush completely
    repeat (20) `WAIT_POSEDGE(clk_i, PERIOD);
    
    // Set column direction BEFORE starting weight load
    weight_load_dir_i = 1;  // Column direction!
    
    // Wait a few cycles for direction change to propagate
    repeat (5) `WAIT_POSEDGE(clk_i, PERIOD);
    
    // Load weights in column direction (all 1s)
    $display("Loading weights in column direction (all 1s)...");
    in_weight_sel_i = ~in_weight_sel_i;
    ready_weight_i = 1;
    
    // Column direction loading:
    // - Similar to row direction, but loads to first WEIGHT_LOAD_COL columns,
    //   then shifts right to other columns
    // - Each cycle loads WEIGHT_LOAD_ROW rows (which is 1 in our case)
    // - Need ROW_SIZE cycles to load all rows
    // - After loading to column 0, it shifts right to columns 1, 2, 3
    // - Then we load to column 1 (shifts to 2, 3, 4), etc.
    
    // Total cycles needed: ROW_SIZE (for all rows) * COL_SIZE (for all columns)
    // But with shift register, we only need ROW_SIZE + COL_SIZE - 1 cycles
    // However, for simplicity, let's do ROW_SIZE * COL_SIZE cycles
    
    // Actually, re-thinking: column direction means we load column by column
    // Each column needs ROW_SIZE cycles to load all its rows
    // So total: COL_SIZE * ROW_SIZE cycles
    
    for (int col_cycle = 0; col_cycle < COL_SIZE; col_cycle++) begin
      for (int row_cycle = 0; row_cycle < ROW_SIZE; row_cycle++) begin
        for (int j = 0; j < COL_SIZE; j++) begin
          for (int k = 0; k < WEIGHT_LOAD_ROW_NUM; k++) begin
            weight_i[j][k] = 1;
          end
        end
        `WAIT_POSEDGE(clk_i, PERIOD);
      end
    end
    
    // weight_ref: all 1s
    for (int col = 0; col < COL_SIZE; col++) begin
      for (int row = 0; row < ROW_SIZE; row++) begin
        weight_ref[col][row] = 1;
      end
    end
    ready_weight_i = 0;
    out_weight_sel_i = in_weight_sel_i;
    
    $display("Weight loading complete. Total cycles: %0d", COL_SIZE * ROW_SIZE);
    $display("Waiting for weights to propagate...");
    
    // Wait extra cycles for weight shifting to complete
    repeat (COL_SIZE + ROW_SIZE) `WAIT_POSEDGE(clk_i, PERIOD);
    
    // Set input (all 1s)
    $display("Setting inputs (all 1s)...");
    for (int i = 0; i < ROW_SIZE; i++) begin
      ifmap_i[i] = 1;
      blk_sidx_i[i] = 0;  // No shift
    end
    
    input_valid_i = 1;
    repeat (calc_gemm_latency()) `WAIT_POSEDGE(clk_i, PERIOD);
    
    // Calculate expected output
    for (int j = 0; j < COL_SIZE; j++) begin
      automatic longint signed sum = 0;
      for (int i = 0; i < ROW_SIZE; i++) begin
        sum += $signed(ifmap_i[i]) * $signed(weight_ref[j][i]);
      end
      expected_output[j] = sum & ((longint'(1) <<< OUT_DW) - 1);
    end
    
    // Check results
    $display("Results:");
    pass_count = 0;
    fail_count = 0;
    
    for (int j = 0; j < COL_SIZE; j++) begin
      automatic logic match = ($signed(ps_o[j]) == $signed(expected_output[j]));
      
      $display("  ps_o[%0d] = %0d (expected: %0d) %s", 
               j, $signed(ps_o[j]), $signed(expected_output[j]),
               match ? "PASS" : "FAIL");
      
      if (match) pass_count++;
      else fail_count++;
      
      $fdisplay(log_fd, "[TEST6] ps_o[%0d] = %0d (expected: %0d) %s", 
                j, $signed(ps_o[j]), $signed(expected_output[j]),
                match ? "PASS" : "FAIL");
    end
    
    $display("Summary: %0d PASS, %0d FAIL out of %0d outputs", pass_count, fail_count, COL_SIZE);
    
    input_valid_i = 0;
    
    // Reset to row direction for subsequent tests
    weight_load_dir_i = 0;
    input_valid_i = 0;
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
    output logic [COL_SIZE-1:0][OUT_DW-1:0] expected_output
  );
    automatic longint signed temp_result[COL_SIZE];
    
    // Initialize outputs
    for (int col = 0; col < COL_SIZE; col++) begin
      temp_result[col] = 0;
    end
    
    // Process each column independently
    for (int col = 0; col < COL_SIZE; col++) begin
      // Accumulate over all input cycles
      for (int k = 0; k < num_cycles; k++) begin
        // MAC operation for each element in the row
        for (int row = 0; row < ROW_SIZE; row++) begin
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
      end
      
      // Truncate to OUT_DW bits
      expected_output[col] = temp_result[col] & ((longint'(1) <<< OUT_DW) - 1);
    end
  endtask
  
  // Simplified reference calculation for single input vector
  // This is a helper for simple test cases
  task calc_single_vector_reference(
    input logic [ROW_SIZE-1:0][IN_DW-1:0] ifmap_vec,
    input logic [COL_SIZE-1:0][ROW_SIZE-1:0][WEIGHT_DW-1:0] weight_mat,
    input logic [ROW_SIZE-1:0][BLK_BITW-1:0] blk_idx_vec,
    output logic [COL_SIZE-1:0][OUT_DW-1:0] expected_output
  );
    automatic logic [`MAX_INPUT_CYCLES-1:0][ROW_SIZE-1:0][IN_DW-1:0] ifmap_history;
    automatic logic [`MAX_INPUT_CYCLES-1:0][ROW_SIZE-1:0][BLK_BITW-1:0] blk_idx_history;
    
    // Copy single vector to history
    ifmap_history[0] = ifmap_vec;
    blk_idx_history[0] = blk_idx_vec;
    
    // Call full reference function with num_cycles=1
    calc_gemm_reference(ifmap_history, weight_mat, blk_idx_history, 1, expected_output);
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
