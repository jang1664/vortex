`timescale 1ns / 1ps

module int2fp_array #(
    parameter int unsigned IN_DW = 0,
    parameter int unsigned OUT_DW = 0,
    parameter int unsigned IN_EXP_WIDTH = 0,
    parameter int unsigned OUT_EXP_WIDTH = 0,
    parameter int unsigned IN_EXP_BIAS = 0,
    parameter int unsigned OUT_EXP_BIAS = 0,
    parameter int unsigned OUT_MANTISSA_WIDTH = 0,
    parameter int unsigned SCALE = 0,
    parameter int unsigned NUM_UNIT = 0,
    parameter int unsigned TILE_SIZE = 0
) (
    input logic clk_i,
    input logic resetn_i,
    input logic [IN_EXP_WIDTH-1:0] max_exp_i,
    input logic [NUM_UNIT-1:0][IN_DW-1:0] ps_i,

    output logic [NUM_UNIT-1:0][OUT_DW-1:0] fp_o
);

  logic [NUM_UNIT/TILE_SIZE-1:0][IN_EXP_WIDTH-1:0] max_exp_i_pipe;

  generate
    for (genvar i = 0; i < NUM_UNIT / TILE_SIZE; i++) begin : col_group
      if (i == 0) begin
        assign max_exp_i_pipe[0] = max_exp_i;
      end else begin
        always_ff @(posedge clk_i, negedge resetn_i) begin
          if (~resetn_i) begin
            max_exp_i_pipe[i] <= '0;
          end else begin
            max_exp_i_pipe[i] <= max_exp_i_pipe[i-1];
          end
        end
      end
    end

    for (genvar i = 0; i < NUM_UNIT; i++) begin : col
      int2fp #(
          .IN_DW(IN_DW),
          .OUT_DW(OUT_DW),
          .IN_EXP_WIDTH(IN_EXP_WIDTH),
          .OUT_EXP_WIDTH(OUT_EXP_WIDTH),
          .IN_EXP_BIAS(IN_EXP_BIAS),
          .OUT_EXP_BIAS(OUT_EXP_BIAS),
          .OUT_MANTISSA_WIDTH(OUT_MANTISSA_WIDTH),
          .SCALE(SCALE)
      ) u_int2fp (
          .clk_i(clk_i),
          .resetn_i(resetn_i),
          .int_data_i(ps_i[i]),
          .max_exp_i(max_exp_i_pipe[i/TILE_SIZE]),
          .fp_data_o(fp_o[i])
      );
    end
  endgenerate

endmodule
