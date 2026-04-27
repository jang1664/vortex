/*
  VX_lmem_dma_misal.sv

  DMA Engine for LMEM <-> GEMM Unit data transfer with byte-misalignment support.
  This version decouples source reads and destination writes using:
    - RD FSM
    - WR FSM
    - response reorder slots

  Usage:
    - DIR = 0: LMEM -> GEMM
    - DIR = 1: GEMM -> LMEM
*/

`include "VX_define.vh"

module VX_lmem_dma_misal import VX_gpu_pkg::*; #(
  parameter `STRING INSTANCE_ID = "",
  parameter int DIR  = 0,
  parameter int NDIM = 3,
  parameter int TAG_WIDTH = 1,
  parameter int RD_PREFETCH_DEPTH = 1,
  // When 0, synthesize aligned-only datapath. See VX_dma_unit_misal for
  // semantics. Simulation-only $fatal guards the SW contract.
  parameter bit ENABLE_MISALIGN = 1'b0
) (
  input  wire clk,
  input  wire reset,

  VX_lmem_dma_ctrl_if.slave ctrl_if,
  VX_gemm_sync_if.master    gemm_sync_if,

  VX_mem_bus_if.master      lmem_bus_if,
  VX_mem_bus_if.master      gemm_bus_if
`ifdef PERF_ENABLE
  ,output dma_perf_t perf
`endif
);

  localparam int BUS_BYTES = lmem_bus_if.DATA_SIZE;
  localparam int BUS_BITS  = BUS_BYTES * 8;
  localparam int BUS_LG2   = `CLOG2(BUS_BYTES);

  // Misalign holds 2 beats for window shift; aligned only needs 1.
  localparam int WIN_BYTES = ENABLE_MISALIGN ? (2 * BUS_BYTES) : BUS_BYTES;
  localparam int WIN_BITS  = WIN_BYTES * 8;
  localparam int WIN_VALID_W = `CLOG2(WIN_BYTES + 1);

  localparam int RD_OUTSTANDING = 8;
  localparam int SLOT_BITS = `CLOG2(RD_OUTSTANDING);
  localparam int TAG_UUID_W  = `UP(UUID_WIDTH);
  localparam int TAG_VALUE_W = TAG_WIDTH - TAG_UUID_W;
  localparam int OCC_W = `CLOG2(RD_OUTSTANDING + 1);
  localparam int RDEPTH_W = `CLOG2(RD_PREFETCH_DEPTH + 1);

  initial begin
    if (lmem_bus_if.DATA_SIZE != gemm_bus_if.DATA_SIZE) begin
      $fatal(1, "%s: DATA_SIZE mismatch! lmem=%0d bytes, gemm=%0d bytes",
             INSTANCE_ID, lmem_bus_if.DATA_SIZE, gemm_bus_if.DATA_SIZE);
    end
    if (NDIM != 3) begin
      $fatal(1, "%s: NDIM=%0d unsupported, this implementation requires NDIM=3",
             INSTANCE_ID, NDIM);
    end
    if (TAG_WIDTH < SLOT_BITS) begin
      $fatal(1, "%s: total tag width (%0d) is smaller than required slot bits (%0d)",
             INSTANCE_ID, TAG_WIDTH, SLOT_BITS);
    end
    if ((RD_PREFETCH_DEPTH + 2) > RD_OUTSTANDING) begin
      $fatal(1, "%s: RD_PREFETCH_DEPTH(%0d) + 2 > RD_OUTSTANDING(%0d)",
             INSTANCE_ID, RD_PREFETCH_DEPTH, RD_OUTSTANDING);
    end
  end

  function automatic logic [lmem_bus_if.ADDR_WIDTH-1:0] to_bus_addr(input logic [63:0] byte_addr);
    to_bus_addr = lmem_bus_if.ADDR_WIDTH'(byte_addr >> BUS_LG2);
  endfunction

  function automatic logic [63:0] align_down(input logic [63:0] a);
    logic [63:0] m;
    begin
      m = 64'(BUS_BYTES - 1);
      align_down = (a & ~m);
    end
  endfunction

  function automatic logic [63:0] align_up(input logic [63:0] a);
    logic [63:0] m;
    begin
      m = 64'(BUS_BYTES - 1);
      align_up = (a + m) & ~m;
    end
  endfunction

  function automatic logic [31:0] umin32(input logic [31:0] a, input logic [31:0] b);
    umin32 = (a < b) ? a : b;
  endfunction

  function automatic logic [BUS_BYTES-1:0] mask_range(input int lane, input int nbytes);
    logic [BUS_BYTES-1:0] m;
    begin
      m = '0;
      for (int i = 0; i < BUS_BYTES; ++i) begin
        if ((i >= lane) && (i < (lane + nbytes)))
          m[i] = 1'b1;
      end
      mask_range = m;
    end
  endfunction

  typedef enum logic [2:0] {
    TOP_IDLE,
    TOP_PRECALC,
    TOP_RUN,
    TOP_SYNC,
    TOP_DONE
  } top_state_e;

  typedef enum logic [1:0] {
    RD_IDLE,
    RD_RUN,
    RD_DONE
  } rd_state_e;

  typedef enum logic [1:0] {
    WR_IDLE,
    WR_RUN,
    WR_DONE
  } wr_state_e;

  typedef enum logic [1:0] {
    SLOT_FREE,
    SLOT_WAIT_RSP,
    SLOT_READY
  } slot_state_e;

  typedef struct packed {
    logic        last;
    logic [31:0] i0;
    logic [31:0] i1;
    logic [31:0] i2;
    logic [63:0] src_base;
    logic [63:0] dst_base;
  } seg_adv_t;

  top_state_e top_state;
  rd_state_e  rd_state;
  wr_state_e  wr_state;

  logic [63:0] base_addr_r[2];
  logic [31:0] stride_r[2][NDIM];
  logic [63:0] stride_bound_r[2][NDIM];
  logic [31:0] bound_r[NDIM];
  logic [31:0] seg_size_r;
  logic [31:0] reg_idx_r;
  logic [31:0] reg_value_r;
  logic        precalc_pending_r;

  wire cmd_start = ctrl_if.start && (top_state == TOP_IDLE);

