`include "VX_define.vh"

//==============================================================================
// VX_dma_unit_misal
//  - cfg_reg_if.DW must be 32
//  - desc word layout (32b words):
//      0  control_reg : [0]=start(valid)
//      1  dst_base_lo
//      2  dst_base_hi
//      3  src_base_lo
//      4  src_base_hi
//      5  src_stride0
//      6  dst_stride0
//      7  src_stride1
//      8  dst_stride1
//      9  src_stride2
//     10  dst_stride2
//     11  bound0
//     12  bound1
//     13  bound2
//     14  seg_size
//     15  padding
//     16  dir_reg     : [0]=direction (0:G2L, 1:L2G)
//     17  reserved
//
//  done_if:
//    - asserted when the whole 3D copy completes for the latched descriptor
//    - holds valid until done_if.ready handshake
//==============================================================================

module VX_dma_unit_misal import VX_gpu_pkg::*; #(
  parameter `STRING INSTANCE_ID = ""
) (
  input wire clk,
  input wire reset,

  VX_config_reg_if.slave cfg_reg_if,     // from LSU (DW=32 expected)

  VX_mem_bus_if.master   dcache_bus_if,  // to dcache
  VX_mem_bus_if.master   lmem_bus_if,    // to local memory

  VX_node_done_if.master done_if
);

  // ------------------------------------------------------------
  // Descriptor layout
  // ------------------------------------------------------------
  localparam int NUM_REGS      = `DMA_CFG_REG_NUM;
  localparam int NDIM          = 3;
  localparam int DESC_DIR_IDX  = 16;

  initial begin
    if (cfg_reg_if.DW != 32) $fatal(1, "cfg_reg_if.DW must be 32");
    if (cfg_reg_if.NUM < NUM_REGS)
      $fatal(1, "cfg_reg_if.NUM(%0d) < NUM_REGS(%0d)", cfg_reg_if.NUM, NUM_REGS);
  end

  // ------------------------------------------------------------
  // Bus widths (bytes per beat)
  // ------------------------------------------------------------
  localparam int DCACHE_BYTES = dcache_bus_if.DATA_SIZE;
  localparam int LMEM_BYTES   = lmem_bus_if.DATA_SIZE;

  localparam int DCACHE_LG2 = `CLOG2(DCACHE_BYTES);
  localparam int LMEM_LG2   = `CLOG2(LMEM_BYTES);

  // NOTE: This window scheme assumes MAX_BYTES=DCACHE_BYTES is enough buffering.
  // If LMEM_BYTES > DCACHE_BYTES, increase WIN_BYTES appropriately.
  localparam int MAX_BYTES    = DCACHE_BYTES;
  localparam int WIN_BYTES    = 2 * MAX_BYTES; // for safe
  localparam int WIN_VALID_W  = `CLOG2(WIN_BYTES + 1);

  function automatic logic [dcache_bus_if.ADDR_WIDTH-1:0] to_dcache_addr(input logic [63:0] byte_addr);
    to_dcache_addr = dcache_bus_if.ADDR_WIDTH'(byte_addr >> DCACHE_LG2);
  endfunction

  function automatic logic [lmem_bus_if.ADDR_WIDTH-1:0] to_lmem_addr(input logic [63:0] byte_addr);
    to_lmem_addr = lmem_bus_if.ADDR_WIDTH'(byte_addr >> LMEM_LG2);
  endfunction

  function automatic logic [31:0] umin32(input logic [31:0] a, input logic [31:0] b);
    return (a < b) ? a : b;
  endfunction

  // per-byte mask of length BUS_BYTES, enable [lane .. lane+nbytes-1]
  function automatic logic [DCACHE_BYTES-1:0] mask_dcache_range(input int lane, input int nbytes);
    logic [DCACHE_BYTES-1:0] m;
    int i;
    begin
      m = '0;
      for (i = 0; i < DCACHE_BYTES; i++) begin
        if ((i >= lane) && (i < (lane + nbytes)))
          m[i] = 1'b1;
      end
      return m;
    end
  endfunction

  function automatic logic [LMEM_BYTES-1:0] mask_lmem_range(input int lane, input int nbytes);
    logic [LMEM_BYTES-1:0] m;
    int i;
    begin
      m = '0;
      for (i = 0; i < LMEM_BYTES; i++) begin
        if ((i >= lane) && (i < (lane + nbytes)))
          m[i] = 1'b1;
      end
      return m;
    end
  endfunction

  // align down / align up
  function automatic logic [63:0] align_down(input logic [63:0] a, input int bytes);
    logic [63:0] mask;
    begin
      mask = 64'(bytes-1);
      return (a & ~mask);
    end
  endfunction

  function automatic logic [63:0] align_up(input logic [63:0] a, input int bytes);
    logic [63:0] m;
    begin
      m = 64'(bytes-1);
      return (a + m) & ~m;
    end
  endfunction

  // ------------------------------------------------------------
  // FSM
  // ------------------------------------------------------------
  typedef enum logic [3:0] {
    S_IDLE,
    S_PRECALC,
    S_PREP_SEG,

    // L2G (LMEM -> DCACHE)
    S_L2G_DECIDE,
    S_L2G_SRC_RD_REQ,
    S_L2G_SRC_RD_WAIT,
    S_L2G_DST_WR_REQ,

    // G2L (DCACHE -> LMEM)
    S_G2L_DECIDE,
    S_G2L_SRC_RD_REQ,
    S_G2L_SRC_RD_WAIT,
    S_G2L_DST_WR_REQ,

    S_ADV_SEG,
    S_DONE
  } state_e;

  state_e state, state_n;

  function automatic string state_to_str(input state_e s);
    case (s)
      S_IDLE:           return "S_IDLE";
      S_PRECALC:        return "S_PRECALC";
      S_PREP_SEG:       return "S_PREP_SEG";
      S_L2G_DECIDE:     return "S_L2G_DECIDE";
      S_L2G_SRC_RD_REQ: return "S_L2G_SRC_RD_REQ";
      S_L2G_SRC_RD_WAIT:return "S_L2G_SRC_RD_WAIT";
      S_L2G_DST_WR_REQ: return "S_L2G_DST_WR_REQ";
      S_G2L_DECIDE:     return "S_G2L_DECIDE";
      S_G2L_SRC_RD_REQ: return "S_G2L_SRC_RD_REQ";
      S_G2L_SRC_RD_WAIT:return "S_G2L_SRC_RD_WAIT";
      S_G2L_DST_WR_REQ: return "S_G2L_DST_WR_REQ";
      S_ADV_SEG:        return "S_ADV_SEG";
      S_DONE:           return "S_DONE";
      default:          return "S_UNKNOWN";
    endcase
  endfunction

  // ------------------------------------------------------------
  // cfg handshake / latch
  // ------------------------------------------------------------
  logic cfg_fire;
  assign cfg_reg_if.ready = (state == S_IDLE);
  assign cfg_fire = cfg_reg_if.valid && cfg_reg_if.ready;

  // Since cfg_reg_if.DW=32, regs_latched[*] is 32-bit.
  logic [cfg_reg_if.NUM-1:0][cfg_reg_if.DW-1:0] regs_latched;
  logic [31:0] entry_id_latched;

  always_ff @(posedge clk) begin
    if (reset) begin
      entry_id_latched <= '0;
      for (int k = 0; k < cfg_reg_if.NUM; k++) regs_latched[k] <= '0;
    end else if (cfg_fire) begin
      entry_id_latched <= cfg_reg_if.entry_id;
      for (int k = 0; k < cfg_reg_if.NUM; k++) regs_latched[k] <= cfg_reg_if.regs[k];
    end
  end

  logic [`UP(UUID_WIDTH)-1:0] dma_uuid;
  assign dma_uuid = `UP(UUID_WIDTH)'(entry_id_latched);

  wire cmd_start = cfg_fire && cfg_reg_if.regs[0][0];

  // Latched descriptor fields (captured atomically at cmd_start)
  logic [63:0] base_addr_r[2];     // [0]=src, [1]=dst
  logic [31:0] stride_r[2][NDIM];  // [src/dst][dim]
  // Precomputed stride * (bound - 1), used for carry-step base address correction.
  logic [63:0] stride_bound_r[2][NDIM];
  logic [31:0] bound_r[NDIM];
  logic [31:0] seg_size_r;
  logic [31:0] padding_r;
  logic        direction_bit_r;    // 0: GLOBAL->LMEM (load), 1: LMEM->GLOBAL (store)
  logic [63:0] base_src_seg_r, base_dst_seg_r;
  logic        precalc_pending_r;

  wire precalc_issue = (state == S_PRECALC) && precalc_pending_r;

  logic [5:0]       precalc_valid;
  logic [5:0][63:0] precalc_result;
  wire              precalc_done = &precalc_valid;

  // 6 parallel pipelined multipliers:
  //   [0] src d0, [1] dst d0, [2] src d1, [3] dst d1, [4] src d2, [5] dst d2
  VX_mul_u32_pipe #(.OUT_REGS(0)) mul_src_d0 (
    .clk(clk),
    .reset(reset),
    .valid_in(precalc_issue),
    .a(stride_r[0][0]),
    .b(bound_r[0] - 32'd1),
    .valid_out(precalc_valid[0]),
    .result(precalc_result[0])
  );

  VX_mul_u32_pipe #(.OUT_REGS(0)) mul_dst_d0 (
    .clk(clk),
    .reset(reset),
    .valid_in(precalc_issue),
    .a(stride_r[1][0]),
    .b(bound_r[0] - 32'd1),
    .valid_out(precalc_valid[1]),
    .result(precalc_result[1])
  );

  VX_mul_u32_pipe #(.OUT_REGS(0)) mul_src_d1 (
    .clk(clk),
    .reset(reset),
    .valid_in(precalc_issue),
    .a(stride_r[0][1]),
    .b(bound_r[1] - 32'd1),
    .valid_out(precalc_valid[2]),
    .result(precalc_result[2])
  );

  VX_mul_u32_pipe #(.OUT_REGS(0)) mul_dst_d1 (
    .clk(clk),
    .reset(reset),
    .valid_in(precalc_issue),
    .a(stride_r[1][1]),
    .b(bound_r[1] - 32'd1),
    .valid_out(precalc_valid[3]),
    .result(precalc_result[3])
  );

  VX_mul_u32_pipe #(.OUT_REGS(0)) mul_src_d2 (
    .clk(clk),
    .reset(reset),
    .valid_in(precalc_issue),
    .a(stride_r[0][2]),
    .b(bound_r[2] - 32'd1),
    .valid_out(precalc_valid[4]),
    .result(precalc_result[4])
  );

  VX_mul_u32_pipe #(.OUT_REGS(0)) mul_dst_d2 (
    .clk(clk),
    .reset(reset),
    .valid_in(precalc_issue),
    .a(stride_r[1][2]),
    .b(bound_r[2] - 32'd1),
    .valid_out(precalc_valid[5]),
    .result(precalc_result[5])
  );

  always_ff @(posedge clk) begin
    if (reset) begin
      base_addr_r[0] <= '0;
      base_addr_r[1] <= '0;
      seg_size_r     <= '0;
      padding_r      <= '0;
      direction_bit_r <= 1'b0;
      precalc_pending_r <= 1'b0;
      for (int d = 0; d < NDIM; d++) begin
        stride_r[0][d] <= '0;
        stride_r[1][d] <= '0;
        stride_bound_r[0][d] <= '0;
        stride_bound_r[1][d] <= '0;
        bound_r[d] <= '0;
      end
    end else if (cmd_start) begin
      if (cfg_reg_if.regs[11][31:0] == 0 ||
          cfg_reg_if.regs[12][31:0] == 0 ||
          cfg_reg_if.regs[13][31:0] == 0) begin
        $fatal(1, "%s: VX_dma_unit_misal: ERROR - bounds cannot be zero!", INSTANCE_ID);
      end

      base_addr_r[0] <= {cfg_reg_if.regs[4][31:0], cfg_reg_if.regs[3][31:0]}; // src
      base_addr_r[1] <= {cfg_reg_if.regs[2][31:0], cfg_reg_if.regs[1][31:0]}; // dst

      for (int d = 0; d < NDIM; d++) begin
        stride_r[0][d] <= cfg_reg_if.regs[5 + 2*d][31:0];
        stride_r[1][d] <= cfg_reg_if.regs[6 + 2*d][31:0];
        bound_r[d]     <= cfg_reg_if.regs[11 + d][31:0];
        stride_bound_r[0][d] <= '0;
        stride_bound_r[1][d] <= '0;
      end

      seg_size_r      <= cfg_reg_if.regs[14][31:0];
      padding_r       <= cfg_reg_if.regs[15][31:0];
      direction_bit_r <= cfg_reg_if.regs[DESC_DIR_IDX][0];
      precalc_pending_r <= 1'b1;
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
    end
  end

  // ------------------------------------------------------------
  // 3D indices + segment byte offset
  // ------------------------------------------------------------
  logic [31:0] i_dim[NDIM];
  logic [31:0] out_off; // bytes within current segment [0 .. seg_size)

  // segment completion latch (for S_ADV_SEG -> S_DONE)
  logic finished;

  // ------------------------------------------------------------
  // Base address per segment (byte)
  // ------------------------------------------------------------
  logic [63:0] base_src_seg, base_dst_seg;

  // Segment bases are maintained incrementally in S_ADV_SEG to avoid per-cycle 64-bit mul/add.
  assign base_src_seg = base_src_seg_r;
  assign base_dst_seg = base_dst_seg_r;

  // ------------------------------------------------------------
  // valid/padding boundary
  // ------------------------------------------------------------
  logic [31:0] valid_total;
  assign valid_total = (seg_size_r > padding_r) ? (seg_size_r - padding_r) : 32'd0;

  // ------------------------------------------------------------
  // Window buffers (streaming) for misaligned support
  //   - win_* LSB = stream head
  // ------------------------------------------------------------
  logic [WIN_BYTES*8-1:0]  win_lmem;
  logic [WIN_VALID_W-1:0]  win_lmem_valid;
  logic [63:0]             lmem_rd_ptr;   // aligned byte addr
  logic [63:0]             lmem_rd_end;   // aligned end (exclusive)
  logic [31:0]             lmem_drop;     // initial misalign bytes to drop

  logic [WIN_BYTES*8-1:0]  win_dcache;
  logic [WIN_VALID_W-1:0]  win_dcache_valid;
  logic [63:0]             dcache_rd_ptr;
  logic [63:0]             dcache_rd_end;
  logic [31:0]             dcache_drop;

  // ------------------------------------------------------------
  // Handshake helpers
  // ------------------------------------------------------------
  wire dcache_req_fire = dcache_bus_if.req_valid && dcache_bus_if.req_ready;
  wire lmem_req_fire   = lmem_bus_if.req_valid   && lmem_bus_if.req_ready;

  wire dcache_rsp_fire = dcache_bus_if.rsp_valid && dcache_bus_if.rsp_ready;
  wire lmem_rsp_fire   = lmem_bus_if.rsp_valid   && lmem_bus_if.rsp_ready;

  // ------------------------------------------------------------
  // Trace logging
  // ------------------------------------------------------------
`ifdef DBG_TRACE_GEMM_CTRL
  always_ff @(posedge clk) begin
    if (!reset) begin
      if (state != state_n) begin
        `TRACE(3, ("%m : [%0t] | DMA_STATE_TRANSITION | {inst=%s, from=%s, to=%s, out_off=%0d, finished=%0d, i0=%0d, i1=%0d, i2=%0d}\n",
                  $time, INSTANCE_ID, state_to_str(state), state_to_str(state_n),
                  out_off, finished, i_dim[0], i_dim[1], i_dim[2]))
      end

      if (cmd_start) begin
        `TRACE(2, ("%m : [%0t] | DMA_START | {inst=%s, entry_id=%0d, dir=%0d, src_base=0x%0h, dst_base=0x%0h, seg_size=%0d, padding=%0d, bound=[%0d,%0d,%0d]}\n",
                  $time, INSTANCE_ID, cfg_reg_if.entry_id, cfg_reg_if.regs[DESC_DIR_IDX][0],
                  {cfg_reg_if.regs[4][31:0], cfg_reg_if.regs[3][31:0]},
                  {cfg_reg_if.regs[2][31:0], cfg_reg_if.regs[1][31:0]},
                  cfg_reg_if.regs[14][31:0], cfg_reg_if.regs[15][31:0],
                  cfg_reg_if.regs[11][31:0], cfg_reg_if.regs[12][31:0], cfg_reg_if.regs[13][31:0]))
        for (int k = 0; k < NUM_REGS; k++) begin
          `TRACE(3, ("%m : [%0t] | DMA_START_REG | {inst=%s, reg_idx=%0d, reg_val=0x%08h}\n", $time, INSTANCE_ID, k, cfg_reg_if.regs[k][31:0]))
        end
      end
    end
  end
`endif

`ifdef DBG_TRACE_GEMM
  always_ff @(posedge clk) begin
    if (!reset) begin
      if (precalc_issue) begin
        logic [31:0] b0m1, b1m1, b2m1;
        b0m1 = bound_r[0] - 32'd1;
        b1m1 = bound_r[1] - 32'd1;
        b2m1 = bound_r[2] - 32'd1;
        `TRACE(2, ("%m : [%0t] | DMA_SETUP_MUL_ISSUE | {inst=%s, src_stride0=%0d, src_bound0_m1=%0d, src_stride1=%0d, src_bound1_m1=%0d, src_stride2=%0d, src_bound2_m1=%0d, dst_stride0=%0d, dst_bound0_m1=%0d, dst_stride1=%0d, dst_bound1_m1=%0d, dst_stride2=%0d, dst_bound2_m1=%0d}\n",
                  $time, INSTANCE_ID,
                  stride_r[0][0], b0m1, stride_r[0][1], b1m1, stride_r[0][2], b2m1,
                  stride_r[1][0], b0m1, stride_r[1][1], b1m1, stride_r[1][2], b2m1))
      end

      if (precalc_done) begin
        `TRACE(2, ("%m : [%0t] | DMA_SETUP_MUL_DONE | {inst=%s, src_stride_bound0=0x%0h, src_stride_bound1=0x%0h, src_stride_bound2=0x%0h, dst_stride_bound0=0x%0h, dst_stride_bound1=0x%0h, dst_stride_bound2=0x%0h}\n",
                  $time, INSTANCE_ID,
                  precalc_result[0], precalc_result[2], precalc_result[4],
                  precalc_result[1], precalc_result[3], precalc_result[5]))
      end

      if (state == S_PREP_SEG && !finished) begin
        logic [63:0] src_rd_ptr_aligned;
        logic [63:0] src_rd_end_aligned;
        logic [31:0] src_drop_bytes;
        src_rd_ptr_aligned = direction_bit_r ? align_down(base_src_seg, LMEM_BYTES) : align_down(base_src_seg, DCACHE_BYTES);
        src_rd_end_aligned = direction_bit_r ? align_up(base_src_seg + 64'(valid_total), LMEM_BYTES)
                                             : align_up(base_src_seg + 64'(valid_total), DCACHE_BYTES);
        src_drop_bytes = direction_bit_r ? 32'(base_src_seg & 64'(LMEM_BYTES-1))
                                         : 32'(base_src_seg & 64'(DCACHE_BYTES-1));
        `TRACE(2, ("%m : [%0t] | DMA_SEG_PREP | {inst=%s, mode=%s, i0=%0d, i1=%0d, i2=%0d, src_base=0x%0h, dst_base=0x%0h, seg_size=%0d, valid_total=%0d, padding=%0d, src_drop=%0d, src_rd_ptr=0x%0h, src_rd_end=0x%0h}\n",
                  $time, INSTANCE_ID, direction_bit_r ? "L2G" : "G2L",
                  i_dim[0], i_dim[1], i_dim[2], base_src_seg, base_dst_seg,
                  seg_size_r, valid_total, padding_r, src_drop_bytes, src_rd_ptr_aligned, src_rd_end_aligned))
      end

      if (state == S_L2G_SRC_RD_REQ && lmem_req_fire) begin
        `TRACE(2, ("%m : [%0t] | DMA_RUN_L2G_RD_REQ_LMEM | {inst=%s, addr=0x%0h, byte_addr=0x%0h, tag=0x%0h, out_off=%0d}\n",
                  $time, INSTANCE_ID, lmem_bus_if.req_data.addr,
                  (64'(lmem_bus_if.req_data.addr) << LMEM_LG2), lmem_bus_if.req_data.tag, out_off))
      end

      if (state == S_L2G_SRC_RD_WAIT && lmem_rsp_fire) begin
        `TRACE(2, ("%m : [%0t] | DMA_RUN_L2G_RD_RSP_LMEM | {inst=%s, data=0x%0h, tag=0x%0h, win_valid=%0d}\n",
                  $time, INSTANCE_ID, lmem_bus_if.rsp_data.data, lmem_bus_if.rsp_data.tag, win_lmem_valid))
      end

      if (state == S_L2G_DST_WR_REQ && dcache_req_fire) begin
        `TRACE(2, ("%m : [%0t] | DMA_RUN_L2G_WR_REQ_DCACHE | {inst=%s, addr=0x%0h, byte_addr=0x%0h, byteen=0x%0h, data=0x%0h, tag=0x%0h, out_off=%0d}\n",
                  $time, INSTANCE_ID, dcache_bus_if.req_data.addr,
                  (64'(dcache_bus_if.req_data.addr) << DCACHE_LG2),
                  dcache_bus_if.req_data.byteen, dcache_bus_if.req_data.data, dcache_bus_if.req_data.tag, out_off))
      end

      if (state == S_G2L_SRC_RD_REQ && dcache_req_fire) begin
        `TRACE(2, ("%m : [%0t] | DMA_RUN_G2L_RD_REQ_DCACHE | {inst=%s, addr=0x%0h, byte_addr=0x%0h, tag=0x%0h, out_off=%0d}\n",
                  $time, INSTANCE_ID, dcache_bus_if.req_data.addr,
                  (64'(dcache_bus_if.req_data.addr) << DCACHE_LG2), dcache_bus_if.req_data.tag, out_off))
      end

      if (state == S_G2L_SRC_RD_WAIT && dcache_rsp_fire) begin
        `TRACE(2, ("%m : [%0t] | DMA_RUN_G2L_RD_RSP_DCACHE | {inst=%s, data=0x%0h, tag=0x%0h, win_valid=%0d}\n",
                  $time, INSTANCE_ID, dcache_bus_if.rsp_data.data, dcache_bus_if.rsp_data.tag, win_dcache_valid))
      end

      if (state == S_G2L_DST_WR_REQ && lmem_req_fire) begin
        `TRACE(2, ("%m : [%0t] | DMA_RUN_G2L_WR_REQ_LMEM | {inst=%s, addr=0x%0h, byte_addr=0x%0h, byteen=0x%0h, data=0x%0h, tag=0x%0h, out_off=%0d}\n",
                  $time, INSTANCE_ID, lmem_bus_if.req_data.addr,
                  (64'(lmem_bus_if.req_data.addr) << LMEM_LG2),
                  lmem_bus_if.req_data.byteen, lmem_bus_if.req_data.data, lmem_bus_if.req_data.tag, out_off))
      end

      if (state == S_ADV_SEG && out_off >= seg_size_r) begin
        logic will_finish;
        will_finish = (bound_r[0] == 0 || bound_r[1] == 0 || bound_r[2] == 0)
                   || ((i_dim[0] + 32'd1 >= bound_r[0])
                    && (i_dim[1] + 32'd1 >= bound_r[1])
                    && (i_dim[2] + 32'd1 >= bound_r[2]));
        `TRACE(2, ("%m : [%0t] | DMA_SEG_ADVANCE | {inst=%s, i0=%0d, i1=%0d, i2=%0d, bound0=%0d, bound1=%0d, bound2=%0d, src_base=0x%0h, dst_base=0x%0h, seg_size=%0d, out_off=%0d, will_finish=%0d}\n",
                  $time, INSTANCE_ID, i_dim[0], i_dim[1], i_dim[2],
                  bound_r[0], bound_r[1], bound_r[2], base_src_seg, base_dst_seg,
                  seg_size_r, out_off, will_finish))
      end

      if (state != S_DONE && state_n == S_DONE) begin
        `TRACE(2, ("%m : [%0t] | DMA_DONE_ASSERT | {inst=%s, entry_id=%0d, i0=%0d, i1=%0d, i2=%0d}\n",
                  $time, INSTANCE_ID, entry_id_latched, i_dim[0], i_dim[1], i_dim[2]))
      end

      if (state == S_DONE && done_if.ready) begin
        `TRACE(2, ("%m : [%0t] | DMA_DONE_HANDSHAKE | {inst=%s, entry_id=%0d}\n",
                  $time, INSTANCE_ID, entry_id_latched))
      end
    end
  end
`endif

  // ------------------------------------------------------------
  // done_if (combinational)
  // ------------------------------------------------------------
  always_comb begin
    done_if.valid = 1'b0;
    done_if.entry_id = entry_id_latched;
    
    if (state == S_DONE)
      done_if.valid = 1'b1;
  end

  // ------------------------------------------------------------
  // Combinational bus driving + next state
  // ------------------------------------------------------------
  always_comb begin
    // defaults
    dcache_bus_if.req_valid = 1'b0;
    dcache_bus_if.req_data  = '0;
    dcache_bus_if.rsp_ready = 1'b1;

    lmem_bus_if.req_valid = 1'b0;
    lmem_bus_if.req_data  = '0;
    lmem_bus_if.rsp_ready = 1'b1;

    state_n = state;

    unique case (state)
      S_IDLE: begin
        if (cmd_start) state_n = S_PRECALC;
      end

      S_PRECALC: begin
        if (precalc_done)
          state_n = S_PREP_SEG;
      end

      S_PREP_SEG: begin
        // finished is computed/latched in sequential block at the moment indices wrap
        if (finished) state_n = S_DONE;
        else begin
          if (direction_bit_r) state_n = S_L2G_DECIDE;
          else               state_n = S_G2L_DECIDE;
        end        
      end

      // ==========================================================
      // L2G (LMEM -> DCACHE)
      // ==========================================================
      S_L2G_DECIDE: begin
        if ((lmem_drop != 0) && (win_lmem_valid >= lmem_drop[WIN_VALID_W-1:0])) begin
          state_n = S_L2G_DECIDE; // stay; next cycle window aligned
        end else begin
          logic [63:0] dst_byte;
          int          lane;
          logic [31:0] remaining;
          logic [31:0] beat_room;
          logic [31:0] wr_nbytes;
          logic [31:0] need_src;

          dst_byte   = base_dst_seg + 64'(out_off);
          lane       = int'(dst_byte[DCACHE_LG2-1:0]);
          remaining  = (out_off < seg_size_r) ? (seg_size_r - out_off) : 32'd0;
          beat_room  = DCACHE_BYTES - lane;
          wr_nbytes  = umin32(remaining, beat_room);

          if (out_off >= valid_total) need_src = 32'd0;
          else                        need_src = umin32(valid_total - out_off, wr_nbytes);

          if ((need_src > win_lmem_valid) && (lmem_rd_ptr < lmem_rd_end)) begin
            state_n = S_L2G_SRC_RD_REQ;
          end else begin
            state_n = S_L2G_DST_WR_REQ;
          end
        end
      end

      S_L2G_SRC_RD_REQ: begin
        lmem_bus_if.req_valid          = 1'b1;
        lmem_bus_if.req_data.rw        = 1'b0;
        lmem_bus_if.req_data.addr      = to_lmem_addr(lmem_rd_ptr);
        lmem_bus_if.req_data.byteen    = '0;
        lmem_bus_if.req_data.flags     = '0;
        lmem_bus_if.req_data.tag.uuid  = dma_uuid;
        lmem_bus_if.req_data.tag.value = '0;
        if (lmem_bus_if.req_ready) state_n = S_L2G_SRC_RD_WAIT;
      end

      S_L2G_SRC_RD_WAIT: begin
        if (lmem_rsp_fire) state_n = S_L2G_DECIDE;
      end

      S_L2G_DST_WR_REQ: begin
        logic [63:0] dst_byte;
        int          lane;
        logic [31:0] remaining;
        logic [31:0] beat_room;
        logic [31:0] wr_nbytes;
        logic [31:0] src_bytes;
        logic [DCACHE_BYTES*8-1:0] wr_data;
        logic [DCACHE_BYTES-1:0]   wr_byteen;

        dst_byte   = base_dst_seg + 64'(out_off);
        lane       = int'(dst_byte[DCACHE_LG2-1:0]);
        remaining  = (out_off < seg_size_r) ? (seg_size_r - out_off) : 32'd0;
        beat_room  = DCACHE_BYTES - lane;
        wr_nbytes  = umin32(remaining, beat_room);

        if (out_off >= valid_total) src_bytes = 32'd0;
        else                        src_bytes = umin32(valid_total - out_off, wr_nbytes);

        wr_data = '0;
        for (int b = 0; b < DCACHE_BYTES; b++) begin
          if ((b >= lane) && (b < lane + int'(wr_nbytes))) begin
            if ((b - lane) < int'(src_bytes)) wr_data[b*8 +: 8] = win_lmem[(b - lane)*8 +: 8];
            else                              wr_data[b*8 +: 8] = 8'h00;
          end
        end

        wr_byteen = mask_dcache_range(lane, int'(wr_nbytes));

        dcache_bus_if.req_valid          = 1'b1;
        dcache_bus_if.req_data.rw        = 1'b1;
        dcache_bus_if.req_data.addr      = to_dcache_addr(dst_byte - 64'(lane)); // beat-aligned
        dcache_bus_if.req_data.data      = wr_data;
        dcache_bus_if.req_data.byteen    = wr_byteen;
        dcache_bus_if.req_data.flags     = '0;
        dcache_bus_if.req_data.tag.uuid  = dma_uuid;
        dcache_bus_if.req_data.tag.value = '0;

        if (dcache_bus_if.req_ready) begin
            if (out_off + wr_nbytes >= seg_size_r) state_n = S_ADV_SEG;
            else                                 state_n = S_L2G_DECIDE;
        end
      end
  
      // ==========================================================
      // G2L (DCACHE -> LMEM)
      // ==========================================================
      S_G2L_DECIDE: begin
        if ((dcache_drop != 0) && (win_dcache_valid >= dcache_drop[WIN_VALID_W-1:0])) begin
          state_n = S_G2L_DECIDE;
        end else begin
          logic [63:0] dst_byte;
          int          lane;
          logic [31:0] remaining;
          logic [31:0] beat_room;
          logic [31:0] wr_nbytes;
          logic [31:0] need_src;

          dst_byte   = base_dst_seg + 64'(out_off);
          lane       = int'(dst_byte[LMEM_LG2-1:0]);
          remaining  = (out_off < seg_size_r) ? (seg_size_r - out_off) : 32'd0;
          beat_room  = LMEM_BYTES - lane;
          wr_nbytes  = umin32(remaining, beat_room);

          if (out_off >= valid_total) need_src = 32'd0;
          else                        need_src = umin32(valid_total - out_off, wr_nbytes);

          if ((need_src > win_dcache_valid) && (dcache_rd_ptr < dcache_rd_end)) begin
            state_n = S_G2L_SRC_RD_REQ;
          end else begin
            state_n = S_G2L_DST_WR_REQ;
          end
        end
      end

      S_G2L_SRC_RD_REQ: begin
        dcache_bus_if.req_valid          = 1'b1;
        dcache_bus_if.req_data.rw        = 1'b0;
        dcache_bus_if.req_data.addr      = to_dcache_addr(dcache_rd_ptr);
        dcache_bus_if.req_data.byteen    = '0;
        dcache_bus_if.req_data.flags     = '0;
        dcache_bus_if.req_data.tag.uuid  = dma_uuid;
        dcache_bus_if.req_data.tag.value = '0;
        if (dcache_bus_if.req_ready) state_n = S_G2L_SRC_RD_WAIT;
      end

      S_G2L_SRC_RD_WAIT: begin
        if (dcache_rsp_fire) state_n = S_G2L_DECIDE;
      end

      S_G2L_DST_WR_REQ: begin
        logic [63:0] dst_byte;
        int          lane;
        logic [31:0] remaining;
        logic [31:0] beat_room;
        logic [31:0] wr_nbytes;
        logic [31:0] src_bytes;
        logic [LMEM_BYTES*8-1:0] wr_data;
        logic [LMEM_BYTES-1:0]   wr_byteen;

        dst_byte   = base_dst_seg + 64'(out_off);
        lane       = int'(dst_byte[LMEM_LG2-1:0]);
        remaining  = (out_off < seg_size_r) ? (seg_size_r - out_off) : 32'd0;
        beat_room  = LMEM_BYTES - lane;
        wr_nbytes  = umin32(remaining, beat_room);

        if (out_off >= valid_total) src_bytes = 32'd0;
        else                        src_bytes = umin32(valid_total - out_off, wr_nbytes);

        wr_data = '0;
        for (int b = 0; b < LMEM_BYTES; b++) begin
          if ((b >= lane) && (b < lane + int'(wr_nbytes))) begin
            if ((b - lane) < int'(src_bytes)) wr_data[b*8 +: 8] = win_dcache[(b - lane)*8 +: 8];
            else                              wr_data[b*8 +: 8] = 8'h00;
          end
        end

        wr_byteen = mask_lmem_range(lane, int'(wr_nbytes));

        lmem_bus_if.req_valid          = 1'b1;
        lmem_bus_if.req_data.rw        = 1'b1;
        lmem_bus_if.req_data.addr      = to_lmem_addr(dst_byte - 64'(lane));
        lmem_bus_if.req_data.data      = wr_data;
        lmem_bus_if.req_data.byteen    = wr_byteen;
        lmem_bus_if.req_data.flags     = '0;
        lmem_bus_if.req_data.tag.uuid  = dma_uuid;
        lmem_bus_if.req_data.tag.value = '0;

        // local mem may not return write response
        if (lmem_bus_if.req_ready) begin
          if (out_off + wr_nbytes >= seg_size_r) state_n = S_ADV_SEG;
          else                                 state_n = S_G2L_DECIDE;
        end
      end

      // ==========================================================
      // advance segment / 3D loop
      // ==========================================================
      S_ADV_SEG: begin
        state_n = S_PREP_SEG;
      end

      S_DONE: begin
        // Hold done_if.valid until handshake
        if (done_if.ready) state_n = S_IDLE;
        else               state_n = S_DONE;
      end

      default: state_n = S_IDLE;
    endcase
  end

  // ------------------------------------------------------------
  // Sequential: state, counters, windows, pointers
  // ------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (reset) begin
      state <= S_IDLE;
      
      base_src_seg_r <= '0;
      base_dst_seg_r <= '0;

      for (int d = 0; d < NDIM; d++) i_dim[d] <= '0;
      out_off   <= '0;
      finished  <= 1'b0;

      win_lmem       <= '0;
      win_lmem_valid <= '0;
      lmem_rd_ptr    <= '0;
      lmem_rd_end    <= '0;
      lmem_drop      <= '0;

      win_dcache       <= '0;
      win_dcache_valid <= '0;
      dcache_rd_ptr    <= '0;
      dcache_rd_end    <= '0;
      dcache_drop      <= '0;
      base_src_seg_r   <= '0;
      base_dst_seg_r   <= '0;

    end else begin
      state <= state_n;

      // -------------------------
      // Start: init 3D + seg offset
      // -------------------------
      if (cmd_start) begin
        i_dim[0]  <= 32'd0;
        i_dim[1]  <= 32'd0;
        i_dim[2]  <= 32'd0;
        out_off   <= 32'd0;
        finished  <= 1'b0;
        base_src_seg_r <= {cfg_reg_if.regs[4][31:0], cfg_reg_if.regs[3][31:0]};
        base_dst_seg_r <= {cfg_reg_if.regs[2][31:0], cfg_reg_if.regs[1][31:0]};
      end

      // After DONE handshake, clear finished for safety
      if (state == S_DONE && done_if.valid && done_if.ready) begin
        finished <= 1'b0;
      end

      // -------------------------
      // Prepare segment: reset windows & init src read pointers based on direction
      // -------------------------
      if (state == S_PREP_SEG) begin
        out_off <= 32'd0;

        win_lmem       <= '0;
        win_lmem_valid <= '0;
        win_dcache       <= '0;
        win_dcache_valid <= '0;

        // reset drops by default (important!)
        lmem_drop   <= 32'd0;
        dcache_drop <= 32'd0;

        if (direction_bit_r) begin
          // L2G: source=LMEM
          lmem_drop   <= (base_src_seg & 64'(LMEM_BYTES-1));
          lmem_rd_ptr <= align_down(base_src_seg, LMEM_BYTES);
          lmem_rd_end <= align_up(base_src_seg + 64'(valid_total), LMEM_BYTES);
        end else begin
          // G2L: source=DCACHE
          dcache_drop  <= (base_src_seg & 64'(DCACHE_BYTES-1));
          dcache_rd_ptr <= align_down(base_src_seg, DCACHE_BYTES);
          dcache_rd_end <= align_up(base_src_seg + 64'(valid_total), DCACHE_BYTES);
        end
      end

      // ==========================================================
      // L2G: capture LMEM read responses into window (append)
      // ==========================================================
      if (state == S_L2G_SRC_RD_WAIT && lmem_rsp_fire) begin
        if (win_lmem_valid + LMEM_BYTES <= WIN_BYTES) begin
          win_lmem[win_lmem_valid*8 +: (LMEM_BYTES*8)] <= lmem_bus_if.rsp_data.data;
          win_lmem_valid <= win_lmem_valid + LMEM_BYTES[WIN_VALID_W-1:0];
        end
        lmem_rd_ptr <= lmem_rd_ptr + LMEM_BYTES;
      end

      // drop initial misalignment bytes once we have enough
      if ((state == S_L2G_DECIDE || state == S_L2G_SRC_RD_WAIT)
          && (lmem_drop != 0) && (win_lmem_valid >= lmem_drop[WIN_VALID_W-1:0])) begin
        win_lmem       <= win_lmem >> (int'(lmem_drop) * 8);
        win_lmem_valid <= win_lmem_valid - lmem_drop[WIN_VALID_W-1:0];
        lmem_drop      <= 32'd0;
      end

      // ==========================================================
      // L2G: after DCACHE write response, consume src bytes + advance out_off
      // ==========================================================
      if (state == S_L2G_DST_WR_REQ && dcache_req_fire) begin
        logic [63:0] dst_byte;
        int          lane;
        logic [31:0] remaining;
        logic [31:0] beat_room;
        logic [31:0] wr_nbytes;
        logic [31:0] src_bytes;

        dst_byte   = base_dst_seg + 64'(out_off);
        lane       = int'(dst_byte[DCACHE_LG2-1:0]);
        remaining  = (out_off < seg_size_r) ? (seg_size_r - out_off) : 32'd0;
        beat_room  = DCACHE_BYTES - lane;
        wr_nbytes  = umin32(remaining, beat_room);

        if (out_off >= valid_total) src_bytes = 32'd0;
        else                        src_bytes = umin32(valid_total - out_off, wr_nbytes);

        if (src_bytes != 0) begin
          win_lmem       <= win_lmem >> (int'(src_bytes) * 8);
          win_lmem_valid <= win_lmem_valid - src_bytes[WIN_VALID_W-1:0];
        end

        out_off <= out_off + wr_nbytes;
      end

      // ==========================================================
      // G2L: capture DCACHE read responses into window (append)
      // ==========================================================
      if (state == S_G2L_SRC_RD_WAIT && dcache_rsp_fire) begin
        if (win_dcache_valid + DCACHE_BYTES <= WIN_BYTES) begin
          win_dcache[win_dcache_valid*8 +: (DCACHE_BYTES*8)] <= dcache_bus_if.rsp_data.data;
          win_dcache_valid <= win_dcache_valid + DCACHE_BYTES[WIN_VALID_W-1:0];
        end
        dcache_rd_ptr <= dcache_rd_ptr + DCACHE_BYTES;
      end

      // drop initial misalignment bytes once we have enough
      if ((state == S_G2L_DECIDE || state == S_G2L_SRC_RD_WAIT)
          && (dcache_drop != 0) && (win_dcache_valid >= dcache_drop[WIN_VALID_W-1:0])) begin
        win_dcache       <= win_dcache >> (int'(dcache_drop) * 8);
        win_dcache_valid <= win_dcache_valid - dcache_drop[WIN_VALID_W-1:0];
        dcache_drop      <= 32'd0;
      end

      // ==========================================================
      // G2L: after LMEM write request fire, consume src bytes + advance out_off
      // ==========================================================
      if (state == S_G2L_DST_WR_REQ && lmem_req_fire) begin
        logic [63:0] dst_byte;
        int          lane;
        logic [31:0] remaining;
        logic [31:0] beat_room;
        logic [31:0] wr_nbytes;
        logic [31:0] src_bytes;

        dst_byte   = base_dst_seg + 64'(out_off);
        lane       = int'(dst_byte[LMEM_LG2-1:0]);
        remaining  = (out_off < seg_size_r) ? (seg_size_r - out_off) : 32'd0;
        beat_room  = LMEM_BYTES - lane;
        wr_nbytes  = umin32(remaining, beat_room);

        if (out_off >= valid_total) src_bytes = 32'd0;
        else                        src_bytes = umin32(valid_total - out_off, wr_nbytes);

        if (src_bytes != 0) begin
          win_dcache       <= win_dcache >> (int'(src_bytes) * 8);
          win_dcache_valid <= win_dcache_valid - src_bytes[WIN_VALID_W-1:0];
        end

        out_off <= out_off + wr_nbytes;
      end

      // ==========================================================
      // Segment done -> advance 3D indices (in S_ADV_SEG)
      //   - DO NOT write state here (single-driver discipline)
      //   - Set finished when the last segment completes
      // ==========================================================
      if (state == S_ADV_SEG) begin
        if (out_off >= seg_size_r) begin
          out_off  <= 32'd0;
          finished <= 1'b0;

          if (bound_r[0] == 0 || bound_r[1] == 0 || bound_r[2] == 0) begin
            // degenerate: no work, treat as finished
            finished <= 1'b1;
            i_dim[0] <= 32'd0;
            i_dim[1] <= 32'd0;
            i_dim[2] <= 32'd0;
          end else if (i_dim[0] + 1 < bound_r[0]) begin
            i_dim[0] <= i_dim[0] + 1;
            base_src_seg_r <= base_src_seg_r + 64'(stride_r[0][0]);
            base_dst_seg_r <= base_dst_seg_r + 64'(stride_r[1][0]);
          end else begin
            i_dim[0] <= 32'd0;
            if (i_dim[1] + 1 < bound_r[1]) begin
              i_dim[1] <= i_dim[1] + 1;
              base_src_seg_r <= base_src_seg_r + 64'(stride_r[0][1]) - stride_bound_r[0][0];
              base_dst_seg_r <= base_dst_seg_r + 64'(stride_r[1][1]) - stride_bound_r[1][0];
            end else begin
              i_dim[1] <= 32'd0;
              if (i_dim[2] + 1 < bound_r[2]) begin
                i_dim[2] <= i_dim[2] + 1;
                base_src_seg_r <= base_src_seg_r + 64'(stride_r[0][2]) - stride_bound_r[0][1] - stride_bound_r[0][0];
                base_dst_seg_r <= base_dst_seg_r + 64'(stride_r[1][2]) - stride_bound_r[1][1] - stride_bound_r[1][0];
              end else begin
                i_dim[2] <= 32'd0;
                finished <= 1'b1;
              end
            end
          end
        end
      end

    end
  end

`ifdef CHIPSCOPE
`ifdef DBG_SCOPE_GEMM
  localparam int DBG_DMA_UNIT_P0_W = $bits({
      reset,
      cfg_reg_if.valid,
      cfg_reg_if.ready,
      cfg_fire,
      cmd_start,
      precalc_issue,
      precalc_done,
      direction_bit_r,
      finished,
      (state == S_DONE),
      done_if.ready,
      dcache_bus_if.req_valid,
      dcache_bus_if.req_ready,
      dcache_bus_if.rsp_valid,
      dcache_bus_if.rsp_ready,
      lmem_bus_if.req_valid,
      lmem_bus_if.req_ready,
      lmem_bus_if.rsp_valid,
      lmem_bus_if.rsp_ready,
      dcache_req_fire,
      lmem_req_fire,
      dcache_rsp_fire,
      lmem_rsp_fire,
      state,
      state_n
  });
  localparam int DBG_DMA_UNIT_P1_W = $bits({
      32'(entry_id_latched),
      out_off,
      seg_size_r,
      valid_total,
      i_dim[0],
      i_dim[1],
      i_dim[2]
  });
  localparam int DBG_DMA_UNIT_P2_W = $bits({
      base_src_seg,
      base_dst_seg,
      lmem_rd_ptr,
      lmem_rd_end,
      dcache_rd_ptr,
      dcache_rd_end
  });
  localparam int DBG_DMA_UNIT_P3_W = $bits({
      lmem_drop,
      dcache_drop,
      bound_r[0],
      bound_r[1],
      bound_r[2],
      stride_r[0][0],
      stride_r[1][0]
  });

  (* keep = "true", mark_debug = "true" *) wire [DBG_DMA_UNIT_P0_W-1:0] dbg_dma_unit_probe0 = {
      reset,
      cfg_reg_if.valid,
      cfg_reg_if.ready,
      cfg_fire,
      cmd_start,
      precalc_issue,
      precalc_done,
      direction_bit_r,
      finished,
      (state == S_DONE),
      done_if.ready,
      dcache_bus_if.req_valid,
      dcache_bus_if.req_ready,
      dcache_bus_if.rsp_valid,
      dcache_bus_if.rsp_ready,
      lmem_bus_if.req_valid,
      lmem_bus_if.req_ready,
      lmem_bus_if.rsp_valid,
      lmem_bus_if.rsp_ready,
      dcache_req_fire,
      lmem_req_fire,
      dcache_rsp_fire,
      lmem_rsp_fire,
      state,
      state_n
  };
  (* keep = "true", mark_debug = "true" *) wire [DBG_DMA_UNIT_P1_W-1:0] dbg_dma_unit_probe1 = {
      32'(entry_id_latched),
      out_off,
      seg_size_r,
      valid_total,
      i_dim[0],
      i_dim[1],
      i_dim[2]
  };
  (* keep = "true", mark_debug = "true" *) wire [DBG_DMA_UNIT_P2_W-1:0] dbg_dma_unit_probe2 = {
      base_src_seg,
      base_dst_seg,
      lmem_rd_ptr,
      lmem_rd_end,
      dcache_rd_ptr,
      dcache_rd_end
  };
  (* keep = "true", mark_debug = "true" *) wire [DBG_DMA_UNIT_P3_W-1:0] dbg_dma_unit_probe3 = {
      lmem_drop,
      dcache_drop,
      bound_r[0],
      bound_r[1],
      bound_r[2],
      stride_r[0][0],
      stride_r[1][0]
  };

  ila_dma_unit_misal ila_dma_unit_misal_inst (
    .clk    (clk),
    .probe0 (dbg_dma_unit_probe0),
    .probe1 (dbg_dma_unit_probe1),
    .probe2 (dbg_dma_unit_probe2),
    .probe3 (dbg_dma_unit_probe3)
  );
`endif
`endif

endmodule
