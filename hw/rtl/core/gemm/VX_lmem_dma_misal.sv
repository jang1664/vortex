`include "VX_define.vh"

//==============================================================================
// VX_lmem_dma_misal
//  Local-DMA policy wrapper around VX_dma_unit.
//
//  DIR=0 maps LMEM to the source (DCache-side common port) and GEMM to the
//  destination (LMEM-side common port). DIR=1 reverses the transfer.
//==============================================================================

module VX_lmem_dma_misal import VX_gpu_pkg::*; #(
  parameter `STRING INSTANCE_ID = "",
  parameter int DIR  = 0,
  parameter int NDIM = 3,
  parameter int TAG_WIDTH = 1,
  // Compatibility-only. The reused core is controlled by RD_OUTSTANDING.
  parameter int RD_PREFETCH_DEPTH = 1,
  parameter bit ENABLE_MISALIGN = 1'b0,
  // Numeric width parameters are explicit because Synopsys DC cannot bind
  // child parameters from interface-instance parameters reliably.
  parameter int LMEM_ADDR_WIDTH_P = 1,
  parameter int GEMM_ADDR_WIDTH_P = 1,
  parameter int LMEM_TAG_WIDTH_P  = TAG_WIDTH,
  parameter int GEMM_TAG_WIDTH_P  = TAG_WIDTH
) (
  input wire clk,
  input wire reset,

  VX_lmem_dma_ctrl_if.slave ctrl_if,
  VX_gemm_sync_if.master    gemm_sync_if,

  VX_mem_bus_if.master      lmem_bus_if,
  VX_mem_bus_if.master      gemm_bus_if
`ifdef PERF_ENABLE
  ,output dma_perf_t perf
`endif
);

  localparam int RD_OUTSTANDING = LMEM_DMA_RD_OUTSTANDING_SLOTS;
  localparam int SLOT_BITS = $clog2(RD_OUTSTANDING);
  localparam int LMEM_TAG_VALUE_W = LMEM_TAG_WIDTH_P - `UP(UUID_WIDTH);
  localparam int GEMM_TAG_VALUE_W = GEMM_TAG_WIDTH_P - `UP(UUID_WIDTH);
  localparam int BUS_BYTES = lmem_bus_if.DATA_SIZE;

  `UNUSED_PARAM (RD_PREFETCH_DEPTH)

  initial begin
    if ((DIR < 0) || (DIR > 1))
      $fatal(1, "%s: DIR(%0d) must be 0 or 1", INSTANCE_ID, DIR);
    if (NDIM != 3)
      $fatal(1, "%s: NDIM(%0d) unsupported, this implementation requires NDIM=3",
             INSTANCE_ID, NDIM);
    if (lmem_bus_if.DATA_SIZE != gemm_bus_if.DATA_SIZE)
      $fatal(1, "%s: DATA_SIZE mismatch (lmem=%0d, gemm=%0d)",
             INSTANCE_ID, lmem_bus_if.DATA_SIZE, gemm_bus_if.DATA_SIZE);
    if (LMEM_ADDR_WIDTH_P != lmem_bus_if.ADDR_WIDTH)
      $fatal(1, "%s: LMEM_ADDR_WIDTH_P(%0d) != lmem_bus_if.ADDR_WIDTH(%0d)",
             INSTANCE_ID, LMEM_ADDR_WIDTH_P, lmem_bus_if.ADDR_WIDTH);
    if (GEMM_ADDR_WIDTH_P != gemm_bus_if.ADDR_WIDTH)
      $fatal(1, "%s: GEMM_ADDR_WIDTH_P(%0d) != gemm_bus_if.ADDR_WIDTH(%0d)",
             INSTANCE_ID, GEMM_ADDR_WIDTH_P, gemm_bus_if.ADDR_WIDTH);
    if (LMEM_TAG_WIDTH_P != lmem_bus_if.TAG_WIDTH)
      $fatal(1, "%s: LMEM_TAG_WIDTH_P(%0d) != lmem_bus_if.TAG_WIDTH(%0d)",
             INSTANCE_ID, LMEM_TAG_WIDTH_P, lmem_bus_if.TAG_WIDTH);
    if (GEMM_TAG_WIDTH_P != gemm_bus_if.TAG_WIDTH)
      $fatal(1, "%s: GEMM_TAG_WIDTH_P(%0d) != gemm_bus_if.TAG_WIDTH(%0d)",
             INSTANCE_ID, GEMM_TAG_WIDTH_P, gemm_bus_if.TAG_WIDTH);
    if (LMEM_TAG_VALUE_W < SLOT_BITS)
      $fatal(1, "%s: LMEM tag.value width(%0d) < slot bits(%0d)",
             INSTANCE_ID, LMEM_TAG_VALUE_W, SLOT_BITS);
    if (GEMM_TAG_VALUE_W < SLOT_BITS)
      $fatal(1, "%s: GEMM tag.value width(%0d) < slot bits(%0d)",
             INSTANCE_ID, GEMM_TAG_VALUE_W, SLOT_BITS);
  end

  VX_config_reg_if #(
    .NUM (`DMA_CFG_REG_NUM),
    .DW  (32)
  ) dma_cfg_if ();

  VX_node_done_if dma_done_if ();

  typedef enum logic [1:0] {
    S_IDLE,
    S_COPY,
    S_SYNC,
    S_DONE
  } state_e;

  state_e state, state_n;
  logic [31:0] reg_idx_r;
  logic [31:0] reg_value_r;

  wire cfg_fire = dma_cfg_if.valid && dma_cfg_if.ready;

  always_comb begin
    dma_cfg_if.regs = '0;
    dma_cfg_if.regs[0][0] = 1'b1;
    dma_cfg_if.regs[1] = ctrl_if.dst_base_addr[31:0];
    dma_cfg_if.regs[2] = ctrl_if.dst_base_addr[63:32];
    dma_cfg_if.regs[3] = ctrl_if.src_base_addr[31:0];
    dma_cfg_if.regs[4] = ctrl_if.src_base_addr[63:32];
    for (int d = 0; d < NDIM; ++d) begin
      dma_cfg_if.regs[5 + 2*d] = ctrl_if.src_strides[d];
      dma_cfg_if.regs[6 + 2*d] = ctrl_if.dst_strides[d];
      dma_cfg_if.regs[11 + d] = ctrl_if.bounds[d];
    end
    dma_cfg_if.regs[14] = ctrl_if.seg_size;
    dma_cfg_if.regs[15] = 32'd0;
    dma_cfg_if.regs[16][0] = (DIR != 0);
    dma_cfg_if.entry_id = 32'd0;
    dma_cfg_if.valid = (state == S_IDLE) && ctrl_if.start;
  end

  always_comb begin
    state_n = state;
    unique case (state)
      S_IDLE: begin
        if (cfg_fire)
          state_n = S_COPY;
      end
      S_COPY: begin
        if (dma_done_if.valid) begin
        `ifdef GEMM_NAIVE
          state_n = S_DONE;
        `else
          state_n = S_SYNC;
        `endif
        end
      end
      S_SYNC: begin
        if (gemm_sync_if.valid && gemm_sync_if.ready)
          state_n = S_DONE;
      end
      S_DONE: begin
        state_n = S_IDLE;
      end
      default: begin
        state_n = S_IDLE;
      end
    endcase
  end

  always_ff @(posedge clk) begin
    if (reset) begin
      state <= S_IDLE;
      reg_idx_r <= '0;
      reg_value_r <= '0;
    end else begin
      state <= state_n;
      if (cfg_fire) begin
        reg_idx_r <= ctrl_if.reg_idx;
        reg_value_r <= ctrl_if.reg_value;
      end
    end
  end

  always_comb begin
    ctrl_if.idle = (state == S_IDLE);
    ctrl_if.done = (state == S_DONE);
    gemm_sync_if.reg_idx = reg_idx_r;
    gemm_sync_if.value = reg_value_r;
  `ifdef GEMM_NAIVE
    gemm_sync_if.valid = 1'b0;
    dma_done_if.ready = (state == S_COPY);
  `else
    gemm_sync_if.valid = (state == S_SYNC);
    dma_done_if.ready = (state == S_SYNC) && gemm_sync_if.ready;
  `endif
  end

