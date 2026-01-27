`timescale 1ns / 1ps

`include "VX_define.vh"

module VX_act_sum #(
    parameter  IN_DW           = `SEL_BLOCK_WIDTH,
    parameter  ALIGNED_DW      = `SIGNED_ALIGNED_MAN_FULL_WIDTH,
    parameter  OUT_DW          = `SAMF_SUM_WIDTH,
    parameter  NUM_UNIT        = `MXU_ROW,
    parameter  BLOCK_SIZE      = `BLOCK_SIZE,
    parameter  PIPELINE_STAGES = 2,
    parameter  DLY_CYCLES      = 1,
    localparam BLK_BITW        = `BLOCK_IDX_WIDTH
) (
    input logic clk_i,
    input logic resetn_i,
    input logic valid_i,
    output logic ready_o,
    input logic [NUM_UNIT-1:0][IN_DW-1:0] data_i,
    input logic [NUM_UNIT-1:0][BLK_BITW-1:0] blk_idx_i,

    output logic [OUT_DW-1:0] sum_act_o,
    output logic valid_o
);

  localparam REDUCE_OUT_DW = IN_DW + `CLOG2(NUM_UNIT);

  logic signed [REDUCE_OUT_DW-1:0] sum_act_q;
  logic reduce_valid;
  logic signed [OUT_DW-1:0] sum_shifted;

  // sum of aligned_data_out_valid
  VX_reduce_tree_pipelined #(
    .IN_W  (REDUCE_OUT_DW),
    .OUT_W (REDUCE_OUT_DW),
    .N     (NUM_UNIT),
    .OP    ("+"),
    .PIPELINE_STAGES (PIPELINE_STAGES)
  ) reduce_tree (
    .clk       (clk_i),
    .reset     (~resetn_i),
    .data_in   (data_i),
    .valid_in  (valid_i),
    .data_out  (sum_act_q),
    .valid_out (reduce_valid)
  );

  assign sum_shifted = $signed(OUT_DW'(sum_act_q)) <<< (BLOCK_SIZE*blk_idx_i);

  // Fixed-cycle output delay: valid/data are delayed by exactly DLY_CYCLES cycles.
  VX_shift_register #(
    .DATAW    (OUT_DW + 1),
    .RESETW   (0),
    .DEPTH    (DLY_CYCLES),
    .NUM_TAPS (1)
  ) u_sum_shift (
    .clk      (clk_i),
    .reset    (~resetn_i),
    .enable   (1'b1),
    .data_in  ({sum_shifted, reduce_valid}),
    .data_out ({sum_act_o, valid_o})
  );

endmodule
