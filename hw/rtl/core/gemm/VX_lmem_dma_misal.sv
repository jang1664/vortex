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
  parameter int BOUND_WIDTH = `DMA_BOUND_WIDTH,
  parameter int MAX_DIMS = NDIM,
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
  localparam int BYTES_D0_WIDTH = 32 + BOUND_WIDTH;
  localparam int BYTES_D01_WIDTH = BYTES_D0_WIDTH + BOUND_WIDTH;
  localparam int BYTES_D012_WIDTH = BYTES_D01_WIDTH + BOUND_WIDTH;

  `UNUSED_PARAM (RD_PREFETCH_DEPTH)

  initial begin
    if ((DIR < 0) || (DIR > 1))
      $fatal(1, "%s: DIR(%0d) must be 0 or 1", INSTANCE_ID, DIR);
    if (NDIM != 3)
      $fatal(1, "%s: NDIM(%0d) unsupported, this implementation requires NDIM=3",
             INSTANCE_ID, NDIM);
    if ((MAX_DIMS < 1) || (MAX_DIMS > NDIM))
      $fatal(1, "%s: MAX_DIMS(%0d) must be in 1..%0d",
             INSTANCE_ID, MAX_DIMS, NDIM);
    if (BOUND_WIDTH != ctrl_if.BOUND_WIDTH)
      $fatal(1, "%s: BOUND_WIDTH(%0d) != ctrl_if.BOUND_WIDTH(%0d)",
             INSTANCE_ID, BOUND_WIDTH, ctrl_if.BOUND_WIDTH);
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
  VX_dma_lookahead_if #(
    .BOUND_WIDTH (BOUND_WIDTH)
  ) dma_lookahead_if ();

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
  logic [31:0] prepared_src_strides_r[MAX_DIMS];
  logic [31:0] prepared_dst_strides_r[MAX_DIMS];
  logic [BOUND_WIDTH-1:0] prepared_bounds_r[MAX_DIMS];
  logic [31:0] prepared_seg_size_r;

  logic prepared_descriptor_match;
  wire prepare_supported = (DIR == 0) && !ENABLE_MISALIGN;
  always_comb begin
    prepared_descriptor_match = prepared_r
        && (ctrl_if.src_base_addr == prepared_src_base_r)
        && (ctrl_if.dst_base_addr == prepared_dst_base_r)
        && (ctrl_if.seg_size == prepared_seg_size_r);
    for (int d = 0; d < MAX_DIMS; ++d) begin
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
  wire [BYTES_D0_WIDTH-1:0] descriptor_bytes_d0
      = ctrl_if.seg_size * ctrl_if.bounds[0];
  wire [BYTES_D01_WIDTH-1:0] descriptor_bytes_d01
      = descriptor_bytes_d0 * ctrl_if.bounds[1];
  wire [BYTES_D012_WIDTH-1:0] descriptor_bytes_d012
      = descriptor_bytes_d01 * ctrl_if.bounds[2];
  logic [63:0] descriptor_write_bytes;
  logic descriptor_write_overflow;
  generate
    if (MAX_DIMS == 1) begin : g_descriptor_bytes_1d
      always_comb begin
        descriptor_write_bytes = 64'(descriptor_bytes_d0);
        descriptor_write_overflow = |(descriptor_bytes_d0 >> 64);
      end
    end else if (MAX_DIMS == 2) begin : g_descriptor_bytes_2d
      always_comb begin
        descriptor_write_bytes = 64'(descriptor_bytes_d01);
        descriptor_write_overflow = |(descriptor_bytes_d01 >> 64);
      end
    end else begin : g_descriptor_bytes_3d
      always_comb begin
        descriptor_write_bytes = descriptor_bytes_d012[63:0];
        descriptor_write_overflow = |(descriptor_bytes_d012 >> 64);
      end
    end
  endgenerate
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
      dma_cfg_if.regs[11 + d] = 32'(ctrl_if.bounds[d]);
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
      for (int d = 0; d < MAX_DIMS; ++d) begin
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
        for (int d = 0; d < MAX_DIMS; ++d) begin
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
      if (cfg_fire) begin
        assert (!descriptor_write_overflow)
          else $fatal(1, "%s: descriptor byte count exceeds 64 bits",
                      INSTANCE_ID);
        if (MAX_DIMS == 1) begin
          assert ((ctrl_if.bounds[1] == BOUND_WIDTH'(1))
               && (ctrl_if.bounds[2] == BOUND_WIDTH'(1)))
            else $fatal(1, "%s: 1D DMA requires BND1/BND2=1", INSTANCE_ID);
        end else if (MAX_DIMS == 2) begin
          assert (ctrl_if.bounds[2] == BOUND_WIDTH'(1))
            else $fatal(1, "%s: 2D DMA requires BND2=1", INSTANCE_ID);
        end
      end
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
    .FIXED_DIR           (DIR),
    .BOUND_WIDTH         (BOUND_WIDTH),
    .MAX_DIMS            (MAX_DIMS)
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
// VX_lmem_dma_input_overlap
//  IMPROVE Input adapter around the common descriptor/response-slot/ordered
//  install queue.  TMEM address generation, scheduler gating and destination
//  mapping remain local to this adapter.
//==============================================================================

module VX_lmem_dma_input_overlap import VX_gpu_pkg::*; #(
  parameter `STRING INSTANCE_ID = "",
  parameter int NDIM = 3,
  parameter int BOUND_WIDTH = `DMA_BOUND_WIDTH,
  parameter int MAX_DIMS = NDIM,
  parameter int TAG_WIDTH = 1,
  parameter int CMD_FIFO_DEPTH = 4,
  parameter int RESPONSE_SLOTS = 8,
  parameter bit RESPONSE_DATA_RAM = 1'b1,
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
  localparam int CMD_COUNT_BITS = $clog2(CMD_FIFO_DEPTH + 1);
  localparam int SLOT_BITS = $clog2(RESPONSE_SLOTS);
  localparam int SLOT_COUNT_BITS = $clog2(RESPONSE_SLOTS + 1);
  localparam int LMEM_TAG_VALUE_W = LMEM_TAG_WIDTH_P - `UP(UUID_WIDTH);
  localparam int BEATS_D0_WIDTH = 32 + BOUND_WIDTH;
  localparam int BEATS_D01_WIDTH = BEATS_D0_WIDTH + BOUND_WIDTH;
  localparam int BEATS_D012_WIDTH = BEATS_D01_WIDTH + BOUND_WIDTH;
  localparam int ADDR_PRODUCT_WIDTH = BOUND_WIDTH + 32;

  typedef struct packed {
    logic [31:0] scheduler_work_seq;
    logic [31:0] seg_size;
    logic [MAX_DIMS-1:0][BOUND_WIDTH-1:0] bounds;
    logic [MAX_DIMS-1:0][31:0] strides;
    logic [63:0] base_addr;
  } input_source_meta_t;

  typedef struct packed {
    logic [31:0] reg_value;
    logic [31:0] reg_idx;
    logic [63:0] base_addr;
  } input_dest_meta_t;

  localparam int SOURCE_METAW = $bits(input_source_meta_t);
  localparam int DEST_METAW = $bits(input_dest_meta_t);
  localparam int DATAW = BUS_BYTES * 8;

  VX_gemm_dma_fetch_if #(
    .INSTANCE_ID   ({INSTANCE_ID, ".fetch_if"}),
    .CMD_PAYLOADW  (SOURCE_METAW + DEST_METAW),
    .REQ_PAYLOADW  (SOURCE_METAW + 32),
    .RSP_PAYLOADW  (DATAW),
    .TAGW          (LMEM_TAG_VALUE_W),
    .COUNTW        (32),
    .SLOT_COUNTW   (SLOT_COUNT_BITS),
    .SLOT_CAPACITY (RESPONSE_SLOTS)
  ) dma_fetch_if (clk, reset);

  VX_gemm_dma_sink_if #(
    .INSTANCE_ID ({INSTANCE_ID, ".sink_if"}),
    .PAYLOADW    (DEST_METAW + 32 + DATAW),
    .TAGW        (64),
    .COUNTW      (32)
  ) dma_sink_if (clk, reset);

  input_source_meta_t command_source_meta;
  input_dest_meta_t command_dest_meta;
  input_source_meta_t fetch_source_meta;
  input_dest_meta_t sink_dest_meta;
  input_dest_meta_t writer_dest_meta;
  wire [31:0] fetch_beat = dma_fetch_if.req_payload[31:0];
  wire [31:0] sink_beat = dma_sink_if.write_payload[DATAW +: 32];
  wire [DATAW-1:0] sink_data = dma_sink_if.write_payload[DATAW-1:0];

  wire [SOURCE_METAW+DEST_METAW-1:0] writer_head_payload;
  wire writer_head_valid;
  wire [31:0] writer_head_cmd_id;
  wire [31:0] writer_head_sequence;
  wire fetch_complete_valid;
  wire [31:0] fetch_complete_cmd_id;
  wire [31:0] fetch_complete_sequence;
  wire install_complete_valid;
  wire [31:0] install_complete_cmd_id;
  wire [31:0] install_complete_sequence;
  wire [31:0] fetch_head_write_beats;
  wire [CMD_COUNT_BITS-1:0] queue_cmd_occupancy;
  wire [SLOT_COUNT_BITS-1:0] queue_slot_occupancy;
  wire [SLOT_COUNT_BITS-1:0] queue_ready_ahead;

  assign command_source_meta.scheduler_work_seq
      = ctrl_if.scheduler_work_seq;
  assign command_source_meta.seg_size = ctrl_if.seg_size;
  for (genvar meta_dim = 0; meta_dim < MAX_DIMS; ++meta_dim) begin : g_input_meta
    assign command_source_meta.bounds[meta_dim] = ctrl_if.bounds[meta_dim];
    assign command_source_meta.strides[meta_dim]
        = ctrl_if.src_strides[meta_dim];
  end
  assign command_source_meta.base_addr = ctrl_if.src_base_addr;
  assign command_dest_meta.reg_value = ctrl_if.reg_value;
  assign command_dest_meta.reg_idx = ctrl_if.reg_idx;
  assign command_dest_meta.base_addr = ctrl_if.dst_base_addr;

  assign fetch_source_meta = dma_fetch_if.req_payload[32 +: SOURCE_METAW];
  assign sink_dest_meta = dma_sink_if.write_payload[DATAW+32 +: DEST_METAW];
  assign writer_dest_meta = writer_head_payload[DEST_METAW-1:0];

  wire [31:0] command_seg_beats = ctrl_if.seg_size / BUS_BYTES;
  wire [BEATS_D0_WIDTH-1:0] command_beats_d0
      = command_seg_beats * ctrl_if.bounds[0];
  wire [BEATS_D01_WIDTH-1:0] command_beats_d01
      = command_beats_d0 * ctrl_if.bounds[1];
  wire [BEATS_D012_WIDTH-1:0] command_beats_d012
      = command_beats_d01 * ctrl_if.bounds[2];
  logic [31:0] command_total_beats;
  logic command_total_beats_overflow;
  generate
    if (MAX_DIMS == 1) begin : g_input_beats_1d
      always_comb begin
        command_total_beats = 32'(command_beats_d0);
        command_total_beats_overflow = |(command_beats_d0 >> 32);
      end
    end else if (MAX_DIMS == 2) begin : g_input_beats_2d
      always_comb begin
        command_total_beats = 32'(command_beats_d01);
        command_total_beats_overflow = |(command_beats_d01 >> 32);
      end
    end else begin : g_input_beats_3d
      always_comb begin
        command_total_beats = 32'(command_beats_d012);
        command_total_beats_overflow = |(command_beats_d012 >> 32);
      end
    end
  endgenerate

  assign dma_fetch_if.cmd_valid = ctrl_if.start;
  assign dma_fetch_if.cmd_id = ctrl_if.scheduler_work_seq;
  assign dma_fetch_if.cmd_total_beats = command_total_beats;
  assign dma_fetch_if.cmd_payload = {command_source_meta, command_dest_meta};

  logic [BOUND_WIDTH-1:0] rd_i_dim_r[MAX_DIMS];
  logic [31:0] rd_seg_offset_r;
  wire [ADDR_PRODUCT_WIDTH-1:0] rd_dim_stride[MAX_DIMS];
  for (genvar addr_dim = 0; addr_dim < MAX_DIMS; ++addr_dim) begin : g_input_addr_product
    assign rd_dim_stride[addr_dim]
        = rd_i_dim_r[addr_dim] * fetch_source_meta.strides[addr_dim];
  end
  logic [63:0] rd_src_byte_addr;
  generate
    if (MAX_DIMS == 1) begin : g_input_addr_1d
      always_comb rd_src_byte_addr = fetch_source_meta.base_addr
          + 64'(rd_dim_stride[0]) + 64'(rd_seg_offset_r);
    end else if (MAX_DIMS == 2) begin : g_input_addr_2d
      always_comb rd_src_byte_addr = fetch_source_meta.base_addr
          + 64'(rd_dim_stride[0]) + 64'(rd_dim_stride[1])
          + 64'(rd_seg_offset_r);
    end else begin : g_input_addr_3d
      always_comb rd_src_byte_addr = fetch_source_meta.base_addr
          + 64'(rd_dim_stride[0]) + 64'(rd_dim_stride[1])
          + 64'(rd_dim_stride[2]) + 64'(rd_seg_offset_r);
    end
  endgenerate

  logic source_urgent_hold_valid_r;
  logic source_urgent_hold_r;
  logic [GEMM_SCHED_PRIORITY_WIDTH-1:0] source_priority_hold_r;
  wire source_urgent_now = queue_ready_ahead
      < SLOT_COUNT_BITS'(READY_AHEAD_LOW_WATERMARK);
  assign lmem_req_priority_o = source_urgent_hold_valid_r
      ? source_priority_hold_r : sched_priority_i;
  assign lmem_req_urgent_o = ENABLE_TMEM_URGENCY
      && (source_urgent_hold_valid_r ? source_urgent_hold_r
                                     : source_urgent_now)
      && ((fetch_source_meta.scheduler_work_seq == 0)
       || (lmem_req_priority_o != GEMM_SCHED_PRIORITY_BACKGROUND));
  wire sched_source_allowed = !ENABLE_SCHED_SOURCE_GATE
                           || sched_source_enable_i
                           || source_urgent_hold_valid_r;

  assign lmem_bus_if.req_valid = dma_fetch_if.req_valid
                              && sched_source_allowed;
  assign dma_fetch_if.req_ready = lmem_bus_if.req_ready
                               && sched_source_allowed;
  assign lmem_bus_if.req_data.rw = 1'b0;
  assign lmem_bus_if.req_data.addr
      = LMEM_ADDR_WIDTH_P'(rd_src_byte_addr >> BUS_ADDR_BITS);
  assign lmem_bus_if.req_data.data = '0;
  assign lmem_bus_if.req_data.byteen = '1;
  assign lmem_bus_if.req_data.flags = '0;
  assign lmem_bus_if.req_data.tag.uuid = '0;
  assign lmem_bus_if.req_data.tag.value = dma_fetch_if.req_tag;

  assign dma_fetch_if.rsp_valid = lmem_bus_if.rsp_valid;
  assign dma_fetch_if.rsp_tag = lmem_bus_if.rsp_data.tag.value;
  assign dma_fetch_if.rsp_payload = lmem_bus_if.rsp_data.data;
  assign lmem_bus_if.rsp_ready = dma_fetch_if.rsp_ready;

  assign gemm_bus_if.req_valid = dma_sink_if.write_valid;
  assign dma_sink_if.write_ready = gemm_bus_if.req_ready;
  assign gemm_bus_if.req_data.rw = 1'b1;
  // Preserve the established Input destination contract: every admitted beat
  // targets the descriptor base; qparam progression remains in the legacy
  // private executor until its separate Step-8 migration.
  assign gemm_bus_if.req_data.addr
      = GEMM_ADDR_WIDTH_P'(sink_dest_meta.base_addr >> BUS_ADDR_BITS);
  assign gemm_bus_if.req_data.data = sink_data;
  assign gemm_bus_if.req_data.byteen = '1;
  assign gemm_bus_if.req_data.flags = '0;
  assign gemm_bus_if.req_data.tag.uuid = '0;
  assign gemm_bus_if.req_data.tag.value = '0;
  assign gemm_bus_if.rsp_ready = 1'b1;

  VX_gemm_stream_dma_queue #(
    .INSTANCE_ID    ({INSTANCE_ID, ".stream_queue"}),
    .CMD_FIFO_DEPTH (CMD_FIFO_DEPTH),
    .RESPONSE_SLOTS (RESPONSE_SLOTS),
    .SOURCE_METAW   (SOURCE_METAW),
    .DEST_METAW     (DEST_METAW),
    .DATAW          (DATAW),
    .COUNTW         (32),
    .SEQW           (32),
    .FETCH_TAGW     (LMEM_TAG_VALUE_W),
    .RING_SLOT_ORDER(1'b1),
    .SINK_PIPELINE  (1'b1),
    .RESPONSE_DATA_RAM (RESPONSE_DATA_RAM)
  ) u_stream_queue (
    .clk(clk),
    .reset(reset),
    .writer_release_i(1'b1),
    .fetch_if(dma_fetch_if),
    .sink_if(dma_sink_if),
    .writer_head_valid_o(writer_head_valid),
    .writer_head_cmd_id_o(writer_head_cmd_id),
    .writer_head_cmd_payload_o(writer_head_payload),
    .writer_head_sequence_o(writer_head_sequence),
    .fetch_complete_valid_o(fetch_complete_valid),
    .fetch_complete_cmd_id_o(fetch_complete_cmd_id),
    .fetch_complete_sequence_o(fetch_complete_sequence),
    .install_complete_valid_o(install_complete_valid),
    .install_complete_cmd_id_o(install_complete_cmd_id),
    .install_complete_sequence_o(install_complete_sequence),
    .fetch_head_write_beats_o(fetch_head_write_beats),
    .install_ready_ahead_o(queue_ready_ahead),
    .cmd_occupancy_o(queue_cmd_occupancy),
    .slot_occupancy_o(queue_slot_occupancy)
  );

  wire source_req_fire = dma_fetch_if.req_valid && dma_fetch_if.req_ready;
  wire destination_write_fire = dma_sink_if.write_valid
                              && dma_sink_if.write_ready;

  assign ctrl_if.idle = dma_fetch_if.cmd_ready;
  assign ctrl_if.prepare_ready = 1'b0;
  assign ctrl_if.write_done = install_complete_valid;
  assign ctrl_if.done = install_complete_valid;
  assign gemm_sync_if.valid = 1'b0;
  assign gemm_sync_if.reg_idx = writer_head_valid
                              ? writer_dest_meta.reg_idx : '0;
  assign gemm_sync_if.value = writer_head_valid
                            ? writer_dest_meta.reg_value : '0;

  assign ready_ahead_o = queue_ready_ahead;
  assign sched_source_valid_o = dma_fetch_if.progress_valid;
  assign sched_source_work_seq_o = dma_fetch_if.progress_valid
      ? fetch_source_meta.scheduler_work_seq : '0;
  assign sched_source_total_beats_o = dma_fetch_if.progress_valid
      ? dma_fetch_if.progress_total_beats : '0;
  assign sched_source_request_beats_o = dma_fetch_if.progress_valid
      ? dma_fetch_if.progress_request_beats : '0;
  assign sched_source_response_beats_o = dma_fetch_if.progress_valid
      ? dma_fetch_if.progress_response_beats : '0;
  assign sched_source_writer_beats_o = dma_fetch_if.progress_valid
      ? fetch_head_write_beats : '0;
  assign sched_slot_occupancy_o = queue_slot_occupancy;
  assign sched_fetch_complete_o = fetch_complete_valid;
  assign sched_fetch_complete_work_seq_o = fetch_complete_cmd_id;

  // Preserve the focused/debug hierarchy names used before extraction.
  wire [CMD_COUNT_BITS-1:0] cmd_count_r = queue_cmd_occupancy;
  wire [SLOT_COUNT_BITS-1:0] slot_occupancy_r = queue_slot_occupancy;

  always_ff @(posedge clk) begin
    if (reset) begin
      source_urgent_hold_valid_r <= 1'b0;
      source_urgent_hold_r <= 1'b0;
      source_priority_hold_r <= '0;
    end else begin
      if (source_req_fire) begin
        source_urgent_hold_valid_r <= 1'b0;
      end else if (lmem_bus_if.req_valid && !source_urgent_hold_valid_r) begin
        source_urgent_hold_valid_r <= 1'b1;
        source_urgent_hold_r <= source_urgent_now;
        source_priority_hold_r <= sched_priority_i;
      end

    end
  end

  generate
    if (MAX_DIMS == 1) begin : g_input_advance_1d
      always_ff @(posedge clk) begin
        if (reset) begin
          rd_i_dim_r <= '{default:'0};
          rd_seg_offset_r <= '0;
        end else if (source_req_fire) begin
          if ((fetch_beat + 32'd1) == dma_fetch_if.progress_total_beats) begin
            rd_i_dim_r <= '{default:'0};
            rd_seg_offset_r <= '0;
          end else if ((rd_seg_offset_r + 32'(BUS_BYTES))
                       >= fetch_source_meta.seg_size) begin
            rd_seg_offset_r <= '0;
            if ((rd_i_dim_r[0] + BOUND_WIDTH'(1))
                < fetch_source_meta.bounds[0])
              rd_i_dim_r[0] <= rd_i_dim_r[0] + BOUND_WIDTH'(1);
            else
              rd_i_dim_r[0] <= '0;
          end else begin
            rd_seg_offset_r <= rd_seg_offset_r + 32'(BUS_BYTES);
          end
        end
      end
    end else if (MAX_DIMS == 2) begin : g_input_advance_2d
      always_ff @(posedge clk) begin
        if (reset) begin
          rd_i_dim_r <= '{default:'0};
          rd_seg_offset_r <= '0;
        end else if (source_req_fire) begin
          if ((fetch_beat + 32'd1) == dma_fetch_if.progress_total_beats) begin
            rd_i_dim_r <= '{default:'0};
            rd_seg_offset_r <= '0;
          end else if ((rd_seg_offset_r + 32'(BUS_BYTES))
                       >= fetch_source_meta.seg_size) begin
            rd_seg_offset_r <= '0;
            if ((rd_i_dim_r[0] + BOUND_WIDTH'(1))
                < fetch_source_meta.bounds[0]) begin
              rd_i_dim_r[0] <= rd_i_dim_r[0] + BOUND_WIDTH'(1);
            end else begin
              rd_i_dim_r[0] <= '0;
              if ((rd_i_dim_r[1] + BOUND_WIDTH'(1))
                  < fetch_source_meta.bounds[1])
                rd_i_dim_r[1] <= rd_i_dim_r[1] + BOUND_WIDTH'(1);
              else
                rd_i_dim_r[1] <= '0;
            end
          end else begin
            rd_seg_offset_r <= rd_seg_offset_r + 32'(BUS_BYTES);
          end
        end
      end
    end else begin : g_input_advance_3d
      always_ff @(posedge clk) begin
        if (reset) begin
          rd_i_dim_r <= '{default:'0};
          rd_seg_offset_r <= '0;
        end else if (source_req_fire) begin
          if ((fetch_beat + 32'd1) == dma_fetch_if.progress_total_beats) begin
            rd_i_dim_r <= '{default:'0};
            rd_seg_offset_r <= '0;
          end else if ((rd_seg_offset_r + 32'(BUS_BYTES))
                       >= fetch_source_meta.seg_size) begin
            rd_seg_offset_r <= '0;
            if ((rd_i_dim_r[0] + BOUND_WIDTH'(1))
                < fetch_source_meta.bounds[0]) begin
              rd_i_dim_r[0] <= rd_i_dim_r[0] + BOUND_WIDTH'(1);
            end else begin
              rd_i_dim_r[0] <= '0;
              if ((rd_i_dim_r[1] + BOUND_WIDTH'(1))
                  < fetch_source_meta.bounds[1]) begin
                rd_i_dim_r[1] <= rd_i_dim_r[1] + BOUND_WIDTH'(1);
              end else begin
                rd_i_dim_r[1] <= '0;
                if ((rd_i_dim_r[2] + BOUND_WIDTH'(1))
                    < fetch_source_meta.bounds[2])
                  rd_i_dim_r[2] <= rd_i_dim_r[2] + BOUND_WIDTH'(1);
              end
            end
          end else begin
            rd_seg_offset_r <= rd_seg_offset_r + 32'(BUS_BYTES);
          end
        end
      end
    end
  endgenerate

  initial begin
    if (NDIM != 3)
      $fatal(1, "%s: Input overlap DMA requires NDIM=3", INSTANCE_ID);
    if ((MAX_DIMS < 1) || (MAX_DIMS > NDIM))
      $fatal(1, "%s: Input MAX_DIMS(%0d) must be in 1..%0d",
             INSTANCE_ID, MAX_DIMS, NDIM);
    if (BOUND_WIDTH != ctrl_if.BOUND_WIDTH)
      $fatal(1, "%s: Input bound width mismatch", INSTANCE_ID);
    if ((CMD_FIFO_DEPTH != 2) && (CMD_FIFO_DEPTH != 4))
      $fatal(1, "%s: common Input queue depth must be 2 or 4", INSTANCE_ID);
    if ((RESPONSE_SLOTS < 1)
     || ((RESPONSE_SLOTS & (RESPONSE_SLOTS - 1)) != 0))
      $fatal(1, "%s: common Input queue slots must be a positive power of two",
             INSTANCE_ID);
    if (ENABLE_WRITER_FENCE || !ENABLE_SAME_CYCLE_CMD_RECYCLE)
      $fatal(1, "%s: common Input adapter cannot be used as qparam legacy path",
             INSTANCE_ID);
    if (BUS_BYTES != gemm_bus_if.DATA_SIZE)
      $fatal(1, "%s: Input source/destination beat widths differ", INSTANCE_ID);
    if ((LMEM_ADDR_WIDTH_P != lmem_bus_if.ADDR_WIDTH)
     || (GEMM_ADDR_WIDTH_P != gemm_bus_if.ADDR_WIDTH))
      $fatal(1, "%s: Input address width mismatch", INSTANCE_ID);
    if ((LMEM_TAG_WIDTH_P != lmem_bus_if.TAG_WIDTH)
     || (GEMM_TAG_WIDTH_P != gemm_bus_if.TAG_WIDTH)
     || (LMEM_TAG_VALUE_W < SLOT_BITS))
      $fatal(1, "%s: Input tag width mismatch", INSTANCE_ID);
    if ((READY_AHEAD_LOW_WATERMARK < 1)
     || (READY_AHEAD_LOW_WATERMARK > RESPONSE_SLOTS))
      $fatal(1, "%s: Input ready-ahead watermark out of range", INSTANCE_ID);
  end

`ifndef SYNTHESIS
  `UNUSED_VAR (writer_wait_i)
  `UNUSED_VAR (writer_consume_value0_i)
  `UNUSED_VAR (writer_consume_value1_i)
  `UNUSED_VAR (sink_beat)
  `UNUSED_VAR (writer_head_cmd_id)
  `UNUSED_VAR (writer_head_sequence)
  `UNUSED_VAR (fetch_complete_sequence)
  `UNUSED_VAR (install_complete_cmd_id)
  `UNUSED_VAR (install_complete_sequence)

  logic destination_stall_r;
  logic [GEMM_ADDR_WIDTH_P-1:0] destination_stall_addr_r;
  logic [DATAW-1:0] destination_stall_data_r;
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
      assert (!(ctrl_if.start && !ctrl_if.idle))
        else $fatal(1, "%s: Input command presented while FIFO full",
                    INSTANCE_ID);
      if (ctrl_if.start && ctrl_if.idle) begin
        assert (!command_total_beats_overflow
             && (ctrl_if.bounds[0] != 0)
             && (ctrl_if.bounds[1] != 0)
             && (ctrl_if.bounds[2] != 0)
             && (ctrl_if.seg_size != 0)
             && ((ctrl_if.seg_size % BUS_BYTES) == 0)
             && !writer_wait_i.valid)
          else $fatal(1, "%s: unsupported common Input descriptor shape",
                      INSTANCE_ID);
        if (MAX_DIMS == 1) begin
          assert ((ctrl_if.bounds[1] == BOUND_WIDTH'(1))
               && (ctrl_if.bounds[2] == BOUND_WIDTH'(1)))
            else $fatal(1, "%s: 1D Input requires BND1/BND2=1", INSTANCE_ID);
        end else if (MAX_DIMS == 2) begin
          assert (ctrl_if.bounds[2] == BOUND_WIDTH'(1))
            else $fatal(1, "%s: 2D Input requires BND2=1", INSTANCE_ID);
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
      assert (queue_ready_ahead <= SLOT_COUNT_BITS'(RESPONSE_SLOTS))
        else $fatal(1, "%s: Input ready-ahead overflow", INSTANCE_ID);
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
      if (ctrl_if.start && ctrl_if.idle)
        `TRACE(1, ("%m : [%0t] | INPUT_DMA_ENQUEUE | {seq=%0d, beats=%0d}\n",
                   $time, ctrl_if.scheduler_work_seq, command_total_beats))
      if (source_req_fire)
        `TRACE(1, ("%m : [%0t] | INPUT_DMA_SOURCE | {seq=%0d, beat=%0d, slot=%0d}\n",
                   $time, fetch_source_meta.scheduler_work_seq,
                   fetch_beat, dma_fetch_if.req_tag))
      if (destination_write_fire)
        `TRACE(1, ("%m : [%0t] | INPUT_DMA_DEST | {seq=%0d, beat=%0d, total=%0d, last=%0d}\n",
                   $time, writer_head_sequence, sink_beat,
                   dma_sink_if.progress_total_beats,
                   dma_sink_if.install_complete))
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
      if (dma_fetch_if.rsp_valid && dma_fetch_if.rsp_ready)
        perf_rd_bytes_r <= perf_rd_bytes_r + PERF_CTR_BITS'(BUS_BYTES);
      if (destination_write_fire)
        perf_wr_bytes_r <= perf_wr_bytes_r + PERF_CTR_BITS'(BUS_BYTES);
      if (install_complete_valid)
        perf_xfers_r <= perf_xfers_r + PERF_CTR_BITS'(1);
      if (queue_cmd_occupancy != 0)
        perf_active_r <= perf_active_r + PERF_CTR_BITS'(1);
      if (source_req_fire)
        perf_src_req_fire_r <= perf_src_req_fire_r + PERF_CTR_BITS'(1);
      if (lmem_bus_if.req_valid && !lmem_bus_if.req_ready)
        perf_src_req_stall_r <= perf_src_req_stall_r + PERF_CTR_BITS'(1);
      if (dma_fetch_if.rsp_valid && dma_fetch_if.rsp_ready)
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
  assign perf.busy = (queue_cmd_occupancy != 0);
`endif

endmodule

//==============================================================================
// VX_lmem_dma_qparam_overlap
//  Scale/Zero-point source-prefetch executor.  The common ordered read/write
//  engine is configured with a resource-specific two-bank consume fence.
//==============================================================================

module VX_lmem_dma_qparam_queue import VX_gpu_pkg::*; #(
  parameter `STRING INSTANCE_ID = "",
  parameter int NDIM = 3,
  parameter int BOUND_WIDTH = `DMA_BOUND_WIDTH,
  parameter int MAX_DIMS = NDIM,
  parameter int TAG_WIDTH = 1,
  parameter int CMD_FIFO_DEPTH = 4,
  parameter int RESPONSE_SLOTS = 8,
  parameter bit RESPONSE_DATA_RAM = 1'b1,
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
  output wire [31:0] sched_fetch_complete_work_seq_o,
  output wire [GEMM_SCHED_PRIORITY_WIDTH-1:0] lmem_req_priority_o
`ifdef PERF_ENABLE
  ,output dma_perf_t perf
`endif
);

  localparam int BUS_BYTES = lmem_bus_if.DATA_SIZE;
  localparam int BUS_ADDR_BITS = `CLOG2(BUS_BYTES);
  localparam int CMD_COUNT_BITS = $clog2(CMD_FIFO_DEPTH + 1);
  localparam int SLOT_BITS = $clog2(RESPONSE_SLOTS);
  localparam int SLOT_COUNT_BITS = $clog2(RESPONSE_SLOTS + 1);
  localparam int LMEM_TAG_VALUE_W = LMEM_TAG_WIDTH_P - `UP(UUID_WIDTH);
  localparam int BEATS_D0_WIDTH = 32 + BOUND_WIDTH;
  localparam int BEATS_D01_WIDTH = BEATS_D0_WIDTH + BOUND_WIDTH;
  localparam int BEATS_D012_WIDTH = BEATS_D01_WIDTH + BOUND_WIDTH;
  localparam int ADDR_PRODUCT_WIDTH = BOUND_WIDTH + 32;

  typedef struct packed {
    logic [31:0] scheduler_work_seq;
    logic [31:0] seg_size;
    logic [MAX_DIMS-1:0][BOUND_WIDTH-1:0] bounds;
    logic [MAX_DIMS-1:0][31:0] strides;
    logic [63:0] base_addr;
  } qparam_source_meta_t;

  typedef struct packed {
    gemm_wait_meta_t writer_wait;
    logic [31:0] reg_value;
    logic [31:0] reg_idx;
    logic [31:0] seg_size;
    logic [MAX_DIMS-1:0][BOUND_WIDTH-1:0] bounds;
    logic [MAX_DIMS-1:0][31:0] strides;
    logic [63:0] base_addr;
  } qparam_dest_meta_t;

  function automatic logic [MAX_DIMS-1:0][BOUND_WIDTH-1:0]
      qparam_advance_dims(
          input logic [MAX_DIMS-1:0][BOUND_WIDTH-1:0] indices,
          input logic [MAX_DIMS-1:0][BOUND_WIDTH-1:0] bounds);
    logic carry;
    begin
      qparam_advance_dims = indices;
      carry = 1'b1;
      for (int d = 0; d < MAX_DIMS; ++d) begin
        if (carry) begin
          if ((indices[d] + BOUND_WIDTH'(1)) < bounds[d]) begin
            qparam_advance_dims[d] = indices[d] + BOUND_WIDTH'(1);
            carry = 1'b0;
          end else begin
            qparam_advance_dims[d] = '0;
          end
        end
      end
    end
  endfunction

  localparam int SOURCE_METAW = $bits(qparam_source_meta_t);
  localparam int DEST_METAW = $bits(qparam_dest_meta_t);
  localparam int DATAW = BUS_BYTES * 8;

  VX_gemm_dma_fetch_if #(
    .INSTANCE_ID   ({INSTANCE_ID, ".fetch_if"}),
    .CMD_PAYLOADW  (SOURCE_METAW + DEST_METAW),
    .REQ_PAYLOADW  (SOURCE_METAW + 32),
    .RSP_PAYLOADW  (DATAW),
    .TAGW          (LMEM_TAG_VALUE_W),
    .COUNTW        (32),
    .SLOT_COUNTW   (SLOT_COUNT_BITS),
    .SLOT_CAPACITY (RESPONSE_SLOTS)
  ) dma_fetch_if (clk, reset);

  VX_gemm_dma_sink_if #(
    .INSTANCE_ID ({INSTANCE_ID, ".sink_if"}),
    .PAYLOADW    (DEST_METAW + 32 + DATAW),
    .TAGW        (64),
    .COUNTW      (32)
  ) dma_sink_if (clk, reset);

  qparam_source_meta_t command_source_meta;
  qparam_dest_meta_t command_dest_meta;
  qparam_source_meta_t fetch_source_meta;
  qparam_dest_meta_t sink_dest_meta;
  qparam_dest_meta_t writer_dest_meta;
  wire [31:0] fetch_beat = dma_fetch_if.req_payload[31:0];
  wire [31:0] sink_beat = dma_sink_if.write_payload[DATAW +: 32];
  wire [DATAW-1:0] sink_data = dma_sink_if.write_payload[DATAW-1:0];

  wire [SOURCE_METAW+DEST_METAW-1:0] writer_head_payload;
  wire writer_head_valid;
  wire [31:0] writer_head_cmd_id;
  wire [31:0] writer_head_sequence;
  wire fetch_complete_valid;
  wire [31:0] fetch_complete_cmd_id;
  wire [31:0] fetch_complete_sequence;
  wire install_complete_valid;
  wire [31:0] install_complete_cmd_id;
  wire [31:0] install_complete_sequence;
  wire [31:0] fetch_head_write_beats;
  wire [CMD_COUNT_BITS-1:0] queue_cmd_occupancy;
  wire [SLOT_COUNT_BITS-1:0] queue_slot_occupancy;
  wire [SLOT_COUNT_BITS-1:0] queue_ready_ahead;

  assign command_source_meta.scheduler_work_seq
      = ctrl_if.scheduler_work_seq;
  assign command_source_meta.seg_size = ctrl_if.seg_size;
  assign command_dest_meta.writer_wait = writer_wait_i;
  assign command_dest_meta.reg_value = ctrl_if.reg_value;
  assign command_dest_meta.reg_idx = ctrl_if.reg_idx;
  assign command_dest_meta.seg_size = ctrl_if.seg_size;
  for (genvar meta_dim = 0; meta_dim < MAX_DIMS; ++meta_dim) begin : g_qparam_meta
    assign command_source_meta.bounds[meta_dim] = ctrl_if.bounds[meta_dim];
    assign command_source_meta.strides[meta_dim]
        = ctrl_if.src_strides[meta_dim];
    assign command_dest_meta.bounds[meta_dim] = ctrl_if.bounds[meta_dim];
    assign command_dest_meta.strides[meta_dim]
        = ctrl_if.dst_strides[meta_dim];
  end
  assign command_source_meta.base_addr = ctrl_if.src_base_addr;
  assign command_dest_meta.base_addr = ctrl_if.dst_base_addr;

  assign fetch_source_meta = dma_fetch_if.req_payload[32 +: SOURCE_METAW];
  assign sink_dest_meta = dma_sink_if.write_payload[DATAW+32 +: DEST_METAW];
  assign writer_dest_meta = writer_head_payload[DEST_METAW-1:0];

  wire [31:0] command_seg_beats = ctrl_if.seg_size / BUS_BYTES;
  wire [BEATS_D0_WIDTH-1:0] command_beats_d0
      = command_seg_beats * ctrl_if.bounds[0];
  wire [BEATS_D01_WIDTH-1:0] command_beats_d01
      = command_beats_d0 * ctrl_if.bounds[1];
  wire [BEATS_D012_WIDTH-1:0] command_beats_d012
      = command_beats_d01 * ctrl_if.bounds[2];
  logic [31:0] command_total_beats;
  logic command_total_beats_overflow;
  generate
    if (MAX_DIMS == 1) begin : g_qparam_beats_1d
      always_comb begin
        command_total_beats = 32'(command_beats_d0);
        command_total_beats_overflow = |(command_beats_d0 >> 32);
      end
    end else if (MAX_DIMS == 2) begin : g_qparam_beats_2d
      always_comb begin
        command_total_beats = 32'(command_beats_d01);
        command_total_beats_overflow = |(command_beats_d01 >> 32);
      end
    end else begin : g_qparam_beats_3d
      always_comb begin
        command_total_beats = 32'(command_beats_d012);
        command_total_beats_overflow = |(command_beats_d012 >> 32);
      end
    end
  endgenerate
  wire command_capacity = queue_cmd_occupancy
                        < CMD_COUNT_BITS'(CMD_FIFO_DEPTH);
  assign dma_fetch_if.cmd_valid = ctrl_if.start && command_capacity;
  assign dma_fetch_if.cmd_id = ctrl_if.scheduler_work_seq;
  assign dma_fetch_if.cmd_total_beats = command_total_beats;
  assign dma_fetch_if.cmd_payload = {command_source_meta, command_dest_meta};

  logic [MAX_DIMS-1:0][BOUND_WIDTH-1:0] rd_i_dim_r;
  logic [31:0] rd_seg_offset_r;
  logic [MAX_DIMS-1:0][BOUND_WIDTH-1:0] wr_i_dim_r;
  logic [31:0] wr_seg_offset_r;
  wire [ADDR_PRODUCT_WIDTH-1:0] rd_dim_stride[MAX_DIMS];
  wire [ADDR_PRODUCT_WIDTH-1:0] wr_dim_stride[MAX_DIMS];
  for (genvar addr_dim = 0; addr_dim < MAX_DIMS; ++addr_dim) begin : g_qparam_addr_product
    assign rd_dim_stride[addr_dim]
        = rd_i_dim_r[addr_dim] * fetch_source_meta.strides[addr_dim];
    assign wr_dim_stride[addr_dim]
        = wr_i_dim_r[addr_dim] * sink_dest_meta.strides[addr_dim];
  end
  logic [63:0] rd_src_byte_addr;
  logic [63:0] wr_dst_byte_addr;
  generate
    if (MAX_DIMS == 1) begin : g_qparam_addr_1d
      always_comb begin
        rd_src_byte_addr = fetch_source_meta.base_addr
            + 64'(rd_dim_stride[0]) + 64'(rd_seg_offset_r);
        wr_dst_byte_addr = sink_dest_meta.base_addr
            + 64'(wr_dim_stride[0]) + 64'(wr_seg_offset_r);
      end
    end else if (MAX_DIMS == 2) begin : g_qparam_addr_2d
      always_comb begin
        rd_src_byte_addr = fetch_source_meta.base_addr
            + 64'(rd_dim_stride[0]) + 64'(rd_dim_stride[1])
            + 64'(rd_seg_offset_r);
        wr_dst_byte_addr = sink_dest_meta.base_addr
            + 64'(wr_dim_stride[0]) + 64'(wr_dim_stride[1])
            + 64'(wr_seg_offset_r);
      end
    end else begin : g_qparam_addr_3d
      always_comb begin
        rd_src_byte_addr = fetch_source_meta.base_addr
            + 64'(rd_dim_stride[0]) + 64'(rd_dim_stride[1])
            + 64'(rd_dim_stride[2]) + 64'(rd_seg_offset_r);
        wr_dst_byte_addr = sink_dest_meta.base_addr
            + 64'(wr_dim_stride[0]) + 64'(wr_dim_stride[1])
            + 64'(wr_dim_stride[2]) + 64'(wr_seg_offset_r);
      end
    end
  endgenerate

  wire writer_wait_rid_is0 = writer_dest_meta.writer_wait.reg_id
      == GEMM_SYNC_REG_ID_WIDTH'(WRITER_RID0);
  wire writer_wait_rid_is1 = writer_dest_meta.writer_wait.reg_id
      == GEMM_SYNC_REG_ID_WIDTH'(WRITER_RID1);
  wire writer_wait_rid_valid = writer_wait_rid_is0 || writer_wait_rid_is1;
  wire [31:0] writer_consume_value = writer_wait_rid_is1
      ? writer_consume_value1_i : writer_consume_value0_i;
  wire writer_released = writer_head_valid
      && (!writer_dest_meta.writer_wait.valid
       || (writer_wait_rid_valid
        && (writer_consume_value >= writer_dest_meta.writer_wait.target)));

  logic source_priority_hold_valid_r;
  logic [GEMM_SCHED_PRIORITY_WIDTH-1:0] source_priority_hold_r;
  assign lmem_req_priority_o = source_priority_hold_valid_r
      ? source_priority_hold_r : sched_priority_i;

  assign lmem_bus_if.req_valid = dma_fetch_if.req_valid;
  assign dma_fetch_if.req_ready = lmem_bus_if.req_ready;
  assign lmem_bus_if.req_data.rw = 1'b0;
  assign lmem_bus_if.req_data.addr
      = LMEM_ADDR_WIDTH_P'(rd_src_byte_addr >> BUS_ADDR_BITS);
  assign lmem_bus_if.req_data.data = '0;
  assign lmem_bus_if.req_data.byteen = '1;
  assign lmem_bus_if.req_data.flags = '0;
  assign lmem_bus_if.req_data.tag.uuid = '0;
  assign lmem_bus_if.req_data.tag.value = dma_fetch_if.req_tag;
  assign dma_fetch_if.rsp_valid = lmem_bus_if.rsp_valid;
  assign dma_fetch_if.rsp_tag = lmem_bus_if.rsp_data.tag.value;
  assign dma_fetch_if.rsp_payload = lmem_bus_if.rsp_data.data;
  assign lmem_bus_if.rsp_ready = dma_fetch_if.rsp_ready;

  assign gemm_bus_if.req_valid = dma_sink_if.write_valid;
  assign dma_sink_if.write_ready = gemm_bus_if.req_ready;
  assign gemm_bus_if.req_data.rw = 1'b1;
  assign gemm_bus_if.req_data.addr
      = GEMM_ADDR_WIDTH_P'(wr_dst_byte_addr >> BUS_ADDR_BITS);
  assign gemm_bus_if.req_data.data = sink_data;
  assign gemm_bus_if.req_data.byteen = '1;
  assign gemm_bus_if.req_data.flags = '0;
  assign gemm_bus_if.req_data.tag.uuid = '0;
  assign gemm_bus_if.req_data.tag.value = '0;
  assign gemm_bus_if.rsp_ready = 1'b1;

  VX_gemm_stream_dma_queue #(
    .INSTANCE_ID     ({INSTANCE_ID, ".stream_queue"}),
    .CMD_FIFO_DEPTH  (CMD_FIFO_DEPTH),
    .RESPONSE_SLOTS  (RESPONSE_SLOTS),
    .SOURCE_METAW    (SOURCE_METAW),
    .DEST_METAW      (DEST_METAW),
    .DATAW           (DATAW),
    .COUNTW          (32),
    .SEQW            (32),
    .FETCH_TAGW      (LMEM_TAG_VALUE_W),
    .RING_SLOT_ORDER (1'b1),
    .SINK_PIPELINE   (1'b1),
    .RESPONSE_DATA_RAM (RESPONSE_DATA_RAM)
  ) u_stream_queue (
    .clk(clk),
    .reset(reset),
    .writer_release_i(writer_released),
    .fetch_if(dma_fetch_if),
    .sink_if(dma_sink_if),
    .writer_head_valid_o(writer_head_valid),
    .writer_head_cmd_id_o(writer_head_cmd_id),
    .writer_head_cmd_payload_o(writer_head_payload),
    .writer_head_sequence_o(writer_head_sequence),
    .fetch_complete_valid_o(fetch_complete_valid),
    .fetch_complete_cmd_id_o(fetch_complete_cmd_id),
    .fetch_complete_sequence_o(fetch_complete_sequence),
    .install_complete_valid_o(install_complete_valid),
    .install_complete_cmd_id_o(install_complete_cmd_id),
    .install_complete_sequence_o(install_complete_sequence),
    .fetch_head_write_beats_o(fetch_head_write_beats),
    .install_ready_ahead_o(queue_ready_ahead),
    .cmd_occupancy_o(queue_cmd_occupancy),
    .slot_occupancy_o(queue_slot_occupancy)
  );

  wire source_req_fire = dma_fetch_if.req_valid && dma_fetch_if.req_ready;
  wire destination_write_fire = dma_sink_if.write_valid
                              && dma_sink_if.write_ready;

  assign ctrl_if.idle = command_capacity;
  assign ctrl_if.prepare_ready = 1'b0;
  assign ctrl_if.write_done = install_complete_valid;
  assign ctrl_if.done = install_complete_valid;
  assign gemm_sync_if.valid = 1'b0;
  assign gemm_sync_if.reg_idx = writer_head_valid
                              ? writer_dest_meta.reg_idx : '0;
  assign gemm_sync_if.value = writer_head_valid
                            ? writer_dest_meta.reg_value : '0;

  assign sched_source_valid_o = dma_fetch_if.progress_valid;
  assign sched_source_work_seq_o = dma_fetch_if.progress_valid
      ? fetch_source_meta.scheduler_work_seq : '0;
  assign sched_source_total_beats_o = dma_fetch_if.progress_valid
      ? dma_fetch_if.progress_total_beats : '0;
  assign sched_source_request_beats_o = dma_fetch_if.progress_valid
      ? dma_fetch_if.progress_request_beats : '0;
  assign sched_source_response_beats_o = dma_fetch_if.progress_valid
      ? dma_fetch_if.progress_response_beats : '0;
  assign sched_source_writer_beats_o = dma_fetch_if.progress_valid
      ? fetch_head_write_beats : '0;
  assign sched_slot_occupancy_o = queue_slot_occupancy;
  assign sched_fetch_complete_o = fetch_complete_valid;
  assign sched_fetch_complete_work_seq_o = fetch_complete_cmd_id;

  // Preserve the established qparam focused/debug hierarchy while making the
  // common queue the only descriptor/slot/install owner.
  wire [CMD_FIFO_DEPTH-1:0] cmd_valid_r = u_stream_queue.cmd_valid_r;
  wire [31:0] cmd_total_beats_r[CMD_FIFO_DEPTH];
  wire [31:0] cmd_wr_count_r[CMD_FIFO_DEPTH];
  for (genvar dbg_cmd = 0; dbg_cmd < CMD_FIFO_DEPTH; ++dbg_cmd) begin : g_qparam_dbg
    assign cmd_total_beats_r[dbg_cmd] = u_stream_queue.cmd_total_r[dbg_cmd];
    assign cmd_wr_count_r[dbg_cmd] = u_stream_queue.cmd_write_r[dbg_cmd];
  end
  wire [CMD_COUNT_BITS-1:0] cmd_count_r = queue_cmd_occupancy;
  wire [SLOT_COUNT_BITS-1:0] slot_occupancy_r = queue_slot_occupancy;
  // Stable focused/elaboration contract for the qparam shared-queue mode.
  // Keep testbench checks at this adapter boundary rather than reaching into
  // child parameters whose representation is simulator-dependent.
  wire dbg_overlap_shared_queue_bound = 1'b1;
  wire [31:0] dbg_overlap_fetch_tag_width = 32'(LMEM_TAG_VALUE_W);
  wire dbg_overlap_ring_slot_order = 1'b1;
  wire dbg_overlap_sink_pipeline = 1'b1;
  wire [31:0] dbg_overlap_writer_sequence = writer_head_sequence;
  wire [31:0] dbg_overlap_writer_total_beats
      = dma_sink_if.progress_total_beats;
  wire [31:0] dbg_overlap_writer_write_count
      = dma_sink_if.progress_write_beats;
  always_ff @(posedge clk) begin
    if (reset) begin
      rd_i_dim_r <= '{default:'0};
      rd_seg_offset_r <= '0;
      wr_i_dim_r <= '{default:'0};
      wr_seg_offset_r <= '0;
      source_priority_hold_valid_r <= 1'b0;
      source_priority_hold_r <= '0;
    end else begin
      if (source_req_fire) begin
        source_priority_hold_valid_r <= 1'b0;
      end else if (lmem_bus_if.req_valid && !source_priority_hold_valid_r) begin
        source_priority_hold_valid_r <= 1'b1;
        source_priority_hold_r <= sched_priority_i;
      end

      if (source_req_fire) begin
        if ((fetch_beat + 32'd1) == dma_fetch_if.progress_total_beats) begin
          rd_i_dim_r <= '{default:'0};
          rd_seg_offset_r <= '0;
        end else if ((rd_seg_offset_r + 32'(BUS_BYTES))
                     >= fetch_source_meta.seg_size) begin
          rd_seg_offset_r <= '0;
          rd_i_dim_r <= qparam_advance_dims(
              rd_i_dim_r, fetch_source_meta.bounds);
        end else begin
          rd_seg_offset_r <= rd_seg_offset_r + 32'(BUS_BYTES);
        end
      end

      if (destination_write_fire) begin
        if (dma_sink_if.install_complete) begin
          wr_i_dim_r <= '{default:'0};
          wr_seg_offset_r <= '0;
        end else if ((wr_seg_offset_r + 32'(BUS_BYTES))
                     >= sink_dest_meta.seg_size) begin
          wr_seg_offset_r <= '0;
          wr_i_dim_r <= qparam_advance_dims(
              wr_i_dim_r, sink_dest_meta.bounds);
        end else begin
          wr_seg_offset_r <= wr_seg_offset_r + 32'(BUS_BYTES);
        end
      end
    end
  end

  initial begin
    if (NDIM != 3)
      $fatal(1, "%s: qparam queue requires NDIM=3", INSTANCE_ID);
    if ((MAX_DIMS < 1) || (MAX_DIMS > NDIM))
      $fatal(1, "%s: qparam MAX_DIMS(%0d) must be in 1..%0d",
             INSTANCE_ID, MAX_DIMS, NDIM);
    if (BOUND_WIDTH != ctrl_if.BOUND_WIDTH)
      $fatal(1, "%s: qparam bound width mismatch", INSTANCE_ID);
    if ((CMD_FIFO_DEPTH != 2) && (CMD_FIFO_DEPTH != 4))
      $fatal(1, "%s: qparam queue depth must be 2 or 4", INSTANCE_ID);
    if ((RESPONSE_SLOTS < 1)
     || ((RESPONSE_SLOTS & (RESPONSE_SLOTS - 1)) != 0))
      $fatal(1, "%s: qparam queue slots must be a positive power of two",
             INSTANCE_ID);
    if (BUS_BYTES != gemm_bus_if.DATA_SIZE)
      $fatal(1, "%s: qparam source/destination widths differ", INSTANCE_ID);
    if ((LMEM_ADDR_WIDTH_P != lmem_bus_if.ADDR_WIDTH)
     || (GEMM_ADDR_WIDTH_P != gemm_bus_if.ADDR_WIDTH)
     || (LMEM_TAG_WIDTH_P != lmem_bus_if.TAG_WIDTH)
     || (GEMM_TAG_WIDTH_P != gemm_bus_if.TAG_WIDTH)
     || (LMEM_TAG_VALUE_W < SLOT_BITS))
      $fatal(1, "%s: qparam bus/tag width mismatch", INSTANCE_ID);
  end

`ifndef SYNTHESIS
  `UNUSED_VAR (sink_beat)
  `UNUSED_VAR (writer_head_cmd_id)
  `UNUSED_VAR (fetch_complete_sequence)
  `UNUSED_VAR (install_complete_cmd_id)
  `UNUSED_VAR (install_complete_sequence)
  `UNUSED_VAR (queue_ready_ahead)

  logic source_stall_r;
  logic [LMEM_ADDR_WIDTH_P-1:0] source_stall_addr_r;
  logic [GEMM_SCHED_PRIORITY_WIDTH-1:0] source_stall_priority_r;
  logic destination_stall_r;
  logic [GEMM_ADDR_WIDTH_P-1:0] destination_stall_addr_r;
  logic [DATAW-1:0] destination_stall_data_r;
  always_ff @(posedge clk) begin
    if (reset) begin
      source_stall_r <= 1'b0;
      source_stall_addr_r <= '0;
      source_stall_priority_r <= '0;
      destination_stall_r <= 1'b0;
      destination_stall_addr_r <= '0;
      destination_stall_data_r <= '0;
    end else begin
      assert (!(ctrl_if.start && !ctrl_if.idle))
        else $fatal(1, "%s: qparam command presented while FIFO full",
                    INSTANCE_ID);
      if (ctrl_if.start && ctrl_if.idle) begin
        assert (!command_total_beats_overflow
             && (ctrl_if.bounds[0] != 0)
             && (ctrl_if.bounds[1] != 0)
             && (ctrl_if.bounds[2] != 0)
             && (ctrl_if.seg_size != 0)
             && ((ctrl_if.seg_size % BUS_BYTES) == 0)
             && (!writer_wait_i.valid
              || ((((writer_wait_i.reg_id
                       == GEMM_SYNC_REG_ID_WIDTH'(WRITER_RID0))
                    && !ctrl_if.dst_base_addr[BUS_ADDR_BITS])
                || ((writer_wait_i.reg_id
                       == GEMM_SYNC_REG_ID_WIDTH'(WRITER_RID1))
                    && ctrl_if.dst_base_addr[BUS_ADDR_BITS]))
               && (writer_wait_i.target != 0))))
          else $fatal(1, "%s: unsupported qparam descriptor/fence", INSTANCE_ID);
        if (MAX_DIMS == 1) begin
          assert ((ctrl_if.bounds[1] == BOUND_WIDTH'(1))
               && (ctrl_if.bounds[2] == BOUND_WIDTH'(1)))
            else $fatal(1, "%s: 1D qparam requires BND1/BND2=1", INSTANCE_ID);
        end else if (MAX_DIMS == 2) begin
          assert (ctrl_if.bounds[2] == BOUND_WIDTH'(1))
            else $fatal(1, "%s: 2D qparam requires BND2=1", INSTANCE_ID);
        end
      end
      if (source_stall_r) begin
        assert (lmem_bus_if.req_valid
             && (lmem_bus_if.req_data.addr == source_stall_addr_r)
             && (lmem_req_priority_o == source_stall_priority_r))
          else $fatal(1, "%s: qparam source changed under backpressure",
                      INSTANCE_ID);
      end
      if (destination_stall_r) begin
        assert (gemm_bus_if.req_valid
             && (gemm_bus_if.req_data.addr == destination_stall_addr_r)
             && (gemm_bus_if.req_data.data == destination_stall_data_r))
          else $fatal(1, "%s: qparam destination changed under backpressure",
                      INSTANCE_ID);
      end
      if (writer_head_valid && writer_dest_meta.writer_wait.valid)
        assert (writer_wait_rid_valid)
          else $fatal(1, "%s: qparam writer RID has no Scale/ZP owner",
                      INSTANCE_ID);
      source_stall_r <= lmem_bus_if.req_valid && !lmem_bus_if.req_ready;
      source_stall_addr_r <= lmem_bus_if.req_data.addr;
      source_stall_priority_r <= lmem_req_priority_o;
      destination_stall_r <= gemm_bus_if.req_valid && !gemm_bus_if.req_ready;
      destination_stall_addr_r <= gemm_bus_if.req_data.addr;
      destination_stall_data_r <= gemm_bus_if.req_data.data;
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
      if (dma_fetch_if.rsp_valid && dma_fetch_if.rsp_ready)
        perf_rd_bytes_r <= perf_rd_bytes_r + PERF_CTR_BITS'(BUS_BYTES);
      if (destination_write_fire)
        perf_wr_bytes_r <= perf_wr_bytes_r + PERF_CTR_BITS'(BUS_BYTES);
      if (install_complete_valid)
        perf_xfers_r <= perf_xfers_r + PERF_CTR_BITS'(1);
      if (queue_cmd_occupancy != 0)
        perf_active_r <= perf_active_r + PERF_CTR_BITS'(1);
      if (source_req_fire)
        perf_src_req_fire_r <= perf_src_req_fire_r + PERF_CTR_BITS'(1);
      if (lmem_bus_if.req_valid && !lmem_bus_if.req_ready)
        perf_src_req_stall_r <= perf_src_req_stall_r + PERF_CTR_BITS'(1);
      if (dma_fetch_if.rsp_valid && dma_fetch_if.rsp_ready)
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
  assign perf.busy = (queue_cmd_occupancy != 0);
`endif

endmodule

module VX_lmem_dma_qparam_overlap import VX_gpu_pkg::*; #(
  parameter `STRING INSTANCE_ID = "",
  parameter int NDIM = 3,
  parameter int BOUND_WIDTH = `DMA_BOUND_WIDTH,
  parameter int MAX_DIMS = NDIM,
  parameter int TAG_WIDTH = 1,
  parameter int CMD_FIFO_DEPTH = 4,
  parameter int RESPONSE_SLOTS = 8,
  parameter bit RESPONSE_DATA_RAM = 1'b1,
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

  VX_lmem_dma_qparam_queue #(
    .INSTANCE_ID          (INSTANCE_ID),
    .NDIM                 (NDIM),
    .BOUND_WIDTH          (BOUND_WIDTH),
    .MAX_DIMS             (MAX_DIMS),
    .TAG_WIDTH            (TAG_WIDTH),
    .CMD_FIFO_DEPTH       (CMD_FIFO_DEPTH),
    .RESPONSE_SLOTS       (RESPONSE_SLOTS),
    .RESPONSE_DATA_RAM    (RESPONSE_DATA_RAM),
    .WRITER_RID0          (WRITER_RID0),
    .WRITER_RID1          (WRITER_RID1),
    .LMEM_ADDR_WIDTH_P    (LMEM_ADDR_WIDTH_P),
    .GEMM_ADDR_WIDTH_P    (GEMM_ADDR_WIDTH_P),
    .LMEM_TAG_WIDTH_P     (LMEM_TAG_WIDTH_P),
    .GEMM_TAG_WIDTH_P     (GEMM_TAG_WIDTH_P)
  ) u_overlap (
    .clk                    (clk),
    .reset                  (reset),
    .sched_priority_i       (sched_priority_i),
    .ctrl_if                (ctrl_if),
    .writer_wait_i          (writer_wait_i),
    .writer_consume_value0_i(writer_consume_value0_i),
    .writer_consume_value1_i(writer_consume_value1_i),
    .gemm_sync_if           (gemm_sync_if),
    .lmem_bus_if            (lmem_bus_if),
    .gemm_bus_if            (gemm_bus_if),
    .lmem_req_priority_o    (lmem_req_priority_o),
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
// VX_lmem_dma_weight_overlap
//  IMPROVE Weight adapter around the common logical-beat stream DMA queue.
//  The upstream bus is already GEMM_WEIGHT_DATA_SIZE wide: the external
//  VX_tmem_wide_read_switch remains the sole owner of narrow-bank request and
//  response-fragment assembly and returns one completed logical beat here.
//==============================================================================

module VX_lmem_dma_weight_overlap import VX_gpu_pkg::*; #(
  parameter `STRING INSTANCE_ID = "",
  parameter int NDIM = 3,
  parameter int BOUND_WIDTH = `DMA_BOUND_WIDTH,
  parameter int MAX_DIMS = NDIM,
  parameter int TAG_WIDTH = 1,
  parameter int CMD_FIFO_DEPTH = 4,
  parameter int CMD_BEATS = `W_LMEM_DMA_CMD_BEATS,
  parameter int RESPONSE_SLOTS = `W_LMEM_DMA_RESPONSE_SLOTS,
  parameter bit RESPONSE_DATA_RAM = 1'b1,
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
  localparam int DATAW = BUS_BYTES * 8;
  localparam int BEATS_D0_WIDTH = 32 + BOUND_WIDTH;
  localparam int BEATS_D01_WIDTH = BEATS_D0_WIDTH + BOUND_WIDTH;
  localparam int BEATS_D012_WIDTH = BEATS_D01_WIDTH + BOUND_WIDTH;
  localparam int ADDR_PRODUCT_WIDTH = BOUND_WIDTH + 32;

  typedef struct packed {
    logic [31:0] scheduler_work_seq;
    logic [31:0] seg_size;
    logic [MAX_DIMS-1:0][BOUND_WIDTH-1:0] bounds;
    logic [MAX_DIMS-1:0][31:0] strides;
    logic [63:0] base_addr;
  } weight_source_meta_t;

  typedef struct packed {
    gemm_wait_meta_t writer_wait;
    logic [31:0] reg_value;
    logic [31:0] reg_idx;
    logic [63:0] base_addr;
  } weight_dest_meta_t;

  function automatic logic [MAX_DIMS-1:0][BOUND_WIDTH-1:0]
      weight_advance_dims(
          input logic [MAX_DIMS-1:0][BOUND_WIDTH-1:0] indices,
          input logic [MAX_DIMS-1:0][BOUND_WIDTH-1:0] bounds);
    logic carry;
    begin
      weight_advance_dims = indices;
      carry = 1'b1;
      for (int d = 0; d < MAX_DIMS; ++d) begin
        if (carry) begin
          if ((indices[d] + BOUND_WIDTH'(1)) < bounds[d]) begin
            weight_advance_dims[d] = indices[d] + BOUND_WIDTH'(1);
            carry = 1'b0;
          end else begin
            weight_advance_dims[d] = '0;
          end
        end
      end
    end
  endfunction

  localparam int SOURCE_METAW = $bits(weight_source_meta_t);
  localparam int DEST_METAW = $bits(weight_dest_meta_t);

  VX_gemm_dma_fetch_if #(
    .INSTANCE_ID   ({INSTANCE_ID, ".fetch_if"}),
    .CMD_PAYLOADW  (SOURCE_METAW + DEST_METAW),
    .REQ_PAYLOADW  (SOURCE_METAW + 32),
    .RSP_PAYLOADW  (DATAW),
    .TAGW          (LMEM_TAG_VALUE_W),
    .COUNTW        (32),
    .SLOT_COUNTW   (SLOT_COUNT_BITS),
    .SLOT_CAPACITY (RESPONSE_SLOTS)
  ) dma_fetch_if (clk, reset);

  VX_gemm_dma_sink_if #(
    .INSTANCE_ID ({INSTANCE_ID, ".sink_if"}),
    .PAYLOADW    (DEST_METAW + 32 + DATAW),
    .TAGW        (64),
    .COUNTW      (32)
  ) dma_sink_if (clk, reset);

  weight_source_meta_t command_source_meta;
  weight_dest_meta_t command_dest_meta;
  weight_source_meta_t fetch_source_meta;
  weight_dest_meta_t sink_dest_meta;
  weight_dest_meta_t writer_dest_meta;
  wire [31:0] fetch_beat = dma_fetch_if.req_payload[31:0];
  wire [31:0] sink_beat = dma_sink_if.write_payload[DATAW +: 32];
  wire [DATAW-1:0] sink_data = dma_sink_if.write_payload[DATAW-1:0];

  wire [SOURCE_METAW+DEST_METAW-1:0] writer_head_payload;
  wire writer_head_valid;
  wire [31:0] writer_head_cmd_id;
  wire [31:0] writer_head_sequence;
  wire fetch_complete_valid;
  wire [31:0] fetch_complete_cmd_id;
  wire [31:0] fetch_complete_sequence;
  wire install_complete_valid;
  wire [31:0] install_complete_cmd_id;
  wire [31:0] install_complete_sequence;
  wire [31:0] fetch_head_write_beats;
  wire [CMD_COUNT_BITS-1:0] queue_cmd_occupancy;
  wire [SLOT_COUNT_BITS-1:0] queue_slot_occupancy;
  wire [SLOT_COUNT_BITS-1:0] queue_ready_ahead;

  assign command_source_meta.scheduler_work_seq
      = ctrl_if.scheduler_work_seq;
  assign command_source_meta.seg_size = ctrl_if.seg_size;
  assign command_dest_meta.writer_wait = writer_wait_i;
  assign command_dest_meta.reg_value = ctrl_if.reg_value;
  assign command_dest_meta.reg_idx = ctrl_if.reg_idx;
  for (genvar meta_dim = 0; meta_dim < MAX_DIMS; ++meta_dim) begin : g_weight_meta
    assign command_source_meta.bounds[meta_dim] = ctrl_if.bounds[meta_dim];
    assign command_source_meta.strides[meta_dim]
        = ctrl_if.src_strides[meta_dim];
  end
  assign command_source_meta.base_addr = ctrl_if.src_base_addr;
  assign command_dest_meta.base_addr = ctrl_if.dst_base_addr;

  assign fetch_source_meta = dma_fetch_if.req_payload[32 +: SOURCE_METAW];
  assign sink_dest_meta = dma_sink_if.write_payload[DATAW+32 +: DEST_METAW];
  assign writer_dest_meta = writer_head_payload[DEST_METAW-1:0];

  wire [31:0] command_seg_beats = ctrl_if.seg_size / BUS_BYTES;
  wire [BEATS_D0_WIDTH-1:0] command_beats_d0
      = command_seg_beats * ctrl_if.bounds[0];
  wire [BEATS_D01_WIDTH-1:0] command_beats_d01
      = command_beats_d0 * ctrl_if.bounds[1];
  wire [BEATS_D012_WIDTH-1:0] command_beats_d012
      = command_beats_d01 * ctrl_if.bounds[2];
  logic [31:0] command_total_beats;
  logic command_total_beats_overflow;
  generate
    if (MAX_DIMS == 1) begin : g_weight_beats_1d
      always_comb begin
        command_total_beats = 32'(command_beats_d0);
        command_total_beats_overflow = |(command_beats_d0 >> 32);
      end
    end else if (MAX_DIMS == 2) begin : g_weight_beats_2d
      always_comb begin
        command_total_beats = 32'(command_beats_d01);
        command_total_beats_overflow = |(command_beats_d01 >> 32);
      end
    end else begin : g_weight_beats_3d
      always_comb begin
        command_total_beats = 32'(command_beats_d012);
        command_total_beats_overflow = |(command_beats_d012 >> 32);
      end
    end
  endgenerate
  assign dma_fetch_if.cmd_valid = ctrl_if.start;
  assign dma_fetch_if.cmd_id = ctrl_if.scheduler_work_seq;
  assign dma_fetch_if.cmd_total_beats = command_total_beats;
  assign dma_fetch_if.cmd_payload = {command_source_meta, command_dest_meta};

  logic [MAX_DIMS-1:0][BOUND_WIDTH-1:0] rd_i_dim_r;
  logic [31:0] rd_seg_offset_r;
  wire [ADDR_PRODUCT_WIDTH-1:0] rd_dim_stride[MAX_DIMS];
  for (genvar addr_dim = 0; addr_dim < MAX_DIMS; ++addr_dim) begin : g_weight_addr_product
    assign rd_dim_stride[addr_dim]
        = rd_i_dim_r[addr_dim] * fetch_source_meta.strides[addr_dim];
  end
  logic [63:0] rd_src_byte_addr;
  generate
    if (MAX_DIMS == 1) begin : g_weight_addr_1d
      always_comb rd_src_byte_addr = fetch_source_meta.base_addr
          + 64'(rd_dim_stride[0]) + 64'(rd_seg_offset_r);
    end else if (MAX_DIMS == 2) begin : g_weight_addr_2d
      always_comb rd_src_byte_addr = fetch_source_meta.base_addr
          + 64'(rd_dim_stride[0]) + 64'(rd_dim_stride[1])
          + 64'(rd_seg_offset_r);
    end else begin : g_weight_addr_3d
      always_comb rd_src_byte_addr = fetch_source_meta.base_addr
          + 64'(rd_dim_stride[0]) + 64'(rd_dim_stride[1])
          + 64'(rd_dim_stride[2]) + 64'(rd_seg_offset_r);
    end
  endgenerate

  wire writer_wait_rid_is_w0 = writer_dest_meta.writer_wait.reg_id
      == GEMM_SYNC_REG_ID_WIDTH'(GEMM_RID_W_CONSUME0);
  wire writer_wait_rid_is_w1 = writer_dest_meta.writer_wait.reg_id
      == GEMM_SYNC_REG_ID_WIDTH'(GEMM_RID_W_CONSUME1);
  wire writer_wait_rid_valid = writer_wait_rid_is_w0
                            || writer_wait_rid_is_w1;
  wire [31:0] writer_consume_value = writer_wait_rid_is_w1
      ? weight_consume_value1_i : weight_consume_value0_i;
  wire writer_released = writer_head_valid
      && (!writer_dest_meta.writer_wait.valid
       || (writer_wait_rid_valid
        && (writer_consume_value >= writer_dest_meta.writer_wait.target)));

  logic source_urgent_hold_valid_r;
  logic source_urgent_hold_r;
  logic [GEMM_SCHED_PRIORITY_WIDTH-1:0] source_priority_hold_r;
  wire source_urgent_now = writer_released
      && (queue_ready_ahead
          < SLOT_COUNT_BITS'(READY_AHEAD_LOW_WATERMARK));
  assign lmem_req_priority_o = source_urgent_hold_valid_r
      ? source_priority_hold_r : sched_priority_i;
  // A tracked scheduler P0 remains background.  Untracked work keeps the
  // established local ready-ahead urgency fallback.
  assign lmem_req_urgent_o = ENABLE_TMEM_URGENCY
      && (source_urgent_hold_valid_r ? source_urgent_hold_r
                                     : source_urgent_now)
      && ((fetch_source_meta.scheduler_work_seq == 0)
       || (lmem_req_priority_o != GEMM_SCHED_PRIORITY_BACKGROUND));

  assign lmem_bus_if.req_valid = dma_fetch_if.req_valid;
  assign dma_fetch_if.req_ready = lmem_bus_if.req_ready;
  assign lmem_bus_if.req_data.rw = 1'b0;
  assign lmem_bus_if.req_data.addr
      = LMEM_ADDR_WIDTH_P'(rd_src_byte_addr >> BUS_ADDR_BITS);
  assign lmem_bus_if.req_data.data = '0;
  assign lmem_bus_if.req_data.byteen = '1;
  assign lmem_bus_if.req_data.flags = '0;
  assign lmem_bus_if.req_data.tag.uuid = '0;
  assign lmem_bus_if.req_data.tag.value = dma_fetch_if.req_tag;

  // This interface is connected outside the module to
  // VX_tmem_wide_read_switch.bus_in_if.  rsp_valid therefore denotes one
  // completed logical Weight beat, never either 64-byte bank fragment.
  assign dma_fetch_if.rsp_valid = lmem_bus_if.rsp_valid;
  assign dma_fetch_if.rsp_tag = lmem_bus_if.rsp_data.tag.value;
  assign dma_fetch_if.rsp_payload = lmem_bus_if.rsp_data.data;
  assign lmem_bus_if.rsp_ready = dma_fetch_if.rsp_ready;

  assign gemm_bus_if.req_valid = dma_sink_if.write_valid;
  assign dma_sink_if.write_ready = gemm_bus_if.req_ready;
  assign gemm_bus_if.req_data.rw = 1'b1;
  assign gemm_bus_if.req_data.addr = GEMM_ADDR_WIDTH_P'(
      sink_dest_meta.base_addr >> BUS_ADDR_BITS);
  assign gemm_bus_if.req_data.data = sink_data;
  assign gemm_bus_if.req_data.byteen = '1;
  assign gemm_bus_if.req_data.flags = '0;
  assign gemm_bus_if.req_data.tag.uuid = '0;
  assign gemm_bus_if.req_data.tag.value = '0;
  assign gemm_bus_if.rsp_ready = 1'b1;

  VX_gemm_stream_dma_queue #(
    .INSTANCE_ID     ({INSTANCE_ID, ".stream_queue"}),
    .CMD_FIFO_DEPTH  (CMD_FIFO_DEPTH),
    .RESPONSE_SLOTS  (RESPONSE_SLOTS),
    .SOURCE_METAW    (SOURCE_METAW),
    .DEST_METAW      (DEST_METAW),
    .DATAW           (DATAW),
    .COUNTW          (32),
    .SEQW            (32),
    .FETCH_TAGW      (LMEM_TAG_VALUE_W),
    .RING_SLOT_ORDER (1'b1),
    .SINK_PIPELINE   (1'b1),
    .RESPONSE_DATA_RAM (RESPONSE_DATA_RAM),
    .SAME_CYCLE_SLOT_RECYCLE (1'b0)
  ) u_stream_queue (
    .clk(clk),
    .reset(reset),
    .writer_release_i(writer_released),
    .fetch_if(dma_fetch_if),
    .sink_if(dma_sink_if),
    .writer_head_valid_o(writer_head_valid),
    .writer_head_cmd_id_o(writer_head_cmd_id),
    .writer_head_cmd_payload_o(writer_head_payload),
    .writer_head_sequence_o(writer_head_sequence),
    .fetch_complete_valid_o(fetch_complete_valid),
    .fetch_complete_cmd_id_o(fetch_complete_cmd_id),
    .fetch_complete_sequence_o(fetch_complete_sequence),
    .install_complete_valid_o(install_complete_valid),
    .install_complete_cmd_id_o(install_complete_cmd_id),
    .install_complete_sequence_o(install_complete_sequence),
    .fetch_head_write_beats_o(fetch_head_write_beats),
    .install_ready_ahead_o(queue_ready_ahead),
    .cmd_occupancy_o(queue_cmd_occupancy),
    .slot_occupancy_o(queue_slot_occupancy)
  );

  wire source_req_fire = dma_fetch_if.req_valid && dma_fetch_if.req_ready;
  wire source_rsp_fire = dma_fetch_if.rsp_valid && dma_fetch_if.rsp_ready;
  wire destination_write_fire = dma_sink_if.write_valid
                              && dma_sink_if.write_ready;
  wire destination_last_write = install_complete_valid;
  wire command_enqueue = dma_fetch_if.cmd_valid && dma_fetch_if.cmd_ready
                       && (dma_fetch_if.cmd_total_beats != 0);

  // Weight descriptors are statically nonzero (CMD_BEATS logical beats), so
  // expose only registered queue capacity plus the ordered install pop.  Do
  // not feed the generic queue's zero-size cmd_ready term back into the GEMM
  // controller: that term depends on the live descriptor bounds and would
  // create a combinational controller/descriptor-ready loop.
  wire command_capacity = (queue_cmd_occupancy < CMD_COUNT_BITS'(CMD_FIFO_DEPTH))
                       || install_complete_valid;
  assign ctrl_if.idle = command_capacity;
  assign ctrl_if.prepare_ready = 1'b0;
  assign ctrl_if.write_done = install_complete_valid;
  assign ctrl_if.done = install_complete_valid;
  assign gemm_sync_if.valid = 1'b0;
  assign gemm_sync_if.reg_idx = writer_head_valid
                              ? writer_dest_meta.reg_idx : '0;
  assign gemm_sync_if.value = writer_head_valid
                            ? writer_dest_meta.reg_value : '0;

  assign ready_ahead_o = queue_ready_ahead;
  assign sched_source_valid_o = dma_fetch_if.progress_valid;
  assign sched_source_work_seq_o = dma_fetch_if.progress_valid
      ? fetch_source_meta.scheduler_work_seq : '0;
  assign sched_source_total_beats_o = dma_fetch_if.progress_valid
      ? dma_fetch_if.progress_total_beats : '0;
  assign sched_source_request_beats_o = dma_fetch_if.progress_valid
      ? dma_fetch_if.progress_request_beats : '0;
  assign sched_source_response_beats_o = dma_fetch_if.progress_valid
      ? dma_fetch_if.progress_response_beats : '0;
  assign sched_source_writer_beats_o = dma_fetch_if.progress_valid
      ? fetch_head_write_beats : '0;
  assign sched_slot_occupancy_o = queue_slot_occupancy;
  assign sched_fetch_complete_o = fetch_complete_valid;
  assign sched_fetch_complete_work_seq_o = fetch_complete_cmd_id;

  // Preserve the established focused/debug hierarchy at the adapter boundary.
  wire [CMD_FIFO_DEPTH-1:0] cmd_valid_r = u_stream_queue.cmd_valid_r;
  wire [CMD_FIFO_DEPTH-1:0] cmd_rd_done_r
      = u_stream_queue.cmd_fetch_done_r;
  wire [CMD_PTR_BITS-1:0] rd_cmd_ptr_r = u_stream_queue.fetch_ptr_r;
  wire [CMD_PTR_BITS-1:0] wr_cmd_ptr_r = u_stream_queue.install_ptr_r;
  wire [CMD_PTR_BITS-1:0] cmd_tail_ptr_r = u_stream_queue.tail_ptr_r;
  wire [CMD_COUNT_BITS-1:0] cmd_count_r = queue_cmd_occupancy;
  wire [SLOT_COUNT_BITS-1:0] slot_occupancy_r = queue_slot_occupancy;
  wire drain_valid_r = u_stream_queue.drain_stage_valid_r;
  wire [SLOT_BITS-1:0] drain_slot_r
      = u_stream_queue.drain_stage_slot_r;
  wire [31:0] next_cmd_sequence_r = u_stream_queue.next_sequence_r;
  wire dbg_overlap_shared_queue_bound = 1'b1;
  wire [31:0] dbg_overlap_fetch_tag_width = 32'(LMEM_TAG_VALUE_W);
  wire [31:0] dbg_overlap_logical_beat_bytes = 32'(BUS_BYTES);
  wire dbg_overlap_ring_slot_order = 1'b1;
  wire dbg_overlap_sink_pipeline = 1'b1;
  wire dbg_overlap_same_cycle_slot_recycle = 1'b0;

  always_ff @(posedge clk) begin
    if (reset) begin
      rd_i_dim_r <= '{default:'0};
      rd_seg_offset_r <= '0;
      source_urgent_hold_valid_r <= 1'b0;
      source_urgent_hold_r <= 1'b0;
      source_priority_hold_r <= '0;
    end else begin
      if (source_req_fire) begin
        source_urgent_hold_valid_r <= 1'b0;
      end else if (lmem_bus_if.req_valid && !source_urgent_hold_valid_r) begin
        source_urgent_hold_valid_r <= 1'b1;
        source_urgent_hold_r <= source_urgent_now;
        source_priority_hold_r <= sched_priority_i;
      end

      if (source_req_fire) begin
        if ((fetch_beat + 32'd1) == dma_fetch_if.progress_total_beats) begin
          rd_i_dim_r <= '{default:'0};
          rd_seg_offset_r <= '0;
        end else if ((rd_seg_offset_r + 32'(BUS_BYTES))
                     >= fetch_source_meta.seg_size) begin
          rd_seg_offset_r <= '0;
          rd_i_dim_r <= weight_advance_dims(
              rd_i_dim_r, fetch_source_meta.bounds);
        end else begin
          rd_seg_offset_r <= rd_seg_offset_r + 32'(BUS_BYTES);
        end
      end
    end
  end

  initial begin
    if (NDIM != 3)
      $fatal(1, "%s: Weight queue requires NDIM=3", INSTANCE_ID);
    if ((MAX_DIMS < 1) || (MAX_DIMS > NDIM))
      $fatal(1, "%s: Weight MAX_DIMS(%0d) must be in 1..%0d",
             INSTANCE_ID, MAX_DIMS, NDIM);
    if (BOUND_WIDTH != ctrl_if.BOUND_WIDTH)
      $fatal(1, "%s: Weight bound width mismatch", INSTANCE_ID);
    if ((CMD_FIFO_DEPTH != 2) && (CMD_FIFO_DEPTH != 4))
      $fatal(1, "%s: Weight queue depth must be 2 or 4", INSTANCE_ID);
    if ((CMD_BEATS < 1) || ((CMD_BEATS & (CMD_BEATS - 1)) != 0))
      $fatal(1, "%s: Weight command beats must be a positive power of two",
             INSTANCE_ID);
    if ((RESPONSE_SLOTS < 1)
     || ((RESPONSE_SLOTS & (RESPONSE_SLOTS - 1)) != 0))
      $fatal(1, "%s: Weight queue slots must be a positive power of two",
             INSTANCE_ID);
    if ((BUS_BYTES != gemm_bus_if.DATA_SIZE)
     || (BUS_BYTES != `GEMM_WEIGHT_DATA_SIZE))
      $fatal(1, "%s: Weight queue requires complete logical Weight beats",
             INSTANCE_ID);
    if ((LMEM_ADDR_WIDTH_P != lmem_bus_if.ADDR_WIDTH)
     || (GEMM_ADDR_WIDTH_P != gemm_bus_if.ADDR_WIDTH)
     || (LMEM_TAG_WIDTH_P != lmem_bus_if.TAG_WIDTH)
     || (GEMM_TAG_WIDTH_P != gemm_bus_if.TAG_WIDTH)
     || (LMEM_TAG_VALUE_W < SLOT_BITS)
     || (GEMM_TAG_VALUE_W < 1))
      $fatal(1, "%s: Weight queue bus/tag width mismatch", INSTANCE_ID);
    if ((READY_AHEAD_LOW_WATERMARK < 1)
     || (READY_AHEAD_LOW_WATERMARK > RESPONSE_SLOTS))
      $fatal(1, "%s: Weight ready-ahead watermark out of range", INSTANCE_ID);
  end

`ifndef SYNTHESIS
  `UNUSED_VAR (sink_beat)
  `UNUSED_VAR (writer_head_cmd_id)
  `UNUSED_VAR (writer_head_sequence)
  `UNUSED_VAR (fetch_complete_sequence)
  `UNUSED_VAR (install_complete_cmd_id)
  `UNUSED_VAR (install_complete_sequence)
  `UNUSED_VAR (drain_slot_r)

  logic source_stall_r;
  logic [LMEM_ADDR_WIDTH_P-1:0] source_stall_addr_r;
  logic [LMEM_TAG_VALUE_W-1:0] source_stall_tag_r;
  logic source_stall_urgent_r;
  logic [GEMM_SCHED_PRIORITY_WIDTH-1:0] source_stall_priority_r;
  logic destination_stall_r;
  logic [GEMM_ADDR_WIDTH_P-1:0] destination_stall_addr_r;
  logic [DATAW-1:0] destination_stall_data_r;
  always_ff @(posedge clk) begin
    if (reset) begin
      source_stall_r <= 1'b0;
      source_stall_addr_r <= '0;
      source_stall_tag_r <= '0;
      source_stall_urgent_r <= 1'b0;
      source_stall_priority_r <= '0;
      destination_stall_r <= 1'b0;
      destination_stall_addr_r <= '0;
      destination_stall_data_r <= '0;
    end else begin
      assert (!(ctrl_if.start && !ctrl_if.idle))
        else $fatal(1, "%s: Weight command presented while FIFO full",
                    INSTANCE_ID);
      assert (!(ctrl_if.prepare && ctrl_if.prepare_ready))
        else $fatal(1, "%s: Weight queue accepted passive prepare",
                    INSTANCE_ID);
      if (command_enqueue) begin
        assert (!command_total_beats_overflow
             && (ctrl_if.bounds[0] != 0)
             && (ctrl_if.bounds[1] != 0)
             && (ctrl_if.bounds[2] != 0)
             && (ctrl_if.seg_size != 0)
             && ((ctrl_if.seg_size % BUS_BYTES) == 0)
             && (command_total_beats == 32'(CMD_BEATS)))
          else $fatal(1, "%s: unsupported Weight descriptor shape/count",
                      INSTANCE_ID);
        if (MAX_DIMS == 1) begin
          assert ((ctrl_if.bounds[1] == BOUND_WIDTH'(1))
               && (ctrl_if.bounds[2] == BOUND_WIDTH'(1)))
            else $fatal(1, "%s: 1D Weight requires BND1/BND2=1", INSTANCE_ID);
        end else if (MAX_DIMS == 2) begin
          assert (ctrl_if.bounds[2] == BOUND_WIDTH'(1))
            else $fatal(1, "%s: 2D Weight requires BND2=1", INSTANCE_ID);
        end
        assert ((ctrl_if.src_base_addr[BUS_ADDR_BITS-1:0] == '0)
             && (ctrl_if.dst_base_addr[BUS_ADDR_BITS-1:0] == '0))
          else $fatal(1, "%s: Weight descriptor is not beat aligned",
                      INSTANCE_ID);
        assert ((ctrl_if.dst_strides[0] == 0)
             && (ctrl_if.dst_strides[1] == 0)
             && (ctrl_if.dst_strides[2] == 0))
          else $fatal(1, "%s: Weight destination is not one register selector",
                      INSTANCE_ID);
        assert (!writer_wait_i.valid
             || (((writer_wait_i.reg_id
                      == GEMM_SYNC_REG_ID_WIDTH'(GEMM_RID_W_CONSUME0))
                   && !ctrl_if.dst_base_addr[BUS_ADDR_BITS])
              || ((writer_wait_i.reg_id
                      == GEMM_SYNC_REG_ID_WIDTH'(GEMM_RID_W_CONSUME1))
                   && ctrl_if.dst_base_addr[BUS_ADDR_BITS])))
          else $fatal(1, "%s: Weight writer RID/buffer mismatch", INSTANCE_ID);
        assert (!writer_wait_i.valid || (writer_wait_i.target != 0))
          else $fatal(1, "%s: Weight writer target must be nonzero", INSTANCE_ID);
      end
      if (lmem_bus_if.rsp_valid) begin
        assert (dma_fetch_if.rsp_owned)
          else $fatal(1, "%s: Weight logical response has no queue owner",
                      INSTANCE_ID);
      end
      if (destination_write_fire) begin
        assert (writer_released && dma_sink_if.write_owned)
          else $fatal(1, "%s: Weight write bypassed owner/fence", INSTANCE_ID);
      end
      if (source_stall_r) begin
        assert (lmem_bus_if.req_valid
             && (lmem_bus_if.req_data.addr == source_stall_addr_r)
             && (lmem_bus_if.req_data.tag.value == source_stall_tag_r)
             && (lmem_req_urgent_o == source_stall_urgent_r)
             && (lmem_req_priority_o == source_stall_priority_r))
          else $fatal(1, "%s: Weight source changed under backpressure",
                      INSTANCE_ID);
      end
      if (destination_stall_r) begin
        assert (gemm_bus_if.req_valid
             && (gemm_bus_if.req_data.addr == destination_stall_addr_r)
             && (gemm_bus_if.req_data.data == destination_stall_data_r))
          else $fatal(1, "%s: Weight destination changed under backpressure",
                      INSTANCE_ID);
      end
      source_stall_r <= lmem_bus_if.req_valid && !lmem_bus_if.req_ready;
      source_stall_addr_r <= lmem_bus_if.req_data.addr;
      source_stall_tag_r <= lmem_bus_if.req_data.tag.value;
      source_stall_urgent_r <= lmem_req_urgent_o;
      source_stall_priority_r <= lmem_req_priority_o;
      destination_stall_r <= gemm_bus_if.req_valid && !gemm_bus_if.req_ready;
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
                   $time, u_stream_queue.cmd_sequence_r[rd_cmd_ptr_r],
                   dma_fetch_if.progress_request_beats,
                   dma_fetch_if.req_tag))
      end
      if (destination_write_fire) begin
        `TRACE(1, ("%m : [%0t] | WEIGHT_DMA_DEST | {seq=%0d, beat=%0d, last=%0d}\n",
                   $time, u_stream_queue.cmd_sequence_r[wr_cmd_ptr_r],
                   dma_sink_if.progress_write_beats,
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
      if (queue_cmd_occupancy != 0)
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
  assign perf.busy = (queue_cmd_occupancy != 0);
`endif

endmodule
