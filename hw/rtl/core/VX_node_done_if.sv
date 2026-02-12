`include "VX_define.vh"
interface VX_node_done_if import VX_gpu_pkg::*; ();

  logic valid;
  logic ready;
  logic [31:0] wid;
  logic [31:0] entry_id;  //entry_id

  modport master (
    output valid,
    output wid,
    output entry_id,
    input ready
  );
  
  modport slave (
    input  valid,
    input  wid,
    input  entry_id,
    output ready
  );

endinterface