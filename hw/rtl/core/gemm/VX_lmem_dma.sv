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
    - seg_size는 BUS_BYTES의 배수라고 가정
    - lmem_bus_if의 data width와 gemm_bus_if의 data width는 같다고 가정
    - ctrl interface에 sync를 위한 reg_idx, reg_value 신호가 있다고 가정
    - ctrl interface의 start 신호는 idle 일때 한 펄스만 주는 것으로 가정
    - idle과 done 신호는 상태를 나타내는 신호, idle 상태면 idle=1이 유지, done 상태면 done=1이 유지
    - done 상태는 1사이클만 유지되고 다시 idle 상태로 돌아감
    - bound는 loop을 도는 횟수라고 가정, src/dst가 동일한 횟수를 돌아야 하므로 bound는 3차원 하나만 존재 (src와 dst가 공유)

*/
`include "VX_define.vh"

module VX_lmem_dma import VX_gpu_pkg::*; #(
  parameter `STRING INSTANCE_ID = "",
  parameter DIR      = 0,        // 0: LMEM->GEMM (read), 1: GEMM->LMEM (write)
  parameter LMEM_DW  = 32,       // LMEM data width in bits
  parameter GEMM_DW  = 32,       // GEMM data width in bits
  parameter NDIM     = 3         // Number of dimensions for nested loop
) (
  input wire clk,
  input wire reset,

  // Control interface
  VX_lmem_dma_ctrl_if.slave ctrl_if,  
  VX_gemm_sync_if.master gemm_sync_if,

  // LMEM memory bus interface
  VX_mem_bus_if.master lmem_bus_if,
  VX_mem_bus_if.master gemm_bus_if
);

  // ------------------------------------------------------------
  // Bus sizing helpers
  // ------------------------------------------------------------
  initial begin
    if (lmem_bus_if.DATA_SIZE != gemm_bus_if.DATA_SIZE) begin
      $fatal(1,
        "%s: DATA_SIZE mismatch! lmem=%0d bytes, gemm=%0d bytes",
        INSTANCE_ID, lmem_bus_if.DATA_SIZE, gemm_bus_if.DATA_SIZE
      );
    end
  end

  localparam int BUS_BYTES = lmem_bus_if.DATA_SIZE;
  localparam int BUS_LG2   = `CLOG2(BUS_BYTES);

  function automatic logic [lmem_bus_if.ADDR_WIDTH-1:0] to_bus_addr(input logic [31:0] byte_addr);
    // VX_mem_bus_if.addr is beat address (byte_addr / BUS_BYTES)
    to_bus_addr = byte_addr[31:BUS_LG2];
  endfunction

  // ------------------------------------------------------------
  // FSM
  // ------------------------------------------------------------

  typedef enum logic [2:0] {
    S_IDLE,
    S_RD_REQ,
    S_RD_WAIT,
    S_WR_REQ,
    S_WR_WAIT,
    S_SYNC,
    S_DONE
  } state_e;

  state_e state, state_n;

  // unpacked parameters
  logic [31:0] base_addr_r[2];  //src, dst
  logic [31:0] stride_r[2][NDIM];  //src, dst
  logic [31:0] bound_r[NDIM];
  logic [31:0] seg_size_r;
  logic [31:0] reg_idx_r;
  logic [31:0] reg_value_r;

  logic cmd_start;
  assign cmd_start = ctrl_if.start && (state == S_IDLE);

  // latch incoming regs on accept
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
      seg_size_r <= ctrl_if.seg_size;

      reg_idx_r  <= ctrl_if.reg_idx;
      reg_value_r  <= ctrl_if.reg_value;
    end
  end

  always_comb begin
    ctrl_if.idle = (state == S_IDLE);
    ctrl_if.done = (state == S_DONE);
  end

  // ------------------------------------------------------------
  // 3D loop counters + segment beat offset
  // ------------------------------------------------------------

  logic [31:0] i_dim[NDIM];   // i0,i1,i2
  logic [31:0] seg_rem;       // remaining bytes in current segment

  logic [BUS_BYTES*8-1:0] rd_buf;
  logic [31:0] beat_off;

  logic at_last_idx;
  always_comb begin
    at_last_idx = 1'b1;
    for (int d=0; d<NDIM; d++) begin
      if (i_dim[d] != (bound_r[d] - 32'd1))
        at_last_idx = 1'b0;
    end
  end
  wire last_done_after_write = (seg_rem <= BUS_BYTES) && at_last_idx;
  
  wire wr_ack_fire = (state == S_WR_WAIT) &&
                     ((DIR && lmem_bus_if.rsp_valid) ||
                      (!DIR && gemm_bus_if.rsp_valid));
  assign ctrl_if.write_done = wr_ack_fire && last_done_after_write;

  // src/dst addr generation (byte address)
  logic [31:0] src_byte_addr, dst_byte_addr;
  always_comb begin
    src_byte_addr =
        base_addr_r[0]
      + i_dim[0] * stride_r[0][0]
      + i_dim[1] * stride_r[0][1]
      + i_dim[2] * stride_r[0][2]
      + beat_off;

    dst_byte_addr =
        base_addr_r[1]
      + i_dim[0] * stride_r[1][0]
      + i_dim[1] * stride_r[1][1]
      + i_dim[2] * stride_r[1][2]
      + beat_off;
  end

  // ------------------------------------------------------------
  // Bus defaults + request generation
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
        if (cmd_start) begin
          state_n = S_RD_REQ;
        end
      end

      S_RD_REQ: begin
        if (DIR) begin  // GEMM->LMEM
          gemm_bus_if.req_valid       = 1'b1;
          gemm_bus_if.req_data.rw     = 1'b0; // READ
          gemm_bus_if.req_data.addr   = to_bus_addr(src_byte_addr);
          gemm_bus_if.req_data.data   = '0;
          gemm_bus_if.req_data.byteen = '0;
          gemm_bus_if.req_data.flags  = '0;
          gemm_bus_if.req_data.tag.uuid = '0;
          gemm_bus_if.req_data.tag.value = '0;
          if (gemm_bus_if.req_ready) state_n = S_RD_WAIT;
        end else begin  // LMEM->GEMM
          lmem_bus_if.req_valid         = 1'b1;
          lmem_bus_if.req_data.rw       = 1'b0; // READ
          lmem_bus_if.req_data.addr     = to_bus_addr(src_byte_addr);
          lmem_bus_if.req_data.data     = '0;
          lmem_bus_if.req_data.byteen   = '0;
          lmem_bus_if.req_data.flags    = '0;
          lmem_bus_if.req_data.tag.uuid = '0;
          lmem_bus_if.req_data.tag.value = '0;
          if (lmem_bus_if.req_ready) state_n = S_RD_WAIT;
        end
      end

      S_RD_WAIT: begin
        if (DIR) begin  // GEMM->LMEM
          if (gemm_bus_if.rsp_valid) state_n = S_WR_REQ;
        end else begin  // LMEM->GEMM
          if (lmem_bus_if.rsp_valid)   state_n = S_WR_REQ;
        end
      end

      S_WR_REQ: begin
        if (!DIR) begin  // LMEM->GEMM
          gemm_bus_if.req_valid       = 1'b1;
          gemm_bus_if.req_data.rw     = 1'b1; // WRITE
          gemm_bus_if.req_data.addr   = to_bus_addr(dst_byte_addr);
          gemm_bus_if.req_data.data   = rd_buf;
          gemm_bus_if.req_data.byteen = '1;
          gemm_bus_if.req_data.flags  = '0;
          gemm_bus_if.req_data.tag.uuid = '0;
          gemm_bus_if.req_data.tag.value = '0;
          if (gemm_bus_if.req_ready) state_n = S_WR_WAIT;
        end else begin  // GEMM->LMEM
          lmem_bus_if.req_valid         = 1'b1;
          lmem_bus_if.req_data.rw       = 1'b1; // WRITE
          lmem_bus_if.req_data.addr     = to_bus_addr(dst_byte_addr);
          lmem_bus_if.req_data.data     = rd_buf;
          lmem_bus_if.req_data.byteen   = '1;
          lmem_bus_if.req_data.flags    = '0;
          lmem_bus_if.req_data.tag.uuid = '0;
          lmem_bus_if.req_data.tag.value = '0;
          if (lmem_bus_if.req_ready) state_n = S_WR_WAIT;
        end
      end

      S_WR_WAIT: begin
        if (wr_ack_fire) begin
          state_n = last_done_after_write ? S_SYNC : S_RD_REQ;
        end
      end

      S_SYNC: begin
        gemm_sync_if.valid = 1'b1;
        if (gemm_sync_if.ready) state_n = S_DONE;
      end

      S_DONE: begin  //SYNC 완료 후
        // one-cycle done state, then idle
        state_n = S_IDLE;
      end

      default: state_n = S_IDLE;
    endcase
  end

  // ------------------------------------------------------------
  // Sequential state + counters + data capture
  // ------------------------------------------------------------

  always_ff @(posedge clk) begin
    if (reset) begin
      state <= S_IDLE;

      for (int d = 0; d < NDIM; d++) begin
        i_dim[d] <= '0;
      end

      seg_rem  <= '0;
      rd_buf   <= '0;
      beat_off <= '0;
    end else begin
      state <= state_n;

      // On start: init loop counters
      if (cmd_start) begin
        for (int d = 0; d < NDIM; d++) begin
          i_dim[d] <= '0;
        end
        seg_rem  <= ctrl_if.seg_size; // bytes remaining in this segment
        beat_off <= 32'd0;
      end

      // Capture read data
      if (state == S_RD_WAIT) begin
        if (DIR && gemm_bus_if.rsp_valid) begin  // GEMM->LMEM
          rd_buf <= gemm_bus_if.rsp_data.data;
        end else if (!DIR && lmem_bus_if.rsp_valid) begin  // LMEM->GEMM
          rd_buf <= lmem_bus_if.rsp_data.data;
        end
      end

      // Advance after write ack
      if (wr_ack_fire && !last_done_after_write) begin
        if (seg_rem > BUS_BYTES) begin
          // next beat in same segment
          seg_rem  <= seg_rem  - BUS_BYTES;
          beat_off <= beat_off + BUS_BYTES;
        end else begin
          // segment finished, reset beat/seg
          seg_rem  <= seg_size_r;
          beat_off <= 32'd0;

          // advance 3D indices with carry
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
                // all dimensions done
                i_dim[2] <= 32'd0;
              end
            end
          end
        end
      end
    end
  end

endmodule
