`include "VX_define.vh"
interface VX_node_done_if import VX_gpu_pkg::*; ();

  logic valid;
  logic ready;
  logic [31:0] wid;

  modport master (
    output valid,
    output wid,
    input ready
  );
  
  modport slave (
    input  valid,
    input  wid,
    output ready
  );

endinterface