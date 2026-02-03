`timescale 1ns / 1ps

/*
  Centralized weight register management for GEMM
  - Manages all weights for the entire GEMM array
  - Supports dual-buffer for weight swapping (in_weight_sel_i / out_weight_sel_i)
  - Supports both row direction and column direction weight loading
*/

module VX_gemm_weight_regs_v1 #(
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
    input  logic in_weight_sel_i,    // Which buffer to load into
    input  logic out_weight_sel_i,   // Which buffer to read from
    
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

  // Dual-buffer weight memory: [row][col][buffer_select]
  logic [ROW_SIZE-1:0][COL_SIZE-1:0][1:0][WEIGHT_DW-1:0] mem;

  // Weight loading logic
  generate
    for (genvar row = 0; row < ROW_SIZE; row++) begin : gen_row
      for (genvar col = 0; col < COL_SIZE; col++) begin : gen_col
        
        always_ff @(posedge clk_i) begin
          if (weight_load_dir_i == 0) begin
            // ============================================================
            // Row direction: load from top to bottom
            // ============================================================
            if (row < WEIGHT_LOAD_ROW_NUM) begin
              // Load new weights for the first WEIGHT_LOAD_ROW_NUM rows
              if (ready_weight_i) begin
                mem[row][col][in_weight_sel_i] <= weight_i[row][col];
              end
            end else begin
              // Shift weights from previous rows
              //TODO: use generate if for avoiding warning
              if (ready_weight_i) begin
                mem[row][col][in_weight_sel_i] <= mem[row - WEIGHT_LOAD_ROW_NUM][col][in_weight_sel_i];
              end
            end
            
          end else begin
            // ============================================================
            // Column direction: load from left to right
            // ============================================================
            if (col < WEIGHT_LOAD_COL_NUM) begin
              // Load new weights for the first WEIGHT_LOAD_COL_NUM columns
              // Similar to row direction: load WEIGHT_LOAD_ROW_NUM rows at a time
              if (ready_weight_i && (col < WEIGHT_LOAD_COL_NUM)) begin
                mem[row][col][in_weight_sel_i] <= weight_i[col][row];
              end else if (ready_weight_i && (col >= WEIGHT_LOAD_COL_NUM)) begin
                // Shift weights from previous rows (within the first column(s))
                mem[row][col][in_weight_sel_i] <= mem[row][col - WEIGHT_LOAD_COL_NUM][in_weight_sel_i];
              end
            end else begin
              // Shift weights from previous columns
              if (ready_weight_i) begin
                mem[row][col][in_weight_sel_i] <= mem[row][col - WEIGHT_LOAD_COL_NUM][in_weight_sel_i];
              end
            end
          end
        end
        
        // Output mux: select active buffer
        assign weight_o[row][col] = mem[row][col][out_weight_sel_i];
        
      end
    end
  endgenerate

`ifdef DBG_TRACE_GEMM
  always @(posedge clk_i) begin
    if (ready_weight_i) begin
      `TRACE(3, ("%t: WEIGHT_REGS: Loading dir=%0d, in_sel=%0d, out_sel=%0d, weights=%0h\n", 
                 $time, weight_load_dir_i, in_weight_sel_i, out_weight_sel_i, weight_i))
    end
  end
`endif

endmodule
