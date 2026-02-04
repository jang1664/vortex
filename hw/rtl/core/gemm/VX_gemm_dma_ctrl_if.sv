`include "VX_define.vh"

interface VX_gemm_dma_ctrl_if import VX_gpu_pkg::*; ();

  logic start;
  logic idle;
  logic done;
  gemm_unified_cmd_t cmd;

  modport master (
    output start, cmd,
    input idle, done
  );

  modport slave (
    input start, cmd,
    output idle, done
  );
  
  
endinterface
