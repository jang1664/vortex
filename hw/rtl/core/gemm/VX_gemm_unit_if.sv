`include "VX_define.vh"

interface VX_gemm_unit_if import VX_gpu_pkg::*; #(
    parameter DATA_SIZE  = 1
) ();
  logic start;
  logic idle;
  logic done;

  modport master (
    output start,
    input  idle,
    input  done
  );
  modport slave (
    input  start,
    output idle,
    output done
  );

endinterface