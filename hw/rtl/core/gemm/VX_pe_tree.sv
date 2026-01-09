`timescale 1ns / 1ps

/*
  input is coarse graind blocks
  psum scale will be treated with simple shifter
*/

module VX_pe_tree #(
    parameter  int IN_DW            = -1,
    parameter  int WEIGHT_DW        = -1,
    parameter  int OUT_DW           = -1,
    parameter  int BLOCK_SIZE       = -1,
    parameter  int BLOCK_NUM        = -1,
    parameter  int SEL_BLOCK_NUM    = -1,
    parameter  int TILE_ROW_SIZE    = -1, // this is total row size of gemm_unit
    parameter  int TILE_COL_SIZE    = -1,
    parameter  int WEIGHT_LOAD_ROW  = 1,  // Number of weight rows loaded at once (TILE_ROW_SIZE % WEIGHT_LOAD_ROW == 0)
    parameter  int WEIGHT_LOAD_COL  = 1,  // Number of weight columns loaded at once (TILE_COL_SIZE % WEIGHT_LOAD_COL == 0)
    parameter  int PIPE_MULT        = 0,  // 1 to enable pipelined multiplier
    parameter  int PIPE_ALIGN       = 0,  // 1 to enable pipelined aligner
    parameter  int PIPELINE_STAGES  = 0,  // Bitmask for pipeline stages (e.g., 3'b101 = pipeline stage 0 and 2)
    localparam int BLK_IDX_NUM      = BLOCK_NUM - SEL_BLOCK_NUM + 1,
    localparam int BLK_BITW         = $clog2(BLK_IDX_NUM),
    localparam int NUM_STAGES       = $clog2(TILE_ROW_SIZE) + 1  // Number of adder tree stages
) (
    input logic clk_i,
    input logic [TILE_ROW_SIZE-1:0][IN_DW-1:0] ifmap_i,
    input logic [TILE_COL_SIZE-1:0][WEIGHT_LOAD_ROW-1:0][WEIGHT_DW-1:0] weight_i,
    input logic [TILE_COL_SIZE-1:0][OUT_DW-1:0] ps_i,
    input logic in_weight_sel_i,
    input logic out_weight_sel_i,
    input logic ready_input_i,
    input logic ready_weight_i,
    input logic weight_load_dir_i,  // 0: row direction (top to bottom), 1: column direction (left to right)
    input logic [TILE_ROW_SIZE-1:0][BLK_BITW-1:0] blk_sidx_i,

    output logic [TILE_ROW_SIZE-1:0][BLK_BITW-1:0] blk_sidx_o,
    output logic [TILE_ROW_SIZE-1:0][IN_DW-1:0] ifmap_o,
    output logic [TILE_COL_SIZE-1:0][OUT_DW-1:0] ps_o,
    output logic [TILE_COL_SIZE-1:0][WEIGHT_LOAD_ROW-1:0][WEIGHT_DW-1:0] weight_o
);

  // Static assertion: WEIGHT_LOAD_ROW must equal WEIGHT_LOAD_COL
  initial begin
    if (WEIGHT_LOAD_ROW != WEIGHT_LOAD_COL) begin
      $error("WEIGHT_LOAD_ROW (%0d) must equal WEIGHT_LOAD_COL (%0d)", 
             WEIGHT_LOAD_ROW, WEIGHT_LOAD_COL);
      $finish;
    end
  end

  logic signed [WEIGHT_DW-1:0] mem[TILE_ROW_SIZE-1:0][TILE_COL_SIZE-1:0][1:0];
  logic signed [IN_DW-1:0] signed_ifmap_i[TILE_ROW_SIZE-1:0][TILE_COL_SIZE-1:0];
  logic signed [OUT_DW-1:0] signed_ps_i[TILE_COL_SIZE-1:0];
  logic signed [OUT_DW-1:0] signed_result[TILE_COL_SIZE-1:0];

  function logic signed [OUT_DW-1:0] align_scale(
      input logic signed [IN_DW+(WEIGHT_DW+1)-1:0] in_data,
      input logic [BLK_BITW-1:0] blk_sidx_i);
    logic signed [OUT_DW-1:0] out_data;
    out_data = in_data;
    if (blk_sidx_i > BLK_IDX_NUM) begin
      return 'x;
    end else if (blk_sidx_i <= BLK_IDX_NUM) begin
      return out_data << (BLOCK_SIZE * blk_sidx_i);
    end else begin
      return 'x;
    end
  endfunction

  generate
    for (genvar i = 0; i < TILE_ROW_SIZE; i++) begin : ifrow_nested
      for (genvar j = 0; j < TILE_COL_SIZE; j++) begin : ifcol_nested
        assign signed_ifmap_i[i][j] = $signed(ifmap_i[i]);
      end
    end

    for (genvar i = 0; i < TILE_ROW_SIZE; i++) begin : ifrow
      always_ff @(posedge clk_i) begin
        if (ready_input_i) begin
          ifmap_o[i] <= ifmap_i[i];
          blk_sidx_o[i] <= blk_sidx_i[i];
        end
      end
    end

    for (genvar i = 0; i < TILE_COL_SIZE; i++) begin : ifcol
      // Stage 0: Multiply and scale (input stage)
      logic signed [TILE_ROW_SIZE-1:0][OUT_DW-1:0] stage0_psum;
      
      // Adder tree stages
      // Stage structure: stage[stage_num][element_index]
      logic signed [NUM_STAGES-1:0][TILE_ROW_SIZE-1:0][OUT_DW-1:0] adder_tree_stage;
      logic signed [NUM_STAGES-1:0][TILE_ROW_SIZE-1:0][OUT_DW-1:0] adder_tree_stage_q;
      logic signed [TILE_ROW_SIZE-1:0][IN_DW+(WEIGHT_DW+1)-1:0] curr_psum;
      
      assign signed_ps_i[i] = $signed(ps_i[i]);

      // Stage 0: Multiply, scale, and prepare for adder tree
      if(PIPE_MULT==0) begin
        always_comb begin
          for (int row_offset = 0; row_offset < TILE_ROW_SIZE; row_offset++) begin
            curr_psum[row_offset] = (signed_ifmap_i[row_offset][i] * 
                        signed'({mem[row_offset][i][out_weight_sel_i][WEIGHT_DW-1], 
                                mem[row_offset][i][out_weight_sel_i]}));
          end
        end
      end else begin
        always_ff @(posedge clk_i) begin
          if (ready_input_i) begin
            for (int row_offset = 0; row_offset < TILE_ROW_SIZE; row_offset++) begin
              curr_psum[row_offset] <= (signed_ifmap_i[row_offset][i] * 
                          signed'({mem[row_offset][i][out_weight_sel_i][WEIGHT_DW-1], 
                                  mem[row_offset][i][out_weight_sel_i]}));
            end
          end
        end
      end

      // Scaling stage after multiplication
      if(PIPE_ALIGN==0) begin
        always_comb begin
          for (int row_offset = 0; row_offset < TILE_ROW_SIZE; row_offset++) begin
            stage0_psum[row_offset] = align_scale(curr_psum[row_offset], blk_sidx_i[row_offset]);
          end
        end
      end else begin
        always_ff @(posedge clk_i) begin
          for (int row_offset = 0; row_offset < TILE_ROW_SIZE; row_offset++) begin
            stage0_psum[row_offset] <= align_scale(curr_psum[row_offset], blk_sidx_i[row_offset]);
          end
        end
      end

      // Adder tree: binary tree reduction
      always_comb begin
        // First stage of adder tree (stage 0)
        for (int idx = 0; idx < TILE_ROW_SIZE; idx++) begin
          if (idx < TILE_ROW_SIZE) begin
            adder_tree_stage[0][idx] = stage0_psum[idx];
          end else begin
            adder_tree_stage[0][idx] = '0;
          end
        end
      end
        
      // Subsequent stages: add pairs
      for (genvar stage = 1; stage < NUM_STAGES; stage++) begin
        localparam prev_stage_size = TILE_ROW_SIZE >> (stage - 1);
        localparam curr_stage_size = TILE_ROW_SIZE >> stage;
        
        always_comb begin
          for (int idx_stage = 0; idx_stage < TILE_ROW_SIZE; idx_stage++) begin
            if (idx_stage < curr_stage_size) begin
              if (PIPELINE_STAGES[stage-1]) begin
                adder_tree_stage[stage][idx_stage] = adder_tree_stage_q[stage-1][idx_stage*2] + adder_tree_stage_q[stage-1][idx_stage*2 + 1];
              end else begin
                adder_tree_stage[stage][idx_stage] = adder_tree_stage[stage-1][idx_stage*2] + adder_tree_stage[stage-1][idx_stage*2 + 1];
              end
            end else begin
              adder_tree_stage[stage][idx_stage] = '0;
            end
          end
        end
      end
        
      // Final stage: add ps_i
      always_comb begin
        if (NUM_STAGES > 0) begin
          if (PIPELINE_STAGES[NUM_STAGES-1]) begin
            signed_result[i] = adder_tree_stage_q[NUM_STAGES-1][0] + signed_ps_i[i];
          end else begin
            signed_result[i] = adder_tree_stage[NUM_STAGES-1][0] + signed_ps_i[i];
          end
        end else begin
          signed_result[i] = signed_ps_i[i];
        end
      end

      // Pipeline registers for adder tree stages
      always_ff @(posedge clk_i) begin
        if (ready_input_i) begin
          for (int stage = 0; stage < NUM_STAGES; stage++) begin
            if (PIPELINE_STAGES[stage]) begin
              for (int idx = 0; idx < TILE_ROW_SIZE; idx++) begin
                adder_tree_stage_q[stage][idx] <= adder_tree_stage[stage][idx];
              end
            end
          end
        end
      end

      // Weight memory management - load based on direction
      always_ff @(posedge clk_i) begin
        if (weight_load_dir_i == 0) begin
          // Row direction: load from top to bottom (original behavior)
          for (int row_offset = 0; row_offset < TILE_ROW_SIZE; row_offset++) begin
            if (row_offset < WEIGHT_LOAD_ROW) begin
              // Load new weights for the first WEIGHT_LOAD_ROW rows
              if (ready_weight_i) begin
                mem[row_offset][i][in_weight_sel_i] <= weight_i[i][row_offset];
              end
            end else begin
              // Shift weights from previous rows
              if (ready_weight_i) begin
                mem[row_offset][i][in_weight_sel_i] <= mem[row_offset-WEIGHT_LOAD_ROW][i][in_weight_sel_i];
              end
            end
          end
        end else begin
          // Column direction: load from left to right
          for (int row_offset = 0; row_offset < TILE_ROW_SIZE; row_offset++) begin
            if (i < WEIGHT_LOAD_COL) begin
              // Load new weights for the first WEIGHT_LOAD_COL columns
              if (ready_weight_i) begin
                mem[row_offset][i][in_weight_sel_i] <= weight_i[i][row_offset];
              end
            end else begin
              // Shift weights from previous columns
              if (ready_weight_i) begin
                mem[row_offset][i][in_weight_sel_i] <= mem[row_offset][i-WEIGHT_LOAD_COL][in_weight_sel_i];
              end
            end
          end
        end
      end

      // Output register
      always_ff @(posedge clk_i) begin
        if (ready_input_i) begin
          ps_o[i] <= $unsigned(signed_result[i]);
        end
      end

      // Weight output - output the last WEIGHT_LOAD_ROW rows
      for (genvar w_row = 0; w_row < WEIGHT_LOAD_ROW; w_row++) begin
        assign weight_o[i][w_row] = $unsigned(mem[TILE_ROW_SIZE-WEIGHT_LOAD_ROW+w_row][i][in_weight_sel_i]);
      end
    end

  endgenerate

endmodule
