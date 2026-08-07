`include "VX_define.vh"

interface VX_gemm_dma_ctrl_if import VX_gpu_pkg::*; ();

  logic start;
  logic cmd_valid;
  logic cmd_ready;
  logic idle;
  logic done;
  logic [GEMM_DMA_TAG_WIDTH-1:0] cmd_tag;
  logic [GEMM_DMA_TAG_WIDTH-1:0] done_tag;
  gemm_unified_cmd_t cmd;

  modport master (
    output start, cmd_valid, cmd, cmd_tag,
    input cmd_ready, idle, done, done_tag
  );

  modport slave (
    input start, cmd_valid, cmd, cmd_tag,
    output cmd_ready, idle, done, done_tag
  );
  
  
endinterface
