/*
  VX_config_registers.sv

  Configuration registers for DMA/GEMM control
  - Receives lsu_mem_if for R/W access
  - Outputs entire register set as wire
  - Stalls on start register write until queue_ready is asserted
*/

`include "VX_define.vh"

module VX_config_registers import VX_gpu_pkg::*; #(
  parameter `STRING INSTANCE_ID = "",
  parameter NUM_REGS  = 16,           // Number of 32-bit registers
  parameter START_BIT = 0,             // Bit position of start signal in register space
  parameter MAS_NUM   = 1
) (
  input wire clk,
  input wire reset,

  // LSU memory interface for register access
  VX_lsu_mem_if.slave lsu_mem_if[MAS_NUM],
  VX_config_reg_if.master regs_out // entire register set output
);

  generate
    for (genvar i = 0; i < MAS_NUM; i = i + 1) begin : block
      assign lsu_mem_if[i].req_ready = 1'b1;
      assign lsu_mem_if[i].rsp_valid = 1'b0;
      assign lsu_mem_if[i].rsp_data  = '0;
    end
  endgenerate

  assign regs_out.ready = 1'b1;
  assign regs_out.regs = '0;

  // config registers

endmodule
