`timescale 1ns / 1ps

module VX_reformatter import VX_gpu_pkg::*; #(
    parameter IN_DW = 16,
    parameter NUM_UNIT = 8,
    parameter ACT_ADD_WIDTH = 16,
    parameter OUT_DW = 32
) (
    input logic clk_i,
    input logic resetn_i,
    input logic [NUM_UNIT-1:0][IN_DW-1:0] data_i,
    input logic [ACT_ADD_WIDTH-1:0] act_sum_i,
    input logic valid_i,

    output logic [NUM_UNIT-1:0][OUT_DW-1:0] data_o,
    output logic valid_o
);

  logic signed [NUM_UNIT-1:0][OUT_DW-1:0] mul_out;
  logic signed [NUM_UNIT-1:0][OUT_DW-1:0] mul_out_q;
  logic mul_out_valid;
  logic signed [ACT_ADD_WIDTH-1:0] act_sum_q;

  logic signed [NUM_UNIT-1:0][OUT_DW-1:0] add_out;
  logic signed [NUM_UNIT-1:0][OUT_DW-1:0] add_out_q;
  logic add_out_valid;

  always_comb begin
    for(int i=0; i<NUM_UNIT; i++) begin
      mul_out[i] = $signed(IN_DW'(data_i[i])) << 1;
    end
  end

  VX_elastic_buffer #(
    .DATAW(OUT_DW * NUM_UNIT + ACT_ADD_WIDTH),
    .SIZE(1)
  ) u_mul_out_buf (
    .clk(clk_i),
    .reset(~resetn_i),
    .valid_in(valid_i),
    .ready_in(),
    .data_in({mul_out, act_sum_i}),
    .data_out({mul_out_q, act_sum_q}),
    .ready_out(1'b1),
    .valid_out(mul_out_valid)
  );

  always_comb begin
    for(int i=0; i<NUM_UNIT; i++) begin
      add_out[i] = $signed(mul_out_q[i]) + act_sum_q;
    end
  end

  VX_elastic_buffer #(
    .DATAW(OUT_DW * NUM_UNIT),
    .SIZE(1)
  ) u_add_out_buf (
    .clk(clk_i),
    .reset(~resetn_i),
    .valid_in(mul_out_valid),
    .ready_in(),
    .data_in(add_out),
    .data_out(add_out_q),
    .ready_out(1'b1),
    .valid_out(add_out_valid)
  );

  assign valid_o = add_out_valid;
  assign data_o = add_out_q;

endmodule
