/*

  Future improvements:
    - support for LMEM multi port
*/
`include "VX_define.vh"

module VX_gemm_node import VX_gpu_pkg::*; #(
    parameter `STRING INSTANCE_ID = ""
) (
    // Clock
    input wire              clk,
    input wire              reset,

    VX_lsu_mem_if.slave     lsu_mem_if,  // for gemm unit control

    VX_lsu_mem_if.master    dma_if,     // to DMA engine
    VX_mem_bus_if.master    lmem_bus_if // for inputs, weights, scale/zero, output
);

    // gemm unit

    // gemm top ctrl

    // gemm cmd ctrls

endmodule