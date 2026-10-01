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
  parameter NDIM     = 3,        // Descriptor dimensions
  parameter BOUND_WIDTH = `DMA_BOUND_WIDTH,
  parameter MAX_DIMS = NDIM      // Implemented nested-loop dimensions
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
    if ((MAX_DIMS < 1) || (MAX_DIMS > NDIM))
      $fatal(1, "%s: MAX_DIMS(%0d) must be in 1..%0d",
             INSTANCE_ID, MAX_DIMS, NDIM);
    if (BOUND_WIDTH != ctrl_if.BOUND_WIDTH)
      $fatal(1, "%s: bound width mismatch", INSTANCE_ID);
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
  logic [31:0] stride_r[2][MAX_DIMS];  //src, dst
  logic [MAX_DIMS-1:0][BOUND_WIDTH-1:0] bound_r;
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
      for (int d=0; d<MAX_DIMS; d++) begin
        stride_r[0][d] <= '0;
        stride_r[1][d] <= '0;
        bound_r[d]     <= '0;
      end
    end else if (cmd_start) begin
      base_addr_r[0] <= ctrl_if.src_base_addr;
      base_addr_r[1] <= ctrl_if.dst_base_addr;
      for (int d=0; d<MAX_DIMS; d++) begin
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
    ctrl_if.prepare_ready = 1'b0;
  end

  // ------------------------------------------------------------
  // 3D loop counters + segment beat offset
  // ------------------------------------------------------------

  logic [MAX_DIMS-1:0][BOUND_WIDTH-1:0] i_dim;
  logic [31:0] seg_rem;       // remaining bytes in current segment

  logic [BUS_BYTES*8-1:0] rd_buf;
  logic [31:0] beat_off;

  function automatic logic [MAX_DIMS-1:0][BOUND_WIDTH-1:0]
      advance_dims(
          input logic [MAX_DIMS-1:0][BOUND_WIDTH-1:0] indices,
          input logic [MAX_DIMS-1:0][BOUND_WIDTH-1:0] bounds);
    logic carry;
    begin
      advance_dims = indices;
      carry = 1'b1;
      for (int d = 0; d < MAX_DIMS; ++d) begin
        if (carry) begin
          if ((indices[d] + BOUND_WIDTH'(1)) < bounds[d]) begin
            advance_dims[d] = indices[d] + BOUND_WIDTH'(1);
            carry = 1'b0;
          end else begin
            advance_dims[d] = '0;
          end
        end
      end
    end
  endfunction

  logic at_last_idx;
  always_comb begin
    at_last_idx = 1'b1;
    for (int d=0; d<MAX_DIMS; d++) begin
      if (i_dim[d] != (bound_r[d] - BOUND_WIDTH'(1)))
        at_last_idx = 1'b0;
    end
  end
  wire last_done_after_write = (seg_rem <= BUS_BYTES) && at_last_idx;
  
  wire wr_ack_fire = (state == S_WR_WAIT) &&
                     ((DIR && lmem_bus_if.rsp_valid) ||
                      (!DIR && gemm_bus_if.rsp_valid));
  assign ctrl_if.write_done = wr_ack_fire && last_done_after_write;

  // src/dst addr generation (byte address)
  localparam int ADDR_PRODUCT_WIDTH = BOUND_WIDTH + 32;
  wire [ADDR_PRODUCT_WIDTH-1:0] src_dim_stride[MAX_DIMS];
  wire [ADDR_PRODUCT_WIDTH-1:0] dst_dim_stride[MAX_DIMS];
  for (genvar addr_dim = 0; addr_dim < MAX_DIMS; ++addr_dim) begin : g_addr_product
    assign src_dim_stride[addr_dim] = i_dim[addr_dim] * stride_r[0][addr_dim];
    assign dst_dim_stride[addr_dim] = i_dim[addr_dim] * stride_r[1][addr_dim];
  end
  logic [31:0] src_byte_addr, dst_byte_addr;
  always_comb begin
    src_byte_addr = base_addr_r[0] + beat_off;
    dst_byte_addr = base_addr_r[1] + beat_off;
    for (int d = 0; d < MAX_DIMS; ++d) begin
      src_byte_addr += 32'(src_dim_stride[d]);
      dst_byte_addr += 32'(dst_dim_stride[d]);
    end
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

      for (int d = 0; d < MAX_DIMS; d++) begin
        i_dim[d] <= '0;
      end

      seg_rem  <= '0;
      rd_buf   <= '0;
      beat_off <= '0;
    end else begin
      state <= state_n;

      // On start: init loop counters
      if (cmd_start) begin
        for (int d = 0; d < MAX_DIMS; d++) begin
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

          i_dim <= advance_dims(i_dim, bound_r);
        end
      end
    end
  end

`ifndef SYNTHESIS
  always_ff @(posedge clk) begin
    if (!reset && cmd_start) begin
      if (MAX_DIMS == 1) begin
        assert ((ctrl_if.bounds[1] == BOUND_WIDTH'(1))
             && (ctrl_if.bounds[2] == BOUND_WIDTH'(1)))
          else $fatal(1, "%s: 1D local DMA requires BND1/BND2=1",
                      INSTANCE_ID);
      end else if (MAX_DIMS == 2) begin
        assert (ctrl_if.bounds[2] == BOUND_WIDTH'(1))
          else $fatal(1, "%s: 2D local DMA requires BND2=1", INSTANCE_ID);
      end
    end
    if (!reset && (state == S_RD_REQ)) begin
      for (int d = 0; d < MAX_DIMS; ++d) begin
        assert ((src_dim_stride[d] >> 32) == 0)
          else $fatal(1, "%s: source dimension product exceeds 32 bits",
                      INSTANCE_ID);
        assert ((dst_dim_stride[d] >> 32) == 0)
          else $fatal(1, "%s: destination dimension product exceeds 32 bits",
                      INSTANCE_ID);
      end
    end
  end
`endif

endmodule
