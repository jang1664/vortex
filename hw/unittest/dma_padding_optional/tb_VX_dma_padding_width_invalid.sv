`timescale 1ns / 1ps
`include "VX_define.vh"

module tb_VX_dma_padding_width_invalid import VX_gpu_pkg::*; ();

  localparam int CFG_NUM = `DMA_CFG_REG_NUM;
  localparam int MEM_ADDR_WIDTH = 34;
  localparam int TAG_WIDTH = 8;
  localparam int DCACHE_BYTES = 32;
  localparam int LMEM_BYTES = 64;

  logic clk = 1'b0;
  logic reset = 1'b1;
  always #5 clk = ~clk;

  VX_config_reg_if #(
    .NUM (CFG_NUM),
    .DW  (32)
  ) cfg_if ();
  VX_dma_lookahead_if lookahead_if ();
  VX_node_done_if done_if ();
  VX_mem_bus_if #(
    .DATA_SIZE      (DCACHE_BYTES),
    .TAG_WIDTH      (TAG_WIDTH),
    .MEM_ADDR_WIDTH (MEM_ADDR_WIDTH)
  ) dcache_if ();
  VX_mem_bus_if #(
    .DATA_SIZE      (LMEM_BYTES),
    .TAG_WIDTH      (TAG_WIDTH),
    .MEM_ADDR_WIDTH (MEM_ADDR_WIDTH)
  ) lmem_if ();

  assign cfg_if.regs = '0;
  assign cfg_if.entry_id = '0;
  assign cfg_if.valid = 1'b0;
  assign lookahead_if.prepare_valid = 1'b0;
  assign lookahead_if.prepare_id = '0;
  assign lookahead_if.src_stride = '0;
  assign lookahead_if.dst_stride = '0;
  assign lookahead_if.bound = '0;
  assign lookahead_if.activate = 1'b0;
  assign lookahead_if.activate_id = '0;
  assign lookahead_if.data_release = 1'b1;
  assign lookahead_if.data_max_beats = '0;
  assign done_if.ready = 1'b1;
  assign dcache_if.req_ready = 1'b1;
  assign dcache_if.rsp_valid = 1'b0;
  assign dcache_if.rsp_data = '0;
  assign lmem_if.req_ready = 1'b1;
  assign lmem_if.rsp_valid = 1'b0;
  assign lmem_if.rsp_data = '0;

  VX_dma_unit_align #(
    .INSTANCE_ID       ("width-invalid"),
    .ENABLE_PADDING    (1'b0),
    .DCACHE_ADDR_WIDTH (MEM_ADDR_WIDTH - `CLOG2(DCACHE_BYTES)),
    .LMEM_ADDR_WIDTH   (MEM_ADDR_WIDTH - `CLOG2(LMEM_BYTES)),
    .DCACHE_TAG_WIDTH  (TAG_WIDTH),
    .LMEM_TAG_WIDTH    (TAG_WIDTH),
    .RD_OUTSTANDING    (4)
  ) dut (
    .clk           (clk),
    .reset         (reset),
    .cfg_reg_if    (cfg_if),
    .lookahead_if  (lookahead_if),
    .dcache_bus_if (dcache_if),
    .lmem_bus_if   (lmem_if),
    .done_if       (done_if)
  );

  initial begin
    #100;
    $fatal(1, "unequal-width padding-disabled elaboration guard did not fire");
  end

endmodule
