/*
  VX_lmem_dma.sv

  DMA Engine for LMEM <-> GEMM Unit data transfer
  Parameterized by direction (read/write), LMEM data width, GEMM data width

  Usage:
    - DIR = 0: LMEM -> GEMM (read from LMEM)
    - DIR = 1: GEMM -> LMEM (write to LMEM)
*/

`include "VX_define.vh"

module VX_lmem_dma import VX_gpu_pkg::*; #(
  parameter `STRING INSTANCE_ID = "",
  parameter DIR      = 0,        // 0: LMEM->GEMM (read), 1: GEMM->LMEM (write)
  parameter LMEM_DW  = 32,       // LMEM data width in bits
  parameter GEMM_DW  = 32,       // GEMM data width in bits
  parameter NDIM     = 3         // Number of dimensions for nested loop
) (
  input wire clk,
  input wire reset,

  // Control interface
  VX_lmem_dma_ctrl_if.slave ctrl_if,

  // LMEM memory bus interface
  VX_mem_bus_if.master lmem_bus_if,
  VX_mem_bus_if.master gemm_bus_if
);

  assign ctrl_if.idle = 1'b1;
  assign ctrl_if.done = 1'b1;

  assign lmem_bus_if.req_ready = 1'b1;
  assign lmem_bus_if.rsp_valid = 1'b0;
  assign lmem_bus_if.rsp_data  = '0;
  assign gemm_bus_if.req_ready = 1'b1;
  assign gemm_bus_if.rsp_valid = 1'b0;
  assign gemm_bus_if.rsp_data  = '0;


endmodule
