`include "VX_define.vh"

/*
  GEMM acc mem <-> local mem
*/
module VX_gemm_output_write_ctrl import VX_gpu_pkg::*; #(
    parameter `STRING INSTANCE_ID = ""
) (
    // Clock
    input wire              clk,
    input wire              reset,

    VX_gemm_ctrl_if.slave   gemm_ctrl_if
);
  assign gemm_ctrl_if.output_write_flag.idle = 1'b1;
  assign gemm_ctrl_if.output_write_flag.done = 1'b1;

endmodule