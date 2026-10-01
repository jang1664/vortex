`include "VX_define.vh"
interface VX_config_reg_if import VX_gpu_pkg::*; #(
  parameter NUM = 3,
  parameter DW  = 64
) ();
  logic [NUM-1:0][DW-1:0] regs;
  logic [31:0] entry_id;
  logic valid;
  logic ready;

  modport master (
    output regs,
    output entry_id,
    output valid,
    input  ready
  );
  modport slave (
    input  regs,
    input  entry_id,
    input  valid,
    output ready
  );

endinterface