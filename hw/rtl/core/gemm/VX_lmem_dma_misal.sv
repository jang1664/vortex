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
  parameter int RD_OUTSTANDING = `LMEM_DMA_RD_OUTSTANDING_SLOTS,
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
    if (((lmem_bus_if.DATA_SIZE % gemm_bus_if.DATA_SIZE) != 0)
     && ((gemm_bus_if.DATA_SIZE % lmem_bus_if.DATA_SIZE) != 0))
      $fatal(1, "%s: DATA_SIZE values must be divisible (lmem=%0d, gemm=%0d)",
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
  VX_dma_lookahead_if dma_lookahead_if ();

  assign dma_lookahead_if.prepare_valid = 1'b0;
  assign dma_lookahead_if.prepare_id = '0;
  assign dma_lookahead_if.src_stride = '0;
  assign dma_lookahead_if.dst_stride = '0;
  assign dma_lookahead_if.bound = '0;
  assign dma_lookahead_if.activate = 1'b0;
  assign dma_lookahead_if.activate_id = '0;

  typedef enum logic [1:0] {
    S_IDLE,
    S_COPY,
    S_SYNC,
    S_DONE
  } state_e;

  state_e state, state_n;
  logic [31:0] reg_idx_r;
  logic [31:0] reg_value_r;
  logic [63:0] write_bytes_remaining_r;
  logic prepared_r;
  logic released_r;
  logic [63:0] prepared_src_base_r;
  logic [63:0] prepared_dst_base_r;
  logic [31:0] prepared_src_strides_r[NDIM];
  logic [31:0] prepared_dst_strides_r[NDIM];
  logic [31:0] prepared_bounds_r[NDIM];
  logic [31:0] prepared_seg_size_r;

  logic prepared_descriptor_match;
  wire prepare_supported = (DIR == 0) && !ENABLE_MISALIGN;
  always_comb begin
    prepared_descriptor_match = prepared_r
        && (ctrl_if.src_base_addr == prepared_src_base_r)
        && (ctrl_if.dst_base_addr == prepared_dst_base_r)
        && (ctrl_if.seg_size == prepared_seg_size_r);
    for (int d = 0; d < NDIM; ++d) begin
      prepared_descriptor_match &=
          (ctrl_if.src_strides[d] == prepared_src_strides_r[d])
       && (ctrl_if.dst_strides[d] == prepared_dst_strides_r[d])
       && (ctrl_if.bounds[d] == prepared_bounds_r[d]);
    end
  end

  wire prepare_fire = ctrl_if.prepare && ctrl_if.prepare_ready;
  wire release_fire = ctrl_if.start && ctrl_if.idle;

  // Unsupported and ordinary start-only transfers always use normal release
  // semantics.  Only a supported prepare transaction may close the commit
  // gate; release is registered before reopening it so completion cannot race
  // the scheduler's same-edge inflight metadata insertion.
  assign dma_lookahead_if.data_release = !prepare_supported
      || released_r || (!prepared_r && !ctrl_if.prepare);
  assign dma_lookahead_if.data_max_beats
      = (prepare_supported && ctrl_if.prepare)
      ? ctrl_if.prepare_max_beats : '0;

  wire cfg_fire = dma_cfg_if.valid && dma_cfg_if.ready;
  wire [63:0] descriptor_write_bytes
      = 64'(ctrl_if.seg_size)
      * 64'(ctrl_if.bounds[0])
      * 64'(ctrl_if.bounds[1])
      * 64'(ctrl_if.bounds[2]);
  wire dst_write_fire = (DIR != 0)
      ? (lmem_bus_if.req_valid && lmem_bus_if.req_ready
         && lmem_bus_if.req_data.rw)
      : (gemm_bus_if.req_valid && gemm_bus_if.req_ready
         && gemm_bus_if.req_data.rw);
  wire [31:0] dst_write_bytes = (DIR != 0)
      ? 32'($countones(lmem_bus_if.req_data.byteen))
      : 32'($countones(gemm_bus_if.req_data.byteen));

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
    dma_cfg_if.valid = (state == S_IDLE)
                    && (ctrl_if.start
                     || (ctrl_if.prepare && prepare_supported));
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
        `ifdef GEMM_IMPROVE
          state_n = S_DONE;
        `elsif GEMM_NAIVE
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
      write_bytes_remaining_r <= '0;
      prepared_r <= 1'b0;
      released_r <= 1'b0;
      prepared_src_base_r <= '0;
      prepared_dst_base_r <= '0;
      prepared_seg_size_r <= '0;
      for (int d = 0; d < NDIM; ++d) begin
        prepared_src_strides_r[d] <= '0;
        prepared_dst_strides_r[d] <= '0;
        prepared_bounds_r[d] <= '0;
      end
    end else begin
      state <= state_n;
      if (cfg_fire) begin
        reg_idx_r <= ctrl_if.reg_idx;
        reg_value_r <= ctrl_if.reg_value;
        write_bytes_remaining_r <= descriptor_write_bytes;
        prepared_r <= ctrl_if.prepare && !ctrl_if.start;
        released_r <= ctrl_if.start;
        prepared_src_base_r <= ctrl_if.src_base_addr;
        prepared_dst_base_r <= ctrl_if.dst_base_addr;
        prepared_seg_size_r <= ctrl_if.seg_size;
        for (int d = 0; d < NDIM; ++d) begin
          prepared_src_strides_r[d] <= ctrl_if.src_strides[d];
          prepared_dst_strides_r[d] <= ctrl_if.dst_strides[d];
          prepared_bounds_r[d] <= ctrl_if.bounds[d];
        end
      end else if (release_fire && prepared_r) begin
        prepared_r <= 1'b0;
        released_r <= 1'b1;
      end else if (dst_write_fire) begin
        write_bytes_remaining_r
            <= write_bytes_remaining_r - 64'(dst_write_bytes);
      end
      if (state == S_DONE) begin
        prepared_r <= 1'b0;
        released_r <= 1'b0;
      end
    end
  end

  always_comb begin
    ctrl_if.prepare_ready = prepare_supported
                         && (state == S_IDLE) && dma_cfg_if.ready;
    ctrl_if.idle = ((state == S_IDLE) && dma_cfg_if.ready)
                || ((state == S_COPY) && prepared_descriptor_match
                 && !released_r);
    ctrl_if.done = (state == S_DONE);
    ctrl_if.write_done = dst_write_fire
                      && (write_bytes_remaining_r != 0)
                      && (write_bytes_remaining_r <= 64'(dst_write_bytes));
    gemm_sync_if.reg_idx = reg_idx_r;
    gemm_sync_if.value = reg_value_r;
  `ifdef GEMM_IMPROVE
    gemm_sync_if.valid = 1'b0;
    dma_done_if.ready = (state == S_COPY);
  `elsif GEMM_NAIVE
    gemm_sync_if.valid = 1'b0;
    dma_done_if.ready = (state == S_COPY);
  `else
    gemm_sync_if.valid = (state == S_SYNC);
    dma_done_if.ready = (state == S_SYNC) && gemm_sync_if.ready;
  `endif
  end

`ifndef SYNTHESIS
  always_ff @(posedge clk) begin
    if (!reset) begin
      if (prepare_fire) begin
        assert (prepare_supported && !ctrl_if.start
             && (ctrl_if.prepare_max_beats != 0))
          else $fatal(1, "%s: invalid local-DMA prepare request", INSTANCE_ID);
      end
      if (release_fire && prepared_r) begin
        assert (prepared_descriptor_match)
          else $fatal(1, "%s: local-DMA release descriptor mismatch",
                      INSTANCE_ID);
      end
      if (dst_write_fire) begin
        assert (released_r || release_fire)
          else $fatal(1, "%s: prepared local-DMA wrote before release",
                      INSTANCE_ID);
        assert ((write_bytes_remaining_r != 0)
             && (64'(dst_write_bytes) <= write_bytes_remaining_r))
          else $fatal(1, "%s: destination write exceeded descriptor byte count",
                      INSTANCE_ID);
      end
      if (ctrl_if.write_done) begin
        assert (dst_write_fire
             && (write_bytes_remaining_r <= 64'(dst_write_bytes)))
          else $fatal(1, "%s: write_done did not match final destination write",
                      INSTANCE_ID);
      end
      if (dma_done_if.valid) begin
        assert (write_bytes_remaining_r == 0)
          else $fatal(1, "%s: DMA core completed before final destination write",
                      INSTANCE_ID);
      end
    end
  end
`endif

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
    .lookahead_if  (dma_lookahead_if),
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
      if (prepare_fire) begin
        `TRACE(1, ("%m : [%0t] | LMEM_DMA_PREPARE | {inst=%s, dir=%0d, src=0x%0h, dst=0x%0h, seg_size=%0d, max_beats=%0d}\n",
                   $time, INSTANCE_ID, DIR, ctrl_if.src_base_addr,
                   ctrl_if.dst_base_addr, ctrl_if.seg_size,
                   ctrl_if.prepare_max_beats))
      end
      if (release_fire && prepared_r) begin
        `TRACE(1, ("%m : [%0t] | LMEM_DMA_RELEASE | {inst=%s, dir=%0d, src=0x%0h, dst=0x%0h}\n",
                   $time, INSTANCE_ID, DIR, ctrl_if.src_base_addr,
                   ctrl_if.dst_base_addr))
      end
      if (cfg_fire && !ctrl_if.prepare) begin
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

//==============================================================================
// VX_lmem_dma_input_overlap
//  Input-only TMEM-to-GEMM DMA with four ordered descriptor contexts and one
//  shared eight-slot response ring.  Source reads may run ahead of GEMM
//  admission; downstream valid/ready backpressure is the admission fence.
//==============================================================================

module VX_lmem_dma_input_overlap import VX_gpu_pkg::*; #(
  parameter `STRING INSTANCE_ID = "",
  parameter int NDIM = 3,
  parameter int TAG_WIDTH = 1,
  parameter int CMD_FIFO_DEPTH = 4,
  parameter int RESPONSE_SLOTS = 8,
  parameter bit ENABLE_TMEM_URGENCY = 1'b0,
  parameter bit ENABLE_SCHED_SOURCE_GATE = 1'b0,
  parameter int READY_AHEAD_LOW_WATERMARK = 4,
  parameter bit ENABLE_WRITER_FENCE = 1'b0,
  parameter bit ENABLE_SAME_CYCLE_CMD_RECYCLE = 1'b1,
  parameter int WRITER_RID0 = 0,
  parameter int WRITER_RID1 = 0,
  parameter int LMEM_ADDR_WIDTH_P = 1,
  parameter int GEMM_ADDR_WIDTH_P = 1,
  parameter int LMEM_TAG_WIDTH_P = TAG_WIDTH,
  parameter int GEMM_TAG_WIDTH_P = TAG_WIDTH
) (
  input wire clk,
  input wire reset,
  input wire sched_source_enable_i,
  input wire [GEMM_SCHED_PRIORITY_WIDTH-1:0] sched_priority_i,

  VX_lmem_dma_ctrl_if.slave ctrl_if,
  input gemm_wait_meta_t     writer_wait_i,
  input wire [31:0]          writer_consume_value0_i,
  input wire [31:0]          writer_consume_value1_i,
  VX_gemm_sync_if.master    gemm_sync_if,
  VX_mem_bus_if.master      lmem_bus_if,
  VX_mem_bus_if.master      gemm_bus_if,
  output wire               lmem_req_urgent_o,
  output wire [GEMM_SCHED_PRIORITY_WIDTH-1:0] lmem_req_priority_o,
  output wire [$clog2(RESPONSE_SLOTS + 1)-1:0] ready_ahead_o,
  output wire               sched_source_valid_o,
  output wire [31:0]        sched_source_work_seq_o,
  output wire [31:0]        sched_source_total_beats_o,
  output wire [31:0]        sched_source_request_beats_o,
  output wire [31:0]        sched_source_response_beats_o,
  output wire [31:0]        sched_source_writer_beats_o,
  output wire [$clog2(RESPONSE_SLOTS + 1)-1:0]
                            sched_slot_occupancy_o,
  output wire               sched_fetch_complete_o,
  output wire [31:0]        sched_fetch_complete_work_seq_o
`ifdef PERF_ENABLE
  ,output dma_perf_t perf
`endif
);

  localparam int BUS_BYTES = lmem_bus_if.DATA_SIZE;
  localparam int BUS_ADDR_BITS = `CLOG2(BUS_BYTES);
  localparam int CMD_PTR_BITS = $clog2(CMD_FIFO_DEPTH);
  localparam int CMD_COUNT_BITS = $clog2(CMD_FIFO_DEPTH + 1);
  localparam int SLOT_BITS = $clog2(RESPONSE_SLOTS);
  localparam int SLOT_COUNT_BITS = $clog2(RESPONSE_SLOTS + 1);
  localparam int LMEM_TAG_VALUE_W = LMEM_TAG_WIDTH_P - `UP(UUID_WIDTH);

  typedef enum logic [1:0] {
    SLOT_FREE,
    SLOT_WAIT_RSP,
    SLOT_READY,
    SLOT_DRAINING
  } slot_state_e;

  logic [CMD_FIFO_DEPTH-1:0] cmd_valid_r;
  logic [CMD_FIFO_DEPTH-1:0] cmd_rd_done_r;
  logic [63:0] cmd_src_base_r[CMD_FIFO_DEPTH];
  logic [63:0] cmd_dst_base_r[CMD_FIFO_DEPTH];
  logic [31:0] cmd_src_strides_r[CMD_FIFO_DEPTH][NDIM];
  logic [31:0] cmd_dst_strides_r[CMD_FIFO_DEPTH][NDIM];
  logic [31:0] cmd_bounds_r[CMD_FIFO_DEPTH][NDIM];
  logic [31:0] cmd_seg_size_r[CMD_FIFO_DEPTH];
  logic [31:0] cmd_reg_idx_r[CMD_FIFO_DEPTH];
  logic [31:0] cmd_reg_value_r[CMD_FIFO_DEPTH];
  logic [31:0] cmd_total_beats_r[CMD_FIFO_DEPTH];
  logic [31:0] cmd_rd_count_r[CMD_FIFO_DEPTH];
  logic [31:0] cmd_wr_count_r[CMD_FIFO_DEPTH];
  logic [31:0] cmd_rsp_count_r[CMD_FIFO_DEPTH];
  logic [31:0] cmd_rd_i_dim_r[CMD_FIFO_DEPTH][NDIM];
  logic [31:0] cmd_rd_seg_offset_r[CMD_FIFO_DEPTH];
  logic [31:0] cmd_wr_i_dim_r[CMD_FIFO_DEPTH][NDIM];
  logic [31:0] cmd_wr_seg_offset_r[CMD_FIFO_DEPTH];
  gemm_wait_meta_t cmd_writer_wait_r[CMD_FIFO_DEPTH];
  logic [31:0] cmd_sequence_r[CMD_FIFO_DEPTH];
  logic [31:0] cmd_scheduler_work_seq_r[CMD_FIFO_DEPTH];

  logic [CMD_PTR_BITS-1:0] rd_cmd_ptr_r;
  logic [CMD_PTR_BITS-1:0] wr_cmd_ptr_r;
  logic [CMD_PTR_BITS-1:0] cmd_tail_ptr_r;
  logic [CMD_COUNT_BITS-1:0] cmd_count_r;
  logic [31:0] next_cmd_sequence_r;

  slot_state_e slot_state_r[RESPONSE_SLOTS];
  logic [CMD_PTR_BITS-1:0] slot_owner_cmd_r[RESPONSE_SLOTS];
  logic [31:0] slot_owner_sequence_r[RESPONSE_SLOTS];
  logic [31:0] slot_owner_beat_r[RESPONSE_SLOTS];
  logic [SLOT_BITS-1:0] alloc_slot_r;
  logic [SLOT_BITS-1:0] wr_expect_slot_r;
  logic [SLOT_COUNT_BITS-1:0] slot_occupancy_r;

  logic drain_valid_r;
  logic [SLOT_BITS-1:0] drain_slot_r;
  logic [CMD_PTR_BITS-1:0] drain_owner_cmd_r;
  logic [31:0] drain_owner_sequence_r;
  logic [31:0] drain_owner_beat_r;
  wire [BUS_BYTES*8-1:0] drain_payload;

  logic [SLOT_COUNT_BITS-1:0] consecutive_ready_ahead;
  logic ready_prefix;
  logic source_urgent_hold_valid_r;
  logic source_urgent_hold_r;
  logic [GEMM_SCHED_PRIORITY_WIDTH-1:0] source_priority_hold_r;

  wire cmd_fifo_full = (cmd_count_r == CMD_COUNT_BITS'(CMD_FIFO_DEPTH));
  wire rd_cmd_valid = cmd_valid_r[rd_cmd_ptr_r]
                   && !cmd_rd_done_r[rd_cmd_ptr_r];
  wire [63:0] rd_src_byte_addr = cmd_src_base_r[rd_cmd_ptr_r]
      + 64'(cmd_rd_i_dim_r[rd_cmd_ptr_r][0]
          * cmd_src_strides_r[rd_cmd_ptr_r][0])
      + 64'(cmd_rd_i_dim_r[rd_cmd_ptr_r][1]
          * cmd_src_strides_r[rd_cmd_ptr_r][1])
      + 64'(cmd_rd_i_dim_r[rd_cmd_ptr_r][2]
          * cmd_src_strides_r[rd_cmd_ptr_r][2])
      + 64'(cmd_rd_seg_offset_r[rd_cmd_ptr_r]);
  wire [63:0] wr_dst_progressed_byte_addr = cmd_dst_base_r[wr_cmd_ptr_r]
      + 64'(cmd_wr_i_dim_r[wr_cmd_ptr_r][0]
          * cmd_dst_strides_r[wr_cmd_ptr_r][0])
      + 64'(cmd_wr_i_dim_r[wr_cmd_ptr_r][1]
          * cmd_dst_strides_r[wr_cmd_ptr_r][1])
      + 64'(cmd_wr_i_dim_r[wr_cmd_ptr_r][2]
          * cmd_dst_strides_r[wr_cmd_ptr_r][2])
      + 64'(cmd_wr_seg_offset_r[wr_cmd_ptr_r]);
  // Preserve the established Input executor destination contract.  Only the
  // qparam specialization requires full destination descriptor progression.
  wire [63:0] wr_dst_byte_addr = ENABLE_WRITER_FENCE
      ? wr_dst_progressed_byte_addr : cmd_dst_base_r[wr_cmd_ptr_r];

  wire source_req_fire = lmem_bus_if.req_valid && lmem_bus_if.req_ready;
  wire [SLOT_BITS-1:0] source_rsp_slot
      = SLOT_BITS'(lmem_bus_if.rsp_data.tag.value);
  wire source_rsp_legal = !lmem_bus_if.rsp_valid
      || (slot_state_r[source_rsp_slot] == SLOT_WAIT_RSP);
  wire source_rsp_fire = lmem_bus_if.rsp_valid && lmem_bus_if.rsp_ready;

  wire drain_matches_writer = cmd_valid_r[wr_cmd_ptr_r]
      && (drain_owner_cmd_r == wr_cmd_ptr_r)
      && (drain_owner_sequence_r == cmd_sequence_r[wr_cmd_ptr_r])
      && (drain_owner_beat_r == cmd_wr_count_r[wr_cmd_ptr_r]);
  wire destination_write_fire = gemm_bus_if.req_valid
                              && gemm_bus_if.req_ready;
  wire destination_last_write = destination_write_fire
      && ((cmd_wr_count_r[wr_cmd_ptr_r] + 32'd1)
          == cmd_total_beats_r[wr_cmd_ptr_r]);
  wire command_enqueue = ctrl_if.start && ctrl_if.idle;
  wire writer_wait_rid_is0
      = cmd_writer_wait_r[wr_cmd_ptr_r].reg_id
     == GEMM_SYNC_REG_ID_WIDTH'(WRITER_RID0);
  wire writer_wait_rid_is1
      = cmd_writer_wait_r[wr_cmd_ptr_r].reg_id
     == GEMM_SYNC_REG_ID_WIDTH'(WRITER_RID1);
  wire writer_wait_rid_valid = writer_wait_rid_is0 || writer_wait_rid_is1;
  wire [31:0] writer_consume_value = writer_wait_rid_is1
      ? writer_consume_value1_i : writer_consume_value0_i;
  wire writer_released = !ENABLE_WRITER_FENCE
      || !cmd_writer_wait_r[wr_cmd_ptr_r].valid
      || (writer_wait_rid_valid
       && (writer_consume_value
           >= cmd_writer_wait_r[wr_cmd_ptr_r].target));

  // Count only the staged drain beat and the consecutive READY prefix at the
  // writer head.  WAIT_RSP occupancy is deliberately excluded.
  always_comb begin
    consecutive_ready_ahead = SLOT_COUNT_BITS'(drain_valid_r);
    ready_prefix = 1'b1;
    for (int offset = 0; offset < RESPONSE_SLOTS; ++offset) begin
      if (ready_prefix
       && (slot_state_r[SLOT_BITS'(wr_expect_slot_r + SLOT_BITS'(offset))]
           == SLOT_READY)) begin
        if (consecutive_ready_ahead < SLOT_COUNT_BITS'(RESPONSE_SLOTS))
          consecutive_ready_ahead = consecutive_ready_ahead
                                  + SLOT_COUNT_BITS'(1);
      end else begin
        ready_prefix = 1'b0;
      end
    end
  end

  wire source_urgent_now = writer_released
      && (consecutive_ready_ahead
          < SLOT_COUNT_BITS'(READY_AHEAD_LOW_WATERMARK));
  assign lmem_req_priority_o = source_urgent_hold_valid_r
      ? source_priority_hold_r : sched_priority_i;
  // A scheduler-managed P0 is an intentional background decision, not an
  // invitation for legacy ready-ahead urgency to raise the request again.
  // Unmanaged descriptors (work_seq zero) retain the legacy fallback.
  assign lmem_req_urgent_o = ENABLE_TMEM_URGENCY
      && (source_urgent_hold_valid_r ? source_urgent_hold_r
                                     : source_urgent_now)
      && ((cmd_scheduler_work_seq_r[rd_cmd_ptr_r] == 0)
       || (lmem_req_priority_o != GEMM_SCHED_PRIORITY_BACKGROUND));
  assign ready_ahead_o = consecutive_ready_ahead;
  assign sched_source_valid_o = rd_cmd_valid;
  assign sched_source_work_seq_o
      = cmd_scheduler_work_seq_r[rd_cmd_ptr_r];
  assign sched_source_total_beats_o = rd_cmd_valid
      ? cmd_total_beats_r[rd_cmd_ptr_r] : '0;
  assign sched_source_request_beats_o = rd_cmd_valid
      ? cmd_rd_count_r[rd_cmd_ptr_r] : '0;
  assign sched_source_response_beats_o = rd_cmd_valid
      ? cmd_rsp_count_r[rd_cmd_ptr_r] : '0;
  assign sched_source_writer_beats_o = rd_cmd_valid
      ? cmd_wr_count_r[rd_cmd_ptr_r] : '0;
  assign sched_slot_occupancy_o = slot_occupancy_r;
  assign sched_fetch_complete_o = source_rsp_fire
      && ((cmd_rsp_count_r[slot_owner_cmd_r[source_rsp_slot]] + 32'd1)
       == cmd_total_beats_r[slot_owner_cmd_r[source_rsp_slot]]);
  assign sched_fetch_complete_work_seq_o
      = cmd_scheduler_work_seq_r[slot_owner_cmd_r[source_rsp_slot]];

  wire slot_read_ready = !drain_valid_r || destination_write_fire;
  wire [CMD_PTR_BITS-1:0] slot_read_cmd = destination_last_write
      ? (wr_cmd_ptr_r + CMD_PTR_BITS'(1)) : wr_cmd_ptr_r;
  wire [31:0] slot_read_beat = destination_write_fire
      ? (destination_last_write ? 32'd0
                                : (cmd_wr_count_r[wr_cmd_ptr_r] + 32'd1))
      : cmd_wr_count_r[wr_cmd_ptr_r];
  wire slot_read_owner_match = cmd_valid_r[slot_read_cmd]
      && (slot_owner_cmd_r[wr_expect_slot_r] == slot_read_cmd)
      && (slot_owner_sequence_r[wr_expect_slot_r]
          == cmd_sequence_r[slot_read_cmd])
      && (slot_owner_beat_r[wr_expect_slot_r] == slot_read_beat);
  wire slot_read_fire = slot_read_ready
      && (slot_state_r[wr_expect_slot_r] == SLOT_READY)
      && slot_read_owner_match;

  // Input keeps the legacy same-cycle recycle behavior.  Qparam wrappers
  // disable it so GEMM req_ready/completion cannot feed command issue back in
  // the same delta cycle; a full FIFO becomes available after its registered
  // count update on the following cycle.
  assign ctrl_if.idle = !cmd_fifo_full
                     || (ENABLE_SAME_CYCLE_CMD_RECYCLE
                      && destination_last_write);
  assign ctrl_if.prepare_ready = 1'b0;
  assign ctrl_if.write_done = destination_last_write;
  assign ctrl_if.done = destination_last_write;

  assign gemm_sync_if.valid = 1'b0;
  assign gemm_sync_if.reg_idx = cmd_valid_r[wr_cmd_ptr_r]
                              ? cmd_reg_idx_r[wr_cmd_ptr_r] : '0;
  assign gemm_sync_if.value = cmd_valid_r[wr_cmd_ptr_r]
                            ? cmd_reg_value_r[wr_cmd_ptr_r] : '0;

  wire sched_source_allowed = !ENABLE_SCHED_SOURCE_GATE
                           || sched_source_enable_i
                           // Admission gating cannot revoke a request that
                           // has already entered ready/valid backpressure.
                           // This registered bit is set on the first stalled
                           // edge and clears only when that request fires.
                           || source_urgent_hold_valid_r;
  assign lmem_bus_if.req_valid = rd_cmd_valid
      && sched_source_allowed
      && (slot_state_r[alloc_slot_r] == SLOT_FREE);
  assign lmem_bus_if.req_data.rw = 1'b0;
  assign lmem_bus_if.req_data.addr
      = LMEM_ADDR_WIDTH_P'(rd_src_byte_addr >> BUS_ADDR_BITS);
  assign lmem_bus_if.req_data.data = '0;
  assign lmem_bus_if.req_data.byteen = '1;
  assign lmem_bus_if.req_data.flags = '0;
  assign lmem_bus_if.req_data.tag.uuid = '0;
  assign lmem_bus_if.req_data.tag.value = LMEM_TAG_VALUE_W'(alloc_slot_r);
  assign lmem_bus_if.rsp_ready = source_rsp_legal;

  assign gemm_bus_if.req_valid = drain_valid_r
                               && drain_matches_writer
                               && writer_released;
  assign gemm_bus_if.req_data.rw = 1'b1;
  assign gemm_bus_if.req_data.addr
      = GEMM_ADDR_WIDTH_P'(wr_dst_byte_addr >> BUS_ADDR_BITS);
  assign gemm_bus_if.req_data.data = drain_payload;
  assign gemm_bus_if.req_data.byteen = '1;
  assign gemm_bus_if.req_data.flags = '0;
  assign gemm_bus_if.req_data.tag.uuid = '0;
  assign gemm_bus_if.req_data.tag.value = '0;
  assign gemm_bus_if.rsp_ready = 1'b1;

  VX_dp_ram #(
    .DATAW     (BUS_BYTES * 8),
    .SIZE      (RESPONSE_SLOTS),
    .WRENW     (1),
    .OUT_REG   (1),
    .LUTRAM    (0),
    .RDW_MODE  ("R"),
    .RADDR_REG (1)
  ) response_payload_ram (
    .clk   (clk),
    .reset (reset),
    .read  (slot_read_fire),
    .write (source_rsp_fire),
    .wren  (1'b1),
    .waddr (source_rsp_slot),
    .wdata (lmem_bus_if.rsp_data.data),
    .raddr (wr_expect_slot_r),
    .rdata (drain_payload)
  );

  initial begin
    if (NDIM != 3)
      $fatal(1, "%s: Input overlap DMA requires NDIM=3", INSTANCE_ID);
    if ((CMD_FIFO_DEPTH != 4)
     || ((CMD_FIFO_DEPTH & (CMD_FIFO_DEPTH - 1)) != 0))
      $fatal(1, "%s: Input command depth must be four, got %0d",
             INSTANCE_ID, CMD_FIFO_DEPTH);
    if ((RESPONSE_SLOTS != 8)
     || ((RESPONSE_SLOTS & (RESPONSE_SLOTS - 1)) != 0))
      $fatal(1, "%s: Input response-slot count must be eight, got %0d",
             INSTANCE_ID, RESPONSE_SLOTS);
    if (BUS_BYTES != gemm_bus_if.DATA_SIZE)
      $fatal(1, "%s: Input source/destination beat widths differ (%0d/%0d)",
             INSTANCE_ID, BUS_BYTES, gemm_bus_if.DATA_SIZE);
    if (LMEM_ADDR_WIDTH_P != lmem_bus_if.ADDR_WIDTH)
      $fatal(1, "%s: Input LMEM address width mismatch", INSTANCE_ID);
    if (GEMM_ADDR_WIDTH_P != gemm_bus_if.ADDR_WIDTH)
      $fatal(1, "%s: Input GEMM address width mismatch", INSTANCE_ID);
    if ((LMEM_TAG_WIDTH_P != lmem_bus_if.TAG_WIDTH)
     || (GEMM_TAG_WIDTH_P != gemm_bus_if.TAG_WIDTH))
      $fatal(1, "%s: Input tag width mismatch", INSTANCE_ID);
    if (LMEM_TAG_VALUE_W < SLOT_BITS)
      $fatal(1, "%s: Input source tag cannot encode eight slots", INSTANCE_ID);
    if (ENABLE_WRITER_FENCE && (WRITER_RID0 == WRITER_RID1))
      $fatal(1, "%s: writer-fence RIDs must identify two banks", INSTANCE_ID);
    if ((READY_AHEAD_LOW_WATERMARK < 1)
     || (READY_AHEAD_LOW_WATERMARK > RESPONSE_SLOTS))
      $fatal(1, "%s: Input ready-ahead watermark %0d is outside 1..%0d",
             INSTANCE_ID, READY_AHEAD_LOW_WATERMARK, RESPONSE_SLOTS);
  end

  always_ff @(posedge clk) begin
    if (reset) begin
      cmd_valid_r <= '0;
      cmd_rd_done_r <= '0;
      rd_cmd_ptr_r <= '0;
      wr_cmd_ptr_r <= '0;
      cmd_tail_ptr_r <= '0;
      cmd_count_r <= '0;
      next_cmd_sequence_r <= '0;
      alloc_slot_r <= '0;
      wr_expect_slot_r <= '0;
      slot_occupancy_r <= '0;
      drain_valid_r <= 1'b0;
      drain_slot_r <= '0;
      drain_owner_cmd_r <= '0;
      drain_owner_sequence_r <= '0;
      drain_owner_beat_r <= '0;
      source_urgent_hold_valid_r <= 1'b0;
      source_urgent_hold_r <= 1'b0;
      source_priority_hold_r <= '0;
      for (int cmd = 0; cmd < CMD_FIFO_DEPTH; ++cmd) begin
        cmd_src_base_r[cmd] <= '0;
        cmd_dst_base_r[cmd] <= '0;
        cmd_seg_size_r[cmd] <= '0;
        cmd_reg_idx_r[cmd] <= '0;
        cmd_reg_value_r[cmd] <= '0;
        cmd_total_beats_r[cmd] <= '0;
        cmd_rd_count_r[cmd] <= '0;
        cmd_wr_count_r[cmd] <= '0;
        cmd_rsp_count_r[cmd] <= '0;
        cmd_rd_seg_offset_r[cmd] <= '0;
        cmd_wr_seg_offset_r[cmd] <= '0;
        cmd_writer_wait_r[cmd] <= '0;
        cmd_sequence_r[cmd] <= '0;
        cmd_scheduler_work_seq_r[cmd] <= '0;
        for (int d = 0; d < NDIM; ++d) begin
          cmd_src_strides_r[cmd][d] <= '0;
          cmd_dst_strides_r[cmd][d] <= '0;
          cmd_bounds_r[cmd][d] <= '0;
          cmd_rd_i_dim_r[cmd][d] <= '0;
          cmd_wr_i_dim_r[cmd][d] <= '0;
        end
      end
      for (int slot = 0; slot < RESPONSE_SLOTS; ++slot) begin
        slot_state_r[slot] <= SLOT_FREE;
        slot_owner_cmd_r[slot] <= '0;
        slot_owner_sequence_r[slot] <= '0;
        slot_owner_beat_r[slot] <= '0;
      end
    end else begin
      if (source_req_fire) begin
        source_urgent_hold_valid_r <= 1'b0;
      end else if (lmem_bus_if.req_valid && !source_urgent_hold_valid_r) begin
        source_urgent_hold_valid_r <= 1'b1;
        source_urgent_hold_r <= source_urgent_now;
        source_priority_hold_r <= sched_priority_i;
      end
      unique case ({command_enqueue, destination_last_write})
        2'b10: cmd_count_r <= cmd_count_r + CMD_COUNT_BITS'(1);
        2'b01: cmd_count_r <= cmd_count_r - CMD_COUNT_BITS'(1);
        default:;
      endcase

      unique case ({source_req_fire, destination_write_fire})
        2'b10: slot_occupancy_r
            <= slot_occupancy_r + SLOT_COUNT_BITS'(1);
        2'b01: slot_occupancy_r
            <= slot_occupancy_r - SLOT_COUNT_BITS'(1);
        default:;
      endcase

      unique case ({slot_read_fire, destination_write_fire})
        2'b10: drain_valid_r <= 1'b1;
        2'b01: drain_valid_r <= 1'b0;
        2'b11: drain_valid_r <= 1'b1;
        default:;
      endcase

      if (destination_last_write) begin
        cmd_valid_r[wr_cmd_ptr_r] <= 1'b0;
        cmd_rd_done_r[wr_cmd_ptr_r] <= 1'b0;
        cmd_wr_count_r[wr_cmd_ptr_r] <= '0;
        cmd_rsp_count_r[wr_cmd_ptr_r] <= '0;
        cmd_wr_seg_offset_r[wr_cmd_ptr_r] <= '0;
        for (int d = 0; d < NDIM; ++d)
          cmd_wr_i_dim_r[wr_cmd_ptr_r][d] <= '0;
        wr_cmd_ptr_r <= wr_cmd_ptr_r + CMD_PTR_BITS'(1);
      end else if (destination_write_fire) begin
        cmd_wr_count_r[wr_cmd_ptr_r]
            <= cmd_wr_count_r[wr_cmd_ptr_r] + 32'd1;
        if ((cmd_wr_seg_offset_r[wr_cmd_ptr_r] + 32'(BUS_BYTES))
            >= cmd_seg_size_r[wr_cmd_ptr_r]) begin
          cmd_wr_seg_offset_r[wr_cmd_ptr_r] <= '0;
          if ((cmd_wr_i_dim_r[wr_cmd_ptr_r][0] + 32'd1)
              < cmd_bounds_r[wr_cmd_ptr_r][0]) begin
            cmd_wr_i_dim_r[wr_cmd_ptr_r][0]
                <= cmd_wr_i_dim_r[wr_cmd_ptr_r][0] + 32'd1;
          end else begin
            cmd_wr_i_dim_r[wr_cmd_ptr_r][0] <= '0;
            if ((cmd_wr_i_dim_r[wr_cmd_ptr_r][1] + 32'd1)
                < cmd_bounds_r[wr_cmd_ptr_r][1]) begin
              cmd_wr_i_dim_r[wr_cmd_ptr_r][1]
                  <= cmd_wr_i_dim_r[wr_cmd_ptr_r][1] + 32'd1;
            end else begin
              cmd_wr_i_dim_r[wr_cmd_ptr_r][1] <= '0;
              if ((cmd_wr_i_dim_r[wr_cmd_ptr_r][2] + 32'd1)
                  < cmd_bounds_r[wr_cmd_ptr_r][2]) begin
                cmd_wr_i_dim_r[wr_cmd_ptr_r][2]
                    <= cmd_wr_i_dim_r[wr_cmd_ptr_r][2] + 32'd1;
              end
            end
          end
        end else begin
          cmd_wr_seg_offset_r[wr_cmd_ptr_r]
              <= cmd_wr_seg_offset_r[wr_cmd_ptr_r] + 32'(BUS_BYTES);
        end
      end

      if (source_rsp_fire)
        cmd_rsp_count_r[slot_owner_cmd_r[source_rsp_slot]]
            <= cmd_rsp_count_r[slot_owner_cmd_r[source_rsp_slot]] + 32'd1;

      if (source_req_fire) begin
        slot_state_r[alloc_slot_r] <= SLOT_WAIT_RSP;
        slot_owner_cmd_r[alloc_slot_r] <= rd_cmd_ptr_r;
        slot_owner_sequence_r[alloc_slot_r]
            <= cmd_sequence_r[rd_cmd_ptr_r];
        slot_owner_beat_r[alloc_slot_r]
            <= cmd_rd_count_r[rd_cmd_ptr_r];
        alloc_slot_r <= alloc_slot_r + SLOT_BITS'(1);

        if ((cmd_rd_seg_offset_r[rd_cmd_ptr_r] + 32'(BUS_BYTES))
            >= cmd_seg_size_r[rd_cmd_ptr_r]) begin
          cmd_rd_seg_offset_r[rd_cmd_ptr_r] <= '0;
          if ((cmd_rd_i_dim_r[rd_cmd_ptr_r][0] + 32'd1)
              < cmd_bounds_r[rd_cmd_ptr_r][0]) begin
            cmd_rd_i_dim_r[rd_cmd_ptr_r][0]
                <= cmd_rd_i_dim_r[rd_cmd_ptr_r][0] + 32'd1;
          end else begin
            cmd_rd_i_dim_r[rd_cmd_ptr_r][0] <= '0;
            if ((cmd_rd_i_dim_r[rd_cmd_ptr_r][1] + 32'd1)
                < cmd_bounds_r[rd_cmd_ptr_r][1]) begin
              cmd_rd_i_dim_r[rd_cmd_ptr_r][1]
                  <= cmd_rd_i_dim_r[rd_cmd_ptr_r][1] + 32'd1;
            end else begin
              cmd_rd_i_dim_r[rd_cmd_ptr_r][1] <= '0;
              if ((cmd_rd_i_dim_r[rd_cmd_ptr_r][2] + 32'd1)
                  < cmd_bounds_r[rd_cmd_ptr_r][2]) begin
                cmd_rd_i_dim_r[rd_cmd_ptr_r][2]
                    <= cmd_rd_i_dim_r[rd_cmd_ptr_r][2] + 32'd1;
              end
            end
          end
        end else begin
          cmd_rd_seg_offset_r[rd_cmd_ptr_r]
              <= cmd_rd_seg_offset_r[rd_cmd_ptr_r] + 32'(BUS_BYTES);
        end

        if ((cmd_rd_count_r[rd_cmd_ptr_r] + 32'd1)
            == cmd_total_beats_r[rd_cmd_ptr_r]) begin
          cmd_rd_done_r[rd_cmd_ptr_r] <= 1'b1;
          rd_cmd_ptr_r <= rd_cmd_ptr_r + CMD_PTR_BITS'(1);
        end else begin
          cmd_rd_count_r[rd_cmd_ptr_r]
              <= cmd_rd_count_r[rd_cmd_ptr_r] + 32'd1;
        end
      end

      if (source_rsp_fire)
        slot_state_r[source_rsp_slot] <= SLOT_READY;

      if (slot_read_fire) begin
        slot_state_r[wr_expect_slot_r] <= SLOT_DRAINING;
        drain_slot_r <= wr_expect_slot_r;
        drain_owner_cmd_r <= slot_owner_cmd_r[wr_expect_slot_r];
        drain_owner_sequence_r
            <= slot_owner_sequence_r[wr_expect_slot_r];
        drain_owner_beat_r <= slot_owner_beat_r[wr_expect_slot_r];
        wr_expect_slot_r <= wr_expect_slot_r + SLOT_BITS'(1);
      end

      if (destination_write_fire) begin
        slot_state_r[drain_slot_r] <= SLOT_FREE;
        slot_owner_cmd_r[drain_slot_r] <= '0;
        slot_owner_sequence_r[drain_slot_r] <= '0;
        slot_owner_beat_r[drain_slot_r] <= '0;
      end

      // Enqueue last so a same-cycle writer pop may reuse the entry.
      if (command_enqueue) begin
        cmd_valid_r[cmd_tail_ptr_r] <= 1'b1;
        cmd_rd_done_r[cmd_tail_ptr_r] <= 1'b0;
        cmd_src_base_r[cmd_tail_ptr_r] <= ctrl_if.src_base_addr;
        cmd_dst_base_r[cmd_tail_ptr_r] <= ctrl_if.dst_base_addr;
        cmd_seg_size_r[cmd_tail_ptr_r] <= ctrl_if.seg_size;
        cmd_reg_idx_r[cmd_tail_ptr_r] <= ctrl_if.reg_idx;
        cmd_reg_value_r[cmd_tail_ptr_r] <= ctrl_if.reg_value;
        cmd_total_beats_r[cmd_tail_ptr_r]
            <= (ctrl_if.seg_size / BUS_BYTES)
             * ctrl_if.bounds[0]
             * ctrl_if.bounds[1]
             * ctrl_if.bounds[2];
        cmd_rd_count_r[cmd_tail_ptr_r] <= '0;
        cmd_wr_count_r[cmd_tail_ptr_r] <= '0;
        cmd_rd_seg_offset_r[cmd_tail_ptr_r] <= '0;
        cmd_wr_seg_offset_r[cmd_tail_ptr_r] <= '0;
        cmd_writer_wait_r[cmd_tail_ptr_r] <= writer_wait_i;
        cmd_sequence_r[cmd_tail_ptr_r] <= next_cmd_sequence_r;
        cmd_scheduler_work_seq_r[cmd_tail_ptr_r]
            <= ctrl_if.scheduler_work_seq;
        for (int d = 0; d < NDIM; ++d) begin
          cmd_src_strides_r[cmd_tail_ptr_r][d] <= ctrl_if.src_strides[d];
          cmd_dst_strides_r[cmd_tail_ptr_r][d] <= ctrl_if.dst_strides[d];
          cmd_bounds_r[cmd_tail_ptr_r][d] <= ctrl_if.bounds[d];
          cmd_rd_i_dim_r[cmd_tail_ptr_r][d] <= '0;
          cmd_wr_i_dim_r[cmd_tail_ptr_r][d] <= '0;
        end
        cmd_tail_ptr_r <= cmd_tail_ptr_r + CMD_PTR_BITS'(1);
        next_cmd_sequence_r <= next_cmd_sequence_r + 32'd1;
      end
    end
  end

`ifndef SYNTHESIS
  // Stable hierarchical probes for the resource-local overlap pipeline.
  // Scale and Zero-point instantiate this engine separately, so the instance
  // path identifies the resource while these names remain common.
  wire [CMD_COUNT_BITS-1:0] dbg_overlap_cmd_occupancy = cmd_count_r;
  wire [SLOT_COUNT_BITS-1:0] dbg_overlap_slot_occupancy
      = slot_occupancy_r;
  wire [CMD_PTR_BITS-1:0] dbg_overlap_read_head = rd_cmd_ptr_r;
  wire [CMD_PTR_BITS-1:0] dbg_overlap_write_head = wr_cmd_ptr_r;
  wire [31:0] dbg_overlap_writer_sequence
      = cmd_sequence_r[wr_cmd_ptr_r];
  wire [31:0] dbg_overlap_writer_total_beats
      = cmd_total_beats_r[wr_cmd_ptr_r];
  wire [31:0] dbg_overlap_writer_write_count
      = cmd_wr_count_r[wr_cmd_ptr_r];
  wire dbg_overlap_writer_wait_valid
      = cmd_writer_wait_r[wr_cmd_ptr_r].valid;
  wire [GEMM_SYNC_REG_ID_WIDTH-1:0] dbg_overlap_writer_wait_rid
      = cmd_writer_wait_r[wr_cmd_ptr_r].reg_id;
  wire [31:0] dbg_overlap_writer_wait_target
      = cmd_writer_wait_r[wr_cmd_ptr_r].target;
  wire dbg_overlap_writer_released = writer_released;

  logic destination_stall_r;
  logic [GEMM_ADDR_WIDTH_P-1:0] destination_stall_addr_r;
  logic [BUS_BYTES*8-1:0] destination_stall_data_r;
  logic source_stall_r;
  logic source_stall_urgent_r;
  logic [GEMM_SCHED_PRIORITY_WIDTH-1:0] source_stall_priority_r;
  always_ff @(posedge clk) begin
    if (reset) begin
      destination_stall_r <= 1'b0;
      destination_stall_addr_r <= '0;
      destination_stall_data_r <= '0;
      source_stall_r <= 1'b0;
      source_stall_urgent_r <= 1'b0;
      source_stall_priority_r <= '0;
    end else begin
      assert (cmd_count_r <= CMD_COUNT_BITS'(CMD_FIFO_DEPTH))
        else $fatal(1, "%s: Input command FIFO overflow", INSTANCE_ID);
      assert (slot_occupancy_r <= SLOT_COUNT_BITS'(RESPONSE_SLOTS))
        else $fatal(1, "%s: Input response-slot overflow", INSTANCE_ID);
      assert (!(ctrl_if.start && !ctrl_if.idle))
        else $fatal(1, "%s: Input command presented while FIFO full",
                    INSTANCE_ID);
      if (cmd_valid_r[wr_cmd_ptr_r]) begin
        assert ((cmd_total_beats_r[wr_cmd_ptr_r] != 0)
             && (cmd_wr_count_r[wr_cmd_ptr_r]
                 < cmd_total_beats_r[wr_cmd_ptr_r]))
          else $fatal(1,
                      "%s: writer count escaped descriptor bound seq=%0d count=%0d total=%0d",
                      INSTANCE_ID, cmd_sequence_r[wr_cmd_ptr_r],
                      cmd_wr_count_r[wr_cmd_ptr_r],
                      cmd_total_beats_r[wr_cmd_ptr_r]);
      end
      if (command_enqueue) begin
        assert (!cmd_valid_r[cmd_tail_ptr_r] || destination_last_write)
          else $fatal(1, "%s: Input command overwrote a live entry",
                      INSTANCE_ID);
        assert ((ctrl_if.bounds[0] != 0)
             && (ctrl_if.bounds[1] != 0)
             && (ctrl_if.bounds[2] != 0)
             && (ctrl_if.seg_size != 0)
             && ((ctrl_if.seg_size % BUS_BYTES) == 0))
          else $fatal(1, "%s: unsupported Input descriptor shape",
                      INSTANCE_ID);
        if (ENABLE_WRITER_FENCE) begin
          assert (!writer_wait_i.valid
               || ((((writer_wait_i.reg_id
                      == GEMM_SYNC_REG_ID_WIDTH'(WRITER_RID0))
                     && !ctrl_if.dst_base_addr[BUS_ADDR_BITS])
                  || ((writer_wait_i.reg_id
                      == GEMM_SYNC_REG_ID_WIDTH'(WRITER_RID1))
                     && ctrl_if.dst_base_addr[BUS_ADDR_BITS]))
                && (writer_wait_i.target != 0)))
            else $fatal(1, "%s: writer RID/target/destination-bank mismatch",
                        INSTANCE_ID);
        end else begin
          assert (!writer_wait_i.valid)
            else $fatal(1, "%s: unexpected writer wait on Input executor",
                        INSTANCE_ID);
        end
      end
      if (lmem_bus_if.rsp_valid) begin
        assert (source_rsp_legal)
          else $fatal(1, "%s: Input response targeted non-WAIT slot",
                      INSTANCE_ID);
      end
      if (destination_write_fire) begin
        assert (drain_matches_writer
             && (slot_state_r[drain_slot_r] == SLOT_DRAINING))
          else $fatal(1, "%s: Input destination order/owner violation",
                      INSTANCE_ID);
        assert (writer_released)
          else $fatal(1, "%s: destination write preceded writer fence",
                      INSTANCE_ID);
        assert ((cmd_total_beats_r[wr_cmd_ptr_r] != 0)
             && (cmd_wr_count_r[wr_cmd_ptr_r]
                 < cmd_total_beats_r[wr_cmd_ptr_r]))
          else $fatal(1,
                      "%s: destination write exceeded descriptor bound seq=%0d count=%0d total=%0d",
                      INSTANCE_ID, cmd_sequence_r[wr_cmd_ptr_r],
                      cmd_wr_count_r[wr_cmd_ptr_r],
                      cmd_total_beats_r[wr_cmd_ptr_r]);
        if (cmd_total_beats_r[wr_cmd_ptr_r] == 32'd1) begin
          assert (destination_last_write)
            else $fatal(1,
                        "%s: one-beat descriptor did not complete on its write seq=%0d",
                        INSTANCE_ID, cmd_sequence_r[wr_cmd_ptr_r]);
        end
      end
      if (destination_stall_r) begin
        assert (gemm_bus_if.req_valid
             && (gemm_bus_if.req_data.addr == destination_stall_addr_r)
             && (gemm_bus_if.req_data.data == destination_stall_data_r))
          else $fatal(1, "%s: Input request changed under backpressure",
                      INSTANCE_ID);
      end
      if (source_stall_r) begin
        assert (lmem_bus_if.req_valid
             && (lmem_req_urgent_o == source_stall_urgent_r)
             && (lmem_req_priority_o == source_stall_priority_r))
          else $fatal(1, "%s: Input source urgency changed under backpressure",
                      INSTANCE_ID);
      end
      assert (consecutive_ready_ahead <= SLOT_COUNT_BITS'(RESPONSE_SLOTS))
        else $fatal(1, "%s: Input ready-ahead count overflow", INSTANCE_ID);
      source_stall_r <= lmem_bus_if.req_valid && !lmem_bus_if.req_ready;
      source_stall_urgent_r <= lmem_req_urgent_o;
      source_stall_priority_r <= lmem_req_priority_o;
      destination_stall_r <= gemm_bus_if.req_valid
                          && !gemm_bus_if.req_ready;
      destination_stall_addr_r <= gemm_bus_if.req_data.addr;
      destination_stall_data_r <= gemm_bus_if.req_data.data;
    end
  end
`endif

`ifdef DBG_TRACE_GEMM
  always_ff @(posedge clk) begin
    if (!reset) begin
      if (command_enqueue)
        `TRACE(1, ("%m : [%0t] | INPUT_DMA_ENQUEUE | {seq=%0d, beats=%0d}\n",
                   $time, next_cmd_sequence_r, ctrl_if.bounds[0]))
      if (source_req_fire)
        `TRACE(1, ("%m : [%0t] | INPUT_DMA_SOURCE | {seq=%0d, beat=%0d, slot=%0d}\n",
                   $time, cmd_sequence_r[rd_cmd_ptr_r],
                   cmd_rd_count_r[rd_cmd_ptr_r], alloc_slot_r))
      if (destination_write_fire)
        `TRACE(1, ("%m : [%0t] | INPUT_DMA_DEST | {seq=%0d, beat=%0d, total=%0d, last=%0d}\n",
                   $time, cmd_sequence_r[wr_cmd_ptr_r],
                   cmd_wr_count_r[wr_cmd_ptr_r],
                   cmd_total_beats_r[wr_cmd_ptr_r],
                   destination_last_write))
    end
  end
`endif

`ifdef PERF_ENABLE
  reg [PERF_CTR_BITS-1:0] perf_rd_bytes_r;
  reg [PERF_CTR_BITS-1:0] perf_wr_bytes_r;
  reg [PERF_CTR_BITS-1:0] perf_xfers_r;
  reg [PERF_CTR_BITS-1:0] perf_active_r;
  reg [PERF_CTR_BITS-1:0] perf_src_req_fire_r;
  reg [PERF_CTR_BITS-1:0] perf_src_req_stall_r;
  reg [PERF_CTR_BITS-1:0] perf_src_data_fire_r;
  reg [PERF_CTR_BITS-1:0] perf_src_data_stall_r;
  reg [PERF_CTR_BITS-1:0] perf_dst_fire_r;
  reg [PERF_CTR_BITS-1:0] perf_dst_stall_r;
  always_ff @(posedge clk) begin
    if (reset) begin
      perf_rd_bytes_r <= '0;
      perf_wr_bytes_r <= '0;
      perf_xfers_r <= '0;
      perf_active_r <= '0;
      perf_src_req_fire_r <= '0;
      perf_src_req_stall_r <= '0;
      perf_src_data_fire_r <= '0;
      perf_src_data_stall_r <= '0;
      perf_dst_fire_r <= '0;
      perf_dst_stall_r <= '0;
    end else begin
      if (source_rsp_fire)
        perf_rd_bytes_r <= perf_rd_bytes_r + PERF_CTR_BITS'(BUS_BYTES);
      if (destination_write_fire)
        perf_wr_bytes_r <= perf_wr_bytes_r + PERF_CTR_BITS'(BUS_BYTES);
      if (destination_last_write)
        perf_xfers_r <= perf_xfers_r + PERF_CTR_BITS'(1);
      if (cmd_count_r != 0)
        perf_active_r <= perf_active_r + PERF_CTR_BITS'(1);
      if (source_req_fire)
        perf_src_req_fire_r <= perf_src_req_fire_r + PERF_CTR_BITS'(1);
      if (lmem_bus_if.req_valid && !lmem_bus_if.req_ready)
        perf_src_req_stall_r <= perf_src_req_stall_r + PERF_CTR_BITS'(1);
      if (source_rsp_fire)
        perf_src_data_fire_r <= perf_src_data_fire_r + PERF_CTR_BITS'(1);
      if (lmem_bus_if.rsp_valid && !lmem_bus_if.rsp_ready)
        perf_src_data_stall_r <= perf_src_data_stall_r + PERF_CTR_BITS'(1);
      if (destination_write_fire)
        perf_dst_fire_r <= perf_dst_fire_r + PERF_CTR_BITS'(1);
      if (gemm_bus_if.req_valid && !gemm_bus_if.req_ready)
        perf_dst_stall_r <= perf_dst_stall_r + PERF_CTR_BITS'(1);
    end
  end
  assign perf.rd_bytes = perf_rd_bytes_r;
  assign perf.wr_bytes = perf_wr_bytes_r;
  assign perf.xfer_count = perf_xfers_r;
  assign perf.active_cycles = perf_active_r;
  assign perf.src_rd_req_fire = perf_src_req_fire_r;
  assign perf.src_rd_req_stall = perf_src_req_stall_r;
  assign perf.src_rd_data_fire = perf_src_data_fire_r;
  assign perf.src_rd_data_stall = perf_src_data_stall_r;
  assign perf.dst_wr_fire = perf_dst_fire_r;
  assign perf.dst_wr_stall = perf_dst_stall_r;
  assign perf.wait_dcache = '0;
  assign perf.wait_lmem = '0;
  assign perf.busy = (cmd_count_r != 0);
`endif

endmodule

//==============================================================================
// VX_lmem_dma_qparam_overlap
//  Scale/Zero-point source-prefetch executor.  The common ordered read/write
//  engine is configured with a resource-specific two-bank consume fence.
//==============================================================================

module VX_lmem_dma_qparam_overlap import VX_gpu_pkg::*; #(
  parameter `STRING INSTANCE_ID = "",
  parameter int NDIM = 3,
  parameter int TAG_WIDTH = 1,
  parameter int CMD_FIFO_DEPTH = 4,
  parameter int RESPONSE_SLOTS = 8,
  parameter int WRITER_RID0 = GEMM_RID_SC_CONSUME0,
  parameter int WRITER_RID1 = GEMM_RID_SC_CONSUME1,
  parameter int LMEM_ADDR_WIDTH_P = 1,
  parameter int GEMM_ADDR_WIDTH_P = 1,
  parameter int LMEM_TAG_WIDTH_P = TAG_WIDTH,
  parameter int GEMM_TAG_WIDTH_P = TAG_WIDTH
) (
  input wire clk,
  input wire reset,
  input wire [GEMM_SCHED_PRIORITY_WIDTH-1:0] sched_priority_i,
  VX_lmem_dma_ctrl_if.slave ctrl_if,
  input gemm_wait_meta_t writer_wait_i,
  input wire [31:0] writer_consume_value0_i,
  input wire [31:0] writer_consume_value1_i,
  VX_gemm_sync_if.master gemm_sync_if,
  VX_mem_bus_if.master lmem_bus_if,
  VX_mem_bus_if.master gemm_bus_if,
  output wire sched_source_valid_o,
  output wire [31:0] sched_source_work_seq_o,
  output wire [31:0] sched_source_total_beats_o,
  output wire [31:0] sched_source_request_beats_o,
  output wire [31:0] sched_source_response_beats_o,
  output wire [31:0] sched_source_writer_beats_o,
  output wire [$clog2(RESPONSE_SLOTS + 1)-1:0]
      sched_slot_occupancy_o,
  output wire sched_fetch_complete_o,
  output wire [31:0] sched_fetch_complete_work_seq_o
  ,output wire [GEMM_SCHED_PRIORITY_WIDTH-1:0] lmem_req_priority_o
`ifdef PERF_ENABLE
  ,output dma_perf_t perf
`endif
);

  VX_lmem_dma_input_overlap #(
    .INSTANCE_ID          (INSTANCE_ID),
    .NDIM                 (NDIM),
    .TAG_WIDTH            (TAG_WIDTH),
    .CMD_FIFO_DEPTH       (CMD_FIFO_DEPTH),
    .RESPONSE_SLOTS       (RESPONSE_SLOTS),
    .ENABLE_WRITER_FENCE  (1'b1),
    .ENABLE_SCHED_SOURCE_GATE (1'b0),
    .ENABLE_SAME_CYCLE_CMD_RECYCLE (1'b0),
    .WRITER_RID0          (WRITER_RID0),
    .WRITER_RID1          (WRITER_RID1),
    .LMEM_ADDR_WIDTH_P    (LMEM_ADDR_WIDTH_P),
    .GEMM_ADDR_WIDTH_P    (GEMM_ADDR_WIDTH_P),
    .LMEM_TAG_WIDTH_P     (LMEM_TAG_WIDTH_P),
    .GEMM_TAG_WIDTH_P     (GEMM_TAG_WIDTH_P)
  ) u_overlap (
    .clk                    (clk),
    .reset                  (reset),
    .sched_source_enable_i  (1'b1),
    .sched_priority_i       (sched_priority_i),
    .ctrl_if                (ctrl_if),
    .writer_wait_i          (writer_wait_i),
    .writer_consume_value0_i(writer_consume_value0_i),
    .writer_consume_value1_i(writer_consume_value1_i),
    .gemm_sync_if           (gemm_sync_if),
    .lmem_bus_if            (lmem_bus_if),
    .gemm_bus_if            (gemm_bus_if),
    .lmem_req_urgent_o      (),
    .lmem_req_priority_o    (lmem_req_priority_o),
    .ready_ahead_o          (),
    .sched_source_valid_o   (sched_source_valid_o),
    .sched_source_work_seq_o(sched_source_work_seq_o),
    .sched_source_total_beats_o(sched_source_total_beats_o),
    .sched_source_request_beats_o(sched_source_request_beats_o),
    .sched_source_response_beats_o(sched_source_response_beats_o),
    .sched_source_writer_beats_o(sched_source_writer_beats_o),
    .sched_slot_occupancy_o (sched_slot_occupancy_o),
    .sched_fetch_complete_o (sched_fetch_complete_o),
    .sched_fetch_complete_work_seq_o(sched_fetch_complete_work_seq_o)
  `ifdef PERF_ENABLE
    ,.perf                  (perf)
  `endif
  );

endmodule

//==============================================================================
// VX_lmem_dma_weight_overlap
//  Weight-only TMEM-to-register DMA with four in-order command contexts and
//  an independent two-bank destination register resource.
//
//  Source requests and destination writes are each command-granular and
//  ordered, but their command heads advance independently.  This permits the
//  source reads of command N+1 to fill the shared response RAM while command N
//  drains to the GEMM weight register.  Per-command length comes from the
//  accepted descriptor; the fixed slot pool bounds aggregate fetch lead.
//==============================================================================

module VX_lmem_dma_weight_overlap import VX_gpu_pkg::*; #(
  parameter `STRING INSTANCE_ID = "",
  parameter int NDIM = 3,
  parameter int TAG_WIDTH = 1,
  parameter int CMD_FIFO_DEPTH = 4,
  parameter int CMD_BEATS = `W_LMEM_DMA_CMD_BEATS,
  parameter int RESPONSE_SLOTS = `W_LMEM_DMA_RESPONSE_SLOTS,
  parameter bit ENABLE_TMEM_URGENCY = 1'b0,
  parameter int READY_AHEAD_LOW_WATERMARK = 2,
  parameter int LMEM_ADDR_WIDTH_P = 1,
  parameter int GEMM_ADDR_WIDTH_P = 1,
  parameter int LMEM_TAG_WIDTH_P = TAG_WIDTH,
  parameter int GEMM_TAG_WIDTH_P = TAG_WIDTH
) (
  input wire clk,
  input wire reset,
  input wire [GEMM_SCHED_PRIORITY_WIDTH-1:0] sched_priority_i,

  VX_lmem_dma_ctrl_if.slave ctrl_if,
  input gemm_wait_meta_t     writer_wait_i,
  input wire [31:0]          weight_consume_value0_i,
  input wire [31:0]          weight_consume_value1_i,
  VX_gemm_sync_if.master    gemm_sync_if,

  VX_mem_bus_if.master      lmem_bus_if,
  VX_mem_bus_if.master      gemm_bus_if,
  output wire               lmem_req_urgent_o,
  output wire [GEMM_SCHED_PRIORITY_WIDTH-1:0] lmem_req_priority_o,
  output wire [$clog2(RESPONSE_SLOTS + 1)-1:0] ready_ahead_o,
  output wire               sched_source_valid_o,
  output wire [31:0]        sched_source_work_seq_o,
  output wire [31:0]        sched_source_total_beats_o,
  output wire [31:0]        sched_source_request_beats_o,
  output wire [31:0]        sched_source_response_beats_o,
  output wire [31:0]        sched_source_writer_beats_o,
  output wire [$clog2(RESPONSE_SLOTS + 1)-1:0]
                            sched_slot_occupancy_o,
  output wire               sched_fetch_complete_o,
  output wire [31:0]        sched_fetch_complete_work_seq_o
`ifdef PERF_ENABLE
  ,output dma_perf_t perf
`endif
);

  localparam int BUS_BYTES = lmem_bus_if.DATA_SIZE;
  localparam int BUS_ADDR_BITS = `CLOG2(BUS_BYTES);
  localparam int CMD_PTR_BITS = $clog2(CMD_FIFO_DEPTH);
  localparam int CMD_COUNT_BITS = $clog2(CMD_FIFO_DEPTH + 1);
  localparam int SLOT_BITS = $clog2(RESPONSE_SLOTS);
  localparam int SLOT_COUNT_BITS = $clog2(RESPONSE_SLOTS + 1);
  localparam int LMEM_TAG_VALUE_W = LMEM_TAG_WIDTH_P - `UP(UUID_WIDTH);
  localparam int GEMM_TAG_VALUE_W = GEMM_TAG_WIDTH_P - `UP(UUID_WIDTH);

  typedef enum logic [1:0] {
    SLOT_FREE,
    SLOT_WAIT_RSP,
    SLOT_READY,
    SLOT_DRAINING
  } slot_state_e;

  logic [CMD_FIFO_DEPTH-1:0] cmd_valid_r;
  logic [CMD_FIFO_DEPTH-1:0] cmd_rd_done_r;
  logic [63:0] cmd_src_base_r[CMD_FIFO_DEPTH];
  logic [63:0] cmd_dst_base_r[CMD_FIFO_DEPTH];
  logic [31:0] cmd_src_strides_r[CMD_FIFO_DEPTH][NDIM];
  logic [31:0] cmd_dst_strides_r[CMD_FIFO_DEPTH][NDIM];
  logic [31:0] cmd_bounds_r[CMD_FIFO_DEPTH][NDIM];
  logic [31:0] cmd_seg_size_r[CMD_FIFO_DEPTH];
  logic [31:0] cmd_reg_idx_r[CMD_FIFO_DEPTH];
  logic [31:0] cmd_reg_value_r[CMD_FIFO_DEPTH];
  gemm_wait_meta_t cmd_writer_wait_r[CMD_FIFO_DEPTH];
  logic [31:0] cmd_total_beats_r[CMD_FIFO_DEPTH];
  logic [31:0] cmd_rd_count_r[CMD_FIFO_DEPTH];
  logic [31:0] cmd_wr_count_r[CMD_FIFO_DEPTH];
  logic [31:0] cmd_rsp_count_r[CMD_FIFO_DEPTH];
  logic [31:0] cmd_rd_i_dim_r[CMD_FIFO_DEPTH][NDIM];
  logic [31:0] cmd_rd_seg_offset_r[CMD_FIFO_DEPTH];
  logic [31:0] cmd_sequence_r[CMD_FIFO_DEPTH];
  logic [31:0] cmd_scheduler_work_seq_r[CMD_FIFO_DEPTH];

  logic [CMD_PTR_BITS-1:0] rd_cmd_ptr_r;
  logic [CMD_PTR_BITS-1:0] wr_cmd_ptr_r;
  logic [CMD_PTR_BITS-1:0] cmd_tail_ptr_r;
  logic [CMD_COUNT_BITS-1:0] cmd_count_r;
  logic [31:0] next_cmd_sequence_r;

  slot_state_e slot_state_r[RESPONSE_SLOTS];
  logic [CMD_PTR_BITS-1:0] slot_owner_cmd_r[RESPONSE_SLOTS];
  logic [31:0] slot_owner_sequence_r[RESPONSE_SLOTS];
  logic [31:0] slot_owner_beat_r[RESPONSE_SLOTS];
  logic [SLOT_BITS-1:0] alloc_slot_r;
  logic [SLOT_BITS-1:0] wr_expect_slot_r;
  logic [SLOT_COUNT_BITS-1:0] slot_occupancy_r;

  logic drain_valid_r;
  logic [SLOT_BITS-1:0] drain_slot_r;
  logic [CMD_PTR_BITS-1:0] drain_owner_cmd_r;
  logic [31:0] drain_owner_sequence_r;
  logic [31:0] drain_owner_beat_r;
  wire [BUS_BYTES*8-1:0] drain_payload;

  logic [SLOT_COUNT_BITS-1:0] consecutive_ready_ahead;
  logic ready_prefix;
  logic source_urgent_hold_valid_r;
  logic source_urgent_hold_r;
  logic [GEMM_SCHED_PRIORITY_WIDTH-1:0] source_priority_hold_r;

  wire cmd_fifo_full = (cmd_count_r == CMD_COUNT_BITS'(CMD_FIFO_DEPTH));
  wire rd_cmd_valid = cmd_valid_r[rd_cmd_ptr_r]
                   && !cmd_rd_done_r[rd_cmd_ptr_r];
  wire [63:0] rd_src_byte_addr = cmd_src_base_r[rd_cmd_ptr_r]
      + 64'(cmd_rd_i_dim_r[rd_cmd_ptr_r][0]
          * cmd_src_strides_r[rd_cmd_ptr_r][0])
      + 64'(cmd_rd_i_dim_r[rd_cmd_ptr_r][1]
          * cmd_src_strides_r[rd_cmd_ptr_r][1])
      + 64'(cmd_rd_i_dim_r[rd_cmd_ptr_r][2]
          * cmd_src_strides_r[rd_cmd_ptr_r][2])
      + 64'(cmd_rd_seg_offset_r[rd_cmd_ptr_r]);

  wire source_req_fire = lmem_bus_if.req_valid && lmem_bus_if.req_ready;
  wire [SLOT_BITS-1:0] source_rsp_slot =
      SLOT_BITS'(lmem_bus_if.rsp_data.tag.value);
  wire source_rsp_legal = !lmem_bus_if.rsp_valid
      || (slot_state_r[source_rsp_slot] == SLOT_WAIT_RSP);
  wire source_rsp_fire = lmem_bus_if.rsp_valid && lmem_bus_if.rsp_ready;

  wire writer_descriptor_valid =
      (cmd_dst_strides_r[wr_cmd_ptr_r][0] == 0)
      && (cmd_dst_strides_r[wr_cmd_ptr_r][1] == 0)
      && (cmd_dst_strides_r[wr_cmd_ptr_r][2] == 0);
  wire drain_matches_writer = cmd_valid_r[wr_cmd_ptr_r]
      && writer_descriptor_valid
      && (drain_owner_cmd_r == wr_cmd_ptr_r)
      && (drain_owner_sequence_r == cmd_sequence_r[wr_cmd_ptr_r])
      && (drain_owner_beat_r == cmd_wr_count_r[wr_cmd_ptr_r]);
  wire writer_wait_rid_is_w0 = cmd_writer_wait_r[wr_cmd_ptr_r].reg_id
      == GEMM_SYNC_REG_ID_WIDTH'(GEMM_RID_W_CONSUME0);
  wire writer_wait_rid_is_w1 = cmd_writer_wait_r[wr_cmd_ptr_r].reg_id
      == GEMM_SYNC_REG_ID_WIDTH'(GEMM_RID_W_CONSUME1);
  wire writer_wait_rid_valid = writer_wait_rid_is_w0
                            || writer_wait_rid_is_w1;
  wire [31:0] writer_consume_value = writer_wait_rid_is_w1
      ? weight_consume_value1_i
      : weight_consume_value0_i;
  wire writer_released = !cmd_writer_wait_r[wr_cmd_ptr_r].valid
      || (writer_wait_rid_valid
       && (writer_consume_value
           >= cmd_writer_wait_r[wr_cmd_ptr_r].target));

  always_comb begin
    consecutive_ready_ahead = SLOT_COUNT_BITS'(drain_valid_r);
    ready_prefix = 1'b1;
    for (int offset = 0; offset < RESPONSE_SLOTS; ++offset) begin
      if (ready_prefix
       && (slot_state_r[SLOT_BITS'(wr_expect_slot_r + SLOT_BITS'(offset))]
           == SLOT_READY)) begin
        if (consecutive_ready_ahead < SLOT_COUNT_BITS'(RESPONSE_SLOTS))
          consecutive_ready_ahead = consecutive_ready_ahead
                                  + SLOT_COUNT_BITS'(1);
      end else begin
        ready_prefix = 1'b0;
      end
    end
  end

  wire source_urgent_now = writer_released
      && (consecutive_ready_ahead
          < SLOT_COUNT_BITS'(READY_AHEAD_LOW_WATERMARK));
  assign lmem_req_priority_o = source_urgent_hold_valid_r
      ? source_priority_hold_r : sched_priority_i;
  // Preserve ready-ahead urgency for legacy/untracked commands.  A tracked
  // P0 request must remain background so far-lookahead Weight cannot regain
  // P1 independently of the dependency scheduler.
  assign lmem_req_urgent_o = ENABLE_TMEM_URGENCY
      && (source_urgent_hold_valid_r ? source_urgent_hold_r
                                     : source_urgent_now)
      && ((cmd_scheduler_work_seq_r[rd_cmd_ptr_r] == 0)
       || (lmem_req_priority_o != GEMM_SCHED_PRIORITY_BACKGROUND));
  assign ready_ahead_o = consecutive_ready_ahead;
  assign sched_source_valid_o = rd_cmd_valid;
  assign sched_source_work_seq_o
      = cmd_scheduler_work_seq_r[rd_cmd_ptr_r];
  assign sched_source_total_beats_o = rd_cmd_valid
      ? cmd_total_beats_r[rd_cmd_ptr_r] : '0;
  assign sched_source_request_beats_o = rd_cmd_valid
      ? cmd_rd_count_r[rd_cmd_ptr_r] : '0;
  assign sched_source_response_beats_o = rd_cmd_valid
      ? cmd_rsp_count_r[rd_cmd_ptr_r] : '0;
  assign sched_source_writer_beats_o = rd_cmd_valid
      ? cmd_wr_count_r[rd_cmd_ptr_r] : '0;
  assign sched_slot_occupancy_o = slot_occupancy_r;
  assign sched_fetch_complete_o = source_rsp_fire
      && ((cmd_rsp_count_r[slot_owner_cmd_r[source_rsp_slot]]
         + 32'd1)
       == cmd_total_beats_r[slot_owner_cmd_r[source_rsp_slot]]);
  assign sched_fetch_complete_work_seq_o
      = cmd_scheduler_work_seq_r[slot_owner_cmd_r[source_rsp_slot]];
  wire destination_write_fire = gemm_bus_if.req_valid
                              && gemm_bus_if.req_ready;
  wire destination_last_write = destination_write_fire
      && ((cmd_wr_count_r[wr_cmd_ptr_r] + 32'd1)
          == cmd_total_beats_r[wr_cmd_ptr_r]);
  wire command_enqueue = ctrl_if.start && ctrl_if.idle;

  // The synchronous RAM read can be launched while the current staged beat is
  // accepted.  On a command boundary this is what makes command N+1's first
  // write available immediately after command N's last write.
  wire slot_read_ready = !drain_valid_r || destination_write_fire;
  wire slot_read_fire = slot_read_ready
      && (slot_state_r[wr_expect_slot_r] == SLOT_READY);

  assign ctrl_if.idle = !cmd_fifo_full || destination_last_write;
  assign ctrl_if.prepare_ready = 1'b0;
  assign ctrl_if.write_done = destination_last_write;
  assign ctrl_if.done = destination_last_write;

  assign gemm_sync_if.valid = 1'b0;
  assign gemm_sync_if.reg_idx = cmd_valid_r[wr_cmd_ptr_r]
                              ? cmd_reg_idx_r[wr_cmd_ptr_r] : '0;
  assign gemm_sync_if.value = cmd_valid_r[wr_cmd_ptr_r]
                            ? cmd_reg_value_r[wr_cmd_ptr_r] : '0;

  assign lmem_bus_if.req_valid = rd_cmd_valid
                               && (slot_state_r[alloc_slot_r] == SLOT_FREE);
  assign lmem_bus_if.req_data.rw = 1'b0;
  assign lmem_bus_if.req_data.addr =
      LMEM_ADDR_WIDTH_P'(rd_src_byte_addr >> BUS_ADDR_BITS);
  assign lmem_bus_if.req_data.data = '0;
  assign lmem_bus_if.req_data.byteen = '1;
  assign lmem_bus_if.req_data.flags = '0;
  assign lmem_bus_if.req_data.tag.uuid = '0;
  assign lmem_bus_if.req_data.tag.value = LMEM_TAG_VALUE_W'(alloc_slot_r);
  assign lmem_bus_if.rsp_ready = source_rsp_legal;

  assign gemm_bus_if.req_valid = drain_valid_r
                               && drain_matches_writer
                               && writer_released;
  assign gemm_bus_if.req_data.rw = 1'b1;
  // ctrl_if.dst_base_addr is a byte address aligned to one Weight beat.  The
  // node encodes {load_dir, wreg_idx} above the alignment bits, so
  // conversion back to the bus beat address reproduces those two bits.
  assign gemm_bus_if.req_data.addr = GEMM_ADDR_WIDTH_P'(
      cmd_dst_base_r[wr_cmd_ptr_r] >> BUS_ADDR_BITS);
  assign gemm_bus_if.req_data.data = drain_payload;
  assign gemm_bus_if.req_data.byteen = '1;
  assign gemm_bus_if.req_data.flags = '0;
  assign gemm_bus_if.req_data.tag.uuid = '0;
  assign gemm_bus_if.req_data.tag.value = '0;
  assign gemm_bus_if.rsp_ready = 1'b1;

  VX_dp_ram #(
    .DATAW     (BUS_BYTES * 8),
    .SIZE      (RESPONSE_SLOTS),
    .WRENW     (1),
    .OUT_REG   (1),
    .LUTRAM    (0),
    .RDW_MODE  ("R"),
    .RADDR_REG (1)
  ) response_payload_ram (
    .clk   (clk),
    .reset (reset),
    .read  (slot_read_fire),
    .write (source_rsp_fire),
    .wren  (1'b1),
    .waddr (source_rsp_slot),
    .wdata (lmem_bus_if.rsp_data.data),
    .raddr (wr_expect_slot_r),
    .rdata (drain_payload)
  );

  initial begin
    if (NDIM != 3)
      $fatal(1, "%s: Weight overlap DMA requires NDIM=3", INSTANCE_ID);
    if (CMD_FIFO_DEPTH != 4)
      $fatal(1, "%s: Weight overlap DMA requires four command entries, got %0d",
             INSTANCE_ID, CMD_FIFO_DEPTH);
    if ((CMD_BEATS < 1) || ((CMD_BEATS & (CMD_BEATS - 1)) != 0))
      $fatal(1, "%s: CMD_BEATS must be a positive power of two, got %0d",
             INSTANCE_ID, CMD_BEATS);
    if ((RESPONSE_SLOTS != (2 * CMD_BEATS))
     || ((RESPONSE_SLOTS & (RESPONSE_SLOTS - 1)) != 0))
      $fatal(1, "%s: shared response slots(%0d) must equal 2*CMD_BEATS(%0d)",
             INSTANCE_ID, RESPONSE_SLOTS, CMD_BEATS);
    if (BUS_BYTES != gemm_bus_if.DATA_SIZE)
      $fatal(1, "%s: Weight source/destination beat widths differ (%0d/%0d)",
             INSTANCE_ID, BUS_BYTES, gemm_bus_if.DATA_SIZE);
    if (LMEM_ADDR_WIDTH_P != lmem_bus_if.ADDR_WIDTH)
      $fatal(1, "%s: LMEM address width mismatch (%0d/%0d)", INSTANCE_ID,
             LMEM_ADDR_WIDTH_P, lmem_bus_if.ADDR_WIDTH);
    if (GEMM_ADDR_WIDTH_P != gemm_bus_if.ADDR_WIDTH)
      $fatal(1, "%s: GEMM address width mismatch (%0d/%0d)", INSTANCE_ID,
             GEMM_ADDR_WIDTH_P, gemm_bus_if.ADDR_WIDTH);
    if (LMEM_TAG_WIDTH_P != lmem_bus_if.TAG_WIDTH)
      $fatal(1, "%s: LMEM tag width mismatch (%0d/%0d)", INSTANCE_ID,
             LMEM_TAG_WIDTH_P, lmem_bus_if.TAG_WIDTH);
    if (GEMM_TAG_WIDTH_P != gemm_bus_if.TAG_WIDTH)
      $fatal(1, "%s: GEMM tag width mismatch (%0d/%0d)", INSTANCE_ID,
             GEMM_TAG_WIDTH_P, gemm_bus_if.TAG_WIDTH);
    if (LMEM_TAG_VALUE_W < SLOT_BITS)
      $fatal(1, "%s: Weight source tag.value width(%0d) cannot encode %0d slots",
             INSTANCE_ID, LMEM_TAG_VALUE_W, RESPONSE_SLOTS);
    if (GEMM_TAG_VALUE_W < 1)
      $fatal(1, "%s: Weight destination tag.value width must be positive",
             INSTANCE_ID);
    if ((READY_AHEAD_LOW_WATERMARK < 1)
     || (READY_AHEAD_LOW_WATERMARK > RESPONSE_SLOTS))
      $fatal(1, "%s: Weight ready-ahead watermark %0d is outside 1..%0d",
             INSTANCE_ID, READY_AHEAD_LOW_WATERMARK, RESPONSE_SLOTS);
  end

  always_ff @(posedge clk) begin
    if (reset) begin
      cmd_valid_r <= '0;
      cmd_rd_done_r <= '0;
      rd_cmd_ptr_r <= '0;
      wr_cmd_ptr_r <= '0;
      cmd_tail_ptr_r <= '0;
      cmd_count_r <= '0;
      next_cmd_sequence_r <= '0;
      alloc_slot_r <= '0;
      wr_expect_slot_r <= '0;
      slot_occupancy_r <= '0;
      drain_valid_r <= 1'b0;
      drain_slot_r <= '0;
      drain_owner_cmd_r <= '0;
      drain_owner_sequence_r <= '0;
      drain_owner_beat_r <= '0;
      source_urgent_hold_valid_r <= 1'b0;
      source_urgent_hold_r <= 1'b0;
      source_priority_hold_r <= '0;
      for (int cmd = 0; cmd < CMD_FIFO_DEPTH; ++cmd) begin
        cmd_src_base_r[cmd] <= '0;
        cmd_dst_base_r[cmd] <= '0;
        cmd_seg_size_r[cmd] <= '0;
        cmd_reg_idx_r[cmd] <= '0;
        cmd_reg_value_r[cmd] <= '0;
        cmd_writer_wait_r[cmd] <= '0;
        cmd_total_beats_r[cmd] <= '0;
        cmd_rd_count_r[cmd] <= '0;
        cmd_wr_count_r[cmd] <= '0;
        cmd_rsp_count_r[cmd] <= '0;
        cmd_rd_seg_offset_r[cmd] <= '0;
        cmd_sequence_r[cmd] <= '0;
        cmd_scheduler_work_seq_r[cmd] <= '0;
        for (int d = 0; d < NDIM; ++d) begin
          cmd_src_strides_r[cmd][d] <= '0;
          cmd_dst_strides_r[cmd][d] <= '0;
          cmd_bounds_r[cmd][d] <= '0;
          cmd_rd_i_dim_r[cmd][d] <= '0;
        end
      end
      for (int slot = 0; slot < RESPONSE_SLOTS; ++slot) begin
        slot_state_r[slot] <= SLOT_FREE;
        slot_owner_cmd_r[slot] <= '0;
        slot_owner_sequence_r[slot] <= '0;
        slot_owner_beat_r[slot] <= '0;
      end
    end else begin
      if (source_req_fire) begin
        source_urgent_hold_valid_r <= 1'b0;
      end else if (lmem_bus_if.req_valid && !source_urgent_hold_valid_r) begin
        source_urgent_hold_valid_r <= 1'b1;
        source_urgent_hold_r <= source_urgent_now;
        source_priority_hold_r <= sched_priority_i;
      end
      unique case ({command_enqueue, destination_last_write})
        2'b10: cmd_count_r <= cmd_count_r + CMD_COUNT_BITS'(1);
        2'b01: cmd_count_r <= cmd_count_r - CMD_COUNT_BITS'(1);
        default:;
      endcase

      unique case ({source_req_fire, destination_write_fire})
        2'b10: slot_occupancy_r
            <= slot_occupancy_r + SLOT_COUNT_BITS'(1);
        2'b01: slot_occupancy_r
            <= slot_occupancy_r - SLOT_COUNT_BITS'(1);
        default:;
      endcase

      unique case ({slot_read_fire, destination_write_fire})
        2'b10: drain_valid_r <= 1'b1;
        2'b01: drain_valid_r <= 1'b0;
        2'b11: drain_valid_r <= 1'b1;
        default:;
      endcase

      if (destination_last_write) begin
        cmd_valid_r[wr_cmd_ptr_r] <= 1'b0;
        cmd_rd_done_r[wr_cmd_ptr_r] <= 1'b0;
        cmd_wr_count_r[wr_cmd_ptr_r] <= '0;
        cmd_rsp_count_r[wr_cmd_ptr_r] <= '0;
        wr_cmd_ptr_r <= wr_cmd_ptr_r + CMD_PTR_BITS'(1);
      end else if (destination_write_fire) begin
        cmd_wr_count_r[wr_cmd_ptr_r]
            <= cmd_wr_count_r[wr_cmd_ptr_r] + 32'd1;
      end

      if (source_rsp_fire)
        cmd_rsp_count_r[slot_owner_cmd_r[source_rsp_slot]]
            <= cmd_rsp_count_r[slot_owner_cmd_r[source_rsp_slot]]
             + 32'd1;

      if (source_req_fire) begin
        slot_state_r[alloc_slot_r] <= SLOT_WAIT_RSP;
        slot_owner_cmd_r[alloc_slot_r] <= rd_cmd_ptr_r;
        slot_owner_sequence_r[alloc_slot_r]
            <= cmd_sequence_r[rd_cmd_ptr_r];
        slot_owner_beat_r[alloc_slot_r]
            <= cmd_rd_count_r[rd_cmd_ptr_r];
        alloc_slot_r <= alloc_slot_r + SLOT_BITS'(1);
        if ((cmd_rd_seg_offset_r[rd_cmd_ptr_r] + 32'(BUS_BYTES))
            >= cmd_seg_size_r[rd_cmd_ptr_r]) begin
          cmd_rd_seg_offset_r[rd_cmd_ptr_r] <= '0;
          if ((cmd_rd_i_dim_r[rd_cmd_ptr_r][0] + 32'd1)
              < cmd_bounds_r[rd_cmd_ptr_r][0]) begin
            cmd_rd_i_dim_r[rd_cmd_ptr_r][0]
                <= cmd_rd_i_dim_r[rd_cmd_ptr_r][0] + 32'd1;
          end else begin
            cmd_rd_i_dim_r[rd_cmd_ptr_r][0] <= '0;
            if ((cmd_rd_i_dim_r[rd_cmd_ptr_r][1] + 32'd1)
                < cmd_bounds_r[rd_cmd_ptr_r][1]) begin
              cmd_rd_i_dim_r[rd_cmd_ptr_r][1]
                  <= cmd_rd_i_dim_r[rd_cmd_ptr_r][1] + 32'd1;
            end else begin
              cmd_rd_i_dim_r[rd_cmd_ptr_r][1] <= '0;
              if ((cmd_rd_i_dim_r[rd_cmd_ptr_r][2] + 32'd1)
                  < cmd_bounds_r[rd_cmd_ptr_r][2]) begin
                cmd_rd_i_dim_r[rd_cmd_ptr_r][2]
                    <= cmd_rd_i_dim_r[rd_cmd_ptr_r][2] + 32'd1;
              end
            end
          end
        end else begin
          cmd_rd_seg_offset_r[rd_cmd_ptr_r]
              <= cmd_rd_seg_offset_r[rd_cmd_ptr_r] + 32'(BUS_BYTES);
        end
        if ((cmd_rd_count_r[rd_cmd_ptr_r] + 32'd1)
            == cmd_total_beats_r[rd_cmd_ptr_r]) begin
          cmd_rd_done_r[rd_cmd_ptr_r] <= 1'b1;
          rd_cmd_ptr_r <= rd_cmd_ptr_r + CMD_PTR_BITS'(1);
        end else begin
          cmd_rd_count_r[rd_cmd_ptr_r]
              <= cmd_rd_count_r[rd_cmd_ptr_r] + 32'd1;
        end
      end

      if (source_rsp_fire)
        slot_state_r[source_rsp_slot] <= SLOT_READY;

      if (slot_read_fire) begin
        slot_state_r[wr_expect_slot_r] <= SLOT_DRAINING;
        drain_slot_r <= wr_expect_slot_r;
        drain_owner_cmd_r <= slot_owner_cmd_r[wr_expect_slot_r];
        drain_owner_sequence_r
            <= slot_owner_sequence_r[wr_expect_slot_r];
        drain_owner_beat_r <= slot_owner_beat_r[wr_expect_slot_r];
        wr_expect_slot_r <= wr_expect_slot_r + SLOT_BITS'(1);
      end

      if (destination_write_fire) begin
        slot_state_r[drain_slot_r] <= SLOT_FREE;
        slot_owner_cmd_r[drain_slot_r] <= '0;
        slot_owner_sequence_r[drain_slot_r] <= '0;
        slot_owner_beat_r[drain_slot_r] <= '0;
      end

      // Enqueue is intentionally last so a simultaneous writer pop and FIFO
      // push can reuse the retired entry without a transient invalid state.
      if (command_enqueue) begin
        cmd_valid_r[cmd_tail_ptr_r] <= 1'b1;
        cmd_rd_done_r[cmd_tail_ptr_r] <= 1'b0;
        cmd_src_base_r[cmd_tail_ptr_r] <= ctrl_if.src_base_addr;
        cmd_dst_base_r[cmd_tail_ptr_r] <= ctrl_if.dst_base_addr;
        cmd_seg_size_r[cmd_tail_ptr_r] <= ctrl_if.seg_size;
        cmd_reg_idx_r[cmd_tail_ptr_r] <= ctrl_if.reg_idx;
        cmd_reg_value_r[cmd_tail_ptr_r] <= ctrl_if.reg_value;
        cmd_writer_wait_r[cmd_tail_ptr_r] <= writer_wait_i;
        cmd_total_beats_r[cmd_tail_ptr_r]
            <= (ctrl_if.seg_size / BUS_BYTES)
             * ctrl_if.bounds[0]
             * ctrl_if.bounds[1]
             * ctrl_if.bounds[2];
        cmd_rd_count_r[cmd_tail_ptr_r] <= '0;
        cmd_wr_count_r[cmd_tail_ptr_r] <= '0;
        cmd_rd_seg_offset_r[cmd_tail_ptr_r] <= '0;
        cmd_sequence_r[cmd_tail_ptr_r] <= next_cmd_sequence_r;
        cmd_scheduler_work_seq_r[cmd_tail_ptr_r]
            <= ctrl_if.scheduler_work_seq;
        for (int d = 0; d < NDIM; ++d) begin
          cmd_src_strides_r[cmd_tail_ptr_r][d] <= ctrl_if.src_strides[d];
          cmd_dst_strides_r[cmd_tail_ptr_r][d] <= ctrl_if.dst_strides[d];
          cmd_bounds_r[cmd_tail_ptr_r][d] <= ctrl_if.bounds[d];
          cmd_rd_i_dim_r[cmd_tail_ptr_r][d] <= '0;
        end
        cmd_tail_ptr_r <= cmd_tail_ptr_r + CMD_PTR_BITS'(1);
        next_cmd_sequence_r <= next_cmd_sequence_r + 32'd1;
      end
    end
  end

`ifndef SYNTHESIS
  logic src_order_valid_r;
  logic dst_order_valid_r;
  logic [31:0] src_order_sequence_r;
  logic [31:0] dst_order_sequence_r;
  logic [31:0] src_order_beat_r;
  logic [31:0] src_order_total_beats_r;
  logic [31:0] dst_order_beat_r;
  logic [31:0] dst_order_total_beats_r;
  logic destination_stall_r;
  logic [GEMM_ADDR_WIDTH_P-1:0] destination_stall_addr_r;
  logic [BUS_BYTES*8-1:0] destination_stall_data_r;
  logic source_stall_r;
  logic source_stall_urgent_r;
  logic [GEMM_SCHED_PRIORITY_WIDTH-1:0] source_stall_priority_r;
  logic [CMD_COUNT_BITS-1:0] live_command_count;
  logic [SLOT_COUNT_BITS-1:0] live_slot_count;
  wire [CMD_PTR_BITS-1:0] slot_read_expected_cmd = destination_last_write
      ? (wr_cmd_ptr_r + CMD_PTR_BITS'(1)) : wr_cmd_ptr_r;
  wire [31:0] slot_read_expected_beat =
      destination_write_fire
      ? (destination_last_write
         ? '0
         : (cmd_wr_count_r[wr_cmd_ptr_r] + 32'd1))
      : cmd_wr_count_r[wr_cmd_ptr_r];

  always_comb begin
    live_command_count = '0;
    for (int cmd = 0; cmd < CMD_FIFO_DEPTH; ++cmd) begin
      if (cmd_valid_r[cmd])
        live_command_count = live_command_count + CMD_COUNT_BITS'(1);
    end
    live_slot_count = '0;
    for (int slot = 0; slot < RESPONSE_SLOTS; ++slot) begin
      if (slot_state_r[slot] != SLOT_FREE)
        live_slot_count = live_slot_count + SLOT_COUNT_BITS'(1);
    end
  end

  always_ff @(posedge clk) begin
    if (reset) begin
      src_order_valid_r <= 1'b0;
      dst_order_valid_r <= 1'b0;
      src_order_sequence_r <= '0;
      dst_order_sequence_r <= '0;
      src_order_beat_r <= '0;
      src_order_total_beats_r <= '0;
      dst_order_beat_r <= '0;
      dst_order_total_beats_r <= '0;
      destination_stall_r <= 1'b0;
      destination_stall_addr_r <= '0;
      destination_stall_data_r <= '0;
      source_stall_r <= 1'b0;
      source_stall_urgent_r <= 1'b0;
      source_stall_priority_r <= '0;
    end else begin
      assert (cmd_count_r <= CMD_COUNT_BITS'(CMD_FIFO_DEPTH))
        else $fatal(1, "%s: Weight command FIFO overflow", INSTANCE_ID);
      assert (slot_occupancy_r <= SLOT_COUNT_BITS'(RESPONSE_SLOTS))
        else $fatal(1, "%s: Weight response-slot overflow", INSTANCE_ID);
      assert (live_command_count == cmd_count_r)
        else $fatal(1, "%s: Weight FIFO valid/count mismatch", INSTANCE_ID);
      assert (live_slot_count == slot_occupancy_r)
        else $fatal(1, "%s: Weight slot lifecycle/count mismatch", INSTANCE_ID);
      assert (!(ctrl_if.start && !ctrl_if.idle))
        else $fatal(1, "%s: Weight command presented while FIFO full",
                    INSTANCE_ID);
      assert (!(ctrl_if.prepare && ctrl_if.prepare_ready))
        else $fatal(1, "%s: Weight executor accepted passive prepare",
                    INSTANCE_ID);

      if (command_enqueue) begin
        assert (!cmd_valid_r[cmd_tail_ptr_r] || destination_last_write)
          else $fatal(1, "%s: Weight command overwrote a live FIFO entry",
                      INSTANCE_ID);
        assert ((ctrl_if.bounds[0] != 0)
             && (ctrl_if.bounds[1] != 0)
             && (ctrl_if.bounds[2] != 0)
             && (ctrl_if.seg_size != 0)
             && ((ctrl_if.seg_size % BUS_BYTES) == 0))
          else $fatal(1, "%s: unsupported Weight descriptor shape", INSTANCE_ID);
        assert ((ctrl_if.src_base_addr[BUS_ADDR_BITS-1:0] == '0)
             && (ctrl_if.dst_base_addr[BUS_ADDR_BITS-1:0] == '0))
          else $fatal(1, "%s: Weight descriptor is not beat aligned",
                      INSTANCE_ID);
        assert ((ctrl_if.dst_strides[0] == 0)
             && (ctrl_if.dst_strides[1] == 0)
             && (ctrl_if.dst_strides[2] == 0))
          else $fatal(1, "%s: Weight destination must remain one register selector",
                      INSTANCE_ID);
        assert (!writer_wait_i.valid
             || (((writer_wait_i.reg_id
                    == GEMM_SYNC_REG_ID_WIDTH'(GEMM_RID_W_CONSUME0))
                   && (ctrl_if.dst_base_addr[BUS_ADDR_BITS] == 1'b0))
              || ((writer_wait_i.reg_id
                    == GEMM_SYNC_REG_ID_WIDTH'(GEMM_RID_W_CONSUME1))
                   && (ctrl_if.dst_base_addr[BUS_ADDR_BITS] == 1'b1))))
          else $fatal(1,
              "%s: Weight writer wait RID does not match destination buffer",
              INSTANCE_ID);
        assert (!writer_wait_i.valid || (writer_wait_i.target != 0))
          else $fatal(1, "%s: Weight writer wait target must be nonzero",
                      INSTANCE_ID);
      end

      if (source_req_fire) begin
        assert (rd_cmd_valid && (slot_state_r[alloc_slot_r] == SLOT_FREE))
          else $fatal(1, "%s: Weight source request used invalid command/slot",
                      INSTANCE_ID);
        if (src_order_valid_r) begin
          if (cmd_rd_count_r[rd_cmd_ptr_r] == 0) begin
            assert (((src_order_beat_r + 32'd1)
                      == src_order_total_beats_r)
                 && (cmd_sequence_r[rd_cmd_ptr_r]
                     == (src_order_sequence_r + 32'd1)))
              else $fatal(1, "%s: Weight source commands interleaved/reordered",
                          INSTANCE_ID);
          end else begin
            assert ((cmd_sequence_r[rd_cmd_ptr_r]
                     == src_order_sequence_r)
                 && (cmd_rd_count_r[rd_cmd_ptr_r]
                     == (src_order_beat_r + 32'd1)))
              else $fatal(1, "%s: Weight source beat order violation",
                          INSTANCE_ID);
          end
        end
        src_order_valid_r <= 1'b1;
        src_order_sequence_r <= cmd_sequence_r[rd_cmd_ptr_r];
        src_order_beat_r <= cmd_rd_count_r[rd_cmd_ptr_r];
        src_order_total_beats_r <= cmd_total_beats_r[rd_cmd_ptr_r];
      end

      if (lmem_bus_if.rsp_valid) begin
        assert (source_rsp_legal)
          else $fatal(1, "%s: Weight response targeted non-WAIT slot %0d",
                      INSTANCE_ID, source_rsp_slot);
      end

      if (slot_read_fire) begin
        assert (slot_state_r[wr_expect_slot_r] == SLOT_READY)
          else $fatal(1, "%s: Weight writer read a non-READY slot",
                      INSTANCE_ID);
        assert (cmd_valid_r[slot_read_expected_cmd]
             && (slot_owner_cmd_r[wr_expect_slot_r]
                 == slot_read_expected_cmd)
             && (slot_owner_sequence_r[wr_expect_slot_r]
                 == cmd_sequence_r[slot_read_expected_cmd])
             && (slot_owner_beat_r[wr_expect_slot_r]
                 == slot_read_expected_beat))
          else $fatal(1, "%s: Weight slot owner/beat does not match writer handoff",
                      INSTANCE_ID);
      end

      if (destination_write_fire) begin
        assert (drain_matches_writer
             && (slot_state_r[drain_slot_r] == SLOT_DRAINING))
          else $fatal(1, "%s: Weight write drained an invalid slot/owner",
                      INSTANCE_ID);
        assert ((writer_released && writer_wait_rid_valid)
             || !cmd_writer_wait_r[wr_cmd_ptr_r].valid)
          else $fatal(1, "%s: Weight destination write bypassed writer fence",
                      INSTANCE_ID);
        if (dst_order_valid_r) begin
          if (cmd_wr_count_r[wr_cmd_ptr_r] == 0) begin
            assert (((dst_order_beat_r + 32'd1)
                      == dst_order_total_beats_r)
                 && (cmd_sequence_r[wr_cmd_ptr_r]
                     == (dst_order_sequence_r + 32'd1)))
              else $fatal(1, "%s: Weight destination commands reordered",
                          INSTANCE_ID);
          end else begin
            assert ((cmd_sequence_r[wr_cmd_ptr_r]
                     == dst_order_sequence_r)
                 && (cmd_wr_count_r[wr_cmd_ptr_r]
                     == (dst_order_beat_r + 32'd1)))
              else $fatal(1, "%s: Weight destination beat order violation",
                          INSTANCE_ID);
          end
        end
        dst_order_valid_r <= 1'b1;
        dst_order_sequence_r <= cmd_sequence_r[wr_cmd_ptr_r];
        dst_order_beat_r <= cmd_wr_count_r[wr_cmd_ptr_r];
        dst_order_total_beats_r <= cmd_total_beats_r[wr_cmd_ptr_r];
      end

      if (cmd_valid_r[wr_cmd_ptr_r]
       && cmd_writer_wait_r[wr_cmd_ptr_r].valid) begin
        assert (writer_wait_rid_valid)
          else $fatal(1, "%s: Weight writer head has invalid consume RID",
                      INSTANCE_ID);
        if (!writer_released) begin
          assert (!gemm_bus_if.req_valid && !destination_write_fire)
            else $fatal(1,
                "%s: unreleased Weight writer issued a destination request",
                INSTANCE_ID);
        end
      end

      if (destination_last_write) begin
        assert (cmd_rd_done_r[wr_cmd_ptr_r]
             && ((cmd_wr_count_r[wr_cmd_ptr_r] + 32'd1)
                 == cmd_total_beats_r[wr_cmd_ptr_r]))
          else $fatal(1, "%s: Weight command completed before all reads/writes",
                      INSTANCE_ID);
      end

      if (destination_stall_r) begin
        assert (gemm_bus_if.req_valid
             && (gemm_bus_if.req_data.addr == destination_stall_addr_r)
             && (gemm_bus_if.req_data.data == destination_stall_data_r))
          else $fatal(1, "%s: Weight destination request changed under stall",
                      INSTANCE_ID);
      end
      if (source_stall_r) begin
        assert (lmem_bus_if.req_valid
             && (lmem_req_urgent_o == source_stall_urgent_r)
             && (lmem_req_priority_o == source_stall_priority_r))
          else $fatal(1, "%s: Weight source urgency changed under backpressure",
                      INSTANCE_ID);
      end
      assert (consecutive_ready_ahead <= SLOT_COUNT_BITS'(RESPONSE_SLOTS))
        else $fatal(1, "%s: Weight ready-ahead count overflow", INSTANCE_ID);
      source_stall_r <= lmem_bus_if.req_valid && !lmem_bus_if.req_ready;
      source_stall_urgent_r <= lmem_req_urgent_o;
      source_stall_priority_r <= lmem_req_priority_o;
      destination_stall_r <= gemm_bus_if.req_valid
                          && !gemm_bus_if.req_ready;
      destination_stall_addr_r <= gemm_bus_if.req_data.addr;
      destination_stall_data_r <= gemm_bus_if.req_data.data;
    end
  end
`endif

`ifdef DBG_TRACE_GEMM
  always_ff @(posedge clk) begin
    if (!reset) begin
      if (command_enqueue) begin
        `TRACE(1, ("%m : [%0t] | WEIGHT_DMA_ENQUEUE | {seq=%0d, src=0x%0h, dst=0x%0h, count=%0d}\n",
                   $time, next_cmd_sequence_r, ctrl_if.src_base_addr,
                   ctrl_if.dst_base_addr, cmd_count_r))
      end
      if (source_req_fire) begin
        `TRACE(1, ("%m : [%0t] | WEIGHT_DMA_SOURCE | {seq=%0d, beat=%0d, slot=%0d}\n",
                   $time, cmd_sequence_r[rd_cmd_ptr_r],
                   cmd_rd_count_r[rd_cmd_ptr_r], alloc_slot_r))
      end
      if (destination_write_fire) begin
        `TRACE(1, ("%m : [%0t] | WEIGHT_DMA_DEST | {seq=%0d, beat=%0d, slot=%0d, last=%0d}\n",
                   $time, cmd_sequence_r[wr_cmd_ptr_r],
                   cmd_wr_count_r[wr_cmd_ptr_r], drain_slot_r,
                   destination_last_write))
      end
    end
  end
`endif

`ifdef PERF_ENABLE
  reg [PERF_CTR_BITS-1:0] perf_rd_bytes_r;
  reg [PERF_CTR_BITS-1:0] perf_wr_bytes_r;
  reg [PERF_CTR_BITS-1:0] perf_xfers_r;
  reg [PERF_CTR_BITS-1:0] perf_active_r;
  reg [PERF_CTR_BITS-1:0] perf_src_req_fire_r;
  reg [PERF_CTR_BITS-1:0] perf_src_req_stall_r;
  reg [PERF_CTR_BITS-1:0] perf_src_data_fire_r;
  reg [PERF_CTR_BITS-1:0] perf_src_data_stall_r;
  reg [PERF_CTR_BITS-1:0] perf_dst_fire_r;
  reg [PERF_CTR_BITS-1:0] perf_dst_stall_r;

  always_ff @(posedge clk) begin
    if (reset) begin
      perf_rd_bytes_r <= '0;
      perf_wr_bytes_r <= '0;
      perf_xfers_r <= '0;
      perf_active_r <= '0;
      perf_src_req_fire_r <= '0;
      perf_src_req_stall_r <= '0;
      perf_src_data_fire_r <= '0;
      perf_src_data_stall_r <= '0;
      perf_dst_fire_r <= '0;
      perf_dst_stall_r <= '0;
    end else begin
      if (source_rsp_fire)
        perf_rd_bytes_r <= perf_rd_bytes_r + PERF_CTR_BITS'(BUS_BYTES);
      if (destination_write_fire)
        perf_wr_bytes_r <= perf_wr_bytes_r + PERF_CTR_BITS'(BUS_BYTES);
      if (destination_last_write)
        perf_xfers_r <= perf_xfers_r + PERF_CTR_BITS'(1);
      if (cmd_count_r != 0)
        perf_active_r <= perf_active_r + PERF_CTR_BITS'(1);
      if (source_req_fire)
        perf_src_req_fire_r <= perf_src_req_fire_r + PERF_CTR_BITS'(1);
      if (lmem_bus_if.req_valid && !lmem_bus_if.req_ready)
        perf_src_req_stall_r <= perf_src_req_stall_r + PERF_CTR_BITS'(1);
      if (source_rsp_fire)
        perf_src_data_fire_r <= perf_src_data_fire_r + PERF_CTR_BITS'(1);
      if (lmem_bus_if.rsp_valid && !lmem_bus_if.rsp_ready)
        perf_src_data_stall_r <= perf_src_data_stall_r + PERF_CTR_BITS'(1);
      if (destination_write_fire)
        perf_dst_fire_r <= perf_dst_fire_r + PERF_CTR_BITS'(1);
      if (gemm_bus_if.req_valid && !gemm_bus_if.req_ready)
        perf_dst_stall_r <= perf_dst_stall_r + PERF_CTR_BITS'(1);
    end
  end

  assign perf.rd_bytes = perf_rd_bytes_r;
  assign perf.wr_bytes = perf_wr_bytes_r;
  assign perf.xfer_count = perf_xfers_r;
  assign perf.active_cycles = perf_active_r;
  assign perf.src_rd_req_fire = perf_src_req_fire_r;
  assign perf.src_rd_req_stall = perf_src_req_stall_r;
  assign perf.src_rd_data_fire = perf_src_data_fire_r;
  assign perf.src_rd_data_stall = perf_src_data_stall_r;
  assign perf.dst_wr_fire = perf_dst_fire_r;
  assign perf.dst_wr_stall = perf_dst_stall_r;
  assign perf.wait_dcache = '0;
  assign perf.wait_lmem = '0;
  assign perf.busy = (cmd_count_r != 0);
`endif

`ifdef CHIPSCOPE
`ifdef DBG_SCOPE_GEMM
  (* keep = "true", mark_debug = "true" *) wire [63:0] dbg_weight_dma = {
    cmd_valid_r,
    cmd_rd_done_r,
    rd_cmd_ptr_r,
    wr_cmd_ptr_r,
    cmd_tail_ptr_r,
    cmd_count_r,
    alloc_slot_r,
    wr_expect_slot_r,
    slot_occupancy_r,
    drain_valid_r,
    drain_slot_r,
    source_req_fire,
    source_rsp_fire,
    destination_write_fire,
    destination_last_write,
    37'd0
  };
`endif
`endif

endmodule
