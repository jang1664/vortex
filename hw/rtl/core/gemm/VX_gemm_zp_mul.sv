`timescale 1ns / 1ps

`include "VX_define.vh"

module VX_gemm_zp_mul import VX_gpu_pkg::*; #(
    parameter  IN_DW           = `SAMF_SUM_WIDTH,
    parameter  REG_DW          = `ZP_TRANS_WIDTH,
    parameter  OUT_DW          = `ZP_MUL_OUT_WIDTH,
    parameter  NUM_UNIT        = `MXU_ROW,
    parameter  DLY_CYCLES      = 1
) (
  input logic clk_i,
  input logic resetn_i,
  input logic valid_i,
  input logic [NUM_UNIT-1:0][IN_DW-1:0] data_i,
  input logic [NUM_UNIT-1:0][REG_DW-1:0] zp_reg_i,
  output logic [NUM_UNIT-1:0][OUT_DW-1:0] data_o,
  output logic valid_o
);

  logic signed [NUM_UNIT-1:0][OUT_DW-1:0] mul_out;

  // Multiply input data with zero-point transformed values
  always_comb begin
    for (int i = 0; i < NUM_UNIT; i++) begin
      mul_out[i] = $signed(IN_DW'(data_i[i])) * $signed(REG_DW'(zp_reg_i[i]));
    end
  end

  VX_shift_register #(
    .DATAW    (OUT_DW*NUM_UNIT + 1),
    .RESETW   (0),
    .DEPTH    (DLY_CYCLES),
    .NUM_TAPS (1)
  ) u_sum_shift (
    .clk      (clk_i),
    .reset    (~resetn_i),
    .enable   (1'b1),
    .data_in  ({mul_out, valid_i}),
    .data_out ({data_o, valid_o})
  );

endmodule