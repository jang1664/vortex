`timescale 1ns / 1ps

module VX_compare #(
    parameter EXP_WIDTH = -1
) (
    input logic [EXP_WIDTH-1:0] data_a_i,
    data_b_i,

    output logic [EXP_WIDTH-1:0] cmp_data_o
);
  always_comb begin
    cmp_data_o = (data_a_i >= data_b_i) ? data_a_i : data_b_i;
  end

endmodule


