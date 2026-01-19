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

  function automatic logic [lmem_bus_if.ADDR_WIDTH-1:0] to_bus_addr(input logic [31:0] byte_addr);
    // VX_mem_bus_if.addr is beat address (byte_addr / BUS_BYTES)
    to_bus_addr = byte_addr[31:BUS_LG2];
  endfunction

  function automatic logic [BUS_LG2-1:0] byte_off(input logic [31:0] byte_addr);
    byte_off = byte_addr[BUS_LG2-1:0];
  endfunction

  // ------------------------------------------------------------
  // FSM + latched regs
  // ------------------------------------------------------------
  typedef enum logic [2:0] {
    S_IDLE,
    S_RD_REQ,
    S_RD_WAIT,
    S_WR_REQ,
    S_WR_WAIT, // only used for DIR=0 (write to GEMM)
    S_SYNC,
    S_DONE
  } state_e;

  state_e state, state_n;

  logic [31:0] base_addr_r[2];          // [0]=src, [1]=dst
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

  always_comb begin
    ctrl_if.idle = (state == S_IDLE);
    ctrl_if.done = (state == S_DONE);
  end

  // ------------------------------------------------------------
  // 3D indices + segment tracking
  // ------------------------------------------------------------
  logic [31:0] i_dim[NDIM];
  logic [31:0] seg_off;     // byte offset within segment
  logic [31:0] seg_rem;     // remaining bytes in segment

  logic at_last_idx;
  always_comb begin
    at_last_idx = 1'b1;
    for (int d=0; d<NDIM; d++) begin
      if (i_dim[d] != (bound_r[d] - 32'd1))
        at_last_idx = 1'b0;
    end
  end

  // ------------------------------------------------------------
  // Byte addresses (misaligned allowed)
  // ------------------------------------------------------------
  logic [31:0] src_byte_addr, dst_byte_addr;

  always_comb begin
    src_byte_addr =
        base_addr_r[0]
      + i_dim[0] * stride_r[0][0]
      + i_dim[1] * stride_r[0][1]
      + i_dim[2] * stride_r[0][2]
      + seg_off;

    dst_byte_addr =
        base_addr_r[1]
      + i_dim[0] * stride_r[1][0]
      + i_dim[1] * stride_r[1][1]
      + i_dim[2] * stride_r[1][2]
      + seg_off;
  end

  // ------------------------------------------------------------
  // Transfer sizing (stay within both current beats)
  // ------------------------------------------------------------
  logic [BUS_LG2-1:0] src_off_b, dst_off_b;
  int unsigned src_room, dst_room;
  int unsigned xfer_b;     // bytes to move this step (0..BUS_BYTES)

  always_comb begin
    src_off_b = byte_off(src_byte_addr);
    dst_off_b = byte_off(dst_byte_addr);

    src_room  = BUS_BYTES - src_off_b;
    dst_room  = BUS_BYTES - dst_off_b;

    xfer_b = seg_rem;
    if (xfer_b > src_room) xfer_b = src_room;
    if (xfer_b > dst_room) xfer_b = dst_room;

    if (xfer_b > BUS_BYTES) xfer_b = BUS_BYTES; // safety
  end

  // ------------------------------------------------------------
  // Data path
  // ------------------------------------------------------------
  logic [BUS_BITS-1:0]  rd_buf;
  logic [BUS_BITS-1:0]  wr_data;
  logic [BUS_BYTES-1:0] wr_byteen;

  always_comb begin
    wr_data   = '0;
    wr_byteen = '0;

    // enable only the bytes we touch at destination beat
    for (int b = 0; b < BUS_BYTES; b++) begin
      if ((b >= dst_off_b) && (b < (dst_off_b + xfer_b)))
        wr_byteen[b] = 1'b1;
    end

    // move xfer_b bytes from rd_buf[src_off] -> wr_data[dst_off]
    for (int k = 0; k < BUS_BYTES; k++) begin
      if (k < xfer_b) begin
        wr_data[(dst_off_b + k)*8 +: 8] = rd_buf[(src_off_b + k)*8 +: 8];
      end
    end
  end

  // ------------------------------------------------------------
  // Handshake events
  // ------------------------------------------------------------
  wire rd_rsp_fire =
      (state == S_RD_WAIT) && (
        (DIR && gemm_bus_if.rsp_valid) ||
        (!DIR && lmem_bus_if.rsp_valid)
      );

  // write commit:
  // - DIR=1 (write to LMEM): commit on req handshake in S_WR_REQ
  // - DIR=0 (write to GEMM): commit on rsp_valid in S_WR_WAIT
  wire lmem_wr_commit =
      (DIR && (state == S_WR_REQ) && lmem_bus_if.req_valid && lmem_bus_if.req_ready);

  wire gemm_wr_commit =
      (!DIR && (state == S_WR_WAIT) && gemm_bus_if.rsp_valid);

  wire wr_commit = lmem_wr_commit || gemm_wr_commit;

  wire last_done_after_write = (seg_rem <= xfer_b) && at_last_idx;

  // ------------------------------------------------------------
  // Bus defaults + FSM
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
        if (cmd_start) state_n = S_RD_REQ;
      end

      S_RD_REQ: begin
        if (DIR) begin  // GEMM -> LMEM : read from GEMM
          gemm_bus_if.req_valid         = 1'b1;
          gemm_bus_if.req_data.rw       = 1'b0;
          gemm_bus_if.req_data.addr     = to_bus_addr(src_byte_addr);
          gemm_bus_if.req_data.byteen   = '0;
          gemm_bus_if.req_data.data     = '0;
          gemm_bus_if.req_data.flags    = '0;
          gemm_bus_if.req_data.tag.uuid = '0;
          gemm_bus_if.req_data.tag.value= '0;
          if (gemm_bus_if.req_ready) state_n = S_RD_WAIT;
        end else begin   // LMEM -> GEMM : read from LMEM
          lmem_bus_if.req_valid         = 1'b1;
          lmem_bus_if.req_data.rw       = 1'b0;
          lmem_bus_if.req_data.addr     = to_bus_addr(src_byte_addr);
          lmem_bus_if.req_data.byteen   = '0;
          lmem_bus_if.req_data.data     = '0;
          lmem_bus_if.req_data.flags    = '0;
          lmem_bus_if.req_data.tag.uuid = '0;
          lmem_bus_if.req_data.tag.value= '0;
          if (lmem_bus_if.req_ready) state_n = S_RD_WAIT;
        end
      end

      S_RD_WAIT: begin
        if (rd_rsp_fire) state_n = S_WR_REQ;
      end

      S_WR_REQ: begin
        if (!DIR) begin  // LMEM -> GEMM : write to GEMM (needs rsp)
          gemm_bus_if.req_valid         = 1'b1;
          gemm_bus_if.req_data.rw       = 1'b1;
          gemm_bus_if.req_data.addr     = to_bus_addr(dst_byte_addr);
          gemm_bus_if.req_data.data     = wr_data;
          gemm_bus_if.req_data.byteen   = wr_byteen;
          gemm_bus_if.req_data.flags    = '0;
          gemm_bus_if.req_data.tag.uuid = '0;
          gemm_bus_if.req_data.tag.value= '0;
          if (gemm_bus_if.req_ready) state_n = S_WR_WAIT;
        end else begin   // GEMM -> LMEM : write to LMEM (no rsp) => commit on handshake
          lmem_bus_if.req_valid         = 1'b1;
          lmem_bus_if.req_data.rw       = 1'b1;
          lmem_bus_if.req_data.addr     = to_bus_addr(dst_byte_addr);
          lmem_bus_if.req_data.data     = wr_data;
          lmem_bus_if.req_data.byteen   = wr_byteen;
          lmem_bus_if.req_data.flags    = '0;
          lmem_bus_if.req_data.tag.uuid = '0;
          lmem_bus_if.req_data.tag.value= '0;

          if (lmem_bus_if.req_ready) begin
            state_n = last_done_after_write ? S_SYNC : S_RD_REQ;
          end
        end
      end

      S_WR_WAIT: begin
        // only for DIR=0 (write to GEMM)
        if (gemm_bus_if.rsp_valid) begin
          state_n = last_done_after_write ? S_SYNC : S_RD_REQ;
        end
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
  // Sequential: state/counters/data capture
  // ------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (reset) begin
      state   <= S_IDLE;
      for (int d=0; d<NDIM; d++) i_dim[d] <= '0;
      seg_off <= '0;
      seg_rem <= '0;
      rd_buf  <= '0;
    end else begin
      state <= state_n;

      // initialize on start (FIX: use ctrl_if.seg_size directly, not seg_size_r)
      if (cmd_start) begin
        for (int d=0; d<NDIM; d++) i_dim[d] <= '0;
        seg_off <= 32'd0;
        seg_rem <= ctrl_if.seg_size;
        rd_buf  <= '0;
      end

      // capture read data
      if (state == S_RD_WAIT) begin
        if (DIR && gemm_bus_if.rsp_valid) begin
          rd_buf <= gemm_bus_if.rsp_data.data;
        end else if (!DIR && lmem_bus_if.rsp_valid) begin
          rd_buf <= lmem_bus_if.rsp_data.data;
        end
      end

      // advance after write commit
      if (wr_commit && !last_done_after_write) begin
        if (seg_rem > xfer_b) begin
          seg_rem <= seg_rem - xfer_b;
          seg_off <= seg_off + xfer_b;
        end else begin
          // segment finished
          seg_rem <= seg_size_r;
          seg_off <= 32'd0;

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
