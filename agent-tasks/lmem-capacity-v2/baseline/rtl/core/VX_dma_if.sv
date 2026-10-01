/*
  VX_lmem_dma_ctrl_if.sv

  Interface for LMEM DMA control
  Contains stride, bound, start, idle, done signals
*/

`include "VX_define.vh"

interface VX_dma_if import VX_gpu_pkg::*; #(
  parameter NDIM = 3,
  parameter BOUND_WIDTH = `DMA_BOUND_WIDTH
) ();

  // Control signals (master -> slave)
  logic        start;
  logic [31:0] src_base_addr;
  logic [31:0] dst_base_addr;
  logic [31:0] src_strides [NDIM];
  logic [31:0] dst_strides [NDIM];
  logic [BOUND_WIDTH-1:0] bounds [NDIM];
  logic [31:0] seg_size;

  // Status signals (slave -> master)
  logic        idle;
  logic        done;

  modport master (
    output start,
    output src_base_addr,
    output dst_base_addr,
    output src_strides,
    output dst_strides,
    output bounds,
    output seg_size,
    input  idle,
    input  done
  );

  modport slave (
    input  start,
    input  src_base_addr,
    input  dst_base_addr,
    input  src_strides,
    input  dst_strides,
    input  bounds,
    input  seg_size,
    output idle,
    output done
  );

endinterface
