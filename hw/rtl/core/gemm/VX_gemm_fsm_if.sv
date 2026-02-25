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
  } flag_t;

  logic [31:0] M_tot;
  logic [31:0] N_tot;
  logic [31:0] K_tot;
  logic [31:0] qblk_tot;
  logic [31:0] wtrans_tot;
  logic [31:0] qdir_tot;

  // 이 DMA 커맨드 스트림의 소유자(워프 ID)
  logic [31:0] entry_id;     // = warp_id

  ctrl_t  ctrl;
  flag_t  flag;

  modport master (
    output ctrl,
    output M_tot,
    output N_tot,
    output K_tot,
    output qblk_tot,
    output wtrans_tot,
    output qdir_tot,
    output entry_id,
    input  flag
  );
  
  modport slave (
    input  ctrl,
    input  M_tot,
    input  N_tot,
    input  K_tot,
    input  qblk_tot,
    input  wtrans_tot,
    input  qdir_tot,
    input  entry_id,
    output flag
  );
  
endinterface : VX_gemm_fsm_if