`ifndef SYNTHESIS
  always_ff @(posedge clk) begin
    if (!reset && !ENABLE_MISALIGN && cmd_start) begin
      if (|ctrl_if.src_base_addr[BUS_LG2-1:0])
        $fatal(1, "%s: ENABLE_MISALIGN=0 but src_base=0x%016h is not %0d-byte aligned",
               INSTANCE_ID, ctrl_if.src_base_addr, BUS_BYTES);
      if (|ctrl_if.dst_base_addr[BUS_LG2-1:0])
        $fatal(1, "%s: ENABLE_MISALIGN=0 but dst_base=0x%016h is not %0d-byte aligned",
               INSTANCE_ID, ctrl_if.dst_base_addr, BUS_BYTES);
      for (int d = 0; d < NDIM; d++) begin
        if (|ctrl_if.src_strides[d][BUS_LG2-1:0])
          $fatal(1, "%s: ENABLE_MISALIGN=0 but src_stride[%0d]=0x%08h is not %0d-byte aligned",
                 INSTANCE_ID, d, ctrl_if.src_strides[d], BUS_BYTES);
        if (|ctrl_if.dst_strides[d][BUS_LG2-1:0])
          $fatal(1, "%s: ENABLE_MISALIGN=0 but dst_stride[%0d]=0x%08h is not %0d-byte aligned",
                 INSTANCE_ID, d, ctrl_if.dst_strides[d], BUS_BYTES);
      end
    end
  end
`endif
  wire precalc_issue = (top_state == TOP_PRECALC) && precalc_pending_r;

  logic [5:0]       precalc_valid;
  logic [5:0][63:0] precalc_result;
  wire              precalc_done = &precalc_valid;

  VX_mul_u32_pipe #(.OUT_REGS(0)) mul_src_d0 (
    .clk(clk), .reset(reset), .valid_in(precalc_issue),
    .a(stride_r[0][0]), .b(bound_r[0] - 32'd1),
    .valid_out(precalc_valid[0]), .result(precalc_result[0])
  );

  VX_mul_u32_pipe #(.OUT_REGS(0)) mul_dst_d0 (
    .clk(clk), .reset(reset), .valid_in(precalc_issue),
    .a(stride_r[1][0]), .b(bound_r[0] - 32'd1),
    .valid_out(precalc_valid[1]), .result(precalc_result[1])
  );

  VX_mul_u32_pipe #(.OUT_REGS(0)) mul_src_d1 (
    .clk(clk), .reset(reset), .valid_in(precalc_issue),
    .a(stride_r[0][1]), .b(bound_r[1] - 32'd1),
    .valid_out(precalc_valid[2]), .result(precalc_result[2])
  );

  VX_mul_u32_pipe #(.OUT_REGS(0)) mul_dst_d1 (
    .clk(clk), .reset(reset), .valid_in(precalc_issue),
    .a(stride_r[1][1]), .b(bound_r[1] - 32'd1),
    .valid_out(precalc_valid[3]), .result(precalc_result[3])
  );

  VX_mul_u32_pipe #(.OUT_REGS(0)) mul_src_d2 (
    .clk(clk), .reset(reset), .valid_in(precalc_issue),
    .a(stride_r[0][2]), .b(bound_r[2] - 32'd1),
    .valid_out(precalc_valid[4]), .result(precalc_result[4])
  );

  VX_mul_u32_pipe #(.OUT_REGS(0)) mul_dst_d2 (
    .clk(clk), .reset(reset), .valid_in(precalc_issue),
    .a(stride_r[1][2]), .b(bound_r[2] - 32'd1),
    .valid_out(precalc_valid[5]), .result(precalc_result[5])
  );

  wire src_is_gemm = (DIR != 0);
  wire dst_is_gemm = (DIR == 0);

  logic [31:0] rd_i_dim[NDIM];
  logic [63:0] rd_base_src_seg_r;
  logic [63:0] rd_base_dst_seg_r;
  logic [63:0] rd_src_rd_ptr_r;
  logic [63:0] rd_src_rd_end_r;
  logic        rd_all_done_r;

  logic [31:0] wr_i_dim[NDIM];
  logic [63:0] wr_base_src_seg_r;
  logic [63:0] wr_base_dst_seg_r;
  logic [31:0] wr_out_off_r;
  logic [31:0] wr_src_drop_r;
  logic [WIN_BITS-1:0] wr_win_r;
  logic [WIN_VALID_W-1:0] wr_win_valid_r;

  slot_state_e slot_state_r[RD_OUTSTANDING];
  logic [BUS_BITS-1:0] slot_data_r[RD_OUTSTANDING];
  logic [SLOT_BITS-1:0] rd_issue_slot_r;
  logic [SLOT_BITS-1:0] wr_expect_slot_r;
  logic [OCC_W-1:0] slot_occupancy_r;
  logic [RDEPTH_W-1:0] rd_ahead_count_r;
  wire rd_prefetch_eligible = (seg_size_r[BUS_LG2-1:0] == '0)
                           && (rd_base_src_seg_r[BUS_LG2-1:0] == '0);

  function automatic logic seg_is_last(
    input logic [31:0] i0,
    input logic [31:0] i1,
    input logic [31:0] i2
  );
    seg_is_last = (i0 == (bound_r[0] - 32'd1))
               && (i1 == (bound_r[1] - 32'd1))
               && (i2 == (bound_r[2] - 32'd1));
  endfunction

  function automatic seg_adv_t advance_segment(
    input logic [31:0] i0,
    input logic [31:0] i1,
    input logic [31:0] i2,
    input logic [63:0] base_src,
    input logic [63:0] base_dst
  );
    seg_adv_t ret;
    begin
      ret.last     = seg_is_last(i0, i1, i2);
      ret.i0       = i0;
      ret.i1       = i1;
      ret.i2       = i2;
      ret.src_base = base_src;
      ret.dst_base = base_dst;

      if (!ret.last) begin
        if (i0 + 1 < bound_r[0]) begin
          ret.i0       = i0 + 1;
          ret.src_base = base_src + 64'(stride_r[0][0]);
          ret.dst_base = base_dst + 64'(stride_r[1][0]);
        end else begin
          ret.i0 = 32'd0;
          if (i1 + 1 < bound_r[1]) begin
            ret.i1       = i1 + 1;
            ret.src_base = base_src + 64'(stride_r[0][1]) - stride_bound_r[0][0];
            ret.dst_base = base_dst + 64'(stride_r[1][1]) - stride_bound_r[1][0];
          end else begin
            ret.i1 = 32'd0;
            ret.i2 = i2 + 1;
            ret.src_base = base_src + 64'(stride_r[0][2]) - stride_bound_r[0][1] - stride_bound_r[0][0];
            ret.dst_base = base_dst + 64'(stride_r[1][2]) - stride_bound_r[1][1] - stride_bound_r[1][0];
          end
        end
      end

      advance_segment = ret;
    end
  endfunction

  wire src_req_fire = src_is_gemm
                    ? (gemm_bus_if.req_valid && gemm_bus_if.req_ready)
                    : (lmem_bus_if.req_valid && lmem_bus_if.req_ready);

  wire src_rsp_fire = src_is_gemm
                    ? (gemm_bus_if.rsp_valid && gemm_bus_if.rsp_ready)
                    : (lmem_bus_if.rsp_valid && lmem_bus_if.rsp_ready);

  wire dst_req_fire = dst_is_gemm
                    ? (gemm_bus_if.req_valid && gemm_bus_if.req_ready)
                    : (lmem_bus_if.req_valid && lmem_bus_if.req_ready);

  wire [63:0] wr_src_byte_addr = wr_base_src_seg_r + 64'(wr_out_off_r);
  wire [63:0] wr_dst_byte_addr = wr_base_dst_seg_r + 64'(wr_out_off_r);
  wire [31:0] wr_remaining = (wr_out_off_r < seg_size_r) ? (seg_size_r - wr_out_off_r) : 32'd0;
  // Aligned mode guarantees the low bits are 0, so we short-circuit the lane
  // computation to a constant — makes the lane-shift barrel in wr_data fold
  // away at elaboration time.
  wire [31:0] wr_lane = ENABLE_MISALIGN ? 32'(wr_dst_byte_addr[BUS_LG2-1:0]) : 32'd0;
  wire [31:0] wr_beat_room = BUS_BYTES - wr_lane;
  wire [31:0] wr_nbytes = umin32(wr_remaining, wr_beat_room);
  wire [63:0] wr_dst_aligned = wr_dst_byte_addr - 64'($unsigned(wr_lane));

  wire wr_pull_slot = (top_state == TOP_RUN)
                   && (wr_state == WR_RUN)
                   && (slot_state_r[wr_expect_slot_r] == SLOT_READY)
                   && (wr_win_valid_r <= (WIN_BYTES - BUS_BYTES));
  logic [WIN_BITS-1:0] wr_win_pre;
  logic [WIN_VALID_W-1:0] wr_win_valid_pre;
  logic [31:0] wr_src_drop_pre;
  logic [BUS_BITS-1:0]  wr_data;
  logic [BUS_BYTES-1:0] wr_byteen;
  wire wr_has_data = (wr_src_drop_pre == 0) && (wr_win_valid_pre >= wr_nbytes) && (wr_nbytes != 0);

  always_comb begin
    wr_win_pre       = wr_win_r;
    wr_win_valid_pre = wr_win_valid_r;
    wr_src_drop_pre  = wr_src_drop_r;

    if (wr_pull_slot) begin
      if (ENABLE_MISALIGN)
        wr_win_pre[wr_win_valid_r*8 +: BUS_BITS] = slot_data_r[wr_expect_slot_r];
      else
        // Aligned: staging is a single BUS_BYTES-wide reg. wr_win_valid_r is
        // always 0 when wr_pull_slot fires (see wr_pull_slot condition).
        wr_win_pre[0 +: BUS_BITS] = slot_data_r[wr_expect_slot_r];
      wr_win_valid_pre = wr_win_valid_r + WIN_VALID_W'(BUS_BYTES);
    end

    if (ENABLE_MISALIGN) begin
      if ((wr_src_drop_pre != 0) && (wr_win_valid_pre >= wr_src_drop_pre[WIN_VALID_W-1:0])) begin
        wr_win_pre       = wr_win_pre >> (wr_src_drop_pre * 8);
        wr_win_valid_pre = wr_win_valid_pre - wr_src_drop_pre[WIN_VALID_W-1:0];
        wr_src_drop_pre  = 32'd0;
      end
    end

    wr_data   = '0;
    wr_byteen = mask_range(int'(wr_lane), int'(wr_nbytes));
    if (ENABLE_MISALIGN) begin
      for (int b = 0; b < BUS_BYTES; ++b) begin
        if ((b >= int'(wr_lane)) && (b < int'(wr_lane + wr_nbytes))) begin
          wr_data[b*8 +: 8] = wr_win_pre[(b - int'(wr_lane))*8 +: 8];
        end
      end
    end else begin
      // lane = 0: window -> wr_data[0 +: wr_nbytes*8], zero-pad beyond
      for (int b = 0; b < BUS_BYTES; ++b) begin
        if (b < int'(wr_nbytes)) begin
          wr_data[b*8 +: 8] = wr_win_pre[b*8 +: 8];
        end
      end
    end
  end

  wire [OCC_W-1:0] slot_occupancy_next
                = slot_occupancy_r
                + OCC_W'(src_req_fire ? 1 : 0)
                - OCC_W'(wr_pull_slot ? 1 : 0);
  wire [TAG_WIDTH-1:0] rd_issue_tag = TAG_WIDTH'(rd_issue_slot_r);

  always_comb begin
    ctrl_if.idle = (top_state == TOP_IDLE);
    ctrl_if.done = (top_state == TOP_DONE);

    lmem_bus_if.req_valid = 1'b0;
    lmem_bus_if.req_data  = '0;
    lmem_bus_if.rsp_ready = 1'b1;

    gemm_bus_if.req_valid = 1'b0;
    gemm_bus_if.req_data  = '0;
    gemm_bus_if.rsp_ready = 1'b1;

    gemm_sync_if.valid   = 1'b0;
    gemm_sync_if.reg_idx = reg_idx_r;
    gemm_sync_if.value   = reg_value_r;

    if ((top_state == TOP_RUN) && (rd_state == RD_RUN)
        && (rd_src_rd_ptr_r < rd_src_rd_end_r)
        && (slot_occupancy_r < RD_OUTSTANDING)
        && (slot_state_r[rd_issue_slot_r] == SLOT_FREE)) begin
      if (src_is_gemm) begin
        gemm_bus_if.req_valid         = 1'b1;
        gemm_bus_if.req_data.rw       = 1'b0;
        gemm_bus_if.req_data.addr     = to_bus_addr(rd_src_rd_ptr_r);
        gemm_bus_if.req_data.byteen   = '0;
        gemm_bus_if.req_data.data     = '0;
        gemm_bus_if.req_data.flags    = '0;
        gemm_bus_if.req_data.tag.uuid = rd_issue_tag[TAG_WIDTH-1 -: TAG_UUID_W];
        gemm_bus_if.req_data.tag.value= rd_issue_tag[TAG_VALUE_W-1:0];
      end else begin
        lmem_bus_if.req_valid         = 1'b1;
        lmem_bus_if.req_data.rw       = 1'b0;
        lmem_bus_if.req_data.addr     = to_bus_addr(rd_src_rd_ptr_r);
        lmem_bus_if.req_data.byteen   = '0;
        lmem_bus_if.req_data.data     = '0;
        lmem_bus_if.req_data.flags    = '0;
        lmem_bus_if.req_data.tag.uuid = rd_issue_tag[TAG_WIDTH-1 -: TAG_UUID_W];
        lmem_bus_if.req_data.tag.value= rd_issue_tag[TAG_VALUE_W-1:0];
      end
    end

    if ((top_state == TOP_RUN) && (wr_state == WR_RUN) && wr_has_data) begin
      if (dst_is_gemm) begin
        gemm_bus_if.req_valid         = 1'b1;
        gemm_bus_if.req_data.rw       = 1'b1;
        gemm_bus_if.req_data.addr     = to_bus_addr(wr_dst_aligned);
        gemm_bus_if.req_data.data     = wr_data;
        gemm_bus_if.req_data.byteen   = wr_byteen;
        gemm_bus_if.req_data.flags    = '0;
        gemm_bus_if.req_data.tag.uuid = '0;
        gemm_bus_if.req_data.tag.value= '0;
      end else begin
        lmem_bus_if.req_valid         = 1'b1;
        lmem_bus_if.req_data.rw       = 1'b1;
        lmem_bus_if.req_data.addr     = to_bus_addr(wr_dst_aligned);
        lmem_bus_if.req_data.data     = wr_data;
        lmem_bus_if.req_data.byteen   = wr_byteen;
        lmem_bus_if.req_data.flags    = '0;
        lmem_bus_if.req_data.tag.uuid = '0;
        lmem_bus_if.req_data.tag.value= '0;
      end
    end

    if (top_state == TOP_SYNC) begin
      gemm_sync_if.valid = 1'b1;
    end
  end

  always_ff @(posedge clk) begin
    if (reset) begin
      top_state <= TOP_IDLE;
      rd_state  <= RD_IDLE;
      wr_state  <= WR_IDLE;

      base_addr_r[0] <= '0;
      base_addr_r[1] <= '0;
      seg_size_r     <= '0;
      reg_idx_r      <= '0;
      reg_value_r    <= '0;
      precalc_pending_r <= 1'b0;

      for (int d = 0; d < NDIM; ++d) begin
        stride_r[0][d] <= '0;
        stride_r[1][d] <= '0;
        stride_bound_r[0][d] <= '0;
        stride_bound_r[1][d] <= '0;
        bound_r[d] <= '0;
        rd_i_dim[d] <= '0;
        wr_i_dim[d] <= '0;
      end

      rd_base_src_seg_r <= '0;
      rd_base_dst_seg_r <= '0;
      rd_src_rd_ptr_r   <= '0;
      rd_src_rd_end_r   <= '0;
      rd_all_done_r     <= 1'b0;

      wr_base_src_seg_r <= '0;
      wr_base_dst_seg_r <= '0;
      wr_out_off_r      <= '0;
      wr_src_drop_r     <= '0;
      wr_win_r          <= '0;
      wr_win_valid_r    <= '0;

      rd_issue_slot_r   <= '0;
      wr_expect_slot_r  <= '0;
      slot_occupancy_r  <= '0;
      rd_ahead_count_r  <= '0;
      for (int i = 0; i < RD_OUTSTANDING; ++i) begin
        slot_state_r[i] <= SLOT_FREE;
        slot_data_r[i]  <= '0;
      end
    end else begin
      if (cmd_start) begin
        base_addr_r[0] <= ctrl_if.src_base_addr;
        base_addr_r[1] <= ctrl_if.dst_base_addr;
        seg_size_r     <= ctrl_if.seg_size;
        reg_idx_r      <= ctrl_if.reg_idx;
        reg_value_r    <= ctrl_if.reg_value;
        precalc_pending_r <= 1'b1;

        for (int d = 0; d < NDIM; ++d) begin
          stride_r[0][d] <= ctrl_if.src_strides[d];
          stride_r[1][d] <= ctrl_if.dst_strides[d];
          stride_bound_r[0][d] <= '0;
          stride_bound_r[1][d] <= '0;
          bound_r[d] <= ctrl_if.bounds[d];
          rd_i_dim[d] <= 32'd0;
          wr_i_dim[d] <= 32'd0;
        end

        rd_base_src_seg_r <= ctrl_if.src_base_addr;
        rd_base_dst_seg_r <= ctrl_if.dst_base_addr;
        rd_src_rd_ptr_r   <= '0;
        rd_src_rd_end_r   <= '0;
        rd_all_done_r     <= 1'b0;

        wr_base_src_seg_r <= ctrl_if.src_base_addr;
        wr_base_dst_seg_r <= ctrl_if.dst_base_addr;
        wr_out_off_r      <= 32'd0;
        // Aligned mode keeps drop permanently 0 so synthesis can prune the
        // drop register entirely.
        wr_src_drop_r     <= ENABLE_MISALIGN ? ctrl_if.src_base_addr[BUS_LG2-1:0] : 32'd0;
        wr_win_r          <= '0;
        wr_win_valid_r    <= '0;

        rd_issue_slot_r  <= '0;
        wr_expect_slot_r <= '0;
        slot_occupancy_r <= '0;
        rd_ahead_count_r <= '0;
        for (int i = 0; i < RD_OUTSTANDING; ++i) begin
          slot_state_r[i] <= SLOT_FREE;
        end

        top_state <= TOP_PRECALC;
        rd_state  <= RD_IDLE;
        wr_state  <= WR_IDLE;
      end else begin
        if (precalc_issue)
          precalc_pending_r <= 1'b0;

        if (precalc_done) begin
          stride_bound_r[0][0] <= precalc_result[0];
          stride_bound_r[1][0] <= precalc_result[1];
          stride_bound_r[0][1] <= precalc_result[2];
          stride_bound_r[1][1] <= precalc_result[3];
          stride_bound_r[0][2] <= precalc_result[4];
          stride_bound_r[1][2] <= precalc_result[5];
        end

        case (top_state)
          TOP_IDLE: begin
          end

          TOP_PRECALC: begin
            if (precalc_done) begin
              top_state <= TOP_RUN;
              rd_state  <= RD_RUN;
              wr_state  <= WR_RUN;
              rd_src_rd_ptr_r <= align_down(base_addr_r[0]);
              rd_src_rd_end_r <= align_up(base_addr_r[0] + 64'(seg_size_r));
            end
          end

          TOP_RUN: begin
            if (src_req_fire) begin
              logic [63:0] next_rd_ptr;
              seg_adv_t rd_adv;
              next_rd_ptr = rd_src_rd_ptr_r + BUS_BYTES;
              slot_state_r[rd_issue_slot_r] <= SLOT_WAIT_RSP;
              rd_issue_slot_r <= rd_issue_slot_r + 1'b1;

              if (next_rd_ptr >= rd_src_rd_end_r) begin
                rd_adv = advance_segment(rd_i_dim[0], rd_i_dim[1], rd_i_dim[2],
                                         rd_base_src_seg_r, rd_base_dst_seg_r);

                if (rd_adv.last) begin
                  rd_state <= RD_DONE;
                  rd_all_done_r <= 1'b1;
                  rd_src_rd_ptr_r <= next_rd_ptr;
                end else if (rd_prefetch_eligible
                             && (rd_ahead_count_r < RDEPTH_W'(RD_PREFETCH_DEPTH))) begin
                  rd_ahead_count_r <= rd_ahead_count_r + RDEPTH_W'(1);
                  rd_i_dim[0] <= rd_adv.i0;
                  rd_i_dim[1] <= rd_adv.i1;
                  rd_i_dim[2] <= rd_adv.i2;
                  rd_base_src_seg_r <= rd_adv.src_base;
                  rd_base_dst_seg_r <= rd_adv.dst_base;
                  rd_src_rd_ptr_r <= align_down(rd_adv.src_base);
                  rd_src_rd_end_r <= align_up(rd_adv.src_base + 64'(seg_size_r));
                  rd_all_done_r <= 1'b0;
                end else begin
                  rd_state <= RD_DONE;
                  rd_all_done_r <= 1'b0;
                  rd_i_dim[0] <= rd_adv.i0;
                  rd_i_dim[1] <= rd_adv.i1;
                  rd_i_dim[2] <= rd_adv.i2;
                  rd_base_src_seg_r <= rd_adv.src_base;
                  rd_base_dst_seg_r <= rd_adv.dst_base;
                  rd_src_rd_ptr_r <= align_down(rd_adv.src_base);
                  rd_src_rd_end_r <= align_up(rd_adv.src_base + 64'(seg_size_r));
                end
              end else begin
                rd_src_rd_ptr_r <= next_rd_ptr;
              end
            end

            if (src_rsp_fire) begin
              logic [SLOT_BITS-1:0] rsp_slot_idx;
              logic [TAG_WIDTH-1:0] rsp_full_tag;
              rsp_full_tag = src_is_gemm
                           ? {gemm_bus_if.rsp_data.tag.uuid, gemm_bus_if.rsp_data.tag.value}
                           : {lmem_bus_if.rsp_data.tag.uuid, lmem_bus_if.rsp_data.tag.value};
              rsp_slot_idx = rsp_full_tag[SLOT_BITS-1:0];
              slot_state_r[rsp_slot_idx] <= SLOT_READY;
              slot_data_r[rsp_slot_idx]  <= src_is_gemm ? gemm_bus_if.rsp_data.data : lmem_bus_if.rsp_data.data;
            end

            begin : wr_update_block
              logic [WIN_BITS-1:0] tmp_win;
              logic [WIN_VALID_W-1:0] tmp_valid;
              logic [31:0] tmp_drop;
              logic [31:0] tmp_out_off;

              tmp_win     = wr_win_r;
              tmp_valid   = wr_win_valid_r;
              tmp_drop    = wr_src_drop_r;
              tmp_out_off = wr_out_off_r;

              if (wr_pull_slot) begin
                if (ENABLE_MISALIGN)
                  tmp_win[tmp_valid*8 +: BUS_BITS] = slot_data_r[wr_expect_slot_r];
                else
                  tmp_win[0 +: BUS_BITS] = slot_data_r[wr_expect_slot_r];
                tmp_valid = tmp_valid + BUS_BYTES[WIN_VALID_W-1:0];
                slot_state_r[wr_expect_slot_r] <= SLOT_FREE;
                wr_expect_slot_r <= wr_expect_slot_r + 1'b1;
              end

              if (ENABLE_MISALIGN) begin
                if ((tmp_drop != 0) && (tmp_valid >= tmp_drop[WIN_VALID_W-1:0])) begin
                  tmp_win   = tmp_win >> (tmp_drop * 8);
                  tmp_valid = tmp_valid - tmp_drop[WIN_VALID_W-1:0];
                  tmp_drop  = 32'd0;
                end
              end

              if (dst_req_fire) begin
                seg_adv_t wr_adv;
                if (wr_nbytes != 0) begin
                  if (ENABLE_MISALIGN) begin
                    tmp_win   = tmp_win >> (wr_nbytes * 8);
                    tmp_valid = tmp_valid - wr_nbytes[WIN_VALID_W-1:0];
                  end else begin
                    // Aligned: one beat consume empties staging. Next pull
                    // refills with a full beat.
                    tmp_win   = '0;
                    tmp_valid = '0;
                  end
                end
                tmp_out_off = wr_out_off_r + wr_nbytes;

                if (tmp_out_off >= seg_size_r) begin
                  wr_adv = advance_segment(wr_i_dim[0], wr_i_dim[1], wr_i_dim[2], wr_base_src_seg_r, wr_base_dst_seg_r);
                  if (wr_adv.last) begin
                    wr_state <= WR_DONE;
                    tmp_win   = '0;
                    tmp_valid = '0;
                    tmp_drop  = 32'd0;
                    tmp_out_off = 32'd0;
                  end else begin
                    wr_i_dim[0] <= wr_adv.i0;
                    wr_i_dim[1] <= wr_adv.i1;
                    wr_i_dim[2] <= wr_adv.i2;
                    wr_base_src_seg_r <= wr_adv.src_base;
                    wr_base_dst_seg_r <= wr_adv.dst_base;
                    // Preserve buffered bytes only when RD is already one
                    // segment ahead. Otherwise the buffered tail belongs to
                    // the current segment's aligned over-read and must be
                    // dropped at the segment boundary.
                    if ((rd_ahead_count_r == 0) || !rd_prefetch_eligible) begin
                      tmp_win   = '0;
                      tmp_valid = '0;
                    end
                    // Aligned mode: drop is always 0 (assertion-enforced).
                    tmp_drop     = ENABLE_MISALIGN ? wr_adv.src_base[BUS_LG2-1:0] : 32'd0;
                    tmp_out_off  = 32'd0;

                    if (rd_ahead_count_r != 0)
                      rd_ahead_count_r <= rd_ahead_count_r - RDEPTH_W'(1);

                    if ((rd_state == RD_DONE) && !rd_all_done_r) begin
                      rd_state <= RD_RUN;
                    end
                  end
                end
              end

              wr_win_r       <= tmp_win;
              wr_win_valid_r <= tmp_valid;
              wr_src_drop_r  <= tmp_drop;
              wr_out_off_r   <= tmp_out_off;
            end

            unique case ({src_req_fire, wr_pull_slot})
              2'b10: slot_occupancy_r <= slot_occupancy_r + OCC_W'(1);
              2'b01: slot_occupancy_r <= slot_occupancy_r - OCC_W'(1);
              default:;
            endcase

            if ((rd_state == RD_DONE)
                && rd_all_done_r
                && (wr_state == WR_DONE)
                && (slot_occupancy_next == 0)
                && (wr_win_valid_r == 0)) begin
              top_state <= TOP_SYNC;
            end
          end

          TOP_SYNC: begin
            if (gemm_sync_if.ready)
              top_state <= TOP_DONE;
          end

          TOP_DONE: begin
            top_state <= TOP_IDLE;
            rd_state  <= RD_IDLE;
            wr_state  <= WR_IDLE;
          end

          default: begin
            top_state <= TOP_IDLE;
            rd_state  <= RD_IDLE;
            wr_state  <= WR_IDLE;
          end
        endcase
      end
    end
  end

`ifdef PERF_ENABLE
    // Direction-based source/destination selection. The synthesizer prunes
    // the unused branch since DIR is a parameter.
    logic perf_src_req_valid;
    logic perf_src_req_ready;
    logic perf_src_rsp_valid;
    logic perf_src_rsp_ready;
    logic perf_dst_req_valid;
    logic perf_dst_req_ready;

    generate
        if (DIR == 0) begin : g_dir_l2g
            // DIR=0 (LMEM -> GEMM): src=lmem, dst=gemm
            assign perf_src_req_valid = lmem_bus_if.req_valid;
            assign perf_src_req_ready = lmem_bus_if.req_ready;
            assign perf_src_rsp_valid = lmem_bus_if.rsp_valid;
            assign perf_src_rsp_ready = lmem_bus_if.rsp_ready;
            assign perf_dst_req_valid = gemm_bus_if.req_valid;
            assign perf_dst_req_ready = gemm_bus_if.req_ready;
        end else begin : g_dir_g2l
            // DIR=1 (GEMM -> LMEM): src=gemm, dst=lmem
            assign perf_src_req_valid = gemm_bus_if.req_valid;
            assign perf_src_req_ready = gemm_bus_if.req_ready;
            assign perf_src_rsp_valid = gemm_bus_if.rsp_valid;
            assign perf_src_rsp_ready = gemm_bus_if.rsp_ready;
            assign perf_dst_req_valid = lmem_bus_if.req_valid;
            assign perf_dst_req_ready = lmem_bus_if.req_ready;
        end
    endgenerate

    // Counters
    reg [PERF_CTR_BITS-1:0] perf_rd_bytes_r;
    reg [PERF_CTR_BITS-1:0] perf_wr_bytes_r;
    reg [PERF_CTR_BITS-1:0] perf_xfers_r;
    reg [PERF_CTR_BITS-1:0] perf_active_r;
    reg [PERF_CTR_BITS-1:0] perf_src_rd_req_fire_r,  perf_src_rd_req_stall_r;
    reg [PERF_CTR_BITS-1:0] perf_src_rd_data_fire_r, perf_src_rd_data_stall_r;
    reg [PERF_CTR_BITS-1:0] perf_dst_wr_fire_r,      perf_dst_wr_stall_r;

    // Edge detection for xfer_count: rising edge into TOP_DONE.
    top_state_e top_state_q1;
    always @(posedge clk) begin
        if (reset)
            top_state_q1 <= TOP_IDLE;
        else
            top_state_q1 <= top_state;
    end

    wire dma_is_active = (top_state != TOP_IDLE) && (top_state != TOP_DONE);
    wire dma_xfer_done = (top_state == TOP_DONE) && (top_state_q1 != TOP_DONE);

    // Fire/stall events on src and dst ports (valid && ready / valid && !ready).
    wire perf_src_rd_req_fire   = perf_src_req_valid &&  perf_src_req_ready;
    wire perf_src_rd_req_stall  = perf_src_req_valid && !perf_src_req_ready;
    wire perf_src_rd_data_fire  = perf_src_rsp_valid &&  perf_src_rsp_ready;
    wire perf_src_rd_data_stall = perf_src_rsp_valid && !perf_src_rsp_ready;
    wire perf_dst_wr_fire       = perf_dst_req_valid &&  perf_dst_req_ready;
    wire perf_dst_wr_stall      = perf_dst_req_valid && !perf_dst_req_ready;

    always @(posedge clk) begin
        if (reset) begin
            perf_rd_bytes_r          <= '0;
            perf_wr_bytes_r          <= '0;
            perf_xfers_r             <= '0;
            perf_active_r            <= '0;
            perf_src_rd_req_fire_r   <= '0;
            perf_src_rd_req_stall_r  <= '0;
            perf_src_rd_data_fire_r  <= '0;
            perf_src_rd_data_stall_r <= '0;
            perf_dst_wr_fire_r       <= '0;
            perf_dst_wr_stall_r      <= '0;
        end else begin
            if (perf_src_rd_data_fire)
                perf_rd_bytes_r <= perf_rd_bytes_r + PERF_CTR_BITS'(BUS_BYTES);
            if (perf_dst_wr_fire)
                perf_wr_bytes_r <= perf_wr_bytes_r + PERF_CTR_BITS'(BUS_BYTES);
            if (dma_xfer_done)
                perf_xfers_r <= perf_xfers_r + PERF_CTR_BITS'(1);
            if (dma_is_active)
                perf_active_r <= perf_active_r + PERF_CTR_BITS'(1);
            if (perf_src_rd_req_fire)
                perf_src_rd_req_fire_r <= perf_src_rd_req_fire_r + PERF_CTR_BITS'(1);
            if (perf_src_rd_req_stall)
                perf_src_rd_req_stall_r <= perf_src_rd_req_stall_r + PERF_CTR_BITS'(1);
            if (perf_src_rd_data_fire)
                perf_src_rd_data_fire_r <= perf_src_rd_data_fire_r + PERF_CTR_BITS'(1);
            if (perf_src_rd_data_stall)
                perf_src_rd_data_stall_r <= perf_src_rd_data_stall_r + PERF_CTR_BITS'(1);
            if (perf_dst_wr_fire)
                perf_dst_wr_fire_r <= perf_dst_wr_fire_r + PERF_CTR_BITS'(1);
            if (perf_dst_wr_stall)
                perf_dst_wr_stall_r <= perf_dst_wr_stall_r + PERF_CTR_BITS'(1);
        end
    end

    assign perf.rd_bytes          = perf_rd_bytes_r;
    assign perf.wr_bytes          = perf_wr_bytes_r;
    assign perf.xfer_count        = perf_xfers_r;
    assign perf.active_cycles     = perf_active_r;
    assign perf.src_rd_req_fire   = perf_src_rd_req_fire_r;
    assign perf.src_rd_req_stall  = perf_src_rd_req_stall_r;
    assign perf.src_rd_data_fire  = perf_src_rd_data_fire_r;
    assign perf.src_rd_data_stall = perf_src_rd_data_stall_r;
    assign perf.dst_wr_fire       = perf_dst_wr_fire_r;
    assign perf.dst_wr_stall      = perf_dst_wr_stall_r;
    // This module never touches dcache and never needs to disambiguate the
    // two local buses, so both wait counters are constant zero here.
    assign perf.wait_dcache       = '0;
    assign perf.wait_lmem         = '0;
    assign perf.busy              = dma_is_active;
`endif

`ifdef CHIPSCOPE
`ifdef DBG_SCOPE_GEMM
  localparam int DBG_TOP_STATE_W = $bits(top_state);
  localparam int DBG_RD_STATE_W  = $bits(rd_state);
  localparam int DBG_WR_STATE_W  = $bits(wr_state);
  (* keep = "true", mark_debug = "true" *) wire [63:0] dbg_lmem_dma_top = {
      top_state,
      rd_state,
      wr_state,
      8'(rd_ahead_count_r),
      ctrl_if.start,
      ctrl_if.idle,
      ctrl_if.done,
      src_req_fire,
      src_rsp_fire,
      dst_req_fire,
      wr_pull_slot,
      precalc_issue,
      precalc_done,
      8'(slot_occupancy_r),
      8'(wr_win_valid_r),
      5'd0
  };
`endif
`endif

endmodule
