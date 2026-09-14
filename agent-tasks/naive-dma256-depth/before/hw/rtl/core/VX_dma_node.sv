`include "VX_define.vh"

module VX_dma_node import VX_gpu_pkg::*; #(
  parameter `STRING INSTANCE_ID = "",
  parameter int N_MASTER     = 1,
  parameter int NUM_ENTRIES  = 16,
  parameter int LMEM_NUM_LANES_P = `LMEM_NUM_PORTS,
  parameter int DCACHE_NUM_LANES_P = `DMA_DCACHE_PORTS,
  // See VX_dma_unit. Default 0 (aligned-only) to track the engine-level
  // convention; override to 1 on paths where SW still emits misaligned bases.
  parameter bit ENABLE_MISALIGN = 1'b0,
  parameter int BOUND_WIDTH = `DMA_BOUND_WIDTH,
  parameter int MAX_DIMS = 3,
  // Forwarded to VX_dma_unit — DC v2023 rejects `interface_inst.PARAM`
  // in parameter binding contexts, so the parent must pass these explicitly.
  // Defaults track the VX_core-side interface widths (see VX_core.sv:87-95).
  parameter int DCACHE_TAG_WIDTH_P = DMA_DCACHE_TAG_WIDTH,
  parameter int LMEM_TAG_WIDTH_P   = LMEM_TAG_WIDTH,
  parameter int MISALIGN_PACK_BYTES = LSU_WORD_SIZE,
  parameter int RD_OUTSTANDING = `DMA_NODE_RD_OUTSTANDING_SLOT
) (
  input wire clk,
  input wire reset,

  VX_lsu_mem_if.slave     mmio_if[N_MASTER], // from LSU
  VX_mem_bus_if.master    dcache_bus_if, // to dcache
  VX_mem_bus_if.master    lmem_bus_if [LMEM_NUM_LANES_P] // to local memory lanes
`ifdef GEMM_NAIVE
  ,input wire [`LMEM_NUM_BANKS-1:0][2:0] naive_write_commit
`endif
`ifdef PERF_ENABLE
  ,output dma_perf_t perf
`endif
);

  localparam int NUM_REGS32      = `DMA_CFG_REG_NUM;
  localparam int ENTRYID_W       = `JOB_MMIO_ENTRYID_W;
  localparam int LMEM_WIDE_BYTES = LMEM_NUM_LANES_P * LSU_WORD_SIZE;
  localparam int DCACHE_WIDE_BYTES = DCACHE_NUM_LANES_P * DCACHE_WORD_SIZE;
  localparam int DMA_DCACHE_ADDR_WIDTH = `MEM_ADDR_WIDTH - `CLOG2(DCACHE_WIDE_BYTES);
  localparam int DMA_LMEM_ADDR_WIDTH   = `MEM_ADDR_WIDTH - `CLOG2(LMEM_WIDE_BYTES);
`ifdef JOB_MMIO_DMA_DESC_ONE_LANE
  localparam bit JOB_DESC_ONE_LANE = 1'b1;
`else
  localparam bit JOB_DESC_ONE_LANE = 1'b0;
`endif

  VX_config_reg_if #(
    .NUM(NUM_REGS32),
    .DW(32)
  ) cfg_reg_if ();

  VX_node_done_if done_if ();
`ifdef GEMM_NAIVE
  VX_node_done_if worker_done_if ();
  wire dma_writes_drained;
  assign done_if.entry_id = worker_done_if.entry_id;
`endif
  VX_dma_lookahead_if #(
    .BOUND_WIDTH(BOUND_WIDTH)
  ) dma_lookahead_if ();

  assign dma_lookahead_if.prepare_valid = 1'b0;
  assign dma_lookahead_if.prepare_id = '0;
  assign dma_lookahead_if.src_stride = '0;
  assign dma_lookahead_if.dst_stride = '0;
  assign dma_lookahead_if.bound = '0;
  assign dma_lookahead_if.activate = 1'b0;
  assign dma_lookahead_if.activate_id = '0;
  assign dma_lookahead_if.data_release = 1'b1;
  assign dma_lookahead_if.data_max_beats = '0;

  // VX_dma_unit operates on one aggregate local-memory beat. Split the
  // aggregate beat across physical LMEM ports so DMA bandwidth can scale
  // independently from the CPU LSU lane count.
  VX_mem_bus_if #(
    .DATA_SIZE(LMEM_WIDE_BYTES),
    .TAG_WIDTH(LMEM_TAG_WIDTH_P)
  ) lmem_wide_bus_if ();

