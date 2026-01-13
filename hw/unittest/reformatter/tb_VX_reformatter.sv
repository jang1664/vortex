`timescale 1ns / 1ps

`include "VX_define.vh"

module tb_VX_reformatter;

  localparam int IN_DW         = 16;
  localparam int NUM_UNIT      = 8;
  localparam int ACT_ADD_WIDTH = 16;
  localparam int OUT_DW        = 32;
  localparam int DLY_CYCLES    = 2;

  logic clk;
  logic resetn;

  logic [NUM_UNIT-1:0][IN_DW-1:0] data_i;
  logic [ACT_ADD_WIDTH-1:0]       act_sum_i;
  logic                           valid_i;

  logic [NUM_UNIT-1:0][OUT_DW-1:0] data_o;
  logic                            valid_o;

  typedef struct packed {
    logic                           valid;
    logic [NUM_UNIT-1:0][IN_DW-1:0] data_in;
    logic [ACT_ADD_WIDTH-1:0]       act_sum;
    logic [NUM_UNIT-1:0][OUT_DW-1:0] data;
  } expected_t;

  expected_t expected_q[$];

  int error_cnt = 0;
  int test_cycles = 100;

  VX_reformatter #(
    .IN_DW        (IN_DW),
    .NUM_UNIT     (NUM_UNIT),
    .ACT_ADD_WIDTH(ACT_ADD_WIDTH),
    .OUT_DW       (OUT_DW)
  ) dut (
    .clk_i    (clk),
    .resetn_i (resetn),
    .data_i   (data_i),
    .act_sum_i(act_sum_i),
    .valid_i  (valid_i),
    .data_o   (data_o),
    .valid_o  (valid_o)
  );

  always #5 clk = ~clk;

  initial begin
    clk = 0;
    resetn = 0;
    valid_i = 0;
    data_i = '0;
    act_sum_i = '0;

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
        data_i[i] = $random;
    end
    act_sum_i = $random;

    if (valid_i) begin
        exp.valid = 1;
        exp.data_in = data_i;
        exp.act_sum = act_sum_i;

        for (i=0; i<NUM_UNIT; ++i) begin
            logic signed [IN_DW-1:0] s_data = data_i[i];
            logic signed [ACT_ADD_WIDTH-1:0] s_sum = act_sum_i;
            logic signed [OUT_DW-1:0] s_res;

            // Logic from TB
            logic signed [OUT_DW-1:0] mul_val;
            mul_val = $signed(IN_DW'(data_i[i])) << 1;
            
            s_res = mul_val + s_sum;
            exp.data[i] = s_res;
        end

        expected_q.push_back(exp);
    end else begin
        exp.valid = 0;
        exp.data_in = '0;
        exp.act_sum = '0;
        exp.data = '0;
        expected_q.push_back(exp);
    end

    if (expected_q.size() > DLY_CYCLES) begin
        expected_t expected_out = expected_q.pop_front();

        if (valid_o !== expected_out.valid) begin
             $display("[Error] Time %0t: valid mismatch. Exp %b, Got %b", $time, expected_out.valid, valid_o);
             error_cnt++;
        end else if (valid_o) begin
             for (i=0; i<NUM_UNIT; ++i) begin
                 if (data_o[i] !== expected_out.data[i]) begin
                     $display("[Error] Time %0t: data[%0d] mismatch. Exp %h, Got %h", $time, i, expected_out.data[i], data_o[i]);
                     $display("        Input: data_i=%h, act_sum=%h", expected_out.data_in[i], expected_out.act_sum);
                     error_cnt++;
                 end
             end
        end
    end
    
    if (error_cnt > 10) $finish;
  endtask

endmodule
