`include "VX_define.vh"

interface VX_gemm_ctrl_if import VX_gpu_pkg::*; #(
    parameter DATA_SIZE  = 1
) ();

  // Unified LMEM DMA control structure
  typedef struct packed {
    logic start;
  } lmem_dma_ctrl_t;

  // Unified LMEM DMA flag structure
  typedef struct packed {
    logic idle;
    logic done;
  } lmem_dma_flag_t;

  // External DMA control (dcache <-> LMEM)
  typedef struct packed {
    logic start;
  } dma_ctrl_t;

  typedef struct packed {
    logic idle;
    logic done;
  } dma_flag_t;

  // LMEM DMA controls and flags
  lmem_dma_ctrl_t  input_read_ctrl;
  lmem_dma_flag_t  input_read_flag;

  lmem_dma_ctrl_t  weight_read_ctrl;
  lmem_dma_flag_t  weight_read_flag;

  lmem_dma_ctrl_t  output_write_ctrl;
  lmem_dma_flag_t  output_write_flag;

  lmem_dma_ctrl_t  quant_param_read_ctrl;
  lmem_dma_flag_t  quant_param_read_flag;

  // External DMA control
  dma_ctrl_t  dma_ctrl;
  dma_flag_t  dma_flag;

  modport master (
    output input_read_ctrl,
    input  input_read_flag,
    output weight_read_ctrl,
    input  weight_read_flag,
    output output_write_ctrl,
    input  output_write_flag,
    output quant_param_read_ctrl,
    input  quant_param_read_flag,
    output dma_ctrl,
    input  dma_flag
  );

  modport slave (
    input  input_read_ctrl,
    output input_read_flag,
    input  weight_read_ctrl,
    output weight_read_flag,
    input  output_write_ctrl,
    output output_write_flag,
    input  quant_param_read_ctrl,
    output quant_param_read_flag,
    input  dma_ctrl,
    output dma_flag
  );

endinterface