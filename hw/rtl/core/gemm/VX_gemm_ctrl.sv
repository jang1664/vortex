`include "VX_define.vh"

module VX_gemm_ctrl import VX_gpu_pkg::*; #(
    parameter `STRING INSTANCE_ID = ""
) (
    // Clock
    input wire              clk,
    input wire              reset,

    VX_lsu_mem_if.slave     lsu_mem_if,  // for gemm unit control
    VX_gemm_ctrl_if.master  gemm_ctrl_if // to gemm unit
);

    // control registers

    // top level FSM

endmodule