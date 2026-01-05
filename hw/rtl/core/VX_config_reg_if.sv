`include "VX_define.vh"
interface VX_config_reg_if import VX_gpu_pkg::*; #(
  parameter NUM = 3,
  parameter DW  = 64
) ();
  logic [NUM-1:0][DW-1:0] regs;
  logic [31:0] wid;
  logic [31:0] tid;
  logic valid;
  logic ready;

  modport master (
    output regs,
    output wid,
    output tid,
    output valid,
    input  ready
  );
  modport slave (
    input  regs,
    input  wid,
    input  tid,
    input  valid,
    output ready
  );

endinterface