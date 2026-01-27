`timescale 1ns / 1ps

module VX_gemm_tree_v1 #(
    parameter  int IN_DW                 = `IFP_WIDTH,
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
    parameter  int PIPELINE_STAGES       = 2,  // Pipeline every N stages
    parameter  int PIPE_MULT             = 1,  // 1 to enable pipelined multiplier
    parameter  int PIPE_ALIGN            = 1,  // 1 to enable pipelined aligner
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
  initial begin
    if (WEIGHT_LOAD_ROW_NUM != WEIGHT_LOAD_COL_NUM) begin
      $error("WEIGHT_LOAD_ROW_NUM (%0d) must equal WEIGHT_LOAD_COL_NUM (%0d)", 
             WEIGHT_LOAD_ROW_NUM, WEIGHT_LOAD_COL_NUM);
      $finish;
    end
  end

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
            .PIPELINE_STAGES(PIPELINE_STAGES),
            .PIPE_MULT(PIPE_MULT),
            .PIPE_ALIGN(PIPE_ALIGN)
        ) u_pe (
            .clk_i            (clk_i),
            .resetn_i         (resetn_i),
            .ifmap_i          (ifmap_i),
            .weight_i         (weight_tile),
            .ps_i             ('0),
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
            .PIPELINE_STAGES(PIPELINE_STAGES),
            .PIPE_MULT(PIPE_MULT),
            .PIPE_ALIGN(PIPE_ALIGN)
        ) u_pe (
            .clk_i            (clk_i),
            .resetn_i         (resetn_i),
            .ifmap_i          (ifmap_q[j-1]),
            .weight_i         (weight_tile),
            .ps_i             ('0),
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
    if (ready_weight_i) begin
      `TRACE(3, ("%t: GEMM_TREE: Weight loading dir=%0d\n", $time, weight_load_dir_i))
    end
    
    if (input_valid_i) begin
      `TRACE(3, ("%t: GEMM_TREE: Input processing\n", $time))
    end
  end
`endif

endmodule
