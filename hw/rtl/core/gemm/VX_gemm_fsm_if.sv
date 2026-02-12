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

  // 이 DMA 커맨드 스트림의 소유자(워프 ID)
  logic [31:0] wid;     // = warp_id

  ctrl_t  ctrl;
  flag_t  flag;

  modport master (
    output ctrl,
    output M_tot,
    output N_tot,
    output K_tot,
    output qblk_tot,
    output wid,
    input  flag
  );
  
  modport slave (
    input  ctrl,
    input  M_tot,
    input  N_tot,
    input  K_tot,
    input  qblk_tot,
    input  wid,
    output flag
  );
  
endinterface : VX_gemm_fsm_if
