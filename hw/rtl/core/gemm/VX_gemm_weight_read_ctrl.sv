`include "VX_define.vh"

module VX_gemm_weight_read_ctrl import VX_gpu_pkg::*; #(
    parameter `STRING INSTANCE_ID = ""
) (
    // Clock
    input wire              clk,
    input wire              reset,

    VX_gemm_ctrl_if.slave   gemm_ctrl_if
);
  assign gemm_ctrl_if.weight_read_flag.idle = 1'b1;
  assign gemm_ctrl_if.weight_read_flag.done = 1'b1;

endmodule