`include "VX_define.vh"

interface VX_gemm_dma_ctrl_if import VX_gpu_pkg::*; ();

  logic start;
  logic idle;
  logic done;
  gemm_unified_cmd_t cmd;
  
  logic [31:0] M_tot;
  logic [31:0] N_tot;
  logic [31:0] K_tot;

  logic [31:0] entry_id;     // mmio reg entry id

  modport master (
    output start, cmd, M_tot, N_tot, K_tot, entry_id,
    input idle, done
  );

  modport slave (
    input start, cmd, M_tot, N_tot, K_tot, entry_id,
    output idle, done
  );
  
  
endinterface
