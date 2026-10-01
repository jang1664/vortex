`timescale 1ns / 1ps
`include "VX_define.vh"

/*
  WoQ-variant of VX_gemm_weight_regs_v1.
  - Removed: weight_load_dir_i + col-direction load path. WoQ supports only
    row-direction weight loading. The col_dir_next generation block, the
    direction mux, and WEIGHT_LOAD_COL_NUM are all removed (no dead logic).
  - Kept: dual-buffer (in_weight_sel_i / out_weight_sel_i) for compute/load
    overlap. That's not WKV-specific.
*/

module VX_woq_gemm_weight_regs_v1 #(
    parameter int ROW_SIZE            = 32,
    parameter int COL_SIZE            = 32,
    parameter int WEIGHT_DW           = 4,
    parameter int WEIGHT_LOAD_ROW_NUM = 1   // Number of weight rows loaded per cycle
) (
    input  logic clk_i,

    // Weight loading interface (row-dir only)
    input  logic [WEIGHT_LOAD_ROW_NUM-1:0][COL_SIZE-1:0][WEIGHT_DW-1:0] weight_i,
    input  logic ready_weight_i,
    input  logic in_weight_sel_i,    // Which buffer to load into
    input  logic out_weight_sel_i,   // Which buffer to read from

    // Weight output to PEs
    output logic [ROW_SIZE-1:0][COL_SIZE-1:0][WEIGHT_DW-1:0] weight_o
);

  // Dual-buffer weight memory: [row][col][buffer_select]
  logic [ROW_SIZE-1:0][COL_SIZE-1:0][1:0][WEIGHT_DW-1:0] mem;

  // Weight loading logic — row-direction only (load from bottom rows up).
  generate
    for (genvar row = 0; row < ROW_SIZE; row++) begin : gen_row
      for (genvar col = 0; col < COL_SIZE; col++) begin : gen_col
        logic [WEIGHT_DW-1:0] row_dir_next;

        if (row >= (ROW_SIZE - WEIGHT_LOAD_ROW_NUM)) begin : g_row_dir_load
          assign row_dir_next = weight_i[row - (ROW_SIZE - WEIGHT_LOAD_ROW_NUM)][col];
        end else begin : g_row_dir_shift
          assign row_dir_next = mem[row + WEIGHT_LOAD_ROW_NUM][col][in_weight_sel_i];
        end

        always_ff @(posedge clk_i) begin
          if (ready_weight_i) begin
            mem[row][col][in_weight_sel_i] <= row_dir_next;
          end
        end

        // Output mux: select active buffer (dual-buffer kept).
        assign weight_o[row][col] = mem[row][col][out_weight_sel_i];

      end
    end
  endgenerate

endmodule
