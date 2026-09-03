`include "VX_define.vh"

//==============================================================================
// VX_dma_unit_align
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

module VX_dma_unit_align import VX_gpu_pkg::*; #(
  parameter `STRING INSTANCE_ID = "",
  parameter bit ENABLE_PADDING = 1'b1,
  parameter int BOUND_WIDTH = `DMA_BOUND_WIDTH,
  parameter int MAX_DIMS = 3,
  // Parent forwards interface ADDR_WIDTH and TAG_WIDTH values explicitly. Synopsys DC
  // rejects `interface_inst.PARAM` access inside localparam initializers,
  // so we cannot read those parameters directly here.
  parameter int DCACHE_ADDR_WIDTH = 1,
  parameter int LMEM_ADDR_WIDTH   = 1,
  parameter int DCACHE_TAG_WIDTH = 1,
  parameter int LMEM_TAG_WIDTH   = 1,
  parameter int RD_OUTSTANDING = 2,
  parameter bit ENABLE_1D_WRITE_COUNTER = 1'b0,
  // -1: use descriptor direction, 0/1: compile-time fixed direction.
  parameter int FIXED_DIR = -1
) (
  input wire clk,
  input wire reset,

  VX_config_reg_if.slave cfg_reg_if,     // from LSU (DW=32 expected)
  VX_dma_lookahead_if.slave lookahead_if,

  VX_mem_bus_if.master   dcache_bus_if,  // to dcache
  VX_mem_bus_if.master   lmem_bus_if,    // to local memory

  VX_node_done_if.master done_if
`ifdef PERF_ENABLE
  ,output dma_perf_t perf
`endif
);

  // ------------------------------------------------------------
  // Descriptor layout
  // ------------------------------------------------------------
  localparam int NUM_REGS      = `DMA_CFG_REG_NUM;
  localparam int NDIM          = 3;
  localparam int DESC_DIR_IDX  = 16;
  localparam int CORRECTION_WIDTH = 32 + BOUND_WIDTH;
  localparam logic [3:0] PRECALC_DIM_MASK = (MAX_DIMS == 1) ? 4'b0000
                                            : (MAX_DIMS == 2) ? 4'b0011
                                                              : 4'b1111;

  initial begin
    if (cfg_reg_if.DW != 32) $fatal(1, "cfg_reg_if.DW must be 32");
    if (cfg_reg_if.NUM < NUM_REGS)
      $fatal(1, "cfg_reg_if.NUM(%0d) < NUM_REGS(%0d)", cfg_reg_if.NUM, NUM_REGS);
    if ((FIXED_DIR < -1) || (FIXED_DIR > 1))
      $fatal(1, "FIXED_DIR(%0d) must be -1, 0, or 1", FIXED_DIR);
    if ((BOUND_WIDTH <= 0) || (BOUND_WIDTH > 32))
      $fatal(1, "BOUND_WIDTH(%0d) must be from 1 through 32", BOUND_WIDTH);
    if ((MAX_DIMS < 1) || (MAX_DIMS > NDIM))
      $fatal(1, "MAX_DIMS(%0d) must be from 1 through %0d", MAX_DIMS, NDIM);
    if ((RD_OUTSTANDING <= 0)
        || ((RD_OUTSTANDING & (RD_OUTSTANDING - 1)) != 0))
      $fatal(1, "RD_OUTSTANDING(%0d) must be a positive power of two", RD_OUTSTANDING);
  end

  // ------------------------------------------------------------
  // Bus widths (bytes per beat)
  // ------------------------------------------------------------
  localparam int DCACHE_BYTES = dcache_bus_if.DATA_SIZE;
  localparam int LMEM_BYTES   = lmem_bus_if.DATA_SIZE;

  localparam int DCACHE_LG2 = `CLOG2(DCACHE_BYTES);
  localparam int LMEM_LG2   = `CLOG2(LMEM_BYTES);

  // Aligned mode only needs one beat of staging because source and destination
  // bases/strides are bus-aligned. Different source/destination beat widths
  // still require a MAX_BYTES window for width conversion.
  localparam int MIN_BYTES    = (DCACHE_BYTES < LMEM_BYTES) ? DCACHE_BYTES : LMEM_BYTES;
  localparam int MAX_BYTES    = (DCACHE_BYTES > LMEM_BYTES) ? DCACHE_BYTES : LMEM_BYTES;
  localparam int CHUNK_BYTES  = MIN_BYTES;
  localparam int WIN_BYTES    = MAX_BYTES;
  localparam int WIN_VALID_W  = `CLOG2(WIN_BYTES + 1);
  localparam int SAME_WIDTH_FAST = (DCACHE_BYTES == LMEM_BYTES);
  localparam bit FIXED_1D_WRITE_COUNTER = ENABLE_1D_WRITE_COUNTER
                                        && (FIXED_DIR == 1)
                                        && (MAX_DIMS == 1)
                                        && SAME_WIDTH_FAST;
  localparam int WR_BEAT_COUNT_W = 33 - DCACHE_LG2;

  initial begin
    if (!(((DCACHE_BYTES % LMEM_BYTES) == 0) || ((LMEM_BYTES % DCACHE_BYTES) == 0)))
      $fatal(1, "aligned DMA requires divisible dcache/lmem bus widths");
    if (!ENABLE_PADDING && (DCACHE_BYTES != LMEM_BYTES))
      $fatal(1,
          "padding-disabled aligned DMA requires equal dcache/lmem bus widths");
    if (ENABLE_1D_WRITE_COUNTER
     && ((FIXED_DIR != 1) || (MAX_DIMS != 1) || !SAME_WIDTH_FAST))
      $fatal(1,
          "1D write counter requires FIXED_DIR=1, MAX_DIMS=1, equal widths");
  end

  function automatic logic [DCACHE_ADDR_WIDTH-1:0] to_dcache_addr(input logic [63:0] byte_addr);
    to_dcache_addr = DCACHE_ADDR_WIDTH'(byte_addr >> DCACHE_LG2);
  endfunction

  function automatic logic [LMEM_ADDR_WIDTH-1:0] to_lmem_addr(input logic [63:0] byte_addr);
    to_lmem_addr = LMEM_ADDR_WIDTH'(byte_addr >> LMEM_LG2);
  endfunction

  function automatic logic [31:0] umin32(input logic [31:0] a, input logic [31:0] b);
    return (a < b) ? a : b;
  endfunction

  function automatic logic [31:0] calc_src_bytes(
    input logic [31:0] byte_off,
    input logic [31:0] valid_bytes,
    input logic [31:0] req_bytes
  );
    if (byte_off >= valid_bytes)
      return 32'd0;
    else
      return umin32(valid_bytes - byte_off, req_bytes);
  endfunction

  function automatic logic [31:0] calc_read_valid_bytes(
    input logic [63:0] src_ptr,
    input logic [63:0] seg_valid_end,
    input logic [31:0] beat_bytes,
    input logic [31:0] valid_bytes
  );
    if ((valid_bytes == 0) || (src_ptr >= seg_valid_end))
      return 32'd0;
    else if ((src_ptr + 64'(beat_bytes)) <= seg_valid_end)
      return beat_bytes;
    else
      return 32'(seg_valid_end - src_ptr);
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

    S_DONE
  } state_e;

  state_e state, state_n;

`ifndef SYNTHESIS
`define VX_DMA_UNIT_ALIGN_STRING_HELPERS
`elsif SIMULATION
`define VX_DMA_UNIT_ALIGN_STRING_HELPERS
`endif

`ifdef VX_DMA_UNIT_ALIGN_STRING_HELPERS
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
      S_DONE:           return "S_DONE";
      default:          return "S_UNKNOWN";
    endcase
  endfunction
`endif // VX_DMA_UNIT_ALIGN_STRING_HELPERS

`ifdef VX_DMA_UNIT_ALIGN_STRING_HELPERS
`undef VX_DMA_UNIT_ALIGN_STRING_HELPERS
`endif

  // ------------------------------------------------------------
  // cfg handshake / latch
  // ------------------------------------------------------------
  logic cfg_fire;
  // A legacy descriptor is accepted only from IDLE.  A controller-selected
  // prepared descriptor may additionally replace an old command on the exact
  // S_DONE completion handshake edge.  This capability is owned solely by
  // registered channel state plus the old-command completion consumer; it
  // must not depend on the controller's ACTIVATE offer.
  assign cfg_reg_if.ready = (state == S_IDLE)
                         || ((state == S_DONE) && done_if.ready);
  assign cfg_fire = cfg_reg_if.valid && cfg_reg_if.ready;

`ifndef SYNTHESIS
  logic cfg_stalled_prev_r;
  logic [NUM_REGS-1:0][31:0] cfg_stall_regs_r;
  logic [31:0] cfg_stall_entry_id_r;
  logic cfg_stall_activate_r;
  logic cfg_stall_activate_id_r;
  logic chain_start_prev_r;
  logic chain_start_fast_prev_r;
  logic chain_start_dir_prev_r;

  always_ff @(posedge clk) begin
    if (reset) begin
      cfg_stalled_prev_r <= 1'b0;
    end else begin
      if (cfg_stalled_prev_r) begin
        assert (cfg_reg_if.valid
             && (cfg_reg_if.regs == cfg_stall_regs_r)
             && (cfg_reg_if.entry_id == cfg_stall_entry_id_r)
             && (lookahead_if.activate == cfg_stall_activate_r)
             && (lookahead_if.activate_id == cfg_stall_activate_id_r))
          else $fatal(1,
              "%s: cfg/ACTIVATE changed while held", INSTANCE_ID);
      end
      cfg_stalled_prev_r <= cfg_reg_if.valid && !cfg_reg_if.ready;
      if (cfg_reg_if.valid && !cfg_reg_if.ready) begin
        cfg_stall_regs_r <= cfg_reg_if.regs;
        cfg_stall_entry_id_r <= cfg_reg_if.entry_id;
        cfg_stall_activate_r <= lookahead_if.activate;
        cfg_stall_activate_id_r <= lookahead_if.activate_id;
      end

      if (lookahead_if.prepare_valid && !cfg_reg_if.valid)
        assert (!cfg_fire)
          else $fatal(1, "%s: PREPARE caused cfg_fire", INSTANCE_ID);
      if (lookahead_if.activate && !cfg_reg_if.valid)
        assert (!cfg_fire)
          else $fatal(1, "%s: ACTIVATE changed state without cfg", INSTANCE_ID);
      if (cfg_fire && cfg_reg_if.regs[0][0] && (state == S_DONE)) begin
        assert (lookahead_if.activate && done_if.valid && done_if.ready)
          else $fatal(1,
              "%s: descriptor replaced old command without done handshake",
              INSTANCE_ID);
      end
      if (!ENABLE_PADDING && cfg_fire)
        assert (cfg_reg_if.regs[15] == 0)
          else $fatal(1,
              "%s: padding-disabled DMA accepted nonzero padding=%0d",
              INSTANCE_ID, cfg_reg_if.regs[15]);

      if (cfg_fire) begin
        for (int d = 0; d < NDIM; ++d) begin
          assert ((cfg_reg_if.regs[11 + d] >> BOUND_WIDTH) == 0)
            else $fatal(1,
                "%s: bound[%0d]=0x%08h exceeds BOUND_WIDTH=%0d",
                INSTANCE_ID, d, cfg_reg_if.regs[11 + d], BOUND_WIDTH);
          if (d >= MAX_DIMS)
            assert (cfg_reg_if.regs[11 + d] == 32'd1)
              else $fatal(1,
                  "%s: inactive bound[%0d]=%0d must be one for MAX_DIMS=%0d",
                  INSTANCE_ID, d, cfg_reg_if.regs[11 + d], MAX_DIMS);
        end
      end

    end
  end
`endif

  // Since cfg_reg_if.DW=32, regs_latched[*] is 32-bit.
  logic [cfg_reg_if.NUM-1:0][cfg_reg_if.DW-1:0] regs_latched;
  logic [31:0] entry_id_latched;

  always_ff @(posedge clk) begin
    if (reset) begin
      entry_id_latched <= '0;
      foreach (regs_latched[k]) regs_latched[k] <= '0;
    end else if (cfg_fire) begin
      entry_id_latched <= cfg_reg_if.entry_id;
      foreach (regs_latched[k]) regs_latched[k] <= cfg_reg_if.regs[k];
    end
  end

  logic [`UP(UUID_WIDTH)-1:0] dma_uuid;
  assign dma_uuid = `UP(UUID_WIDTH)'(entry_id_latched);

  wire cmd_start = cfg_fire && cfg_reg_if.regs[0][0];
  wire cmd_dir = (FIXED_DIR < 0)
               ? cfg_reg_if.regs[DESC_DIR_IDX][0] : FIXED_DIR[0];
  wire [63:0] cmd_src_base = {
      cfg_reg_if.regs[4][31:0], cfg_reg_if.regs[3][31:0]};
  wire [63:0] cmd_dst_base = {
      cfg_reg_if.regs[2][31:0], cfg_reg_if.regs[1][31:0]};
  wire [31:0] cmd_valid_total = ENABLE_PADDING
                              ? (cfg_reg_if.regs[14] - cfg_reg_if.regs[15])
                              : cfg_reg_if.regs[14];
  wire [32:0] cmd_wr_rounded_bytes = {1'b0, cfg_reg_if.regs[14]}
                                         + 33'(DCACHE_BYTES - 1);
  wire [WR_BEAT_COUNT_W-1:0] cmd_wr_beats_per_seg
      = WR_BEAT_COUNT_W'(cmd_wr_rounded_bytes >> DCACHE_LG2);
  wire [31:0] cmd_wr_partial_bytes
      = cfg_reg_if.regs[14] & 32'(DCACHE_BYTES - 1);
  wire [WIN_VALID_W-1:0] cmd_wr_final_bytes
      = (cmd_wr_partial_bytes == 0)
      ? WIN_VALID_W'(DCACHE_BYTES)
      : WIN_VALID_W'(cmd_wr_partial_bytes);
  wire cmd_bounds_nonzero;
  if (MAX_DIMS == 1) begin : g_cmd_bounds_1d
    assign cmd_bounds_nonzero = (cfg_reg_if.regs[11] != 0);
  end else if (MAX_DIMS == 2) begin : g_cmd_bounds_2d
    assign cmd_bounds_nonzero = (cfg_reg_if.regs[11] != 0)
                             && (cfg_reg_if.regs[12] != 0);
  end else begin : g_cmd_bounds_3d
    assign cmd_bounds_nonzero = (cfg_reg_if.regs[11] != 0)
                             && (cfg_reg_if.regs[12] != 0)
                             && (cfg_reg_if.regs[13] != 0);
  end
  wire cmd_fast_path = cmd_start
                    && cmd_bounds_nonzero
                    && (cfg_reg_if.regs[14] != 0)
                    && (ENABLE_PADDING
                        ? (cfg_reg_if.regs[14] > cfg_reg_if.regs[15])
                        : 1'b1);

`ifndef SYNTHESIS
  always_ff @(posedge clk) begin
    if (reset) begin
      chain_start_prev_r <= 1'b0;
    end else begin
      if (chain_start_prev_r) begin
        assert (state != S_IDLE && state != S_DONE)
          else $fatal(1,
              "%s: chained descriptor visited an idle/done state", INSTANCE_ID);
        assert (state == (chain_start_fast_prev_r
                       ? (chain_start_dir_prev_r
                          ? S_L2G_DECIDE : S_G2L_DECIDE)
                       : S_PRECALC))
          else $fatal(1,
              "%s: chained descriptor did not enter its direct next state",
              INSTANCE_ID);
      end
      chain_start_prev_r <= cmd_start && (state == S_DONE);
      if (cmd_start && (state == S_DONE)) begin
        chain_start_fast_prev_r <= cmd_fast_path;
        chain_start_dir_prev_r <= cmd_dir;
      end
    end
  end
