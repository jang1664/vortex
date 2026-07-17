`include "VX_define.vh"

//==============================================================================
// VX_dma_unit_misal
//  Pipelined misaligned DMA backend.
//
//  The datapath is split into four independently backpressured stages:
//    1. 3-D source address generation and tagged read-request enqueue
//    2. source read-request issue through registered request queues
//    3. tagged response capture and aligned-fast/PACK destination assembly
//    4. destination write-request issue through the same request queues
//
//  Read slots allow the address generator to run across segment boundaries
//  while older responses are waiting, being packed, or waiting to be written.
//==============================================================================

module VX_dma_unit_misal import VX_gpu_pkg::*; #(
  parameter `STRING INSTANCE_ID = "",
  parameter int MISALIGN_PACK_BYTES = LSU_WORD_SIZE,
  parameter int DCACHE_ADDR_WIDTH = 1,
  parameter int LMEM_ADDR_WIDTH   = 1,
  parameter int DCACHE_TAG_WIDTH = 1,
  parameter int LMEM_TAG_WIDTH   = 1,
  parameter int RD_OUTSTANDING = 2
) (
  input wire clk,
  input wire reset,

  VX_config_reg_if.slave cfg_reg_if,

  VX_mem_bus_if.master   dcache_bus_if,
  VX_mem_bus_if.master   lmem_bus_if,

  VX_node_done_if.master done_if
`ifdef PERF_ENABLE
  ,output dma_perf_t perf
`endif
);

  localparam int NUM_REGS     = `DMA_CFG_REG_NUM;
  localparam int NDIM         = 3;
  localparam int DESC_DIR_IDX = 16;

  localparam int DCACHE_BYTES = dcache_bus_if.DATA_SIZE;
  localparam int LMEM_BYTES   = lmem_bus_if.DATA_SIZE;
  localparam int DCACHE_LG2   = `CLOG2(DCACHE_BYTES);
  localparam int LMEM_LG2     = `CLOG2(LMEM_BYTES);
  localparam int MIN_BYTES    = (DCACHE_BYTES < LMEM_BYTES) ? DCACHE_BYTES : LMEM_BYTES;
  localparam int MAX_BYTES    = (DCACHE_BYTES > LMEM_BYTES) ? DCACHE_BYTES : LMEM_BYTES;
  localparam int PACK_BYTES   = MISALIGN_PACK_BYTES;
  localparam int PACK_BITS    = PACK_BYTES * 8;
  localparam int FAST_BYTES   = MIN_BYTES;
  localparam int FAST_BITS    = FAST_BYTES * 8;
  localparam int MAX_CHUNKS   = MAX_BYTES / PACK_BYTES;
  localparam int DCACHE_CHUNKS = DCACHE_BYTES / PACK_BYTES;
  localparam int LMEM_CHUNKS   = LMEM_BYTES / PACK_BYTES;
  localparam int MAX_FAST_CHUNKS = MAX_BYTES / FAST_BYTES;
  localparam int DCACHE_FAST_CHUNKS = DCACHE_BYTES / FAST_BYTES;
  localparam int LMEM_FAST_CHUNKS = LMEM_BYTES / FAST_BYTES;

  localparam int DCACHE_TAG_VALUE_W = DCACHE_TAG_WIDTH - `UP(UUID_WIDTH);
  localparam int LMEM_TAG_VALUE_W   = LMEM_TAG_WIDTH - `UP(UUID_WIDTH);
  localparam int MIN_TAG_VALUE_W    = (DCACHE_TAG_VALUE_W < LMEM_TAG_VALUE_W)
                                    ? DCACHE_TAG_VALUE_W : LMEM_TAG_VALUE_W;
  localparam int RD_SLOT_BITS_CAP   = (RD_OUTSTANDING > 1)
                                    ? $clog2(RD_OUTSTANDING) : 0;
  localparam int RD_SLOT_BITS       = (RD_SLOT_BITS_CAP < 1) ? 1 : RD_SLOT_BITS_CAP;
  // The source response owns the slot tag. Preserve the wider DCache window
  // for G2L even when the LMEM response tag limits L2G to fewer slots.
  localparam int DCACHE_SLOT_BITS   = (DCACHE_TAG_VALUE_W < RD_SLOT_BITS_CAP)
                                    ? DCACHE_TAG_VALUE_W : RD_SLOT_BITS_CAP;
  localparam int LMEM_SLOT_BITS     = (LMEM_TAG_VALUE_W < RD_SLOT_BITS_CAP)
                                    ? LMEM_TAG_VALUE_W : RD_SLOT_BITS_CAP;
  localparam int DCACHE_RD_OUTSTANDING = (DCACHE_SLOT_BITS == 0)
                                       ? 1 : (1 << DCACHE_SLOT_BITS);
  localparam int LMEM_RD_OUTSTANDING = (LMEM_SLOT_BITS == 0)
                                     ? 1 : (1 << LMEM_SLOT_BITS);
  localparam int SLOT_OCC_W         = `CLOG2(RD_OUTSTANDING + 1);
  localparam int SLOT_BYTE_W        = `CLOG2(MAX_BYTES + 1);

  localparam int REQ_BUF_DEPTH      = 4;
  localparam int REQ_PENDING_W      = `CLOG2(REQ_BUF_DEPTH + 1);
  localparam int DCACHE_RD_CTRL_DATAW = DCACHE_ADDR_WIDTH + MEM_FLAGS_WIDTH
                                      + `UP(UUID_WIDTH) + DCACHE_TAG_VALUE_W;
  localparam int LMEM_RD_CTRL_DATAW = LMEM_ADDR_WIDTH + MEM_FLAGS_WIDTH
                                    + `UP(UUID_WIDTH) + LMEM_TAG_VALUE_W;
  localparam int DCACHE_WR_DATAW = DCACHE_ADDR_WIDTH + (DCACHE_BYTES * 8)
                                + DCACHE_BYTES + MEM_FLAGS_WIDTH
                                + `UP(UUID_WIDTH) + DCACHE_TAG_VALUE_W;
  localparam int LMEM_WR_DATAW = LMEM_ADDR_WIDTH + (LMEM_BYTES * 8)
                              + LMEM_BYTES + MEM_FLAGS_WIDTH
                              + `UP(UUID_WIDTH) + LMEM_TAG_VALUE_W;

  function automatic bit is_power_of_two(input int value);
    return (value > 0) && ((value & (value - 1)) == 0);
  endfunction

  initial begin
    if (cfg_reg_if.DW != 32)
      $fatal(1, "cfg_reg_if.DW must be 32");
    if (cfg_reg_if.NUM < NUM_REGS)
      $fatal(1, "cfg_reg_if.NUM(%0d) < NUM_REGS(%0d)", cfg_reg_if.NUM, NUM_REGS);
    if (MIN_TAG_VALUE_W < 1)
      $fatal(1, "tag.value width must be >= 1 (dcache=%0d, lmem=%0d)", DCACHE_TAG_VALUE_W, LMEM_TAG_VALUE_W);
    if (!is_power_of_two(RD_OUTSTANDING))
      $fatal(1, "RD_OUTSTANDING(%0d) must be a power of two", RD_OUTSTANDING);
    if (!is_power_of_two(PACK_BYTES))
      $fatal(1, "MISALIGN_PACK_BYTES(%0d) must be a power of two", PACK_BYTES);
    if (PACK_BYTES > MIN_BYTES)
      $fatal(1, "MISALIGN_PACK_BYTES(%0d) exceeds min bus width(%0d)", PACK_BYTES, MIN_BYTES);
    if ((DCACHE_BYTES % PACK_BYTES) != 0)
      $fatal(1, "DCACHE_BYTES(%0d) must be divisible by MISALIGN_PACK_BYTES(%0d)", DCACHE_BYTES, PACK_BYTES);
    if ((LMEM_BYTES % PACK_BYTES) != 0)
      $fatal(1, "LMEM_BYTES(%0d) must be divisible by MISALIGN_PACK_BYTES(%0d)", LMEM_BYTES, PACK_BYTES);
  end

  function automatic logic [DCACHE_ADDR_WIDTH-1:0] to_dcache_addr(input logic [63:0] byte_addr);
    return DCACHE_ADDR_WIDTH'(byte_addr >> DCACHE_LG2);
  endfunction

  function automatic logic [LMEM_ADDR_WIDTH-1:0] to_lmem_addr(input logic [63:0] byte_addr);
    return LMEM_ADDR_WIDTH'(byte_addr >> LMEM_LG2);
  endfunction

  function automatic logic [31:0] umin32(input logic [31:0] a, input logic [31:0] b);
    return (a < b) ? a : b;
  endfunction

  function automatic logic [63:0] align_down(input logic [63:0] a, input int bytes);
    logic [63:0] mask;
    begin
      mask = 64'(bytes) - 64'd1;
      return a & ~mask;
    end
  endfunction

  function automatic logic [63:0] align_up(input logic [63:0] a, input int bytes);
    logic [63:0] mask;
    begin
      mask = 64'(bytes) - 64'd1;
      return (a + mask) & ~mask;
    end
  endfunction

  function automatic logic [PACK_BITS-1:0] select_src_chunk(
    input logic [MAX_BYTES*8-1:0] data,
    input int                     chunk_idx,
    input int                     src_bytes
  );
    logic [PACK_BITS-1:0] chunk;
    begin
      chunk = '0;
      for (int c = 0; c < MAX_CHUNKS; ++c) begin
        if ((chunk_idx == c) && ((c * PACK_BYTES) < src_bytes))
          chunk = data[(c * PACK_BITS) +: PACK_BITS];
      end
      return chunk;
    end
  endfunction

  function automatic logic [PACK_BITS-1:0] make_src_pack(
    input logic [MAX_BYTES*8-1:0] data,
    input logic [31:0]            lane,
    input int                     src_bytes
  );
    int chunk_idx;
    int byte_off;
    logic [2*PACK_BITS-1:0] window;
    logic [PACK_BITS-1:0] result;
    begin
      chunk_idx = int'(lane / PACK_BYTES);
      byte_off  = int'(lane % PACK_BYTES);
      window    = {select_src_chunk(data, chunk_idx + 1, src_bytes),
                   select_src_chunk(data, chunk_idx,     src_bytes)};
      for (int i = 0; i < PACK_BYTES; ++i)
        result[i*8 +: 8] = window[(byte_off + i)*8 +: 8];
      return result;
    end
  endfunction

  function automatic logic [FAST_BITS-1:0] select_src_fast(
    input logic [MAX_BYTES*8-1:0] data,
    input logic [31:0]            lane
  );
    logic [FAST_BITS-1:0] result;
    begin
      result = '0;
      for (int c = 0; c < MAX_FAST_CHUNKS; ++c) begin
        if (lane == 32'(c * FAST_BYTES))
          result = data[(c * FAST_BITS) +: FAST_BITS];
      end
      return result;
    end
  endfunction

  function automatic logic [DCACHE_BYTES*8-1:0] insert_dcache_pack(
    input logic [DCACHE_BYTES*8-1:0] old_data,
    input logic [PACK_BITS-1:0]      pack_data,
    input logic [31:0]               lane,
    input logic [31:0]               nbytes
  );
    logic [DCACHE_BYTES*8-1:0] tmp;
    logic [2*PACK_BITS-1:0] window;
    int chunk_idx;
    int byte_off;
    begin
      tmp       = old_data;
      window    = '0;
      chunk_idx = int'(lane / PACK_BYTES);
      byte_off  = int'(lane % PACK_BYTES);
      window[0 +: PACK_BITS] = tmp[(chunk_idx * PACK_BITS) +: PACK_BITS];
      if ((chunk_idx + 1) < DCACHE_CHUNKS)
        window[PACK_BITS +: PACK_BITS] = tmp[((chunk_idx + 1) * PACK_BITS) +: PACK_BITS];
      for (int i = 0; i < PACK_BYTES; ++i) begin
        if (i < int'(nbytes))
          window[(byte_off + i) * 8 +: 8] = pack_data[i * 8 +: 8];
      end
      tmp[(chunk_idx * PACK_BITS) +: PACK_BITS] = window[0 +: PACK_BITS];
      if ((chunk_idx + 1) < DCACHE_CHUNKS)
        tmp[((chunk_idx + 1) * PACK_BITS) +: PACK_BITS] = window[PACK_BITS +: PACK_BITS];
      return tmp;
    end
  endfunction

  function automatic logic [DCACHE_BYTES-1:0] insert_dcache_be(
    input logic [DCACHE_BYTES-1:0] old_be,
    input logic [31:0]             lane,
    input logic [31:0]             nbytes
  );
    logic [DCACHE_BYTES-1:0] tmp;
    begin
      tmp = old_be;
      for (int i = 0; i < DCACHE_BYTES; ++i) begin
        if ((i >= int'(lane)) && (i < int'(lane + nbytes)))
          tmp[i] = 1'b1;
      end
      return tmp;
    end
  endfunction

  function automatic logic [DCACHE_BYTES*8-1:0] insert_dcache_fast(
    input logic [DCACHE_BYTES*8-1:0] old_data,
    input logic [FAST_BITS-1:0]      fast_data,
    input logic [31:0]               lane
  );
    logic [DCACHE_BYTES*8-1:0] tmp;
    begin
      tmp = old_data;
      for (int c = 0; c < DCACHE_FAST_CHUNKS; ++c) begin
        if (lane == 32'(c * FAST_BYTES))
          tmp[(c * FAST_BITS) +: FAST_BITS] = fast_data;
      end
      return tmp;
    end
  endfunction

  function automatic logic [LMEM_BYTES*8-1:0] insert_lmem_pack(
    input logic [LMEM_BYTES*8-1:0] old_data,
    input logic [PACK_BITS-1:0]    pack_data,
    input logic [31:0]             lane,
    input logic [31:0]             nbytes
  );
    logic [LMEM_BYTES*8-1:0] tmp;
    logic [2*PACK_BITS-1:0] window;
    int chunk_idx;
    int byte_off;
    begin
      tmp       = old_data;
      window    = '0;
      chunk_idx = int'(lane / PACK_BYTES);
      byte_off  = int'(lane % PACK_BYTES);
      window[0 +: PACK_BITS] = tmp[(chunk_idx * PACK_BITS) +: PACK_BITS];
      if ((chunk_idx + 1) < LMEM_CHUNKS)
        window[PACK_BITS +: PACK_BITS] = tmp[((chunk_idx + 1) * PACK_BITS) +: PACK_BITS];
      for (int i = 0; i < PACK_BYTES; ++i) begin
        if (i < int'(nbytes))
          window[(byte_off + i) * 8 +: 8] = pack_data[i * 8 +: 8];
      end
      tmp[(chunk_idx * PACK_BITS) +: PACK_BITS] = window[0 +: PACK_BITS];
      if ((chunk_idx + 1) < LMEM_CHUNKS)
        tmp[((chunk_idx + 1) * PACK_BITS) +: PACK_BITS] = window[PACK_BITS +: PACK_BITS];
      return tmp;
    end
  endfunction

  function automatic logic [LMEM_BYTES-1:0] insert_lmem_be(
    input logic [LMEM_BYTES-1:0] old_be,
    input logic [31:0]           lane,
    input logic [31:0]           nbytes
  );
    logic [LMEM_BYTES-1:0] tmp;
    begin
      tmp = old_be;
      for (int i = 0; i < LMEM_BYTES; ++i) begin
        if ((i >= int'(lane)) && (i < int'(lane + nbytes)))
          tmp[i] = 1'b1;
      end
      return tmp;
    end
  endfunction

  function automatic logic [LMEM_BYTES*8-1:0] insert_lmem_fast(
    input logic [LMEM_BYTES*8-1:0] old_data,
    input logic [FAST_BITS-1:0]    fast_data,
    input logic [31:0]             lane
  );
    logic [LMEM_BYTES*8-1:0] tmp;
    begin
      tmp = old_data;
      for (int c = 0; c < LMEM_FAST_CHUNKS; ++c) begin
        if (lane == 32'(c * FAST_BYTES))
          tmp[(c * FAST_BITS) +: FAST_BITS] = fast_data;
      end
      return tmp;
    end
  endfunction

  typedef enum logic [1:0] {
    S_IDLE,
    S_PRECALC,
    S_RUN,
    S_DONE
  } state_e;

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

  state_e state, state_n;
  rd_state_e rd_state;
  wr_state_e wr_state;

  logic cfg_fire;
  assign cfg_reg_if.ready = (state == S_IDLE);
  assign cfg_fire = cfg_reg_if.valid && cfg_reg_if.ready;
  wire cmd_start = cfg_fire && cfg_reg_if.regs[0][0];

  logic [31:0] entry_id_latched;
  logic [`UP(UUID_WIDTH)-1:0] dma_uuid;
  assign dma_uuid = `UP(UUID_WIDTH)'(entry_id_latched);

  logic [63:0] base_addr_r[2];
  logic [31:0] stride_r[2][NDIM];
  logic [63:0] stride_bound_r[2][NDIM];
  logic [31:0] bound_r[NDIM];
  logic [31:0] seg_size_r;
  logic [31:0] padding_r;
  logic        direction_bit_r;
  logic        precalc_pending_r;

  wire precalc_issue = (state == S_PRECALC) && precalc_pending_r;
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

  always_ff @(posedge clk) begin
    if (reset) begin
      entry_id_latched <= '0;
      base_addr_r[0] <= '0;
      base_addr_r[1] <= '0;
      seg_size_r <= '0;
      padding_r <= '0;
      direction_bit_r <= 1'b0;
      precalc_pending_r <= 1'b0;
      for (int d = 0; d < NDIM; ++d) begin
        stride_r[0][d] <= '0;
        stride_r[1][d] <= '0;
        stride_bound_r[0][d] <= '0;
        stride_bound_r[1][d] <= '0;
        bound_r[d] <= '0;
      end
    end else if (cmd_start) begin
      entry_id_latched <= cfg_reg_if.entry_id;
      base_addr_r[0] <= {cfg_reg_if.regs[4][31:0], cfg_reg_if.regs[3][31:0]};
      base_addr_r[1] <= {cfg_reg_if.regs[2][31:0], cfg_reg_if.regs[1][31:0]};
      for (int d = 0; d < NDIM; ++d) begin
        stride_r[0][d] <= cfg_reg_if.regs[5 + 2*d][31:0];
        stride_r[1][d] <= cfg_reg_if.regs[6 + 2*d][31:0];
        bound_r[d] <= cfg_reg_if.regs[11 + d][31:0];
        stride_bound_r[0][d] <= '0;
        stride_bound_r[1][d] <= '0;
      end
      seg_size_r <= cfg_reg_if.regs[14][31:0];
      padding_r <= cfg_reg_if.regs[15][31:0];
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

  logic [31:0] valid_total;
  assign valid_total = (seg_size_r > padding_r) ? (seg_size_r - padding_r) : 32'd0;

  logic [31:0] rd_i_dim[NDIM];
  logic [63:0] rd_src_seg_base_r;
  logic [63:0] rd_src_ptr_r;
  logic [63:0] rd_src_end_r;
  logic [RD_SLOT_BITS-1:0] rd_issue_slot_r;

  logic [31:0] wr_i_dim[NDIM];
  logic [63:0] wr_dst_seg_base_r;
  logic [31:0] wr_out_off_r;
  wire [31:0] out_off = wr_out_off_r;
  logic [63:0] wr_dst_write_base_r;
  logic [31:0] wr_dst_lane_r;
  logic [DCACHE_BYTES*8-1:0] wr_dcache_data_r;
  logic [DCACHE_BYTES-1:0]   wr_dcache_be_r;
  logic [LMEM_BYTES*8-1:0]   wr_lmem_data_r;
  logic [LMEM_BYTES-1:0]     wr_lmem_be_r;

  slot_state_e slot_state_r[RD_OUTSTANDING];
  logic [RD_OUTSTANDING-1:0][SLOT_BYTE_W-1:0] slot_lane_r;
  logic [RD_OUTSTANDING-1:0][SLOT_BYTE_W-1:0] slot_remaining_r;
  logic [RD_SLOT_BITS-1:0] wr_expect_slot_r;
  logic [SLOT_OCC_W-1:0] slot_occupancy_r;

  function automatic logic [RD_SLOT_BITS-1:0] next_slot(
    input logic [RD_SLOT_BITS-1:0] idx,
    input logic [SLOT_OCC_W-1:0] limit
  );
    if (limit <= SLOT_OCC_W'(1))
      return '0;
    else if (SLOT_OCC_W'(idx) + SLOT_OCC_W'(1) >= limit)
      return '0;
    else
      return idx + RD_SLOT_BITS'(1);
  endfunction

  wire rd_is_last_seg = (rd_i_dim[0] + 32'd1 >= bound_r[0])
                      && (rd_i_dim[1] + 32'd1 >= bound_r[1])
                      && (rd_i_dim[2] + 32'd1 >= bound_r[2]);
  wire wr_is_last_seg = (wr_i_dim[0] + 32'd1 >= bound_r[0])
                      && (wr_i_dim[1] + 32'd1 >= bound_r[1])
                      && (wr_i_dim[2] + 32'd1 >= bound_r[2]);

  wire [63:0] rd_next_seg_base =
    (rd_i_dim[0] + 32'd1 < bound_r[0])
      ? (rd_src_seg_base_r + 64'(stride_r[0][0]))
      : ((rd_i_dim[1] + 32'd1 < bound_r[1])
          ? (rd_src_seg_base_r + 64'(stride_r[0][1]) - stride_bound_r[0][0])
          : (rd_src_seg_base_r + 64'(stride_r[0][2])
             - stride_bound_r[0][1] - stride_bound_r[0][0]));

  wire [63:0] wr_next_seg_base =
    (wr_i_dim[0] + 32'd1 < bound_r[0])
      ? (wr_dst_seg_base_r + 64'(stride_r[1][0]))
      : ((wr_i_dim[1] + 32'd1 < bound_r[1])
          ? (wr_dst_seg_base_r + 64'(stride_r[1][1]) - stride_bound_r[1][0])
          : (wr_dst_seg_base_r + 64'(stride_r[1][2])
             - stride_bound_r[1][1] - stride_bound_r[1][0]));

  wire [31:0] rd_src_bytes = direction_bit_r ? 32'(LMEM_BYTES) : 32'(DCACHE_BYTES);
  wire [63:0] rd_next_ptr = rd_src_ptr_r + 64'(rd_src_bytes);
  wire rd_crosses_seg = (rd_next_ptr >= rd_src_end_r);
  wire [63:0] rd_valid_start = (rd_src_ptr_r < rd_src_seg_base_r)
                             ? rd_src_seg_base_r : rd_src_ptr_r;
  wire [63:0] rd_valid_end_limit = rd_src_seg_base_r + 64'(valid_total);
  wire [63:0] rd_beat_end = ((rd_src_ptr_r + 64'(rd_src_bytes)) < rd_valid_end_limit)
                          ? (rd_src_ptr_r + 64'(rd_src_bytes)) : rd_valid_end_limit;
  wire [31:0] rd_issue_lane = 32'(rd_valid_start - rd_src_ptr_r);
  wire [31:0] rd_issue_bytes = (rd_beat_end > rd_valid_start)
                             ? 32'(rd_beat_end - rd_valid_start) : 32'd0;

  logic dcache_req_valid_w;
  wire  dcache_req_ready_w;
  logic dcache_req_rw_w;
  logic [DCACHE_ADDR_WIDTH-1:0] dcache_req_addr_w;
  logic [DCACHE_BYTES*8-1:0] dcache_req_data_w;
  logic [DCACHE_BYTES-1:0] dcache_req_byteen_w;
  logic [MEM_FLAGS_WIDTH-1:0] dcache_req_flags_w;
  logic [`UP(UUID_WIDTH)-1:0] dcache_req_tag_uuid_w;
  logic [DCACHE_TAG_VALUE_W-1:0] dcache_req_tag_value_w;

  logic lmem_req_valid_w;
  wire  lmem_req_ready_w;
  logic lmem_req_rw_w;
  logic [LMEM_ADDR_WIDTH-1:0] lmem_req_addr_w;
  logic [LMEM_BYTES*8-1:0] lmem_req_data_w;
  logic [LMEM_BYTES-1:0] lmem_req_byteen_w;
  logic [MEM_FLAGS_WIDTH-1:0] lmem_req_flags_w;
  logic [`UP(UUID_WIDTH)-1:0] lmem_req_tag_uuid_w;
  logic [LMEM_TAG_VALUE_W-1:0] lmem_req_tag_value_w;

  wire dcache_rd_valid;
  wire dcache_rd_ready;
  wire [DCACHE_ADDR_WIDTH-1:0] dcache_rd_addr;
  wire [MEM_FLAGS_WIDTH-1:0] dcache_rd_flags;
  wire [`UP(UUID_WIDTH)-1:0] dcache_rd_tag_uuid;
  wire [DCACHE_TAG_VALUE_W-1:0] dcache_rd_tag_value;
  wire dcache_wr_valid;
  wire dcache_wr_ready;
  wire [DCACHE_ADDR_WIDTH-1:0] dcache_wr_addr;
  wire [DCACHE_BYTES*8-1:0] dcache_wr_data;
  wire [DCACHE_BYTES-1:0] dcache_wr_byteen;
  wire [MEM_FLAGS_WIDTH-1:0] dcache_wr_flags;
  wire [`UP(UUID_WIDTH)-1:0] dcache_wr_tag_uuid;
  wire [DCACHE_TAG_VALUE_W-1:0] dcache_wr_tag_value;

  wire lmem_rd_valid;
  wire lmem_rd_ready;
  wire [LMEM_ADDR_WIDTH-1:0] lmem_rd_addr;
  wire [MEM_FLAGS_WIDTH-1:0] lmem_rd_flags;
  wire [`UP(UUID_WIDTH)-1:0] lmem_rd_tag_uuid;
  wire [LMEM_TAG_VALUE_W-1:0] lmem_rd_tag_value;
  wire lmem_wr_valid;
  wire lmem_wr_ready;
  wire [LMEM_ADDR_WIDTH-1:0] lmem_wr_addr;
  wire [LMEM_BYTES*8-1:0] lmem_wr_data;
  wire [LMEM_BYTES-1:0] lmem_wr_byteen;
  wire [MEM_FLAGS_WIDTH-1:0] lmem_wr_flags;
  wire [`UP(UUID_WIDTH)-1:0] lmem_wr_tag_uuid;
  wire [LMEM_TAG_VALUE_W-1:0] lmem_wr_tag_value;

  VX_elastic_buffer #(
    .DATAW   (DCACHE_RD_CTRL_DATAW),
    .SIZE    (REQ_BUF_DEPTH),
    .OUT_REG (1)
  ) dcache_req_buf (
    .clk       (clk),
    .reset     (reset),
    .valid_in  (dcache_req_valid_w && !dcache_req_rw_w),
    .ready_in  (dcache_rd_ready),
    .data_in   ({dcache_req_addr_w, dcache_req_flags_w,
                 dcache_req_tag_uuid_w, dcache_req_tag_value_w}),
    .data_out  ({dcache_rd_addr, dcache_rd_flags,
                 dcache_rd_tag_uuid, dcache_rd_tag_value}),
    .valid_out (dcache_rd_valid),
    .ready_out (dcache_bus_if.req_ready)
  );

  VX_elastic_buffer #(
    .DATAW   (DCACHE_WR_DATAW),
    .SIZE    (1),
    .OUT_REG (1)
  ) dcache_wr_buf (
    .clk       (clk),
    .reset     (reset),
    .valid_in  (dcache_req_valid_w && dcache_req_rw_w),
    .ready_in  (dcache_wr_ready),
    .data_in   ({dcache_req_addr_w, dcache_req_data_w,
                 dcache_req_byteen_w, dcache_req_flags_w,
                 dcache_req_tag_uuid_w, dcache_req_tag_value_w}),
    .data_out  ({dcache_wr_addr, dcache_wr_data,
                 dcache_wr_byteen, dcache_wr_flags,
                 dcache_wr_tag_uuid, dcache_wr_tag_value}),
    .valid_out (dcache_wr_valid),
    .ready_out (dcache_bus_if.req_ready)
  );

  VX_elastic_buffer #(
    .DATAW   (LMEM_RD_CTRL_DATAW),
    .SIZE    (REQ_BUF_DEPTH),
    .OUT_REG (1)
  ) lmem_req_buf (
    .clk       (clk),
    .reset     (reset),
    .valid_in  (lmem_req_valid_w && !lmem_req_rw_w),
    .ready_in  (lmem_rd_ready),
    .data_in   ({lmem_req_addr_w, lmem_req_flags_w,
                 lmem_req_tag_uuid_w, lmem_req_tag_value_w}),
    .data_out  ({lmem_rd_addr, lmem_rd_flags,
                 lmem_rd_tag_uuid, lmem_rd_tag_value}),
    .valid_out (lmem_rd_valid),
    .ready_out (lmem_bus_if.req_ready)
  );

  VX_elastic_buffer #(
    .DATAW   (LMEM_WR_DATAW),
    .SIZE    (1),
    .OUT_REG (1)
  ) lmem_wr_buf (
    .clk       (clk),
    .reset     (reset),
    .valid_in  (lmem_req_valid_w && lmem_req_rw_w),
    .ready_in  (lmem_wr_ready),
    .data_in   ({lmem_req_addr_w, lmem_req_data_w,
                 lmem_req_byteen_w, lmem_req_flags_w,
                 lmem_req_tag_uuid_w, lmem_req_tag_value_w}),
    .data_out  ({lmem_wr_addr, lmem_wr_data,
                 lmem_wr_byteen, lmem_wr_flags,
                 lmem_wr_tag_uuid, lmem_wr_tag_value}),
    .valid_out (lmem_wr_valid),
    .ready_out (lmem_bus_if.req_ready)
  );

  assign dcache_req_ready_w = dcache_req_rw_w
                            ? dcache_wr_ready : dcache_rd_ready;
  assign lmem_req_ready_w = lmem_req_rw_w
                          ? lmem_wr_ready : lmem_rd_ready;

  assign dcache_bus_if.req_valid = direction_bit_r
                                 ? dcache_wr_valid : dcache_rd_valid;
  assign dcache_bus_if.req_data.rw = direction_bit_r;
  assign dcache_bus_if.req_data.addr = direction_bit_r
                                    ? dcache_wr_addr : dcache_rd_addr;
  assign dcache_bus_if.req_data.data = direction_bit_r
                                    ? dcache_wr_data : '0;
  assign dcache_bus_if.req_data.byteen = direction_bit_r
                                      ? dcache_wr_byteen : '0;
  assign dcache_bus_if.req_data.flags = direction_bit_r
                                     ? dcache_wr_flags : dcache_rd_flags;
  assign dcache_bus_if.req_data.tag.uuid = direction_bit_r
                                        ? dcache_wr_tag_uuid : dcache_rd_tag_uuid;
  assign dcache_bus_if.req_data.tag.value = direction_bit_r
                                         ? dcache_wr_tag_value : dcache_rd_tag_value;

  assign lmem_bus_if.req_valid = direction_bit_r
                               ? lmem_rd_valid : lmem_wr_valid;
  assign lmem_bus_if.req_data.rw = !direction_bit_r;
  assign lmem_bus_if.req_data.addr = direction_bit_r
                                  ? lmem_rd_addr : lmem_wr_addr;
  assign lmem_bus_if.req_data.data = direction_bit_r
                                  ? '0 : lmem_wr_data;
  assign lmem_bus_if.req_data.byteen = direction_bit_r
                                    ? '0 : lmem_wr_byteen;
  assign lmem_bus_if.req_data.flags = direction_bit_r
                                   ? lmem_rd_flags : lmem_wr_flags;
  assign lmem_bus_if.req_data.tag.uuid = direction_bit_r
                                      ? lmem_rd_tag_uuid : lmem_wr_tag_uuid;
  assign lmem_bus_if.req_data.tag.value = direction_bit_r
                                       ? lmem_rd_tag_value : lmem_wr_tag_value;

  wire dcache_req_issue_fire = dcache_req_valid_w && dcache_req_ready_w;
  wire lmem_req_issue_fire   = lmem_req_valid_w && lmem_req_ready_w;
  wire dcache_req_fire = dcache_bus_if.req_valid && dcache_bus_if.req_ready;
  wire lmem_req_fire   = lmem_bus_if.req_valid && lmem_bus_if.req_ready;
  wire dcache_rsp_fire = dcache_bus_if.rsp_valid && dcache_bus_if.rsp_ready;
  wire lmem_rsp_fire   = lmem_bus_if.rsp_valid && lmem_bus_if.rsp_ready;

  wire src_req_issue_fire = direction_bit_r ? lmem_req_issue_fire : dcache_req_issue_fire;
  wire src_req_fire = direction_bit_r
                    ? (lmem_req_fire && !lmem_bus_if.req_data.rw)
                    : (dcache_req_fire && !dcache_bus_if.req_data.rw);
  wire src_rsp_fire = direction_bit_r ? lmem_rsp_fire : dcache_rsp_fire;
  wire dst_req_fire = direction_bit_r
                    ? (dcache_req_fire && dcache_bus_if.req_data.rw)
                    : (lmem_req_fire && lmem_bus_if.req_data.rw);

  logic [REQ_PENDING_W-1:0] dcache_req_pending_r;
  logic [REQ_PENDING_W-1:0] lmem_req_pending_r;
  // Preserve the established debug/XMR names used by the DMA unittest and
  // existing FSDB analysis scripts.
  wire [REQ_PENDING_W-1:0] dcache_req_buf_pending_r = dcache_req_pending_r;
  wire [REQ_PENDING_W-1:0] lmem_req_buf_pending_r = lmem_req_pending_r;
  wire [REQ_PENDING_W-1:0] dcache_req_pending_next = dcache_req_pending_r
      + REQ_PENDING_W'(dcache_req_issue_fire) - REQ_PENDING_W'(dcache_req_fire);
  wire [REQ_PENDING_W-1:0] lmem_req_pending_next = lmem_req_pending_r
      + REQ_PENDING_W'(lmem_req_issue_fire) - REQ_PENDING_W'(lmem_req_fire);

  wire [SLOT_OCC_W-1:0] rd_outstanding_limit = direction_bit_r
      ? SLOT_OCC_W'(LMEM_RD_OUTSTANDING) : SLOT_OCC_W'(DCACHE_RD_OUTSTANDING);
  wire [RD_SLOT_BITS-1:0] lmem_rsp_slot_idx
      = RD_SLOT_BITS'(lmem_bus_if.rsp_data.tag.value);
  wire [RD_SLOT_BITS-1:0] dcache_rsp_slot_idx
      = RD_SLOT_BITS'(dcache_bus_if.rsp_data.tag.value);
  wire [RD_SLOT_BITS-1:0] rsp_slot_idx = direction_bit_r
      ? lmem_rsp_slot_idx : dcache_rsp_slot_idx;

  logic pack_slot_retire;
  logic [MAX_BYTES*8-1:0] response_payload_wdata;
  wire [MAX_BYTES*8-1:0] response_payload_rdata;
  wire [RD_SLOT_BITS-1:0] wr_next_slot_idx
      = next_slot(wr_expect_slot_r, rd_outstanding_limit);
  wire wr_slot_ready = (slot_state_r[wr_expect_slot_r] == SLOT_READY);
  wire wr_slot_draining = (slot_state_r[wr_expect_slot_r] == SLOT_DRAINING);
  wire wr_next_slot_ready = (slot_state_r[wr_next_slot_idx] == SLOT_READY);
  wire response_payload_read;
  wire [RD_SLOT_BITS-1:0] response_payload_raddr
      = (pack_slot_retire && wr_next_slot_ready)
      ? wr_next_slot_idx : wr_expect_slot_r;

  always_comb begin
    response_payload_wdata = '0;
    if (direction_bit_r)
      response_payload_wdata[0 +: LMEM_BYTES*8] = lmem_bus_if.rsp_data.data;
    else
      response_payload_wdata[0 +: DCACHE_BYTES*8] = dcache_bus_if.rsp_data.data;
  end

  VX_dp_ram #(
    .DATAW     (MAX_BYTES * 8),
    .SIZE      (RD_OUTSTANDING),
    .WRENW     (1),
    .OUT_REG   (1),
    .LUTRAM    (0),
    .RDW_MODE  ("R"),
    .RADDR_REG (1),
    .RESET_RAM (0)
  ) response_payload_ram (
    .clk   (clk),
    .reset (reset),
    .read  (response_payload_read),
    .write (src_rsp_fire),
    .wren  (1'b1),
    .waddr (rsp_slot_idx),
    .wdata (response_payload_wdata),
    .raddr (response_payload_raddr),
    .rdata (response_payload_rdata)
  );

  wire rd_can_issue = (state == S_RUN)
                   && (rd_state == RD_RUN)
                   && (rd_src_ptr_r < rd_src_end_r)
                   && (slot_occupancy_r < rd_outstanding_limit)
                   && (slot_state_r[rd_issue_slot_r] == SLOT_FREE);

  logic pack_can_move;
  logic pack_flush;
  logic pack_move_fire;
  logic pack_fast_move;
  logic [31:0] pack_move_bytes;
  logic [31:0] pack_src_bytes;
  logic [PACK_BITS-1:0] pack_data;
  logic [FAST_BITS-1:0] fast_data;
  logic [DCACHE_BYTES*8-1:0] wr_dcache_data_next;
  logic [DCACHE_BYTES-1:0]   wr_dcache_be_next;
  logic [LMEM_BYTES*8-1:0]   wr_lmem_data_next;
  logic [LMEM_BYTES-1:0]     wr_lmem_be_next;

  wire [31:0] wr_dst_bytes = direction_bit_r ? 32'(DCACHE_BYTES) : 32'(LMEM_BYTES);
  wire [31:0] wr_seg_remaining = (wr_out_off_r < seg_size_r)
                                     ? (seg_size_r - wr_out_off_r) : 32'd0;
  wire [31:0] wr_payload_remaining = (wr_out_off_r < valid_total)
                                         ? (valid_total - wr_out_off_r) : 32'd0;
  wire [31:0] wr_dst_room = (wr_dst_lane_r < wr_dst_bytes)
                                ? (wr_dst_bytes - wr_dst_lane_r) : 32'd0;
  wire [31:0] wr_slot_remaining = 32'(slot_remaining_r[wr_expect_slot_r]);
  wire [31:0] wr_slot_lane = 32'(slot_lane_r[wr_expect_slot_r]);

  wire dst_req_ready_w = direction_bit_r ? dcache_req_ready_w : lmem_req_ready_w;
  wire dst_req_issue_fire = pack_can_move && pack_flush && dst_req_ready_w;

  always_comb begin
    logic [31:0] tmp_min;
    logic [31:0] src_bus_bytes;

    pack_can_move = 1'b0;
    pack_flush = 1'b0;
    pack_move_fire = 1'b0;
    pack_slot_retire = 1'b0;
    pack_fast_move = 1'b0;
    pack_move_bytes = 32'd0;
    pack_src_bytes = 32'd0;
    pack_data = '0;
    fast_data = '0;
    wr_dcache_data_next = wr_dcache_data_r;
    wr_dcache_be_next = wr_dcache_be_r;
    wr_lmem_data_next = wr_lmem_data_r;
    wr_lmem_be_next = wr_lmem_be_r;
    tmp_min = 32'd0;
    src_bus_bytes = direction_bit_r ? 32'(LMEM_BYTES) : 32'(DCACHE_BYTES);

    if ((state == S_RUN) && (wr_state == WR_RUN)
        && (wr_seg_remaining != 0) && (wr_dst_room != 0)) begin
      if (wr_payload_remaining != 0) begin
        pack_can_move = wr_slot_draining && (wr_slot_remaining != 0);
        if (pack_can_move) begin
          pack_fast_move = (wr_seg_remaining >= 32'(FAST_BYTES))
                        && (wr_dst_room >= 32'(FAST_BYTES))
                        && (wr_payload_remaining >= 32'(FAST_BYTES))
                        && (wr_slot_remaining >= 32'(FAST_BYTES))
                        && ((wr_slot_lane & 32'(FAST_BYTES - 1)) == 0)
                        && ((wr_dst_lane_r & 32'(FAST_BYTES - 1)) == 0);
          if (pack_fast_move) begin
            pack_move_bytes = 32'(FAST_BYTES);
            fast_data = select_src_fast(response_payload_rdata, wr_slot_lane);
          end else begin
            tmp_min = umin32(32'(PACK_BYTES), wr_seg_remaining);
            tmp_min = umin32(tmp_min, wr_dst_room);
            tmp_min = umin32(tmp_min, wr_payload_remaining);
            pack_move_bytes = umin32(tmp_min, wr_slot_remaining);
            pack_data = make_src_pack(response_payload_rdata, wr_slot_lane,
                                      int'(src_bus_bytes));
          end
          pack_src_bytes = pack_move_bytes;
        end
      end else begin
        pack_can_move = 1'b1;
        pack_fast_move = (wr_seg_remaining >= 32'(FAST_BYTES))
                      && (wr_dst_room >= 32'(FAST_BYTES))
                      && ((wr_dst_lane_r & 32'(FAST_BYTES - 1)) == 0);
        if (pack_fast_move) begin
          pack_move_bytes = 32'(FAST_BYTES);
        end else begin
          tmp_min = umin32(32'(PACK_BYTES), wr_seg_remaining);
          pack_move_bytes = umin32(tmp_min, wr_dst_room);
        end
        pack_src_bytes = 32'd0;
        pack_data = '0;
      end

      pack_flush = pack_can_move
                && (pack_move_bytes != 0)
                && (((wr_dst_lane_r + pack_move_bytes) >= wr_dst_bytes)
                 || ((wr_out_off_r + pack_move_bytes) >= seg_size_r));
      pack_move_fire = pack_can_move && (!pack_flush || dst_req_ready_w);
      pack_slot_retire = pack_move_fire && (pack_src_bytes != 0)
                      && (pack_move_bytes >= wr_slot_remaining);

      if (pack_can_move && (pack_move_bytes != 0)) begin
        if (direction_bit_r) begin
          if (pack_fast_move)
            wr_dcache_data_next = insert_dcache_fast(wr_dcache_data_r, fast_data,
                                                     wr_dst_lane_r);
          else
            wr_dcache_data_next = insert_dcache_pack(wr_dcache_data_r, pack_data,
                                                     wr_dst_lane_r, pack_move_bytes);
          wr_dcache_be_next = insert_dcache_be(wr_dcache_be_r, wr_dst_lane_r,
                                               pack_move_bytes);
        end else begin
          if (pack_fast_move)
            wr_lmem_data_next = insert_lmem_fast(wr_lmem_data_r, fast_data,
                                                 wr_dst_lane_r);
          else
            wr_lmem_data_next = insert_lmem_pack(wr_lmem_data_r, pack_data,
                                                 wr_dst_lane_r, pack_move_bytes);
          wr_lmem_be_next = insert_lmem_be(wr_lmem_be_r, wr_dst_lane_r,
                                           pack_move_bytes);
        end
      end
    end
  end

  // A completed drain can launch the next in-order SRAM read on the same
  // edge. The registered RAM output then contains the next slot without an
  // additional inter-slot bubble.
  assign response_payload_read = (state == S_RUN) && (wr_state == WR_RUN)
      && (wr_slot_ready || (pack_slot_retire && wr_next_slot_ready));

  always_comb begin
    dcache_req_valid_w = 1'b0;
    dcache_req_rw_w = 1'b0;
    dcache_req_addr_w = '0;
    dcache_req_data_w = '0;
    dcache_req_byteen_w = '0;
    dcache_req_flags_w = '0;
    dcache_req_tag_uuid_w = '0;
    dcache_req_tag_value_w = '0;

    lmem_req_valid_w = 1'b0;
    lmem_req_rw_w = 1'b0;
    lmem_req_addr_w = '0;
    lmem_req_data_w = '0;
    lmem_req_byteen_w = '0;
    lmem_req_flags_w = '0;
    lmem_req_tag_uuid_w = '0;
    lmem_req_tag_value_w = '0;

    // A destination may return a write acknowledgement even though only source
    // read responses feed the packer. Drain both response channels so an
    // acknowledgement cannot backpressure the next descriptor.
    dcache_bus_if.rsp_ready = 1'b1;
    lmem_bus_if.rsp_ready = 1'b1;

    if (rd_can_issue) begin
      if (direction_bit_r) begin
        lmem_req_valid_w = 1'b1;
        lmem_req_rw_w = 1'b0;
        lmem_req_addr_w = to_lmem_addr(rd_src_ptr_r);
        lmem_req_tag_uuid_w = dma_uuid;
        lmem_req_tag_value_w = LMEM_TAG_VALUE_W'(rd_issue_slot_r);
      end else begin
        dcache_req_valid_w = 1'b1;
        dcache_req_rw_w = 1'b0;
        dcache_req_addr_w = to_dcache_addr(rd_src_ptr_r);
        dcache_req_tag_uuid_w = dma_uuid;
        dcache_req_tag_value_w = DCACHE_TAG_VALUE_W'(rd_issue_slot_r);
      end
    end

    if ((state == S_RUN) && (wr_state == WR_RUN) && pack_can_move && pack_flush) begin
      if (direction_bit_r) begin
        dcache_req_valid_w = 1'b1;
        dcache_req_rw_w = 1'b1;
        dcache_req_addr_w = to_dcache_addr(wr_dst_write_base_r);
        dcache_req_data_w = wr_dcache_data_next;
        dcache_req_byteen_w = wr_dcache_be_next;
        dcache_req_tag_uuid_w = dma_uuid;
      end else begin
        lmem_req_valid_w = 1'b1;
        lmem_req_rw_w = 1'b1;
        lmem_req_addr_w = to_lmem_addr(wr_dst_write_base_r);
        lmem_req_data_w = wr_lmem_data_next;
        lmem_req_byteen_w = wr_lmem_be_next;
        lmem_req_tag_uuid_w = dma_uuid;
      end
    end
  end

  wire [SLOT_OCC_W-1:0] slot_occupancy_next = slot_occupancy_r
      + SLOT_OCC_W'(src_req_issue_fire) - SLOT_OCC_W'(pack_slot_retire);

  always_comb begin
    state_n = state;
    unique case (state)
      S_IDLE: begin
        if (cmd_start)
          state_n = S_PRECALC;
      end
      S_PRECALC: begin
        if (precalc_done) begin
          if ((bound_r[0] == 0) || (bound_r[1] == 0) || (bound_r[2] == 0)
              || (seg_size_r == 0))
            state_n = S_DONE;
          else
            state_n = S_RUN;
        end
      end
      S_RUN: begin
        if ((rd_state == RD_DONE) && (wr_state == WR_DONE)
            && (slot_occupancy_next == 0)
            && (dcache_req_pending_next == 0)
            && (lmem_req_pending_next == 0))
          state_n = S_DONE;
      end
      S_DONE: begin
        if (done_if.ready)
          state_n = S_IDLE;
      end
      default: state_n = S_IDLE;
    endcase
  end

  always_ff @(posedge clk) begin
    if (reset) begin
      state <= S_IDLE;
      rd_state <= RD_IDLE;
      wr_state <= WR_IDLE;
      rd_src_seg_base_r <= '0;
      rd_src_ptr_r <= '0;
      rd_src_end_r <= '0;
      rd_issue_slot_r <= '0;
      wr_dst_seg_base_r <= '0;
      wr_out_off_r <= '0;
      wr_dst_write_base_r <= '0;
      wr_dst_lane_r <= '0;
      wr_dcache_data_r <= '0;
      wr_dcache_be_r <= '0;
      wr_lmem_data_r <= '0;
      wr_lmem_be_r <= '0;
      wr_expect_slot_r <= '0;
      slot_occupancy_r <= '0;
      dcache_req_pending_r <= '0;
      lmem_req_pending_r <= '0;
      for (int d = 0; d < NDIM; ++d) begin
        rd_i_dim[d] <= '0;
        wr_i_dim[d] <= '0;
      end
      for (int s = 0; s < RD_OUTSTANDING; ++s) begin
        slot_state_r[s] <= SLOT_FREE;
        slot_lane_r[s] <= '0;
        slot_remaining_r[s] <= '0;
      end
    end else begin
      state <= state_n;
      dcache_req_pending_r <= dcache_req_pending_next;
      lmem_req_pending_r <= lmem_req_pending_next;

      if (cmd_start) begin
        rd_state <= RD_IDLE;
        wr_state <= WR_IDLE;
        rd_src_seg_base_r <= {cfg_reg_if.regs[4][31:0], cfg_reg_if.regs[3][31:0]};
        rd_src_ptr_r <= '0;
        rd_src_end_r <= '0;
        rd_issue_slot_r <= '0;
        wr_dst_seg_base_r <= {cfg_reg_if.regs[2][31:0], cfg_reg_if.regs[1][31:0]};
        wr_out_off_r <= '0;
        wr_dst_write_base_r <= '0;
        wr_dst_lane_r <= '0;
        wr_dcache_data_r <= '0;
        wr_dcache_be_r <= '0;
        wr_lmem_data_r <= '0;
        wr_lmem_be_r <= '0;
        wr_expect_slot_r <= '0;
        slot_occupancy_r <= '0;
        for (int d = 0; d < NDIM; ++d) begin
          rd_i_dim[d] <= '0;
          wr_i_dim[d] <= '0;
        end
        for (int s = 0; s < RD_OUTSTANDING; ++s) begin
          slot_state_r[s] <= SLOT_FREE;
          slot_lane_r[s] <= '0;
          slot_remaining_r[s] <= '0;
        end
      end

      if ((state == S_PRECALC) && precalc_done
          && (bound_r[0] != 0) && (bound_r[1] != 0) && (bound_r[2] != 0)
          && (seg_size_r != 0)) begin
        rd_src_seg_base_r <= base_addr_r[0];
        if (valid_total == 0) begin
          rd_src_ptr_r <= align_down(base_addr_r[0], int'(rd_src_bytes));
          rd_src_end_r <= align_down(base_addr_r[0], int'(rd_src_bytes));
          rd_state <= RD_DONE;
        end else begin
          rd_src_ptr_r <= align_down(base_addr_r[0], int'(rd_src_bytes));
          rd_src_end_r <= align_up(base_addr_r[0] + 64'(valid_total), int'(rd_src_bytes));
          rd_state <= RD_RUN;
        end

        wr_dst_seg_base_r <= base_addr_r[1];
        wr_out_off_r <= 32'd0;
        wr_dst_write_base_r <= align_down(base_addr_r[1], int'(wr_dst_bytes));
        wr_dst_lane_r <= 32'(base_addr_r[1] & (64'(wr_dst_bytes) - 64'd1));
        wr_state <= WR_RUN;
      end else if (state == S_RUN) begin
        if (src_req_issue_fire) begin
          slot_state_r[rd_issue_slot_r] <= SLOT_WAIT_RSP;
          slot_lane_r[rd_issue_slot_r] <= SLOT_BYTE_W'(rd_issue_lane);
          slot_remaining_r[rd_issue_slot_r] <= SLOT_BYTE_W'(rd_issue_bytes);
          rd_issue_slot_r <= next_slot(rd_issue_slot_r, rd_outstanding_limit);

          if (rd_crosses_seg) begin
            if (rd_is_last_seg) begin
              rd_state <= RD_DONE;
              rd_src_ptr_r <= rd_next_ptr;
            end else begin
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
              rd_src_seg_base_r <= rd_next_seg_base;
              rd_src_ptr_r <= align_down(rd_next_seg_base, int'(rd_src_bytes));
              rd_src_end_r <= align_up(rd_next_seg_base + 64'(valid_total), int'(rd_src_bytes));
            end
          end else begin
            rd_src_ptr_r <= rd_next_ptr;
          end
        end

        if (src_rsp_fire) begin
          slot_state_r[rsp_slot_idx] <= SLOT_READY;
        end

        if (response_payload_read)
          slot_state_r[response_payload_raddr] <= SLOT_DRAINING;

        if (pack_move_fire) begin
          logic [31:0] out_off_next;
          out_off_next = wr_out_off_r + pack_move_bytes;

          if (pack_src_bytes != 0) begin
            if (pack_slot_retire) begin
              slot_state_r[wr_expect_slot_r] <= SLOT_FREE;
              slot_lane_r[wr_expect_slot_r] <= '0;
              slot_remaining_r[wr_expect_slot_r] <= '0;
              wr_expect_slot_r <= wr_next_slot_idx;
            end else begin
              slot_lane_r[wr_expect_slot_r] <= SLOT_BYTE_W'(wr_slot_lane + pack_move_bytes);
              slot_remaining_r[wr_expect_slot_r] <= SLOT_BYTE_W'(wr_slot_remaining - pack_move_bytes);
            end
          end

          if (pack_flush) begin
            wr_dcache_data_r <= '0;
            wr_dcache_be_r <= '0;
            wr_lmem_data_r <= '0;
            wr_lmem_be_r <= '0;

            if (out_off_next >= seg_size_r) begin
              if (wr_is_last_seg) begin
                wr_state <= WR_DONE;
                wr_out_off_r <= out_off_next;
              end else begin
                if (wr_i_dim[0] + 32'd1 < bound_r[0]) begin
                  wr_i_dim[0] <= wr_i_dim[0] + 32'd1;
                end else begin
                  wr_i_dim[0] <= 32'd0;
                  if (wr_i_dim[1] + 32'd1 < bound_r[1]) begin
                    wr_i_dim[1] <= wr_i_dim[1] + 32'd1;
                  end else begin
                    wr_i_dim[1] <= 32'd0;
                    wr_i_dim[2] <= wr_i_dim[2] + 32'd1;
                  end
                end
                wr_dst_seg_base_r <= wr_next_seg_base;
                wr_out_off_r <= 32'd0;
                wr_dst_write_base_r <= align_down(wr_next_seg_base, int'(wr_dst_bytes));
                wr_dst_lane_r <= 32'(wr_next_seg_base & (64'(wr_dst_bytes) - 64'd1));
              end
            end else begin
              wr_out_off_r <= out_off_next;
              wr_dst_write_base_r <= wr_dst_write_base_r + 64'(wr_dst_bytes);
              wr_dst_lane_r <= 32'd0;
            end
          end else begin
            wr_out_off_r <= out_off_next;
            wr_dst_lane_r <= wr_dst_lane_r + pack_move_bytes;
            wr_dcache_data_r <= wr_dcache_data_next;
            wr_dcache_be_r <= wr_dcache_be_next;
            wr_lmem_data_r <= wr_lmem_data_next;
            wr_lmem_be_r <= wr_lmem_be_next;
          end
        end

        slot_occupancy_r <= slot_occupancy_next;
      end
    end
  end

`ifdef SIMULATION
  always_ff @(posedge clk) begin
    if (!reset && src_rsp_fire) begin
      assert (slot_state_r[rsp_slot_idx] == SLOT_WAIT_RSP)
        else $fatal(1, "%m: response for non-waiting DMA slot %0d", rsp_slot_idx);
    end
    if (!reset && response_payload_read) begin
      assert (slot_state_r[response_payload_raddr] == SLOT_READY)
        else $fatal(1, "%m: response SRAM read for non-ready DMA slot %0d",
                    response_payload_raddr);
    end
    if (!reset && src_rsp_fire && response_payload_read) begin
      assert (rsp_slot_idx != response_payload_raddr)
        else $fatal(1, "%m: simultaneous response SRAM read/write for DMA slot %0d",
                    rsp_slot_idx);
    end
    if (!reset && pack_move_fire && (pack_src_bytes != 0)) begin
      assert (slot_state_r[wr_expect_slot_r] == SLOT_DRAINING)
        else $fatal(1, "%m: source payload consumed from non-draining DMA slot %0d",
                    wr_expect_slot_r);
    end
    if (!reset && pack_move_fire && pack_fast_move) begin
      assert ((pack_move_bytes == 32'(FAST_BYTES))
           && ((wr_dst_lane_r & 32'(FAST_BYTES - 1)) == 0)
           && ((pack_src_bytes == 0)
            || ((wr_slot_lane & 32'(FAST_BYTES - 1)) == 0)))
        else $fatal(1, "%m: invalid aligned DMA fast move");
    end
  end
`endif

`ifdef DBG_TRACE_GEMM
  always_ff @(posedge clk) begin
    if (!reset) begin
      if (cmd_start) begin
        `TRACE(2, ("%m : [%0t] | DMA_START | {inst=%s, entry_id=%0d, dir=%0d, src_base=0x%0h, dst_base=0x%0h, seg_size=%0d, padding=%0d, bound=[%0d,%0d,%0d], pack=%0d, slots=%0d}\n",
                  $time, INSTANCE_ID, cfg_reg_if.entry_id, cfg_reg_if.regs[DESC_DIR_IDX][0],
                  {cfg_reg_if.regs[4][31:0], cfg_reg_if.regs[3][31:0]},
                  {cfg_reg_if.regs[2][31:0], cfg_reg_if.regs[1][31:0]},
                  cfg_reg_if.regs[14][31:0], cfg_reg_if.regs[15][31:0],
                  cfg_reg_if.regs[11][31:0], cfg_reg_if.regs[12][31:0], cfg_reg_if.regs[13][31:0],
                  PACK_BYTES, RD_OUTSTANDING))
      end
      if (src_req_issue_fire) begin
        `TRACE(3, ("%m : [%0t] | DMA_RD_ENQUEUE | {inst=%s, slot=%0d, addr=0x%0h, lane=%0d, bytes=%0d, occ=%0d}\n",
                  $time, INSTANCE_ID, rd_issue_slot_r, rd_src_ptr_r,
                  rd_issue_lane, rd_issue_bytes, slot_occupancy_r))
      end
      if (src_rsp_fire) begin
        `TRACE(3, ("%m : [%0t] | DMA_RD_RESPONSE | {inst=%s, slot=%0d, occ=%0d}\n",
                  $time, INSTANCE_ID, rsp_slot_idx, slot_occupancy_r))
      end
      if (dst_req_issue_fire) begin
        `TRACE(3, ("%m : [%0t] | DMA_WR_ENQUEUE | {inst=%s, addr=0x%0h, out_off=%0d, bytes=%0d, fast=%0d}\n",
                  $time, INSTANCE_ID, wr_dst_write_base_r, wr_out_off_r,
                  pack_move_bytes, pack_fast_move))
      end
    end
  end
`endif

  always_comb begin
    done_if.valid = (state == S_DONE);
    done_if.entry_id = entry_id_latched;
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

  wire g2l_rd_beat = (state == S_RUN) && !direction_bit_r && dcache_rsp_fire;
  wire l2g_wr_beat = (state == S_RUN) && direction_bit_r
                   && dcache_req_fire && dcache_bus_if.req_data.rw;
  wire dma_is_active = (state != S_IDLE) && (state != S_DONE);
  wire dma_xfer_done = (state != S_DONE) && (state_n == S_DONE);
  wire dma_stall_dcache = dcache_bus_if.req_valid && !dcache_bus_if.req_ready;
  wire dma_stall_lmem = lmem_bus_if.req_valid && !lmem_bus_if.req_ready;
  wire perf_src_rd_req_stall = direction_bit_r
      ? (lmem_bus_if.req_valid && !lmem_bus_if.req_ready && !lmem_bus_if.req_data.rw)
      : (dcache_bus_if.req_valid && !dcache_bus_if.req_ready && !dcache_bus_if.req_data.rw);
  wire perf_src_rd_data_stall = direction_bit_r
      ? (lmem_bus_if.rsp_valid && !lmem_bus_if.rsp_ready)
      : (dcache_bus_if.rsp_valid && !dcache_bus_if.rsp_ready);
  wire perf_dst_wr_stall = direction_bit_r
      ? (dcache_bus_if.req_valid && !dcache_bus_if.req_ready && dcache_bus_if.req_data.rw)
      : (lmem_bus_if.req_valid && !lmem_bus_if.req_ready && lmem_bus_if.req_data.rw);

  always_ff @(posedge clk) begin
    if (reset) begin
      perf_rd_bytes_r <= '0;
      perf_wr_bytes_r <= '0;
      perf_xfers_r <= '0;
      perf_active_r <= '0;
      perf_wait_dcache_r <= '0;
      perf_wait_lmem_r <= '0;
      perf_src_rd_req_fire_r <= '0;
      perf_src_rd_req_stall_r <= '0;
      perf_src_rd_data_fire_r <= '0;
      perf_src_rd_data_stall_r <= '0;
      perf_dst_wr_fire_r <= '0;
      perf_dst_wr_stall_r <= '0;
    end else begin
      if (g2l_rd_beat)
        perf_rd_bytes_r <= perf_rd_bytes_r + PERF_CTR_BITS'(DCACHE_BYTES);
      if (l2g_wr_beat)
        perf_wr_bytes_r <= perf_wr_bytes_r + PERF_CTR_BITS'(DCACHE_BYTES);
      if (dma_xfer_done)
        perf_xfers_r <= perf_xfers_r + PERF_CTR_BITS'(1);
      if (dma_is_active)
        perf_active_r <= perf_active_r + PERF_CTR_BITS'(1);
      if (dma_stall_dcache)
        perf_wait_dcache_r <= perf_wait_dcache_r + PERF_CTR_BITS'(1);
      if (dma_stall_lmem)
        perf_wait_lmem_r <= perf_wait_lmem_r + PERF_CTR_BITS'(1);
      if (src_req_fire)
        perf_src_rd_req_fire_r <= perf_src_rd_req_fire_r + PERF_CTR_BITS'(1);
      if (perf_src_rd_req_stall)
        perf_src_rd_req_stall_r <= perf_src_rd_req_stall_r + PERF_CTR_BITS'(1);
      if (src_rsp_fire)
        perf_src_rd_data_fire_r <= perf_src_rd_data_fire_r + PERF_CTR_BITS'(1);
      if (perf_src_rd_data_stall)
        perf_src_rd_data_stall_r <= perf_src_rd_data_stall_r + PERF_CTR_BITS'(1);
      if (dst_req_fire)
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
  assign perf.wait_dcache       = perf_wait_dcache_r;
  assign perf.wait_lmem         = perf_wait_lmem_r;
  assign perf.busy              = dma_is_active;
`endif

endmodule
