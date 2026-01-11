`timescale 1ns / 1ps

/*
  PE Tree for GEMM operations
  - Receives weights directly from centralized weight registers
  - No internal weight management
  - Focus on MAC operations and adder tree
*/

module VX_pe_tree_new #(
    parameter  int IN_DW            = -1,
    parameter  int WEIGHT_DW        = -1,
    parameter  int OUT_DW           = -1,
    parameter  int BLOCK_SIZE       = -1,
    parameter  int BLOCK_NUM        = -1,
    parameter  int SEL_BLOCK_NUM    = -1,
    parameter  int ROW_SIZE         = -1,
    parameter  int TILE_COL_SIZE    = -1,
    parameter  int PIPE_MULT        = 0,
    parameter  int PIPE_ALIGN       = 0,
    parameter  int PIPELINE_STAGES  = 0,
    localparam int BLK_IDX_NUM      = BLOCK_NUM - SEL_BLOCK_NUM + 1,
    localparam int BLK_BITW         = $clog2(BLK_IDX_NUM),
    localparam int NUM_STAGES       = $clog2(ROW_SIZE) + 1
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

  localparam int MAC_DW = IN_DW + WEIGHT_DW + BLK_BITW;

  // Output assignments
  assign valid_o = input_valid_i;

  // MAC and Adder Tree for each column
  generate
    for (genvar col = 0; col < TILE_COL_SIZE; col++) begin : gen_col
      
      // Stage 0: MAC operations
      logic signed [ROW_SIZE-1:0][MAC_DW-1:0] mac_results;
      logic signed [ROW_SIZE-1:0][MAC_DW-1:0] mac_results_q;
      
      for (genvar row = 0; row < ROW_SIZE; row++) begin : gen_mac
        logic signed [IN_DW-1:0] ifmap_val;
        logic signed [WEIGHT_DW-1:0] weight_val;
        logic [BLK_BITW-1:0] blk_idx;
        logic signed [IN_DW+WEIGHT_DW-1:0] product;
        logic signed [MAC_DW-1:0] aligned;
        
        assign ifmap_val = $signed(ifmap_i[row]);
        assign weight_val = $signed(weight_i[row][col]);
        assign blk_idx = blk_sidx_i[row];
        
        if (PIPE_MULT) begin : gen_pipe_mult
          logic signed [IN_DW+WEIGHT_DW-1:0] product_q;
          logic [BLK_BITW-1:0] blk_idx_q;
          
          always_ff @(posedge clk_i) begin
            if (input_valid_i) begin
              product_q <= ifmap_val * weight_val;
              blk_idx_q <= blk_idx;
            end
          end
          
          assign product = product_q;
          assign aligned = (PIPE_ALIGN) ? 
                           (product <<< blk_idx_q) : 
                           (product <<< blk_idx);
        end else begin : gen_no_pipe_mult
          assign product = ifmap_val * weight_val;
          assign aligned = product <<< blk_idx;
        end
        
        if (PIPE_ALIGN && !PIPE_MULT) begin : gen_pipe_align
          logic signed [MAC_DW-1:0] aligned_q;
          always_ff @(posedge clk_i) begin
            if (input_valid_i) begin
              aligned_q <= aligned;
            end
          end
          assign mac_results[row] = aligned_q;
        end else begin : gen_no_pipe_align
          assign mac_results[row] = aligned;
        end
      end
      
      // Pipeline stage 0 results if needed
      if ((PIPELINE_STAGES & 1) != 0) begin : gen_pipe_stage0
        always_ff @(posedge clk_i) begin
          if (input_valid_i) begin
            mac_results_q <= mac_results;
          end
        end
      end else begin : gen_no_pipe_stage0
        assign mac_results_q = mac_results;
      end
      
      // Adder Tree
      logic signed [NUM_STAGES-1:0][ROW_SIZE-1:0][MAC_DW-1:0] adder_tree;
      assign adder_tree[0] = mac_results_q;
      
      for (genvar stage = 1; stage < NUM_STAGES; stage++) begin : gen_stage
        localparam int NUM_ADDERS = ROW_SIZE >> stage;
        
        for (genvar k = 0; k < NUM_ADDERS; k++) begin : gen_adder
          logic signed [MAC_DW-1:0] sum;
          logic signed [MAC_DW-1:0] sum_q;
          
          if (k*2+1 < (ROW_SIZE >> (stage-1))) begin : gen_both_operands
            assign sum = adder_tree[stage-1][k*2] + adder_tree[stage-1][k*2+1];
          end else begin : gen_one_operand
            assign sum = adder_tree[stage-1][k*2];
          end
          
          if ((PIPELINE_STAGES & (1 << stage)) != 0) begin : gen_pipe_adder
            always_ff @(posedge clk_i) begin
              if (input_valid_i) begin
                sum_q <= sum;
              end
            end
            assign adder_tree[stage][k] = sum_q;
          end else begin : gen_no_pipe_adder
            assign adder_tree[stage][k] = sum;
          end
        end
        
        // Unused positions
        for (genvar k = NUM_ADDERS; k < ROW_SIZE; k++) begin : gen_unused
          assign adder_tree[stage][k] = '0;
        end
      end
      
      // Output stage
      logic signed [OUT_DW-1:0] final_sum_extended;
      logic signed [OUT_DW-1:0] accumulated_result;
      
      // Sign-extend final_sum from MAC_DW to OUT_DW
      assign final_sum_extended = $signed(adder_tree[NUM_STAGES-1][0]);
      
      // Add to partial sum from previous PE
      assign accumulated_result = final_sum_extended + $signed(ps_i[col]);
      
      always_ff @(posedge clk_i) begin
        if (input_valid_i) begin
          ps_o[col] <= $unsigned(accumulated_result);
        end
      end
      
    end
  endgenerate

`ifdef DBG_TRACE_GEMM
  always @(posedge clk_i) begin
    if (input_valid_i) begin
      `TRACE(3, ("%t: PE_TREE: Processing input\n", $time))
      // Show first two inputs and weights for debugging
      for (integer r = 0; r < 2; r++) begin
        `TRACE(3, ("  ifmap_i[%0d]=0x%0h, blk_sidx_i[%0d]=%0d\n", r, ifmap_i[r], r, blk_sidx_i[r]))
        for (integer c = 0; c < 2; c++) begin
          `TRACE(3, ("    weight_i[%0d][%0d]=0x%0h\n", r, c, weight_i[r][c]))
        end
      end
    end
  end
`endif

endmodule