`endif

  // ------------------------------------------------------------
  // Runtime alignment guard for the aligned-only module.
  // Simulation-only ($fatal is stripped by synthesis). Checks base/stride
  // lower bits on each command start; padding and seg_size are allowed to be
  // byte-granular since the last beat is handled via byteen.
  // ------------------------------------------------------------
`ifndef SYNTHESIS
  always_ff @(posedge clk) begin
    if (!reset && cmd_start) begin
      if ((FIXED_DIR >= 0)
          && (cfg_reg_if.regs[DESC_DIR_IDX][0] != FIXED_DIR[0]))
        $fatal(1, "%s: descriptor direction (%0d) does not match FIXED_DIR(%0d)",
               INSTANCE_ID, cfg_reg_if.regs[DESC_DIR_IDX][0], FIXED_DIR);
      // src and dst ride different buses depending on direction, so each must be
      // checked against the beat of the bus it actually touches:
      //   dir=0 (G2L): src=DCACHE, dst=LMEM ;  dir=1 (L2G): src=LMEM, dst=DCACHE.
      // The LMEM beat (NUM_LSU_LANES*LSU_WORD_SIZE) can exceed the DCACHE line, so
      // a fixed src->LMEM / dst->DCACHE orientation would falsely trip on the
      // global side of a G2L transfer (e.g. a 64B-aligned global base on a 256B
      // LMEM bus) while under-checking the LMEM side.
      if (|(cfg_reg_if.regs[3] & ((cmd_dir ? 32'(LMEM_BYTES) : 32'(DCACHE_BYTES)) - 32'd1)))
        $fatal(1, "%s: aligned DMA src_base_lo=0x%08h is not %0d-byte aligned",
               INSTANCE_ID, cfg_reg_if.regs[3],
               cmd_dir ? LMEM_BYTES : DCACHE_BYTES);
      if (|(cfg_reg_if.regs[1] & ((cmd_dir ? 32'(DCACHE_BYTES) : 32'(LMEM_BYTES)) - 32'd1)))
        $fatal(1, "%s: aligned DMA dst_base_lo=0x%08h is not %0d-byte aligned",
               INSTANCE_ID, cfg_reg_if.regs[1],
               cmd_dir ? DCACHE_BYTES : LMEM_BYTES);
      if (|(cfg_reg_if.regs[5] & ((cmd_dir ? 32'(LMEM_BYTES) : 32'(DCACHE_BYTES)) - 32'd1)))
        $fatal(1, "%s: aligned DMA src_stride[%0d]=0x%08h is not %0d-byte aligned",
               INSTANCE_ID, 0, cfg_reg_if.regs[5],
               cmd_dir ? LMEM_BYTES : DCACHE_BYTES);
      if (|(cfg_reg_if.regs[6] & ((cmd_dir ? 32'(DCACHE_BYTES) : 32'(LMEM_BYTES)) - 32'd1)))
        $fatal(1, "%s: aligned DMA dst_stride[%0d]=0x%08h is not %0d-byte aligned",
               INSTANCE_ID, 0, cfg_reg_if.regs[6],
               cmd_dir ? DCACHE_BYTES : LMEM_BYTES);
      if (|(cfg_reg_if.regs[7] & ((cmd_dir ? 32'(LMEM_BYTES) : 32'(DCACHE_BYTES)) - 32'd1)))
        $fatal(1, "%s: aligned DMA src_stride[%0d]=0x%08h is not %0d-byte aligned",
               INSTANCE_ID, 1, cfg_reg_if.regs[7],
               cmd_dir ? LMEM_BYTES : DCACHE_BYTES);
      if (|(cfg_reg_if.regs[8] & ((cmd_dir ? 32'(DCACHE_BYTES) : 32'(LMEM_BYTES)) - 32'd1)))
        $fatal(1, "%s: aligned DMA dst_stride[%0d]=0x%08h is not %0d-byte aligned",
               INSTANCE_ID, 1, cfg_reg_if.regs[8],
               cmd_dir ? DCACHE_BYTES : LMEM_BYTES);
      if (|(cfg_reg_if.regs[9] & ((cmd_dir ? 32'(LMEM_BYTES) : 32'(DCACHE_BYTES)) - 32'd1)))
        $fatal(1, "%s: aligned DMA src_stride[%0d]=0x%08h is not %0d-byte aligned",
               INSTANCE_ID, 2, cfg_reg_if.regs[9],
               cmd_dir ? LMEM_BYTES : DCACHE_BYTES);
      if (|(cfg_reg_if.regs[10] & ((cmd_dir ? 32'(DCACHE_BYTES) : 32'(LMEM_BYTES)) - 32'd1)))
        $fatal(1, "%s: aligned DMA dst_stride[%0d]=0x%08h is not %0d-byte aligned",
               INSTANCE_ID, 2, cfg_reg_if.regs[10],
               cmd_dir ? DCACHE_BYTES : LMEM_BYTES);
    end
  end
`endif

  // Latched descriptor fields (captured atomically at cmd_start)
  logic [31:0] stride_r[2][NDIM];  // [src/dst][dim]
  // Precomputed stride * (bound - 1), used for carry-step base address correction.
  // D2 products are intentionally absent: no next-base equation consumes them.
  logic [63:0] stride_bound_r[2][2];
  logic [BOUND_WIDTH-1:0] bound_r[NDIM];
  logic [31:0] seg_size_r;
  logic [31:0] padding_r;
  logic        direction_bit_r;    // 0: GLOBAL->LMEM (load), 1: LMEM->GLOBAL (store)
  wire         active_dir = (FIXED_DIR < 0) ? direction_bit_r : FIXED_DIR[0];
  logic [63:0] rd_base_src_seg_r, wr_base_dst_seg_r;
  logic        precalc_pending_r;
  logic [3:0]  precalc_needed_r;
  logic [3:0]  precalc_ready_r;
  logic [GEMM_PREFETCH_MAX_BEATS_WIDTH-1:0] data_max_beats_r;
  logic [GEMM_PREFETCH_MAX_BEATS_WIDTH-1:0] pre_release_reads_r;

  wire pre_release_source_credit = (data_max_beats_r != 0)
      && (pre_release_reads_r < data_max_beats_r);
  wire source_issue_enable = lookahead_if.data_release
                          || pre_release_source_credit;

  // Two random-access look-ahead result slots.  Only multiplication operands,
  // dependency masks, and D0/D1 correction results are stored here; the full
  // descriptor remains controller-owned until ACTIVATE/cfg_fire.
  logic [1:0]          prep_owner_valid_r;
  logic [1:0]          prep_activated_r;
  logic [1:0]          prep_issue_pending_r;
  logic [1:0][3:0]     prep_needed_r;
  logic [1:0][3:0]     prep_ready_r;
  logic [1:0][3:0][CORRECTION_WIDTH-1:0] prep_result_r;
  logic [1:0][1:0][31:0] prep_src_stride_r;
  logic [1:0][1:0][31:0] prep_dst_stride_r;
  logic [1:0][1:0][BOUND_WIDTH-1:0] prep_bound_r;

  localparam int PRECALC_SRC_D0 = 0;
  localparam int PRECALC_DST_D0 = 1;
  localparam int PRECALC_SRC_D1 = 2;
  localparam int PRECALC_DST_D1 = 3;

  logic [3:0] cmd_precalc_needed;
  always_comb begin
    logic consume_d0;
    logic consume_d1;
    consume_d0 = (MAX_DIMS > 1) && (cfg_reg_if.regs[12] > 1);
    if (MAX_DIMS > 2)
      consume_d0 |= (cfg_reg_if.regs[13] > 1);
    consume_d1 = (MAX_DIMS > 2) && (cfg_reg_if.regs[13] > 1);
    cmd_precalc_needed = '0;

    // Excluded descriptors retain the legacy setup wait. Positive fast-path
    // descriptors issue only correction products that can actually be used.
    if (cmd_fast_path) begin
      if (MAX_DIMS > 1) begin
        cmd_precalc_needed[PRECALC_SRC_D0] = consume_d0
            && (cfg_reg_if.regs[11] > 1) && (cfg_reg_if.regs[5] != 0);
        cmd_precalc_needed[PRECALC_DST_D0] = consume_d0
            && (cfg_reg_if.regs[11] > 1) && (cfg_reg_if.regs[6] != 0);
      end
      if (MAX_DIMS > 2) begin
        cmd_precalc_needed[PRECALC_SRC_D1] = consume_d1
            && (cfg_reg_if.regs[12] > 1) && (cfg_reg_if.regs[7] != 0);
        cmd_precalc_needed[PRECALC_DST_D1] = consume_d1
            && (cfg_reg_if.regs[12] > 1) && (cfg_reg_if.regs[8] != 0);
      end
    end else begin
      cmd_precalc_needed = PRECALC_DIM_MASK;
    end
  end

  logic [3:0] prep_cmd_needed;
  always_comb begin
    prep_cmd_needed = '0;
    if (MAX_DIMS > 1) begin
      prep_cmd_needed[PRECALC_SRC_D0] = (lookahead_if.bound[0] > 1)
          && (lookahead_if.src_stride[0] != 0);
      prep_cmd_needed[PRECALC_DST_D0] = (lookahead_if.bound[0] > 1)
          && (lookahead_if.dst_stride[0] != 0);
    end
    if (MAX_DIMS > 2) begin
      prep_cmd_needed[PRECALC_SRC_D1] = (lookahead_if.bound[1] > 1)
          && (lookahead_if.src_stride[1] != 0);
      prep_cmd_needed[PRECALC_DST_D1] = (lookahead_if.bound[1] > 1)
          && (lookahead_if.dst_stride[1] != 0);
    end
  end

  wire prepare_fire = lookahead_if.prepare_valid
                   && lookahead_if.prepare_ready;
  assign lookahead_if.prepare_ready =
      !prep_owner_valid_r[lookahead_if.prepare_id];

  wire cache_issue_id = prep_issue_pending_r[0] ? 1'b0 : 1'b1;
  wire active_precalc_issue = precalc_pending_r;
  wire precalc_issue = active_precalc_issue;
  wire cache_precalc_issue = !active_precalc_issue
                          && (|prep_issue_pending_r);
  wire multiplier_issue = active_precalc_issue || cache_precalc_issue;
  wire multiplier_issue_cache = cache_precalc_issue;

  logic [3:0] multiplier_needed;
  logic [3:0][31:0] multiplier_stride;
  logic [3:0][BOUND_WIDTH-1:0] multiplier_bound;
  always_comb begin
    multiplier_needed = precalc_needed_r;
    multiplier_stride[PRECALC_SRC_D0] = stride_r[0][0];
    multiplier_stride[PRECALC_DST_D0] = stride_r[1][0];
    multiplier_stride[PRECALC_SRC_D1] = stride_r[0][1];
    multiplier_stride[PRECALC_DST_D1] = stride_r[1][1];
    multiplier_bound[PRECALC_SRC_D0] = bound_r[0];
    multiplier_bound[PRECALC_DST_D0] = bound_r[0];
    multiplier_bound[PRECALC_SRC_D1] = bound_r[1];
    multiplier_bound[PRECALC_DST_D1] = bound_r[1];
    if (cache_precalc_issue) begin
      multiplier_needed = prep_needed_r[cache_issue_id];
      multiplier_stride[PRECALC_SRC_D0] =
          prep_src_stride_r[cache_issue_id][0];
      multiplier_stride[PRECALC_DST_D0] =
          prep_dst_stride_r[cache_issue_id][0];
      multiplier_stride[PRECALC_SRC_D1] =
          prep_src_stride_r[cache_issue_id][1];
      multiplier_stride[PRECALC_DST_D1] =
          prep_dst_stride_r[cache_issue_id][1];
      multiplier_bound[PRECALC_SRC_D0] = prep_bound_r[cache_issue_id][0];
      multiplier_bound[PRECALC_DST_D0] = prep_bound_r[cache_issue_id][0];
      multiplier_bound[PRECALC_SRC_D1] = prep_bound_r[cache_issue_id][1];
      multiplier_bound[PRECALC_DST_D1] = prep_bound_r[cache_issue_id][1];
    end
  end

  logic [1:0] multiplier_owner_tag;
  VX_shift_register #(
    .DATAW  (2),
    .RESETW (2),
    .DEPTH  (4)
  ) multiplier_tag_pipe (
    .clk      (clk),
    .reset    (reset),
    .enable   (1'b1),
    .data_in  ({multiplier_issue_cache, cache_issue_id}),
    .data_out (multiplier_owner_tag)
  );

  logic [3:0]                            precalc_valid;
  logic [3:0][CORRECTION_WIDTH-1:0]      precalc_result;
  wire multiplier_result_cache = multiplier_owner_tag[1];
  wire multiplier_result_id = multiplier_owner_tag[0];
  wire [3:0] active_precalc_valid = precalc_valid
                                  & {4{!multiplier_result_cache}};

  logic [1:0][3:0] prep_ready_now;
  always_comb begin
    prep_ready_now[0] = prep_ready_r[0] | ~prep_needed_r[0];
    prep_ready_now[1] = prep_ready_r[1] | ~prep_needed_r[1];
    if (multiplier_result_cache) begin
      prep_ready_now[multiplier_result_id] |= precalc_valid;
    end
  end

  assign lookahead_if.result_ready[0] =
      prep_owner_valid_r[lookahead_if.prepare_id]
      && prep_ready_now[lookahead_if.prepare_id][PRECALC_SRC_D0]
      && prep_ready_now[lookahead_if.prepare_id][PRECALC_SRC_D1];
  assign lookahead_if.result_ready[1] =
      prep_owner_valid_r[lookahead_if.prepare_id]
      && prep_ready_now[lookahead_if.prepare_id][PRECALC_DST_D0]
      && prep_ready_now[lookahead_if.prepare_id][PRECALC_DST_D1];

  wire activate_slot_owner = lookahead_if.activate
                          && prep_owner_valid_r[lookahead_if.activate_id];
  wire activate_cache_hit = cmd_start && activate_slot_owner
      && ((prep_ready_now[lookahead_if.activate_id] & cmd_precalc_needed)
       == cmd_precalc_needed);
  logic [3:0][CORRECTION_WIDTH-1:0] activate_cached_result;
  always_comb begin
    activate_cached_result = prep_result_r[lookahead_if.activate_id];
    if (multiplier_result_cache
     && (multiplier_result_id == lookahead_if.activate_id)) begin
      for (int p = 0; p < 4; ++p) begin
        if (precalc_valid[p])
          activate_cached_result[p] = precalc_result[p];
      end
    end
  end

  wire [3:0]        precalc_ready_now = precalc_ready_r
                                          | active_precalc_valid
                                          | ~precalc_needed_r;
  wire              precalc_done = &precalc_ready_now;

  wire [63:0] src_d0_correction = active_precalc_valid[PRECALC_SRC_D0]
                                      ? 64'(precalc_result[PRECALC_SRC_D0])
                                      : stride_bound_r[0][0];
  wire [63:0] dst_d0_correction = active_precalc_valid[PRECALC_DST_D0]
                                      ? 64'(precalc_result[PRECALC_DST_D0])
                                      : stride_bound_r[1][0];
  wire [63:0] src_d1_correction = active_precalc_valid[PRECALC_SRC_D1]
                                      ? 64'(precalc_result[PRECALC_SRC_D1])
                                      : stride_bound_r[0][1];
  wire [63:0] dst_d1_correction = active_precalc_valid[PRECALC_DST_D1]
                                      ? 64'(precalc_result[PRECALC_DST_D1])
                                      : stride_bound_r[1][1];

  // MAX_DIMS=1 has no carry correction. MAX_DIMS=2 needs D0 only, and
  // MAX_DIMS=3 needs D0/D1. D2 never has a higher dimension to carry into.
  if (MAX_DIMS > 1) begin : g_precalc_d0
    VX_mul_u32_pipe #(
      .OUT_REGS(0),
      .A_WIDTH (32),
      .B_WIDTH (BOUND_WIDTH)
    ) mul_src_d0 (
      .clk(clk),
      .reset(reset),
      .valid_in(multiplier_issue && multiplier_needed[PRECALC_SRC_D0]),
      .a(multiplier_stride[PRECALC_SRC_D0]),
      .b(multiplier_bound[PRECALC_SRC_D0] - BOUND_WIDTH'(1)),
      .valid_out(precalc_valid[PRECALC_SRC_D0]),
      .result(precalc_result[PRECALC_SRC_D0])
    );

    VX_mul_u32_pipe #(
      .OUT_REGS(0),
      .A_WIDTH (32),
      .B_WIDTH (BOUND_WIDTH)
    ) mul_dst_d0 (
      .clk(clk),
      .reset(reset),
      .valid_in(multiplier_issue && multiplier_needed[PRECALC_DST_D0]),
      .a(multiplier_stride[PRECALC_DST_D0]),
      .b(multiplier_bound[PRECALC_DST_D0] - BOUND_WIDTH'(1)),
      .valid_out(precalc_valid[PRECALC_DST_D0]),
      .result(precalc_result[PRECALC_DST_D0])
    );
  end else begin : g_no_precalc_d0
    assign precalc_valid[PRECALC_SRC_D0] = 1'b0;
    assign precalc_valid[PRECALC_DST_D0] = 1'b0;
    assign precalc_result[PRECALC_SRC_D0] = '0;
    assign precalc_result[PRECALC_DST_D0] = '0;
  end

  if (MAX_DIMS > 2) begin : g_precalc_d1
    VX_mul_u32_pipe #(
      .OUT_REGS(0),
      .A_WIDTH (32),
      .B_WIDTH (BOUND_WIDTH)
    ) mul_src_d1 (
      .clk(clk),
      .reset(reset),
      .valid_in(multiplier_issue && multiplier_needed[PRECALC_SRC_D1]),
      .a(multiplier_stride[PRECALC_SRC_D1]),
      .b(multiplier_bound[PRECALC_SRC_D1] - BOUND_WIDTH'(1)),
      .valid_out(precalc_valid[PRECALC_SRC_D1]),
      .result(precalc_result[PRECALC_SRC_D1])
    );

    VX_mul_u32_pipe #(
      .OUT_REGS(0),
      .A_WIDTH (32),
      .B_WIDTH (BOUND_WIDTH)
    ) mul_dst_d1 (
      .clk(clk),
      .reset(reset),
      .valid_in(multiplier_issue && multiplier_needed[PRECALC_DST_D1]),
      .a(multiplier_stride[PRECALC_DST_D1]),
      .b(multiplier_bound[PRECALC_DST_D1] - BOUND_WIDTH'(1)),
      .valid_out(precalc_valid[PRECALC_DST_D1]),
      .result(precalc_result[PRECALC_DST_D1])
    );
  end else begin : g_no_precalc_d1
    assign precalc_valid[PRECALC_SRC_D1] = 1'b0;
    assign precalc_valid[PRECALC_DST_D1] = 1'b0;
    assign precalc_result[PRECALC_SRC_D1] = '0;
    assign precalc_result[PRECALC_DST_D1] = '0;
  end

  always_ff @(posedge clk) begin
    if (reset) begin
      seg_size_r     <= '0;
      padding_r      <= '0;
      direction_bit_r <= 1'b0;
      precalc_pending_r <= 1'b0;
      precalc_needed_r <= '0;
      precalc_ready_r <= '0;
      prep_owner_valid_r <= '0;
      prep_activated_r <= '0;
      prep_issue_pending_r <= '0;
      prep_needed_r <= '0;
      prep_ready_r <= '0;
      prep_result_r <= '0;
      prep_src_stride_r <= '0;
      prep_dst_stride_r <= '0;
      prep_bound_r <= '0;
      foreach (bound_r[d]) begin
        stride_r[0][d] <= '0;
        stride_r[1][d] <= '0;
        bound_r[d] <= '0;
      end
      foreach (stride_bound_r[s, d])
        stride_bound_r[s][d] <= '0;
    end else if (cmd_start) begin
      foreach (bound_r[d]) begin
        if (d < MAX_DIMS) begin
          stride_r[0][d] <= cfg_reg_if.regs[5 + 2*d][31:0];
          stride_r[1][d] <= cfg_reg_if.regs[6 + 2*d][31:0];
          bound_r[d]     <= cfg_reg_if.regs[11 + d][BOUND_WIDTH-1:0];
        end else begin
          stride_r[0][d] <= '0;
          stride_r[1][d] <= '0;
          bound_r[d]     <= BOUND_WIDTH'(1);
        end
      end
      foreach (stride_bound_r[s, d])
        stride_bound_r[s][d] <= '0;

      seg_size_r      <= cfg_reg_if.regs[14][31:0];
      padding_r       <= cfg_reg_if.regs[15][31:0];
      direction_bit_r <= cfg_reg_if.regs[DESC_DIR_IDX][0];
      precalc_needed_r <= cmd_precalc_needed;
      if (activate_cache_hit) begin
        precalc_ready_r <= 4'b1111;
        precalc_pending_r <= 1'b0;
        stride_bound_r[0][0]
            <= 64'(activate_cached_result[PRECALC_SRC_D0]);
        stride_bound_r[1][0]
            <= 64'(activate_cached_result[PRECALC_DST_D0]);
        stride_bound_r[0][1]
            <= 64'(activate_cached_result[PRECALC_SRC_D1]);
        stride_bound_r[1][1]
            <= 64'(activate_cached_result[PRECALC_DST_D1]);
      end else begin
        precalc_ready_r <= ~cmd_precalc_needed;
        precalc_pending_r <= |cmd_precalc_needed;
      end
    end else begin
      if (active_precalc_issue)
        precalc_pending_r <= 1'b0;

      for (int p = 0; p < 4; ++p) begin
        if (active_precalc_valid[p])
          precalc_ready_r[p] <= 1'b1;
      end
      if (active_precalc_valid[PRECALC_SRC_D0])
        stride_bound_r[0][0] <= 64'(precalc_result[0]);
      if (active_precalc_valid[PRECALC_DST_D0])
        stride_bound_r[1][0] <= 64'(precalc_result[1]);
      if (active_precalc_valid[PRECALC_SRC_D1])
        stride_bound_r[0][1] <= 64'(precalc_result[2]);
      if (active_precalc_valid[PRECALC_DST_D1])
        stride_bound_r[1][1] <= 64'(precalc_result[3]);
    end

    if (!reset) begin
      if (prepare_fire) begin
        prep_owner_valid_r[lookahead_if.prepare_id] <= 1'b1;
        prep_activated_r[lookahead_if.prepare_id] <= 1'b0;
        prep_issue_pending_r[lookahead_if.prepare_id]
            <= |prep_cmd_needed;
        prep_needed_r[lookahead_if.prepare_id] <= prep_cmd_needed;
        prep_ready_r[lookahead_if.prepare_id] <= ~prep_cmd_needed;
        prep_result_r[lookahead_if.prepare_id] <= '0;
        prep_src_stride_r[lookahead_if.prepare_id]
            <= lookahead_if.src_stride;
        prep_dst_stride_r[lookahead_if.prepare_id]
            <= lookahead_if.dst_stride;
        prep_bound_r[lookahead_if.prepare_id] <= lookahead_if.bound;
      end

      if (cache_precalc_issue)
        prep_issue_pending_r[cache_issue_id] <= 1'b0;

      if (multiplier_result_cache) begin
        for (int p = 0; p < 4; ++p) begin
          if (precalc_valid[p]) begin
            prep_ready_r[multiplier_result_id][p] <= 1'b1;
            prep_result_r[multiplier_result_id][p] <= precalc_result[p];
          end
        end
      end

      if (cmd_start && activate_slot_owner)
        prep_activated_r[lookahead_if.activate_id] <= 1'b1;

      for (int id = 0; id < 2; ++id) begin
        if (prep_owner_valid_r[id]
         && (prep_activated_r[id]
          || (cmd_start && lookahead_if.activate
           && (lookahead_if.activate_id == id)))
         && (&prep_ready_now[id])) begin
          prep_owner_valid_r[id] <= 1'b0;
          prep_activated_r[id] <= 1'b0;
          prep_issue_pending_r[id] <= 1'b0;
        end
      end
    end
  end

`ifndef SYNTHESIS
  always_ff @(posedge clk) begin
    if (!reset) begin
      if (prepare_fire)
        assert (!prep_owner_valid_r[lookahead_if.prepare_id])
          else $fatal(1, "%s: PREPARE reused a live prep_id", INSTANCE_ID);
      if (prepare_fire && (MAX_DIMS == 1))
        assert (lookahead_if.bound[1] == BOUND_WIDTH'(1))
          else $fatal(1,
              "%s: PREPARE inactive bound[1]=%0d must be one for MAX_DIMS=1",
              INSTANCE_ID, lookahead_if.bound[1]);

      if (multiplier_result_cache && (|precalc_valid)) begin
        assert (prep_owner_valid_r[multiplier_result_id])
          else $fatal(1,
              "%s: late multiplier result targeted an unowned prep_id",
              INSTANCE_ID);
        for (int p = 0; p < 4; ++p) begin
          if (precalc_valid[p])
            assert (prep_needed_r[multiplier_result_id][p])
              else $fatal(1,
                  "%s: multiplier result targeted a different slot owner",
                  INSTANCE_ID);
        end
      end
    end
  end
`endif

  // ------------------------------------------------------------
  // 3D indices + segment byte offset
  //   - rd_i_dim / rd_base_src_seg_r advance when the RD side finishes
  //     issuing reads for the current segment (src_req_fire crosses end)
  //   - wr_i_dim / wr_base_dst_seg_r advance when the WR side finishes
  //     writing the current segment (dst_req_fire causes out_off == seg_size)
  //   - This decouples the two sides so the slot array (depth 8) can hold
  //     reads from future segments while writes of the current segment
  //     are still draining. Without the split, each segment would serialize
  //     through S_PREP_SEG -> DECIDE -> S_ADV_SEG (~7–8 cycles / seg).
  // ------------------------------------------------------------
  logic [BOUND_WIDTH-1:0] rd_i_dim[NDIM];
  logic [BOUND_WIDTH-1:0] wr_i_dim[NDIM];
  logic [BOUND_WIDTH-1:0] rd_i_dim_advance[NDIM];
  logic [BOUND_WIDTH-1:0] wr_i_dim_advance[NDIM];
  wire bounds_nonzero;
  if (MAX_DIMS == 1) begin : g_bounds_1d
    assign bounds_nonzero = (bound_r[0] != 0);
  end else if (MAX_DIMS == 2) begin : g_bounds_2d
    assign bounds_nonzero = (bound_r[0] != 0) && (bound_r[1] != 0);
  end else begin : g_bounds_3d
    assign bounds_nonzero = (bound_r[0] != 0)
                         && (bound_r[1] != 0)
                         && (bound_r[2] != 0);
  end
  logic [31:0] out_off; // bytes within current WR segment [0 .. seg_size)
  logic [WR_BEAT_COUNT_W-1:0] wr_beats_per_seg_r;
  logic [WR_BEAT_COUNT_W-1:0] wr_beats_remaining_r;
  logic [WIN_VALID_W-1:0] wr_final_bytes_r;
  logic        rd_rollover_pending_r;
  logic        wr_rollover_pending_r;

  // ------------------------------------------------------------
  // Base address per segment (byte)
  // ------------------------------------------------------------
  logic [63:0] rd_base_src_seg, wr_base_dst_seg;
  logic [63:0] wr_base_src_seg_r;

  // Segment bases are maintained incrementally in src_req_fire / dst_req_fire
  // handlers to avoid per-cycle 64-bit mul/add.
  assign rd_base_src_seg = rd_base_src_seg_r;
  assign wr_base_dst_seg = wr_base_dst_seg_r;

  // Finished wires are declared later, after rd_state_e / wr_state_e
  // are in scope (VCS does not accept forward references to them here).

  // ------------------------------------------------------------
  // valid/padding boundary
  // ------------------------------------------------------------
  logic [31:0] valid_total;
  assign valid_total = ENABLE_PADDING
                     ? ((seg_size_r > padding_r) ? (seg_size_r - padding_r) : 32'd0)
                     : seg_size_r;

  // ------------------------------------------------------------
  // Window buffers for width conversion
  //   - win_* LSB = stream head
  // ------------------------------------------------------------
  logic [WIN_BYTES*8-1:0]  win_lmem;
  logic [WIN_VALID_W-1:0]  win_lmem_valid;
  logic [WIN_VALID_W-1:0]  win_lmem_head;
  logic [63:0]             lmem_rd_ptr;
  logic [63:0]             lmem_rd_end;   // aligned end (exclusive)

  logic [WIN_BYTES*8-1:0]  win_dcache;
  logic [WIN_VALID_W-1:0]  win_dcache_valid;
  logic [WIN_VALID_W-1:0]  win_dcache_head;
  logic [63:0]             dcache_rd_ptr;
  logic [63:0]             dcache_rd_end;

  // ------------------------------------------------------------
  // Decoupled RD/WR control + response slots
  // ------------------------------------------------------------
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
    SLOT_READY,
    SLOT_DRAINING
  } slot_state_e;

  localparam int RD_SLOT_BITS_CAP   = (RD_OUTSTANDING > 1)
                                    ? $clog2(RD_OUTSTANDING) : 0;
  localparam int DCACHE_TAG_VALUE_W = DCACHE_TAG_WIDTH - `UP(UUID_WIDTH);
  localparam int LMEM_TAG_VALUE_W   = LMEM_TAG_WIDTH - `UP(UUID_WIDTH);
  localparam int MIN_TAG_VALUE_W    = (DCACHE_TAG_VALUE_W < LMEM_TAG_VALUE_W)
                                    ? DCACHE_TAG_VALUE_W : LMEM_TAG_VALUE_W;
  // Keep at least 1 bit in localparams so vector declarations remain legal,
  // then enforce the real minimum at runtime with a fatal check below.
  localparam int RD_SLOT_BITS       = (RD_SLOT_BITS_CAP < 1) ? 1 : RD_SLOT_BITS_CAP;
  localparam int RD_OUTSTANDING_EFF = RD_OUTSTANDING;
  localparam int SLOT_OCC_W         = `CLOG2(RD_OUTSTANDING_EFF + 1);

  initial begin
    if (MIN_TAG_VALUE_W < 1)
      $fatal(1, "tag.value width must be >= 1 (dcache=%0d, lmem=%0d)", DCACHE_TAG_VALUE_W, LMEM_TAG_VALUE_W);
    if (DCACHE_TAG_VALUE_W < RD_SLOT_BITS_CAP)
      $fatal(1, "dcache tag.value width (%0d) < requested slot bits (%0d)",
             DCACHE_TAG_VALUE_W, RD_SLOT_BITS_CAP);
    if (LMEM_TAG_VALUE_W < RD_SLOT_BITS_CAP)
      $fatal(1, "lmem tag.value width (%0d) < requested slot bits (%0d)",
             LMEM_TAG_VALUE_W, RD_SLOT_BITS_CAP);
  end

  rd_state_e rd_state;
  wr_state_e wr_state;

  // Finished: wr side has issued writes for the last segment. Equivalent to
  // wr_state == WR_DONE; kept as a wire for trace/chipscope readability.
  // Declared here (not near the segment-base wires above) because VCS
  // requires rd_state_e / wr_state_e to be in scope.
  logic finished;
  assign finished = (wr_state == WR_DONE);
  logic rd_finished;
  assign rd_finished = (rd_state == RD_DONE);

  slot_state_e                slot_state_r [RD_OUTSTANDING_EFF];
  logic [RD_OUTSTANDING_EFF-1:0][WIN_VALID_W-1:0] slot_valid_bytes_r;
  logic [RD_SLOT_BITS-1:0]    rd_issue_slot_r;
  logic [RD_SLOT_BITS-1:0]    wr_expect_slot_r;
  logic [SLOT_OCC_W-1:0]      slot_occupancy_r;

  localparam int DCACHE_RD_CTRL_DATAW = DCACHE_ADDR_WIDTH + DCACHE_BYTES + MEM_FLAGS_WIDTH
                                      + `UP(UUID_WIDTH) + DCACHE_TAG_VALUE_W;
  localparam int LMEM_RD_CTRL_DATAW = LMEM_ADDR_WIDTH + LMEM_BYTES + MEM_FLAGS_WIDTH
                                    + `UP(UUID_WIDTH) + LMEM_TAG_VALUE_W;

  wire                       wr_slot_valid_r;
  wire [MAX_BYTES*8-1:0]     wr_slot_data_r;
  wire [WIN_VALID_W-1:0]     wr_slot_valid_bytes_r;
  logic                      ram_wr_slot_valid_r;
  logic [WIN_VALID_W-1:0]    ram_wr_slot_valid_bytes_r;
  logic [RD_SLOT_BITS-1:0]   ram_wr_slot_r;
  wire [MAX_BYTES*8-1:0]     ram_wr_slot_data;
  wire                       wr_slot_read_valid;
  wire                       wr_slot_read_ready;
  wire                       wr_slot_read_fire;
  wire                       wr_slot_pop_ready;
  wire                       wr_slot_drain_fire;
  wire                       wr_payload_needed;
  logic                      wr_slot_pending_r;
  wire                       wr_slot_pending_next;

  logic                      dcache_req_valid_w;
  wire                       dcache_req_ready_w;
  logic                      dcache_req_rw_w;
  logic [DCACHE_ADDR_WIDTH-1:0] dcache_req_addr_w;
  logic [DCACHE_BYTES*8-1:0] dcache_req_data_w;
  logic [DCACHE_BYTES-1:0]   dcache_req_byteen_w;
  logic [MEM_FLAGS_WIDTH-1:0] dcache_req_flags_w;
  logic [`UP(UUID_WIDTH)-1:0] dcache_req_tag_uuid_w;
  logic [DCACHE_TAG_VALUE_W-1:0] dcache_req_tag_value_w;
  wire                       dcache_req_issue_fire;
  logic [1:0]                dcache_req_buf_pending_r;
  wire [1:0]                 dcache_req_buf_pending_next;

  logic                      lmem_req_valid_w;
  wire                       lmem_req_ready_w;
  logic                      lmem_req_rw_w;
  logic [LMEM_ADDR_WIDTH-1:0] lmem_req_addr_w;
  logic [LMEM_BYTES*8-1:0]   lmem_req_data_w;
  logic [LMEM_BYTES-1:0]     lmem_req_byteen_w;
  logic [MEM_FLAGS_WIDTH-1:0] lmem_req_flags_w;
  logic [`UP(UUID_WIDTH)-1:0] lmem_req_tag_uuid_w;
  logic [LMEM_TAG_VALUE_W-1:0] lmem_req_tag_value_w;
  wire                       lmem_req_issue_fire;
  logic [1:0]                lmem_req_buf_pending_r;
  wire [1:0]                 lmem_req_buf_pending_next;

  wire dcache_rd_valid;
  wire dcache_rd_ready;
  wire [DCACHE_ADDR_WIDTH-1:0] dcache_rd_addr;
  wire [DCACHE_BYTES-1:0] dcache_rd_byteen;
  wire [MEM_FLAGS_WIDTH-1:0] dcache_rd_flags;
  wire [`UP(UUID_WIDTH)-1:0] dcache_rd_tag_uuid;
  wire [DCACHE_TAG_VALUE_W-1:0] dcache_rd_tag_value;

  wire lmem_rd_valid;
  wire lmem_rd_ready;
  wire [LMEM_ADDR_WIDTH-1:0] lmem_rd_addr;
  wire [LMEM_BYTES-1:0] lmem_rd_byteen;
  wire [MEM_FLAGS_WIDTH-1:0] lmem_rd_flags;
  wire [`UP(UUID_WIDTH)-1:0] lmem_rd_tag_uuid;
  wire [LMEM_TAG_VALUE_W-1:0] lmem_rd_tag_value;

  // Only read control travels through elastic buffers. Wide response and
  // write payload data remains in the response RAM / conversion window.
  VX_elastic_buffer #(
    .DATAW   (DCACHE_RD_CTRL_DATAW),
    .SIZE    (2),
    .OUT_REG (1)
  ) dcache_req_buf (
    .clk       (clk),
    .reset     (reset),
    .valid_in  (dcache_req_valid_w && !dcache_req_rw_w),
    .ready_in  (dcache_rd_ready),
    .data_in   ({dcache_req_addr_w, dcache_req_byteen_w, dcache_req_flags_w,
                 dcache_req_tag_uuid_w, dcache_req_tag_value_w}),
    .data_out  ({dcache_rd_addr, dcache_rd_byteen, dcache_rd_flags,
                 dcache_rd_tag_uuid, dcache_rd_tag_value}),
    .valid_out (dcache_rd_valid),
    .ready_out (dcache_bus_if.req_ready)
  );

  VX_elastic_buffer #(
    .DATAW   (LMEM_RD_CTRL_DATAW),
    .SIZE    (2),
    .OUT_REG (1)
  ) lmem_req_buf (
    .clk       (clk),
    .reset     (reset),
    .valid_in  (lmem_req_valid_w && !lmem_req_rw_w),
    .ready_in  (lmem_rd_ready),
    .data_in   ({lmem_req_addr_w, lmem_req_byteen_w, lmem_req_flags_w,
                 lmem_req_tag_uuid_w, lmem_req_tag_value_w}),
    .data_out  ({lmem_rd_addr, lmem_rd_byteen, lmem_rd_flags,
                 lmem_rd_tag_uuid, lmem_rd_tag_value}),
    .valid_out (lmem_rd_valid),
    .ready_out (lmem_bus_if.req_ready)
  );

  assign dcache_req_ready_w = dcache_req_rw_w
                            ? dcache_bus_if.req_ready : dcache_rd_ready;
  assign lmem_req_ready_w = lmem_req_rw_w
                          ? lmem_bus_if.req_ready : lmem_rd_ready;

  assign dcache_bus_if.req_valid = active_dir
                                 ? (dcache_req_valid_w && dcache_req_rw_w)
                                 : dcache_rd_valid;
  assign dcache_bus_if.req_data.rw = active_dir;
  assign dcache_bus_if.req_data.addr = active_dir
                                    ? dcache_req_addr_w : dcache_rd_addr;
  assign dcache_bus_if.req_data.data = ENABLE_PADDING
                                     ? ((active_dir && wr_payload_needed)
                                        ? dcache_req_data_w : '0)
                                     : ram_wr_slot_data;
  assign dcache_bus_if.req_data.byteen = active_dir
                                      ? dcache_req_byteen_w : dcache_rd_byteen;
  assign dcache_bus_if.req_data.flags = active_dir
                                     ? dcache_req_flags_w : dcache_rd_flags;
  assign dcache_bus_if.req_data.tag.uuid = active_dir
                                        ? dcache_req_tag_uuid_w : dcache_rd_tag_uuid;
  assign dcache_bus_if.req_data.tag.value = active_dir
                                         ? dcache_req_tag_value_w : dcache_rd_tag_value;

  assign lmem_bus_if.req_valid = active_dir
                               ? lmem_rd_valid
                               : (lmem_req_valid_w && lmem_req_rw_w);
  assign lmem_bus_if.req_data.rw = !active_dir;
  assign lmem_bus_if.req_data.addr = active_dir
                                  ? lmem_rd_addr : lmem_req_addr_w;
  assign lmem_bus_if.req_data.data = ENABLE_PADDING
                                   ? ((!active_dir && wr_payload_needed)
                                      ? lmem_req_data_w : '0)
                                   : ram_wr_slot_data;
  assign lmem_bus_if.req_data.byteen = active_dir
                                    ? lmem_rd_byteen : lmem_req_byteen_w;
  assign lmem_bus_if.req_data.flags = active_dir
                                   ? lmem_rd_flags : lmem_req_flags_w;
  assign lmem_bus_if.req_data.tag.uuid = active_dir
                                      ? lmem_rd_tag_uuid : lmem_req_tag_uuid_w;
  assign lmem_bus_if.req_data.tag.value = active_dir
                                       ? lmem_rd_tag_value : lmem_req_tag_value_w;

  assign wr_slot_valid_r = ram_wr_slot_valid_r;
  assign wr_slot_data_r = ram_wr_slot_data;
  assign wr_slot_valid_bytes_r = ram_wr_slot_valid_bytes_r;
  assign wr_slot_read_ready = !ram_wr_slot_valid_r || wr_slot_drain_fire;

  function automatic logic [RD_SLOT_BITS-1:0] next_rd_slot_idx(
    input logic [RD_SLOT_BITS-1:0] idx
  );
    begin
      if (RD_OUTSTANDING_EFF == 1)
        next_rd_slot_idx = '0;
      else
        next_rd_slot_idx = idx + RD_SLOT_BITS'(1);
    end
  endfunction

  // ------------------------------------------------------------
  // Handshake helpers
  // ------------------------------------------------------------
  wire dcache_req_fire = dcache_bus_if.req_valid && dcache_bus_if.req_ready;
  wire lmem_req_fire   = lmem_bus_if.req_valid   && lmem_bus_if.req_ready;
  assign dcache_req_issue_fire = dcache_req_valid_w && dcache_req_ready_w;
  assign lmem_req_issue_fire = lmem_req_valid_w && lmem_req_ready_w;

  wire dcache_rsp_fire = dcache_bus_if.rsp_valid && dcache_bus_if.rsp_ready;
  wire lmem_rsp_fire   = lmem_bus_if.rsp_valid   && lmem_bus_if.rsp_ready;

  wire src_req_fire = active_dir
                    ? ((state == S_L2G_DECIDE) && lmem_req_issue_fire && (lmem_req_rw_w == 1'b0))
                    : ((state == S_G2L_DECIDE) && dcache_req_issue_fire && (dcache_req_rw_w == 1'b0));

  wire dst_req_fire = active_dir
                    ? ((state == S_L2G_DECIDE) && dcache_req_issue_fire && (dcache_req_rw_w == 1'b1))
                    : ((state == S_G2L_DECIDE) && lmem_req_issue_fire && (lmem_req_rw_w == 1'b1));

  wire src_rsp_fire = active_dir ? lmem_rsp_fire : dcache_rsp_fire;

  wire [63:0] rd_src_ptr_cur      = active_dir ? lmem_rd_ptr : dcache_rd_ptr;
  wire [31:0] rd_src_beat_bytes   = active_dir ? 32'(LMEM_BYTES) : 32'(DCACHE_BYTES);
  wire [63:0] rd_seg_valid_end    = rd_base_src_seg_r + 64'(valid_total);
  wire [31:0] rd_beat_valid_bytes = calc_read_valid_bytes(
    rd_src_ptr_cur,
    rd_seg_valid_end,
    rd_src_beat_bytes,
    valid_total
  );
  wire [63:0] rd_next_ptr = rd_src_ptr_cur + 64'(rd_src_beat_bytes);
  wire        rd_crosses_seg = active_dir ? (rd_next_ptr >= lmem_rd_end)
                                                : (rd_next_ptr >= dcache_rd_end);
  wire        rd_is_last_seg;
  wire [3:0]  rd_rollover_dep_mask;
  wire [63:0] rd_next_base;
  if (MAX_DIMS == 1) begin : g_rd_dim1
    assign rd_is_last_seg = (rd_i_dim[0] + BOUND_WIDTH'(1) >= bound_r[0]);
    assign rd_rollover_dep_mask = '0;
    assign rd_next_base = (rd_i_dim[0] + BOUND_WIDTH'(1) < bound_r[0])
        ? (rd_base_src_seg_r + 64'(stride_r[0][0])) : 64'd0;
    always_comb begin
      rd_i_dim_advance[0] = rd_i_dim[0] + BOUND_WIDTH'(1);
      rd_i_dim_advance[1] = '0;
      rd_i_dim_advance[2] = '0;
    end
  end else if (MAX_DIMS == 2) begin : g_rd_dim2
    assign rd_is_last_seg = (rd_i_dim[0] + BOUND_WIDTH'(1) >= bound_r[0])
                         && (rd_i_dim[1] + BOUND_WIDTH'(1) >= bound_r[1]);
    assign rd_rollover_dep_mask =
        (rd_i_dim[0] + BOUND_WIDTH'(1) < bound_r[0])
            ? 4'b0000 : 4'b0001;
    assign rd_next_base =
        (rd_i_dim[0] + BOUND_WIDTH'(1) < bound_r[0])
            ? (rd_base_src_seg_r + 64'(stride_r[0][0]))
            : ((rd_i_dim[1] + BOUND_WIDTH'(1) < bound_r[1])
                ? (rd_base_src_seg_r + 64'(stride_r[0][1])
                    - src_d0_correction)
                : 64'd0);
    always_comb begin
      rd_i_dim_advance[0] = rd_i_dim[0];
      rd_i_dim_advance[1] = rd_i_dim[1];
      rd_i_dim_advance[2] = '0;
      if (rd_i_dim[0] + BOUND_WIDTH'(1) < bound_r[0]) begin
        rd_i_dim_advance[0] = rd_i_dim[0] + BOUND_WIDTH'(1);
      end else begin
        rd_i_dim_advance[0] = '0;
        rd_i_dim_advance[1] = rd_i_dim[1] + BOUND_WIDTH'(1);
      end
    end
  end else begin : g_rd_dim3
    assign rd_is_last_seg = (rd_i_dim[0] + BOUND_WIDTH'(1) >= bound_r[0])
                         && (rd_i_dim[1] + BOUND_WIDTH'(1) >= bound_r[1])
                         && (rd_i_dim[2] + BOUND_WIDTH'(1) >= bound_r[2]);
    assign rd_rollover_dep_mask =
        (rd_i_dim[0] + BOUND_WIDTH'(1) < bound_r[0]) ? 4'b0000
        : (rd_i_dim[1] + BOUND_WIDTH'(1) < bound_r[1]) ? 4'b0001
                                                       : 4'b0101;
    assign rd_next_base =
        (rd_i_dim[0] + BOUND_WIDTH'(1) < bound_r[0])
            ? (rd_base_src_seg_r + 64'(stride_r[0][0]))
            : ((rd_i_dim[1] + BOUND_WIDTH'(1) < bound_r[1])
                ? (rd_base_src_seg_r + 64'(stride_r[0][1])
                    - src_d0_correction)
                : ((rd_i_dim[2] + BOUND_WIDTH'(1) < bound_r[2])
                    ? (rd_base_src_seg_r + 64'(stride_r[0][2])
                        - src_d1_correction - src_d0_correction)
                    : 64'd0));
    always_comb begin
      rd_i_dim_advance[0] = rd_i_dim[0];
      rd_i_dim_advance[1] = rd_i_dim[1];
      rd_i_dim_advance[2] = rd_i_dim[2];
      if (rd_i_dim[0] + BOUND_WIDTH'(1) < bound_r[0]) begin
        rd_i_dim_advance[0] = rd_i_dim[0] + BOUND_WIDTH'(1);
      end else begin
        rd_i_dim_advance[0] = '0;
        if (rd_i_dim[1] + BOUND_WIDTH'(1) < bound_r[1]) begin
          rd_i_dim_advance[1] = rd_i_dim[1] + BOUND_WIDTH'(1);
        end else begin
          rd_i_dim_advance[1] = '0;
          rd_i_dim_advance[2] = rd_i_dim[2] + BOUND_WIDTH'(1);
        end
      end
    end
  end
  wire rd_rollover_ready = ((precalc_ready_now & rd_rollover_dep_mask)
                            == rd_rollover_dep_mask);
  wire rd_rollover_set = src_req_fire && rd_crosses_seg
                       && !rd_is_last_seg && !rd_rollover_ready;
  wire rd_rollover_release = rd_rollover_pending_r && rd_rollover_ready;
  wire rd_rollover_advance = (src_req_fire && rd_crosses_seg
                           && !rd_is_last_seg && rd_rollover_ready)
                          || rd_rollover_release;
  wire [RD_SLOT_BITS-1:0] rsp_slot_idx = active_dir
                                       ? lmem_bus_if.rsp_data.tag.value[RD_SLOT_BITS-1:0]
                                       : dcache_bus_if.rsp_data.tag.value[RD_SLOT_BITS-1:0];

  logic [MAX_BYTES*8-1:0] slot_rsp_data_raw;
  logic [MAX_BYTES*8-1:0] slot_rsp_data;
  always_comb begin
    slot_rsp_data_raw = '0;
    if (active_dir)
      slot_rsp_data_raw[0 +: LMEM_BYTES*8] = lmem_bus_if.rsp_data.data;
    else
      slot_rsp_data_raw[0 +: DCACHE_BYTES*8] = dcache_bus_if.rsp_data.data;

    if (!ENABLE_PADDING) begin
      slot_rsp_data = slot_rsp_data_raw;
    end else begin
      slot_rsp_data = '0;
      for (int b = 0; b < MAX_BYTES; ++b) begin
        if (!SAME_WIDTH_FAST
            || (b < int'(slot_valid_bytes_r[rsp_slot_idx])))
          slot_rsp_data[b*8 +: 8] = slot_rsp_data_raw[b*8 +: 8];
      end
    end
  end

  VX_dp_ram #(
    .DATAW    (MAX_BYTES * 8),
    .SIZE     (RD_OUTSTANDING_EFF),
    .WRENW    (1),
    .OUT_REG  (1),
    .LUTRAM   (0),
    .RDW_MODE ("R"),
    .RADDR_REG(1)
  ) response_payload_ram (
    .clk   (clk),
    .reset (reset),
    .read  (wr_slot_read_fire),
    .write (src_rsp_fire),
    .wren  (1'b1),
    .waddr (rsp_slot_idx),
    .wdata (slot_rsp_data),
    .raddr (wr_expect_slot_r),
    .rdata (ram_wr_slot_data)
  );

  wire [31:0] wr_dst_beat_bytes = active_dir ? 32'(DCACHE_BYTES) : 32'(LMEM_BYTES);
  wire [31:0] wr_remaining;
  wire [31:0] wr_nbytes_cur;
  wire [31:0] wr_src_bytes_cur;
  wire        wr_seg_complete_fire;
  if (FIXED_1D_WRITE_COUNTER) begin : g_fixed_1d_write_count
    // The output DMA has fixed DIR=1, equal bus widths, and zero padding.
    // Descriptor-time division by the power-of-two beat size leaves only a
    // small remaining-beat test on the per-beat request path.
    assign wr_remaining = 32'd0;
    assign wr_nbytes_cur = (wr_beats_remaining_r == 0)
                         ? 32'd0
                         : ((wr_beats_remaining_r == WR_BEAT_COUNT_W'(1))
                            ? 32'(wr_final_bytes_r)
                            : 32'(DCACHE_BYTES));
    assign wr_src_bytes_cur = wr_nbytes_cur;
    assign wr_seg_complete_fire = dst_req_fire
                                && (wr_beats_remaining_r
                                    == WR_BEAT_COUNT_W'(1));
  end else begin : g_generic_write_count
    assign wr_remaining = (out_off < seg_size_r)
                        ? (seg_size_r - out_off) : 32'd0;
    assign wr_nbytes_cur = umin32(wr_remaining, wr_dst_beat_bytes);
    assign wr_src_bytes_cur = ENABLE_PADDING
                            ? calc_src_bytes(out_off, valid_total,
                                             wr_nbytes_cur)
                            : wr_nbytes_cur;
    assign wr_seg_complete_fire = dst_req_fire
                                && (out_off + wr_nbytes_cur >= seg_size_r);
  end
  assign wr_payload_needed = (wr_src_bytes_cur != 0);
  wire        wr_is_last_seg;
  wire [3:0] wr_rollover_dep_mask;
  wire wr_rollover_ready = ((precalc_ready_now & wr_rollover_dep_mask)
                            == wr_rollover_dep_mask);
  wire wr_rollover_set = wr_seg_complete_fire
                       && !wr_is_last_seg && !wr_rollover_ready;
  wire wr_rollover_release = wr_rollover_pending_r && wr_rollover_ready;
  wire wr_rollover_advance = (wr_seg_complete_fire
                           && !wr_is_last_seg && wr_rollover_ready)
                          || wr_rollover_release;
  wire [63:0] wr_next_base_src;
  wire [63:0] wr_next_base_dst;
  if (MAX_DIMS == 1) begin : g_wr_dim1
    assign wr_is_last_seg = (wr_i_dim[0] + BOUND_WIDTH'(1) >= bound_r[0]);
    assign wr_rollover_dep_mask = '0;
    assign wr_next_base_src =
        (wr_i_dim[0] + BOUND_WIDTH'(1) < bound_r[0])
            ? (wr_base_src_seg_r + 64'(stride_r[0][0])) : 64'd0;
    assign wr_next_base_dst =
        (wr_i_dim[0] + BOUND_WIDTH'(1) < bound_r[0])
            ? (wr_base_dst_seg_r + 64'(stride_r[1][0])) : 64'd0;
    always_comb begin
      wr_i_dim_advance[0] = wr_i_dim[0] + BOUND_WIDTH'(1);
      wr_i_dim_advance[1] = '0;
      wr_i_dim_advance[2] = '0;
    end
  end else if (MAX_DIMS == 2) begin : g_wr_dim2
    assign wr_is_last_seg = (wr_i_dim[0] + BOUND_WIDTH'(1) >= bound_r[0])
                         && (wr_i_dim[1] + BOUND_WIDTH'(1) >= bound_r[1]);
    assign wr_rollover_dep_mask =
        (wr_i_dim[0] + BOUND_WIDTH'(1) < bound_r[0])
            ? 4'b0000 : 4'b0011;
    assign wr_next_base_src =
        (wr_i_dim[0] + BOUND_WIDTH'(1) < bound_r[0])
            ? (wr_base_src_seg_r + 64'(stride_r[0][0]))
            : ((wr_i_dim[1] + BOUND_WIDTH'(1) < bound_r[1])
                ? (wr_base_src_seg_r + 64'(stride_r[0][1])
                    - src_d0_correction)
                : 64'd0);
    assign wr_next_base_dst =
        (wr_i_dim[0] + BOUND_WIDTH'(1) < bound_r[0])
            ? (wr_base_dst_seg_r + 64'(stride_r[1][0]))
            : ((wr_i_dim[1] + BOUND_WIDTH'(1) < bound_r[1])
                ? (wr_base_dst_seg_r + 64'(stride_r[1][1])
                    - dst_d0_correction)
                : 64'd0);
    always_comb begin
      wr_i_dim_advance[0] = wr_i_dim[0];
      wr_i_dim_advance[1] = wr_i_dim[1];
      wr_i_dim_advance[2] = '0;
      if (wr_i_dim[0] + BOUND_WIDTH'(1) < bound_r[0]) begin
        wr_i_dim_advance[0] = wr_i_dim[0] + BOUND_WIDTH'(1);
      end else begin
        wr_i_dim_advance[0] = '0;
        wr_i_dim_advance[1] = wr_i_dim[1] + BOUND_WIDTH'(1);
      end
    end
  end else begin : g_wr_dim3
    assign wr_is_last_seg = (wr_i_dim[0] + BOUND_WIDTH'(1) >= bound_r[0])
                         && (wr_i_dim[1] + BOUND_WIDTH'(1) >= bound_r[1])
                         && (wr_i_dim[2] + BOUND_WIDTH'(1) >= bound_r[2]);
    assign wr_rollover_dep_mask =
        (wr_i_dim[0] + BOUND_WIDTH'(1) < bound_r[0]) ? 4'b0000
        : (wr_i_dim[1] + BOUND_WIDTH'(1) < bound_r[1]) ? 4'b0011
                                                       : 4'b1111;
    assign wr_next_base_src =
        (wr_i_dim[0] + BOUND_WIDTH'(1) < bound_r[0])
            ? (wr_base_src_seg_r + 64'(stride_r[0][0]))
            : ((wr_i_dim[1] + BOUND_WIDTH'(1) < bound_r[1])
                ? (wr_base_src_seg_r + 64'(stride_r[0][1])
                    - src_d0_correction)
                : ((wr_i_dim[2] + BOUND_WIDTH'(1) < bound_r[2])
                    ? (wr_base_src_seg_r + 64'(stride_r[0][2])
                        - src_d1_correction - src_d0_correction)
                    : 64'd0));
    assign wr_next_base_dst =
        (wr_i_dim[0] + BOUND_WIDTH'(1) < bound_r[0])
            ? (wr_base_dst_seg_r + 64'(stride_r[1][0]))
            : ((wr_i_dim[1] + BOUND_WIDTH'(1) < bound_r[1])
                ? (wr_base_dst_seg_r + 64'(stride_r[1][1])
                    - dst_d0_correction)
                : ((wr_i_dim[2] + BOUND_WIDTH'(1) < bound_r[2])
                    ? (wr_base_dst_seg_r + 64'(stride_r[1][2])
                        - dst_d1_correction - dst_d0_correction)
                    : 64'd0));
    always_comb begin
      wr_i_dim_advance[0] = wr_i_dim[0];
      wr_i_dim_advance[1] = wr_i_dim[1];
      wr_i_dim_advance[2] = wr_i_dim[2];
      if (wr_i_dim[0] + BOUND_WIDTH'(1) < bound_r[0]) begin
        wr_i_dim_advance[0] = wr_i_dim[0] + BOUND_WIDTH'(1);
      end else begin
        wr_i_dim_advance[0] = '0;
        if (wr_i_dim[1] + BOUND_WIDTH'(1) < bound_r[1]) begin
          wr_i_dim_advance[1] = wr_i_dim[1] + BOUND_WIDTH'(1);
        end else begin
          wr_i_dim_advance[1] = '0;
          wr_i_dim_advance[2] = wr_i_dim[2] + BOUND_WIDTH'(1);
        end
      end
    end
  end
  wire        dst_payload_fire = dst_req_fire && wr_payload_needed;

  // Slot-read stage. The selected response RAM slot remains SLOT_DRAINING and
  // its registered output remains stable until the destination datapath
  // consumes it. No wide payload is copied into an elastic buffer.
  assign wr_slot_read_valid = ((state == S_L2G_DECIDE) || (state == S_G2L_DECIDE))
                           && (wr_state == WR_RUN)
                           && (slot_state_r[wr_expect_slot_r] == SLOT_READY);
  assign wr_slot_read_fire = wr_slot_read_valid && wr_slot_read_ready;

  // Pull/drain overlap from the registered RAM output into the width-conversion
  // window. A drained slot can be replaced by the next RAM read in the same cycle.
  wire wr_window_can_pull = !SAME_WIDTH_FAST
                         && ((state == S_L2G_DECIDE) || (state == S_G2L_DECIDE))
                         && (wr_state == WR_RUN)
                         && (active_dir
                             ? (win_lmem_valid   <= WIN_VALID_W'(WIN_BYTES - LMEM_BYTES))
                             : (win_dcache_valid <= WIN_VALID_W'(WIN_BYTES - DCACHE_BYTES)));
  wire wr_window_pull = wr_slot_valid_r && wr_window_can_pull;

  assign wr_slot_pop_ready = SAME_WIDTH_FAST
                           ? (dst_req_fire
                              && (ENABLE_PADDING ? wr_payload_needed : 1'b1))
                           : wr_window_can_pull;
  assign wr_slot_drain_fire = wr_slot_valid_r && wr_slot_pop_ready;
  wire slot_release_fire = wr_slot_drain_fire;
  assign wr_slot_pending_next = (wr_slot_pending_r && !wr_slot_drain_fire)
                              || wr_slot_read_fire;
  assign dcache_req_buf_pending_next = dcache_req_buf_pending_r
                                     + 2'(dcache_req_issue_fire)
                                     - 2'(dcache_req_fire);
  assign lmem_req_buf_pending_next = lmem_req_buf_pending_r
                                   + 2'(lmem_req_issue_fire)
                                   - 2'(lmem_req_fire);

  always_ff @(posedge clk) begin
    if (reset || cmd_start || (state == S_PREP_SEG)) begin
      ram_wr_slot_valid_r <= 1'b0;
      ram_wr_slot_valid_bytes_r <= '0;
      ram_wr_slot_r <= '0;
    end else if ((state == S_L2G_DECIDE) || (state == S_G2L_DECIDE)) begin
      unique case ({wr_slot_read_fire, wr_slot_drain_fire})
        2'b10: ram_wr_slot_valid_r <= 1'b1;
        2'b01: ram_wr_slot_valid_r <= 1'b0;
        2'b11: ram_wr_slot_valid_r <= 1'b1;
        default:;
      endcase
      if (wr_slot_read_fire) begin
        ram_wr_slot_valid_bytes_r <= slot_valid_bytes_r[wr_expect_slot_r];
        ram_wr_slot_r <= wr_expect_slot_r;
      end
    end
  end

`ifndef SYNTHESIS
  logic ram_wr_stall_r;
  logic [MAX_BYTES*8-1:0] ram_wr_stall_data_r;
  logic [WIN_VALID_W-1:0] ram_wr_stall_valid_bytes_r;
  logic [RD_SLOT_BITS-1:0] ram_wr_stall_slot_r;

  always_ff @(posedge clk) begin
    if (reset) begin
      ram_wr_stall_r <= 1'b0;
      ram_wr_stall_data_r <= '0;
      ram_wr_stall_valid_bytes_r <= '0;
      ram_wr_stall_slot_r <= '0;
    end else begin
      if (dst_req_fire && !lookahead_if.data_release)
        $fatal(1, "%s: destination request issued before data release",
               INSTANCE_ID);
      if (!ENABLE_PADDING && dst_req_fire)
        assert (wr_src_bytes_cur == wr_nbytes_cur)
          else $fatal(1,
              "%s: padding-disabled write byte mismatch src=%0d dst=%0d",
              INSTANCE_ID, wr_src_bytes_cur, wr_nbytes_cur);
      if (src_req_fire && !lookahead_if.data_release
       && ((data_max_beats_r == 0)
        || (pre_release_reads_r >= data_max_beats_r)))
        $fatal(1, "%s: pre-release source-read credit exceeded",
               INSTANCE_ID);
      if (src_rsp_fire && (slot_state_r[rsp_slot_idx] != SLOT_WAIT_RSP))
        $fatal(1, "%s: response wrote slot %0d in state %0d",
               INSTANCE_ID, rsp_slot_idx, slot_state_r[rsp_slot_idx]);
      if (wr_slot_read_fire && (slot_state_r[wr_expect_slot_r] != SLOT_READY))
        $fatal(1, "%s: SRAM read issued for non-ready slot %0d",
               INSTANCE_ID, wr_expect_slot_r);
      if (wr_slot_drain_fire
          && (slot_state_r[ram_wr_slot_r] != SLOT_DRAINING))
        $fatal(1, "%s: destination drained non-draining slot %0d",
               INSTANCE_ID, ram_wr_slot_r);
      if (src_rsp_fire && wr_slot_read_fire && (rsp_slot_idx == wr_expect_slot_r))
        $fatal(1, "%s: simultaneous response write and drain read for slot %0d",
               INSTANCE_ID, rsp_slot_idx);

      if (ram_wr_stall_r
          && ((ram_wr_slot_data != ram_wr_stall_data_r)
              || (ram_wr_slot_valid_bytes_r != ram_wr_stall_valid_bytes_r)
              || (ram_wr_slot_r != ram_wr_stall_slot_r)))
        $fatal(1, "%s: response SRAM output changed during destination stall",
               INSTANCE_ID);

      ram_wr_stall_r <= ram_wr_slot_valid_r && !wr_slot_pop_ready;
      ram_wr_stall_data_r <= ram_wr_slot_data;
      ram_wr_stall_valid_bytes_r <= ram_wr_slot_valid_bytes_r;
      ram_wr_stall_slot_r <= ram_wr_slot_r;
    end
  end
`endif

`ifndef SYNTHESIS
  logic rd_rollover_release_seen_r;
  logic wr_rollover_release_seen_r;

  always_ff @(posedge clk) begin
    if (reset || cmd_start || (state == S_PREP_SEG)) begin
      rd_rollover_release_seen_r <= 1'b0;
      wr_rollover_release_seen_r <= 1'b0;
    end else begin
      if (rd_rollover_set) begin
        if (rd_rollover_pending_r)
          $fatal(1, "%s: read rollover was queued twice", INSTANCE_ID);
        rd_rollover_release_seen_r <= 1'b0;
      end
      if (wr_rollover_set) begin
        if (wr_rollover_pending_r)
          $fatal(1, "%s: write rollover was queued twice", INSTANCE_ID);
        wr_rollover_release_seen_r <= 1'b0;
      end

      if (rd_rollover_release) begin
        if (!rd_rollover_pending_r || rd_rollover_release_seen_r)
          $fatal(1, "%s: read rollover released more than once", INSTANCE_ID);
        rd_rollover_release_seen_r <= 1'b1;
      end
      if (wr_rollover_release) begin
        if (!wr_rollover_pending_r || wr_rollover_release_seen_r)
          $fatal(1, "%s: write rollover released more than once", INSTANCE_ID);
        wr_rollover_release_seen_r <= 1'b1;
      end

      if (rd_rollover_advance
          && ((precalc_ready_now & rd_rollover_dep_mask)
              != rd_rollover_dep_mask))
        $fatal(1, "%s: read rollover consumed an invalid correction",
               INSTANCE_ID);
      if (wr_rollover_advance
          && ((precalc_ready_now & wr_rollover_dep_mask)
              != wr_rollover_dep_mask))
        $fatal(1, "%s: write rollover consumed an invalid correction",
               INSTANCE_ID);
    end
  end
`endif

  logic [WIN_BYTES*8-1:0] win_lmem_next;
  logic [WIN_VALID_W-1:0] win_lmem_valid_next;
  logic [WIN_VALID_W-1:0] win_lmem_head_next;
  logic [WIN_BYTES*8-1:0] win_dcache_next;
  logic [WIN_VALID_W-1:0] win_dcache_valid_next;
  logic [WIN_VALID_W-1:0] win_dcache_head_next;
  logic [31:0]            out_off_next;
  logic [BOUND_WIDTH-1:0] wr_i_dim_next[NDIM];
  logic [63:0]            wr_base_src_seg_next;
  logic [63:0]            wr_base_dst_seg_next;
  wr_state_e              wr_state_next;
  logic                   wr_rollover_pending_next;

  always_comb begin
    int lmem_tail;
    int dcache_tail;

    win_lmem_next         = win_lmem;
    win_lmem_valid_next   = win_lmem_valid;
    win_lmem_head_next    = win_lmem_head;
    win_dcache_next       = win_dcache;
    win_dcache_valid_next = win_dcache_valid;
    win_dcache_head_next  = win_dcache_head;
    out_off_next          = out_off;
    wr_base_src_seg_next  = wr_base_src_seg_r;
    wr_base_dst_seg_next  = wr_base_dst_seg_r;
    wr_state_next         = wr_state;
    wr_rollover_pending_next = wr_rollover_pending_r;
    lmem_tail             = 0;
    dcache_tail           = 0;
    for (int d = 0; d < NDIM; d++) begin
      wr_i_dim_next[d] = wr_i_dim[d];
    end

    if ((state == S_L2G_DECIDE) || (state == S_G2L_DECIDE)) begin
      if (SAME_WIDTH_FAST) begin
        win_lmem_next         = '0;
        win_lmem_valid_next   = '0;
        win_lmem_head_next    = '0;
        win_dcache_next       = '0;
        win_dcache_valid_next = '0;
        win_dcache_head_next  = '0;
      end else if (state == S_L2G_DECIDE) begin
        if (dst_req_fire && active_dir && (wr_src_bytes_cur != 0)) begin
          if (wr_src_bytes_cur[WIN_VALID_W-1:0] >= win_lmem_valid_next) begin
            win_lmem_valid_next = '0;
            win_lmem_head_next  = '0;
          end else begin
            win_lmem_valid_next = win_lmem_valid_next - wr_src_bytes_cur[WIN_VALID_W-1:0];
            win_lmem_head_next  = WIN_VALID_W'(
                (int'(win_lmem_head_next) + int'(wr_src_bytes_cur)) % WIN_BYTES);
          end
        end

        if (wr_window_pull && active_dir && (win_lmem_valid_next + LMEM_BYTES <= WIN_BYTES)) begin
          lmem_tail = (int'(win_lmem_head_next) + int'(win_lmem_valid_next)) % WIN_BYTES;
          for (int pos = 0; pos < WIN_BYTES; pos++) begin
            if (lmem_tail == pos) begin
              for (int b = 0; b < LMEM_BYTES; b++) begin
                if (b < int'(wr_slot_valid_bytes_r))
                  win_lmem_next[((pos + b) % WIN_BYTES)*8 +: 8]
                      = wr_slot_data_r[b*8 +: 8];
              end
            end
          end
          win_lmem_valid_next = win_lmem_valid_next + wr_slot_valid_bytes_r;
          if (win_lmem_valid_next == '0)
            win_lmem_head_next = '0;
        end
      end else begin
        if (dst_req_fire && !active_dir && (wr_src_bytes_cur != 0)) begin
          if (wr_src_bytes_cur[WIN_VALID_W-1:0] >= win_dcache_valid_next) begin
            win_dcache_valid_next = '0;
            win_dcache_head_next  = '0;
          end else begin
            win_dcache_valid_next = win_dcache_valid_next - wr_src_bytes_cur[WIN_VALID_W-1:0];
            win_dcache_head_next  = WIN_VALID_W'(
                (int'(win_dcache_head_next) + int'(wr_src_bytes_cur)) % WIN_BYTES);
          end
        end

        if (wr_window_pull && !active_dir && (win_dcache_valid_next + DCACHE_BYTES <= WIN_BYTES)) begin
          dcache_tail = (int'(win_dcache_head_next) + int'(win_dcache_valid_next)) % WIN_BYTES;
          for (int pos = 0; pos < WIN_BYTES; pos++) begin
            if (dcache_tail == pos) begin
              for (int b = 0; b < DCACHE_BYTES; b++) begin
                if (b < int'(wr_slot_valid_bytes_r))
                  win_dcache_next[((pos + b) % WIN_BYTES)*8 +: 8]
                      = wr_slot_data_r[b*8 +: 8];
              end
            end
          end
          win_dcache_valid_next = win_dcache_valid_next + wr_slot_valid_bytes_r;
          if (win_dcache_valid_next == '0)
            win_dcache_head_next = '0;
        end
      end

      if (dst_req_fire) begin
        out_off_next = out_off + wr_nbytes_cur;
        if (wr_seg_complete_fire) begin
          if (wr_is_last_seg) begin
            wr_state_next = WR_DONE;
          end else if (wr_rollover_set) begin
            // Preserve the completed segment until its carry corrections
            // arrive. The read iterator and response drain remain active.
            wr_rollover_pending_next = 1'b1;
          end
        end
      end

      if (wr_rollover_advance) begin
        for (int d = 0; d < NDIM; ++d)
          wr_i_dim_next[d] = wr_i_dim_advance[d];
        wr_base_src_seg_next = wr_next_base_src;
        wr_base_dst_seg_next = wr_next_base_dst;
        out_off_next = 32'd0;
        wr_rollover_pending_next = 1'b0;
        if (!SAME_WIDTH_FAST && (state == S_L2G_DECIDE)
            && (win_lmem_valid_next == '0))
          win_lmem_head_next = '0;
        if (!SAME_WIDTH_FAST && (state == S_G2L_DECIDE)
            && (win_dcache_valid_next == '0))
          win_dcache_head_next = '0;
      end
    end
  end

  // ------------------------------------------------------------
  // Trace logging
  // ------------------------------------------------------------
`ifdef DBG_TRACE_GEMM_CTRL
  always_ff @(posedge clk) begin
    if (!reset) begin
      if (state != state_n) begin
        `TRACE(3, ("%m : [%0t] | DMA_STATE_TRANSITION | {inst=%s, from=%s, to=%s, out_off=%0d, finished=%0d, i0=%0d, i1=%0d, i2=%0d}\n",
                  $time, INSTANCE_ID, state_to_str(state), state_to_str(state_n),
                  out_off, finished, wr_i_dim[0], wr_i_dim[1], wr_i_dim[2]))
      end

      if (cmd_start) begin
        `TRACE(2, ("%m : [%0t] | DMA_START | {inst=%s, entry_id=%0d, dir=%0d, src_base=0x%0h, dst_base=0x%0h, seg_size=%0d, padding=%0d, bound=[%0d,%0d,%0d]}\n",
                  $time, INSTANCE_ID, cfg_reg_if.entry_id, cmd_dir,
                  {cfg_reg_if.regs[4][31:0], cfg_reg_if.regs[3][31:0]},
                  {cfg_reg_if.regs[2][31:0], cfg_reg_if.regs[1][31:0]},
                  cfg_reg_if.regs[14][31:0], cfg_reg_if.regs[15][31:0],
                  cfg_reg_if.regs[11][31:0], cfg_reg_if.regs[12][31:0], cfg_reg_if.regs[13][31:0]))
        foreach (regs_latched[k]) begin
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
        `TRACE(2, ("%m : [%0t] | DMA_SETUP_MUL_ISSUE | {inst=%s, needed=0x%0h, src_stride0=%0d, src_bound0_m1=%0d, src_stride1=%0d, src_bound1_m1=%0d, dst_stride0=%0d, dst_bound0_m1=%0d, dst_stride1=%0d, dst_bound1_m1=%0d}\n",
                  $time, INSTANCE_ID,
                  precalc_needed_r,
                  stride_r[0][0], bound_r[0] - BOUND_WIDTH'(1),
                  stride_r[0][1], bound_r[1] - BOUND_WIDTH'(1),
                  stride_r[1][0], bound_r[0] - BOUND_WIDTH'(1),
                  stride_r[1][1], bound_r[1] - BOUND_WIDTH'(1)))
      end

      if (|precalc_valid) begin
        `TRACE(2, ("%m : [%0t] | DMA_SETUP_MUL_DONE | {inst=%s, ready=0x%0h, src_stride_bound0=0x%0h, src_stride_bound1=0x%0h, dst_stride_bound0=0x%0h, dst_stride_bound1=0x%0h}\n",
                  $time, INSTANCE_ID,
                  precalc_ready_now,
                  src_d0_correction, src_d1_correction,
                  dst_d0_correction, dst_d1_correction))
      end

      if (state == S_PREP_SEG) begin
        `TRACE(2, ("%m : [%0t] | DMA_SEG_PREP | {inst=%s, mode=%s, i0=%0d, i1=%0d, i2=%0d, src_base=0x%0h, dst_base=0x%0h, seg_size=%0d, valid_total=%0d, padding=%0d, src_rd_ptr=0x%0h, src_rd_end=0x%0h}\n",
                  $time, INSTANCE_ID, active_dir ? "L2G" : "G2L",
                  wr_i_dim[0], wr_i_dim[1], wr_i_dim[2], rd_base_src_seg, wr_base_dst_seg,
                  seg_size_r, valid_total, padding_r,
                  active_dir ? align_down(rd_base_src_seg, LMEM_BYTES) : align_down(rd_base_src_seg, DCACHE_BYTES),
                  active_dir ? align_up(rd_base_src_seg + 64'(valid_total), LMEM_BYTES)
                                  : align_up(rd_base_src_seg + 64'(valid_total), DCACHE_BYTES)))
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

      // Note: legacy DMA_SEG_ADVANCE trace (fired in S_ADV_SEG) removed.
      // Per-seg advance now happens inline in src_req_fire / dst_req_fire;
      // add a finer trace there if needed for debugging.

      if (state != S_DONE && state_n == S_DONE) begin
        `TRACE(2, ("%m : [%0t] | DMA_DONE_ASSERT | {inst=%s, entry_id=%0d, i0=%0d, i1=%0d, i2=%0d}\n",
                  $time, INSTANCE_ID, entry_id_latched, wr_i_dim[0], wr_i_dim[1], wr_i_dim[2]))
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
    dcache_req_valid_w = 1'b0;
    dcache_req_rw_w = 1'b0;
    dcache_req_addr_w = '0;
    dcache_req_data_w = '0;
    dcache_req_byteen_w = '0;
    dcache_req_flags_w = '0;
    dcache_req_tag_uuid_w = '0;
    dcache_req_tag_value_w = '0;
    dcache_bus_if.rsp_ready = 1'b1;

    lmem_req_valid_w = 1'b0;
    lmem_req_rw_w = 1'b0;
    lmem_req_addr_w = '0;
    lmem_req_data_w = '0;
    lmem_req_byteen_w = '0;
    lmem_req_flags_w = '0;
    lmem_req_tag_uuid_w = '0;
    lmem_req_tag_value_w = '0;
    lmem_bus_if.rsp_ready = 1'b1;

    state_n = state;

    unique case (state)
      S_IDLE: begin
        if (cmd_start) begin
          if (cmd_fast_path)
            state_n = cmd_dir ? S_L2G_DECIDE : S_G2L_DECIDE;
          else
            state_n = S_PRECALC;
        end
      end

      S_PRECALC: begin
        if (precalc_done)
          state_n = S_PREP_SEG;
      end

      S_PREP_SEG: begin
        // Entered exactly once per descriptor (from S_PRECALC) to perform
        // the initial segment init. Descriptor completion is detected by
        // the DECIDE states' exit condition, not here.
        state_n = active_dir ? S_L2G_DECIDE : S_G2L_DECIDE;
      end

      // ==========================================================
      // L2G (LMEM -> DCACHE), decoupled RD/WR
      // ==========================================================
      S_L2G_DECIDE: begin
        logic rd_can_issue;
        logic wr_can_issue;
        logic [SLOT_OCC_W-1:0] occ_next;

        logic [LMEM_TAG_VALUE_W-1:0] rd_tag_value;

        logic [63:0] dst_byte;
        int          lane;
        logic [31:0] remaining;
        logic [31:0] beat_room;
        logic [31:0] wr_nbytes;
        logic [31:0] src_bytes;
        logic [DCACHE_BYTES*8-1:0] wr_data;
        logic [DCACHE_BYTES-1:0]   wr_byteen;

        rd_can_issue = (rd_state == RD_RUN)
                    && (lmem_rd_ptr < lmem_rd_end)
                    && source_issue_enable
                    && (slot_occupancy_r < SLOT_OCC_W'(RD_OUTSTANDING_EFF))
                    && (slot_state_r[rd_issue_slot_r] == SLOT_FREE);

        if (rd_can_issue) begin
          rd_tag_value = '0;
          rd_tag_value[RD_SLOT_BITS-1:0] = rd_issue_slot_r;

          lmem_req_valid_w     = 1'b1;
          lmem_req_rw_w        = 1'b0;
          lmem_req_addr_w      = to_lmem_addr(lmem_rd_ptr);
          lmem_req_data_w      = '0;
          lmem_req_byteen_w    = mask_lmem_range(0, int'(rd_beat_valid_bytes));
          lmem_req_flags_w     = '0;
          lmem_req_tag_uuid_w  = dma_uuid;
          lmem_req_tag_value_w = rd_tag_value;
        end

        dst_byte   = wr_base_dst_seg + 64'(out_off);
        // In aligned mode the destination base is guaranteed 0-mod-BUS, so
        // lane folds to 0 at every beat and the assembler below degenerates
        // to a direct window read. Elaboration-time constant.
        lane       = 0;
        remaining  = wr_remaining;
        beat_room  = wr_dst_beat_bytes;
        wr_nbytes  = wr_nbytes_cur;
        src_bytes  = wr_src_bytes_cur;

        // Source and destination beats can have different widths, so require
        // the exact number of payload bytes consumed by this destination beat.
        wr_can_issue = (wr_state == WR_RUN)
                    && lookahead_if.data_release
                    && (wr_nbytes != 0)
                    && (SAME_WIDTH_FAST
                        ? ((src_bytes == 0)
                           || (wr_slot_valid_r && (wr_slot_valid_bytes_r >= src_bytes[WIN_VALID_W-1:0])))
                        : ((src_bytes == 0) || (win_lmem_valid >= src_bytes[WIN_VALID_W-1:0])));

        if (wr_can_issue) begin
          wr_data = '0;
          if (SAME_WIDTH_FAST) begin
            wr_data = wr_slot_data_r;
          end else begin
            for (int b = 0; b < DCACHE_BYTES; b++) begin
              if (b < int'(src_bytes)) begin
                for (int pos = 0; pos < WIN_BYTES; pos++) begin
                  if (win_lmem_head == WIN_VALID_W'(pos))
                    wr_data[b*8 +: 8]
                        = win_lmem[((pos + b) % WIN_BYTES)*8 +: 8];
                end
              end
            end
          end

          wr_byteen = mask_dcache_range(lane, int'(wr_nbytes));

          dcache_req_valid_w     = 1'b1;
          dcache_req_rw_w        = 1'b1;
          dcache_req_addr_w      = to_dcache_addr(dst_byte - 64'(lane));
          dcache_req_data_w      = wr_data;
          dcache_req_byteen_w    = wr_byteen;
          dcache_req_flags_w     = '0;
          dcache_req_tag_uuid_w  = dma_uuid;
          dcache_req_tag_value_w = '0;
        end

        occ_next = slot_occupancy_r;
        unique case ({src_req_fire, slot_release_fire})
          2'b10: occ_next = slot_occupancy_r + SLOT_OCC_W'(1);
          2'b01: occ_next = slot_occupancy_r - SLOT_OCC_W'(1);
          default:;
        endcase

        // Both rd and wr have issued/drained the descriptor's last seg.
        // With seg advances handled inline by the req_fire handlers, this
        // condition now signals descriptor-level completion.
        if ((rd_state == RD_DONE) && (wr_state == WR_DONE)
            && (occ_next == 0)
            && !wr_slot_pending_next
            && (dcache_req_buf_pending_next == 0)
            && (lmem_req_buf_pending_next == 0))
          state_n = S_DONE;
      end

      // ==========================================================
      // G2L (DCACHE -> LMEM), decoupled RD/WR
      // ==========================================================
      S_G2L_DECIDE: begin
        logic rd_can_issue;
        logic wr_can_issue;
        logic [SLOT_OCC_W-1:0] occ_next;

        logic [DCACHE_TAG_VALUE_W-1:0] rd_tag_value;

        logic [63:0] dst_byte;
        int          lane;
        logic [31:0] remaining;
        logic [31:0] beat_room;
        logic [31:0] wr_nbytes;
        logic [31:0] src_bytes;
        logic [LMEM_BYTES*8-1:0] wr_data;
        logic [LMEM_BYTES-1:0]   wr_byteen;

        rd_can_issue = (rd_state == RD_RUN)
                    && (dcache_rd_ptr < dcache_rd_end)
                    && source_issue_enable
                    && (slot_occupancy_r < SLOT_OCC_W'(RD_OUTSTANDING_EFF))
                    && (slot_state_r[rd_issue_slot_r] == SLOT_FREE);

        if (rd_can_issue) begin
          rd_tag_value = '0;
          rd_tag_value[RD_SLOT_BITS-1:0] = rd_issue_slot_r;

          dcache_req_valid_w     = 1'b1;
          dcache_req_rw_w        = 1'b0;
          dcache_req_addr_w      = to_dcache_addr(dcache_rd_ptr);
          dcache_req_byteen_w    = mask_dcache_range(0, int'(rd_beat_valid_bytes));
          dcache_req_flags_w     = '0;
          dcache_req_tag_uuid_w  = dma_uuid;
          dcache_req_tag_value_w = rd_tag_value;
        end

        dst_byte   = wr_base_dst_seg + 64'(out_off);
        lane       = 0;
        remaining  = wr_remaining;
        beat_room  = wr_dst_beat_bytes;
        wr_nbytes  = wr_nbytes_cur;
        src_bytes  = wr_src_bytes_cur;

        wr_can_issue = (wr_state == WR_RUN)
                    && lookahead_if.data_release
                    && (wr_nbytes != 0)
                    && (SAME_WIDTH_FAST
                        ? ((src_bytes == 0)
                           || (wr_slot_valid_r && (wr_slot_valid_bytes_r >= src_bytes[WIN_VALID_W-1:0])))
                        : ((src_bytes == 0) || (win_dcache_valid >= src_bytes[WIN_VALID_W-1:0])));

        if (wr_can_issue) begin
          wr_data = '0;
          if (SAME_WIDTH_FAST) begin
            wr_data = wr_slot_data_r;
          end else begin
            for (int b = 0; b < LMEM_BYTES; b++) begin
              if (b < int'(src_bytes)) begin
                for (int pos = 0; pos < WIN_BYTES; pos++) begin
                  if (win_dcache_head == WIN_VALID_W'(pos))
                    wr_data[b*8 +: 8]
                        = win_dcache[((pos + b) % WIN_BYTES)*8 +: 8];
                end
              end
            end
          end

          wr_byteen = mask_lmem_range(lane, int'(wr_nbytes));

          lmem_req_valid_w     = 1'b1;
          lmem_req_rw_w        = 1'b1;
          lmem_req_addr_w      = to_lmem_addr(dst_byte - 64'(lane));
          lmem_req_data_w      = wr_data;
          lmem_req_byteen_w    = wr_byteen;
          lmem_req_flags_w     = '0;
          lmem_req_tag_uuid_w  = dma_uuid;
          lmem_req_tag_value_w = '0;
        end

        occ_next = slot_occupancy_r;
        unique case ({src_req_fire, slot_release_fire})
          2'b10: occ_next = slot_occupancy_r + SLOT_OCC_W'(1);
          2'b01: occ_next = slot_occupancy_r - SLOT_OCC_W'(1);
          default:;
        endcase

        // Both rd and wr have issued/drained the descriptor's last seg.
        // With seg advances handled inline by the req_fire handlers, this
        // condition now signals descriptor-level completion.
        if ((rd_state == RD_DONE) && (wr_state == WR_DONE)
            && (occ_next == 0)
            && !wr_slot_pending_next
            && (dcache_req_buf_pending_next == 0)
            && (lmem_req_buf_pending_next == 0))
          state_n = S_DONE;
      end

      // Legacy single-step states are no longer used; route back to decoupled run states.
      S_L2G_SRC_RD_REQ,
      S_L2G_SRC_RD_WAIT,
      S_L2G_DST_WR_REQ: begin
        state_n = S_L2G_DECIDE;
      end

      S_G2L_SRC_RD_REQ,
      S_G2L_SRC_RD_WAIT,
      S_G2L_DST_WR_REQ: begin
        state_n = S_G2L_DECIDE;
      end

      S_DONE: begin
        if (cmd_start) begin
          if (cmd_fast_path)
            state_n = cmd_dir ? S_L2G_DECIDE : S_G2L_DECIDE;
          else
            state_n = S_PRECALC;
        end else if (done_if.ready) begin
          state_n = S_IDLE;
        end
      end

      default: begin
        state_n = S_IDLE;
      end
    endcase
  end

  // Output-only descriptor-time write geometry.  The count reloads at a 1D
  // segment boundary, so arbitrary bound0 values retain the generic engine's
  // segment ordering without a per-beat seg_size subtraction/comparison.
  always_ff @(posedge clk) begin
    if (reset) begin
      wr_beats_per_seg_r <= '0;
      wr_beats_remaining_r <= '0;
      wr_final_bytes_r <= '0;
    end else if (cmd_start) begin
      wr_beats_per_seg_r <= cmd_wr_beats_per_seg;
      wr_beats_remaining_r <= cmd_wr_beats_per_seg;
      wr_final_bytes_r <= cmd_wr_final_bytes;
    end else if (FIXED_1D_WRITE_COUNTER) begin
      if (wr_rollover_advance) begin
        wr_beats_remaining_r <= wr_beats_per_seg_r;
      end else if (dst_req_fire && (wr_beats_remaining_r != 0)) begin
        wr_beats_remaining_r <= wr_beats_remaining_r
                              - WR_BEAT_COUNT_W'(1);
      end
    end
  end

`ifndef SYNTHESIS
  always_ff @(posedge clk) begin
    if (!reset && FIXED_1D_WRITE_COUNTER) begin
      if (cfg_fire) begin
        assert (cfg_reg_if.regs[15] == 0)
          else $fatal(1,
              "%s: fixed 1D write counter requires zero padding",
              INSTANCE_ID);
      end
      if (dst_req_fire) begin
        assert (wr_beats_remaining_r != 0)
          else $fatal(1, "%s: fixed 1D write counter underflow", INSTANCE_ID);
        assert (wr_nbytes_cur
             == umin32((out_off < seg_size_r)
                       ? (seg_size_r - out_off) : 32'd0,
                       wr_dst_beat_bytes))
          else $fatal(1,
              "%s: fixed 1D final-byte state diverged from generic geometry",
              INSTANCE_ID);
        assert (wr_seg_complete_fire
             == (out_off + wr_nbytes_cur >= seg_size_r))
          else $fatal(1,
              "%s: fixed 1D segment completion diverged from generic geometry",
              INSTANCE_ID);
      end
    end
  end
`endif

  // ------------------------------------------------------------
  // Sequential: state, counters, windows, pointers
  // ------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (reset) begin
      state <= S_IDLE;

      rd_base_src_seg_r <= '0;
      wr_base_src_seg_r <= '0;
      wr_base_dst_seg_r <= '0;

      foreach (rd_i_dim[d]) begin
        rd_i_dim[d] <= '0;
        wr_i_dim[d] <= '0;
      end
      out_off   <= '0;

      win_lmem       <= '0;
      win_lmem_valid <= '0;
      win_lmem_head  <= '0;
      lmem_rd_ptr    <= '0;
      lmem_rd_end    <= '0;

      win_dcache       <= '0;
      win_dcache_valid <= '0;
      win_dcache_head  <= '0;
      dcache_rd_ptr    <= '0;
      dcache_rd_end    <= '0;

      rd_state <= RD_IDLE;
      wr_state <= WR_IDLE;
      rd_rollover_pending_r <= 1'b0;
      wr_rollover_pending_r <= 1'b0;
      rd_issue_slot_r  <= '0;
      wr_expect_slot_r <= '0;
      slot_occupancy_r <= '0;
      data_max_beats_r <= '0;
      pre_release_reads_r <= '0;
      wr_slot_pending_r <= 1'b0;
      dcache_req_buf_pending_r <= '0;
      lmem_req_buf_pending_r <= '0;
      foreach (slot_state_r[i]) begin
        slot_state_r[i] <= SLOT_FREE;
        slot_valid_bytes_r[i] <= '0;
      end

    end else begin
      state <= state_n;
      wr_rollover_pending_r <= wr_rollover_pending_next;
      wr_slot_pending_r <= wr_slot_pending_next;
      dcache_req_buf_pending_r <= dcache_req_buf_pending_next;
      lmem_req_buf_pending_r <= lmem_req_buf_pending_next;

      // -------------------------
      // Start: init 3D + seg offset
      //   Both rd-side and wr-side start at segment 0 with the same base
      //   addresses from the descriptor. They advance independently as
      //   reads and writes drain (see src_req_fire / dst_req_fire handlers).
      // -------------------------
      if (cmd_start) begin
        data_max_beats_r <= lookahead_if.data_max_beats;
        pre_release_reads_r <= '0;
        foreach (rd_i_dim[d]) begin
          rd_i_dim[d] <= '0;
          wr_i_dim[d] <= '0;
        end
        out_off   <= 32'd0;
        rd_base_src_seg_r <= cmd_src_base;
        wr_base_src_seg_r <= cmd_src_base;
        wr_base_dst_seg_r <= cmd_dst_base;

        rd_rollover_pending_r <= 1'b0;
        wr_rollover_pending_r <= 1'b0;
        rd_issue_slot_r  <= '0;
        wr_expect_slot_r <= '0;
        slot_occupancy_r <= '0;
        win_lmem       <= '0;
        win_lmem_valid <= '0;
        win_lmem_head  <= '0;
        win_dcache       <= '0;
        win_dcache_valid <= '0;
        win_dcache_head  <= '0;
        foreach (slot_state_r[i]) begin
          slot_state_r[i] <= SLOT_FREE;
          slot_valid_bytes_r[i] <= '0;
        end

        if (cmd_fast_path) begin
          rd_state <= RD_RUN;
          wr_state <= WR_RUN;
          if (cmd_dir) begin
            lmem_rd_ptr <= align_down(cmd_src_base, LMEM_BYTES);
            lmem_rd_end <= align_up(
                cmd_src_base + 64'(cmd_valid_total), LMEM_BYTES);
            dcache_rd_ptr <= '0;
            dcache_rd_end <= '0;
          end else begin
            dcache_rd_ptr <= align_down(cmd_src_base, DCACHE_BYTES);
            dcache_rd_end <= align_up(
                cmd_src_base + 64'(cmd_valid_total), DCACHE_BYTES);
            lmem_rd_ptr <= '0;
            lmem_rd_end <= '0;
          end
        end else begin
          rd_state <= RD_IDLE;
          wr_state <= WR_IDLE;
        end
      end

      // -------------------------
      // Prepare segment: reset windows + init decoupled RD/WR context.
      // In the pipelined design this block runs only ONCE per descriptor
      // (seg 0 setup). Subsequent segment boundaries are handled inline
      // by the src_req_fire (rd-side) and dst_req_fire (wr-side) handlers
      // below, so the FSM stays in DECIDE until both sides finish.
      // -------------------------
      if (state == S_PREP_SEG) begin
        out_off <= 32'd0;
        rd_rollover_pending_r <= 1'b0;
        wr_rollover_pending_r <= 1'b0;

        win_lmem       <= '0;
        win_lmem_valid <= '0;
        win_lmem_head  <= '0;
        win_dcache       <= '0;
        win_dcache_valid <= '0;
        win_dcache_head  <= '0;

        rd_issue_slot_r  <= '0;
        wr_expect_slot_r <= '0;
        slot_occupancy_r <= '0;
        foreach (slot_state_r[i]) begin
          slot_state_r[i] <= SLOT_FREE;
          slot_valid_bytes_r[i] <= '0;
        end

        if (!bounds_nonzero || (seg_size_r == 0)) begin
          // Degenerate descriptor (no work) — short-circuit to DONE.
          rd_state <= RD_DONE;
          wr_state <= WR_DONE;
        end else begin
          wr_state <= WR_RUN;

          if (active_dir) begin
            // L2G: source=LMEM
            lmem_rd_ptr <= align_down(rd_base_src_seg, LMEM_BYTES);
            if (valid_total == 0) begin
              lmem_rd_end <= align_down(rd_base_src_seg, LMEM_BYTES);
              rd_state    <= RD_DONE;
            end else begin
              lmem_rd_end <= align_up(rd_base_src_seg + 64'(valid_total), LMEM_BYTES);
              rd_state    <= RD_RUN;
            end
            dcache_rd_ptr <= '0;
            dcache_rd_end <= '0;
          end else begin
            // G2L: source=DCACHE
            dcache_rd_ptr <= align_down(rd_base_src_seg, DCACHE_BYTES);
            if (valid_total == 0) begin
              dcache_rd_end <= align_down(rd_base_src_seg, DCACHE_BYTES);
              rd_state      <= RD_DONE;
            end else begin
              dcache_rd_end <= align_up(rd_base_src_seg + 64'(valid_total), DCACHE_BYTES);
              rd_state      <= RD_RUN;
            end
            lmem_rd_ptr <= '0;
            lmem_rd_end <= '0;
          end
        end
      end else if ((state == S_L2G_DECIDE) || (state == S_G2L_DECIDE)) begin
        if (src_req_fire && !lookahead_if.data_release)
          pre_release_reads_r <= pre_release_reads_r + 1'b1;
        // -------------------------
        // Source read issue bookkeeping
        //   When a read completes the current rd segment (next_ptr hits
        //   rd_end), advance rd_i_dim and rd_base_src_seg_r to the NEXT
        //   segment immediately. Only set rd_state=RD_DONE when the last
        //   segment's last read is issued. This keeps reads streaming
        //   across segment boundaries (pipeline-hiding HBM latency).
        //   Pre-condition: valid_total > 0 (else rd_state=RD_DONE from init).
        // -------------------------
        if (rd_rollover_release) begin
          for (int d = 0; d < NDIM; ++d)
            rd_i_dim[d] <= rd_i_dim_advance[d];
          rd_base_src_seg_r <= rd_next_base;
          rd_rollover_pending_r <= 1'b0;
          if (active_dir) begin
            lmem_rd_ptr <= align_down(rd_next_base, LMEM_BYTES);
            lmem_rd_end <= align_up(
                rd_next_base + 64'(valid_total), LMEM_BYTES);
          end else begin
            dcache_rd_ptr <= align_down(rd_next_base, DCACHE_BYTES);
            dcache_rd_end <= align_up(
                rd_next_base + 64'(valid_total), DCACHE_BYTES);
          end
        end else if (src_req_fire) begin
          slot_state_r[rd_issue_slot_r] <= SLOT_WAIT_RSP;
          slot_valid_bytes_r[rd_issue_slot_r] <= WIN_VALID_W'(rd_beat_valid_bytes);
          rd_issue_slot_r <= next_rd_slot_idx(rd_issue_slot_r);

          if (rd_crosses_seg) begin
            if (rd_is_last_seg) begin
              // All rd segments issued
              rd_state <= RD_DONE;
              if (active_dir) lmem_rd_ptr <= rd_next_ptr;
              else                 dcache_rd_ptr <= rd_next_ptr;
            end else if (rd_rollover_ready) begin
              // Advance rd_i_dim, rd_base_src_seg_r, recompute rd_ptr/rd_end
              for (int d = 0; d < NDIM; ++d)
                rd_i_dim[d] <= rd_i_dim_advance[d];
              rd_base_src_seg_r <= rd_next_base;
              if (active_dir) begin
                lmem_rd_ptr <= align_down(rd_next_base, LMEM_BYTES);
                lmem_rd_end <= align_up(rd_next_base + 64'(valid_total), LMEM_BYTES);
              end else begin
                dcache_rd_ptr <= align_down(rd_next_base, DCACHE_BYTES);
                dcache_rd_end <= align_up(rd_next_base + 64'(valid_total), DCACHE_BYTES);
              end
            end else begin
              // The completed segment remains selected until its required
              // correction products arrive. No new source request can issue
              // because the read pointer is held at the segment end.
              rd_rollover_pending_r <= 1'b1;
              if (active_dir)
                lmem_rd_ptr <= rd_next_ptr;
              else
                dcache_rd_ptr <= rd_next_ptr;
            end
          end else begin
            // Stay in current rd segment
            if (active_dir) lmem_rd_ptr <= rd_next_ptr;
            else                 dcache_rd_ptr <= rd_next_ptr;
          end
        end

        // -------------------------
        // Source response -> slot capture
        // -------------------------
        if (src_rsp_fire) begin
          slot_state_r[rsp_slot_idx] <= SLOT_READY;
        end

        // -------------------------
        // WR-side window consume/update (per direction)
        // -------------------------
        win_lmem         <= win_lmem_next;
        win_lmem_valid   <= win_lmem_valid_next;
        win_lmem_head    <= win_lmem_head_next;
        win_dcache       <= win_dcache_next;
        win_dcache_valid <= win_dcache_valid_next;
        win_dcache_head  <= win_dcache_head_next;
        out_off          <= out_off_next;
        wr_state         <= wr_state_next;
        wr_rollover_pending_r <= wr_rollover_pending_next;
        wr_base_src_seg_r <= wr_base_src_seg_next;
        wr_base_dst_seg_r <= wr_base_dst_seg_next;
        foreach (wr_i_dim[d]) begin
          wr_i_dim[d] <= wr_i_dim_next[d];
        end

        if (wr_slot_read_fire) begin
          slot_state_r[wr_expect_slot_r] <= SLOT_DRAINING;
          wr_expect_slot_r <= next_rd_slot_idx(wr_expect_slot_r);
        end

        if (wr_slot_drain_fire)
          slot_state_r[ram_wr_slot_r] <= SLOT_FREE;

        unique case ({src_req_fire, slot_release_fire})
          2'b10: slot_occupancy_r <= slot_occupancy_r + SLOT_OCC_W'(1);
          2'b01: slot_occupancy_r <= slot_occupancy_r - SLOT_OCC_W'(1);
          default:;
        endcase
      end

      // Note: the legacy S_ADV_SEG block that advanced i_dim and bases
      // in lockstep has been removed. Per-seg advance is now inlined in
      // src_req_fire (rd side) and dst_req_fire (wr side) above.

    end
  end

`ifdef PERF_ENABLE
    reg [PERF_CTR_BITS-1:0] perf_rd_bytes_r;
    reg [PERF_CTR_BITS-1:0] perf_wr_bytes_r;
    reg [PERF_CTR_BITS-1:0] perf_xfers_r;
    reg [PERF_CTR_BITS-1:0] perf_active_r;
    reg [PERF_CTR_BITS-1:0] perf_wait_dcache_r;
    reg [PERF_CTR_BITS-1:0] perf_wait_lmem_r;
    reg [PERF_CTR_BITS-1:0] perf_src_rd_req_fire_r,  perf_src_rd_req_stall_r;
    reg [PERF_CTR_BITS-1:0] perf_src_rd_data_fire_r, perf_src_rd_data_stall_r;
    reg [PERF_CTR_BITS-1:0] perf_dst_wr_fire_r,      perf_dst_wr_stall_r;

    // ----------------------------------------------------------------
    // Decoupled-FSM perf predicates
    //
    // The FSM was refactored to a decoupled architecture: the top FSM
    // remains in S_G2L_DECIDE / S_L2G_DECIDE while sub-FSMs (rd_state_e,
    // wr_state_e) drive the actual bus handshakes. The legacy
    // S_*_SRC_RD_REQ / S_*_SRC_RD_WAIT / S_*_DST_WR_REQ states are
    // unreachable on the live path (they fall through to the DECIDE
    // states — see the legacy fall-through block in the next_state
    // always_comb). Predicates that gate on those states are therefore
    // dead and produce all-zero counters.
    //
    // The perf gates below use the actual active DECIDE states combined
    // with the bus handshake helpers declared near the top of the file
    // (dcache_req_fire / dcache_rsp_fire / lmem_req_fire / lmem_rsp_fire).
    // Direction model (matches src_req_fire / dst_req_fire above):
    //   - direction_bit_r=0 (G2L, HBM->local): state==S_G2L_DECIDE,
    //       src=dcache (rw=0 reads), dst=lmem (rw=1 writes).
    //   - direction_bit_r=1 (L2G, local->HBM): state==S_L2G_DECIDE,
    //       src=lmem (rw=0 reads), dst=dcache (rw=1 writes).
    // ----------------------------------------------------------------

    // Active state shorthand for the per-direction perf gates
    wire in_g2l_active = (state == S_G2L_DECIDE);
    wire in_l2g_active = (state == S_L2G_DECIDE);

    // G2L read beat: HBM read response landed
    wire g2l_rd_beat = in_g2l_active && dcache_rsp_fire;
    // L2G write beat: HBM write request accepted
    wire l2g_wr_beat = in_l2g_active && dcache_req_fire && (dcache_bus_if.req_data.rw == 1'b1);

    // Active: DMA is busy (not idle/done)
    wire dma_is_active = (state != S_IDLE) && (state != S_DONE);
    // Transfer complete edge
    wire dma_xfer_done = (state != S_DONE) && (state_n == S_DONE);

    // Stall breakdown: dcache side (HBM) — valid && !ready, gated on direction
    wire dma_stall_dcache = (in_g2l_active && dcache_bus_if.req_valid && !dcache_bus_if.req_ready && (dcache_bus_if.req_data.rw == 1'b0))
                          | (in_g2l_active && dcache_bus_if.rsp_valid && !dcache_bus_if.rsp_ready)
                          | (in_l2g_active && dcache_bus_if.req_valid && !dcache_bus_if.req_ready && (dcache_bus_if.req_data.rw == 1'b1));
    // Stall breakdown: lmem side — valid && !ready, gated on direction
    wire dma_stall_lmem = (in_g2l_active && lmem_bus_if.req_valid && !lmem_bus_if.req_ready && (lmem_bus_if.req_data.rw == 1'b1))
                        | (in_l2g_active && lmem_bus_if.req_valid && !lmem_bus_if.req_ready && (lmem_bus_if.req_data.rw == 1'b0))
                        | (in_l2g_active && lmem_bus_if.rsp_valid && !lmem_bus_if.rsp_ready);

    // Fire/stall per port (direction-independent: G2L src=dcache, L2G src=lmem)
    // src_rd_req: sending read request to source
    wire perf_src_rd_req_fire  = (in_g2l_active && dcache_req_fire && (dcache_bus_if.req_data.rw == 1'b0))
                               | (in_l2g_active && lmem_req_fire   && (lmem_bus_if.req_data.rw   == 1'b0));
    wire perf_src_rd_req_stall = (in_g2l_active && dcache_bus_if.req_valid && !dcache_bus_if.req_ready && (dcache_bus_if.req_data.rw == 1'b0))
                               | (in_l2g_active && lmem_bus_if.req_valid   && !lmem_bus_if.req_ready   && (lmem_bus_if.req_data.rw   == 1'b0));
    // src_rd_data: receiving read data from source
    wire perf_src_rd_data_fire  = (in_g2l_active && dcache_rsp_fire)
                                | (in_l2g_active && lmem_rsp_fire);
    wire perf_src_rd_data_stall = (in_g2l_active && dcache_bus_if.rsp_valid && !dcache_bus_if.rsp_ready)
                                | (in_l2g_active && lmem_bus_if.rsp_valid   && !lmem_bus_if.rsp_ready);
    // dst_wr: writing to destination
    wire perf_dst_wr_fire  = (in_g2l_active && lmem_req_fire   && (lmem_bus_if.req_data.rw   == 1'b1))
                           | (in_l2g_active && dcache_req_fire && (dcache_bus_if.req_data.rw == 1'b1));
    wire perf_dst_wr_stall = (in_g2l_active && lmem_bus_if.req_valid   && !lmem_bus_if.req_ready   && (lmem_bus_if.req_data.rw   == 1'b1))
                           | (in_l2g_active && dcache_bus_if.req_valid && !dcache_bus_if.req_ready && (dcache_bus_if.req_data.rw == 1'b1));

    // ----------------------------------------------------------------
    // Perf-trigger register stage (timing fix).
    //
    // Decouples the perf counter CEs from the FSM next-state / AXI
    // handshake combinational fanout. The original worst path was
    // state_n -> dma_xfer_done -> SLR crossing -> perf_xfers_r/CE
    // (-1.145 ns at 100 MHz, 23 logic levels, 81% route delay).
    //
    // Telemetry-only path: every predicate is delayed by exactly 1
    // cycle, so all counter totals remain exact (events are merely
    // observed one cycle later — every predicate slides together).
    // Cost: ~12 flops per DMA unit instance, inside PERF_ENABLE only.
    // ----------------------------------------------------------------
    reg g2l_rd_beat_q;
    reg l2g_wr_beat_q;
    reg dma_is_active_q;
    reg dma_xfer_done_q;
    reg dma_stall_dcache_q;
    reg dma_stall_lmem_q;
    reg perf_src_rd_req_fire_q,   perf_src_rd_req_stall_q;
    reg perf_src_rd_data_fire_q,  perf_src_rd_data_stall_q;
    reg perf_dst_wr_fire_q,       perf_dst_wr_stall_q;

    always @(posedge clk) begin
        if (reset) begin
            g2l_rd_beat_q            <= 1'b0;
            l2g_wr_beat_q            <= 1'b0;
            dma_is_active_q          <= 1'b0;
            dma_xfer_done_q          <= 1'b0;
            dma_stall_dcache_q       <= 1'b0;
            dma_stall_lmem_q         <= 1'b0;
            perf_src_rd_req_fire_q   <= 1'b0;
            perf_src_rd_req_stall_q  <= 1'b0;
            perf_src_rd_data_fire_q  <= 1'b0;
            perf_src_rd_data_stall_q <= 1'b0;
            perf_dst_wr_fire_q       <= 1'b0;
            perf_dst_wr_stall_q      <= 1'b0;
        end else begin
            g2l_rd_beat_q            <= g2l_rd_beat;
            l2g_wr_beat_q            <= l2g_wr_beat;
            dma_is_active_q          <= dma_is_active;
            dma_xfer_done_q          <= dma_xfer_done;
            dma_stall_dcache_q       <= dma_stall_dcache;
            dma_stall_lmem_q         <= dma_stall_lmem;
            perf_src_rd_req_fire_q   <= perf_src_rd_req_fire;
            perf_src_rd_req_stall_q  <= perf_src_rd_req_stall;
            perf_src_rd_data_fire_q  <= perf_src_rd_data_fire;
            perf_src_rd_data_stall_q <= perf_src_rd_data_stall;
            perf_dst_wr_fire_q       <= perf_dst_wr_fire;
            perf_dst_wr_stall_q      <= perf_dst_wr_stall;
        end
    end

    always @(posedge clk) begin
        if (reset) begin
            perf_rd_bytes_r          <= '0;
            perf_wr_bytes_r          <= '0;
            perf_xfers_r             <= '0;
            perf_active_r            <= '0;
            perf_wait_dcache_r       <= '0;
            perf_wait_lmem_r         <= '0;
            perf_src_rd_req_fire_r   <= '0;
            perf_src_rd_req_stall_r  <= '0;
            perf_src_rd_data_fire_r  <= '0;
            perf_src_rd_data_stall_r <= '0;
            perf_dst_wr_fire_r       <= '0;
            perf_dst_wr_stall_r      <= '0;
        end else begin
            if (g2l_rd_beat_q)
                perf_rd_bytes_r <= perf_rd_bytes_r + PERF_CTR_BITS'(DCACHE_BYTES);
            if (l2g_wr_beat_q)
                perf_wr_bytes_r <= perf_wr_bytes_r + PERF_CTR_BITS'(DCACHE_BYTES);
            if (dma_xfer_done_q)
                perf_xfers_r <= perf_xfers_r + PERF_CTR_BITS'(1);
            if (dma_is_active_q)
                perf_active_r <= perf_active_r + PERF_CTR_BITS'(1);
            if (dma_stall_dcache_q)
                perf_wait_dcache_r <= perf_wait_dcache_r + PERF_CTR_BITS'(1);
            if (dma_stall_lmem_q)
                perf_wait_lmem_r <= perf_wait_lmem_r + PERF_CTR_BITS'(1);
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
    assign perf.wait_dcache       = perf_wait_dcache_r;
    assign perf.wait_lmem         = perf_wait_lmem_r;
    assign perf.busy              = dma_is_active;
`endif

`ifdef CHIPSCOPE
`ifdef DBG_SCOPE_GEMM
  localparam int DBG_BIT_W    = $bits(logic);
  localparam int DBG_STATE_W  = $bits(state);
  localparam int DBG_WORD_W   = $bits(logic [31:0]);
  localparam int DBG_ADDR64_W = $bits(rd_base_src_seg);

  localparam int DBG_DMA_UNIT_P0_W = (23 * DBG_BIT_W) + (2 * DBG_STATE_W);
  localparam int DBG_DMA_UNIT_P1_W = ((4 + NDIM) * DBG_WORD_W);
  localparam int DBG_DMA_UNIT_P2_W = (6 * DBG_ADDR64_W);
  localparam int DBG_DMA_UNIT_P3_W = (7 * DBG_WORD_W);

  (* keep = "true", mark_debug = "true" *) wire [DBG_DMA_UNIT_P0_W-1:0] dbg_dma_unit_probe0 = {
      reset,
      cfg_reg_if.valid,
      cfg_reg_if.ready,
      cfg_fire,
      cmd_start,
      precalc_issue,
      precalc_done,
      active_dir,
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
      wr_i_dim[0],
      wr_i_dim[1],
      wr_i_dim[2]
  };
  (* keep = "true", mark_debug = "true" *) wire [DBG_DMA_UNIT_P2_W-1:0] dbg_dma_unit_probe2 = {
      rd_base_src_seg,
      wr_base_dst_seg,
      lmem_rd_ptr,
      lmem_rd_end,
      dcache_rd_ptr,
      dcache_rd_end
  };
  (* keep = "true", mark_debug = "true" *) wire [DBG_DMA_UNIT_P3_W-1:0] dbg_dma_unit_probe3 = {
      32'd0,
      32'd0,
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
