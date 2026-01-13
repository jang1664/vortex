`timescale 1ns / 1ps

`include "VX_define.vh"

import cf_math_pkg::*;

module tb_VX_fp16_mul();
  parameter string tb_name = "tb_VX_fp16_mul";
  parameter PERIOD = 10.0;
  
  logic clk;
  logic reset;
  
  // Input A
  logic        a_valid;
  logic        a_ready;
  logic [15:0] a_data;
  
  // Input B
  logic        b_valid;
  logic        b_ready;
  logic [15:0] b_data;
  
  // Output
  logic        result_valid;
  logic        result_ready;
  logic [15:0] result_data;
  
  // DUT instantiation
  VX_fp16_mul #(
    .LATENCY(2),
    .OUT_BUF(0)
  ) dut (
    .clk          (clk),
    .reset        (reset),
    .a_valid      (a_valid),
    .a_ready      (a_ready),
    .a_data       (a_data),
    .b_valid      (b_valid),
    .b_ready      (b_ready),
    .b_data       (b_data),
    .result_valid (result_valid),
    .result_ready (result_ready),
    .result_data  (result_data)
  );
  
  // Clock generation
  initial begin
    clk = 0;
    forever #(PERIOD/2) clk = ~clk;
  end
  
  // Timeout watchdog
  initial begin
    #100000;
    $display("TIMEOUT: Test took too long");
    $finish;
  end
  
  // Monitor VX_fp16_mul output for debugging
  // always @(posedge clk) begin
  //   if (result_valid && result_ready) begin
  //     $display("DEBUG: VX_fp16_mul output = 0x%04h", result_data);
  //   end
  // end
  
  // Output FIFO for capturing results
  localparam int OUTPUT_DATA_WIDTH = 16;
  
  VX_stream_intf #(
    .DATA_WIDTH(OUTPUT_DATA_WIDTH)
  ) output_in (
    .clk(clk)
  );
  VX_stream_intf #(
    .DATA_WIDTH(OUTPUT_DATA_WIDTH)
  ) output_out (
    .clk(clk)
  );
  virtual VX_stream_slave_always_ready_dbg_if #(
    .DATA_WIDTH(OUTPUT_DATA_WIDTH)
  ) fifo_dbg_vif;
  
  logic fifo_clear;
  
  VX_stream_slave_always_ready #(
    .DATA_WIDTH(OUTPUT_DATA_WIDTH)
  ) u_output_fifo (
    .clk_i   (clk),
    .rst_ni  (~reset),
    .clear_i (fifo_clear),
    .flags_o (/*unused*/),
    .push_i  (output_in),
    .pop_o   (output_out)
  );
  
assign output_out.ready = 1'b1;  // Must be 1 to allow FIFO to pop data
assign output_in.data   = result_data;
assign output_in.strb   = '1;
assign output_in.valid  = result_valid;
assign result_ready     = output_in.ready;

initial begin
  fifo_dbg_vif = u_output_fifo.dbg_if;
end

// Test variables
int error_count = 0;
int test_count = 0;

// FP16 to real conversion using cf_math_pkg
function automatic real fp16_to_float(input [15:0] fp16);
  return fp16_bit_to_fp16_val(fp16);
endfunction

// Real to FP16 conversion using cf_math_pkg
function automatic [15:0] float_to_fp16(input real value);
  return fp32_val_to_fp16_bit(value);
