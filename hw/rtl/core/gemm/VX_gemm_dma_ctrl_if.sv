`include "VX_define.vh"

interface VX_gemm_dma_ctrl_if import VX_gpu_pkg::*; ();

  logic start;
  logic idle;
  logic done;
  gemm_unified_cmd_t cmd;
  
  logic [31:0] M_orig;
  logic [31:0] N_orig;
  logic [31:0] K_orig;
  logic [31:0] qblk_orig;

  logic [31:0] M_target;
  logic [31:0] N_target;
  logic [31:0] K_target;

  logic [31:0] wtrans_tot;
  logic [31:0] qdir_tot;

  logic [31:0] entry_id;     // mmio reg entry id

  modport master (
    output start, cmd, M_orig, N_orig, K_orig, qblk_orig, M_target, N_target, K_target, wtrans_tot, qdir_tot, entry_id,
    input idle, done
  );

  modport slave (
    input start, cmd, M_orig, N_orig, K_orig, qblk_orig, M_target, N_target, K_target, wtrans_tot, qdir_tot, entry_id,
    output idle, done
  );
  
  
endinterface
