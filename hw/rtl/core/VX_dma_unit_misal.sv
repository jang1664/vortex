`include "VX_define.vh"

//==============================================================================
// VX_dma_unit_misal
//  Misaligned DMA backend.
//
//  This implementation intentionally trades DMA throughput for routability:
//  one source beat is outstanding at a time, and byte realignment is performed
//  over MISALIGN_PACK_BYTES chunks instead of a full-width barrel shifter.
//==============================================================================

module VX_dma_unit_misal import VX_gpu_pkg::*; #(
  parameter `STRING INSTANCE_ID = "",
  parameter int MISALIGN_PACK_BYTES = LSU_WORD_SIZE,
  // Parent forwards interface ADDR_WIDTH and TAG_WIDTH values explicitly. Synopsys DC
  // rejects `interface_inst.PARAM` access inside localparam initializers.
  parameter int DCACHE_ADDR_WIDTH = 1,
  parameter int LMEM_ADDR_WIDTH   = 1,
  parameter int DCACHE_TAG_WIDTH = 1,
  parameter int LMEM_TAG_WIDTH   = 1
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
  localparam int MAX_CHUNKS   = MAX_BYTES / PACK_BYTES;
  localparam int DCACHE_CHUNKS = DCACHE_BYTES / PACK_BYTES;
  localparam int LMEM_CHUNKS   = LMEM_BYTES / PACK_BYTES;

  localparam int DCACHE_TAG_VALUE_W = DCACHE_TAG_WIDTH - `UP(UUID_WIDTH);
  localparam int LMEM_TAG_VALUE_W   = LMEM_TAG_WIDTH - `UP(UUID_WIDTH);
  localparam int MIN_TAG_VALUE_W    = (DCACHE_TAG_VALUE_W < LMEM_TAG_VALUE_W)
                                    ? DCACHE_TAG_VALUE_W : LMEM_TAG_VALUE_W;
  localparam int DCACHE_REQ_DATAW   = 1 + DCACHE_ADDR_WIDTH + (DCACHE_BYTES * 8)
                                   + DCACHE_BYTES + MEM_FLAGS_WIDTH
                                   + `UP(UUID_WIDTH) + DCACHE_TAG_VALUE_W;

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
    to_dcache_addr = DCACHE_ADDR_WIDTH'(byte_addr >> DCACHE_LG2);
  endfunction

  function automatic logic [LMEM_ADDR_WIDTH-1:0] to_lmem_addr(input logic [63:0] byte_addr);
    to_lmem_addr = LMEM_ADDR_WIDTH'(byte_addr >> LMEM_LG2);
  endfunction

  function automatic logic [31:0] umin32(input logic [31:0] a, input logic [31:0] b);
    return (a < b) ? a : b;
  endfunction

  function automatic logic [63:0] align_down(input logic [63:0] a, input int bytes);
    logic [63:0] mask;
    logic [63:0] bytes64;
    begin
      bytes64 = 64'(bytes);
      mask = bytes64 - 64'd1;
      return (a & ~mask);
    end
  endfunction

  function automatic logic [63:0] align_up(input logic [63:0] a, input int bytes);
    logic [63:0] mask;
    logic [63:0] bytes64;
    begin
      bytes64 = 64'(bytes);
      mask = bytes64 - 64'd1;
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
    logic [2*PACK_BITS-1:0] win;
    logic [PACK_BITS-1:0] result;
    begin
      chunk_idx = int'(lane / PACK_BYTES);
      byte_off  = int'(lane % PACK_BYTES);
      win       = {select_src_chunk(data, chunk_idx + 1, src_bytes),
                   select_src_chunk(data, chunk_idx,     src_bytes)};
      for (int i = 0; i < PACK_BYTES; ++i)
        result[i*8 +: 8] = win[(byte_off + i)*8 +: 8];
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
    logic [2*PACK_BITS-1:0] win;
    int chunk_idx;
    int byte_off;
    begin
      tmp       = old_data;
      win       = '0;
      chunk_idx = int'(lane / PACK_BYTES);
      byte_off  = int'(lane % PACK_BYTES);

      win[0 +: PACK_BITS] = tmp[(chunk_idx * PACK_BITS) +: PACK_BITS];
      if ((chunk_idx + 1) < DCACHE_CHUNKS)
        win[PACK_BITS +: PACK_BITS] = tmp[((chunk_idx + 1) * PACK_BITS) +: PACK_BITS];

      for (int i = 0; i < PACK_BYTES; ++i) begin
        if (i < int'(nbytes))
          win[(byte_off + i) * 8 +: 8] = pack_data[i * 8 +: 8];
      end

      tmp[(chunk_idx * PACK_BITS) +: PACK_BITS] = win[0 +: PACK_BITS];
      if ((chunk_idx + 1) < DCACHE_CHUNKS)
        tmp[((chunk_idx + 1) * PACK_BITS) +: PACK_BITS] = win[PACK_BITS +: PACK_BITS];
      return tmp;
    end
  endfunction

  function automatic logic [DCACHE_BYTES-1:0] insert_dcache_be(
    input logic [DCACHE_BYTES-1:0] old_be,
    input logic [31:0]             lane,
    input logic [31:0]             nbytes
  );
    logic [DCACHE_BYTES-1:0] tmp;
    logic [2*PACK_BYTES-1:0] win;
    int chunk_idx;
    int byte_off;
    begin
      tmp       = old_be;
      win       = '0;
      chunk_idx = int'(lane / PACK_BYTES);
      byte_off  = int'(lane % PACK_BYTES);

      win[0 +: PACK_BYTES] = tmp[(chunk_idx * PACK_BYTES) +: PACK_BYTES];
      if ((chunk_idx + 1) < DCACHE_CHUNKS)
        win[PACK_BYTES +: PACK_BYTES] = tmp[((chunk_idx + 1) * PACK_BYTES) +: PACK_BYTES];

      for (int i = 0; i < PACK_BYTES; ++i) begin
        if (i < int'(nbytes))
          win[byte_off + i] = 1'b1;
      end

      tmp[(chunk_idx * PACK_BYTES) +: PACK_BYTES] = win[0 +: PACK_BYTES];
      if ((chunk_idx + 1) < DCACHE_CHUNKS)
        tmp[((chunk_idx + 1) * PACK_BYTES) +: PACK_BYTES] = win[PACK_BYTES +: PACK_BYTES];
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
    logic [2*PACK_BITS-1:0] win;
    int chunk_idx;
    int byte_off;
    begin
      tmp       = old_data;
      win       = '0;
      chunk_idx = int'(lane / PACK_BYTES);
      byte_off  = int'(lane % PACK_BYTES);

      win[0 +: PACK_BITS] = tmp[(chunk_idx * PACK_BITS) +: PACK_BITS];
      if ((chunk_idx + 1) < LMEM_CHUNKS)
        win[PACK_BITS +: PACK_BITS] = tmp[((chunk_idx + 1) * PACK_BITS) +: PACK_BITS];

      for (int i = 0; i < PACK_BYTES; ++i) begin
        if (i < int'(nbytes))
          win[(byte_off + i) * 8 +: 8] = pack_data[i * 8 +: 8];
      end

      tmp[(chunk_idx * PACK_BITS) +: PACK_BITS] = win[0 +: PACK_BITS];
      if ((chunk_idx + 1) < LMEM_CHUNKS)
        tmp[((chunk_idx + 1) * PACK_BITS) +: PACK_BITS] = win[PACK_BITS +: PACK_BITS];
      return tmp;
    end
  endfunction

  function automatic logic [LMEM_BYTES-1:0] insert_lmem_be(
    input logic [LMEM_BYTES-1:0] old_be,
    input logic [31:0]           lane,
    input logic [31:0]           nbytes
  );
    logic [LMEM_BYTES-1:0] tmp;
    logic [2*PACK_BYTES-1:0] win;
    int chunk_idx;
    int byte_off;
    begin
      tmp       = old_be;
      win       = '0;
      chunk_idx = int'(lane / PACK_BYTES);
      byte_off  = int'(lane % PACK_BYTES);

      win[0 +: PACK_BYTES] = tmp[(chunk_idx * PACK_BYTES) +: PACK_BYTES];
      if ((chunk_idx + 1) < LMEM_CHUNKS)
        win[PACK_BYTES +: PACK_BYTES] = tmp[((chunk_idx + 1) * PACK_BYTES) +: PACK_BYTES];

      for (int i = 0; i < PACK_BYTES; ++i) begin
        if (i < int'(nbytes))
          win[byte_off + i] = 1'b1;
      end

      tmp[(chunk_idx * PACK_BYTES) +: PACK_BYTES] = win[0 +: PACK_BYTES];
      if ((chunk_idx + 1) < LMEM_CHUNKS)
        tmp[((chunk_idx + 1) * PACK_BYTES) +: PACK_BYTES] = win[PACK_BYTES +: PACK_BYTES];
      return tmp;
    end
  endfunction

  typedef enum logic [3:0] {
    S_IDLE,
    S_PRECALC,
    S_PREP_SEG,
    S_L2G_SRC_RD_REQ,
    S_L2G_SRC_RD_WAIT,
    S_L2G_PACK,
    S_L2G_DST_WR_REQ,
    S_G2L_SRC_RD_REQ,
    S_G2L_SRC_RD_WAIT,
    S_G2L_PACK,
    S_G2L_DST_WR_REQ,
    S_DCACHE_DRAIN,
    S_DONE
  } state_e;

  state_e state, state_n;

`ifdef DBG_TRACE_GEMM_CTRL
`define VX_DMA_UNIT_MISAL_STRING_HELPERS
`elsif SIMULATION
`define VX_DMA_UNIT_MISAL_STRING_HELPERS
`endif

