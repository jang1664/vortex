`include "VX_define.vh"

module VX_gemm_quant_param_read_ctrl import VX_gpu_pkg::*; #(
    parameter `STRING INSTANCE_ID = ""
) (
    // Clock
    input wire              clk,
    input wire              reset,

    VX_gemm_ctrl_if.slave   gemm_ctrl_if
);

endmodule
