/*
  VX_lmem_dma.sv

  DMA Engine for LMEM <-> GEMM Unit data transfer
  Parameterized by direction (read/write), LMEM data width, GEMM data width

  Usage:
    - DIR = 0: LMEM -> GEMM (read from LMEM)
    - DIR = 1: GEMM -> LMEM (write to LMEM)
*/
/*
  - Assumptions:
    - seg_size에 대한 제한이 없다
    - lmem_bus_if의 data width와 gemm_bus_if의 data width는 같다고 가정
    - ctrl interface에 sync를 위한 reg_idx, reg_value 신호가 있다고 가정
    - ctrl interface의 start 신호는 idle 일때 한 펄스만 주는 것으로 가정
    - idle과 done 신호는 상태를 나타내는 신호, idle 상태면 idle=1이 유지, done 상태면 done=1이 유지
    - done 상태는 1사이클만 유지되고 다시 idle 상태로 돌아감
    - bound는 loop을 도는 횟수라고 가정, src/dst가 동일한 횟수를 돌아야 하므로 bound는 3차원 하나만 존재 (src와 dst가 공유)
*/

`include "VX_define.vh"

module VX_lmem_dma_misal import VX_gpu_pkg::*; #(
  parameter `STRING INSTANCE_ID = "",
  parameter int DIR  = 0,   // 0: LMEM->GEMM, 1: GEMM->LMEM
  parameter int NDIM = 3
) (
  input  wire clk,
  input  wire reset,

  VX_lmem_dma_ctrl_if.slave ctrl_if,
  VX_gemm_sync_if.master    gemm_sync_if,

  VX_mem_bus_if.master      lmem_bus_if,
  VX_mem_bus_if.master      gemm_bus_if
);

  // ------------------------------------------------------------
  // Width / sanity checks
  // ------------------------------------------------------------
  localparam int BUS_BYTES = lmem_bus_if.DATA_SIZE;
  localparam int BUS_BITS  = BUS_BYTES * 8;
  localparam int BUS_LG2   = `CLOG2(BUS_BYTES);

  initial begin
    if (lmem_bus_if.DATA_SIZE != gemm_bus_if.DATA_SIZE) begin
      $fatal(1, "%s: DATA_SIZE mismatch! lmem=%0d bytes, gemm=%0d bytes",
             INSTANCE_ID, lmem_bus_if.DATA_SIZE, gemm_bus_if.DATA_SIZE);
    end
  end

  function automatic logic [lmem_bus_if.ADDR_WIDTH-1:0] to_bus_addr(input logic [63:0] byte_addr);
    // VX_mem_bus_if.addr is beat address (byte_addr / BUS_BYTES)
    to_bus_addr = lmem_bus_if.ADDR_WIDTH'(byte_addr>>BUS_LG2);
  endfunction

  function automatic logic [63:0] align_down(input logic [63:0] a);
    logic [63:0] m;
    begin
      m = 64'(BUS_BYTES-1);
      align_down = (a & ~m);
    end
  endfunction

  function automatic logic [63:0] align_up(input logic [63:0] a);
    logic [63:0] m;
    begin
      m = 64'(BUS_BYTES-1);
      align_up = (a + m) & ~m;
    end
  endfunction

  function automatic logic [31:0] umin32(input logic [31:0] a, input logic [31:0] b);
    return (a < b) ? a : b;
  endfunction

  function automatic logic [BUS_BYTES-1:0] mask_range(input int lane, input int nbytes);
    logic [BUS_BYTES-1:0] m;
    int i;
    begin
      m = '0;
      for (i = 0; i < BUS_BYTES; i++) begin
        if ((i >= lane) && (i < (lane + nbytes)))
          m[i] = 1'b1;
      end
      return m;
    end
  endfunction

  // ------------------------------------------------------------
  // Select source/dest bus by DIR
  // ------------------------------------------------------------
  // DIR=0: src=lmem, dst=gemm (dst write may have no rsp; commit on req handshake) load
  // DIR=1: src=gemm, dst=lmem (dst write may have no rsp; commit on req handshake) store
  wire src_is_gemm = (DIR != 0);
  wire dst_is_gemm = (DIR == 0);

  // ------------------------------------------------------------
  // FSM
  // ------------------------------------------------------------
  typedef enum logic [3:0] {
    S_IDLE,
    S_PREP_SEG,
    S_DECIDE,
    S_SRC_RD_REQ,
    S_SRC_RD_WAIT,
    S_DST_WR_REQ,
    //S_DST_WR_WAIT, // only used when dst_is_gemm (DIR=0)
    S_ADV_SEG,
    S_SYNC,
    S_DONE
  } state_e;

  state_e state, state_n;

  // ------------------------------------------------------------
  // Latched control regs on start
  // ------------------------------------------------------------
  logic [63:0] base_addr_r[2];          // [0]=src, [1]=dst
  logic [31:0] stride_r[2][NDIM];
  logic [31:0] bound_r[NDIM];
  logic [31:0] seg_size_r;
  logic [31:0] reg_idx_r;
  logic [31:0] reg_value_r;

  wire cmd_start = ctrl_if.start && (state == S_IDLE);

  always_ff @(posedge clk) begin
    if (reset) begin
      base_addr_r[0] <= '0; base_addr_r[1] <= '0;
      seg_size_r     <= '0;
      reg_idx_r      <= '0;
      reg_value_r    <= '0;
      for (int d=0; d<NDIM; d++) begin
        stride_r[0][d] <= '0;
        stride_r[1][d] <= '0;
        bound_r[d]     <= '0;
      end
    end else if (cmd_start) begin
      if (ctrl_if.bounds[0] == 0 ||
          ctrl_if.bounds[1] == 0 ||
          ctrl_if.bounds[2] == 0) begin
        $fatal(1, "%s: VX_lmem_dma_misal: ERROR - bounds cannot be zero!", INSTANCE_ID);
      end
      
      base_addr_r[0] <= ctrl_if.src_base_addr;
      base_addr_r[1] <= ctrl_if.dst_base_addr;
      for (int d=0; d<NDIM; d++) begin
        stride_r[0][d] <= ctrl_if.src_strides[d];
        stride_r[1][d] <= ctrl_if.dst_strides[d];
        bound_r[d]     <= ctrl_if.bounds[d];
      end
      seg_size_r   <= ctrl_if.seg_size;
      reg_idx_r    <= ctrl_if.reg_idx;
      reg_value_r  <= ctrl_if.reg_value;
    end
  end

  // status outputs
  always_comb begin
    ctrl_if.idle = (state == S_IDLE);
    ctrl_if.done = (state == S_DONE); // 1-cycle pulse (S_DONE -> S_IDLE)
  end

  // ------------------------------------------------------------
  // 3D indices + segment offset
  // ------------------------------------------------------------
  logic [31:0] i_dim[NDIM];
  logic [31:0] out_off; // byte offset within segment [0..seg_size)

  logic at_last_idx;
  always_comb begin
    at_last_idx = 1'b1;
    for (int d=0; d<NDIM; d++) begin
      if (bound_r[d] == 0) begin
        at_last_idx = 1'b1; // degenerate, treat as done quickly
      end else if (i_dim[d] != (bound_r[d] - 32'd1)) begin
        at_last_idx = 1'b0;
      end
    end
  end

  // ------------------------------------------------------------
  // Base address per segment (byte)
  // ------------------------------------------------------------
  logic [63:0] base_src_seg, base_dst_seg;

  always_comb begin
    base_src_seg =
        base_addr_r[0]
      + 64'(i_dim[0]) * 64'(stride_r[0][0])
      + 64'(i_dim[1]) * 64'(stride_r[0][1])
      + 64'(i_dim[2]) * 64'(stride_r[0][2]);

    base_dst_seg =
        base_addr_r[1]
      + 64'(i_dim[0]) * 64'(stride_r[1][0])
      + 64'(i_dim[1]) * 64'(stride_r[1][1])
      + 64'(i_dim[2]) * 64'(stride_r[1][2]);
  end

  // ------------------------------------------------------------
  // Window (byte-stream) for source
  // ------------------------------------------------------------
  localparam int WIN_BYTES   = 2 * BUS_BYTES;              // simple, usually enough
  localparam int WIN_BITS    = WIN_BYTES * 8;
  localparam int WIN_VALID_W = `CLOG2(WIN_BYTES + 1);

  logic [WIN_BITS-1:0]  win;
  logic [WIN_VALID_W-1:0] win_valid;

  logic [63:0] src_rd_ptr; // aligned byte address for next src read
  logic [63:0] src_rd_end; // aligned end (exclusive)
  logic [31:0] src_drop;   // initial misalign bytes to drop

  // ------------------------------------------------------------
  // Current src/dst byte addresses for this out_off
  // ------------------------------------------------------------
  logic [63:0] src_byte_addr, dst_byte_addr;

  always_comb begin
    src_byte_addr = base_src_seg + 64'(out_off);
    dst_byte_addr = base_dst_seg + 64'(out_off);
  end

  // ------------------------------------------------------------
  // How many bytes to write this destination beat (no padding concept here)
  // ------------------------------------------------------------
  logic [31:0] remaining;
  int          lane;
  logic [31:0] beat_room;
  logic [31:0] wr_nbytes;   // bytes covered on destination in this step
  logic [31:0] need_src;    // source bytes needed from window (==wr_nbytes here)

  always_comb begin
    remaining = (out_off < seg_size_r) ? (seg_size_r - out_off) : 32'd0;
    lane      = int'(dst_byte_addr[BUS_LG2-1:0]); // dst_byte_addr % BUS_BYTES
    beat_room = BUS_BYTES - lane;
    wr_nbytes = umin32(remaining, beat_room);
    need_src  = wr_nbytes;
  end

  // ------------------------------------------------------------
  // Handshake helpers
  // ------------------------------------------------------------
  wire lmem_req_fire = lmem_bus_if.req_valid && lmem_bus_if.req_ready;
  wire gemm_req_fire = gemm_bus_if.req_valid && gemm_bus_if.req_ready;

  wire lmem_rsp_fire = lmem_bus_if.rsp_valid && lmem_bus_if.rsp_ready;
  wire gemm_rsp_fire = gemm_bus_if.rsp_valid && gemm_bus_if.rsp_ready;

  wire src_rsp_fire  = src_is_gemm ? gemm_rsp_fire : lmem_rsp_fire;
  wire dst_req_fire  = dst_is_gemm ? gemm_req_fire : lmem_req_fire;
  wire dst_rsp_fire  = dst_is_gemm ? gemm_rsp_fire : lmem_rsp_fire;

  // ------------------------------------------------------------
  // Build destination write data/mask from window head
  // ------------------------------------------------------------
  logic [BUS_BITS-1:0]  wr_data;
  logic [BUS_BYTES-1:0] wr_byteen;

  always_comb begin
    wr_data   = '0;
    wr_byteen = mask_range(lane, int'(wr_nbytes));

    // Place stream bytes into dst lanes [lane .. lane+wr_nbytes-1]
    for (int b = 0; b < BUS_BYTES; b++) begin
      if ((b >= lane) && (b < lane + int'(wr_nbytes))) begin
        // window head is byte 0 at win[7:0]
        wr_data[b*8 +: 8] = win[(b - lane)*8 +: 8];
      end
    end
  end

  // ------------------------------------------------------------
  // Bus defaults + FSM combinational
  // ------------------------------------------------------------
  always_comb begin
    // defaults
    lmem_bus_if.req_valid = 1'b0;
    lmem_bus_if.req_data  = '0;
    lmem_bus_if.rsp_ready = 1'b1;

    gemm_bus_if.req_valid = 1'b0;
    gemm_bus_if.req_data  = '0;
    gemm_bus_if.rsp_ready = 1'b1;

    // sync defaults
    gemm_sync_if.valid   = 1'b0;
    gemm_sync_if.reg_idx = reg_idx_r;
    gemm_sync_if.value   = reg_value_r;

    state_n = state;

    unique case (state)
      S_IDLE: begin
        if (cmd_start) state_n = S_PREP_SEG;
      end

      S_PREP_SEG: begin
        // window + src pointers get (re)initialized in sequential block
        state_n = S_DECIDE;
      end

      S_DECIDE: begin
        // 1) if initial misalign drop pending and we have enough, just stay (sequential will drop)
        if ((src_drop != 0) && (win_valid >= src_drop[WIN_VALID_W-1:0])) begin
          state_n = S_DECIDE;
        end else begin
          // 2) ensure window has enough source bytes; if not, read more (if any left)
          if ((need_src > win_valid) && (src_rd_ptr < src_rd_end)) begin
            state_n = S_SRC_RD_REQ;
          end else begin
            state_n = S_DST_WR_REQ;
          end
        end
      end

      S_SRC_RD_REQ: begin
        // issue aligned read to source bus at src_rd_ptr
        if (src_is_gemm) begin
          gemm_bus_if.req_valid         = 1'b1;
          gemm_bus_if.req_data.rw       = 1'b0;
          gemm_bus_if.req_data.addr     = to_bus_addr(src_rd_ptr);
          gemm_bus_if.req_data.byteen   = '0;
          gemm_bus_if.req_data.data     = '0;
          gemm_bus_if.req_data.flags    = '0;
          gemm_bus_if.req_data.tag.uuid = '0;
          gemm_bus_if.req_data.tag.value= '0;
          if (gemm_bus_if.req_ready) state_n = S_SRC_RD_WAIT;
        end else begin
          lmem_bus_if.req_valid         = 1'b1;
          lmem_bus_if.req_data.rw       = 1'b0;
          lmem_bus_if.req_data.addr     = to_bus_addr(src_rd_ptr);
          lmem_bus_if.req_data.byteen   = '0;
          lmem_bus_if.req_data.data     = '0;
          lmem_bus_if.req_data.flags    = '0;
          lmem_bus_if.req_data.tag.uuid = '0;
          lmem_bus_if.req_data.tag.value= '0;
          if (lmem_bus_if.req_ready) state_n = S_SRC_RD_WAIT;
        end
      end

      S_SRC_RD_WAIT: begin
        if (src_rsp_fire) state_n = S_DECIDE;
      end

      S_DST_WR_REQ: begin
        // write to destination bus, beat-aligned addr (dst_byte_addr - lane)
        logic [63:0] dst_aligned;
        dst_aligned = dst_byte_addr - 64'($unsigned(lane));

        if (dst_is_gemm) begin
          // LMEM -> GEMM : write to GEMM (NO rsp) => commit on req handshake
          gemm_bus_if.req_valid         = 1'b1;
          gemm_bus_if.req_data.rw       = 1'b1;
          gemm_bus_if.req_data.addr     = to_bus_addr(dst_aligned);
          gemm_bus_if.req_data.data     = wr_data;
          gemm_bus_if.req_data.byteen   = wr_byteen;
          gemm_bus_if.req_data.flags    = '0;
          gemm_bus_if.req_data.tag.uuid = '0;
          gemm_bus_if.req_data.tag.value= '0;
          if (gemm_bus_if.req_ready) begin
            if (out_off + wr_nbytes >= seg_size_r) state_n = S_ADV_SEG;
            else                                   state_n = S_DECIDE;
          end
        end else begin
          // GEMM -> LMEM : write to LMEM (assume no rsp) => commit on handshake
          lmem_bus_if.req_valid         = 1'b1;
          lmem_bus_if.req_data.rw       = 1'b1;
          lmem_bus_if.req_data.addr     = to_bus_addr(dst_aligned);
          lmem_bus_if.req_data.data     = wr_data;
          lmem_bus_if.req_data.byteen   = wr_byteen;
          lmem_bus_if.req_data.flags    = '0;
          lmem_bus_if.req_data.tag.uuid = '0;
          lmem_bus_if.req_data.tag.value= '0;

          if (lmem_bus_if.req_ready) begin
            // sequential will advance out_off/window pop on req_fire
            if (out_off + wr_nbytes >= seg_size_r)
              state_n = S_ADV_SEG;
            else
              state_n = S_DECIDE;
          end
        end
      end
/*
      S_DST_WR_WAIT: begin
        // only used for dst_is_gemm
        if (dst_rsp_fire) begin
          if (out_off + wr_nbytes >= seg_size_r)
            state_n = S_ADV_SEG;
          else
            state_n = S_DECIDE;
        end
      end*/

      S_ADV_SEG: begin
        // index update done in sequential; next state chosen there via state override OR here
        // we'll just go to S_PREP_SEG by default; sequential may redirect to S_SYNC when last
        state_n = S_PREP_SEG;
      end

      S_SYNC: begin
        gemm_sync_if.valid = 1'b1;
        if (gemm_sync_if.ready) state_n = S_DONE;
      end

      S_DONE: begin
        state_n = S_IDLE;
      end

      default: state_n = S_IDLE;
    endcase
  end

  // ------------------------------------------------------------
  // Sequential: state/counters/window/pointers
  // ------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (reset) begin
      state <= S_IDLE;

      for (int d=0; d<NDIM; d++) i_dim[d] <= '0;
      out_off <= '0;

      win <= '0;
      win_valid <= '0;

      src_rd_ptr <= '0;
      src_rd_end <= '0;
      src_drop   <= '0;

    end else begin
      state <= state_n;

      // --------------------------------------------------------
      // On start: init indices and go
      // --------------------------------------------------------
      if (cmd_start) begin
        for (int d=0; d<NDIM; d++) i_dim[d] <= 32'd0;
        out_off <= 32'd0;
      end

      // --------------------------------------------------------
      // On segment prep: reset window and initialize source pointers
      // --------------------------------------------------------
      if (state == S_PREP_SEG) begin
        out_off <= 32'd0;

        win <= '0;
        win_valid <= '0;

        // Source pointer setup (aligned)
        // We need to read seg_size_r bytes starting from base_src_seg (misaligned allowed)
        src_drop   <= 32'(base_src_seg[BUS_LG2-1:0]);                 // base_src_seg % BUS_BYTES
        src_rd_ptr <= align_down(base_src_seg);                       // aligned start
        src_rd_end <= align_up(base_src_seg + 64'(seg_size_r));            // aligned end (exclusive)
      end

      // --------------------------------------------------------
      // Capture source read response into window (append)
      // --------------------------------------------------------
      if (state == S_SRC_RD_WAIT && src_rsp_fire) begin
        logic [BUS_BITS-1:0] src_data;
        src_data = src_is_gemm ? gemm_bus_if.rsp_data.data : lmem_bus_if.rsp_data.data;

        // append if space is available
        if (win_valid + BUS_BYTES <= WIN_BYTES) begin
          win[win_valid*8 +: BUS_BITS] <= src_data;
          win_valid <= win_valid + BUS_BYTES[WIN_VALID_W-1:0];
        end
        // advance read ptr regardless
        src_rd_ptr <= src_rd_ptr + BUS_BYTES;
      end

      // --------------------------------------------------------
      // Drop initial misalignment bytes once enough bytes are buffered
      // --------------------------------------------------------
      if ((state == S_DECIDE || state == S_SRC_RD_WAIT)
          && (src_drop != 0) && (win_valid >= src_drop[WIN_VALID_W-1:0])) begin
        win       <= win >> (src_drop * 8);
        win_valid <= win_valid - src_drop[WIN_VALID_W-1:0];
        src_drop  <= 32'd0;
      end

      // --------------------------------------------------------
      // After destination write commit, consume bytes from window and advance out_off
      //  - dst_is_gemm: commit on rsp in S_DST_WR_WAIT
      //  - dst_is_lmem: commit on req_fire in S_DST_WR_REQ
      // --------------------------------------------------------
      if (state == S_DST_WR_REQ  && dst_req_fire) begin
        // consume exactly wr_nbytes from window (these are the bytes we used)
        if (wr_nbytes != 0) begin
          win       <= win >> (wr_nbytes * 8);
          win_valid <= win_valid - wr_nbytes[WIN_VALID_W-1:0];
        end
        out_off <= out_off + wr_nbytes;
      end

      // --------------------------------------------------------
      // Segment done -> advance NDIM indices in S_ADV_SEG
      // --------------------------------------------------------
      if (state == S_ADV_SEG) begin
        // If we just finished the last segment of the last index, go to SYNC.
        // NOTE: segment is considered finished when out_off already reached seg_size_r.
        if (at_last_idx) begin
          state <= S_SYNC; // override next-state to sync
        end else begin
          // NDIM carry
          if (i_dim[0] + 1 < bound_r[0]) begin
            i_dim[0] <= i_dim[0] + 1;
          end else begin
            i_dim[0] <= 32'd0;
            if (i_dim[1] + 1 < bound_r[1]) begin
              i_dim[1] <= i_dim[1] + 1;
            end else begin
              i_dim[1] <= 32'd0;
              if (i_dim[2] + 1 < bound_r[2]) begin
                i_dim[2] <= i_dim[2] + 1;
              end else begin
                i_dim[2] <= 32'd0;
              end
            end
          end
        end
      end

    end
  end

endmodule
