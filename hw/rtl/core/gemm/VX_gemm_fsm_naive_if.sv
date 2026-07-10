// Derived from origin/fpint_naive (ffb5aecb3); namespaced for dual-backend builds.
`include "VX_define.vh"

`ifdef GEMM_NAIVE

/*
  - unified cmd description
*/

interface VX_gemm_fsm_naive_if import VX_gpu_pkg::*; ();

  typedef struct packed {
    gemm_unified_cmd_t cmd;
    logic start;
  } ctrl_t;

  typedef struct packed {
    logic idle;
    logic done;
  } flag_t;

  logic [31:0] M_orig;
  logic [31:0] N_orig;
  logic [31:0] K_orig;
  logic [31:0] qblk_orig;

  logic [31:0] M_target;
  logic [31:0] N_target;
  logic [31:0] K_target;

  logic [31:0] wtrans_tot;
  logic [31:0] qdir_tot;

  logic [31:0] entry_id;     // = warp_id

  ctrl_t  ctrl;
  flag_t  flag;

  modport master (
    output ctrl,
    output M_orig,
    output N_orig,
    output K_orig,
    output qblk_orig,
    output M_target,
    output N_target,
    output K_target,
    output wtrans_tot,
    output qdir_tot,
    output entry_id,
    input  flag
  );
  
  modport slave (
    input  ctrl,
    input  M_orig,
    input  N_orig,
    input  K_orig,
    input  qblk_orig,
    input  M_target,
    input  N_target,
    input  K_target,
    input  wtrans_tot,
    input  qdir_tot,
    input  entry_id,
    output flag
  );
  
endinterface : VX_gemm_fsm_naive_if

`endif // GEMM_NAIVE
