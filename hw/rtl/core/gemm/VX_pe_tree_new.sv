`timescale 1ns / 1ps
`include "VX_define.vh"

/*
  PE Tree for GEMM operations
  - Receives weights directly from centralized weight registers
  - No internal weight management
  - Focus on MAC operations and adder tree
*/

module VX_pe_tree_new import VX_gpu_pkg::*, VX_utils_pkg::*; #(
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
    // input  logic [TILE_COL_SIZE-1:0][OUT_DW-1:0] ps_i,
    input  logic input_valid_i,
    input  logic [ROW_SIZE-1:0][BLK_BITW-1:0] blk_sidx_i,

    output logic [TILE_COL_SIZE-1:0][OUT_DW-1:0] ps_o,
    output logic valid_o
);

  localparam int MAC_DW = `SIGNED_ALIGNED_MAN_PADDED_FULL_WIDTH + `W_BIT_WIDTH;
  localparam int PIPELINE_STAGES = get_pipe_stage_bitmask(ROW_SIZE, PIPELINE_STAGE_INTV);

  // MAC and Adder Tree for each column
  logic signed [IN_DW-1:0] ifmap_val[TILE_COL_SIZE][ROW_SIZE];
  logic signed [WEIGHT_DW-1:0] weight_val[TILE_COL_SIZE][ROW_SIZE];
  logic [BLK_BITW-1:0] blk_idx[TILE_COL_SIZE][ROW_SIZE];
  // Direct the multiplier into DSP48E2 blocks. Vivado infers A*B in DSP when
  // this attribute is on the product signal declaration. Combined with AREG/BREG
  // from upstream pipelining, MREG may be absorbed into the DSP automatically.
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
      
      // Valid signals for pipeline stages
      // logic valid_mult, valid_align;
      
      // Stage 0: MAC operations
      for (genvar row = 0; row < ROW_SIZE; row++) begin : gen_mac
        // logic signed [IN_DW-1:0] ifmap_val;
        // logic signed [WEIGHT_DW-1:0] weight_val;
        // logic [BLK_BITW-1:0] blk_idx;
        // logic signed [IN_DW+WEIGHT_DW-1:0] product;
        // logic signed [IN_DW+WEIGHT_DW-1:0] product_out;
        // logic [BLK_BITW-1:0] blk_idx_out;
        // logic signed [MAC_DW-1:0] aligned;
        // logic signed [MAC_DW-1:0] aligned_out;
        // logic valid_mult_row, valid_align_row;
        
        assign ifmap_val[col][row] = $signed(ifmap_i[row]);
        assign weight_val[col][row] = $signed(weight_i[row][col]);
        assign blk_idx[col][row] = blk_sidx_i[row];
        
        // Multiply
        assign product[col][row] = ifmap_val[col][row] * weight_val[col][row];
        
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
          .data_in   ({product[col][row], blk_idx[col][row]}),
          .data_out  ({product_out[col][row], blk_idx_out[col][row]}),
          .ready_out (1'b1),
          .valid_out (valid_mult_row[col][row])
        );
        
        // Align (shift) - sign-extend product_out to MAC_DW before shift to avoid overflow
        always_comb begin
          aligned[col][row] = $signed(product_out[col][row]);
          aligned[col][row] = aligned[col][row] << blk_idx_out[col][row];
        end
        
        // Elastic buffer for align output
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
        
        // Use row 0's valid for the entire column
        if (row == 0) begin : gen_valid_assign
          assign valid_mult[col] = valid_mult_row[col][row];
          assign valid_align[col] = valid_align_row[col][row];
        end

        assign mac_results_collected[col][row] = aligned_out[col][row];
      end
      
      // Reduction tree using VX_reduce_tree_pipelined
      always_comb begin
        // Flatten mac_results_collected for reduction tree input
        for (int r = 0; r < ROW_SIZE; r++) begin
          mac_results_collected_flat[col][r] = mac_results_collected[col][r];
        end
      end
      VX_reduce_tree_pipelined_v2 #(
        .IN_W  (MAC_DW),
        .OUT_W (MAC_DW + $clog2(ROW_SIZE)),  // Width increases due to addition
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
      
      // Output stage
      
      // Sign-extend final_sum from MAC_DW to OUT_DW
      assign final_sum_extended[col] = $signed(reduced_sum[col]);
      
      // Add to partial sum from previous PE
      // assign accumulated_result = final_sum_extended + $signed(ps_i[col]);
      assign accumulated_result[col] = final_sum_extended[col]; // No ps_i addition for now
      
      // Output register with valid
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
      
      // Use column 0's valid for output
      if (col == 0) begin : gen_valid_out
        assign valid_o = valid_output[col];
      end
      
    end
  endgenerate

`ifdef DBG_TRACE_GEMM
  always @(posedge clk_i) begin
    if (resetn_i) begin
      // Input processing
      if (input_valid_i) begin
        `TRACE(3, ("%m : [%0t] | PE_TREE_INPUT_VALID | {}\n", $time))
        `TRACE(3, ("%m : [%0t] | PE_TREE_IFMAP | {ifmap=%s}\n",
            $time, VX_utils_pkg::parseWordNoNormal(ifmap_i, ROW_SIZE * IN_DW, IN_DW, "int")))
        `TRACE(3, ("%m : [%0t] | PE_TREE_BLK_IDX | {blk_idx=%s}\n",
            $time, VX_utils_pkg::parseWordNoNormal(blk_sidx_i, ROW_SIZE * BLK_BITW, BLK_BITW, "uint")))
        // `TRACE(4, ("%t: PE_TREE:   ps_i=%s\n",
        //     $time, VX_utils_pkg::parseWordNoNormal(ps_i, TILE_COL_SIZE * OUT_DW, OUT_DW, "int")))
        for (int c = 0; c < TILE_COL_SIZE; c++) begin
          logic [ROW_SIZE-1:0][WEIGHT_DW-1:0] weights_col;
          for (int r = 0; r < ROW_SIZE; r++) begin
            weights_col[r] = weight_i[r][c];
          end
          `TRACE(4, ("%m : [%0t] | PE_TREE_WEIGHT_COL | {col=%0d, weight=%s}\n",
              $time, c, VX_utils_pkg::parseWordNoNormal(weights_col, ROW_SIZE * WEIGHT_DW, WEIGHT_DW, "int")))
        end
      end

      // Output valid
      if (valid_o) begin
        `TRACE(2, ("%m : [%0t] | PE_TREE_OUTPUT_VALID | {}\n", $time))
        `TRACE(2, ("%m : [%0t] | PE_TREE_PS_O | {ps_o=%s}\n",
            $time, VX_utils_pkg::parseWordNoNormal(ps_o, TILE_COL_SIZE * OUT_DW, OUT_DW, "int")))
      end
    end
  end
`endif

endmodule
