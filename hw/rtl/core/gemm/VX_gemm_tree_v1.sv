`timescale 1ns / 1ps
`include "VX_define.vh"

module VX_gemm_tree_v1 import VX_gpu_pkg::*; #(
    parameter  int IN_DW                 = `SEL_BLOCK_WIDTH,
    parameter  int WEIGHT_DW             = `W_BIT_WIDTH,
    parameter  int OUT_DW                = `O_BIT_WIDTH,
    parameter  int BLOCK_SIZE            = `BLOCK_SIZE,
    parameter  int BLOCK_NUM             = `BLOCK_NUM,
    parameter  int SEL_BLOCK_NUM         = `SEL_BLOCK_NUM,
    parameter  int ROW_SIZE              = `MXU_ROW,
    parameter  int COL_SIZE              = `MXU_COL,
    parameter  int TILE_COL_SIZE         = `MXU_COL_TILE,
    parameter  int WEIGHT_LOAD_ROW_NUM   = `MXU_WLOAD_NUM,  // Number of weight rows loaded at once (ROW_SIZE % WEIGHT_LOAD_ROW_NUM == 0)
    parameter  int WEIGHT_LOAD_COL_NUM   = `MXU_WLOAD_NUM,  // Number of weight columns loaded at once (COL_SIZE % WEIGHT_LOAD_COL_NUM == 0)
    parameter  int PIPELINE_STAGE_INTV   = `MXU_PIPE_ADD_INTV,  // Pipeline stage interval
    parameter  int PIPE_MULT             = `MXU_PIPE_MUL_EN,  // 1 to enable pipelined multiplier
    parameter  int PIPE_ALIGN            = `MXU_PIPE_ALIGN_EN,  // 1 to enable pipelined aligner
    localparam int BLK_BITW              = `BLOCK_IDX_WIDTH
) (

    input logic clk_i,
    input logic resetn_i,
    input logic [ROW_SIZE-1:0][IN_DW-1:0] ifmap_i,
    input logic [WEIGHT_LOAD_ROW_NUM-1:0][COL_SIZE-1:0][WEIGHT_DW-1:0] weight_i,
    input logic in_weight_sel_i,
    input logic out_weight_sel_i,
    input logic ready_weight_i,
    input logic input_valid_i,
    input logic weight_load_dir_i,  // 0: row direction (top to bottom), 1: column direction (left to right)
    input logic [ROW_SIZE-1:0][BLK_BITW-1:0] blk_sidx_i,

    output logic [COL_SIZE-1:0][OUT_DW-1:0] ps_o,
    output logic [COL_SIZE/TILE_COL_SIZE-1:0] output_valid_o
);

  // Static assertion: WEIGHT_LOAD_ROW_NUM must equal WEIGHT_LOAD_COL_NUM
  `STATIC_ASSERT(WEIGHT_LOAD_ROW_NUM == WEIGHT_LOAD_COL_NUM, ("WEIGHT_LOAD_ROW_NUM (%0d) must equal WEIGHT_LOAD_COL_NUM (%0d)", 
                                                               WEIGHT_LOAD_ROW_NUM, WEIGHT_LOAD_COL_NUM))
  `STATIC_ASSERT(ROW_SIZE == COL_SIZE, ("ROW_SIZE (%0d) must equal COL_SIZE (%0d) for GEMM tree structure", 
                                        ROW_SIZE, COL_SIZE))
  `STATIC_ASSERT(ROW_SIZE % WEIGHT_LOAD_ROW_NUM == 0, ("ROW_SIZE (%0d) must be multiple of WEIGHT_LOAD_ROW_NUM (%0d)", 
                                                       ROW_SIZE, WEIGHT_LOAD_ROW_NUM))
  `STATIC_ASSERT(COL_SIZE%TILE_COL_SIZE == 0, ("COL_SIZE (%0d) must be multiple of TILE_COL_SIZE (%0d)", 
                                               COL_SIZE, TILE_COL_SIZE))

  //internal siganls
  logic [COL_SIZE/TILE_COL_SIZE-1:0][ROW_SIZE-1:0][IN_DW-1:0] ifmap_q;
  logic [COL_SIZE/TILE_COL_SIZE-1:0][ROW_SIZE-1:0][BLK_BITW-1:0] blk_sidx_q;
  
  // Valid and weight_sel signal propagation (column direction)
  logic [COL_SIZE/TILE_COL_SIZE-1:0] in_valid_q;
  logic [COL_SIZE/TILE_COL_SIZE-1:0] out_weight_sel_q;
  
  // Centralized weight registers output
  logic [ROW_SIZE-1:0][COL_SIZE-1:0][WEIGHT_DW-1:0] weights;

  // Pipeline registers for column propagation
  generate
    for (genvar j = 0; j < COL_SIZE / TILE_COL_SIZE; j++) begin : gen_col_pipe
      always_ff @(posedge clk_i or negedge resetn_i) begin
        if (!resetn_i) begin
          in_valid_q[j] <= 1'b0;
          out_weight_sel_q[j] <= 1'b0;
        end else begin
          if (j == 0) begin
            // First column receives inputs directly
            if (input_valid_i) begin
              ifmap_q[j] <= ifmap_i;
              blk_sidx_q[j] <= blk_sidx_i;
            end
            in_valid_q[j] <= input_valid_i;
            out_weight_sel_q[j] <= out_weight_sel_i;
          end else begin
            // Subsequent columns propagate from previous column
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

  // Centralized weight register management
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
      .weight_load_dir_i(weight_load_dir_i),  // Use input directly
      .in_weight_sel_i(in_weight_sel_i),
      .out_weight_sel_i(out_weight_sel_i),
      .weight_o(weights)
  );

  generate
    for (genvar j = 0; j < COL_SIZE / TILE_COL_SIZE; j++) begin : tile_col
      
      // Extract weight tile for this PE
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
            // .ps_i             ('0),
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
            // .ps_i             ('0),
            .input_valid_i    (in_valid_q[j-1]),
            .blk_sidx_i       (blk_sidx_q[j-1]),
            .ps_o             (ps_o[TILE_COL_SIZE*j+:TILE_COL_SIZE]),
            .valid_o          (output_valid_o[j])
        );
      end
    end
  endgenerate

`ifdef DBG_TRACE_GEMM
  always @(posedge clk_i) begin
    if (resetn_i) begin
      // Weight loading event
      if (ready_weight_i) begin
        `TRACE(2, ("%t: GEMM_TREE: Weight load - dir=%0d, in_sel=%0d, out_sel=%0d\n",
            $time, weight_load_dir_i, in_weight_sel_i, out_weight_sel_i))
        `TRACE(4, ("%t: GEMM_TREE: Weight[0][0:3]={0x%0h, 0x%0h, 0x%0h, 0x%0h}\n",
            $time, weight_i[0][0], weight_i[0][1], weight_i[0][2], weight_i[0][3]))
      end

      // Input processing event
      if (input_valid_i) begin
        `TRACE(2, ("%t: GEMM_TREE: Input valid - blk_idx[0]=%0d\n", $time, blk_sidx_i[0]))
        `TRACE(4, ("%t: GEMM_TREE: ifmap[0:3]={0x%0h, 0x%0h, 0x%0h, 0x%0h}\n",
            $time, ifmap_i[0], ifmap_i[1], ifmap_i[2], ifmap_i[3]))
      end

      // Output valid events (per tile)
      for (integer t = 0; t < COL_SIZE/TILE_COL_SIZE; t++) begin
        if (output_valid_o[t]) begin
          `TRACE(2, ("%t: GEMM_TREE: Tile[%0d] output valid - ps[0]=0x%0h\n",
              $time, t, ps_o[t*TILE_COL_SIZE]))
        end
      end
    end
  end
`endif

endmodule
