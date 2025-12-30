/*
  VX_dma.sv

  DMA Engine for VX Core
  dcache <-> local memory

  control registers per warp

  Future improvements:
    - support multiple port

*/

`include "VX_define.vh"

module VX_dma import VX_gpu_pkg::*; #(
  parameter `STRING INSTANCE_ID = "" 
) (
  input wire clk,
  input wire reset,

  VX_lsu_mem_if.slave     lsu_mem_if, // for programming control registers

  VX_mem_bus_if.master    dcache_bus_if, // to dcache
  VX_mem_bus_if.master    lmem_bus_if // to local memory
);

endmodule