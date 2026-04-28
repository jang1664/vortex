`include "VX_define.vh"

module VX_gemm_job_frontend import VX_gpu_pkg::*; #(
  parameter `STRING INSTANCE_ID = "",
  parameter int NUM_MASTERS  = 1,
  parameter logic [63:0] CFG_BASE_ADDR = 64'h0,
  parameter int FIFO_DEPTH = 16
) (
  input  wire clk,
  input  wire reset,

  VX_lsu_mem_if.slave            mmio_if[NUM_MASTERS],
  VX_instruction_if.master       issue_if,
  VX_gemm_node_done_if.slave     done_if
);

  localparam int MMIO_ARB_SEL_BITS  = `ARB_SEL_BITS(NUM_MASTERS, 1);
  localparam int MMIO_ARB_TAG_WIDTH = LSU_TAG_WIDTH + MMIO_ARB_SEL_BITS;
  localparam int DATA_SIZE_SHIFT    = `CLOG2(LSU_WORD_SIZE);
  localparam int ADDR_WIDTH         = `MEM_ADDR_WIDTH - DATA_SIZE_SHIFT;
  localparam int NUM_LANES          = `NUM_LSU_LANES;
  localparam int FIFO_CNT_W         = `CLOG2(FIFO_DEPTH+1);
  localparam int FIFO_PUSHCNT_W     = `CLOG2(NUM_LANES+1);

  // MMIO layout (8-lane burst window)
  //   [CFG_BASE_ADDR + 0]                 : ALLOC read doorbell (lane 0 only)
  //   [CFG_BASE_ADDR + 8 .. CFG+8+8*NL)   : 8-slot stream burst window
  //                                          lane i writes to CFG_BASE+8+8*i
  //                                          (lane 0 == legacy GEMM_STREAM_ADDR)
  //   [CFG_BASE_ADDR + 0x80]              : STATE read register (lane 0 only)
  //
  // STATE moved up from offset 16 to 0x80 to make room for the burst window
  // (offsets 8..71 = 0x08..0x47 are now stream slots 0..7).
  localparam logic [63:0] STREAM_START_OFF_B = 64'd8;
  localparam logic [63:0] STREAM_END_OFF_B   = STREAM_START_OFF_B
                                             + 64'(NUM_LANES) * 64'(LSU_WORD_SIZE);
  localparam logic [63:0] STATE_READ_OFF_B   = 64'd128;

  VX_lsu_mem_if #(
    .NUM_LANES(`NUM_LSU_LANES),
    .DATA_SIZE(LSU_WORD_SIZE),
    .TAG_WIDTH(MMIO_ARB_TAG_WIDTH)
  ) mmio_arb_out[1] ();

  VX_lsu_mem_arb #(
    .NUM_INPUTS (NUM_MASTERS),
    .NUM_OUTPUTS(1),
    .NUM_LANES  (`NUM_LSU_LANES),
    .DATA_SIZE  (LSU_WORD_SIZE),
    .TAG_WIDTH  (LSU_TAG_WIDTH),
    .TAG_SEL_IDX(0),
    .ARBITER    ("R"),
    .REQ_OUT_BUF(0),
    .RSP_OUT_BUF(2)
  ) mmio_arb (
    .clk       (clk),
    .reset     (reset),
    .bus_in_if (mmio_if),
    .bus_out_if(mmio_arb_out)
  );

  logic occupied_q, occupied_d;
  logic [30:0] generation_q, generation_d;

  logic rsp_valid_q, rsp_valid_d;
  logic [`NUM_LSU_LANES-1:0] rsp_mask_q, rsp_mask_d;
  logic [`NUM_LSU_LANES-1:0][LSU_WORD_SIZE*8-1:0] rsp_data_q, rsp_data_d;
  logic [MMIO_ARB_TAG_WIDTH-1:0] rsp_tag_q, rsp_tag_d;

  // Lane-0 decode (ALLOC / STATE — single-thread ops).
  logic [63:0] byte_addr0;
  logic [63:0] off0;
  logic        req_is_alloc;
  logic        req_is_state;
  logic        req_is_read;

  // Per-lane decode (stream window).
  logic [NUM_LANES-1:0]                       is_stream_lane;
  wire  [NUM_LANES-1:0]                       push_mask_w;
  logic [NUM_LANES-1:0]                       fifo_push_mask;
  logic [NUM_LANES-1:0][LSU_WORD_SIZE*8-1:0]  push_data;

  wire         any_stream_write_w;
  logic        fifo_push_fire;
  logic        rsp_holding;
  logic        done_fire;

  initial begin
    if (LSU_WORD_SIZE != 8) begin
      $fatal(1, "%s: VX_gemm_job_frontend requires LSU_WORD_SIZE == 8 bytes (64 bits)", INSTANCE_ID);
    end
  end

  function automatic logic [63:0] addr_to_byte(input logic [ADDR_WIDTH-1:0] a);
    begin
      addr_to_byte = (64'(a) << DATA_SIZE_SHIFT);
    end
  endfunction

  function automatic logic [63:0] get_off(input logic [63:0] byte_addr_i);
    begin
      get_off = (byte_addr_i >= CFG_BASE_ADDR)
              ? (byte_addr_i - CFG_BASE_ADDR)
              : 64'hFFFF_FFFF_FFFF_FFFF;
    end
  endfunction

  // Per-lane stream decode: lane k is "stream-active" iff
  //   - mmio request is valid AND a write
  //   - lane mask bit k is set
  //   - lane-k byte address falls in [STREAM_START_OFF_B, STREAM_END_OFF_B)
  // The legacy single-slot lane-0 path is the degenerate case mask=0x01.
  for (genvar k = 0; k < NUM_LANES; ++k) begin : g_lane_decode
    wire [63:0] lane_byte_addr = addr_to_byte(mmio_arb_out[0].req_data.addr[k]);
    wire [63:0] lane_off       = get_off(lane_byte_addr);
    assign is_stream_lane[k]   = (lane_off >= STREAM_START_OFF_B)
                              && (lane_off <  STREAM_END_OFF_B);
    assign push_data[k]        = mmio_arb_out[0].req_data.data[k];
  end

  // Serializer FIFO (multi-push, single-pop).
  logic [FIFO_CNT_W-1:0]      fifo_count;
  logic [FIFO_CNT_W-1:0]      fifo_free;
  logic [LSU_WORD_SIZE*8-1:0] fifo_data_out;
  logic                       fifo_empty;
  logic                       fifo_pop;
  logic [FIFO_PUSHCNT_W-1:0]  push_count;

  // Per-lane push mask: only meaningful for stream writes. Computed as
  // a continuous assignment so it is purely combinational and lives
  // outside the always_comb that drives the read/state path.
  assign push_mask_w        = (mmio_arb_out[0].req_valid && mmio_arb_out[0].req_data.rw)
                            ? (mmio_arb_out[0].req_data.mask & is_stream_lane)
                            : '0;
  assign any_stream_write_w = | push_mask_w;

  VX_popcount #(
    .N (NUM_LANES)
  ) u_push_count (
    .data_in  (push_mask_w),
    .data_out (push_count)
  );

  VX_multi_push_fifo #(
    .WIDTH              (LSU_WORD_SIZE*8),
    .DEPTH              (FIFO_DEPTH),
    .MAX_PUSH_PER_CYCLE (NUM_LANES)
  ) u_serializer (
    .clk        (clk),
    .reset      (reset),
    .push_mask  (fifo_push_mask),
    .data_in    (push_data),
    .pop        (fifo_pop),
    .data_out   (fifo_data_out),
    .empty      (fifo_empty),
    .count      (fifo_count),
    .free_count (fifo_free)
  );

  `UNUSED_VAR (fifo_count)

  // Drive issue interface from FIFO output.
  assign issue_if.inst  = fifo_data_out;
  assign issue_if.valid = ~fifo_empty;
  assign fifo_pop       = (~fifo_empty) & issue_if.ready;

  always_comb begin
    occupied_d      = occupied_q;
    generation_d    = generation_q;
    rsp_valid_d     = rsp_valid_q;
    rsp_mask_d      = rsp_mask_q;
    rsp_data_d      = rsp_data_q;
    rsp_tag_d       = rsp_tag_q;

    byte_addr0   = '0;
    off0         = 64'hFFFF_FFFF_FFFF_FFFF;
    req_is_alloc = 1'b0;
    req_is_state = 1'b0;
    req_is_read  = 1'b0;

    rsp_holding = rsp_valid_q && ~mmio_arb_out[0].rsp_ready;
    done_fire   = done_if.valid && done_if.ready;

    done_if.ready             = 1'b1;
    mmio_arb_out[0].req_ready = ~rsp_holding;

    if (rsp_valid_q && mmio_arb_out[0].rsp_ready) begin
      rsp_valid_d = 1'b0;
      rsp_mask_d  = '0;
      rsp_data_d  = '0;
      rsp_tag_d   = '0;
    end

    if (done_fire) begin
      occupied_d = 1'b0;
    end

    if (mmio_arb_out[0].req_valid) begin
      // Lane-0 decode for read/alloc/state ops.
      byte_addr0   = addr_to_byte(mmio_arb_out[0].req_data.addr[0]);
      off0         = get_off(byte_addr0);
      req_is_alloc = (off0 < 64'(LSU_WORD_SIZE));
      req_is_state = (off0 >= STATE_READ_OFF_B)
                  && (off0 < STATE_READ_OFF_B + 64'(LSU_WORD_SIZE));
      req_is_read  = ~mmio_arb_out[0].req_data.rw;

      // Backpressure for stream writes: hold req_ready off until the FIFO
      // has room for popcount(push_mask) words.  Otherwise the read path
      // logic below applies (single-thread ALLOC/STATE).
      if (any_stream_write_w) begin
        mmio_arb_out[0].req_ready = ~rsp_holding
                                 && occupied_q
                                 && (fifo_free >= FIFO_CNT_W'(push_count));
      end
    end

    // Read response state update happens on accepted handshake.
    if (mmio_arb_out[0].req_valid && mmio_arb_out[0].req_ready) begin
      unique case (1'b1)
        any_stream_write_w: begin
          // FIFO push handled below via fifo_push_mask; nothing to do here.
        end
        req_is_read: begin
          rsp_valid_d = 1'b1;
          rsp_mask_d  = mmio_arb_out[0].req_data.mask;
          rsp_tag_d   = mmio_arb_out[0].req_data.tag;
          rsp_data_d  = '0;

          if (req_is_alloc) begin
            if (~occupied_q) begin
              occupied_d = 1'b1;
              generation_d = generation_q + 30'd1;
              rsp_data_d[0] = {32'b0, generation_d, 1'b1};
            end else begin
              rsp_data_d[0] = {32'b0, generation_q, 1'b0};
            end
          end else if (req_is_state) begin
            rsp_data_d[0] = {32'b0, generation_q, occupied_q};
          end
        end
        default: begin
          // Write to a non-stream offset, or no-op — drop.
        end
      endcase
    end
  end

  // FIFO push fires on accepted stream-write handshake.  Gate the lane
  // mask so the FIFO only sees pushes on actual handshakes.
  assign fifo_push_fire = mmio_arb_out[0].req_valid
                       && mmio_arb_out[0].req_ready
                       && any_stream_write_w;
  assign fifo_push_mask = fifo_push_fire ? push_mask_w : '0;

  always_ff @(posedge clk) begin
    if (reset) begin
      occupied_q  <= 1'b0;
      generation_q <= '0;
      rsp_valid_q <= 1'b0;
      rsp_mask_q  <= '0;
      rsp_data_q  <= '0;
      rsp_tag_q   <= '0;
    end else begin
      occupied_q  <= occupied_d;
      generation_q <= generation_d;
      rsp_valid_q <= rsp_valid_d;
      rsp_mask_q  <= rsp_mask_d;
      rsp_data_q  <= rsp_data_d;
      rsp_tag_q   <= rsp_tag_d;
    end
  end

  assign mmio_arb_out[0].rsp_valid    = rsp_valid_q;
  assign mmio_arb_out[0].rsp_data.mask = rsp_mask_q;
  assign mmio_arb_out[0].rsp_data.data = rsp_data_q;
  assign mmio_arb_out[0].rsp_data.tag  = rsp_tag_q;

endmodule
