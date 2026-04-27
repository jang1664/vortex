`include "VX_define.vh"

module VX_dma_node import VX_gpu_pkg::*; #(
  parameter `STRING INSTANCE_ID = "",
  parameter int N_MASTER     = 1,
  parameter int NUM_ENTRIES  = 16
) (
  input wire clk,
  input wire reset,

  VX_lsu_mem_if.slave     mmio_if[N_MASTER], // from LSU
  VX_mem_bus_if.master    dcache_bus_if, // to dcache (single 64B port)
  VX_mem_bus_if.master    lmem_bus_if [`NUM_LSU_LANES] // per-lane to lmem
`ifdef PERF_ENABLE
  ,output dma_perf_t perf
`endif
);

  localparam int NUM_REGS32      = `DMA_CFG_REG_NUM;
  localparam int ENTRYID_W       = `JOB_MMIO_ENTRYID_W;
  localparam int LMEM_WIDE_BYTES = `NUM_LSU_LANES * LSU_WORD_SIZE;

  VX_config_reg_if #(
    .NUM(NUM_REGS32),
    .DW(32)
  ) cfg_reg_if ();

  VX_node_done_if done_if ();

  // Internal wide LMEM bus seen by VX_dma_unit_misal (DATA_SIZE = 64B).
  // VX_dma_unit_misal is width-parameterized via lmem_bus_if.DATA_SIZE so the
  // engine works at the aggregate 64B granularity; the per-lane scatter below
  // converts that to NUM_LSU_LANES x 8B for the external interface.
  VX_mem_bus_if #(
    .DATA_SIZE(LMEM_WIDE_BYTES),
    .TAG_WIDTH(LMEM_TAG_WIDTH)
  ) lmem_wide_bus_if ();

  // MMIO front-end:
  //  - handles multi-master arbitration
  //  - stores descriptor entries
  //  - dispatches ready entries to dma unit
  VX_job_frontend #(
    .INSTANCE_ID  (INSTANCE_ID),
    .NUM_MASTERS  (N_MASTER),
    .NUM_ENTRIES  (NUM_ENTRIES),
    .NUM_REGS32   (NUM_REGS32),
    .ENTRYID_W    (ENTRYID_W),
    .CFG_BASE_ADDR(`DMA_REG_BASE_ADDR)
  ) u_job_frontend (
    .clk    (clk),
    .reset  (reset),
    .mmio_if(mmio_if),
    .issue_if(cfg_reg_if.master),
    .done_if(done_if.slave)
  );

  // DMA backend worker:
  //  - consumes one dispatched descriptor at a time
  //  - performs misalignment-safe 3D copy
  //  - reports completion via done_if(entry_id)
  VX_dma_unit_misal #(
    .INSTANCE_ID(INSTANCE_ID)
  ) u_dma_unit_misal (
    .clk          (clk),
    .reset        (reset),
    .cfg_reg_if   (cfg_reg_if.slave),
    .dcache_bus_if(dcache_bus_if),
    .lmem_bus_if  (lmem_wide_bus_if),
    .done_if      (done_if.master)
  `ifdef PERF_ENABLE
    ,.perf(perf)
  `endif
  );

  // -------------------------------------------------------------------------
  // Lane scatter: 64B wide LMEM bus -> NUM_LSU_LANES x 8B narrow buses.
  // Wait-all-lanes rsp gather (per-lane skid + AND release) is required
  // because the wide bus has no per-lane mask field.
  // -------------------------------------------------------------------------
  VX_mem_bus_split #(
    .NUM_LANES     (`NUM_LSU_LANES),
    .LANE_DATA_SIZE(LSU_WORD_SIZE),
    .TAG_WIDTH     (LMEM_TAG_WIDTH)
  ) lmem_lane_split (
    .clk         (clk),
    .reset       (reset),
    .wide_bus_if (lmem_wide_bus_if),
    .lane_bus_if (lmem_bus_if)
  );

endmodule
