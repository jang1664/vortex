`include "VX_define.vh"

//==============================================================================
// VX_dma_unit
//  Parameterized wrapper that selects the aligned-only or misaligned DMA unit.
//
//  Keep the implementation files structurally separate:
//    - VX_dma_unit_align.sv: ENABLE_MISALIGN=0, first target for LUT/PnR work
//    - VX_dma_unit_misal.sv: ENABLE_MISALIGN=1, byte-misaligned support
//==============================================================================

module VX_dma_unit import VX_gpu_pkg::*; #(
  parameter `STRING INSTANCE_ID = "",
  parameter bit ENABLE_MISALIGN = 1'b0,
  // Parent forwards interface ADDR_WIDTH and TAG_WIDTH values explicitly. Synopsys DC
  // rejects `interface_inst.PARAM` access inside localparam initializers.
  parameter int DCACHE_ADDR_WIDTH = 1,
  parameter int LMEM_ADDR_WIDTH   = 1,
  parameter int DCACHE_TAG_WIDTH = 1,
  parameter int LMEM_TAG_WIDTH   = 1,
  parameter int MISALIGN_PACK_BYTES = LSU_WORD_SIZE,
  parameter int RD_OUTSTANDING = 2,
  // -1: use descriptor direction, 0/1: compile-time fixed direction.
  parameter int FIXED_DIR = -1
) (
  input wire clk,
  input wire reset,

  VX_config_reg_if.slave cfg_reg_if,

  VX_mem_bus_if.master   dcache_bus_if,
  VX_mem_bus_if.master   lmem_bus_if,

  VX_node_done_if.master done_if
`ifdef PERF_ENABLE
  ,output dma_perf_t perf
`endif
);

  if (ENABLE_MISALIGN) begin : g_misaligned
    VX_dma_unit_misal #(
      .INSTANCE_ID      (INSTANCE_ID),
      .DCACHE_ADDR_WIDTH(DCACHE_ADDR_WIDTH),
      .LMEM_ADDR_WIDTH  (LMEM_ADDR_WIDTH),
      .DCACHE_TAG_WIDTH (DCACHE_TAG_WIDTH),
      .LMEM_TAG_WIDTH   (LMEM_TAG_WIDTH),
      .MISALIGN_PACK_BYTES (MISALIGN_PACK_BYTES),
      .RD_OUTSTANDING   (RD_OUTSTANDING),
      .FIXED_DIR        (FIXED_DIR)
    ) u_impl (
      .clk            (clk),
      .reset          (reset),
      .cfg_reg_if     (cfg_reg_if),
      .dcache_bus_if  (dcache_bus_if),
      .lmem_bus_if    (lmem_bus_if),
      .done_if        (done_if)
    `ifdef PERF_ENABLE
      ,.perf          (perf)
    `endif
    );
  end else begin : g_aligned
    VX_dma_unit_align #(
      .INSTANCE_ID      (INSTANCE_ID),
      .DCACHE_ADDR_WIDTH(DCACHE_ADDR_WIDTH),
      .LMEM_ADDR_WIDTH  (LMEM_ADDR_WIDTH),
      .DCACHE_TAG_WIDTH (DCACHE_TAG_WIDTH),
      .LMEM_TAG_WIDTH   (LMEM_TAG_WIDTH),
      .RD_OUTSTANDING   (RD_OUTSTANDING),
      .FIXED_DIR        (FIXED_DIR)
    ) u_impl (
      .clk            (clk),
      .reset          (reset),
      .cfg_reg_if     (cfg_reg_if),
      .dcache_bus_if  (dcache_bus_if),
      .lmem_bus_if    (lmem_bus_if),
      .done_if        (done_if)
    `ifdef PERF_ENABLE
      ,.perf          (perf)
    `endif
    );
  end

endmodule
