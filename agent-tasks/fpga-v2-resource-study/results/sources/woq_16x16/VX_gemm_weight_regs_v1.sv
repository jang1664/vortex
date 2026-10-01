`timescale 1ns / 1ps
module VX_gemm_weight_regs_v1 import VX_gpu_pkg::*; #(
    parameter int ROW_SIZE            = 32,
    parameter int COL_SIZE            = 32,
    parameter int WEIGHT_DW           = 4,
    parameter int WEIGHT_LOAD_ROW_NUM = 1,   
    parameter int WEIGHT_LOAD_COL_NUM = 1    
) (
    input  logic clk_i,
    input  logic [WEIGHT_LOAD_ROW_NUM-1:0][COL_SIZE-1:0][WEIGHT_DW-1:0] weight_i,
    input  logic ready_weight_i,
    input  logic weight_load_dir_i,   
    input  gemm_wreg_idx_t in_weight_sel_i,    
    input  gemm_wreg_idx_t out_weight_sel_i,   
    output logic [ROW_SIZE-1:0][COL_SIZE-1:0][WEIGHT_DW-1:0] weight_o
);
  initial begin
    if (WEIGHT_LOAD_ROW_NUM != WEIGHT_LOAD_COL_NUM) begin
      $error("WEIGHT_LOAD_ROW_NUM (%0d) must equal WEIGHT_LOAD_COL_NUM (%0d)", 
             WEIGHT_LOAD_ROW_NUM, WEIGHT_LOAD_COL_NUM);
      $finish;
    end
  end
  logic [ROW_SIZE-1:0][COL_SIZE-1:0][1:0][WEIGHT_DW-1:0] mem;
  generate
    for (genvar row = 0; row < ROW_SIZE; row++) begin : gen_row
      for (genvar col = 0; col < COL_SIZE; col++) begin : gen_col
        logic [WEIGHT_DW-1:0] row_dir_next;
        logic [WEIGHT_DW-1:0] col_dir_next;
        if (row >= (ROW_SIZE - WEIGHT_LOAD_ROW_NUM)) begin : g_row_dir_load
          assign row_dir_next = weight_i[row - (ROW_SIZE - WEIGHT_LOAD_ROW_NUM)][col];
        end else begin : g_row_dir_shift
          assign row_dir_next = mem[row + WEIGHT_LOAD_ROW_NUM][col][in_weight_sel_i];
        end
        if (col >= (COL_SIZE - WEIGHT_LOAD_COL_NUM)) begin : g_col_dir_load
          assign col_dir_next = weight_i[col - (COL_SIZE - WEIGHT_LOAD_COL_NUM)][row];
        end else begin : g_col_dir_shift
          assign col_dir_next = mem[row][col + WEIGHT_LOAD_COL_NUM][in_weight_sel_i];
        end
        always_ff @(posedge clk_i) begin
          if (ready_weight_i) begin
            if (weight_load_dir_i == 1'b0) begin
              mem[row][col][in_weight_sel_i] <= row_dir_next;
            end else begin
              mem[row][col][in_weight_sel_i] <= col_dir_next;
            end
          end
        end
        assign weight_o[row][col] = mem[row][col][out_weight_sel_i];
      end
    end
  endgenerate
endmodule
