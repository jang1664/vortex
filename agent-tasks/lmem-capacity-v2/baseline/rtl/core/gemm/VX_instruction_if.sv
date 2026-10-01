`include "VX_define.vh"

interface VX_instruction_if import VX_gpu_pkg::*; #(
  parameter DW  = 64
) ();
  logic [DW-1:0] inst;
  logic valid;
  logic ready;

  modport master (
    output inst,
    output valid,
    input  ready
  );
  modport slave (
    input  inst,
    input  valid,
    output ready
  );
endinterface
