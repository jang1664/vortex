`include "VX_define.vh"

interface VX_dma_lookahead_if import VX_gpu_pkg::*; #(
  parameter BOUND_WIDTH = `DMA_BOUND_WIDTH
) ();

  logic                 prepare_valid;
  logic [0:0]           prepare_id;
  logic [1:0][31:0]     src_stride;
  logic [1:0][31:0]     dst_stride;
  logic [1:0][BOUND_WIDTH-1:0] bound;
  logic                 activate;
  logic [0:0]           activate_id;
  logic                 data_release;
  logic [GEMM_PREFETCH_MAX_BEATS_WIDTH-1:0] data_max_beats;
  logic                 prepare_ready;
  logic [1:0]           result_ready;

  modport master (
    output prepare_valid,
    output prepare_id,
    output src_stride,
    output dst_stride,
    output bound,
    output activate,
    output activate_id,
    output data_release,
    output data_max_beats,
    input  prepare_ready,
    input  result_ready
  );

  modport slave (
    input  prepare_valid,
    input  prepare_id,
    input  src_stride,
    input  dst_stride,
    input  bound,
    input  activate,
    input  activate_id,
    input  data_release,
    input  data_max_beats,
    output prepare_ready,
    output result_ready
  );

endinterface
