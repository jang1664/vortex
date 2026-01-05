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

  VX_lsu_mem_if.slave     lsu_mem_if[`NUM_LSU_BLOCKS], // for programming control registers

  VX_mem_bus_if.master    dcache_bus_if, // to dcache
  VX_mem_bus_if.master    lmem_bus_if // to local memory
);

  //TODO: implement DMA
  generate
    for (genvar i = 0; i < `NUM_LSU_BLOCKS; i = i + 1) begin : block
      assign lsu_mem_if[i].rsp_valid = 0;
      assign lsu_mem_if[i].rsp_data = '0;
      assign lsu_mem_if[i].req_ready = 1;
    end
  endgenerate

  assign dcache_bus_if.req_valid = 0;
  assign dcache_bus_if.req_data = '0;
  assign dcache_bus_if.rsp_ready = 1;

  assign lmem_bus_if.req_valid = 0;
  assign lmem_bus_if.req_data = '0;
  assign lmem_bus_if.rsp_ready = 1;

  localparam NDIM=3;
  localparam LMEM=0;
  localparam GLOBAL=1;

  // config registers
  logic [31:0] lmem_strides[2][NDIM]; // [LMEM/GLOBAL][DIM]
  logic [31:0] lmem_bnds[2][NDIM];
  logic [31:0] lmem_segsize[2][NDIM];
  logic [31:0] lmem_padding[2][NDIM];

  // FSM -> 3D loop

  // make request for 1D segments

endmodule