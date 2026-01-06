`include "VX_define.vh"

interface VX_gemm_sync_if import VX_gpu_pkg::*; ();

  logic [31:0] reg_idx;
  logic [31:0] value;
  logic valid;
  logic ready;

  modport master (
    input ready,
    output valid, reg_idx, value
  );

  modport slave (
    output ready,
    input valid, reg_idx, value
  );
  
  
endinterface
