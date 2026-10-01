`timescale 1ns / 1ps
module VX_gemm_tree_v1 import VX_gpu_pkg::*; #(
    parameter  int IN_DW                 = (((((1 + 10) + 1 - 1) / 1) + ((1 == 1) ? 0 : 1)) * 1 + 1),
    parameter  int WEIGHT_DW             = 4,
    parameter  int OUT_DW                = ((((((1 + 10 + (4 + 2 + (23-10))) + 1 - 1) / 1) * 1) + 1) + 4 + $clog2(16)),
    parameter  int BLOCK_SIZE            = 1,
    parameter  int BLOCK_NUM             = (((((1 + 10 + (4 + 2 + (23-10))) + 1 - 1) / 1) * 1) / 1),
    parameter  int SEL_BLOCK_NUM         = ((((1 + 10) + 1 - 1) / 1) + ((1 == 1) ? 0 : 1)),
    parameter  int ROW_SIZE              = 16,
    parameter  int COL_SIZE              = 16,
    parameter  int TILE_COL_SIZE         = 16,
    parameter  int WEIGHT_LOAD_ROW_NUM   = 4,   
    parameter  int WEIGHT_LOAD_COL_NUM   = 4,   
    parameter  int PIPELINE_STAGE_INTV   = 2,   
    parameter  int PIPE_MULT             = 1,   
    parameter  int PIPE_ALIGN            = 1,   
    localparam int BLK_BITW              = $clog2(((((((1 + 10 + (4 + 2 + (23-10))) + 1 - 1) / 1) * 1) / 1) - ((((1 + 10) + 1 - 1) / 1) + ((1 == 1) ? 0 : 1)) + 1))
) (
    input logic clk_i,
    input logic resetn_i,
    input logic [ROW_SIZE-1:0][IN_DW-1:0] ifmap_i,
    input logic [WEIGHT_LOAD_ROW_NUM-1:0][COL_SIZE-1:0][WEIGHT_DW-1:0] weight_i,
    input gemm_wreg_idx_t in_weight_sel_i,
    input gemm_wreg_idx_t out_weight_sel_i,
    input logic ready_weight_i,
    input logic input_valid_i,
    input logic weight_load_dir_i,   
    input logic [ROW_SIZE-1:0][BLK_BITW-1:0] blk_sidx_i,
    output logic [COL_SIZE-1:0][OUT_DW-1:0] ps_o,
    output logic [COL_SIZE/TILE_COL_SIZE-1:0] output_valid_o
);
  logic [COL_SIZE/TILE_COL_SIZE-1:0][ROW_SIZE-1:0][IN_DW-1:0] ifmap_q;
  logic [COL_SIZE/TILE_COL_SIZE-1:0][ROW_SIZE-1:0][BLK_BITW-1:0] blk_sidx_q;
  logic [COL_SIZE/TILE_COL_SIZE-1:0] in_valid_q;
  gemm_wreg_idx_t out_weight_sel_q [COL_SIZE/TILE_COL_SIZE-1:0];
  logic [ROW_SIZE-1:0][COL_SIZE-1:0][WEIGHT_DW-1:0] weights;
  generate
    for (genvar j = 0; j < COL_SIZE / TILE_COL_SIZE; j++) begin : gen_col_pipe
      if (j == 0) begin : gen_col_pipe_zero
        always_ff @(posedge clk_i or negedge resetn_i) begin
          if (!resetn_i) begin
            in_valid_q[j] <= 1'b0;
            out_weight_sel_q[j] <= '0;
          end else begin
            if (input_valid_i) begin
              ifmap_q[j] <= ifmap_i;
              blk_sidx_q[j] <= blk_sidx_i;
            end
            in_valid_q[j] <= input_valid_i;
            out_weight_sel_q[j] <= out_weight_sel_i;
          end
        end
      end else begin : gen_col_pipe_nonzero
        always_ff @(posedge clk_i or negedge resetn_i) begin
          if (!resetn_i) begin
            in_valid_q[j] <= 1'b0;
            out_weight_sel_q[j] <= '0;
          end else begin
            if (in_valid_q[j-1]) begin
              ifmap_q[j] <= ifmap_q[j-1];
              blk_sidx_q[j] <= blk_sidx_q[j-1];
            end
            in_valid_q[j] <= in_valid_q[j-1];
            out_weight_sel_q[j] <= out_weight_sel_q[j-1];
          end
        end
      end
    end
  endgenerate
  VX_gemm_weight_regs_v1 #(
      .ROW_SIZE(ROW_SIZE),
      .COL_SIZE(COL_SIZE),
      .WEIGHT_DW(WEIGHT_DW),
      .WEIGHT_LOAD_ROW_NUM(WEIGHT_LOAD_ROW_NUM),
      .WEIGHT_LOAD_COL_NUM(WEIGHT_LOAD_COL_NUM)
  ) u_weight_regs (
      .clk_i(clk_i),
      .weight_i(weight_i),
      .ready_weight_i(ready_weight_i),
      .weight_load_dir_i(weight_load_dir_i),   
      .in_weight_sel_i(in_weight_sel_i),
      .out_weight_sel_i(out_weight_sel_i),
      .weight_o(weights)
  );
  generate
    for (genvar j = 0; j < COL_SIZE / TILE_COL_SIZE; j++) begin : tile_col
      logic [ROW_SIZE-1:0][TILE_COL_SIZE-1:0][WEIGHT_DW-1:0] weight_tile;
      for (genvar r = 0; r < ROW_SIZE; r++) begin : gen_row
        for (genvar c = 0; c < TILE_COL_SIZE; c++) begin : gen_col
          assign weight_tile[r][c] = weights[r][j*TILE_COL_SIZE + c];
        end
      end
      if (j == 0) begin : gen_col_zero
        VX_pe_tree_new #(
            .IN_DW(IN_DW),
            .WEIGHT_DW(WEIGHT_DW),
            .OUT_DW(OUT_DW),
            .BLOCK_SIZE(BLOCK_SIZE),
            .BLOCK_NUM(BLOCK_NUM),
            .SEL_BLOCK_NUM(SEL_BLOCK_NUM),
            .ROW_SIZE(ROW_SIZE),
            .TILE_COL_SIZE(TILE_COL_SIZE),
            .PIPELINE_STAGE_INTV(PIPELINE_STAGE_INTV),
            .PIPE_MULT(PIPE_MULT),
            .PIPE_ALIGN(PIPE_ALIGN)
        ) u_pe (
            .clk_i            (clk_i),
            .resetn_i         (resetn_i),
            .ifmap_i          (ifmap_i),
            .weight_i         (weight_tile),
            .input_valid_i    (input_valid_i),
            .blk_sidx_i       (blk_sidx_i),
            .ps_o             (ps_o[TILE_COL_SIZE*j+:TILE_COL_SIZE]),
            .valid_o          (output_valid_o[j])
        );
      end else begin : gen_col_not_zero
        VX_pe_tree_new #(
            .IN_DW(IN_DW),
            .WEIGHT_DW(WEIGHT_DW),
            .OUT_DW(OUT_DW),
            .BLOCK_SIZE(BLOCK_SIZE),
            .BLOCK_NUM(BLOCK_NUM),
            .SEL_BLOCK_NUM(SEL_BLOCK_NUM),
            .ROW_SIZE(ROW_SIZE),
            .TILE_COL_SIZE(TILE_COL_SIZE),
            .PIPELINE_STAGE_INTV(PIPELINE_STAGE_INTV),
            .PIPE_MULT(PIPE_MULT),
            .PIPE_ALIGN(PIPE_ALIGN)
        ) u_pe (
            .clk_i            (clk_i),
            .resetn_i         (resetn_i),
            .ifmap_i          (ifmap_q[j-1]),
            .weight_i         (weight_tile),
            .input_valid_i    (in_valid_q[j-1]),
            .blk_sidx_i       (blk_sidx_q[j-1]),
            .ps_o             (ps_o[TILE_COL_SIZE*j+:TILE_COL_SIZE]),
            .valid_o          (output_valid_o[j])
        );
      end
    end
  endgenerate
endmodule
