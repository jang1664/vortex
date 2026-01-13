`timescale 1ns / 1ps

`include "VX_define.vh"

module tb_VX_prealigner import VX_gpu_pkg::*;();
  parameter string tb_name = "tb_VX_prealigner";

  parameter PERIOD = 10.0;
  parameter FREQ = 100;
  parameter string OBJ = "func";
  parameter string FILE_POSTFIX = "func";

  parameter int unsigned NUM_UNIT = 4;

  localparam int HIDDEN_WIDTH   = `HIDDEN_WIDTH;
  localparam int SIGN_WIDTH     = `IFP_SIGN_WIDTH;
  localparam int EXP_WIDTH      = `IFP_EXP_WIDTH;
  localparam int MANTISSA_WIDTH = `IFP_MAN_WIDTH;
  localparam int ACT_WIDTH      = `IFP_WIDTH;
  localparam int EXTRA_WIDTH    = `EXTRA_BIT_WIDTH;
  localparam int BLOCK_SIZE     = `BLOCK_SIZE;
  localparam int ALIGNED_WIDTH  = `SEL_BLOCK_WIDTH;
  localparam int BLOCK_NUM      = `BLOCK_NUM;
  localparam int SEL_BLOCK_NUM  = `SEL_BLOCK_NUM;
  localparam int BLK_IDX_NUM    = `BLK_IDX_NUM;
  localparam int BLK_BITW       = `BLOCK_IDX_WIDTH;

  logic clk_i;
  logic resetn_i;
  logic [NUM_UNIT-1:0][ACT_WIDTH-1:0] fp_data_i;
  logic [NUM_UNIT-1:0][ALIGNED_WIDTH-1:0] int_data_o;
  logic [NUM_UNIT-1:0][BLK_BITW-1:0] blk_idx_o;
  logic [EXP_WIDTH-1:0] max_exp_o;
  logic valid_i;
  logic ready_o;
  logic valid_o;
  logic ready_i;

  integer rpt_fd;
  integer log_fd;

  VX_prealigner #(
      .NUM_UNIT      (NUM_UNIT)
  ) u_prealigner (
      .clk_i     (clk_i),
      .resetn_i  (resetn_i),
      .fp_data_i (fp_data_i),
      .int_data_o(int_data_o),
      .blk_idx_o (blk_idx_o),
      .max_exp_o (max_exp_o),
      .valid_i   (valid_i),
      .ready_o   (ready_o),
      .valid_o   (valid_o),
      .ready_i   (ready_i)
  );

  // Output FIFO for capturing results
  localparam int OUTPUT_DATA_WIDTH = NUM_UNIT*ALIGNED_WIDTH + NUM_UNIT*BLK_BITW + EXP_WIDTH;
  
  VX_stream_intf #(
    .DATA_WIDTH(OUTPUT_DATA_WIDTH)
  ) output_in (
    .clk(clk_i)
  );
  VX_stream_intf #(
    .DATA_WIDTH(OUTPUT_DATA_WIDTH)
  ) output_out (
    .clk(clk_i)
  );
  virtual VX_stream_slave_always_ready_dbg_if #(
    .DATA_WIDTH(OUTPUT_DATA_WIDTH)
  ) fifo_dbg_vif;

  logic fifo_clear;
  
  VX_stream_slave_always_ready #(
    .DATA_WIDTH(OUTPUT_DATA_WIDTH)
  ) u_output_fifo (
    .clk_i(clk_i),
    .rst_ni(resetn_i),
    .clear_i(fifo_clear),
    .flags_o(/*unused*/),
    .push_i(output_in),
    .pop_o(output_out)
  );
  
  assign output_out.ready = 1'b0;
  assign output_in.data = {max_exp_o, blk_idx_o, int_data_o};
  assign output_in.strb = '1;
  assign output_in.valid = valid_o;
  assign ready_i = output_in.ready;
  
  initial begin
    fifo_dbg_vif = u_output_fifo.dbg_if;
  end

  string fsdb_file_path;
  string fst_file_path;
  string rpt_file_path;
  string log_file_path;
  string name;

  initial clk_i = 0;
  always #(PERIOD / 2) clk_i = ~clk_i;

  // Timeout watchdog
  initial begin
    #(PERIOD * 10000); // 10000 cycles timeout
    $display("\n\n***** ERROR: SIMULATION TIMEOUT *****");
    $display("Simulation stuck - check handshake signals");
    $display("Current time: %0t", $time);
    $finish;
  end

  // Monitor handshake signals
  always @(posedge clk_i) begin
    if (valid_i && !ready_o) begin
      $display("@%0t: STALL at INPUT - valid_i=1 but ready_o=0", $time);
    end
    if (valid_o && !ready_i) begin
      $display("@%0t: STALL at OUTPUT - valid_o=1 but ready_i=0", $time);
    end
  end

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
    $dumpvars(0, tb_VX_prealigner);
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

  /*
    aligned_man_full_width = 30
    aligned_man_vali_width = 11

    ----- block size = 2 -----
    block_num = 15
    sel_block_num = 6
    sel_block_width = 12

    shift0 blocks : 14, 13, 12, 11, 10, 9
    shift1 blocks : 14, 13, 12, 11, 10, 9
    shift2 blocks : 13, 12, 11, 10, 9, 8
    shift3 blocks : 13, 12, 11, 10, 9, 8

    shift_man0 : 101010101010000000000000000000
    shift_man1 : 010101010101000000000000000000
    shift_man2 : 001010101010100000000000000000
    shift_man3 : 000101010101010000000000000000

    ----- block size = 3 -----
    block_num = 10
    sel_block_num = 5
    sel_block_width = 15
    shift0 blocks : 9, 8, 7, 6, 5
    shift1 blocks : 9, 8, 7, 6, 5
    shift2 blocks : 9, 8, 7, 6, 5
    shift3 blocks : 8, 7, 6, 5, 4

    ----- block size = 4 ----
    block_num = 8
    sel_block_num = 4
    sel_block_width = 16
    shift0 blocks : 7, 6, 5, 4
    shift1 blocks : 7, 6, 5, 4
    shift2 blocks : 7, 6, 5, 4
    shift3 blocks : 7, 6, 5, 4
  */
  task test_simple();
    $display("=====================================================================");
    $display("START SIMPLE TEST"); 
    $display("=====================================================================");
    resetn_i = 1'b0;
    valid_i = 1'b0;
    fifo_clear = 1'b0;
    `WAIT_POSEDGE(clk_i, PERIOD);
    resetn_i = 1'b1;
    `WAIT_POSEDGE(clk_i, PERIOD);

    // driving input (array size = 4)
    if(NUM_UNIT != 4) begin
      $display("please set NUM_UNIT = 4 for func sim. current one is %0d", NUM_UNIT);
      $finish;
    end
    valid_i = 1'b1;
    fp_data_i[0] = {1'b0, 5'(20), 10'('b0101010101)};
    fp_data_i[1] = {1'b0, 5'(20-(`BLOCK_SIZE)), 10'('b0101010101)};
    fp_data_i[2] = {1'b0, 5'(20-(2*`BLOCK_SIZE)), 10'('b0101010101)};
    fp_data_i[3] = {1'b0, 5'(20-(3*`BLOCK_SIZE)), 10'('b0101010101)};

    // wait result
    valid_i = 1'b0;
    repeat (10) begin
      `WAIT_POSEDGE(clk_i, PERIOD);
      $display("@%0t: waiting... valid_o=%b, ready_i=%b", $time, valid_o, ready_i);
    end

    // display results
    $display("@%0t: Results ready", $time);
    $fdisplay(log_fd, "max_exp : %0d", max_exp_o);

    for (int i = 0; i < 4; i++) begin
      // $display("prealigned[%0d] = %f", i, real'(int_data_o[i]) / (2.0 ** (ALIGNED_WIDTH - 2)));
      //$display("prealigned[%0d] = %f", i, real'(int_data_o[i]));
      $fdisplay(log_fd, "data[%0d]      = %b", i, int_data_o[i]);
      $fdisplay(log_fd, "block_idx[%0d] = %d", i, blk_idx_o[i]);
    end
  endtask

  task sim_func();
    $display("=====================================================================");
    $display("=======================  START SIMULATION  ==========================");
    $display("=====================================================================");
    $display("BLOCK_SIZE    : %0d", BLOCK_SIZE);
    $display("BLOCK_NUM     : %0d", BLOCK_NUM);
    $display("SEL_BLOCK_NUM : %0d", SEL_BLOCK_NUM);
    $display("ALIGNED_WIDTH : %0d", ALIGNED_WIDTH);
    $display("EXTRA_WIDTH   : %0d", EXTRA_WIDTH);
    test_simple();
    test_basic_cases();
    test_random();
  endtask

  // Basic test cases to verify reference function
  task test_basic_cases();
    logic [NUM_UNIT-1:0][ACT_WIDTH-1:0] fp_input;
    logic [NUM_UNIT-1:0][ALIGNED_WIDTH-1:0] expected_int_data;
    logic [NUM_UNIT-1:0][BLK_BITW-1:0] expected_blk_idx;
    logic [EXP_WIDTH-1:0] expected_max_exp;
    logic [OUTPUT_DATA_WIDTH-1:0] fifo_data;
    logic [NUM_UNIT-1:0][ALIGNED_WIDTH-1:0] actual_int_data;
    logic [NUM_UNIT-1:0][BLK_BITW-1:0] actual_blk_idx;
    logic [EXP_WIDTH-1:0] actual_max_exp;
    int pass_count, fail_count;
    
    $display("=====================================================================");
    $display("START BASIC TEST CASES");
    $display("=====================================================================");
    
    pass_count = 0;
    fail_count = 0;
    
    fifo_clear = 1'b1;
    resetn_i = 1'b0;
    valid_i = 1'b0;
    `WAIT_POSEDGE(clk_i, PERIOD);
    resetn_i = 1'b1;
    `WAIT_POSEDGE(clk_i, PERIOD);
    fifo_clear = 1'b0;
    
    // Test Case 1: All same exponent (no shifting)
    $display("\n--- Test Case 1: Same exponent ---");
    fp_input[0] = {1'b0, 5'd10, 10'h155}; // +, exp=10, man=0x155
    fp_input[1] = {1'b0, 5'd10, 10'h2AA}; // +, exp=10, man=0x2AA
    fp_input[2] = {1'b1, 5'd10, 10'h1FF}; // -, exp=10, man=0x1FF
    fp_input[3] = {1'b1, 5'd10, 10'h100}; // -, exp=10, man=0x100
    
    calc_prealigner_reference(fp_input, expected_int_data, expected_blk_idx, expected_max_exp);
    
    fp_data_i = fp_input;
    valid_i = 1'b1;
    `WAIT_POSEDGE(clk_i, PERIOD);
    valid_i = 1'b0;
    
    while (fifo_dbg_vif.get_queue_size() == 0) `WAIT_POSEDGE(clk_i, PERIOD);
    fifo_data = fifo_dbg_vif.get_queue_data(0);
    fifo_clear = 1'b1;
    `WAIT_POSEDGE(clk_i, PERIOD);
    fifo_clear = 1'b0;
    
    actual_int_data = fifo_data[NUM_UNIT*ALIGNED_WIDTH-1:0];
    actual_blk_idx = fifo_data[NUM_UNIT*ALIGNED_WIDTH +: NUM_UNIT*BLK_BITW];
    actual_max_exp = fifo_data[NUM_UNIT*ALIGNED_WIDTH + NUM_UNIT*BLK_BITW +: EXP_WIDTH];
    
    if (compare_results(expected_int_data, expected_blk_idx, expected_max_exp,
                        actual_int_data, actual_blk_idx, actual_max_exp, "TC1"))
      pass_count++;
    else
      fail_count++;
    
    // Test Case 2: Different exponents
    $display("\n--- Test Case 2: Different exponents ---");
    fp_input[0] = {1'b0, 5'd15, 10'h3FF}; // +, exp=15, man=0x3FF
    fp_input[1] = {1'b0, 5'd12, 10'h200}; // +, exp=12, man=0x200
    fp_input[2] = {1'b1, 5'd10, 10'h100}; // -, exp=10, man=0x100
    fp_input[3] = {1'b0, 5'd8,  10'h0AA}; // +, exp=8,  man=0x0AA
    
    calc_prealigner_reference(fp_input, expected_int_data, expected_blk_idx, expected_max_exp);
    
    fp_data_i = fp_input;
    valid_i = 1'b1;
    `WAIT_POSEDGE(clk_i, PERIOD);
    valid_i = 1'b0;
    
    while (fifo_dbg_vif.get_queue_size() == 0) `WAIT_POSEDGE(clk_i, PERIOD);
    fifo_data = fifo_dbg_vif.get_queue_data(0);
    fifo_clear = 1'b1;
    `WAIT_POSEDGE(clk_i, PERIOD);
    fifo_clear = 1'b0;
    
    actual_int_data = fifo_data[NUM_UNIT*ALIGNED_WIDTH-1:0];
    actual_blk_idx = fifo_data[NUM_UNIT*ALIGNED_WIDTH +: NUM_UNIT*BLK_BITW];
    actual_max_exp = fifo_data[NUM_UNIT*ALIGNED_WIDTH + NUM_UNIT*BLK_BITW +: EXP_WIDTH];
    
    if (compare_results(expected_int_data, expected_blk_idx, expected_max_exp,
                        actual_int_data, actual_blk_idx, actual_max_exp, "TC2"))
      pass_count++;
    else
      fail_count++;
    
    // Test Case 3: Sign variations
    $display("\n--- Test Case 3: Sign variations ---");
    fp_input[0] = {1'b1, 5'd20, 10'h2FF}; // -, exp=20
    fp_input[1] = {1'b0, 5'd20, 10'h1AA}; // +, exp=20
    fp_input[2] = {1'b1, 5'd18, 10'h3AB}; // -, exp=18
    fp_input[3] = {1'b0, 5'd16, 10'h155}; // +, exp=16
    
    calc_prealigner_reference(fp_input, expected_int_data, expected_blk_idx, expected_max_exp);
    
    fp_data_i = fp_input;
    valid_i = 1'b1;
    `WAIT_POSEDGE(clk_i, PERIOD);
    valid_i = 1'b0;
    
    while (fifo_dbg_vif.get_queue_size() == 0) `WAIT_POSEDGE(clk_i, PERIOD);
    fifo_data = fifo_dbg_vif.get_queue_data(0);
    fifo_clear = 1'b1;
    `WAIT_POSEDGE(clk_i, PERIOD);
    fifo_clear = 1'b0;
    
    actual_int_data = fifo_data[NUM_UNIT*ALIGNED_WIDTH-1:0];
    actual_blk_idx = fifo_data[NUM_UNIT*ALIGNED_WIDTH +: NUM_UNIT*BLK_BITW];
    actual_max_exp = fifo_data[NUM_UNIT*ALIGNED_WIDTH + NUM_UNIT*BLK_BITW +: EXP_WIDTH];
    
    if (compare_results(expected_int_data, expected_blk_idx, expected_max_exp,
                        actual_int_data, actual_blk_idx, actual_max_exp, "TC3"))
      pass_count++;
    else
      fail_count++;
    
    $display("\n=====================================================================");
    $display("BASIC TEST SUMMARY: %0d PASS, %0d FAIL", pass_count, fail_count);
    $display("=====================================================================\n");
    
    if (fail_count > 0) begin
      $display("ERROR: Basic tests failed. Fix reference function before random tests.");
      $finish;
    end
  endtask

  // Helper function to compare results
  function automatic int compare_results(
    input logic [NUM_UNIT-1:0][ALIGNED_WIDTH-1:0] exp_int_data,
    input logic [NUM_UNIT-1:0][BLK_BITW-1:0] exp_blk_idx,
    input logic [EXP_WIDTH-1:0] exp_max_exp,
    input logic [NUM_UNIT-1:0][ALIGNED_WIDTH-1:0] act_int_data,
    input logic [NUM_UNIT-1:0][BLK_BITW-1:0] act_blk_idx,
    input logic [EXP_WIDTH-1:0] act_max_exp,
    input string test_name
  );
    int errors = 0;
    
    if (act_max_exp !== exp_max_exp) begin
      $display("  %s FAIL: max_exp mismatch - Expected: %0d, Got: %0d", 
               test_name, exp_max_exp, act_max_exp);
      errors++;
    end
    
    for (int i = 0; i < NUM_UNIT; i++) begin
      if (act_blk_idx[i] !== exp_blk_idx[i]) begin
        $display("  %s FAIL: blk_idx[%0d] mismatch - Expected: %0d, Got: %0d",
                 test_name, i, exp_blk_idx[i], act_blk_idx[i]);
        errors++;
      end
      
      if (act_int_data[i] !== exp_int_data[i]) begin
        $display("  %s FAIL: int_data[%0d] mismatch - Expected: %b, Got: %b",
                 test_name, i, exp_int_data[i], act_int_data[i]);
        errors++;
      end
    end
    
    if (errors == 0) begin
      $display("  %s PASS", test_name);
      return 1;
    end else begin
      return 0;
    end
  endfunction

  // Reference calculation for prealigner operation
  // Computes: aligned integer values and block indices from floating-point inputs
  // Accurately matches HW implementation
  task calc_prealigner_reference(
    input logic [NUM_UNIT-1:0][ACT_WIDTH-1:0] fp_input,
    output logic [NUM_UNIT-1:0][ALIGNED_WIDTH-1:0] expected_int_data,
    output logic [NUM_UNIT-1:0][BLK_BITW-1:0] expected_blk_idx,
    output logic [EXP_WIDTH-1:0] expected_max_exp
  );
    logic [NUM_UNIT-1:0][EXP_WIDTH-1:0] exponents;
    logic [NUM_UNIT-1:0][MANTISSA_WIDTH-1:0] mantissas;
    logic [NUM_UNIT-1:0][SIGN_WIDTH-1:0] signs;
    logic [EXP_WIDTH-1:0] max_exp;
    
    // Stage 1: Extract FP components and find max exponent
    for (int i = 0; i < NUM_UNIT; i++) begin
      signs[i] = fp_input[i][ACT_WIDTH-1];
      exponents[i] = fp_input[i][ACT_WIDTH-2:MANTISSA_WIDTH];
      mantissas[i] = fp_input[i][MANTISSA_WIDTH-1:0];
    end
    
    // Find maximum exponent
    max_exp = exponents[0];
    for (int i = 1; i < NUM_UNIT; i++) begin
      if (exponents[i] > max_exp) begin
        max_exp = exponents[i];
      end
    end
    expected_max_exp = max_exp;
    
    // Stage 2: Align mantissas and calculate block indices
    for (int i = 0; i < NUM_UNIT; i++) begin
      automatic int shift_amount;
      automatic logic [MANTISSA_WIDTH:0] hidden_man;
      automatic logic [MANTISSA_WIDTH+EXTRA_WIDTH:0] shift_man;
      automatic logic [BLK_IDX_NUM-1:0] is_right_of_first_valid_block;
      automatic int enc;
      automatic int no_exist_one;
      automatic int lsb_blk_idx;
      automatic logic [SEL_BLOCK_NUM*BLOCK_SIZE-1:0] sel_portion;
      automatic logic [29:0] shift_man_padded;
      
      // Create hidden mantissa (add implicit 1 for normalized, 0 for denormalized)
      hidden_man = (|exponents[i]) ? {1'b1, mantissas[i]} : {1'b0, mantissas[i]};
      
      // Calculate shift amount
      shift_amount = max_exp - exponents[i];
      
      // Shift mantissa right (add EXTRA_WIDTH zeros to LSB first)
      shift_man = {hidden_man, {EXTRA_WIDTH{1'b0}}} >> shift_amount;
      
      // Calculate block index using same logic as HW
      // Build is_right_of_first_valid_block vector
      for (int idx = 0; idx < BLK_IDX_NUM; idx++) begin
        is_right_of_first_valid_block[BLK_IDX_NUM-idx-1] = (shift_amount < ((idx+1) * BLOCK_SIZE));
      end
      
      // Find leading zero count (first 1 from MSB)
      enc = 0;
      no_exist_one = 1;
      for (int idx = BLK_IDX_NUM-1; idx >= 0; idx--) begin
        if (is_right_of_first_valid_block[idx]) begin
          enc = BLK_IDX_NUM - 1 - idx;
          no_exist_one = 0;
          break;
        end
      end
      
      // Calculate lsb_blk_idx
      lsb_blk_idx = no_exist_one ? 0 : (BLOCK_NUM - 1) - enc - (SEL_BLOCK_NUM - 1);
      expected_blk_idx[i] = lsb_blk_idx;
      
      // Stage 3: Extract selected portion and apply sign
      // Extract SEL_BLOCK_NUM blocks starting from lsb_blk_idx
      // HW uses: {ALIGNED_MAN_PADDED_FULL_WIDTH'(shift_man)}[BLOCK_SIZE*lsb_blk_idx +: SEL_BITW]
      // Since ALIGNED_MAN_PADDED_FULL_WIDTH = 30 for BLOCK_SIZE=1, we pad shift_man to 30 bits
      shift_man_padded = 30'(shift_man);
      
      // Select portion: SEL_BITW = SEL_BLOCK_NUM * BLOCK_SIZE
      sel_portion = shift_man_padded[BLOCK_SIZE*lsb_blk_idx +: SEL_BLOCK_NUM*BLOCK_SIZE];
      
      // Add sign bit and apply 2's complement if negative
      // int_data = (~sign) ? {1'b0, sel_portion} : ~{1'b0, sel_portion} + 1
      if (!signs[i]) begin
        expected_int_data[i] = {1'b0, sel_portion};
      end else begin
        expected_int_data[i] = ~{1'b0, sel_portion} + 1'b1;
      end
    end
  endtask

  // Random test for prealigner
  task test_random();
    localparam int NUM_TESTS = 100;
    logic [NUM_UNIT-1:0][ACT_WIDTH-1:0] fp_input[NUM_TESTS];
    logic [NUM_UNIT-1:0][ALIGNED_WIDTH-1:0] expected_int_data[NUM_TESTS];
    logic [NUM_UNIT-1:0][BLK_BITW-1:0] expected_blk_idx[NUM_TESTS];
    logic [EXP_WIDTH-1:0] expected_max_exp[NUM_TESTS];
    logic [NUM_UNIT-1:0][ALIGNED_WIDTH-1:0] actual_int_data;
    logic [NUM_UNIT-1:0][BLK_BITW-1:0] actual_blk_idx;
    logic [EXP_WIDTH-1:0] actual_max_exp;
    logic [OUTPUT_DATA_WIDTH-1:0] fifo_data;
    int error_count;
    int cnt;
    
    $display("=====================================================================");
    $display("START RANDOM TEST");
    $display("=====================================================================");
    
    error_count = 0;
    resetn_i = 1'b0;
    valid_i = 1'b0;
    `WAIT_POSEDGE(clk_i, PERIOD);
    resetn_i = 1'b1;
    `WAIT_POSEDGE(clk_i, PERIOD);
    
    // Clear FIFO once at the beginning
    fifo_clear = 1'b1;
    `WAIT_POSEDGE(clk_i, PERIOD);
    fifo_clear = 1'b0;
    `WAIT_POSEDGE(clk_i, PERIOD);
    
    // Phase 1: Generate all inputs and send to DUT
    $display("Phase 1: Generating and sending %0d test inputs...", NUM_TESTS);
    
    // Pre-generate all test inputs
    for (int test_idx = 0; test_idx < NUM_TESTS; test_idx++) begin
      // Generate random floating-point inputs
      for (int i = 0; i < NUM_UNIT; i++) begin
        // Random sign, exponent, and mantissa
        fp_input[test_idx][i][ACT_WIDTH-1] = $urandom_range(0, 1); // sign
        fp_input[test_idx][i][ACT_WIDTH-2:MANTISSA_WIDTH] = $urandom_range(1, (1 << EXP_WIDTH) - 2); // exponent (avoid 0 and max)
        fp_input[test_idx][i][MANTISSA_WIDTH-1:0] = $urandom(); // mantissa
      end
      
      // Calculate expected output using reference function
      calc_prealigner_reference(fp_input[test_idx], expected_int_data[test_idx], expected_blk_idx[test_idx], expected_max_exp[test_idx]);
    end
    
    // Send inputs with randomized valid timing
    cnt = 0;
    while (cnt < NUM_TESTS) begin
      // Randomly assert valid_i
      if ($urandom_range(0, 1) == 1) begin
        valid_i = 1'b1;
        fp_data_i = fp_input[cnt];
        
        if (cnt % 10 == 0) begin
          $display("Sent %0d/%0d test inputs...", cnt, NUM_TESTS);
        end
        cnt = cnt + 1;
      end else begin
        valid_i = 1'b0;
      end
      `WAIT_POSEDGE(clk_i, PERIOD);
    end
    valid_i = 1'b0;
    
    // Wait for all outputs to be in FIFO
    $display("Waiting for all outputs to be processed...");
    while (fifo_dbg_vif.get_queue_size() < NUM_TESTS) begin
      `WAIT_POSEDGE(clk_i, PERIOD);
    end
    $display("All %0d outputs received in FIFO (size=%0d)", NUM_TESTS, fifo_dbg_vif.get_queue_size());
    
    // Phase 2: Check all results from FIFO
    $display("\nPhase 2: Verifying all %0d results...", NUM_TESTS);
    for (int test_idx = 0; test_idx < NUM_TESTS; test_idx++) begin
      // Read from FIFO
      fifo_data = fifo_dbg_vif.get_queue_data(test_idx);
      
      // Unpack FIFO data
      actual_int_data = fifo_data[NUM_UNIT*ALIGNED_WIDTH-1:0];
      actual_blk_idx = fifo_data[NUM_UNIT*ALIGNED_WIDTH +: NUM_UNIT*BLK_BITW];
      actual_max_exp = fifo_data[NUM_UNIT*ALIGNED_WIDTH + NUM_UNIT*BLK_BITW +: EXP_WIDTH];
      
      // Compare results
      if (actual_max_exp !== expected_max_exp[test_idx]) begin
        $fdisplay(log_fd, "Test %0d FAILED: max_exp mismatch", test_idx);
        $fdisplay(log_fd, "  Expected: %0d, Got: %0d", expected_max_exp[test_idx], actual_max_exp);
        error_count++;
      end
      
      for (int i = 0; i < NUM_UNIT; i++) begin
        if (actual_blk_idx[i] !== expected_blk_idx[test_idx][i]) begin
          $fdisplay(log_fd, "Test %0d FAILED: blk_idx[%0d] mismatch", test_idx, i);
          $fdisplay(log_fd, "  Expected: %0d, Got: %0d", expected_blk_idx[test_idx][i], actual_blk_idx[i]);
          error_count++;
        end
        
        if (actual_int_data[i] !== expected_int_data[test_idx][i]) begin
          $fdisplay(log_fd, "Test %0d FAILED: int_data[%0d] mismatch", test_idx, i);
          $fdisplay(log_fd, "  Expected: %b, Got: %b", expected_int_data[test_idx][i], actual_int_data[i]);
          error_count++;
        end
      end
      
      if (test_idx % 10 == 0) begin
        $display("Verified %0d/%0d tests...", test_idx, NUM_TESTS);
      end
    end
    
    if (error_count == 0) begin
      $display("=====================================================================");
      $display("RANDOM TEST PASSED: All %0d tests passed!", NUM_TESTS);
      $display("=====================================================================");
    end else begin
      $display("=====================================================================");
      $display("RANDOM TEST FAILED: %0d errors found", error_count);
      $display("=====================================================================");
    end
    
    // Clear FIFO at end
    fifo_clear = 1'b1;
    `WAIT_POSEDGE(clk_i, PERIOD);
    fifo_clear = 1'b0;
  endtask

  task sim_power();
    localparam CYCLE = 128;

    resetn_i = 1'b0;
    `WAIT_POSEDGE(clk_i, PERIOD);
    resetn_i = 1'b1;

    for (int i = 0; i < CYCLE; i++) begin
      fp_data_i = $urandom();
      `WAIT_POSEDGE(clk_i, PERIOD);
    end
  endtask

endmodule
