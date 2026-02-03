`timescale 1ns / 1ps
`include "VX_define.vh"

/*
  PE Tree for GEMM operations
  - Receives weights directly from centralized weight registers
  - No internal weight management
  - Focus on MAC operations and adder tree
*/

module VX_pe_tree_new import VX_gpu_pkg::*; #(
    parameter  int IN_DW                = `SEL_BLOCK_WIDTH,
    parameter  int WEIGHT_DW            = `W_BIT_WIDTH,
    parameter  int OUT_DW               = `O_BIT_WIDTH,
    parameter  int BLOCK_SIZE           = `BLOCK_SIZE,
    parameter  int BLOCK_NUM            = `BLOCK_NUM,
    parameter  int SEL_BLOCK_NUM        = `SEL_BLOCK_NUM,
    parameter  int ROW_SIZE             = `MXU_ROW,
    parameter  int TILE_COL_SIZE        = `MXU_COL_TILE,
    parameter  int PIPE_MULT            = `MXU_PIPE_MUL_EN,
    parameter  int PIPE_ALIGN           = `MXU_PIPE_ALIGN_EN,
    parameter  int PIPELINE_STAGE_INTV  = `MXU_PIPE_ADD_INTV,
    localparam int BLK_IDX_NUM          = BLOCK_NUM - SEL_BLOCK_NUM + 1,
    localparam int BLK_BITW             = $clog2(BLK_IDX_NUM)
) (
    input  logic clk_i,
    input  logic resetn_i,
    input  logic [ROW_SIZE-1:0][IN_DW-1:0] ifmap_i,
    input  logic [ROW_SIZE-1:0][TILE_COL_SIZE-1:0][WEIGHT_DW-1:0] weight_i,  // Changed: direct weight input
    input  logic [TILE_COL_SIZE-1:0][OUT_DW-1:0] ps_i,
    input  logic input_valid_i,
    input  logic [ROW_SIZE-1:0][BLK_BITW-1:0] blk_sidx_i,

    output logic [TILE_COL_SIZE-1:0][OUT_DW-1:0] ps_o,
    output logic valid_o
);

  localparam int MAC_DW = `ALIGNED_MAN_PADDED_FULL_WIDTH + `W_BIT_WIDTH;
  localparam int PIPELINE_STAGES = get_pipe_stage_bitmask(ROW_SIZE, PIPELINE_STAGE_INTV);

  // MAC and Adder Tree for each column
  generate
    for (genvar col = 0; col < TILE_COL_SIZE; col++) begin : gen_col
      
      // Valid signals for pipeline stages
      logic valid_mult, valid_align;
      
      // Stage 0: MAC operations
      for (genvar row = 0; row < ROW_SIZE; row++) begin : gen_mac
        logic signed [IN_DW-1:0] ifmap_val;
        logic signed [WEIGHT_DW-1:0] weight_val;
        logic [BLK_BITW-1:0] blk_idx;
        logic signed [IN_DW+WEIGHT_DW-1:0] product;
        logic signed [IN_DW+WEIGHT_DW-1:0] product_out;
        logic [BLK_BITW-1:0] blk_idx_out;
        logic signed [MAC_DW-1:0] aligned;
        logic signed [MAC_DW-1:0] aligned_out;
        logic valid_mult_row, valid_align_row;
        
        assign ifmap_val = $signed(ifmap_i[row]);
        assign weight_val = $signed(weight_i[row][col]);
        assign blk_idx = blk_sidx_i[row];
        
        // Multiply
        assign product = ifmap_val * weight_val;
        
        // Elastic buffer for multiplier output (includes blk_idx for align stage)
        VX_elastic_buffer #(
          .DATAW   (IN_DW+WEIGHT_DW+BLK_BITW),
          .SIZE    (PIPE_MULT),
          .OUT_REG (PIPE_MULT)
        ) mult_buffer (
          .clk       (clk_i),
          .reset     (~resetn_i),
          .valid_in  (input_valid_i),
          .ready_in  (),
          .data_in   ({product, blk_idx}),
          .data_out  ({product_out, blk_idx_out}),
          .ready_out (1'b1),
          .valid_out (valid_mult_row)
        );
        
        // Align (shift)
        assign aligned = product_out <<< blk_idx_out;
        
        // Elastic buffer for align output
        VX_elastic_buffer #(
          .DATAW   (MAC_DW),
          .SIZE    (PIPE_ALIGN),
          .OUT_REG (PIPE_ALIGN)
        ) align_buffer (
          .clk       (clk_i),
          .reset     (~resetn_i),
          .valid_in  (valid_mult_row),
          .ready_in  (),
          .data_in   (aligned),
          .data_out  (aligned_out),
          .ready_out (1'b1),
          .valid_out (valid_align_row)
        );
        
        // Use row 0's valid for the entire column
        if (row == 0) begin : gen_valid_assign
          assign valid_mult = valid_mult_row;
          assign valid_align = valid_align_row;
        end
      end
      
      // Collect MAC results for reduction
      logic signed [ROW_SIZE-1:0][MAC_DW-1:0] mac_results_collected;
      for (genvar row = 0; row < ROW_SIZE; row++) begin : gen_collect
        assign mac_results_collected[row] = gen_mac[row].aligned_out;
      end
      
      // Reduction tree using VX_reduce_tree_pipelined
      logic signed [MAC_DW-1:0] reduced_sum;
      logic valid_reduced;
      VX_reduce_tree_pipelined_v2 #(
        .IN_W  (MAC_DW),
        .OUT_W (MAC_DW),
        .N     (ROW_SIZE),
        .OP    ("+"),
        .PIPELINE_STAGES (PIPELINE_STAGES),
        .EB_SIZE (1),
        .EB_OUT_REG (1)
      ) reduce_tree (
        .clk       (clk_i),
        .reset     (~resetn_i),
        .data_in   (mac_results_collected),
        .valid_in  (valid_align),
        .data_out  (reduced_sum),
        .valid_out (valid_reduced)
      );
      
      // Output stage
      logic signed [OUT_DW-1:0] final_sum_extended;
      logic signed [OUT_DW-1:0] accumulated_result;
      logic valid_output;
      
      // Sign-extend final_sum from MAC_DW to OUT_DW
      assign final_sum_extended = $signed(reduced_sum);
      
      // Add to partial sum from previous PE
      assign accumulated_result = final_sum_extended + $signed(ps_i[col]);
      
      // Output register with valid
      always_ff @(posedge clk_i or negedge resetn_i) begin
        if (!resetn_i) begin
          ps_o[col] <= '0;
          valid_output <= 1'b0;
        end else begin
          if (valid_reduced) begin
            ps_o[col] <= $unsigned(accumulated_result);
          end
          valid_output <= valid_reduced;
        end
      end
      
      // Use column 0's valid for output
      if (col == 0) begin : gen_valid_out
        assign valid_o = valid_output;
      end
      
    end
  endgenerate

`ifdef DBG_TRACE_GEMM
  always @(posedge clk_i) begin
    if (resetn_i) begin
      // Input processing
      if (input_valid_i) begin
        `TRACE(3, ("%t: PE_TREE: Input valid\n", $time))
        `TRACE(3, ("%t: PE_TREE:   ifmap=%s\n",
            $time, parseWordNoNormal(ifmap_i, ROW_SIZE * IN_DW, IN_DW, "int")))
        `TRACE(3, ("%t: PE_TREE:   blk_idx=%s\n",
            $time, parseWordNoNormal(blk_sidx_i, ROW_SIZE * BLK_BITW, BLK_BITW, "uint")))
        `TRACE(4, ("%t: PE_TREE:   ps_i=%s\n",
            $time, parseWordNoNormal(ps_i, TILE_COL_SIZE * OUT_DW, OUT_DW, "int")))
        for (int c = 0; c < TILE_COL_SIZE; c++) begin
          logic [ROW_SIZE-1:0][WEIGHT_DW-1:0] weights_col;
          for (int r = 0; r < ROW_SIZE; r++) begin
            weights_col[r] = weight_i[r][c];
          end
          `TRACE(4, ("%t: PE_TREE:   weight[col=%0d]=%s\n",
              $time, c, parseWordNoNormal(weights_col, ROW_SIZE * WEIGHT_DW, WEIGHT_DW, "int")))
        end
      end

      // Output valid
      if (valid_o) begin
        `TRACE(2, ("%t: PE_TREE: Output valid\n", $time))
        `TRACE(2, ("%t: PE_TREE:   ps_o=%s\n",
            $time, parseWordNoNormal(ps_o, TILE_COL_SIZE * OUT_DW, OUT_DW, "int")))
      end
    end
  end
`endif

endmodule
