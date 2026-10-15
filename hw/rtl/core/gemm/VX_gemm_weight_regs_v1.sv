`timescale 1ns / 1ps
`include "VX_define.vh"

/*
  Centralized weight register management for GEMM
  - Manages all weights for the entire GEMM array
  - Supports dual-buffer for weight swapping (in_weight_sel_i / out_weight_sel_i)
  - Supports both row direction and column direction weight loading
*/

module VX_gemm_weight_regs_v1 import VX_gpu_pkg::*; #(
`ifdef GEMM_NAIVE_FP16_ENABLE
    parameter bit ROW_ONLY            = 0,
`endif
    parameter int ROW_SIZE            = 32,
    parameter int COL_SIZE            = 32,
    parameter int WEIGHT_DW           = 4,
    parameter int WEIGHT_LOAD_ROW_NUM = 1,  // Number of weight rows loaded per cycle
    parameter int WEIGHT_LOAD_COL_NUM = 1   // Number of weight columns loaded per cycle
) (
    input  logic clk_i,
    
    // Weight loading interface
    input  logic [WEIGHT_LOAD_ROW_NUM-1:0][COL_SIZE-1:0][WEIGHT_DW-1:0] weight_i,
    input  logic ready_weight_i,
    input  logic weight_load_dir_i,  // 0: row direction, 1: column direction
    input  gemm_wreg_idx_t in_weight_sel_i,   // Which bank to load into
    input  gemm_wreg_idx_t out_weight_sel_i,  // Which bank to read from
    
    // Weight output to PEs
    output logic [ROW_SIZE-1:0][COL_SIZE-1:0][WEIGHT_DW-1:0] weight_o
);

  // Static assertion: WEIGHT_LOAD_ROW_NUM must equal WEIGHT_LOAD_COL_NUM
  initial begin
    if (WEIGHT_LOAD_ROW_NUM != WEIGHT_LOAD_COL_NUM) begin
      $error("WEIGHT_LOAD_ROW_NUM (%0d) must equal WEIGHT_LOAD_COL_NUM (%0d)", 
             WEIGHT_LOAD_ROW_NUM, WEIGHT_LOAD_COL_NUM);
      $finish;
    end
  end

  // Independent two-bank Weight double buffer: [row][col][bank_select].
  logic [ROW_SIZE-1:0][COL_SIZE-1:0][1:0][WEIGHT_DW-1:0] mem;

  // Weight loading logic
  generate
    for (genvar row = 0; row < ROW_SIZE; row++) begin : gen_row
      for (genvar col = 0; col < COL_SIZE; col++) begin : gen_col
        logic [WEIGHT_DW-1:0] row_dir_next;
`ifndef GEMM_NAIVE_FP16_ENABLE
        logic [WEIGHT_DW-1:0] col_dir_next;
`endif

        if (row >= (ROW_SIZE - WEIGHT_LOAD_ROW_NUM)) begin : g_row_dir_load
          assign row_dir_next = weight_i[row - (ROW_SIZE - WEIGHT_LOAD_ROW_NUM)][col];
        end else begin : g_row_dir_shift
          assign row_dir_next = mem[row + WEIGHT_LOAD_ROW_NUM][col][in_weight_sel_i];
        end

`ifdef GEMM_NAIVE_FP16_ENABLE
        // FPFP has row-major weights only. Do not elaborate transpose indices
        // against a rectangular row payload. Legacy FPINT keeps both paths.
        if (ROW_ONLY) begin : g_row_only
          always_ff @(posedge clk_i) begin
            if (ready_weight_i)
              mem[row][col][in_weight_sel_i] <= row_dir_next;
          end
        end else begin : g_bidirectional
        logic [WEIGHT_DW-1:0] col_dir_next;
`endif
        if (col >= (COL_SIZE - WEIGHT_LOAD_COL_NUM)) begin : g_col_dir_load
          assign col_dir_next = weight_i[col - (COL_SIZE - WEIGHT_LOAD_COL_NUM)][row];
        end else begin : g_col_dir_shift
          assign col_dir_next = mem[row][col + WEIGHT_LOAD_COL_NUM][in_weight_sel_i];
        end

        always_ff @(posedge clk_i) begin
          if (ready_weight_i) begin
            if (weight_load_dir_i == 1'b0) begin
              // Row direction: load from bottom to top
              mem[row][col][in_weight_sel_i] <= row_dir_next;
            end else begin
              // Column direction: load from right to left
              mem[row][col][in_weight_sel_i] <= col_dir_next;
            end
          end
        end
        
`ifdef GEMM_NAIVE_FP16_ENABLE
        end
`endif
        // Output mux: select active buffer
        assign weight_o[row][col] = mem[row][col][out_weight_sel_i];
        
      end
    end
  endgenerate

`ifdef DBG_TRACE_GEMM
  always @(posedge clk_i) begin
    if (ready_weight_i) begin
      `TRACE(3, ("%m : [%0t] | WEIGHT_REGS_LOADING | {dir=%0d, in_sel=%0d, out_sel=%0d, weights=%0h}\n",
                 $time, weight_load_dir_i, in_weight_sel_i, out_weight_sel_i, weight_i))
    end
  end
`endif

endmodule
