`timescale 1ns / 1ps

module VX_gemm_tree #(
    parameter  int IN_DW               = `IFP_WIDTH,
    parameter  int WEIGHT_DW           = `W_BIT_WIDTH,
    parameter  int OUT_DW              = `O_BIT_WIDTH,
    parameter  int BLOCK_SIZE          = `BLOCK_SIZE,
    parameter  int BLOCK_NUM           = `BLOCK_NUM,
    parameter  int SEL_BLOCK_NUM       = `SEL_BLOCK_NUM,
    parameter  int ROW_SIZE            = 32,
    parameter  int COL_SIZE            = 32,
    parameter  int TILE_COL_SIZE       = 32,
    parameter  int WEIGHT_LOAD_ROW_NUM = 1,  // Number of weight rows loaded at once (ROW_SIZE % WEIGHT_LOAD_ROW_NUM == 0)
    parameter  int WEIGHT_LOAD_COL_NUM = 1,  // Number of weight columns loaded at once (COL_SIZE % WEIGHT_LOAD_COL_NUM == 0)
    parameter  int PIPE_INTERVAL       = 2,  // Pipeline every N stages
    parameter  int PIPE_MULT           = 1,  // 1 to enable pipelined multiplier
    parameter  int PIPE_ALIGN          = 1,  // 1 to enable pipelined aligner
    localparam int BLK_BITW            = `BLOCK_IDX_WIDTH
) (

    input logic clk_i,
    input logic [ROW_SIZE-1:0][IN_DW-1:0] ifmap_i,
    input logic [COL_SIZE-1:0][WEIGHT_LOAD_ROW_NUM-1:0][WEIGHT_DW-1:0] weight_i,
    input logic in_weight_sel_i,
    input logic out_weight_sel_i,
    input logic ready_weight_i,
    input logic input_valid_i,
    input logic weight_load_dir_i,  // 0: row direction (top to bottom), 1: column direction (left to right)
    input logic [ROW_SIZE-1:0][BLK_BITW-1:0] blk_sidx_i,

    output logic [COL_SIZE-1:0][OUT_DW-1:0] ps_o
);

  localparam int TILE_ROW_SIZE      = ROW_SIZE;

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
  logic [ROW_SIZE/TILE_ROW_SIZE-1:0][COL_SIZE-1:0][WEIGHT_LOAD_ROW_NUM-1:0][WEIGHT_DW-1:0] weight_q;
  logic [ROW_SIZE/TILE_ROW_SIZE-1:0][COL_SIZE-1:0][OUT_DW-1:0] ps_q;
  
  // Valid and weight_sel signal propagation (column direction)
  logic [COL_SIZE/TILE_COL_SIZE-1:0] valid_q;
  logic [COL_SIZE/TILE_COL_SIZE-1:0] in_weight_sel_q;
  logic [COL_SIZE/TILE_COL_SIZE-1:0] out_weight_sel_q;
  logic [COL_SIZE/TILE_COL_SIZE-1:0] weight_load_dir_q;
  
  // Centralized weight registers output
  logic [ROW_SIZE-1:0][COL_SIZE-1:0][WEIGHT_DW-1:0] weights;

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

  // Centralized weight register management
  VX_gemm_weight_regs #(
      .ROW_SIZE(ROW_SIZE),
      .COL_SIZE(COL_SIZE),
      .WEIGHT_DW(WEIGHT_DW),
      .WEIGHT_LOAD_ROW_NUM(WEIGHT_LOAD_ROW_NUM),
      .WEIGHT_LOAD_COL_NUM(WEIGHT_LOAD_COL_NUM)
  ) u_weight_regs (
      .clk_i(clk_i),
      .weight_i(weight_i),
      .ready_weight_i(ready_weight_i),
      .weight_load_dir_i(weight_load_dir_q[COL_SIZE/TILE_COL_SIZE-1]),  // Use propagated signal from last column
      .in_weight_sel_i(in_weight_sel_i),  // Input directly from top
      .out_weight_sel_i(out_weight_sel_i),
      .weight_o(weights)
  );

  generate
    for (genvar i = 0; i < ROW_SIZE / TILE_ROW_SIZE; i++) begin : tile_row
      for (genvar j = 0; j < COL_SIZE / TILE_COL_SIZE; j++) begin : tile_col
        
        // Extract weight tile for this PE
        logic [TILE_ROW_SIZE-1:0][TILE_COL_SIZE-1:0][WEIGHT_DW-1:0] weight_tile;
        
        for (genvar r = 0; r < TILE_ROW_SIZE; r++) begin : gen_row
          for (genvar c = 0; c < TILE_COL_SIZE; c++) begin : gen_col
            assign weight_tile[r][c] = weights[i*TILE_ROW_SIZE + r][j*TILE_COL_SIZE + c];
          end
        end
        
        if (i == 0) begin : trz
          if (j == 0) begin : tcz
            VX_pe_tree_new #(
                .IN_DW(IN_DW),
                .WEIGHT_DW(WEIGHT_DW),
                .OUT_DW(OUT_DW),
                .BLOCK_SIZE(BLOCK_SIZE),
                .BLOCK_NUM(BLOCK_NUM),
                .SEL_BLOCK_NUM(SEL_BLOCK_NUM),
                .TILE_ROW_SIZE(TILE_ROW_SIZE),
                .TILE_COL_SIZE(TILE_COL_SIZE),
                .PIPELINE_STAGES(get_pipe_stage(TILE_ROW_SIZE)),
                .PIPE_MULT(PIPE_MULT),
                .PIPE_ALIGN(PIPE_ALIGN)
            ) u_pe (
                .clk_i            (clk_i),
                .ifmap_i          (ifmap_i[TILE_ROW_SIZE*i+:TILE_ROW_SIZE]),
                .weight_i         (weight_tile),
                .ps_i             ('0),
                .input_valid_i    (input_valid_i),
                .in_weight_sel_i  (in_weight_sel_i),
                .out_weight_sel_i (out_weight_sel_i),
                .weight_load_dir_i(weight_load_dir_i),
                .blk_sidx_i       (blk_sidx_i[TILE_ROW_SIZE*i+:TILE_ROW_SIZE]),
                .blk_sidx_o       (blk_sidx_q[j][TILE_ROW_SIZE*i+:TILE_ROW_SIZE]),
                .ifmap_o          (ifmap_q[j][TILE_ROW_SIZE*i+:TILE_ROW_SIZE]),
                .ps_o             (ps_q[i][TILE_COL_SIZE*j+:TILE_COL_SIZE]),
                .valid_o          (valid_q[j]),
                .in_weight_sel_o  (in_weight_sel_q[j]),
                .out_weight_sel_o (out_weight_sel_q[j]),
                .weight_load_dir_o(weight_load_dir_q[j])
            );
          end else begin : tcnz
            VX_pe_tree_new #(
                .IN_DW(IN_DW),
                .WEIGHT_DW(WEIGHT_DW),
                .OUT_DW(OUT_DW),
                .BLOCK_SIZE(BLOCK_SIZE),
                .BLOCK_NUM(BLOCK_NUM),
                .SEL_BLOCK_NUM(SEL_BLOCK_NUM),
                .TILE_ROW_SIZE(TILE_ROW_SIZE),
                .TILE_COL_SIZE(TILE_COL_SIZE),
                .PIPELINE_STAGES(get_pipe_stage(TILE_ROW_SIZE)),
                .PIPE_MULT(PIPE_MULT),
                .PIPE_ALIGN(PIPE_ALIGN)
            ) u_pe (
                .clk_i            (clk_i),
                .ifmap_i          (ifmap_q[j-1][TILE_ROW_SIZE*i+:TILE_ROW_SIZE]),
                .weight_i         (weight_tile),
                .ps_i             ('0),
                .input_valid_i    (valid_q[j-1]),
                .in_weight_sel_i  (in_weight_sel_q[j-1]),
                .out_weight_sel_i (out_weight_sel_q[j-1]),
                .weight_load_dir_i(weight_load_dir_q[j-1]),
                .blk_sidx_i       (blk_sidx_q[j-1][TILE_ROW_SIZE*i+:TILE_ROW_SIZE]),
                .blk_sidx_o       (blk_sidx_q[j][TILE_ROW_SIZE*i+:TILE_ROW_SIZE]),
                .ifmap_o          (ifmap_q[j][TILE_ROW_SIZE*i+:TILE_ROW_SIZE]),
                .ps_o             (ps_q[i][TILE_COL_SIZE*j+:TILE_COL_SIZE]),
                .valid_o          (valid_q[j]),
                .in_weight_sel_o  (in_weight_sel_q[j]),
                .out_weight_sel_o (out_weight_sel_q[j]),
                .weight_load_dir_o(weight_load_dir_q[j])
            );
          end
        end else begin : trnz
          if (j == 0) begin : tcz
            VX_pe_tree_new #(
                .IN_DW(IN_DW),
                .WEIGHT_DW(WEIGHT_DW),
                .OUT_DW(OUT_DW),
                .BLOCK_SIZE(BLOCK_SIZE),
                .BLOCK_NUM(BLOCK_NUM),
                .SEL_BLOCK_NUM(SEL_BLOCK_NUM),
                .TILE_ROW_SIZE(TILE_ROW_SIZE),
                .TILE_COL_SIZE(TILE_COL_SIZE),
                .PIPELINE_STAGES(get_pipe_stage(TILE_ROW_SIZE)),
                .PIPE_MULT(PIPE_MULT),
                .PIPE_ALIGN(PIPE_ALIGN)
            ) u_pe (
                .clk_i            (clk_i),
                .ifmap_i          (ifmap_i[TILE_ROW_SIZE*i+:TILE_ROW_SIZE]),
                .weight_i         (weight_tile),
                .ps_i             (ps_q[i-1][TILE_COL_SIZE*j+:TILE_COL_SIZE]),
                .input_valid_i    (input_valid_i),
                .in_weight_sel_i  (in_weight_sel_i),
                .out_weight_sel_i (out_weight_sel_i),
                .weight_load_dir_i(weight_load_dir_i),
                .blk_sidx_i       (blk_sidx_i[TILE_ROW_SIZE*i+:TILE_ROW_SIZE]),
                .blk_sidx_o       (blk_sidx_q[j][TILE_ROW_SIZE*i+:TILE_ROW_SIZE]),
                .ifmap_o          (ifmap_q[j][TILE_ROW_SIZE*i+:TILE_ROW_SIZE]),
                .ps_o             (ps_q[i][TILE_COL_SIZE*j+:TILE_COL_SIZE]),
                .valid_o          (valid_q[j]),
                .in_weight_sel_o  (in_weight_sel_q[j]),
                .out_weight_sel_o (out_weight_sel_q[j]),
                .weight_load_dir_o(weight_load_dir_q[j])
            );
          end else begin : tcnz
            VX_pe_tree_new #(
                .IN_DW(IN_DW),
                .WEIGHT_DW(WEIGHT_DW),
                .OUT_DW(OUT_DW),
                .BLOCK_SIZE(BLOCK_SIZE),
                .BLOCK_NUM(BLOCK_NUM),
                .SEL_BLOCK_NUM(SEL_BLOCK_NUM),
                .TILE_ROW_SIZE(TILE_ROW_SIZE),
                .TILE_COL_SIZE(TILE_COL_SIZE),
                .PIPELINE_STAGES(get_pipe_stage(TILE_ROW_SIZE)),
                .PIPE_MULT(PIPE_MULT),
                .PIPE_ALIGN(PIPE_ALIGN)
            ) u_pe (
                .clk_i            (clk_i),
                .ifmap_i          (ifmap_q[j-1][TILE_ROW_SIZE*i+:TILE_ROW_SIZE]),
                .weight_i         (weight_tile),
                .ps_i             (ps_q[i-1][TILE_COL_SIZE*j+:TILE_COL_SIZE]),
                .input_valid_i    (valid_q[j-1]),
                .in_weight_sel_i  (in_weight_sel_q[j-1]),
                .out_weight_sel_i (out_weight_sel_q[j-1]),
                .weight_load_dir_i(weight_load_dir_q[j-1]),
                .blk_sidx_i       (blk_sidx_q[j-1][TILE_ROW_SIZE*i+:TILE_ROW_SIZE]),
                .blk_sidx_o       (blk_sidx_q[j][TILE_ROW_SIZE*i+:TILE_ROW_SIZE]),
                .ifmap_o          (ifmap_q[j][TILE_ROW_SIZE*i+:TILE_ROW_SIZE]),
                .ps_o             (ps_q[i][TILE_COL_SIZE*j+:TILE_COL_SIZE]),
                .valid_o          (valid_q[j]),
                .in_weight_sel_o  (in_weight_sel_q[j]),
                .out_weight_sel_o (out_weight_sel_q[j]),
                .weight_load_dir_o(weight_load_dir_q[j])
            );
          end
        end
      end
    end
  endgenerate

  assign ps_o = ps_q[ROW_SIZE/TILE_ROW_SIZE-1];

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
