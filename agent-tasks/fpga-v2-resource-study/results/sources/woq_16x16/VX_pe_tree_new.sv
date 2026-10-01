`timescale 1ns / 1ps
module VX_pe_tree_new import VX_gpu_pkg::*, VX_utils_pkg::*; #(
    parameter  int IN_DW                = (((((1 + 10) + 1 - 1) / 1) + ((1 == 1) ? 0 : 1)) * 1 + 1),
    parameter  int WEIGHT_DW            = 4,
    parameter  int OUT_DW               = ((((((1 + 10 + (4 + 2 + (23-10))) + 1 - 1) / 1) * 1) + 1) + 4 + $clog2(16)),
    parameter  int BLOCK_SIZE           = 1,
    parameter  int BLOCK_NUM            = (((((1 + 10 + (4 + 2 + (23-10))) + 1 - 1) / 1) * 1) / 1),
    parameter  int SEL_BLOCK_NUM        = ((((1 + 10) + 1 - 1) / 1) + ((1 == 1) ? 0 : 1)),
    parameter  int ROW_SIZE             = 16,
    parameter  int TILE_COL_SIZE        = 16,
    parameter  int PIPE_MULT            = 1,
    parameter  int PIPE_ALIGN           = 1,
    parameter  int PIPELINE_STAGE_INTV  = 2,
    localparam int BLK_IDX_NUM          = BLOCK_NUM - SEL_BLOCK_NUM + 1,
    localparam int BLK_BITW             = $clog2(BLK_IDX_NUM)
) (
    input  logic clk_i,
    input  logic resetn_i,
    input  logic [ROW_SIZE-1:0][IN_DW-1:0] ifmap_i,
    input  logic [ROW_SIZE-1:0][TILE_COL_SIZE-1:0][WEIGHT_DW-1:0] weight_i,   
    input  logic input_valid_i,
    input  logic [ROW_SIZE-1:0][BLK_BITW-1:0] blk_sidx_i,
    output logic [TILE_COL_SIZE-1:0][OUT_DW-1:0] ps_o,
    output logic valid_o
);
  localparam int MAC_DW = (((((1 + 10 + (4 + 2 + (23-10))) + 1 - 1) / 1) * 1) + 1) + 4;
  localparam int PIPELINE_STAGES = get_pipe_stage_bitmask(ROW_SIZE, PIPELINE_STAGE_INTV);
  logic signed [IN_DW-1:0] ifmap_val[TILE_COL_SIZE][ROW_SIZE];
  logic signed [WEIGHT_DW-1:0] weight_val[TILE_COL_SIZE][ROW_SIZE];
  logic [BLK_BITW-1:0] blk_idx[TILE_COL_SIZE][ROW_SIZE];
  (* use_dsp = "yes" *) logic signed [IN_DW+WEIGHT_DW-1:0] product[TILE_COL_SIZE][ROW_SIZE];
  logic signed [IN_DW+WEIGHT_DW-1:0] product_out[TILE_COL_SIZE][ROW_SIZE];
  logic [BLK_BITW-1:0] blk_idx_out[TILE_COL_SIZE][ROW_SIZE];
  logic signed [MAC_DW-1:0] aligned[TILE_COL_SIZE][ROW_SIZE];
  logic signed [MAC_DW-1:0] aligned_out[TILE_COL_SIZE][ROW_SIZE];
  logic valid_mult_row[TILE_COL_SIZE][ROW_SIZE];
  logic valid_align_row[TILE_COL_SIZE][ROW_SIZE];
  logic valid_mult[TILE_COL_SIZE];
  logic valid_align[TILE_COL_SIZE];
  logic signed [MAC_DW-1:0] mac_results_collected[TILE_COL_SIZE][ROW_SIZE];
  logic [ROW_SIZE-1:0][MAC_DW-1:0] mac_results_collected_flat[TILE_COL_SIZE];
  logic signed [MAC_DW+$clog2(ROW_SIZE)-1:0] reduced_sum[TILE_COL_SIZE];
  logic valid_reduced[TILE_COL_SIZE];
  logic signed [MAC_DW + $clog2(ROW_SIZE)-1:0] final_sum_extended[TILE_COL_SIZE];
  logic signed [MAC_DW + $clog2(ROW_SIZE)-1:0] accumulated_result[TILE_COL_SIZE];
  logic valid_output[TILE_COL_SIZE];
  generate
    for (genvar col = 0; col < TILE_COL_SIZE; col++) begin : gen_col
      for (genvar row = 0; row < ROW_SIZE; row++) begin : gen_mac
        assign ifmap_val[col][row] = $signed(ifmap_i[row]);
        assign weight_val[col][row] = $signed(weight_i[row][col]);
        assign blk_idx[col][row] = blk_sidx_i[row];
        assign product[col][row] = ifmap_val[col][row] * weight_val[col][row];
        VX_elastic_buffer #(
          .DATAW   (IN_DW+WEIGHT_DW+BLK_BITW),
          .SIZE    (PIPE_MULT),
          .OUT_REG (PIPE_MULT)
        ) mult_buffer (
          .clk       (clk_i),
          .reset     (~resetn_i),
          .valid_in  (input_valid_i),
          .ready_in  (),
          .data_in   ({product[col][row], blk_idx[col][row]}),
          .data_out  ({product_out[col][row], blk_idx_out[col][row]}),
          .ready_out (1'b1),
          .valid_out (valid_mult_row[col][row])
        );
        always_comb begin
          aligned[col][row] = $signed(product_out[col][row]);
          aligned[col][row] = aligned[col][row] << blk_idx_out[col][row];
        end
        VX_elastic_buffer #(
          .DATAW   (MAC_DW),
          .SIZE    (PIPE_ALIGN),
          .OUT_REG (PIPE_ALIGN)
        ) align_buffer (
          .clk       (clk_i),
          .reset     (~resetn_i),
          .valid_in  (valid_mult_row[col][row]),
          .ready_in  (),
          .data_in   (aligned[col][row]),
          .data_out  (aligned_out[col][row]),
          .ready_out (1'b1),
          .valid_out (valid_align_row[col][row])
        );
        if (row == 0) begin : gen_valid_assign
          assign valid_mult[col] = valid_mult_row[col][row];
          assign valid_align[col] = valid_align_row[col][row];
        end
        assign mac_results_collected[col][row] = aligned_out[col][row];
      end
      always_comb begin
        for (int r = 0; r < ROW_SIZE; r++) begin
          mac_results_collected_flat[col][r] = mac_results_collected[col][r];
        end
      end
      VX_reduce_tree_pipelined_v2 #(
        .IN_W  (MAC_DW),
        .OUT_W (MAC_DW + $clog2(ROW_SIZE)),   
        .N     (ROW_SIZE),
        .OP    ("+"),
        .PIPELINE_STAGES (PIPELINE_STAGES),
        .EB_SIZE (1),
        .EB_OUT_REG (1)
      ) reduce_tree (
        .clk       (clk_i),
        .reset     (~resetn_i),
        .data_in   (mac_results_collected_flat[col]),
        .valid_in  (valid_align[col]),
        .data_out  (reduced_sum[col]),
        .valid_out (valid_reduced[col])
      );
      assign final_sum_extended[col] = $signed(reduced_sum[col]);
      assign accumulated_result[col] = final_sum_extended[col];  
      always_ff @(posedge clk_i or negedge resetn_i) begin
        if (!resetn_i) begin
          ps_o[col] <= '0;
          valid_output[col] <= 1'b0;
        end else begin
          if (valid_reduced[col]) begin
            ps_o[col] <= accumulated_result[col];
          end
          valid_output[col] <= valid_reduced[col];
        end
      end
      if (col == 0) begin : gen_valid_out
        assign valid_o = valid_output[col];
      end
    end
  endgenerate
endmodule
