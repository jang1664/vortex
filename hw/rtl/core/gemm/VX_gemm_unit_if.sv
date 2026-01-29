`include "VX_define.vh"

interface VX_gemm_unit_if import VX_gpu_pkg::*; #(
    parameter ADDR_WIDTH  = 1
) ();
  logic start;
  logic idle;
  logic done;

  gemm_unit_ctrl_t gemm_unit_ctrl;


  modport master (
    output start, gemm_unit_ctrl,
    input  idle, done
  );
  modport slave (
    input  start, gemm_unit_ctrl,
    output idle, done
  );

endinterface