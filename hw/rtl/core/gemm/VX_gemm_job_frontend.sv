`include "VX_define.vh"

module VX_gemm_job_frontend import VX_gpu_pkg::*; #(
  parameter `STRING INSTANCE_ID = "",
  parameter int NUM_MASTERS  = 1,
  parameter logic [63:0] CFG_BASE_ADDR = 64'h0
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

  // MMIO layout
  //   [CFG_BASE_ADDR + 0] : ALLOC read doorbell
  //   [CFG_BASE_ADDR + 8] : command stream start (fixed)
  //   each 64-bit write from this address is a raw instruction word
  localparam logic [63:0] STREAM_START_OFF_B = 64'd8;

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

  logic rsp_valid_q, rsp_valid_d;
  logic [`NUM_LSU_LANES-1:0] rsp_mask_q, rsp_mask_d;
  logic [`NUM_LSU_LANES-1:0][LSU_WORD_SIZE*8-1:0] rsp_data_q, rsp_data_d;
  logic [MMIO_ARB_TAG_WIDTH-1:0] rsp_tag_q, rsp_tag_d;

  logic [63:0] byte_addr;
  logic [63:0] off;
  logic        req_is_alloc;
  logic        req_is_stream;
  logic        req_is_read;
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

  always_comb begin
    occupied_d      = occupied_q;
    rsp_valid_d     = rsp_valid_q;
    rsp_mask_d      = rsp_mask_q;
    rsp_data_d      = rsp_data_q;
    rsp_tag_d       = rsp_tag_q;

    byte_addr    = '0;
    off          = 64'hFFFF_FFFF_FFFF_FFFF;
    req_is_alloc  = 1'b0;
    req_is_stream = 1'b0;
    req_is_read   = 1'b0;

    rsp_holding = rsp_valid_q && ~mmio_arb_out[0].rsp_ready;
    done_fire   = done_if.valid && done_if.ready;

    issue_if.inst  = '0;
    issue_if.valid = 1'b0;
    done_if.ready  = 1'b1;
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
      byte_addr    = addr_to_byte(mmio_arb_out[0].req_data.addr[0]);
      off          = get_off(byte_addr);
      req_is_alloc = (off < 64'(LSU_WORD_SIZE));
      req_is_stream = (off >= STREAM_START_OFF_B);
      req_is_read  = ~mmio_arb_out[0].req_data.rw;

      if (req_is_stream && mmio_arb_out[0].req_data.rw) begin
        mmio_arb_out[0].req_ready = ~rsp_holding
                                 && occupied_q
                                 && issue_if.ready;
      end
    end

    if (mmio_arb_out[0].req_valid && mmio_arb_out[0].req_ready) begin
      if (req_is_stream && mmio_arb_out[0].req_data.rw) begin
        issue_if.inst  = mmio_arb_out[0].req_data.data[0];
        issue_if.valid = 1'b1;
      end else if (req_is_read) begin
        rsp_valid_d = 1'b1;
        rsp_mask_d  = mmio_arb_out[0].req_data.mask;
        rsp_tag_d   = mmio_arb_out[0].req_data.tag;
        rsp_data_d  = '0;

        if (req_is_alloc) begin
          if (~occupied_q) begin
            occupied_d = 1'b1;
            rsp_data_d[0][0] = 1'b1;
          end
        end
      end
    end
  end

  always_ff @(posedge clk) begin
    if (reset) begin
      occupied_q  <= 1'b0;
      rsp_valid_q <= 1'b0;
      rsp_mask_q  <= '0;
      rsp_data_q  <= '0;
      rsp_tag_q   <= '0;
    end else begin
      occupied_q  <= occupied_d;
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
