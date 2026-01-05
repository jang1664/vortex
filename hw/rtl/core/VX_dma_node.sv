/*
  VX_dma.sv

  DMA Engine for VX Core
  dcache <-> local memory

  control registers per warp

  Future improvements:
    - support multiple port

*/

`include "VX_define.vh"

module VX_dma_node import VX_gpu_pkg::*; #(
  parameter `STRING INSTANCE_ID = "" 
) (
  input wire clk,
  input wire reset,

  VX_config_reg_if.slave cfg_reg_if, // from LSU

  VX_mem_bus_if.master    dcache_bus_if, // to dcache
  VX_mem_bus_if.master    lmem_bus_if // to local memory
);

  //TODO: implement DMA
  assign cfg_reg_if.ready = 1'b0;

  assign dcache_bus_if.req_valid = 0;
  assign dcache_bus_if.req_data = '0;
  assign dcache_bus_if.rsp_ready = 1;

  assign lmem_bus_if.req_valid = 0;
  assign lmem_bus_if.req_data = '0;
  assign lmem_bus_if.rsp_ready = 1;

  localparam NDIM=3;
  localparam LMEM=0;
  localparam GLOBAL=1;

  // interpret config registers
  logic [31:0] lmem_strides[2][NDIM]; // [LMEM/GLOBAL][DIM]
  logic [31:0] lmem_bnds[2][NDIM];
  logic [31:0] lmem_segsize[2][NDIM];
  logic [31:0] lmem_padding[2][NDIM];

  // FSM -> 3D loop

  // make request for 1D segments

endmodule