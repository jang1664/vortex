`include "VX_define.vh"

interface VX_gemm_ctrl_if import VX_gpu_pkg::*; #(
    parameter DATA_SIZE  = 1
) ();

  typedef struct packed {
    logic start;
  } input_read_ctrl_t;

  typedef struct packed {
    logic idle;
    logic done;
  } input_read_flag_t;

  typedef struct packed {
    logic start;
  } weight_read_ctrl_t;

  typedef struct packed {
    logic idle;
    logic done;
  } weight_read_flag_t;

  typedef struct packed {
    logic start;
  } output_write_ctrl_t;

  typedef struct packed {
    logic idle;
    logic done;
  } output_write_flag_t;

  typedef struct packed {
    logic start;
  } quant_param_read_ctrl_t;

  typedef struct packed {
    logic idle;
    logic done;
  } quant_param_read_flag_t;

  typedef struct packed {
    logic start;
  } dma_ctrl_t;

  typedef struct packed {
    logic idle;
    logic done;
  } dma_flag_t;

  input_read_ctrl_t  input_read_ctrl;
  input_read_flag_t  input_read_flag;

  weight_read_ctrl_t  weight_read_ctrl;
  weight_read_flag_t  weight_read_flag;

  output_write_ctrl_t  output_write_ctrl;
  output_write_flag_t  output_write_flag;

  quant_param_read_ctrl_t  quant_param_read_ctrl;
  quant_param_read_flag_t  quant_param_read_flag;

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