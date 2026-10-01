`include "VX_define.vh"
interface VX_gemm_node_done_if import VX_gpu_pkg::*; ();

  logic valid;
  logic ready;

  modport master (
    output valid,
    input ready
  );
  
  modport slave (
    input  valid,
    output ready
  );

endinterface