endfunction
  
  // Test task with randomized valid timing
  task automatic test_multiply(input real a, input real b);
    reg [15:0] a_fp16;
    reg [15:0] b_fp16;
    real a_converted;
    real b_converted;
    real expected;
    reg [15:0] expected_fp16;
    int a_wait, b_wait;
    reg [15:0] result_fp16;
    real result;
    real expected_val;
    real abs_error;
    real rel_error;
    
    a_fp16 = float_to_fp16(a);
    b_fp16 = float_to_fp16(b);
    a_converted = fp16_to_float(a_fp16);
    b_converted = fp16_to_float(b_fp16);
    expected = a_converted * b_converted;
    expected_fp16 = float_to_fp16(expected);
    
    // Randomize when each input becomes valid
    a_wait = $urandom_range(0, 5);
    b_wait = $urandom_range(0, 5);
    
    fork
      // Input A with random delay
      begin
        a_valid = 0;
        repeat(a_wait) @(posedge clk);
        a_data = a_fp16;
        a_valid = 1;
        while (!a_ready) @(posedge clk);
        @(posedge clk);
        a_valid = 0;
      end
      
      // Input B with random delay
      begin
        b_valid = 0;
        repeat(b_wait) @(posedge clk);
        b_data = b_fp16;
        b_valid = 1;
        while (!b_ready) @(posedge clk);
        @(posedge clk);
        b_valid = 0;
      end
    join
    
    // Wait for result
    while (fifo_dbg_vif.get_queue_size() == 0) @(posedge clk);
    
    result_fp16 = fifo_dbg_vif.get_queue_data(0);
    @(posedge clk);  // Allow one cycle for FIFO to pop the data
    
    result = fp16_to_float(result_fp16);
    expected_val = fp16_to_float(expected_fp16);
    abs_error = (result > expected_val) ? (result - expected_val) : (expected_val - result);
    rel_error = (expected_val != 0.0) ? abs_error / ((expected_val > 0) ? expected_val : -expected_val) : abs_error;
    
    test_count++;
    
    if (rel_error > 1e-3 && abs_error > 1e-3) begin
      $display("ERROR: Test %0d FAILED", test_count);
      $display("  A (input)   = %f -> FP16: %f (0x%04h)", a, a_converted, a_fp16);
      $display("  B (input)   = %f -> FP16: %f (0x%04h)", b, b_converted, b_fp16);
      $display("  Expected    = %f (0x%04h)", expected_val, expected_fp16);
      $display("  Got         = %f (0x%04h)", result, result_fp16);
      $display("  Rel Error   = %e", rel_error);
      error_count++;
    end else begin
      $display("PASS: Test %0d - FP16(0x%04h * 0x%04h) = 0x%04h (expected: 0x%04h)", 
        test_count, a_fp16, b_fp16, result_fp16, expected_fp16);
    end
  endtask
  
  // Main test sequence
  initial begin
    $display("======================================");
    $display("  VX_fp16_mul Testbench");
    $display("======================================");
    
    // Initialize
    reset = 1;
    a_valid = 0;
    b_valid = 0;
    a_data = 0;
    b_data = 0;
    fifo_clear = 0;
    
    repeat(10) @(posedge clk);
    reset = 0;
    repeat(5) @(posedge clk);
    
    // Basic tests (values within FP16 range)
    $display("\n--- Basic Tests ---");
    test_multiply(2.0, 3.0);
    test_multiply(1.5, 2.5);
    test_multiply(-1.0, 2.0);
    test_multiply(0.5, 0.25);
    test_multiply(10.0, 0.1);
    
    // Edge cases
    $display("\n--- Edge Cases ---");
    test_multiply(0.0, 5.0);
    test_multiply(1.0, 1.0);
    test_multiply(-0.0, 3.0);
    
    // Random tests (scaled for FP16 range ±65504)
    $display("\n--- Random Tests (100 iterations) ---");
    for (int i = 0; i < 100; i++) begin
      automatic real a_val = ($urandom() % 10000) / 100.0 - 50.0;
      automatic real b_val = ($urandom() % 10000) / 100.0 - 50.0;
      test_multiply(a_val, b_val);
    end
    
    // Final report
    $display("\n======================================");
    $display("  Test Summary");
    $display("======================================");
    $display("  Total Tests: %0d", test_count);
    $display("  Passed:      %0d", test_count - error_count);
    $display("  Failed:      %0d", error_count);
    
    if (error_count == 0)
      $display("\n*** ALL TESTS PASSED ***");
    else
      $display("\n*** %0d TESTS FAILED ***", error_count);
    
    $finish;
  end

endmodule
