`timescale 1ns / 1ps

`include "VX_define.vh"

module tb_VX_fp32_mul();
  parameter string tb_name = "tb_VX_fp32_mul";
  parameter PERIOD = 10.0;
  
  logic clk;
  logic reset;
  
  // Input A
  logic        a_valid;
  logic        a_ready;
  logic [31:0] a_data;
  
  // Input B
  logic        b_valid;
  logic        b_ready;
  logic [31:0] b_data;
  
  // Output
  logic        result_valid;
  logic        result_ready;
  logic [31:0] result_data;
  
  // DUT instantiation
  VX_fp32_mul #(
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
  
  // Output FIFO for capturing results
  localparam int OUTPUT_DATA_WIDTH = 32;
  
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
  
  assign output_out.ready = 1'b0;
  assign output_in.data   = result_data;
  assign output_in.strb   = '1;
  assign output_in.valid  = result_valid;
  assign result_ready     = output_in.ready;
  
  initial begin
    fifo_dbg_vif = u_output_fifo.dbg_if;
  end
  
  // Test variables
  real a_float, b_float, expected_float, result_float;
  int error_count = 0;
  int test_count = 0;
  
  // Convert FP32 bits to real
  function real bits_to_float(input [31:0] bits);
    real result;
    int fd;
    fd = $fopen("/tmp/fp_convert.bin", "wb");
    $fwrite(fd, "%u", bits);
    $fclose(fd);
    fd = $fopen("/tmp/fp_convert.bin", "rb");
    $fscanf(fd, "%f", result);
    $fclose(fd);
    return result;
  endfunction
  
  // Convert real to FP32 bits
  function [31:0] float_to_bits(input real value);
    int fd;
    int bits;
    fd = $fopen("/tmp/fp_convert.bin", "wb");
    $fwrite(fd, "%f", value);
    $fclose(fd);
    fd = $fopen("/tmp/fp_convert.bin", "rb");
    $fscanf(fd, "%u", bits);
    $fclose(fd);
    return bits;
  endfunction
  
  // Test task with randomized valid timing
  task automatic test_multiply(input real a, input real b);
    reg [31:0] a_bits;
    reg [31:0] b_bits;
    real expected;
    int a_wait, b_wait;
    reg [31:0] result_bits;
    real result;
    real abs_error;
    real rel_error;
    
    a_bits = $shortrealtobits(a);
    b_bits = $shortrealtobits(b);
    expected = a * b;
    
    // Randomize when each input becomes valid
    a_wait = $urandom_range(0, 5);
    b_wait = $urandom_range(0, 5);
    
    fork
      // Input A with random delay
      begin
        a_valid = 0;
        repeat(a_wait) @(posedge clk);
        a_data = a_bits;
        a_valid = 1;
        while (!a_ready) @(posedge clk);
        @(posedge clk);
        a_valid = 0;
      end
      
      // Input B with random delay
      begin
        b_valid = 0;
        repeat(b_wait) @(posedge clk);
        b_data = b_bits;
        b_valid = 1;
        while (!b_ready) @(posedge clk);
        @(posedge clk);
        b_valid = 0;
      end
    join
    
    // Wait for result
    while (fifo_dbg_vif.get_queue_size() == 0) @(posedge clk);
    
    result_bits = fifo_dbg_vif.get_queue_data(0);
    result = $bitstoshortreal(result_bits);
    abs_error = (result > expected) ? (result - expected) : (expected - result);
    rel_error = (expected != 0.0) ? abs_error / ((expected > 0) ? expected : -expected) : abs_error;
    
    test_count++;
    
    if (rel_error > 1e-6 && abs_error > 1e-6) begin
      $display("ERROR: Test %0d FAILED", test_count);
      $display("  A = %f (0x%08h)", a, a_bits);
      $display("  B = %f (0x%08h)", b, b_bits);
      $display("  Expected = %f (0x%08h)", expected, $shortrealtobits(expected));
      $display("  Got      = %f (0x%08h)", result, result_bits);
      $display("  Rel Error = %e", rel_error);
      error_count++;
    end else begin
      $display("PASS: Test %0d - %f * %f = %f", test_count, a, b, result);
    end
  endtask
  
  // Main test sequence
  initial begin
    $display("======================================");
    $display("  VX_fp32_mul Testbench");
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
    
    // Basic tests
    $display("\n--- Basic Tests ---");
    test_multiply(2.0, 3.0);
    test_multiply(1.5, 2.5);
    test_multiply(-1.0, 2.0);
    test_multiply(0.5, 0.25);
    test_multiply(100.0, 0.01);
    
    // Edge cases
    $display("\n--- Edge Cases ---");
    test_multiply(0.0, 5.0);
    test_multiply(1.0, 1.0);
    test_multiply(-0.0, 3.0);
    
    // Random tests
    $display("\n--- Random Tests (100 iterations) ---");
    for (int i = 0; i < 100; i++) begin
      automatic real a_val = $urandom() / 1000000.0 - 2147.0;
      automatic real b_val = $urandom() / 1000000.0 - 2147.0;
      test_multiply(a_val, b_val);
    end
    
    // Final report
    $display("\n======================================");
    $display("  Test Summary");
    $display("======================================");
    $display("  Total Tests: %0d", test_count);
    $display("  Passed:      %0d", test_count - error_count);
    $display("  Failed:      %0d", error_count);
    
    if (error_count == 0) begin
      $display("\n*** ALL TESTS PASSED ***");
    end else begin
      $display("\n*** %0d TESTS FAILED ***", error_count);
    end
    
    $finish;
  end

endmodule
