`timescale 1ns / 1ps

module gemm_tree #(
    parameter  int IN_DW              = 16,
    parameter  int WEIGHT_DW          = 4,
    parameter  int OUT_DW             = 41,
    parameter  int BLOCK_SIZE         = 5,
    parameter  int BLOCK_NUM          = 6,
    parameter  int SEL_BLOCK_NUM      = 3,
    parameter  int ROW_SIZE           = 32,
    parameter  int COL_SIZE           = 32,
    parameter  int TILE_COL_SIZE      = 32,
    parameter  int WEIGHT_LOAD_ROW_NUM = 1,  // Number of weight rows loaded at once (ROW_SIZE % WEIGHT_LOAD_ROW_NUM == 0)
    parameter  int PIPE_MULT          = 1,  // 1 to enable pipelined multiplier
    parameter  int PIPE_ALIGN         = 1,  // 1 to enable pipelined aligner
    localparam int TILE_ROW_SIZE      = ROW_SIZE,
    localparam int BLK_IDX_NUM        = BLOCK_NUM - SEL_BLOCK_NUM + 1,
    localparam int BLK_BITW           = $clog2(BLK_IDX_NUM),
    localparam int PIPE_INTERVAL      = 2  // Pipeline every N stages
) (

    input logic clk_i,
    input logic [ROW_SIZE-1:0][IN_DW-1:0] ifmap_i,
    input logic [COL_SIZE-1:0][WEIGHT_LOAD_ROW_NUM-1:0][WEIGHT_DW-1:0] weight_i,
    input logic in_weight_sel_i,
    input logic out_weight_sel_i,
    input logic ready_weight_i,
    input logic ready_input_i,
    input logic [ROW_SIZE-1:0][BLK_BITW-1:0] blk_sidx_i,

    output logic [COL_SIZE-1:0][OUT_DW-1:0] ps_o
);

  //internal siganls
  logic [COL_SIZE/TILE_COL_SIZE-1:0][ROW_SIZE-1:0][IN_DW-1:0] ifmap_q;
  logic [COL_SIZE/TILE_COL_SIZE-1:0][ROW_SIZE-1:0][BLK_BITW-1:0] blk_sidx_q;
  logic [ROW_SIZE/TILE_ROW_SIZE-1:0][COL_SIZE-1:0][WEIGHT_LOAD_ROW_NUM-1:0][WEIGHT_DW-1:0] weight_q;
  logic [ROW_SIZE/TILE_ROW_SIZE-1:0][COL_SIZE-1:0][OUT_DW-1:0] ps_q;

  function automatic int get_pipe_stage(int row_size);
    int num_stages;
    int pipe_stages;
    
    // Calculate number of adder tree stages
    // NUM_STAGES = $clog2(TILE_ROW_SIZE) + 1
    num_stages = $clog2(row_size) + 1;
    
    // Generate bitmask: set bit to 1 every PIPE_INTERVAL stages
    pipe_stages = 0;
    for (int i = 0; i < num_stages; i++) begin
      if (i % PIPE_INTERVAL == 0) begin
        pipe_stages = pipe_stages | (1 << i);
      end
    end
    
    return pipe_stages;
  endfunction

  generate
    for (genvar i = 0; i < ROW_SIZE / TILE_ROW_SIZE; i++) begin : tile_row
      for (genvar j = 0; j < COL_SIZE / TILE_COL_SIZE; j++) begin : tile_col
        if (i == 0) begin : trz
          if (j == 0) begin : tcz
            pe_tree #(
                .IN_DW(IN_DW),
                .WEIGHT_DW(WEIGHT_DW),
                .OUT_DW(OUT_DW),
                .BLOCK_SIZE(BLOCK_SIZE),
                .BLOCK_NUM(BLOCK_NUM),
                .SEL_BLOCK_NUM(SEL_BLOCK_NUM),
                .TILE_ROW_SIZE(TILE_ROW_SIZE),
                .TILE_COL_SIZE(TILE_COL_SIZE),
                .WEIGHT_LOAD_ROW(WEIGHT_LOAD_ROW_NUM),
                .PIPELINE_STAGES(get_pipe_stage(TILE_ROW_SIZE)),
                .PIPE_MULT(PIPE_MULT),
                .PIPE_ALIGN(PIPE_ALIGN)
            ) u_pe (
                .clk_i           (clk_i),
                .ifmap_i         (ifmap_i[TILE_ROW_SIZE*i+:TILE_ROW_SIZE]),
                .weight_i        (weight_i[TILE_COL_SIZE*j+:TILE_COL_SIZE]),
                .ps_i            ('0),
                .in_weight_sel_i (in_weight_sel_i),
                .out_weight_sel_i(out_weight_sel_i),
                .ready_input_i   (ready_input_i),
                .ready_weight_i  (ready_weight_i),
                .blk_sidx_i      (blk_sidx_i[TILE_ROW_SIZE*i+:TILE_ROW_SIZE]),
                .blk_sidx_o      (blk_sidx_q[j][TILE_ROW_SIZE*i+:TILE_ROW_SIZE]),
                .ifmap_o         (ifmap_q[j][TILE_ROW_SIZE*i+:TILE_ROW_SIZE]),
                .ps_o            (ps_q[i][TILE_COL_SIZE*j+:TILE_COL_SIZE]),
                .weight_o        (weight_q[i][TILE_COL_SIZE*j+:TILE_COL_SIZE])
            );
          end else begin : tcnz
            pe_tree #(
                .IN_DW(IN_DW),
                .WEIGHT_DW(WEIGHT_DW),
                .OUT_DW(OUT_DW),
                .BLOCK_SIZE(BLOCK_SIZE),
                .BLOCK_NUM(BLOCK_NUM),
                .SEL_BLOCK_NUM(SEL_BLOCK_NUM),
                .TILE_ROW_SIZE(TILE_ROW_SIZE),
                .TILE_COL_SIZE(TILE_COL_SIZE),
                .WEIGHT_LOAD_ROW(WEIGHT_LOAD_ROW_NUM),
                .PIPELINE_STAGES(get_pipe_stage(TILE_ROW_SIZE)),
                .PIPE_MULT(PIPE_MULT),
                .PIPE_ALIGN(PIPE_ALIGN)
            ) u_pe (
                .clk_i           (clk_i),
                .ifmap_i         (ifmap_q[j-1][TILE_ROW_SIZE*i+:TILE_ROW_SIZE]),
                .weight_i        (weight_i[TILE_COL_SIZE*j+:TILE_COL_SIZE]),
                .ps_i            ('0),
                .in_weight_sel_i (in_weight_sel_i),
                .out_weight_sel_i(out_weight_sel_i),
                .ready_input_i   (ready_input_i),
                .ready_weight_i  (ready_weight_i),
                .blk_sidx_i      (blk_sidx_q[j-1][TILE_ROW_SIZE*i+:TILE_ROW_SIZE]),
                .blk_sidx_o      (blk_sidx_q[j][TILE_ROW_SIZE*i+:TILE_ROW_SIZE]),
                .ifmap_o         (ifmap_q[j][TILE_ROW_SIZE*i+:TILE_ROW_SIZE]),
                .ps_o            (ps_q[i][TILE_COL_SIZE*j+:TILE_COL_SIZE]),
                .weight_o        (weight_q[i][TILE_COL_SIZE*j+:TILE_COL_SIZE])
            );
          end
        end else begin : trnz
          if (j == 0) begin : tcz
            pe_tree #(
                .IN_DW(IN_DW),
                .WEIGHT_DW(WEIGHT_DW),
                .OUT_DW(OUT_DW),
                .BLOCK_SIZE(BLOCK_SIZE),
                .BLOCK_NUM(BLOCK_NUM),
                .SEL_BLOCK_NUM(SEL_BLOCK_NUM),
                .TILE_ROW_SIZE(TILE_ROW_SIZE),
                .TILE_COL_SIZE(TILE_COL_SIZE),
                .WEIGHT_LOAD_ROW(WEIGHT_LOAD_ROW_NUM),
                .PIPELINE_STAGES(get_pipe_stage(TILE_ROW_SIZE)),
                .PIPE_MULT(PIPE_MULT),
                .PIPE_ALIGN(PIPE_ALIGN)
            ) u_pe (
                .clk_i           (clk_i),
                .ifmap_i         (ifmap_i[TILE_ROW_SIZE*i+:TILE_ROW_SIZE]),
                .weight_i        (weight_q[i-1][TILE_COL_SIZE*j+:TILE_COL_SIZE]),
                .ps_i            (ps_q[i-1][TILE_COL_SIZE*j+:TILE_COL_SIZE]),
                .in_weight_sel_i (in_weight_sel_i),
                .out_weight_sel_i(out_weight_sel_i),
                .ready_input_i   (ready_input_i),
                .ready_weight_i  (ready_weight_i),
                .blk_sidx_i      (blk_sidx_i[TILE_ROW_SIZE*i+:TILE_ROW_SIZE]),
                .blk_sidx_o      (blk_sidx_q[j][TILE_ROW_SIZE*i+:TILE_ROW_SIZE]),
                .ifmap_o         (ifmap_q[j][TILE_ROW_SIZE*i+:TILE_ROW_SIZE]),
                .ps_o            (ps_q[i][TILE_COL_SIZE*j+:TILE_COL_SIZE]),
                .weight_o        (weight_q[i][TILE_COL_SIZE*j+:TILE_COL_SIZE])
            );
          end else begin : tcnz
            pe_tree #(
                .IN_DW(IN_DW),
                .WEIGHT_DW(WEIGHT_DW),
                .OUT_DW(OUT_DW),
                .BLOCK_SIZE(BLOCK_SIZE),
                .BLOCK_NUM(BLOCK_NUM),
                .SEL_BLOCK_NUM(SEL_BLOCK_NUM),
                .TILE_ROW_SIZE(TILE_ROW_SIZE),
                .TILE_COL_SIZE(TILE_COL_SIZE),
                .WEIGHT_LOAD_ROW(WEIGHT_LOAD_ROW_NUM),
                .PIPELINE_STAGES(get_pipe_stage(TILE_ROW_SIZE)),
                .PIPE_MULT(PIPE_MULT),
                .PIPE_ALIGN(PIPE_ALIGN)
            ) u_pe (
                .clk_i           (clk_i),
                .ifmap_i         (ifmap_q[j-1][TILE_ROW_SIZE*i+:TILE_ROW_SIZE]),
                .weight_i        (weight_q[i-1][TILE_COL_SIZE*j+:TILE_COL_SIZE]),
                .ps_i            (ps_q[i-1][TILE_COL_SIZE*j+:TILE_COL_SIZE]),
                .in_weight_sel_i (in_weight_sel_i),
                .out_weight_sel_i(out_weight_sel_i),
                .ready_input_i   (ready_input_i),
                .ready_weight_i  (ready_weight_i),
                .blk_sidx_i      (blk_sidx_q[j-1][TILE_ROW_SIZE*i+:TILE_ROW_SIZE]),
                .blk_sidx_o      (blk_sidx_q[j][TILE_ROW_SIZE*i+:TILE_ROW_SIZE]),
                .ifmap_o         (ifmap_q[j][TILE_ROW_SIZE*i+:TILE_ROW_SIZE]),
                .ps_o            (ps_q[i][TILE_COL_SIZE*j+:TILE_COL_SIZE]),
                .weight_o        (weight_q[i][TILE_COL_SIZE*j+:TILE_COL_SIZE])
            );
          end
        end
      end
    end
  endgenerate

  assign ps_o = ps_q[ROW_SIZE/TILE_ROW_SIZE-1];

endmodule
