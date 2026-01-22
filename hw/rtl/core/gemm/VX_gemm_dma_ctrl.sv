`include "VX_define.vh"

module VX_gemm_dma_ctrl import VX_gpu_pkg::*; #(
    parameter `STRING INSTANCE_ID = ""
) (
    // Clock
    input wire              clk,
    input wire              reset,

    VX_gemm_dma_ctrl_if.slave  gemm_dma_ctrl_if, // from gemm ctrl
    VX_gemm_sync_if.master      gemm_sync_if, // to gemm/dma node, 이거 마스터여야 함
    VX_lsu_mem_if.master       dma_if
);
  assign gemm_dma_ctrl_if.idle = 1'b1;
  assign gemm_dma_ctrl_if.done = 1'b1;
  assign dma_if.req_valid = 1'b0;
  assign dma_if.rsp_ready = 1'b1;
  assign gemm_sync_if.ready = '1;

endmodule