`ifdef VX_DMA_UNIT_MISAL_STRING_HELPERS
  function automatic string state_to_str(input state_e s);
    case (s)
      S_IDLE:            return "S_IDLE";
      S_PRECALC:         return "S_PRECALC";
      S_PREP_SEG:        return "S_PREP_SEG";
      S_L2G_SRC_RD_REQ:  return "S_L2G_SRC_RD_REQ";
      S_L2G_SRC_RD_WAIT: return "S_L2G_SRC_RD_WAIT";
      S_L2G_PACK:        return "S_L2G_PACK";
      S_L2G_DST_WR_REQ:  return "S_L2G_DST_WR_REQ";
      S_G2L_SRC_RD_REQ:  return "S_G2L_SRC_RD_REQ";
      S_G2L_SRC_RD_WAIT: return "S_G2L_SRC_RD_WAIT";
      S_G2L_PACK:        return "S_G2L_PACK";
      S_G2L_DST_WR_REQ:  return "S_G2L_DST_WR_REQ";
      S_DCACHE_DRAIN:    return "S_DCACHE_DRAIN";
      S_DONE:            return "S_DONE";
      default:           return "S_UNKNOWN";
    endcase
  endfunction
`endif

`ifdef VX_DMA_UNIT_MISAL_STRING_HELPERS
`undef VX_DMA_UNIT_MISAL_STRING_HELPERS
`endif

  logic cfg_fire;
  assign cfg_reg_if.ready = (state == S_IDLE);
  assign cfg_fire = cfg_reg_if.valid && cfg_reg_if.ready;

  logic [31:0] entry_id_latched;
  logic [`UP(UUID_WIDTH)-1:0] dma_uuid;
  assign dma_uuid = `UP(UUID_WIDTH)'(entry_id_latched);

  wire cmd_start = cfg_fire && cfg_reg_if.regs[0][0];

  always_ff @(posedge clk) begin
    if (reset) begin
      entry_id_latched <= '0;
    end else if (cfg_fire) begin
      entry_id_latched <= cfg_reg_if.entry_id;
    end
  end

  logic [31:0] stride_r[2][NDIM];
  logic [63:0] stride_bound_r[2][NDIM];
  logic [31:0] bound_r[NDIM];
  logic [31:0] seg_size_r;
  logic [31:0] padding_r;
  logic        direction_bit_r; // 0: GLOBAL->LMEM, 1: LMEM->GLOBAL
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

  logic [31:0] i_dim[NDIM];
  logic [63:0] src_seg_base_r;
  logic [63:0] dst_seg_base_r;
  logic [31:0] out_off;
  logic [31:0] valid_total;
  assign valid_total = (seg_size_r > padding_r) ? (seg_size_r - padding_r) : 32'd0;

  logic [MAX_BYTES*8-1:0] src_buf_r;
  logic                   src_valid_r;
  logic [63:0]            src_rd_ptr_r;
  logic [63:0]            src_rd_end_r;
  logic [31:0]            src_lane_r;

  logic [63:0] dst_write_base_r;
  logic [31:0] dst_lane_r;
  logic [DCACHE_BYTES*8-1:0] dst_dcache_data_r;
  logic [DCACHE_BYTES-1:0]   dst_dcache_be_r;
  logic [LMEM_BYTES*8-1:0]   dst_lmem_data_r;
  logic [LMEM_BYTES-1:0]     dst_lmem_be_r;
  logic                      seg_done_r;

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

  wire finished = (state == S_DONE);
  wire current_seg_last = (i_dim[0] + 32'd1 >= bound_r[0])
                       && (i_dim[1] + 32'd1 >= bound_r[1])
                       && (i_dim[2] + 32'd1 >= bound_r[2]);

  wire dcache_req_fire = dcache_bus_if.req_valid && dcache_bus_if.req_ready;
  wire lmem_req_fire   = lmem_bus_if.req_valid   && lmem_bus_if.req_ready;
  assign dcache_req_issue_fire = dcache_req_valid_w && dcache_req_ready_w;
  assign dcache_req_buf_pending_next = dcache_req_buf_pending_r
                                     + 2'(dcache_req_issue_fire)
                                     - 2'(dcache_req_fire);
  wire dcache_rsp_fire = dcache_bus_if.rsp_valid && dcache_bus_if.rsp_ready;
  wire lmem_rsp_fire   = lmem_bus_if.rsp_valid   && lmem_bus_if.rsp_ready;

`ifdef PERF_ENABLE
  wire src_req_fire = ((!direction_bit_r) && dcache_req_fire && !dcache_bus_if.req_data.rw)
                   || ((state == S_L2G_SRC_RD_REQ) && lmem_req_fire);
  wire src_rsp_fire = ((state == S_G2L_SRC_RD_WAIT) && dcache_rsp_fire)
                   || ((state == S_L2G_SRC_RD_WAIT) && lmem_rsp_fire);
