`include "VX_define.vh"

module VX_dma_node import VX_gpu_pkg::*; #(
  parameter `STRING INSTANCE_ID = "",
  parameter int N_MASTER     = 1
) (
  input wire clk,
  input wire reset,

  VX_lsu_mem_if.slave     mmio_if[N_MASTER], // from LSU
  VX_mem_bus_if.master    dcache_bus_if, // to dcache
  VX_mem_bus_if.master    lmem_bus_if // to local memory
);

endmodule
