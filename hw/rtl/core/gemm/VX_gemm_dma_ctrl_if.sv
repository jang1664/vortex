`include "VX_define.vh"

interface VX_gemm_dma_ctrl_if import VX_gpu_pkg::*; ();

  logic start;
  logic idle;
  logic done;

  modport master (
    output start,
    input idle, done
  );

  modport slave (
    input start,
    output idle, done
  );
  
  
endinterface
