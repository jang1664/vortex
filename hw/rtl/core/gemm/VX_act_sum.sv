`timescale 1ns / 1ps

module act_sum #(
    parameter  IN_DW         = -1,
    parameter  OUT_DW        = -1,
    parameter  NUM_UNIT      = -1,
    parameter  TILE_SIZE     = -1,
    parameter  BLOCK_SIZE    = -1,
    parameter  BLOCK_NUM     = -1,
    parameter  SEL_BLOCK_NUM = -1,
    localparam BLK_IDX_NUM   = BLOCK_NUM - SEL_BLOCK_NUM + 1,
    localparam BLK_BITW      = $clog2(BLK_IDX_NUM)
) (
    input logic clk_i,
    input logic resetn_i,
    input logic [NUM_UNIT-1:0][IN_DW-1:0] data_i,
    input logic [NUM_UNIT-1:0][BLK_BITW-1:0] blk_idx_i,

    output logic [OUT_DW-1:0] sum_act_o
);

  logic signed [OUT_DW-1:0] int_sum_act_d[NUM_UNIT/TILE_SIZE-1:0];
  logic signed [OUT_DW-1:0] int_sum_act_q[NUM_UNIT/TILE_SIZE-1:0];

  generate
    for (genvar i = 0; i < NUM_UNIT / TILE_SIZE; i++) begin : rg
      if (i == 0) begin : rgz
        always_comb begin
          int_sum_act_d[i] = '0;
          for (int k = 0; k < TILE_SIZE; k++) begin
            int_sum_act_d[i] = int_sum_act_d[i] + (signed'(data_i[i*TILE_SIZE+k]) << (BLOCK_SIZE*blk_idx_i[i*TILE_SIZE+k]));
          end
        end
      end else begin : rgnz
        always_comb begin
          int_sum_act_d[i] = int_sum_act_q[i-1];
          for (int k = 0; k < TILE_SIZE; k++) begin
            int_sum_act_d[i] = int_sum_act_d[i] + (signed'(data_i[i*TILE_SIZE+k]) << (BLOCK_SIZE*blk_idx_i[i*TILE_SIZE+k]));
          end
        end
      end

      always_ff @(posedge clk_i) begin
        int_sum_act_q[i] <= int_sum_act_d[i];
      end
    end
  endgenerate

  assign sum_act_o = int_sum_act_q[NUM_UNIT/TILE_SIZE-1];

endmodule
