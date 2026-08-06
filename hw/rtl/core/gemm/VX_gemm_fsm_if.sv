`include "VX_define.vh"

/*
  - unified cmd description
*/

interface VX_gemm_fsm_if import VX_gpu_pkg::*; ();

  typedef struct packed {
    gemm_unified_cmd_t cmd;
    logic start;
  } ctrl_t;

  typedef struct packed {
    logic idle;  //ready처럼 사용
    logic done;
    logic [4:0] child_ready;
  } flag_t;

  ctrl_t  ctrl;
  flag_t  flag;

  modport master (
    output ctrl,
    input  flag
  );
  
  modport slave (
    input  ctrl,
    output flag
  );
  
endinterface : VX_gemm_fsm_if