`ifdef GEMM_NAIVE
  VX_mem_bus_if #(
    .DATA_SIZE(LMEM_WIDE_BYTES), .TAG_WIDTH(LMEM_TAG_WIDTH_P)
  ) fenced_lmem_bus_if ();
  wire allow_lmem_request;
  wire [`LMEM_NUM_BANKS-1:0] dma_bank_commit;
  for (genvar b = 0; b < `LMEM_NUM_BANKS; ++b) begin : g_dma_commit
    assign dma_bank_commit[b] = naive_write_commit[b][2:1] == 2'b11;
  end
  VX_naive_dma_write_fence #(
    .NUM_LANES(LMEM_NUM_LANES_P), .NUM_BANKS(`LMEM_NUM_BANKS)
  ) write_fence (
    .clk(clk), .reset(reset),
    .req_valid(lmem_wide_bus_if.req_valid), .req_write(lmem_wide_bus_if.req_data.rw),
    .req_byteen(lmem_wide_bus_if.req_data.byteen),
    .downstream_ready(fenced_lmem_bus_if.req_ready), .commit_valid(dma_bank_commit),
    .worker_done_valid(worker_done_if.valid), .frontend_done_ready(done_if.ready),
    .allow_request(allow_lmem_request), .drained(dma_writes_drained),
    .frontend_done_valid(done_if.valid), .worker_done_ready(worker_done_if.ready)
  );
  `UNUSED_VAR (dma_writes_drained)
  assign fenced_lmem_bus_if.req_valid = lmem_wide_bus_if.req_valid && allow_lmem_request;
  assign fenced_lmem_bus_if.req_data = lmem_wide_bus_if.req_data;
  assign lmem_wide_bus_if.req_ready = fenced_lmem_bus_if.req_ready && allow_lmem_request;
  assign lmem_wide_bus_if.rsp_valid = fenced_lmem_bus_if.rsp_valid;
  assign lmem_wide_bus_if.rsp_data = fenced_lmem_bus_if.rsp_data;
  assign fenced_lmem_bus_if.rsp_ready = lmem_wide_bus_if.rsp_ready;
`endif

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
    .CFG_BASE_ADDR(`DMA_REG_BASE_ADDR),
    .ONE_LANE_MMIO(JOB_DESC_ONE_LANE)
  ) u_job_frontend (
    .clk    (clk),
    .reset  (reset),
    .mmio_if(mmio_if),
    .issue_if(cfg_reg_if.master),
    .done_if(done_if.slave),
    .hw_write_valid_i(1'b0),
    .hw_write_entry_id_i('0),
    .hw_write_value_i('0)
  );

  // DMA backend worker:
  //  - consumes one dispatched descriptor at a time
  //  - selects aligned-only or misaligned implementation by parameter
  //  - reports completion via done_if(entry_id)
  VX_dma_unit #(
    .INSTANCE_ID      (INSTANCE_ID),
    .ENABLE_MISALIGN  (ENABLE_MISALIGN),
    .BOUND_WIDTH      (BOUND_WIDTH),
    .MAX_DIMS         (MAX_DIMS),
    .DCACHE_ADDR_WIDTH(DMA_DCACHE_ADDR_WIDTH),
    .LMEM_ADDR_WIDTH  (DMA_LMEM_ADDR_WIDTH),
    .DCACHE_TAG_WIDTH (DCACHE_TAG_WIDTH_P),
    .LMEM_TAG_WIDTH   (LMEM_TAG_WIDTH_P),
    .MISALIGN_PACK_BYTES (MISALIGN_PACK_BYTES),
    .RD_OUTSTANDING   (RD_OUTSTANDING)
  ) u_dma_unit (
    .clk          (clk),
    .reset        (reset),
    .cfg_reg_if   (cfg_reg_if.slave),
    .lookahead_if (dma_lookahead_if.slave),
    .dcache_bus_if(dcache_bus_if),
    .lmem_bus_if  (lmem_wide_bus_if),
`ifdef GEMM_NAIVE
    .done_if      (worker_done_if.master)
`else
    .done_if      (done_if.master)
`endif
`ifdef PERF_ENABLE
    ,.perf        (perf)
`endif
  );

  if (LMEM_NUM_LANES_P == 1) begin : g_single_lmem_lane
`ifdef GEMM_NAIVE
    `ASSIGN_VX_MEM_BUS_IF(lmem_bus_if[0], fenced_lmem_bus_if);
`else
    `ASSIGN_VX_MEM_BUS_IF(lmem_bus_if[0], lmem_wide_bus_if);
`endif
  end else begin : g_split_lmem_lanes
    VX_mem_bus_split #(
      .NUM_LANES      (LMEM_NUM_LANES_P),
      .LANE_DATA_SIZE (LSU_WORD_SIZE),
      .TAG_WIDTH      (LMEM_TAG_WIDTH_P),
      .ENABLE_LANE_MASK(1)
    ) lmem_lane_split (
      .clk         (clk),
      .reset       (reset),
`ifdef GEMM_NAIVE
      .wide_bus_if (fenced_lmem_bus_if),
`else
      .wide_bus_if (lmem_wide_bus_if),
`endif
      .lane_bus_if (lmem_bus_if)
    );
  end

endmodule
