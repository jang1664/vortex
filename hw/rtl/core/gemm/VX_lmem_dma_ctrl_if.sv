/*
  VX_lmem_dma_ctrl_if.sv

  Interface for LMEM DMA control
  Contains stride, bound, start, idle, done signals
*/

`include "VX_define.vh"

interface VX_lmem_dma_ctrl_if import VX_gpu_pkg::*; #(
  parameter NDIM = 3
) ();

  // Control signals (master -> slave)
  logic        start;
  logic        prepare;
  logic [GEMM_PREFETCH_MAX_BEATS_WIDTH-1:0] prepare_max_beats;
  logic [63:0] src_base_addr;
  logic [63:0] dst_base_addr;
  logic [31:0] src_strides [NDIM];
  logic [31:0] dst_strides [NDIM];
  logic [31:0] bounds      [NDIM];
  logic [31:0] seg_size;
  logic [31:0] reg_idx;
  logic [31:0] reg_value;

  // Status signals (slave -> master)
  logic        idle;
  logic        prepare_ready;
  logic        done;
  // Pulses on acceptance of the descriptor's final destination write.
  // This is the architectural transfer completion, before wrapper lifecycle
  // states such as legacy synchronization and S_DONE.
  logic        write_done;

  modport master (
    output start,
    output prepare,
    output prepare_max_beats,
    output src_base_addr,
    output dst_base_addr,
    output src_strides,
    output dst_strides,
    output bounds,
    output seg_size,
    output reg_idx,
    output reg_value,
    input  idle,
    input  prepare_ready,
    input  done,
    input  write_done
  );

  modport slave (
    input  start,
    input  prepare,
    input  prepare_max_beats,
    input  src_base_addr,
    input  dst_base_addr,
    input  src_strides,
    input  dst_strides,
    input  bounds,
    input  seg_size,
    input  reg_idx,
    input  reg_value,
    output idle,
    output prepare_ready,
    output done,
    output write_done
  );

endinterface