`ifdef PERF_ENABLE
  dma_perf_t core_perf;
  `UNUSED_VAR (core_perf)
`endif

  VX_dma_unit #(
    .INSTANCE_ID         ({INSTANCE_ID, ":core"}),
    .ENABLE_MISALIGN     (ENABLE_MISALIGN),
    .DCACHE_ADDR_WIDTH   (LMEM_ADDR_WIDTH_P),
    .LMEM_ADDR_WIDTH     (GEMM_ADDR_WIDTH_P),
    .DCACHE_TAG_WIDTH    (LMEM_TAG_WIDTH_P),
    .LMEM_TAG_WIDTH      (GEMM_TAG_WIDTH_P),
    .RD_OUTSTANDING      (RD_OUTSTANDING),
    .FIXED_DIR           (DIR)
  ) dma_core (
    .clk           (clk),
    .reset         (reset),
    .cfg_reg_if    (dma_cfg_if),
    .dcache_bus_if (lmem_bus_if),
    .lmem_bus_if   (gemm_bus_if),
    .done_if       (dma_done_if)
  `ifdef PERF_ENABLE
    ,.perf         (core_perf)
  `endif
  );

`ifdef DBG_TRACE_GEMM
  always_ff @(posedge clk) begin
    if (!reset) begin
      if (cfg_fire) begin
        `TRACE(1, ("%m : [%0t] | LMEM_DMA_START | {inst=%s, dir=%0d, src=0x%0h, dst=0x%0h, seg_size=%0d}\n",
                   $time, INSTANCE_ID, DIR, ctrl_if.src_base_addr,
                   ctrl_if.dst_base_addr, ctrl_if.seg_size))
      end
      if (ctrl_if.done) begin
        `TRACE(1, ("%m : [%0t] | LMEM_DMA_DONE | {inst=%s, dir=%0d}\n",
                   $time, INSTANCE_ID, DIR))
      end
    end
  end