`endif
  wire dst_req_issue_fire = ((state == S_G2L_DST_WR_REQ) && lmem_req_fire)
                         || ((state == S_L2G_DST_WR_REQ) && dcache_req_issue_fire);

  logic pack_can_move;
  logic pack_flush;
  logic [31:0] pack_move_bytes;
  logic [31:0] pack_src_bytes;
  logic [PACK_BITS-1:0] pack_data;

  always_comb begin
    logic [31:0] src_bus_bytes;
    logic [31:0] dst_bus_bytes;
    logic [31:0] seg_remaining;
    logic [31:0] dst_room;
    logic [31:0] payload_remaining;
    logic [31:0] src_room;
    logic [31:0] tmp_min;

    dcache_req_valid_w = 1'b0;
    dcache_req_rw_w = 1'b0;
    dcache_req_addr_w = '0;
    dcache_req_data_w = '0;
    dcache_req_byteen_w = '0;
    dcache_req_flags_w = '0;
    dcache_req_tag_uuid_w = '0;
    dcache_req_tag_value_w = '0;
    dcache_bus_if.rsp_ready = (state == S_G2L_SRC_RD_WAIT);

    lmem_bus_if.req_valid = 1'b0;
    lmem_bus_if.req_data  = '0;
    lmem_bus_if.rsp_ready = (state == S_L2G_SRC_RD_WAIT);

    state_n = state;
    src_bus_bytes = 32'd0;
    dst_bus_bytes = 32'd0;
    seg_remaining = 32'd0;
    dst_room = 32'd0;
    payload_remaining = 32'd0;
    src_room = 32'd0;
    tmp_min = 32'd0;
    pack_can_move = 1'b0;
    pack_flush = 1'b0;
    pack_move_bytes = 32'd0;
    pack_src_bytes = 32'd0;
    pack_data = '0;

    if ((state == S_L2G_PACK) || (state == S_G2L_PACK)) begin
      src_bus_bytes = direction_bit_r ? 32'(LMEM_BYTES)   : 32'(DCACHE_BYTES);
      dst_bus_bytes = direction_bit_r ? 32'(DCACHE_BYTES) : 32'(LMEM_BYTES);
      seg_remaining = (out_off < seg_size_r) ? (seg_size_r - out_off) : 32'd0;
      dst_room = (dst_lane_r < dst_bus_bytes) ? (dst_bus_bytes - dst_lane_r) : 32'd0;
      payload_remaining = (out_off < valid_total) ? (valid_total - out_off) : 32'd0;
      src_room = (src_lane_r < src_bus_bytes) ? (src_bus_bytes - src_lane_r) : 32'd0;

      if ((seg_remaining != 0) && (dst_room != 0)) begin
        if (payload_remaining != 0) begin
          pack_can_move = src_valid_r && (src_room != 0);
          if (pack_can_move) begin
            tmp_min = umin32(32'(PACK_BYTES), seg_remaining);
            tmp_min = umin32(tmp_min, dst_room);
            tmp_min = umin32(tmp_min, payload_remaining);
            pack_move_bytes = umin32(tmp_min, src_room);
            pack_src_bytes  = pack_move_bytes;
            pack_data       = make_src_pack(src_buf_r, src_lane_r, int'(src_bus_bytes));
          end
        end else begin
          pack_can_move = 1'b1;
          tmp_min = umin32(32'(PACK_BYTES), seg_remaining);
          pack_move_bytes = umin32(tmp_min, dst_room);
          pack_src_bytes = 32'd0;
          pack_data = '0;
        end

        pack_flush = pack_can_move
                  && (pack_move_bytes != 0)
                  && (((dst_lane_r + pack_move_bytes) >= dst_bus_bytes)
                   || ((out_off + pack_move_bytes) >= seg_size_r));
      end
    end

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
        if ((bound_r[0] == 0) || (bound_r[1] == 0) || (bound_r[2] == 0) || (seg_size_r == 0)) begin
          state_n = S_DONE;
        end else if (direction_bit_r) begin
          state_n = (valid_total != 0) ? S_L2G_SRC_RD_REQ : S_L2G_PACK;
        end else begin
          state_n = (valid_total != 0) ? S_G2L_SRC_RD_REQ : S_G2L_PACK;
        end
      end

      S_L2G_SRC_RD_REQ: begin
        lmem_bus_if.req_valid          = (src_rd_ptr_r < src_rd_end_r);
        lmem_bus_if.req_data.rw        = 1'b0;
        lmem_bus_if.req_data.addr      = to_lmem_addr(src_rd_ptr_r);
        lmem_bus_if.req_data.byteen    = '0;
        lmem_bus_if.req_data.flags     = '0;
        lmem_bus_if.req_data.tag.uuid  = dma_uuid;
        lmem_bus_if.req_data.tag.value = '0;
        if ((src_rd_ptr_r < src_rd_end_r) && lmem_bus_if.req_ready)
          state_n = S_L2G_SRC_RD_WAIT;
      end

      S_L2G_SRC_RD_WAIT: begin
        if (lmem_bus_if.rsp_valid)
          state_n = S_L2G_PACK;
      end

      S_L2G_PACK: begin
        if (pack_can_move)
          state_n = pack_flush ? S_L2G_DST_WR_REQ : S_L2G_PACK;
        else
          state_n = S_L2G_SRC_RD_REQ;
      end

      S_L2G_DST_WR_REQ: begin
        dcache_req_valid_w     = 1'b1;
        dcache_req_rw_w        = 1'b1;
        dcache_req_addr_w      = to_dcache_addr(dst_write_base_r);
        dcache_req_data_w      = dst_dcache_data_r;
        dcache_req_byteen_w    = dst_dcache_be_r;
        dcache_req_flags_w     = '0;
        dcache_req_tag_uuid_w  = dma_uuid;
        dcache_req_tag_value_w = '0;
        if (dcache_req_issue_fire)
          state_n = seg_done_r ? (current_seg_last ? S_DCACHE_DRAIN : S_PREP_SEG) : S_L2G_PACK;
      end

      S_G2L_SRC_RD_REQ: begin
        dcache_req_valid_w     = (src_rd_ptr_r < src_rd_end_r);
        dcache_req_rw_w        = 1'b0;
        dcache_req_addr_w      = to_dcache_addr(src_rd_ptr_r);
        dcache_req_byteen_w    = '0;
        dcache_req_flags_w     = '0;
        dcache_req_tag_uuid_w  = dma_uuid;
        dcache_req_tag_value_w = '0;
        if (dcache_req_issue_fire)
          state_n = S_G2L_SRC_RD_WAIT;
      end

      S_G2L_SRC_RD_WAIT: begin
        if (dcache_bus_if.rsp_valid)
          state_n = S_G2L_PACK;
      end

      S_G2L_PACK: begin
        if (pack_can_move)
          state_n = pack_flush ? S_G2L_DST_WR_REQ : S_G2L_PACK;
        else
          state_n = S_G2L_SRC_RD_REQ;
      end

      S_G2L_DST_WR_REQ: begin
        lmem_bus_if.req_valid          = 1'b1;
        lmem_bus_if.req_data.rw        = 1'b1;
        lmem_bus_if.req_data.addr      = to_lmem_addr(dst_write_base_r);
        lmem_bus_if.req_data.data      = dst_lmem_data_r;
        lmem_bus_if.req_data.byteen    = dst_lmem_be_r;
        lmem_bus_if.req_data.flags     = '0;
        lmem_bus_if.req_data.tag.uuid  = dma_uuid;
        lmem_bus_if.req_data.tag.value = '0;
        if (lmem_bus_if.req_ready)
          state_n = seg_done_r ? (current_seg_last ? S_DONE : S_PREP_SEG) : S_G2L_PACK;
      end

      S_DCACHE_DRAIN: begin
        if (dcache_req_buf_pending_next == 0)
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
      src_seg_base_r <= '0;
      dst_seg_base_r <= '0;
      out_off <= '0;
      src_buf_r <= '0;
      src_valid_r <= 1'b0;
      src_rd_ptr_r <= '0;
      src_rd_end_r <= '0;
      src_lane_r <= '0;
      dst_write_base_r <= '0;
      dst_lane_r <= '0;
      dst_dcache_data_r <= '0;
      dst_dcache_be_r <= '0;
      dst_lmem_data_r <= '0;
      dst_lmem_be_r <= '0;
      seg_done_r <= 1'b0;
      dcache_req_buf_pending_r <= '0;
      for (int d = 0; d < NDIM; ++d)
        i_dim[d] <= '0;
    end else begin
      state <= state_n;
      dcache_req_buf_pending_r <= dcache_req_buf_pending_next;

      if (cmd_start) begin
        src_seg_base_r <= {cfg_reg_if.regs[4][31:0], cfg_reg_if.regs[3][31:0]};
        dst_seg_base_r <= {cfg_reg_if.regs[2][31:0], cfg_reg_if.regs[1][31:0]};
        out_off <= '0;
        src_buf_r <= '0;
        src_valid_r <= 1'b0;
        src_rd_ptr_r <= '0;
        src_rd_end_r <= '0;
        src_lane_r <= '0;
        dst_write_base_r <= '0;
        dst_lane_r <= '0;
        dst_dcache_data_r <= '0;
        dst_dcache_be_r <= '0;
        dst_lmem_data_r <= '0;
        dst_lmem_be_r <= '0;
        seg_done_r <= 1'b0;
        for (int d = 0; d < NDIM; ++d)
          i_dim[d] <= '0;
      end

      if (state == S_PREP_SEG) begin
        logic [31:0] src_bytes;
        logic [31:0] dst_bytes;
        src_bytes = direction_bit_r ? 32'(LMEM_BYTES) : 32'(DCACHE_BYTES);
        dst_bytes = direction_bit_r ? 32'(DCACHE_BYTES) : 32'(LMEM_BYTES);

        out_off <= 32'd0;
        src_buf_r <= '0;
        src_valid_r <= 1'b0;
        src_rd_ptr_r <= align_down(src_seg_base_r, int'(src_bytes));
        src_rd_end_r <= align_up(src_seg_base_r + 64'(valid_total), int'(src_bytes));
        src_lane_r <= 32'(src_seg_base_r & (64'(src_bytes) - 64'd1));
        dst_write_base_r <= align_down(dst_seg_base_r, int'(dst_bytes));
        dst_lane_r <= 32'(dst_seg_base_r & (64'(dst_bytes) - 64'd1));
        dst_dcache_data_r <= '0;
        dst_dcache_be_r <= '0;
        dst_lmem_data_r <= '0;
        dst_lmem_be_r <= '0;
        seg_done_r <= 1'b0;
      end

      if ((state == S_L2G_SRC_RD_REQ) && lmem_req_fire)
        src_rd_ptr_r <= src_rd_ptr_r + 64'(LMEM_BYTES);

      if ((state == S_G2L_SRC_RD_REQ) && dcache_req_issue_fire)
        src_rd_ptr_r <= src_rd_ptr_r + 64'(DCACHE_BYTES);

      if ((state == S_L2G_SRC_RD_WAIT) && lmem_rsp_fire) begin
        src_buf_r <= '0;
        src_buf_r[0 +: LMEM_BYTES*8] <= lmem_bus_if.rsp_data.data;
        src_valid_r <= 1'b1;
      end

      if ((state == S_G2L_SRC_RD_WAIT) && dcache_rsp_fire) begin
        src_buf_r <= '0;
        src_buf_r[0 +: DCACHE_BYTES*8] <= dcache_bus_if.rsp_data.data;
        src_valid_r <= 1'b1;
      end

      if (((state == S_L2G_PACK) || (state == S_G2L_PACK)) && pack_can_move && (pack_move_bytes != 0)) begin
        logic [31:0] src_bus_bytes;
        logic [31:0] src_lane_next;
        logic [31:0] dst_lane_next;
        logic [31:0] out_off_next;

        src_bus_bytes = direction_bit_r ? 32'(LMEM_BYTES) : 32'(DCACHE_BYTES);
        src_lane_next = src_lane_r + pack_src_bytes;
        dst_lane_next = dst_lane_r + pack_move_bytes;
        out_off_next  = out_off + pack_move_bytes;

        if (direction_bit_r) begin
          dst_dcache_data_r <= insert_dcache_pack(dst_dcache_data_r, pack_data, dst_lane_r, pack_move_bytes);
          dst_dcache_be_r   <= insert_dcache_be(dst_dcache_be_r, dst_lane_r, pack_move_bytes);
        end else begin
          dst_lmem_data_r <= insert_lmem_pack(dst_lmem_data_r, pack_data, dst_lane_r, pack_move_bytes);
          dst_lmem_be_r   <= insert_lmem_be(dst_lmem_be_r, dst_lane_r, pack_move_bytes);
        end

        if (pack_src_bytes != 0) begin
          if (src_lane_next >= src_bus_bytes) begin
            src_lane_r <= 32'd0;
            src_valid_r <= 1'b0;
          end else begin
            src_lane_r <= src_lane_next;
          end
        end

        out_off <= out_off_next;
        dst_lane_r <= dst_lane_next;
        if (pack_flush)
          seg_done_r <= (out_off_next >= seg_size_r);
      end

      if (dst_req_issue_fire) begin
        dst_dcache_data_r <= '0;
        dst_dcache_be_r <= '0;
        dst_lmem_data_r <= '0;
        dst_lmem_be_r <= '0;
        dst_lane_r <= 32'd0;
        seg_done_r <= 1'b0;

        if (seg_done_r) begin
          if (!current_seg_last) begin
            if (i_dim[0] + 32'd1 < bound_r[0]) begin
              i_dim[0] <= i_dim[0] + 32'd1;
              src_seg_base_r <= src_seg_base_r + 64'(stride_r[0][0]);
              dst_seg_base_r <= dst_seg_base_r + 64'(stride_r[1][0]);
            end else if (i_dim[1] + 32'd1 < bound_r[1]) begin
              i_dim[0] <= 32'd0;
              i_dim[1] <= i_dim[1] + 32'd1;
              src_seg_base_r <= src_seg_base_r + 64'(stride_r[0][1]) - stride_bound_r[0][0];
              dst_seg_base_r <= dst_seg_base_r + 64'(stride_r[1][1]) - stride_bound_r[1][0];
            end else begin
              i_dim[0] <= 32'd0;
              i_dim[1] <= 32'd0;
              i_dim[2] <= i_dim[2] + 32'd1;
              src_seg_base_r <= src_seg_base_r + 64'(stride_r[0][2]) - stride_bound_r[0][1] - stride_bound_r[0][0];
              dst_seg_base_r <= dst_seg_base_r + 64'(stride_r[1][2]) - stride_bound_r[1][1] - stride_bound_r[1][0];
            end
          end
        end else begin
          if (direction_bit_r)
            dst_write_base_r <= dst_write_base_r + 64'(DCACHE_BYTES);
          else
            dst_write_base_r <= dst_write_base_r + 64'(LMEM_BYTES);
        end
      end
    end
  end

`ifdef DBG_TRACE_GEMM
  always_ff @(posedge clk) begin
    if (!reset) begin
      if (state != state_n) begin
        `TRACE(3, ("%m : [%0t] | DMA_STATE_TRANSITION | {inst=%s, from=%s, to=%s, out_off=%0d, finished=%0d, i0=%0d, i1=%0d, i2=%0d}\n",
                  $time, INSTANCE_ID, state_to_str(state), state_to_str(state_n),
                  out_off, finished, i_dim[0], i_dim[1], i_dim[2]))
      end

      if (cmd_start) begin
        `TRACE(2, ("%m : [%0t] | DMA_START | {inst=%s, entry_id=%0d, dir=%0d, src_base=0x%0h, dst_base=0x%0h, seg_size=%0d, padding=%0d, bound=[%0d,%0d,%0d], pack=%0d}\n",
                  $time, INSTANCE_ID, cfg_reg_if.entry_id, cfg_reg_if.regs[DESC_DIR_IDX][0],
                  {cfg_reg_if.regs[4][31:0], cfg_reg_if.regs[3][31:0]},
                  {cfg_reg_if.regs[2][31:0], cfg_reg_if.regs[1][31:0]},
                  cfg_reg_if.regs[14][31:0], cfg_reg_if.regs[15][31:0],
                  cfg_reg_if.regs[11][31:0], cfg_reg_if.regs[12][31:0], cfg_reg_if.regs[13][31:0],
                  PACK_BYTES))
      end

      if (state == S_PREP_SEG) begin
        `TRACE(2, ("%m : [%0t] | DMA_SEG_PREP | {inst=%s, mode=%s, i0=%0d, i1=%0d, i2=%0d, src_base=0x%0h, dst_base=0x%0h, seg_size=%0d, valid_total=%0d, padding=%0d}\n",
                  $time, INSTANCE_ID, direction_bit_r ? "L2G" : "G2L",
                  i_dim[0], i_dim[1], i_dim[2], src_seg_base_r, dst_seg_base_r,
                  seg_size_r, valid_total, padding_r))
      end

      if ((state == S_L2G_SRC_RD_REQ) && lmem_req_fire) begin
        `TRACE(2, ("%m : [%0t] | DMA_RUN_L2G_RD_REQ_LMEM | {inst=%s, addr=0x%0h, byte_addr=0x%0h, out_off=%0d}\n",
                  $time, INSTANCE_ID, lmem_bus_if.req_data.addr,
                  (64'(lmem_bus_if.req_data.addr) << LMEM_LG2), out_off))
      end

      if (!direction_bit_r && dcache_req_fire && !dcache_bus_if.req_data.rw) begin
        `TRACE(2, ("%m : [%0t] | DMA_RUN_G2L_RD_REQ_DCACHE | {inst=%s, addr=0x%0h, byte_addr=0x%0h, out_off=%0d}\n",
                  $time, INSTANCE_ID, dcache_bus_if.req_data.addr,
                  (64'(dcache_bus_if.req_data.addr) << DCACHE_LG2), out_off))
      end

      if (direction_bit_r && dcache_req_fire && dcache_bus_if.req_data.rw) begin
        `TRACE(2, ("%m : [%0t] | DMA_RUN_L2G_WR_REQ_DCACHE | {inst=%s, addr=0x%0h, byte_addr=0x%0h, byteen=0x%0h, out_off=%0d}\n",
                  $time, INSTANCE_ID, dcache_bus_if.req_data.addr,
                  (64'(dcache_bus_if.req_data.addr) << DCACHE_LG2),
                  dcache_bus_if.req_data.byteen, out_off))
      end

      if ((state == S_G2L_DST_WR_REQ) && lmem_req_fire) begin
        `TRACE(2, ("%m : [%0t] | DMA_RUN_G2L_WR_REQ_LMEM | {inst=%s, addr=0x%0h, byte_addr=0x%0h, byteen=0x%0h, out_off=%0d}\n",
                  $time, INSTANCE_ID, lmem_bus_if.req_data.addr,
                  (64'(lmem_bus_if.req_data.addr) << LMEM_LG2),
                  lmem_bus_if.req_data.byteen, out_off))
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

  wire g2l_rd_beat = (state == S_G2L_SRC_RD_WAIT) && dcache_rsp_fire;
  wire l2g_wr_beat = direction_bit_r && dcache_req_fire && dcache_bus_if.req_data.rw;
  wire dma_is_active = (state != S_IDLE) && (state != S_DONE);
  wire dma_xfer_done = (state != S_DONE) && (state_n == S_DONE);
  wire dma_stall_dcache = (dcache_bus_if.req_valid && !dcache_bus_if.req_ready)
                        | ((state == S_G2L_SRC_RD_WAIT) && dcache_bus_if.rsp_valid && !dcache_bus_if.rsp_ready);
  wire dma_stall_lmem = ((state == S_L2G_SRC_RD_REQ) && lmem_bus_if.req_valid && !lmem_bus_if.req_ready)
                      | ((state == S_L2G_SRC_RD_WAIT) && lmem_bus_if.rsp_valid && !lmem_bus_if.rsp_ready)
                      | ((state == S_G2L_DST_WR_REQ) && lmem_bus_if.req_valid && !lmem_bus_if.req_ready);
  wire perf_src_rd_req_fire  = src_req_fire;
  wire perf_src_rd_req_stall = ((!direction_bit_r) && dcache_bus_if.req_valid && !dcache_bus_if.req_ready
                                && !dcache_bus_if.req_data.rw)
                             | ((state == S_L2G_SRC_RD_REQ) && lmem_bus_if.req_valid && !lmem_bus_if.req_ready);
  wire perf_src_rd_data_fire  = src_rsp_fire;
  wire perf_src_rd_data_stall = ((state == S_G2L_SRC_RD_WAIT) && dcache_bus_if.rsp_valid && !dcache_bus_if.rsp_ready)
                              | ((state == S_L2G_SRC_RD_WAIT) && lmem_bus_if.rsp_valid && !lmem_bus_if.rsp_ready);
  wire perf_dst_wr_fire  = ((state == S_G2L_DST_WR_REQ) && lmem_req_fire)
                         | (direction_bit_r && dcache_req_fire && dcache_bus_if.req_data.rw);
  wire perf_dst_wr_stall = ((state == S_G2L_DST_WR_REQ) && lmem_bus_if.req_valid && !lmem_bus_if.req_ready)
                         | (direction_bit_r && dcache_bus_if.req_valid && !dcache_bus_if.req_ready
                            && dcache_bus_if.req_data.rw);

  reg g2l_rd_beat_q;
  reg l2g_wr_beat_q;
  reg dma_is_active_q;
  reg dma_xfer_done_q;
  reg dma_stall_dcache_q;
  reg dma_stall_lmem_q;
  reg perf_src_rd_req_fire_q,   perf_src_rd_req_stall_q;
  reg perf_src_rd_data_fire_q,  perf_src_rd_data_stall_q;
  reg perf_dst_wr_fire_q,       perf_dst_wr_stall_q;

  always_ff @(posedge clk) begin
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
  localparam int DBG_ADDR64_W = $bits(src_seg_base_r);

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
      i_dim[0],
      i_dim[1],
      i_dim[2]
  };

  (* keep = "true", mark_debug = "true" *) wire [DBG_DMA_UNIT_P2_W-1:0] dbg_dma_unit_probe2 = {
      src_seg_base_r,
      dst_seg_base_r,
      src_rd_ptr_r,
      src_rd_end_r,
      dst_write_base_r,
      64'(dst_lane_r)
  };

  (* keep = "true", mark_debug = "true" *) wire [DBG_DMA_UNIT_P3_W-1:0] dbg_dma_unit_probe3 = {
      src_lane_r,
      dst_lane_r,
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
