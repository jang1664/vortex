`timescale 1ns / 1ps

module reformatter 
  import modes::*;
#(
    parameter NUM_UNIT = -1,
    parameter IN_DW = -1,
    parameter ACT_ADD_WIDTH = -1,
    parameter TILE_SIZE = -1,
    parameter OUT_DW = -1

) (
    input logic clk_i,
    input logic resetn_i,
    input logic [NUM_UNIT-1:0][IN_DW-1:0] data_i,
    input logic [ACT_ADD_WIDTH-1:0] act_sum_i,
    input weight_mode_t weight_mode_i,

    output logic [NUM_UNIT-1:0][OUT_DW-1:0] data_o
);

  logic signed [ACT_ADD_WIDTH-1:0] act_sum_q[NUM_UNIT/TILE_SIZE-1:0];
  logic signed [NUM_UNIT-1:0][IN_DW+1-1:0] data_o_int;
  logic signed [NUM_UNIT-1:0][OUT_DW-1:0] final_data_o_int;

  assign act_sum_q[0] = (weight_mode_i == W_SYM) ? act_sum_i : '0;
  always_ff @(posedge clk_i) begin
    for (int i = 1; i < NUM_UNIT / TILE_SIZE; i++) begin
      if(weight_mode_i == W_SYM) begin
        act_sum_q[i] <= act_sum_q[i-1];
      end
    end
  end

  generate
    for (genvar i = 0; i < NUM_UNIT / TILE_SIZE; i++) begin : cg
      for (genvar j = 0; j < TILE_SIZE; j++) begin : col_off
        always_comb begin
          data_o_int[i*TILE_SIZE+j] = (weight_mode_i == W_SYM) ? data_i[TILE_SIZE*i+j] << 1 : '0;
          final_data_o_int[i*TILE_SIZE+j] = data_o_int[i*TILE_SIZE+j] + act_sum_q[i];
        end
      end
    end
  endgenerate

  always_ff @(posedge clk_i) begin
    if(weight_mode_i == W_SYM) begin
      data_o <= final_data_o_int;
    end else begin
      data_o <= data_i;
    end
  end

endmodule
