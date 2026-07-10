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
  // Parent forwards interface TAG_WIDTH values explicitly. Synopsys DC
  // rejects `interface_inst.PARAM` access inside localparam initializers,
  // so we cannot read dcache_bus_if.TAG_WIDTH / lmem_bus_if.TAG_WIDTH
  // directly here.
  parameter int DCACHE_TAG_WIDTH = 1,
  parameter int LMEM_TAG_WIDTH   = 1
) (
  input wire clk,
  input wire reset,

  VX_config_reg_if.slave cfg_reg_if,     // from LSU (DW=32 expected)

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

  // Aligned mode only needs one beat of staging because source and destination
  // bases/strides are bus-aligned. Different source/destination beat widths
  // still require a MAX_BYTES window for width conversion.
  localparam int MIN_BYTES    = (DCACHE_BYTES < LMEM_BYTES) ? DCACHE_BYTES : LMEM_BYTES;
  localparam int MAX_BYTES    = (DCACHE_BYTES > LMEM_BYTES) ? DCACHE_BYTES : LMEM_BYTES;
  localparam int CHUNK_BYTES  = MIN_BYTES;
  localparam int WIN_BYTES    = MAX_BYTES;
  localparam int WIN_VALID_W  = `CLOG2(WIN_BYTES + 1);
  localparam int SAME_WIDTH_FAST = (DCACHE_BYTES == LMEM_BYTES);

  initial begin
    if (!(((DCACHE_BYTES % LMEM_BYTES) == 0) || ((LMEM_BYTES % DCACHE_BYTES) == 0)))
      $fatal(1, "aligned DMA requires divisible dcache/lmem bus widths");
  end

  function automatic logic [dcache_bus_if.ADDR_WIDTH-1:0] to_dcache_addr(input logic [63:0] byte_addr);
    to_dcache_addr = dcache_bus_if.ADDR_WIDTH'(byte_addr >> DCACHE_LG2);
  endfunction

  function automatic logic [lmem_bus_if.ADDR_WIDTH-1:0] to_lmem_addr(input logic [63:0] byte_addr);
    to_lmem_addr = lmem_bus_if.ADDR_WIDTH'(byte_addr >> LMEM_LG2);
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
  assign cfg_reg_if.ready = (state == S_IDLE);
  assign cfg_fire = cfg_reg_if.valid && cfg_reg_if.ready;

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

  // ------------------------------------------------------------
  // Runtime alignment guard for the aligned-only module.
  // Simulation-only ($fatal is stripped by synthesis). Checks base/stride
  // lower bits on each command start; padding and seg_size are allowed to be
  // byte-granular since the last beat is handled via byteen.
  // ------------------------------------------------------------
`ifndef SYNTHESIS
  always_ff @(posedge clk) begin
    if (!reset && cmd_start) begin
      // src and dst ride different buses depending on direction, so each must be
      // checked against the beat of the bus it actually touches:
      //   dir=0 (G2L): src=DCACHE, dst=LMEM ;  dir=1 (L2G): src=LMEM, dst=DCACHE.
      // The LMEM beat (NUM_LSU_LANES*LSU_WORD_SIZE) can exceed the DCACHE line, so
      // a fixed src->LMEM / dst->DCACHE orientation would falsely trip on the
      // global side of a G2L transfer (e.g. a 64B-aligned global base on a 256B
      // LMEM bus) while under-checking the LMEM side.
      if (|(cfg_reg_if.regs[3] & ((cfg_reg_if.regs[DESC_DIR_IDX][0] ? 32'(LMEM_BYTES) : 32'(DCACHE_BYTES)) - 32'd1)))
        $fatal(1, "%s: aligned DMA src_base_lo=0x%08h is not %0d-byte aligned",
               INSTANCE_ID, cfg_reg_if.regs[3],
               cfg_reg_if.regs[DESC_DIR_IDX][0] ? LMEM_BYTES : DCACHE_BYTES);
      if (|(cfg_reg_if.regs[1] & ((cfg_reg_if.regs[DESC_DIR_IDX][0] ? 32'(DCACHE_BYTES) : 32'(LMEM_BYTES)) - 32'd1)))
        $fatal(1, "%s: aligned DMA dst_base_lo=0x%08h is not %0d-byte aligned",
               INSTANCE_ID, cfg_reg_if.regs[1],
               cfg_reg_if.regs[DESC_DIR_IDX][0] ? DCACHE_BYTES : LMEM_BYTES);
      if (|(cfg_reg_if.regs[5] & ((cfg_reg_if.regs[DESC_DIR_IDX][0] ? 32'(LMEM_BYTES) : 32'(DCACHE_BYTES)) - 32'd1)))
        $fatal(1, "%s: aligned DMA src_stride[%0d]=0x%08h is not %0d-byte aligned",
               INSTANCE_ID, 0, cfg_reg_if.regs[5],
               cfg_reg_if.regs[DESC_DIR_IDX][0] ? LMEM_BYTES : DCACHE_BYTES);
      if (|(cfg_reg_if.regs[6] & ((cfg_reg_if.regs[DESC_DIR_IDX][0] ? 32'(DCACHE_BYTES) : 32'(LMEM_BYTES)) - 32'd1)))
        $fatal(1, "%s: aligned DMA dst_stride[%0d]=0x%08h is not %0d-byte aligned",
               INSTANCE_ID, 0, cfg_reg_if.regs[6],
               cfg_reg_if.regs[DESC_DIR_IDX][0] ? DCACHE_BYTES : LMEM_BYTES);
      if (|(cfg_reg_if.regs[7] & ((cfg_reg_if.regs[DESC_DIR_IDX][0] ? 32'(LMEM_BYTES) : 32'(DCACHE_BYTES)) - 32'd1)))
        $fatal(1, "%s: aligned DMA src_stride[%0d]=0x%08h is not %0d-byte aligned",
               INSTANCE_ID, 1, cfg_reg_if.regs[7],
               cfg_reg_if.regs[DESC_DIR_IDX][0] ? LMEM_BYTES : DCACHE_BYTES);
      if (|(cfg_reg_if.regs[8] & ((cfg_reg_if.regs[DESC_DIR_IDX][0] ? 32'(DCACHE_BYTES) : 32'(LMEM_BYTES)) - 32'd1)))
        $fatal(1, "%s: aligned DMA dst_stride[%0d]=0x%08h is not %0d-byte aligned",
               INSTANCE_ID, 1, cfg_reg_if.regs[8],
               cfg_reg_if.regs[DESC_DIR_IDX][0] ? DCACHE_BYTES : LMEM_BYTES);
      if (|(cfg_reg_if.regs[9] & ((cfg_reg_if.regs[DESC_DIR_IDX][0] ? 32'(LMEM_BYTES) : 32'(DCACHE_BYTES)) - 32'd1)))
        $fatal(1, "%s: aligned DMA src_stride[%0d]=0x%08h is not %0d-byte aligned",
               INSTANCE_ID, 2, cfg_reg_if.regs[9],
               cfg_reg_if.regs[DESC_DIR_IDX][0] ? LMEM_BYTES : DCACHE_BYTES);
      if (|(cfg_reg_if.regs[10] & ((cfg_reg_if.regs[DESC_DIR_IDX][0] ? 32'(DCACHE_BYTES) : 32'(LMEM_BYTES)) - 32'd1)))
        $fatal(1, "%s: aligned DMA dst_stride[%0d]=0x%08h is not %0d-byte aligned",
               INSTANCE_ID, 2, cfg_reg_if.regs[10],
               cfg_reg_if.regs[DESC_DIR_IDX][0] ? DCACHE_BYTES : LMEM_BYTES);
    end
  end
`endif

  // Latched descriptor fields (captured atomically at cmd_start)
  logic [63:0] base_addr_r[2];     // [0]=src, [1]=dst
  logic [31:0] stride_r[2][NDIM];  // [src/dst][dim]
  // Precomputed stride * (bound - 1), used for carry-step base address correction.
  logic [63:0] stride_bound_r[2][NDIM];
  logic [31:0] bound_r[NDIM];
  logic [31:0] seg_size_r;
  logic [31:0] padding_r;
  logic        direction_bit_r;    // 0: GLOBAL->LMEM (load), 1: LMEM->GLOBAL (store)
  logic [63:0] rd_base_src_seg_r, wr_base_dst_seg_r;
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
      foreach (bound_r[d]) begin
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
        $display(1, "%s: VX_dma_unit_align: ERROR - bounds cannot be zero!", INSTANCE_ID);
      end

      base_addr_r[0] <= {cfg_reg_if.regs[4][31:0], cfg_reg_if.regs[3][31:0]}; // src
      base_addr_r[1] <= {cfg_reg_if.regs[2][31:0], cfg_reg_if.regs[1][31:0]}; // dst

      foreach (bound_r[d]) begin
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
  //   - rd_i_dim / rd_base_src_seg_r advance when the RD side finishes
  //     issuing reads for the current segment (src_req_fire crosses end)
  //   - wr_i_dim / wr_base_dst_seg_r advance when the WR side finishes
  //     writing the current segment (dst_req_fire causes out_off == seg_size)
  //   - This decouples the two sides so the slot array (depth 8) can hold
  //     reads from future segments while writes of the current segment
  //     are still draining. Without the split, each segment would serialize
  //     through S_PREP_SEG -> DECIDE -> S_ADV_SEG (~7–8 cycles / seg).
  // ------------------------------------------------------------
  logic [31:0] rd_i_dim[NDIM];
  logic [31:0] wr_i_dim[NDIM];
  logic [31:0] out_off; // bytes within current WR segment [0 .. seg_size)

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
  assign valid_total = (seg_size_r > padding_r) ? (seg_size_r - padding_r) : 32'd0;

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
    SLOT_READY
  } slot_state_e;

  localparam int RD_OUTSTANDING_CAP = `DMA_RD_OUTSTANDING_SLOT;
  localparam int RD_SLOT_BITS_CAP   = `CLOG2(RD_OUTSTANDING_CAP);
  localparam int DCACHE_TAG_VALUE_W = DCACHE_TAG_WIDTH - `UP(UUID_WIDTH);
  localparam int LMEM_TAG_VALUE_W   = LMEM_TAG_WIDTH - `UP(UUID_WIDTH);
  localparam int MIN_TAG_VALUE_W    = (DCACHE_TAG_VALUE_W < LMEM_TAG_VALUE_W)
                                    ? DCACHE_TAG_VALUE_W : LMEM_TAG_VALUE_W;
  // Keep at least 1 bit in localparams so vector declarations remain legal,
  // then enforce the real minimum at runtime with a fatal check below.
  localparam int EFF_TAG_VALUE_W    = (MIN_TAG_VALUE_W < 1) ? 1 : MIN_TAG_VALUE_W;
  localparam int RD_SLOT_BITS_RAW   = (EFF_TAG_VALUE_W < RD_SLOT_BITS_CAP)
                                    ? EFF_TAG_VALUE_W : RD_SLOT_BITS_CAP;
  localparam int RD_SLOT_BITS       = (RD_SLOT_BITS_RAW < 1) ? 1 : RD_SLOT_BITS_RAW;
  localparam int RD_OUTSTANDING     = (RD_SLOT_BITS_RAW == 0) ? 1 : (1 << RD_SLOT_BITS_RAW);
  localparam int SLOT_OCC_W         = `CLOG2(RD_OUTSTANDING + 1);

  initial begin
    if (MIN_TAG_VALUE_W < 1)
      $fatal(1, "tag.value width must be >= 1 (dcache=%0d, lmem=%0d)", DCACHE_TAG_VALUE_W, LMEM_TAG_VALUE_W);
    if (DCACHE_TAG_VALUE_W < RD_SLOT_BITS)
      $fatal(1, "dcache tag.value width (%0d) < RD_SLOT_BITS (%0d)", DCACHE_TAG_VALUE_W, RD_SLOT_BITS);
    if (LMEM_TAG_VALUE_W < RD_SLOT_BITS)
      $fatal(1, "lmem tag.value width (%0d) < RD_SLOT_BITS (%0d)", LMEM_TAG_VALUE_W, RD_SLOT_BITS);
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

  slot_state_e                slot_state_r [RD_OUTSTANDING];
  logic [RD_OUTSTANDING-1:0][MAX_BYTES*8-1:0] slot_data_r;
  logic [RD_OUTSTANDING-1:0][WIN_VALID_W-1:0] slot_valid_bytes_r;
  logic [RD_SLOT_BITS-1:0]    rd_issue_slot_r;
  logic [RD_SLOT_BITS-1:0]    wr_expect_slot_r;
  logic [SLOT_OCC_W-1:0]      slot_occupancy_r;

  localparam int WR_SLOT_DATAW = MAX_BYTES*8 + WIN_VALID_W;
  localparam int DCACHE_REQ_DATAW = 1 + dcache_bus_if.ADDR_WIDTH + (DCACHE_BYTES*8)
                                  + DCACHE_BYTES + MEM_FLAGS_WIDTH
                                  + `UP(UUID_WIDTH) + DCACHE_TAG_VALUE_W;
  localparam int LMEM_REQ_DATAW = 1 + lmem_bus_if.ADDR_WIDTH + (LMEM_BYTES*8)
                                + LMEM_BYTES + MEM_FLAGS_WIDTH
                                + `UP(UUID_WIDTH) + LMEM_TAG_VALUE_W;

  wire                       wr_slot_valid_r;
  wire [MAX_BYTES*8-1:0]     wr_slot_data_r;
  wire [WIN_VALID_W-1:0]     wr_slot_valid_bytes_r;
  wire                       wr_slot_read_valid;
  wire                       wr_slot_read_ready;
  wire                       wr_slot_read_fire;
  wire                       wr_slot_pop_ready;
  wire                       wr_slot_drain_fire;
  logic [1:0]                wr_slot_buf_pending_r;
  wire [1:0]                 wr_slot_buf_pending_next;

  logic                      dcache_req_valid_w;
  wire                       dcache_req_ready_w;
  logic                      dcache_req_rw_w;
  logic [dcache_bus_if.ADDR_WIDTH-1:0] dcache_req_addr_w;
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
  logic [lmem_bus_if.ADDR_WIDTH-1:0] lmem_req_addr_w;
  logic [LMEM_BYTES*8-1:0]   lmem_req_data_w;
  logic [LMEM_BYTES-1:0]     lmem_req_byteen_w;
  logic [MEM_FLAGS_WIDTH-1:0] lmem_req_flags_w;
  logic [`UP(UUID_WIDTH)-1:0] lmem_req_tag_uuid_w;
  logic [LMEM_TAG_VALUE_W-1:0] lmem_req_tag_value_w;
  wire                       lmem_req_issue_fire;
  logic [1:0]                lmem_req_buf_pending_r;
  wire [1:0]                 lmem_req_buf_pending_next;

  VX_elastic_buffer #(
    .DATAW   (WR_SLOT_DATAW),
    .SIZE    (2),
    .OUT_REG (1)
  ) wr_slot_buf (
    .clk       (clk),
    .reset     (reset),
    .valid_in  (wr_slot_read_valid),
    .ready_in  (wr_slot_read_ready),
    .data_in   ({slot_data_r[wr_expect_slot_r], slot_valid_bytes_r[wr_expect_slot_r]}),
    .data_out  ({wr_slot_data_r, wr_slot_valid_bytes_r}),
    .valid_out (wr_slot_valid_r),
    .ready_out (wr_slot_pop_ready)
  );

  VX_elastic_buffer #(
    .DATAW   (DCACHE_REQ_DATAW),
    .SIZE    (2),
    .OUT_REG (1)
  ) dcache_req_buf (
    .clk       (clk),
    .reset     (reset),
    .valid_in  (dcache_req_valid_w),
    .ready_in  (dcache_req_ready_w),
    .data_in   ({
      dcache_req_rw_w,
      dcache_req_addr_w,
      dcache_req_data_w,
      dcache_req_byteen_w,
      dcache_req_flags_w,
      dcache_req_tag_uuid_w,
      dcache_req_tag_value_w
    }),
    .data_out  ({
      dcache_bus_if.req_data.rw,
      dcache_bus_if.req_data.addr,
      dcache_bus_if.req_data.data,
      dcache_bus_if.req_data.byteen,
      dcache_bus_if.req_data.flags,
      dcache_bus_if.req_data.tag.uuid,
      dcache_bus_if.req_data.tag.value
    }),
    .valid_out (dcache_bus_if.req_valid),
    .ready_out (dcache_bus_if.req_ready)
  );

  VX_elastic_buffer #(
    .DATAW   (LMEM_REQ_DATAW),
    .SIZE    (2),
    .OUT_REG (1)
  ) lmem_req_buf (
    .clk       (clk),
    .reset     (reset),
    .valid_in  (lmem_req_valid_w),
    .ready_in  (lmem_req_ready_w),
    .data_in   ({
      lmem_req_rw_w,
      lmem_req_addr_w,
      lmem_req_data_w,
      lmem_req_byteen_w,
      lmem_req_flags_w,
      lmem_req_tag_uuid_w,
      lmem_req_tag_value_w
    }),
    .data_out  ({
      lmem_bus_if.req_data.rw,
      lmem_bus_if.req_data.addr,
      lmem_bus_if.req_data.data,
      lmem_bus_if.req_data.byteen,
      lmem_bus_if.req_data.flags,
      lmem_bus_if.req_data.tag.uuid,
      lmem_bus_if.req_data.tag.value
    }),
    .valid_out (lmem_bus_if.req_valid),
    .ready_out (lmem_bus_if.req_ready)
  );

  function automatic logic [RD_SLOT_BITS-1:0] next_rd_slot_idx(
    input logic [RD_SLOT_BITS-1:0] idx
  );
    begin
      if (RD_OUTSTANDING == 1)
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

  wire src_req_fire = direction_bit_r
                    ? ((state == S_L2G_DECIDE) && lmem_req_issue_fire && (lmem_req_rw_w == 1'b0))
                    : ((state == S_G2L_DECIDE) && dcache_req_issue_fire && (dcache_req_rw_w == 1'b0));

  wire dst_req_fire = direction_bit_r
                    ? ((state == S_L2G_DECIDE) && dcache_req_issue_fire && (dcache_req_rw_w == 1'b1))
                    : ((state == S_G2L_DECIDE) && lmem_req_issue_fire && (lmem_req_rw_w == 1'b1));

  wire src_rsp_fire = direction_bit_r ? lmem_rsp_fire : dcache_rsp_fire;

  wire [63:0] rd_src_ptr_cur      = direction_bit_r ? lmem_rd_ptr : dcache_rd_ptr;
  wire [31:0] rd_src_beat_bytes   = direction_bit_r ? 32'(LMEM_BYTES) : 32'(DCACHE_BYTES);
  wire [63:0] rd_seg_valid_end    = rd_base_src_seg_r + 64'(valid_total);
  wire [31:0] rd_beat_valid_bytes = calc_read_valid_bytes(
    rd_src_ptr_cur,
    rd_seg_valid_end,
    rd_src_beat_bytes,
    valid_total
  );
  wire [63:0] rd_next_ptr = rd_src_ptr_cur + 64'(rd_src_beat_bytes);
  wire        rd_crosses_seg = direction_bit_r ? (rd_next_ptr >= lmem_rd_end)
                                                : (rd_next_ptr >= dcache_rd_end);
  wire        rd_is_last_seg = (rd_i_dim[0] + 32'd1 >= bound_r[0])
                            && (rd_i_dim[1] + 32'd1 >= bound_r[1])
                            && (rd_i_dim[2] + 32'd1 >= bound_r[2]);
  wire [63:0] rd_next_base =
    (rd_i_dim[0] + 32'd1 < bound_r[0])
      ? (rd_base_src_seg_r + 64'(stride_r[0][0]))
      : ((rd_i_dim[1] + 32'd1 < bound_r[1])
          ? (rd_base_src_seg_r + 64'(stride_r[0][1]) - stride_bound_r[0][0])
          : ((rd_i_dim[2] + 32'd1 < bound_r[2])
              ? (rd_base_src_seg_r + 64'(stride_r[0][2]) - stride_bound_r[0][1] - stride_bound_r[0][0])
              : 64'd0));

  wire [RD_SLOT_BITS-1:0] rsp_slot_idx = direction_bit_r
                                       ? lmem_bus_if.rsp_data.tag.value[RD_SLOT_BITS-1:0]
                                       : dcache_bus_if.rsp_data.tag.value[RD_SLOT_BITS-1:0];

  wire [31:0] wr_dst_beat_bytes = direction_bit_r ? 32'(DCACHE_BYTES) : 32'(LMEM_BYTES);
  wire [31:0] wr_remaining      = (out_off < seg_size_r) ? (seg_size_r - out_off) : 32'd0;
  wire [31:0] wr_nbytes_cur     = umin32(wr_remaining, wr_dst_beat_bytes);
  wire [31:0] wr_src_bytes_cur  = calc_src_bytes(out_off, valid_total, wr_nbytes_cur);
  wire        wr_payload_needed = (wr_src_bytes_cur != 0);
  wire        wr_is_last_seg    = (wr_i_dim[0] + 32'd1 >= bound_r[0])
                               && (wr_i_dim[1] + 32'd1 >= bound_r[1])
                               && (wr_i_dim[2] + 32'd1 >= bound_r[2]);
  wire [63:0] wr_next_base_src =
    (wr_i_dim[0] + 32'd1 < bound_r[0])
      ? (wr_base_src_seg_r + 64'(stride_r[0][0]))
      : ((wr_i_dim[1] + 32'd1 < bound_r[1])
          ? (wr_base_src_seg_r + 64'(stride_r[0][1]) - stride_bound_r[0][0])
          : ((wr_i_dim[2] + 32'd1 < bound_r[2])
              ? (wr_base_src_seg_r + 64'(stride_r[0][2]) - stride_bound_r[0][1] - stride_bound_r[0][0])
              : 64'd0));
  wire [63:0] wr_next_base_dst =
    (wr_i_dim[0] + 32'd1 < bound_r[0])
      ? (wr_base_dst_seg_r + 64'(stride_r[1][0]))
      : ((wr_i_dim[1] + 32'd1 < bound_r[1])
          ? (wr_base_dst_seg_r + 64'(stride_r[1][1]) - stride_bound_r[1][0])
          : ((wr_i_dim[2] + 32'd1 < bound_r[2])
              ? (wr_base_dst_seg_r + 64'(stride_r[1][2]) - stride_bound_r[1][1] - stride_bound_r[1][0])
              : 64'd0));
  wire        dst_payload_fire = dst_req_fire && wr_payload_needed;

  // Slot-read stage. The depth-2 elastic buffer decouples indexed slot capture
  // from destination-request backpressure, so slot capture no longer depends on
  // the external memory ready path.
  assign wr_slot_read_valid = ((state == S_L2G_DECIDE) || (state == S_G2L_DECIDE))
                           && (wr_state == WR_RUN)
                           && (slot_state_r[wr_expect_slot_r] == SLOT_READY);
  assign wr_slot_read_fire = wr_slot_read_valid && wr_slot_read_ready;

  // Pull/drain overlap from the registered slot stage into the width-conversion
  // window. Without the dst_req_fire bypass the single-beat staging forces pull
  // and drain to alternate, capping the engine at 0.5 beat/cycle.
  wire wr_window_can_pull = !SAME_WIDTH_FAST
                         && ((state == S_L2G_DECIDE) || (state == S_G2L_DECIDE))
                         && (wr_state == WR_RUN)
                         && (direction_bit_r
                             ? (win_lmem_valid   <= WIN_VALID_W'(WIN_BYTES - LMEM_BYTES))
                             : (win_dcache_valid <= WIN_VALID_W'(WIN_BYTES - DCACHE_BYTES)));
  wire wr_window_pull = wr_slot_valid_r && wr_window_can_pull;

  assign wr_slot_pop_ready = SAME_WIDTH_FAST ? (dst_req_fire && wr_payload_needed)
                                             : wr_window_can_pull;
  assign wr_slot_drain_fire = wr_slot_valid_r && wr_slot_pop_ready;
  assign wr_slot_buf_pending_next = wr_slot_buf_pending_r
                                  + 2'(wr_slot_read_fire)
                                  - 2'(wr_slot_drain_fire);
  assign dcache_req_buf_pending_next = dcache_req_buf_pending_r
                                     + 2'(dcache_req_issue_fire)
                                     - 2'(dcache_req_fire);
  assign lmem_req_buf_pending_next = lmem_req_buf_pending_r
                                   + 2'(lmem_req_issue_fire)
                                   - 2'(lmem_req_fire);

  logic [WIN_BYTES*8-1:0] win_lmem_next;
  logic [WIN_VALID_W-1:0] win_lmem_valid_next;
  logic [WIN_VALID_W-1:0] win_lmem_head_next;
  logic [WIN_BYTES*8-1:0] win_dcache_next;
  logic [WIN_VALID_W-1:0] win_dcache_valid_next;
  logic [WIN_VALID_W-1:0] win_dcache_head_next;
  logic [31:0]            out_off_next;
  logic [31:0]            wr_i_dim_next[NDIM];
  logic [63:0]            wr_base_src_seg_next;
  logic [63:0]            wr_base_dst_seg_next;
  wr_state_e              wr_state_next;

  always_comb begin
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
        if (dst_req_fire && direction_bit_r && (wr_src_bytes_cur != 0)) begin
          if (wr_src_bytes_cur[WIN_VALID_W-1:0] >= win_lmem_valid_next) begin
            win_lmem_valid_next = '0;
            win_lmem_head_next  = '0;
          end else begin
            win_lmem_valid_next = win_lmem_valid_next - wr_src_bytes_cur[WIN_VALID_W-1:0];
            win_lmem_head_next  = win_lmem_head_next + wr_src_bytes_cur[WIN_VALID_W-1:0];
          end
        end

        if (wr_window_pull && direction_bit_r && (win_lmem_valid_next + LMEM_BYTES <= WIN_BYTES)) begin
          for (int b = 0; b < LMEM_BYTES; b++) begin
            if (b < int'(wr_slot_valid_bytes_r)) begin
              for (int off = 0; off < WIN_BYTES; off += CHUNK_BYTES) begin
                if ((win_lmem_valid_next == WIN_VALID_W'(off)) && ((off + b) < WIN_BYTES))
                  win_lmem_next[(off + b)*8 +: 8] = wr_slot_data_r[b*8 +: 8];
              end
            end
          end
          win_lmem_valid_next = win_lmem_valid_next + wr_slot_valid_bytes_r;
          if (win_lmem_valid_next == '0)
            win_lmem_head_next = '0;
        end
      end else begin
        if (dst_req_fire && !direction_bit_r && (wr_src_bytes_cur != 0)) begin
          if (wr_src_bytes_cur[WIN_VALID_W-1:0] >= win_dcache_valid_next) begin
            win_dcache_valid_next = '0;
            win_dcache_head_next  = '0;
          end else begin
            win_dcache_valid_next = win_dcache_valid_next - wr_src_bytes_cur[WIN_VALID_W-1:0];
            win_dcache_head_next  = win_dcache_head_next + wr_src_bytes_cur[WIN_VALID_W-1:0];
          end
        end

        if (wr_window_pull && !direction_bit_r && (win_dcache_valid_next + DCACHE_BYTES <= WIN_BYTES)) begin
          for (int b = 0; b < DCACHE_BYTES; b++) begin
            if (b < int'(wr_slot_valid_bytes_r)) begin
              for (int off = 0; off < WIN_BYTES; off += CHUNK_BYTES) begin
                if ((win_dcache_valid_next == WIN_VALID_W'(off)) && ((off + b) < WIN_BYTES))
                  win_dcache_next[(off + b)*8 +: 8] = wr_slot_data_r[b*8 +: 8];
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
        if (out_off_next >= seg_size_r) begin
          if (wr_is_last_seg) begin
            wr_state_next = WR_DONE;
          end else begin
            if (wr_i_dim[0] + 32'd1 < bound_r[0]) begin
              wr_i_dim_next[0] = wr_i_dim[0] + 32'd1;
            end else begin
              wr_i_dim_next[0] = 32'd0;
              if (wr_i_dim[1] + 32'd1 < bound_r[1]) begin
                wr_i_dim_next[1] = wr_i_dim[1] + 32'd1;
              end else begin
                wr_i_dim_next[1] = 32'd0;
                wr_i_dim_next[2] = wr_i_dim[2] + 32'd1;
              end
            end
            wr_base_src_seg_next = wr_next_base_src;
            wr_base_dst_seg_next = wr_next_base_dst;
            out_off_next = 32'd0;
            if (!SAME_WIDTH_FAST && (state == S_L2G_DECIDE) && (win_lmem_valid_next == '0))
              win_lmem_head_next = '0;
            if (!SAME_WIDTH_FAST && (state == S_G2L_DECIDE) && (win_dcache_valid_next == '0))
              win_dcache_head_next = '0;
          end
        end
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
                  $time, INSTANCE_ID, cfg_reg_if.entry_id, cfg_reg_if.regs[DESC_DIR_IDX][0],
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
        `TRACE(2, ("%m : [%0t] | DMA_SETUP_MUL_ISSUE | {inst=%s, src_stride0=%0d, src_bound0_m1=%0d, src_stride1=%0d, src_bound1_m1=%0d, src_stride2=%0d, src_bound2_m1=%0d, dst_stride0=%0d, dst_bound0_m1=%0d, dst_stride1=%0d, dst_bound1_m1=%0d, dst_stride2=%0d, dst_bound2_m1=%0d}\n",
                  $time, INSTANCE_ID,
                  stride_r[0][0], bound_r[0] - 32'd1,
                  stride_r[0][1], bound_r[1] - 32'd1,
                  stride_r[0][2], bound_r[2] - 32'd1,
                  stride_r[1][0], bound_r[0] - 32'd1,
                  stride_r[1][1], bound_r[1] - 32'd1,
                  stride_r[1][2], bound_r[2] - 32'd1))
      end

      if (precalc_done) begin
        `TRACE(2, ("%m : [%0t] | DMA_SETUP_MUL_DONE | {inst=%s, src_stride_bound0=0x%0h, src_stride_bound1=0x%0h, src_stride_bound2=0x%0h, dst_stride_bound0=0x%0h, dst_stride_bound1=0x%0h, dst_stride_bound2=0x%0h}\n",
                  $time, INSTANCE_ID,
                  precalc_result[0], precalc_result[2], precalc_result[4],
                  precalc_result[1], precalc_result[3], precalc_result[5]))
      end

      if (state == S_PREP_SEG) begin
        `TRACE(2, ("%m : [%0t] | DMA_SEG_PREP | {inst=%s, mode=%s, i0=%0d, i1=%0d, i2=%0d, src_base=0x%0h, dst_base=0x%0h, seg_size=%0d, valid_total=%0d, padding=%0d, src_rd_ptr=0x%0h, src_rd_end=0x%0h}\n",
                  $time, INSTANCE_ID, direction_bit_r ? "L2G" : "G2L",
                  wr_i_dim[0], wr_i_dim[1], wr_i_dim[2], rd_base_src_seg, wr_base_dst_seg,
                  seg_size_r, valid_total, padding_r,
                  direction_bit_r ? align_down(rd_base_src_seg, LMEM_BYTES) : align_down(rd_base_src_seg, DCACHE_BYTES),
                  direction_bit_r ? align_up(rd_base_src_seg + 64'(valid_total), LMEM_BYTES)
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
        if (cmd_start)
          state_n = S_PRECALC;
      end

      S_PRECALC: begin
        if (precalc_done)
          state_n = S_PREP_SEG;
      end

      S_PREP_SEG: begin
        // Entered exactly once per descriptor (from S_PRECALC) to perform
        // the initial segment init. Descriptor completion is detected by
        // the DECIDE states' exit condition, not here.
        state_n = direction_bit_r ? S_L2G_DECIDE : S_G2L_DECIDE;
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
                    && (slot_occupancy_r < SLOT_OCC_W'(RD_OUTSTANDING))
                    && (slot_state_r[rd_issue_slot_r] == SLOT_FREE);

        if (rd_can_issue) begin
          rd_tag_value = '0;
          rd_tag_value[RD_SLOT_BITS-1:0] = rd_issue_slot_r;

          lmem_req_valid_w     = 1'b1;
          lmem_req_rw_w        = 1'b0;
          lmem_req_addr_w      = to_lmem_addr(lmem_rd_ptr);
          lmem_req_data_w      = '0;
          lmem_req_byteen_w    = '0;
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
                    && (wr_nbytes != 0)
                    && (SAME_WIDTH_FAST
                        ? ((src_bytes == 0)
                           || (wr_slot_valid_r && (wr_slot_valid_bytes_r >= src_bytes[WIN_VALID_W-1:0])))
                        : ((src_bytes == 0) || (win_lmem_valid >= src_bytes[WIN_VALID_W-1:0])));

        if (wr_can_issue) begin
          wr_data = '0;
          if (SAME_WIDTH_FAST) begin
            for (int b = 0; b < DCACHE_BYTES; b++) begin
              if (b < int'(src_bytes))
                wr_data[b*8 +: 8] = wr_slot_data_r[b*8 +: 8];
            end
          end else begin
            for (int b = 0; b < DCACHE_BYTES; b++) begin
              if (b < int'(src_bytes)) begin
                for (int off = 0; off < WIN_BYTES; off += CHUNK_BYTES) begin
                  if ((win_lmem_head == WIN_VALID_W'(off)) && ((off + b) < WIN_BYTES))
                    wr_data[b*8 +: 8] = win_lmem[(off + b)*8 +: 8];
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
        unique case ({src_req_fire, wr_slot_read_fire})
          2'b10: occ_next = slot_occupancy_r + SLOT_OCC_W'(1);
          2'b01: occ_next = slot_occupancy_r - SLOT_OCC_W'(1);
          default:;
        endcase

        // Both rd and wr have issued/drained the descriptor's last seg.
        // With seg advances handled inline by the req_fire handlers, this
        // condition now signals descriptor-level completion.
        if ((rd_state == RD_DONE) && (wr_state == WR_DONE)
            && (occ_next == 0)
            && (wr_slot_buf_pending_next == 0)
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
                    && (slot_occupancy_r < SLOT_OCC_W'(RD_OUTSTANDING))
                    && (slot_state_r[rd_issue_slot_r] == SLOT_FREE);

        if (rd_can_issue) begin
          rd_tag_value = '0;
          rd_tag_value[RD_SLOT_BITS-1:0] = rd_issue_slot_r;

          dcache_req_valid_w     = 1'b1;
          dcache_req_rw_w        = 1'b0;
          dcache_req_addr_w      = to_dcache_addr(dcache_rd_ptr);
          dcache_req_byteen_w    = '0;
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
                    && (wr_nbytes != 0)
                    && (SAME_WIDTH_FAST
                        ? ((src_bytes == 0)
                           || (wr_slot_valid_r && (wr_slot_valid_bytes_r >= src_bytes[WIN_VALID_W-1:0])))
                        : ((src_bytes == 0) || (win_dcache_valid >= src_bytes[WIN_VALID_W-1:0])));

        if (wr_can_issue) begin
          wr_data = '0;
          if (SAME_WIDTH_FAST) begin
            for (int b = 0; b < LMEM_BYTES; b++) begin
              if (b < int'(src_bytes))
                wr_data[b*8 +: 8] = wr_slot_data_r[b*8 +: 8];
            end
          end else begin
            for (int b = 0; b < LMEM_BYTES; b++) begin
              if (b < int'(src_bytes)) begin
                for (int off = 0; off < WIN_BYTES; off += CHUNK_BYTES) begin
                  if ((win_dcache_head == WIN_VALID_W'(off)) && ((off + b) < WIN_BYTES))
                    wr_data[b*8 +: 8] = win_dcache[(off + b)*8 +: 8];
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
        unique case ({src_req_fire, wr_slot_read_fire})
          2'b10: occ_next = slot_occupancy_r + SLOT_OCC_W'(1);
          2'b01: occ_next = slot_occupancy_r - SLOT_OCC_W'(1);
          default:;
        endcase

        // Both rd and wr have issued/drained the descriptor's last seg.
        // With seg advances handled inline by the req_fire handlers, this
        // condition now signals descriptor-level completion.
        if ((rd_state == RD_DONE) && (wr_state == WR_DONE)
            && (occ_next == 0)
            && (wr_slot_buf_pending_next == 0)
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
        if (done_if.ready)
          state_n = S_IDLE;
      end

      default: begin
        state_n = S_IDLE;
      end
    endcase
  end

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
      rd_issue_slot_r  <= '0;
      wr_expect_slot_r <= '0;
      slot_occupancy_r <= '0;
      wr_slot_buf_pending_r <= '0;
      dcache_req_buf_pending_r <= '0;
      lmem_req_buf_pending_r <= '0;
      foreach (slot_state_r[i]) begin
        slot_state_r[i] <= SLOT_FREE;
        slot_data_r[i]  <= '0;
        slot_valid_bytes_r[i] <= '0;
      end

    end else begin
      state <= state_n;
      wr_slot_buf_pending_r <= wr_slot_buf_pending_next;
      dcache_req_buf_pending_r <= dcache_req_buf_pending_next;
      lmem_req_buf_pending_r <= lmem_req_buf_pending_next;

      // -------------------------
      // Start: init 3D + seg offset
      //   Both rd-side and wr-side start at segment 0 with the same base
      //   addresses from the descriptor. They advance independently as
      //   reads and writes drain (see src_req_fire / dst_req_fire handlers).
      // -------------------------
      if (cmd_start) begin
        foreach (rd_i_dim[d]) begin
          rd_i_dim[d] <= 32'd0;
          wr_i_dim[d] <= 32'd0;
        end
        out_off   <= 32'd0;
        rd_base_src_seg_r <= {cfg_reg_if.regs[4][31:0], cfg_reg_if.regs[3][31:0]};
        wr_base_src_seg_r <= {cfg_reg_if.regs[4][31:0], cfg_reg_if.regs[3][31:0]};
        wr_base_dst_seg_r <= {cfg_reg_if.regs[2][31:0], cfg_reg_if.regs[1][31:0]};

        rd_state <= RD_IDLE;
        wr_state <= WR_IDLE;
        rd_issue_slot_r  <= '0;
        wr_expect_slot_r <= '0;
        slot_occupancy_r <= '0;
        foreach (slot_state_r[i]) begin
          slot_state_r[i] <= SLOT_FREE;
          slot_data_r[i]  <= '0;
          slot_valid_bytes_r[i] <= '0;
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

        if (bound_r[0] == 0 || bound_r[1] == 0 || bound_r[2] == 0
            || seg_size_r == 0) begin
          // Degenerate descriptor (no work) — short-circuit to DONE.
          rd_state <= RD_DONE;
          wr_state <= WR_DONE;
        end else begin
          wr_state <= WR_RUN;

          if (direction_bit_r) begin
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
        // -------------------------
        // Source read issue bookkeeping
        //   When a read completes the current rd segment (next_ptr hits
        //   rd_end), advance rd_i_dim and rd_base_src_seg_r to the NEXT
        //   segment immediately. Only set rd_state=RD_DONE when the last
        //   segment's last read is issued. This keeps reads streaming
        //   across segment boundaries (pipeline-hiding HBM latency).
        //   Pre-condition: valid_total > 0 (else rd_state=RD_DONE from init).
        // -------------------------
        if (src_req_fire) begin
          slot_state_r[rd_issue_slot_r] <= SLOT_WAIT_RSP;
          slot_valid_bytes_r[rd_issue_slot_r] <= WIN_VALID_W'(rd_beat_valid_bytes);
          rd_issue_slot_r <= next_rd_slot_idx(rd_issue_slot_r);

          if (rd_crosses_seg) begin
            if (rd_is_last_seg) begin
              // All rd segments issued
              rd_state <= RD_DONE;
              if (direction_bit_r) lmem_rd_ptr <= rd_next_ptr;
              else                 dcache_rd_ptr <= rd_next_ptr;
            end else begin
              // Advance rd_i_dim, rd_base_src_seg_r, recompute rd_ptr/rd_end
              if (rd_i_dim[0] + 32'd1 < bound_r[0]) begin
                rd_i_dim[0] <= rd_i_dim[0] + 32'd1;
              end else begin
                rd_i_dim[0] <= 32'd0;
                if (rd_i_dim[1] + 32'd1 < bound_r[1]) begin
                  rd_i_dim[1] <= rd_i_dim[1] + 32'd1;
                end else begin
                  rd_i_dim[1] <= 32'd0;
                  rd_i_dim[2] <= rd_i_dim[2] + 32'd1;
                end
              end
              rd_base_src_seg_r <= rd_next_base;
              if (direction_bit_r) begin
                lmem_rd_ptr <= align_down(rd_next_base, LMEM_BYTES);
                lmem_rd_end <= align_up(rd_next_base + 64'(valid_total), LMEM_BYTES);
              end else begin
                dcache_rd_ptr <= align_down(rd_next_base, DCACHE_BYTES);
                dcache_rd_end <= align_up(rd_next_base + 64'(valid_total), DCACHE_BYTES);
              end
            end
          end else begin
            // Stay in current rd segment
            if (direction_bit_r) lmem_rd_ptr <= rd_next_ptr;
            else                 dcache_rd_ptr <= rd_next_ptr;
          end
        end

        // -------------------------
        // Source response -> slot capture
        // -------------------------
        if (src_rsp_fire) begin
          slot_state_r[rsp_slot_idx] <= SLOT_READY;
          slot_data_r[rsp_slot_idx]  <= '0;
          if (direction_bit_r)
            slot_data_r[rsp_slot_idx][0 +: LMEM_BYTES*8] <= lmem_bus_if.rsp_data.data;
          else
            slot_data_r[rsp_slot_idx][0 +: DCACHE_BYTES*8] <= dcache_bus_if.rsp_data.data;
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
        wr_base_src_seg_r <= wr_base_src_seg_next;
        wr_base_dst_seg_r <= wr_base_dst_seg_next;
        foreach (wr_i_dim[d]) begin
          wr_i_dim[d] <= wr_i_dim_next[d];
        end

        if (wr_slot_read_fire) begin
          slot_state_r[wr_expect_slot_r] <= SLOT_FREE;
          wr_expect_slot_r <= next_rd_slot_idx(wr_expect_slot_r);
        end

        unique case ({src_req_fire, wr_slot_read_fire})
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
