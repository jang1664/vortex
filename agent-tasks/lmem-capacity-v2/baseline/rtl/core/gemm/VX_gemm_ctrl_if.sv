`include "VX_define.vh"

interface VX_gemm_ctrl_if import VX_gpu_pkg::*; #(
    parameter DATA_SIZE  = 1
) ();

  // Unified LMEM DMA control structure
  typedef struct packed {
    gemm_unified_cmd_t cmd;
    logic start;
    logic prepare;
  } lmem_dma_ctrl_t;

  // Unified LMEM DMA flag structure
  typedef struct packed {
    logic idle;
    logic done;
    logic prepare_ready;
  } lmem_dma_flag_t;

  // External DMA control (dcache <-> LMEM)
  typedef struct packed {
    gemm_unified_cmd_t cmd;
    logic start;
    logic cmd_valid;
    logic [GEMM_DMA_TAG_WIDTH-1:0] cmd_tag;
    logic prepare_valid;
    gemm_unified_cmd_t prepare_cmd;
  } dma_ctrl_t;

  typedef struct packed {
    logic idle;
    logic done;
    logic cmd_ready;
    logic prepare_ready;
    logic [GEMM_DMA_TAG_WIDTH-1:0] done_tag;
  } dma_flag_t;

  // LMEM DMA controls and flags
  lmem_dma_ctrl_t  input_read_ctrl;
  lmem_dma_flag_t  input_read_flag;

  lmem_dma_ctrl_t  weight_read_ctrl;
  lmem_dma_flag_t  weight_read_flag;

  lmem_dma_ctrl_t  output_write_ctrl;
  lmem_dma_flag_t  output_write_flag;

  lmem_dma_ctrl_t  scale_read_ctrl;
  lmem_dma_flag_t  scale_read_flag;

  lmem_dma_ctrl_t  zero_point_read_ctrl;
  lmem_dma_flag_t  zero_point_read_flag;

  // Legacy combined-qparam pins retained for wrappers that do not instantiate
  // the improve scheduler.  VX_gemm_ctrl does not drive or consume them.
  lmem_dma_ctrl_t  quant_param_read_ctrl;
  lmem_dma_flag_t  quant_param_read_flag;

  // External DMA control
  dma_ctrl_t  dma_ctrl;
  dma_flag_t  dma_flag;

  // Exact operand-consumer dependency levels.  W/S/Z expose the registered
  // view so a final register write becomes consumable only on the following
  // cycle.  ACC retains its same-cycle effective admission view.
  logic [31:0] input_w_load_value [2];
  logic [31:0] input_sc_load_value[2];
  logic [31:0] input_zp_load_value[2];
  logic [31:0] input_acc_free_value[2];

  modport master (
    output input_read_ctrl,
    input  input_read_flag,
    output weight_read_ctrl,
    input  weight_read_flag,
    output output_write_ctrl,
    input  output_write_flag,
    output scale_read_ctrl,
    input  scale_read_flag,
    output zero_point_read_ctrl,
    input  zero_point_read_flag,
    output quant_param_read_ctrl,
    input  quant_param_read_flag,
    output dma_ctrl,
    input  dma_flag,
    output input_w_load_value,
    output input_sc_load_value,
    output input_zp_load_value,
    output input_acc_free_value
  );

  modport slave (
    input  input_read_ctrl,
    output input_read_flag,
    input  weight_read_ctrl,
    output weight_read_flag,
    input  output_write_ctrl,
    output output_write_flag,
    input  scale_read_ctrl,
    output scale_read_flag,
    input  zero_point_read_ctrl,
    output zero_point_read_flag,
    input  quant_param_read_ctrl,
    output quant_param_read_flag,
    input  dma_ctrl,
    output dma_flag,
    input  input_w_load_value,
    input  input_sc_load_value,
    input  input_zp_load_value,
    input  input_acc_free_value
  );

endinterface
