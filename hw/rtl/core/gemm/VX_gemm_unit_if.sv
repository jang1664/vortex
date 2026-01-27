`include "VX_define.vh"

interface VX_gemm_unit_if import VX_gpu_pkg::*; #(
    parameter ADDR_WIDTH  = 1
) ();
  logic start;
  logic idle;
  logic done;

  logic quant_dir; // 0:col, 1:row
  logic [`GEMM_ACC_MEM_ADDR_WIDTH-1:0] acc_mem_base_addr;
  logic [`GEMM_ACC_MAX_CNT-1:0] acc_cnt;

  logic wreg_use_idx;
  logic sreg_use_idx;
  logic zreg_use_idx;

  logic wreg_wr_idx, sreg_wr_idx, zreg_wr_idx;
  logic weight_load_dir;

  logic is_load;

  modport master (
    output start, acc_mem_base_addr, acc_cnt, quant_dir,
           wreg_use_idx, sreg_use_idx, zreg_use_idx,
           wreg_wr_idx, sreg_wr_idx, zreg_wr_idx,
           weight_load_dir, is_load,
    input  idle, done
  );
  modport slave (
    input  start, acc_mem_base_addr, acc_cnt, quant_dir,
           wreg_use_idx, sreg_use_idx, zreg_use_idx,
           wreg_wr_idx, sreg_wr_idx, zreg_wr_idx,
           weight_load_dir, is_load,
    output idle, done
  );

endinterface