`endif

`ifdef PERF_ENABLE
  wire perf_src_req_valid = (DIR != 0) ? gemm_bus_if.req_valid
                                       : lmem_bus_if.req_valid;
  wire perf_src_req_ready = (DIR != 0) ? gemm_bus_if.req_ready
                                       : lmem_bus_if.req_ready;
  wire perf_src_rsp_valid = (DIR != 0) ? gemm_bus_if.rsp_valid
                                       : lmem_bus_if.rsp_valid;
  wire perf_src_rsp_ready = (DIR != 0) ? gemm_bus_if.rsp_ready
                                       : lmem_bus_if.rsp_ready;
  wire perf_dst_req_valid = (DIR != 0) ? lmem_bus_if.req_valid
                                       : gemm_bus_if.req_valid;
  wire perf_dst_req_ready = (DIR != 0) ? lmem_bus_if.req_ready
                                       : gemm_bus_if.req_ready;

  wire dma_is_active = (state == S_COPY) || (state == S_SYNC);
  wire dma_xfer_done = (state != S_DONE) && (state_n == S_DONE);
  wire perf_src_rd_req_fire = perf_src_req_valid && perf_src_req_ready;
  wire perf_src_rd_req_stall = perf_src_req_valid && !perf_src_req_ready;
  wire perf_src_rd_data_fire = perf_src_rsp_valid && perf_src_rsp_ready;
  wire perf_src_rd_data_stall = perf_src_rsp_valid && !perf_src_rsp_ready;
  wire perf_dst_wr_fire = perf_dst_req_valid && perf_dst_req_ready;
  wire perf_dst_wr_stall = perf_dst_req_valid && !perf_dst_req_ready;

  reg dma_is_active_q, dma_xfer_done_q;
  reg perf_src_rd_req_fire_q, perf_src_rd_req_stall_q;
  reg perf_src_rd_data_fire_q, perf_src_rd_data_stall_q;
  reg perf_dst_wr_fire_q, perf_dst_wr_stall_q;

  reg [PERF_CTR_BITS-1:0] perf_rd_bytes_r;
  reg [PERF_CTR_BITS-1:0] perf_wr_bytes_r;
  reg [PERF_CTR_BITS-1:0] perf_xfers_r;
  reg [PERF_CTR_BITS-1:0] perf_active_r;
  reg [PERF_CTR_BITS-1:0] perf_src_rd_req_fire_r, perf_src_rd_req_stall_r;
  reg [PERF_CTR_BITS-1:0] perf_src_rd_data_fire_r, perf_src_rd_data_stall_r;
  reg [PERF_CTR_BITS-1:0] perf_dst_wr_fire_r, perf_dst_wr_stall_r;

  always_ff @(posedge clk) begin
    if (reset) begin
      dma_is_active_q <= 1'b0;
      dma_xfer_done_q <= 1'b0;
      perf_src_rd_req_fire_q <= 1'b0;
      perf_src_rd_req_stall_q <= 1'b0;
      perf_src_rd_data_fire_q <= 1'b0;
      perf_src_rd_data_stall_q <= 1'b0;
      perf_dst_wr_fire_q <= 1'b0;
      perf_dst_wr_stall_q <= 1'b0;
    end else begin
      dma_is_active_q <= dma_is_active;
      dma_xfer_done_q <= dma_xfer_done;
      perf_src_rd_req_fire_q <= perf_src_rd_req_fire;
      perf_src_rd_req_stall_q <= perf_src_rd_req_stall;
      perf_src_rd_data_fire_q <= perf_src_rd_data_fire;
      perf_src_rd_data_stall_q <= perf_src_rd_data_stall;
      perf_dst_wr_fire_q <= perf_dst_wr_fire;
      perf_dst_wr_stall_q <= perf_dst_wr_stall;
    end
  end

  always_ff @(posedge clk) begin
    if (reset) begin
      perf_rd_bytes_r <= '0;
      perf_wr_bytes_r <= '0;
      perf_xfers_r <= '0;
      perf_active_r <= '0;
      perf_src_rd_req_fire_r <= '0;
      perf_src_rd_req_stall_r <= '0;
      perf_src_rd_data_fire_r <= '0;
      perf_src_rd_data_stall_r <= '0;
      perf_dst_wr_fire_r <= '0;
      perf_dst_wr_stall_r <= '0;
    end else begin
      if (perf_src_rd_data_fire_q)
        perf_rd_bytes_r <= perf_rd_bytes_r + PERF_CTR_BITS'(BUS_BYTES);
      if (perf_dst_wr_fire_q)
        perf_wr_bytes_r <= perf_wr_bytes_r + PERF_CTR_BITS'(BUS_BYTES);
      if (dma_xfer_done_q)
        perf_xfers_r <= perf_xfers_r + PERF_CTR_BITS'(1);
      if (dma_is_active_q)
        perf_active_r <= perf_active_r + PERF_CTR_BITS'(1);
      if (perf_src_rd_req_fire_q)
        perf_src_rd_req_fire_r <= perf_src_rd_req_fire_r + PERF_CTR_BITS'(1);
      if (perf_src_rd_req_stall_q)
        perf_src_rd_req_stall_r <= perf_src_rd_req_stall_r + PERF_CTR_BITS'(1);
      if (perf_src_rd_data_fire_q)
        perf_src_rd_data_fire_r <= perf_src_rd_data_fire_r + PERF_CTR_BITS'(1);
      if (perf_src_rd_data_stall_q)
        perf_src_rd_data_stall_r <= perf_src_rd_data_stall_r + PERF_CTR_BITS'(1);
      if (perf_dst_wr_fire_q)
        perf_dst_wr_fire_r <= perf_dst_wr_fire_r + PERF_CTR_BITS'(1);
      if (perf_dst_wr_stall_q)
        perf_dst_wr_stall_r <= perf_dst_wr_stall_r + PERF_CTR_BITS'(1);
    end
  end

  assign perf.rd_bytes = perf_rd_bytes_r;
  assign perf.wr_bytes = perf_wr_bytes_r;
  assign perf.xfer_count = perf_xfers_r;
  assign perf.active_cycles = perf_active_r;
  assign perf.src_rd_req_fire = perf_src_rd_req_fire_r;
  assign perf.src_rd_req_stall = perf_src_rd_req_stall_r;
  assign perf.src_rd_data_fire = perf_src_rd_data_fire_r;
  assign perf.src_rd_data_stall = perf_src_rd_data_stall_r;
  assign perf.dst_wr_fire = perf_dst_wr_fire_r;
  assign perf.dst_wr_stall = perf_dst_wr_stall_r;
  assign perf.wait_dcache = '0;
  assign perf.wait_lmem = '0;
  assign perf.busy = dma_is_active;
`endif

`ifdef CHIPSCOPE
`ifdef DBG_SCOPE_GEMM
  (* keep = "true", mark_debug = "true" *) wire [63:0] dbg_lmem_dma_top = {
    state,
    ctrl_if.start,
    ctrl_if.idle,
    ctrl_if.done,
    dma_cfg_if.valid,
    dma_cfg_if.ready,
    dma_done_if.valid,
    dma_done_if.ready,
    gemm_sync_if.valid,
    gemm_sync_if.ready,
    lmem_bus_if.req_valid,
    lmem_bus_if.req_ready,
    lmem_bus_if.rsp_valid,
    lmem_bus_if.rsp_ready,
    gemm_bus_if.req_valid,
    gemm_bus_if.req_ready,
    gemm_bus_if.rsp_valid,
    gemm_bus_if.rsp_ready,
    45'd0
  };
`endif
`endif

endmodule
