`timescale 1ns / 1ps

/*
  Centralized weight register management for GEMM
  - Manages all weights for the entire GEMM array
  - Supports dual-buffer for weight swapping (in_weight_sel_i / out_weight_sel_i)
  - Supports both row direction and column direction weight loading
*/

module VX_gemm_weight_regs_v2 #(
    parameter int ROW_SIZE            = 32,
    parameter int COL_SIZE            = 32,
    parameter int WEIGHT_DW           = 4,
    parameter int WEIGHT_LOAD_ROW_NUM = 1,  // Number of weight rows loaded per cycle
    parameter int WEIGHT_LOAD_COL_NUM = 1   // Number of weight columns loaded per cycle
) (
    input  logic clk_i,
    input  logic resetn_i,
    
    // Weight loading interface
    input  logic [WEIGHT_LOAD_ROW_NUM-1:0][COL_SIZE-1:0][WEIGHT_DW-1:0] weight_i,
    input  logic ready_weight_i,
    input  logic [WEIGHT_LOAD_ROW_NUM-1:0][$clog2(ROW_SIZE)-1:0] weight_dst_i,
    input  logic weight_load_dir_i,  // 0: row direction, 1: column direction
    input  logic in_weight_sel_i,    // Which buffer to load into
    input  logic out_weight_sel_i,   // Which buffer to read from
    
    // Weight output to PEs
    output logic [ROW_SIZE-1:0][COL_SIZE-1:0][WEIGHT_DW-1:0] weight_o
);

  // Static assertion: WEIGHT_LOAD_ROW_NUM must equal WEIGHT_LOAD_COL_NUM
  initial begin
    if(ROW_SIZE != COL_SIZE) begin
      $error("ROW_SIZE (%0d) must equal COL_SIZE (%0d) for weight loading", 
             ROW_SIZE, COL_SIZE);
      $finish;
    end
    if (WEIGHT_LOAD_ROW_NUM != WEIGHT_LOAD_COL_NUM) begin
      $error("WEIGHT_LOAD_ROW_NUM (%0d) must equal WEIGHT_LOAD_COL_NUM (%0d)", 
             WEIGHT_LOAD_ROW_NUM, WEIGHT_LOAD_COL_NUM);
      $finish;
    end
  end

  // Dual-buffer weight memory: [row][col][buffer_select]
  logic [ROW_SIZE-1:0][COL_SIZE-1:0][WEIGHT_DW-1:0] weight_mem_rowdir_network;
  logic [COL_SIZE-1:0][ROW_SIZE-1:0][WEIGHT_DW-1:0] weight_mem_coldir_network;
  logic [ROW_SIZE-1:0][COL_SIZE-1:0][1:0][WEIGHT_DW-1:0] mem;
  
  // Propagated control signals
  logic [ROW_SIZE/WEIGHT_LOAD_ROW_NUM-1:0] rowdir_in_weight_sel_q;
  logic [ROW_SIZE/WEIGHT_LOAD_ROW_NUM-1:0] rowdir_ready_weight_q;
  logic [ROW_SIZE-1:0][$clog2(ROW_SIZE)-1:0] rowdir_weight_dst_q;

  logic [COL_SIZE/WEIGHT_LOAD_COL_NUM-1:0] coldir_in_weight_sel_q;
  logic [COL_SIZE/WEIGHT_LOAD_COL_NUM-1:0] coldir_ready_weight_q;
  logic [COL_SIZE-1:0][$clog2(COL_SIZE)-1:0] coldir_weight_dst_q;

  // weight load direction propagation
  generate
    for (genvar row_blk = 0; row_blk < ROW_SIZE / WEIGHT_LOAD_ROW_NUM; row_blk++) begin : gen_rowdir_propagate
      if(row_blk == 0) begin : gen_rowdir_first
        assign rowdir_in_weight_sel_q[row_blk] = in_weight_sel_i;
        assign rowdir_ready_weight_q[row_blk] = ready_weight_i & (weight_load_dir_i == 0);
        assign rowdir_weight_dst_q[row_blk +: WEIGHT_LOAD_ROW_NUM] = weight_dst_i;
        assign weight_mem_rowdir_network[row_blk * WEIGHT_LOAD_ROW_NUM +: WEIGHT_LOAD_ROW_NUM] = weight_i;
      end else begin : gen_rowdir_others
        always_ff @(posedge clk_i or negedge resetn_i) begin
          if (!resetn_i) begin
            rowdir_in_weight_sel_q[row_blk] <= 1'b0;
            rowdir_ready_weight_q[row_blk] <= 1'b0;
            rowdir_weight_dst_q[row_blk * WEIGHT_LOAD_ROW_NUM +: WEIGHT_LOAD_ROW_NUM] <= '0;
          end else begin
            rowdir_in_weight_sel_q[row_blk] <= rowdir_in_weight_sel_q[row_blk - 1];
            rowdir_ready_weight_q[row_blk] <= rowdir_ready_weight_q[row_blk - 1];
            rowdir_weight_dst_q[row_blk * WEIGHT_LOAD_ROW_NUM +: WEIGHT_LOAD_ROW_NUM] <= 
              rowdir_weight_dst_q[(row_blk - 1) * WEIGHT_LOAD_ROW_NUM +: WEIGHT_LOAD_ROW_NUM];
            if (rowdir_ready_weight_q[row_blk - 1]) begin
              weight_mem_rowdir_network[row_blk * WEIGHT_LOAD_ROW_NUM +: WEIGHT_LOAD_ROW_NUM] <=
                weight_mem_rowdir_network[(row_blk - 1) * WEIGHT_LOAD_ROW_NUM +: WEIGHT_LOAD_ROW_NUM];
            end
          end
        end
      end
    end

    for(genvar col_blk = 0; col_blk < COL_SIZE / WEIGHT_LOAD_COL_NUM; col_blk++) begin : gen_coldir_propagate
      if(col_blk == 0) begin : gen_coldir_first
        assign coldir_in_weight_sel_q[col_blk] = in_weight_sel_i;
        assign coldir_ready_weight_q[col_blk] = ready_weight_i & (weight_load_dir_i == 1);
        assign coldir_weight_dst_q[col_blk +: WEIGHT_LOAD_COL_NUM] = weight_dst_i;
        assign weight_mem_coldir_network[col_blk * WEIGHT_LOAD_COL_NUM +: WEIGHT_LOAD_COL_NUM] = weight_i;
      end else begin : gen_coldir_others
        always_ff @(posedge clk_i or negedge resetn_i) begin
          if (!resetn_i) begin
            coldir_in_weight_sel_q[col_blk] <= 1'b0;
            coldir_ready_weight_q[col_blk] <= 1'b0;
            coldir_weight_dst_q[col_blk * WEIGHT_LOAD_COL_NUM +: WEIGHT_LOAD_COL_NUM] <= '0;
          end else begin
            coldir_in_weight_sel_q[col_blk] <= coldir_in_weight_sel_q[col_blk - 1];
            coldir_ready_weight_q[col_blk] <= coldir_ready_weight_q[col_blk - 1];
            coldir_weight_dst_q[col_blk * WEIGHT_LOAD_COL_NUM +: WEIGHT_LOAD_COL_NUM] <= 
              coldir_weight_dst_q[(col_blk - 1) * WEIGHT_LOAD_COL_NUM +: WEIGHT_LOAD_COL_NUM];
            if (coldir_ready_weight_q[col_blk - 1]) begin
              weight_mem_coldir_network[col_blk * WEIGHT_LOAD_COL_NUM +: WEIGHT_LOAD_COL_NUM] <=
                weight_mem_coldir_network[(col_blk - 1) * WEIGHT_LOAD_COL_NUM +: WEIGHT_LOAD_COL_NUM];
            end
          end
        end
      end
    end
  endgenerate
  
  // Weight loading logic
  generate
    for(genvar row=0; row<ROW_SIZE; row++) begin
      for(genvar col=0; col<COL_SIZE; col++) begin
        always_ff @(posedge clk_i) begin
          if(rowdir_ready_weight_q[row/WEIGHT_LOAD_ROW_NUM]) begin
            mem[row][col][rowdir_in_weight_sel_q[row/WEIGHT_LOAD_ROW_NUM]] <= 
              weight_mem_rowdir_network[row][col];
          end else if(coldir_ready_weight_q[col/WEIGHT_LOAD_COL_NUM]) begin
            mem[row][col][coldir_in_weight_sel_q[col/WEIGHT_LOAD_COL_NUM]] <= 
              weight_mem_coldir_network[col][row];
          end
        end

        assign weight_o[row][col] = mem[row][col][out_weight_sel_i];
      end
    end
  endgenerate

`ifdef DBG_TRACE_GEMM
  always @(posedge clk_i) begin
    if (ready_weight_i) begin
      `TRACE(3, ("%m : [%0t] | WEIGHT_REGS_LOADING | {dir=%0d, in_sel=%0d, out_sel=%0d, dst=%p}\n",
                 $time, weight_load_dir_i, in_weight_sel_i, out_weight_sel_i, weight_dst_i))
    end
  end
`endif

endmodule
