`timescale 1ns / 1ps

`include "VX_define.vh"

module tb_VX_gemm_zp_mul;

  localparam int IN_DW      = `SAMF_SUM_WIDTH;
  localparam int REG_DW     = `ZP_TRANS_WIDTH;
  localparam int OUT_DW     = `ZP_MUL_OUT_WIDTH;
  localparam int NUM_UNIT   = `MXU_ROW;
  localparam int DLY_CYCLES = 3; 

  logic clk;
  logic resetn;

  logic valid_i;
  logic [NUM_UNIT-1:0][IN_DW-1:0]  data_i;
  logic [NUM_UNIT-1:0][REG_DW-1:0] zp_reg_i;
  
  logic valid_o;
  logic [NUM_UNIT-1:0][OUT_DW-1:0] data_o;
  
  typedef struct packed {
    logic valid;
    logic [NUM_UNIT-1:0][OUT_DW-1:0] data;
  } expected_t;
  
  expected_t expected_q[$];
  
  int error_cnt = 0;
  int test_cycles = 100;

  VX_gemm_zp_mul #(
    .IN_DW     (IN_DW),
    .REG_DW    (REG_DW),
    .OUT_DW    (OUT_DW),
    .NUM_UNIT  (NUM_UNIT),
    .DLY_CYCLES(DLY_CYCLES)
  ) dut (
    .clk_i   (clk),
    .resetn_i(resetn),
    .valid_i (valid_i),
    .data_i  (data_i),
    .zp_reg_i(zp_reg_i),
    .data_o  (data_o),
    .valid_o (valid_o)
  );

  always #5 clk = ~clk;

  initial begin
    clk = 0;
    resetn = 0;
    valid_i = 0;
    data_i = '0;
    zp_reg_i = '0;
    
    #20 resetn = 1;
    
    repeat (test_cycles) begin
        @(negedge clk);
        drive_stimulus(1);
    end
    
    // Flush
    repeat (DLY_CYCLES + 5) begin
        @(negedge clk);
        drive_stimulus(0); 
    end
    
    if (error_cnt == 0) begin
        $display("TEST PASSED");
    end else begin
        $display("TEST FAILED with %0d errors", error_cnt);
    end
    $finish;
  end

  task automatic drive_stimulus(input logic random_valid);
    expected_t exp;
    int i;
    
    if (random_valid) begin
        valid_i = $urandom_range(0, 1);
    end else begin
        valid_i = 0;
    end

    for (i=0; i<NUM_UNIT; ++i) begin
        data_i[i]   = $random; 
        zp_reg_i[i] = $random;
    end
    
    exp.valid = valid_i;
    for (i=0; i<NUM_UNIT; ++i) begin
         logic signed [IN_DW-1:0]  s_data = data_i[i];
         logic signed [REG_DW-1:0] s_reg  = zp_reg_i[i];
         logic signed [OUT_DW-1:0] s_res;
         s_res = s_data * s_reg;
         exp.data[i] = s_res;
    end
    
    expected_q.push_back(exp);
    
    if (expected_q.size() > DLY_CYCLES) begin
        expected_t expected_out = expected_q.pop_front();
        
        if (valid_o !== expected_out.valid) begin
            $display("[Error] Time %0t: valid mismatch. Exp %b, Got %b", $time, expected_out.valid, valid_o);
            error_cnt++;
        end else if (valid_o) begin
             for (i=0; i<NUM_UNIT; ++i) begin
                 if (data_o[i] !== expected_out.data[i]) begin
                     $display("[Error] Time %0t: data[%0d] mismatch. Exp %h, Got %h", $time, i, expected_out.data[i], data_o[i]);
                     error_cnt++;
                 end
             end
        end
    end
    
    if (error_cnt > 10) $finish; 
  endtask

endmodule
