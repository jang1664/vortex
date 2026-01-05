`include "VX_define.vh"

module VX_gemm_dma_ctrl import VX_gpu_pkg::*; #(
    parameter `STRING INSTANCE_ID = ""
) (
    // Clock
    input wire              clk,
    input wire              reset,

    VX_gemm_ctrl_if.slave   gemm_ctrl_if,
    VX_lsu_mem_if.master    dma_if
);
  assign gemm_ctrl_if.dma_flag.idle = 1'b1;
  assign gemm_ctrl_if.dma_flag.done = 1'b1;
  assign dma_if.req_valid = 1'b0;
  assign dma_if.rsp_ready = 1'b1;

endmodule