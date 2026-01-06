`include "VX_define.vh"

module VX_gemm_fsm import VX_gpu_pkg::*; #(
    parameter `STRING INSTANCE_ID = ""
) (
    // Clock
    input wire              clk,
    input wire              reset,

    VX_config_reg_if.slave cfg_reg_if, // from gemm node
    VX_gemm_fsm_if.master  gemm_fsm_if // to gemm unit
);

  assign cfg_reg_if.ready = 1'b0;
  assign gemm_fsm_if.ctrl.start = 1'b0;

endmodule