`include "VX_define.vh"

interface VX_gemm_dma_ctrl_if import VX_gpu_pkg::*; ();

  logic start;
  logic idle;
  logic done;
  gemm_unified_cmd_t cmd;
  
  logic [31:0] M_tot;
  logic [31:0] N_tot;
  logic [31:0] K_tot;

  // 이 DMA 커맨드 스트림의 소유자(워프 ID)
  logic [31:0] wid;     // = warp_id

  modport master (
    output start, cmd, M_tot, N_tot, K_tot, wid,
    input idle, done
  );

  modport slave (
    input start, cmd, M_tot, N_tot, K_tot, wid,
    output idle, done
  );
  
  
endinterface
