`include "VX_define.vh"

module VX_gemm_dma_ctrl_with_dma import VX_gpu_pkg::*; #(
  parameter `STRING INSTANCE_ID = ""
) (
  input wire clk,
  input wire reset,

  VX_gemm_dma_ctrl_if.slave gemm_dma_ctrl_if,     // from gemm_ctrl

  VX_mem_bus_if.master    dcache_bus_if, // to dcache
  VX_mem_bus_if.master    lmem_bus_if,   // to local memory
  VX_gemm_sync_if.master  gemm_sync_if
);
  // ------------------------------------------------------------
  // Descriptor layout
  // ------------------------------------------------------------
  localparam int NUM_REGS     = 16;
  localparam int REGS_DW      = 32;
  localparam int NDIM         = 3;
  localparam int NUM_ENTRIES  = 4;
  localparam int ENTRYID_W    = 4;

  localparam int CFG_NUM_LANES = 4;
  localparam int CFG_DATA_SIZE = 16; // bytes

  VX_lsu_mem_if #(
    .NUM_LANES(CFG_NUM_LANES),
    .DATA_SIZE(CFG_DATA_SIZE),
    .TAG_WIDTH(45)
  ) dma_if[1]();

  VX_config_reg_if #(
    .NUM(NUM_REGS),
    .DW(REGS_DW)
  ) config_reg_if();

  VX_node_done_if node_done_if();

  initial begin
    if (config_reg_if.DW != REGS_DW) $fatal(1, "config_reg_if.DW must be 32");
    if (config_reg_if.NUM < NUM_REGS) $fatal(1, "config_reg_if.NUM(%0d) < NUM_REGS(%0d)", config_reg_if.NUM, NUM_REGS);
  end


  VX_gemm_dma_ctrl #(
    .DMA_CFG_STRIDE_BYTES(REGS_DW/8),
    .DMA_ENTRY_STRIDE_BYTES(NUM_REGS*REGS_DW/8),
    .ENTRYID_W(ENTRYID_W),
    .POLL_GAP_CYCLES(1),
    .ALLOC_RETRY_GAP_CYCLES(0)
  ) gemm_dma_ctrl (
    .clk(clk),
    .reset(reset),

    .gemm_dma_ctrl_if(gemm_dma_ctrl_if),
    .gemm_sync_if(gemm_sync_if),
    .dma_if(dma_if[0].master)
  );

  VX_job_frontend #(
    .NUM_ENTRIES(NUM_ENTRIES),
    .NUM_REGS32(NUM_REGS),
    .ENTRYID_W(ENTRYID_W)
  ) config_register (
    .clk(clk),
    .reset(reset),

    .mmio_if(dma_if),
    .issue_if(config_reg_if.master),
    .done_if(node_done_if.slave)
  );

  VX_dma_unit_misal #(.INSTANCE_ID("dma0")) dma_node (
    .clk          (clk),
    .reset        (reset),
    .cfg_reg_if   (config_reg_if.slave),
    .dcache_bus_if(dcache_bus_if),
    .lmem_bus_if  (lmem_bus_if),
    .done_if      (node_done_if.master)
  );


endmodule
