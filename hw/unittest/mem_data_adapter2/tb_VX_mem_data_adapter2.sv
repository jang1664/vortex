`timescale 1ns / 1ps
`include "VX_define.vh"

module tb_VX_mem_data_adapter2;

  localparam int PERIOD         = 10;
  localparam int TIMEOUT_CYCLES = 200;

  logic clk;
  logic reset;

  int error_count;

  initial begin
    clk = 1'b0;
    forever #(PERIOD/2) clk = ~clk;
  end

  initial begin
    reset = 1'b1;
    repeat (5) @(posedge clk);
    reset = 1'b0;
  end

  // ==========================================================================
  // Case A: DST wider than SRC
  // ==========================================================================

  localparam int W_SRC_DW    = 32;
  localparam int W_SRC_AW    = 10;
  localparam int W_SRC_TAG_W = 6;

  localparam int W_DST_DW    = 128;
  localparam int W_DST_AW    = 8;
  localparam int W_DST_TAG_W = 8;

  localparam int W_P = (W_DST_DW / W_SRC_DW);
  localparam int W_D = $clog2(W_P);

  logic                     w_mem_req_valid_in;
  logic [W_SRC_AW-1:0]      w_mem_req_addr_in;
  logic                     w_mem_req_rw_in;
  logic [W_SRC_DW/8-1:0]    w_mem_req_byteen_in;
  logic [W_SRC_DW-1:0]      w_mem_req_data_in;
  logic [W_SRC_TAG_W-1:0]   w_mem_req_tag_in;
  wire                      w_mem_req_ready_in;

  wire                      w_mem_rsp_valid_in;
  wire [W_SRC_DW-1:0]       w_mem_rsp_data_in;
  wire [W_SRC_TAG_W-1:0]    w_mem_rsp_tag_in;
  logic                     w_mem_rsp_ready_in;

  wire                      w_mem_req_valid_out;
  wire [W_DST_AW-1:0]       w_mem_req_addr_out;
  wire                      w_mem_req_rw_out;
  wire [W_DST_DW/8-1:0]     w_mem_req_byteen_out;
  wire [W_DST_DW-1:0]       w_mem_req_data_out;
  wire [W_DST_TAG_W-1:0]    w_mem_req_tag_out;
  logic                     w_mem_req_ready_out;

  logic                     w_mem_rsp_valid_out;
  logic [W_DST_DW-1:0]      w_mem_rsp_data_out;
  logic [W_DST_TAG_W-1:0]   w_mem_rsp_tag_out;
  wire                      w_mem_rsp_ready_out;

  VX_mem_data_adapter2 #(
    .SRC_DATA_WIDTH (W_SRC_DW),
    .SRC_ADDR_WIDTH (W_SRC_AW),
    .DST_DATA_WIDTH (W_DST_DW),
    .DST_ADDR_WIDTH (W_DST_AW),
    .SRC_TAG_WIDTH  (W_SRC_TAG_W),
    .DST_TAG_WIDTH  (W_DST_TAG_W),
    .OOO_SLOTS      (2),
    .REQ_OUT_BUF    (0),
    .RSP_OUT_BUF    (0)
  ) dut_wider_dst (
    .clk               (clk),
    .reset             (reset),
    .mem_req_valid_in  (w_mem_req_valid_in),
    .mem_req_addr_in   (w_mem_req_addr_in),
    .mem_req_rw_in     (w_mem_req_rw_in),
    .mem_req_byteen_in (w_mem_req_byteen_in),
    .mem_req_data_in   (w_mem_req_data_in),
    .mem_req_tag_in    (w_mem_req_tag_in),
    .mem_req_ready_in  (w_mem_req_ready_in),
    .mem_rsp_valid_in  (w_mem_rsp_valid_in),
    .mem_rsp_data_in   (w_mem_rsp_data_in),
    .mem_rsp_tag_in    (w_mem_rsp_tag_in),
    .mem_rsp_ready_in  (w_mem_rsp_ready_in),
    .mem_req_valid_out (w_mem_req_valid_out),
    .mem_req_addr_out  (w_mem_req_addr_out),
    .mem_req_rw_out    (w_mem_req_rw_out),
    .mem_req_byteen_out(w_mem_req_byteen_out),
    .mem_req_data_out  (w_mem_req_data_out),
    .mem_req_tag_out   (w_mem_req_tag_out),
    .mem_req_ready_out (w_mem_req_ready_out),
    .mem_rsp_valid_out (w_mem_rsp_valid_out),
    .mem_rsp_data_out  (w_mem_rsp_data_out),
    .mem_rsp_tag_out   (w_mem_rsp_tag_out),
    .mem_rsp_ready_out (w_mem_rsp_ready_out)
  );

  // ==========================================================================
  // Case B: SRC wider than DST (split + OOO merge)
  // ==========================================================================

  localparam int N_SRC_DW    = 128;
  localparam int N_SRC_AW    = 8;
  localparam int N_SRC_TAG_W = 6;

  localparam int N_DST_DW    = 32;
  localparam int N_DST_AW    = 10;
  localparam int N_DST_TAG_W = 4;

  localparam int N_OOO_SLOTS = 2;
  localparam int N_P         = (N_SRC_DW / N_DST_DW);
  localparam int N_D         = $clog2(N_P);

  logic                     n_mem_req_valid_in;
  logic [N_SRC_AW-1:0]      n_mem_req_addr_in;
  logic                     n_mem_req_rw_in;
  logic [N_SRC_DW/8-1:0]    n_mem_req_byteen_in;
  logic [N_SRC_DW-1:0]      n_mem_req_data_in;
  logic [N_SRC_TAG_W-1:0]   n_mem_req_tag_in;
  wire                      n_mem_req_ready_in;

  wire                      n_mem_rsp_valid_in;
  wire [N_SRC_DW-1:0]       n_mem_rsp_data_in;
  wire [N_SRC_TAG_W-1:0]    n_mem_rsp_tag_in;
  logic                     n_mem_rsp_ready_in;

  wire                      n_mem_req_valid_out;
  wire [N_DST_AW-1:0]       n_mem_req_addr_out;
  wire                      n_mem_req_rw_out;
  wire [N_DST_DW/8-1:0]     n_mem_req_byteen_out;
  wire [N_DST_DW-1:0]       n_mem_req_data_out;
  wire [N_DST_TAG_W-1:0]    n_mem_req_tag_out;
  logic                     n_mem_req_ready_out;

  logic                     n_mem_rsp_valid_out;
  logic [N_DST_DW-1:0]      n_mem_rsp_data_out;
  logic [N_DST_TAG_W-1:0]   n_mem_rsp_tag_out;
  wire                      n_mem_rsp_ready_out;

  VX_mem_data_adapter2 #(
    .SRC_DATA_WIDTH (N_SRC_DW),
    .SRC_ADDR_WIDTH (N_SRC_AW),
    .DST_DATA_WIDTH (N_DST_DW),
    .DST_ADDR_WIDTH (N_DST_AW),
    .SRC_TAG_WIDTH  (N_SRC_TAG_W),
    .DST_TAG_WIDTH  (N_DST_TAG_W),
    .OOO_SLOTS      (N_OOO_SLOTS),
    .REQ_OUT_BUF    (0),
    .RSP_OUT_BUF    (0)
  ) dut_wider_src (
    .clk               (clk),
    .reset             (reset),
    .mem_req_valid_in  (n_mem_req_valid_in),
    .mem_req_addr_in   (n_mem_req_addr_in),
    .mem_req_rw_in     (n_mem_req_rw_in),
    .mem_req_byteen_in (n_mem_req_byteen_in),
    .mem_req_data_in   (n_mem_req_data_in),
    .mem_req_tag_in    (n_mem_req_tag_in),
    .mem_req_ready_in  (n_mem_req_ready_in),
    .mem_rsp_valid_in  (n_mem_rsp_valid_in),
    .mem_rsp_data_in   (n_mem_rsp_data_in),
    .mem_rsp_tag_in    (n_mem_rsp_tag_in),
    .mem_rsp_ready_in  (n_mem_rsp_ready_in),
    .mem_req_valid_out (n_mem_req_valid_out),
    .mem_req_addr_out  (n_mem_req_addr_out),
    .mem_req_rw_out    (n_mem_req_rw_out),
    .mem_req_byteen_out(n_mem_req_byteen_out),
    .mem_req_data_out  (n_mem_req_data_out),
    .mem_req_tag_out   (n_mem_req_tag_out),
    .mem_req_ready_out (n_mem_req_ready_out),
    .mem_rsp_valid_out (n_mem_rsp_valid_out),
    .mem_rsp_data_out  (n_mem_rsp_data_out),
    .mem_rsp_tag_out   (n_mem_rsp_tag_out),
    .mem_rsp_ready_out (n_mem_rsp_ready_out)
  );

  // ==========================================================================
  // Case C: same width (passthrough)
  // ==========================================================================

  localparam int P_SRC_DW    = 64;
  localparam int P_SRC_AW    = 9;
  localparam int P_SRC_TAG_W = 5;

  localparam int P_DST_DW    = 64;
  localparam int P_DST_AW    = 9;
  localparam int P_DST_TAG_W = 5;

  logic                     p_mem_req_valid_in;
  logic [P_SRC_AW-1:0]      p_mem_req_addr_in;
  logic                     p_mem_req_rw_in;
  logic [P_SRC_DW/8-1:0]    p_mem_req_byteen_in;
  logic [P_SRC_DW-1:0]      p_mem_req_data_in;
  logic [P_SRC_TAG_W-1:0]   p_mem_req_tag_in;
  wire                      p_mem_req_ready_in;

  wire                      p_mem_rsp_valid_in;
  wire [P_SRC_DW-1:0]       p_mem_rsp_data_in;
  wire [P_SRC_TAG_W-1:0]    p_mem_rsp_tag_in;
  logic                     p_mem_rsp_ready_in;

  wire                      p_mem_req_valid_out;
  wire [P_DST_AW-1:0]       p_mem_req_addr_out;
  wire                      p_mem_req_rw_out;
  wire [P_DST_DW/8-1:0]     p_mem_req_byteen_out;
  wire [P_DST_DW-1:0]       p_mem_req_data_out;
  wire [P_DST_TAG_W-1:0]    p_mem_req_tag_out;
  logic                     p_mem_req_ready_out;

  logic                     p_mem_rsp_valid_out;
  logic [P_DST_DW-1:0]      p_mem_rsp_data_out;
  logic [P_DST_TAG_W-1:0]   p_mem_rsp_tag_out;
  wire                      p_mem_rsp_ready_out;

  VX_mem_data_adapter2 #(
    .SRC_DATA_WIDTH (P_SRC_DW),
    .SRC_ADDR_WIDTH (P_SRC_AW),
    .DST_DATA_WIDTH (P_DST_DW),
    .DST_ADDR_WIDTH (P_DST_AW),
    .SRC_TAG_WIDTH  (P_SRC_TAG_W),
    .DST_TAG_WIDTH  (P_DST_TAG_W),
    .OOO_SLOTS      (2),
    .REQ_OUT_BUF    (0),
    .RSP_OUT_BUF    (0)
  ) dut_passthru (
    .clk               (clk),
    .reset             (reset),
    .mem_req_valid_in  (p_mem_req_valid_in),
    .mem_req_addr_in   (p_mem_req_addr_in),
    .mem_req_rw_in     (p_mem_req_rw_in),
    .mem_req_byteen_in (p_mem_req_byteen_in),
    .mem_req_data_in   (p_mem_req_data_in),
    .mem_req_tag_in    (p_mem_req_tag_in),
    .mem_req_ready_in  (p_mem_req_ready_in),
    .mem_rsp_valid_in  (p_mem_rsp_valid_in),
    .mem_rsp_data_in   (p_mem_rsp_data_in),
    .mem_rsp_tag_in    (p_mem_rsp_tag_in),
    .mem_rsp_ready_in  (p_mem_rsp_ready_in),
    .mem_req_valid_out (p_mem_req_valid_out),
    .mem_req_addr_out  (p_mem_req_addr_out),
    .mem_req_rw_out    (p_mem_req_rw_out),
    .mem_req_byteen_out(p_mem_req_byteen_out),
    .mem_req_data_out  (p_mem_req_data_out),
    .mem_req_tag_out   (p_mem_req_tag_out),
    .mem_req_ready_out (p_mem_req_ready_out),
    .mem_rsp_valid_out (p_mem_rsp_valid_out),
    .mem_rsp_data_out  (p_mem_rsp_data_out),
    .mem_rsp_tag_out   (p_mem_rsp_tag_out),
    .mem_rsp_ready_out (p_mem_rsp_ready_out)
  );

  // ==========================================================================
  // Stimulus helpers
  // ==========================================================================

  task automatic w_send_req_capture(
    input  logic [W_SRC_AW-1:0]    addr,
    input  logic                   rw,
    input  logic [W_SRC_DW/8-1:0]  byteen,
    input  logic [W_SRC_DW-1:0]    data,
    input  logic [W_SRC_TAG_W-1:0] tag,
    output logic [W_DST_AW-1:0]    out_addr,
    output logic                   out_rw,
    output logic [W_DST_DW/8-1:0]  out_byteen,
    output logic [W_DST_DW-1:0]    out_data,
    output logic [W_DST_TAG_W-1:0] out_tag
  );
    bit in_done;
    bit out_done;
    int t;
  begin
    in_done  = 1'b0;
    out_done = 1'b0;
    out_addr = '0;
    out_rw = '0;
    out_byteen = '0;
    out_data = '0;
    out_tag = '0;

    @(negedge clk);
    w_mem_req_addr_in   = addr;
    w_mem_req_rw_in     = rw;
    w_mem_req_byteen_in = byteen;
    w_mem_req_data_in   = data;
    w_mem_req_tag_in    = tag;
    w_mem_req_valid_in  = 1'b1;

    for (t = 0; t < TIMEOUT_CYCLES; ++t) begin
      @(posedge clk);
      if (!out_done && w_mem_req_valid_out && w_mem_req_ready_out) begin
        out_addr = w_mem_req_addr_out;
        out_rw = w_mem_req_rw_out;
        out_byteen = w_mem_req_byteen_out;
        out_data = w_mem_req_data_out;
        out_tag = w_mem_req_tag_out;
        out_done = 1'b1;
      end
      if (!in_done && w_mem_req_valid_in && w_mem_req_ready_in) begin
        in_done = 1'b1;
      end
      if (in_done && out_done)
        break;
    end

    if (!(in_done && out_done)) begin
      $error("w_send_req_capture timeout");
      error_count++;
    end

    @(negedge clk);
    w_mem_req_valid_in = 1'b0;
  end
  endtask

  task automatic w_send_rsp_expect(
    input logic [W_DST_DW-1:0]    rsp_data,
    input logic [W_DST_TAG_W-1:0] rsp_tag,
    input logic [W_SRC_DW-1:0]    exp_data,
    input logic [W_SRC_TAG_W-1:0] exp_tag
  );
    bit dst_done;
    bit src_done;
    int t;
  begin
    dst_done = 1'b0;
    src_done = 1'b0;

    @(negedge clk);
    w_mem_rsp_data_out  = rsp_data;
    w_mem_rsp_tag_out   = rsp_tag;
    w_mem_rsp_valid_out = 1'b1;

    for (t = 0; t < TIMEOUT_CYCLES; ++t) begin
      @(posedge clk);
      if (!dst_done && w_mem_rsp_valid_out && w_mem_rsp_ready_out)
        dst_done = 1'b1;

      if (!src_done && w_mem_rsp_valid_in && w_mem_rsp_ready_in) begin
        if (w_mem_rsp_data_in !== exp_data) begin
          $error("w_rsp_data mismatch: got=0x%0h exp=0x%0h", w_mem_rsp_data_in, exp_data);
          error_count++;
        end
        if (w_mem_rsp_tag_in !== exp_tag) begin
          $error("w_rsp_tag mismatch: got=0x%0h exp=0x%0h", w_mem_rsp_tag_in, exp_tag);
          error_count++;
        end
        src_done = 1'b1;
      end

      if (dst_done && src_done)
        break;
    end

    if (!(dst_done && src_done)) begin
      $error("w_send_rsp_expect timeout");
      error_count++;
    end

    @(negedge clk);
    w_mem_rsp_valid_out = 1'b0;
  end
  endtask

  task automatic n_send_parent_req_capture(
    input  logic [N_SRC_AW-1:0]      addr,
    input  logic                     rw,
    input  logic [N_SRC_DW/8-1:0]    byteen,
    input  logic [N_SRC_DW-1:0]      data,
    input  logic [N_SRC_TAG_W-1:0]   tag,
    output logic [N_P-1:0][N_DST_AW-1:0]   out_addr,
    output logic [N_P-1:0][N_DST_DW/8-1:0] out_byteen,
    output logic [N_P-1:0][N_DST_DW-1:0]   out_data,
    output logic [N_P-1:0][N_DST_TAG_W-1:0] out_tag,
    output logic [N_P-1:0]           out_rw,
    output int                       ready_low_cycles
  );
    bit in_done;
    int seen;
    int t;
  begin
    in_done = 1'b0;
    seen = 0;
    ready_low_cycles = 0;
    out_addr = '0;
    out_byteen = '0;
    out_data = '0;
    out_tag = '0;
    out_rw = '0;

    @(negedge clk);
    n_mem_req_addr_in   = addr;
    n_mem_req_rw_in     = rw;
    n_mem_req_byteen_in = byteen;
    n_mem_req_data_in   = data;
    n_mem_req_tag_in    = tag;
    n_mem_req_valid_in  = 1'b1;

    for (t = 0; t < TIMEOUT_CYCLES; ++t) begin
      @(posedge clk);

      if (n_mem_req_valid_in && !n_mem_req_ready_in)
        ready_low_cycles++;

      if (n_mem_req_valid_out && n_mem_req_ready_out) begin
        if (seen < N_P) begin
          out_addr[seen]   = n_mem_req_addr_out;
          out_byteen[seen] = n_mem_req_byteen_out;
          out_data[seen]   = n_mem_req_data_out;
          out_tag[seen]    = n_mem_req_tag_out;
          out_rw[seen]     = n_mem_req_rw_out;
        end else begin
          $error("n_send_parent_req_capture got extra split request");
          error_count++;
        end
        seen++;
      end

      if (!in_done && n_mem_req_valid_in && n_mem_req_ready_in)
        in_done = 1'b1;

      if (in_done && (seen == N_P))
        break;
    end

    if (!(in_done && (seen == N_P))) begin
      $error("n_send_parent_req_capture timeout (in_done=%0d seen=%0d)", in_done, seen);
      error_count++;
    end

    @(negedge clk);
    n_mem_req_valid_in = 1'b0;
  end
  endtask

  task automatic n_send_dst_rsp(
    input logic [N_DST_DW-1:0]    rsp_data,
    input logic [N_DST_TAG_W-1:0] rsp_tag
  );
    bit done;
    int t;
  begin
    done = 1'b0;

    @(negedge clk);
    n_mem_rsp_data_out  = rsp_data;
    n_mem_rsp_tag_out   = rsp_tag;
    n_mem_rsp_valid_out = 1'b1;

    for (t = 0; t < TIMEOUT_CYCLES; ++t) begin
      @(posedge clk);
      if (n_mem_rsp_valid_out && n_mem_rsp_ready_out) begin
        done = 1'b1;
        break;
      end
    end

    if (!done) begin
      $error("n_send_dst_rsp timeout");
      error_count++;
    end

    @(negedge clk);
    n_mem_rsp_valid_out = 1'b0;
  end
  endtask

  task automatic n_expect_src_rsp(
    input logic [N_SRC_DW-1:0]    exp_data,
    input logic [N_SRC_TAG_W-1:0] exp_tag
  );
    bit done;
    int t;
  begin
    done = 1'b0;

    for (t = 0; t < TIMEOUT_CYCLES; ++t) begin
      @(posedge clk);
      if (n_mem_rsp_valid_in && n_mem_rsp_ready_in) begin
        if (n_mem_rsp_data_in !== exp_data) begin
          $error("n_rsp_data mismatch: got=0x%0h exp=0x%0h", n_mem_rsp_data_in, exp_data);
          error_count++;
        end
        if (n_mem_rsp_tag_in !== exp_tag) begin
          $error("n_rsp_tag mismatch: got=0x%0h exp=0x%0h", n_mem_rsp_tag_in, exp_tag);
          error_count++;
        end
        done = 1'b1;
        break;
      end
    end

    if (!done) begin
      $error("n_expect_src_rsp timeout");
      error_count++;
    end
  end
  endtask

  // ==========================================================================
  // Testcases
  // ==========================================================================

  task automatic test_wider_dst;
    logic [W_SRC_AW-1:0]    req_addr;
    logic                   req_rw;
    logic [W_SRC_DW/8-1:0]  req_byteen;
    logic [W_SRC_DW-1:0]    req_data;
    logic [W_SRC_TAG_W-1:0] req_tag;

    logic [W_DST_AW-1:0]    got_addr;
    logic                   got_rw;
    logic [W_DST_DW/8-1:0]  got_byteen;
    logic [W_DST_DW-1:0]    got_data;
    logic [W_DST_TAG_W-1:0] got_tag;

    logic [W_D-1:0]         idx;
    logic [W_DST_AW-1:0]    exp_addr;
    logic [W_DST_DW/8-1:0]  exp_byteen;
    logic [W_DST_DW-1:0]    exp_data;
    logic [W_DST_TAG_W-1:0] exp_tag;

    logic [W_P-1:0][W_SRC_DW-1:0] rsp_words;
    logic [W_DST_DW-1:0]          dst_rsp_data;
    logic [W_DST_TAG_W-1:0]       dst_rsp_tag;
    logic [W_SRC_DW-1:0]          exp_rsp_data;
    logic [W_SRC_TAG_W-1:0]       exp_rsp_tag;
  begin
    $display("[TB] Case A: DST wider than SRC");

    req_addr   = 10'h1a6;          // low 2bits = 2
    req_rw     = 1'b1;
    req_byteen = 4'b1010;
    req_data   = 32'hA1B2_C3D4;
    req_tag    = 6'h2d;

    w_send_req_capture(req_addr, req_rw, req_byteen, req_data, req_tag,
                       got_addr, got_rw, got_byteen, got_data, got_tag);

    idx = req_addr[W_D-1:0];
    exp_addr = W_DST_AW'(req_addr >> W_D);
    exp_byteen = '0;
    exp_byteen[idx*(W_SRC_DW/8) +: (W_SRC_DW/8)] = req_byteen;
    exp_data = '0;
    exp_data[idx*W_SRC_DW +: W_SRC_DW] = req_data;
    exp_tag = {req_tag, idx};

    if (got_addr !== exp_addr) begin
      $error("w_req_addr mismatch: got=0x%0h exp=0x%0h", got_addr, exp_addr);
      error_count++;
    end
    if (got_rw !== req_rw) begin
      $error("w_req_rw mismatch: got=%0b exp=%0b", got_rw, req_rw);
      error_count++;
    end
    if (got_byteen !== exp_byteen) begin
      $error("w_req_byteen mismatch: got=0x%0h exp=0x%0h", got_byteen, exp_byteen);
      error_count++;
    end
    if (got_data !== exp_data) begin
      $error("w_req_data mismatch: got=0x%0h exp=0x%0h", got_data, exp_data);
      error_count++;
    end
    if (got_tag !== exp_tag) begin
      $error("w_req_tag mismatch: got=0x%0h exp=0x%0h", got_tag, exp_tag);
      error_count++;
    end

    rsp_words[0] = 32'h1111_1111;
    rsp_words[1] = 32'h2222_2222;
    rsp_words[2] = 32'h3333_3333;
    rsp_words[3] = 32'h4444_4444;
    dst_rsp_data = rsp_words;
    dst_rsp_tag  = {6'h15, 2'd2};

    exp_rsp_data = rsp_words[2];
    exp_rsp_tag  = 6'h15;

    w_send_rsp_expect(dst_rsp_data, dst_rsp_tag, exp_rsp_data, exp_rsp_tag);
  end
  endtask

  task automatic test_wider_src_ooo;
    logic [N_SRC_AW-1:0]    req1_addr, req2_addr, wr_addr;
    logic [N_SRC_DW/8-1:0]  req1_byteen, req2_byteen, wr_byteen;
    logic [N_SRC_DW-1:0]    req1_data, req2_data, wr_data;
    logic [N_SRC_TAG_W-1:0] req1_tag, req2_tag, wr_tag;

    logic [N_P-1:0][N_DST_AW-1:0]    req1_addr_f, req2_addr_f, wr_addr_f;
    logic [N_P-1:0][N_DST_DW/8-1:0]  req1_byteen_f, req2_byteen_f, wr_byteen_f;
    logic [N_P-1:0][N_DST_DW-1:0]    req1_data_f, req2_data_f, wr_data_f;
    logic [N_P-1:0][N_DST_TAG_W-1:0] req1_tag_f, req2_tag_f, wr_tag_f;
    logic [N_P-1:0]                  req1_rw_f, req2_rw_f, wr_rw_f;

    logic [N_DST_AW-1:0]            exp_addr;
    logic [N_DST_DW/8-1:0]          exp_byteen;
    logic [N_DST_DW-1:0]            exp_data;
    logic [N_DST_TAG_W-N_D-1:0]     req1_tag_hi, req2_tag_hi, wr_tag_hi;

    logic [N_P-1:0][N_DST_DW-1:0]   rsp1_frag, rsp2_frag;
    logic [N_SRC_DW-1:0]            exp_rsp1_data, exp_rsp2_data;

    int wait1, wait2, waitw;
    int i;
  begin
    $display("[TB] Case B: SRC wider than DST (split + OOO merge)");

    req1_addr   = 8'h10;
    req1_byteen = 16'hF0F0;
    req1_data   = 128'h0123_4567_89ab_cdef_0011_2233_4455_6677;
    req1_tag    = 6'h11;

    req2_addr   = 8'h22;
    req2_byteen = 16'h0FF0;
    req2_data   = 128'h8899_aabb_ccdd_eeff_dead_beef_cafe_babe;
    req2_tag    = 6'h2a;

    wr_addr     = 8'h33;
    wr_byteen   = 16'h3333;
    wr_data     = 128'h1357_9bdf_2468_ace0_1111_2222_3333_4444;
    wr_tag      = 6'h3c;

    n_send_parent_req_capture(req1_addr, 1'b0, req1_byteen, req1_data, req1_tag,
                              req1_addr_f, req1_byteen_f, req1_data_f, req1_tag_f, req1_rw_f, wait1);

    if (wait1 !== (N_P - 1)) begin
      $error("req1 ready_low_cycles mismatch: got=%0d exp=%0d", wait1, (N_P - 1));
      error_count++;
    end

    req1_tag_hi = req1_tag_f[0][N_DST_TAG_W-1:N_D];
    for (i = 0; i < N_P; ++i) begin
      exp_addr = {req1_addr, N_D'(i)};
      exp_byteen = req1_byteen[i*(N_DST_DW/8) +: (N_DST_DW/8)];
      exp_data = req1_data[i*N_DST_DW +: N_DST_DW];

      if (req1_addr_f[i] !== exp_addr) begin
        $error("req1 frag%0d addr mismatch: got=0x%0h exp=0x%0h", i, req1_addr_f[i], exp_addr);
        error_count++;
      end
      if (req1_byteen_f[i] !== exp_byteen) begin
        $error("req1 frag%0d byteen mismatch: got=0x%0h exp=0x%0h", i, req1_byteen_f[i], exp_byteen);
        error_count++;
      end
      if (req1_data_f[i] !== exp_data) begin
        $error("req1 frag%0d data mismatch: got=0x%0h exp=0x%0h", i, req1_data_f[i], exp_data);
        error_count++;
      end
      if (req1_rw_f[i] !== 1'b0) begin
        $error("req1 frag%0d rw mismatch: got=%0b exp=0", i, req1_rw_f[i]);
        error_count++;
      end
      if (req1_tag_f[i][N_D-1:0] !== N_D'(i)) begin
        $error("req1 frag%0d tag low bits mismatch: got=0x%0h exp=0x%0h", i, req1_tag_f[i][N_D-1:0], N_D'(i));
        error_count++;
      end
      if (req1_tag_f[i][N_DST_TAG_W-1:N_D] !== req1_tag_hi) begin
        $error("req1 frag%0d tag high bits mismatch", i);
        error_count++;
      end
    end

    n_send_parent_req_capture(req2_addr, 1'b0, req2_byteen, req2_data, req2_tag,
                              req2_addr_f, req2_byteen_f, req2_data_f, req2_tag_f, req2_rw_f, wait2);

    if (wait2 !== (N_P - 1)) begin
      $error("req2 ready_low_cycles mismatch: got=%0d exp=%0d", wait2, (N_P - 1));
      error_count++;
    end

    req2_tag_hi = req2_tag_f[0][N_DST_TAG_W-1:N_D];
    for (i = 0; i < N_P; ++i) begin
      exp_addr = {req2_addr, N_D'(i)};
      exp_byteen = req2_byteen[i*(N_DST_DW/8) +: (N_DST_DW/8)];
      exp_data = req2_data[i*N_DST_DW +: N_DST_DW];

      if (req2_addr_f[i] !== exp_addr) begin
        $error("req2 frag%0d addr mismatch: got=0x%0h exp=0x%0h", i, req2_addr_f[i], exp_addr);
        error_count++;
      end
      if (req2_byteen_f[i] !== exp_byteen) begin
        $error("req2 frag%0d byteen mismatch: got=0x%0h exp=0x%0h", i, req2_byteen_f[i], exp_byteen);
        error_count++;
      end
      if (req2_data_f[i] !== exp_data) begin
        $error("req2 frag%0d data mismatch: got=0x%0h exp=0x%0h", i, req2_data_f[i], exp_data);
        error_count++;
      end
      if (req2_rw_f[i] !== 1'b0) begin
        $error("req2 frag%0d rw mismatch: got=%0b exp=0", i, req2_rw_f[i]);
        error_count++;
      end
      if (req2_tag_f[i][N_D-1:0] !== N_D'(i)) begin
        $error("req2 frag%0d tag low bits mismatch", i);
        error_count++;
      end
      if (req2_tag_f[i][N_DST_TAG_W-1:N_D] !== req2_tag_hi) begin
        $error("req2 frag%0d tag high bits mismatch", i);
        error_count++;
      end
    end

    // Writes must not consume OOO slots; this should pass even with 2 read slots active.
    n_send_parent_req_capture(wr_addr, 1'b1, wr_byteen, wr_data, wr_tag,
                              wr_addr_f, wr_byteen_f, wr_data_f, wr_tag_f, wr_rw_f, waitw);

    if (waitw !== (N_P - 1)) begin
      $error("write ready_low_cycles mismatch: got=%0d exp=%0d", waitw, (N_P - 1));
      error_count++;
    end

    wr_tag_hi = wr_tag_f[0][N_DST_TAG_W-1:N_D];
    for (i = 0; i < N_P; ++i) begin
      exp_addr = {wr_addr, N_D'(i)};
      exp_byteen = wr_byteen[i*(N_DST_DW/8) +: (N_DST_DW/8)];
      exp_data = wr_data[i*N_DST_DW +: N_DST_DW];

      if (wr_addr_f[i] !== exp_addr) begin
        $error("write frag%0d addr mismatch: got=0x%0h exp=0x%0h", i, wr_addr_f[i], exp_addr);
        error_count++;
      end
      if (wr_byteen_f[i] !== exp_byteen) begin
        $error("write frag%0d byteen mismatch: got=0x%0h exp=0x%0h", i, wr_byteen_f[i], exp_byteen);
        error_count++;
      end
      if (wr_data_f[i] !== exp_data) begin
        $error("write frag%0d data mismatch: got=0x%0h exp=0x%0h", i, wr_data_f[i], exp_data);
        error_count++;
      end
      if (wr_rw_f[i] !== 1'b1) begin
        $error("write frag%0d rw mismatch: got=%0b exp=1", i, wr_rw_f[i]);
        error_count++;
      end
      if (wr_tag_f[i][N_D-1:0] !== N_D'(i)) begin
        $error("write frag%0d tag low bits mismatch", i);
        error_count++;
      end
      if (wr_tag_f[i][N_DST_TAG_W-1:N_D] !== wr_tag_hi) begin
        $error("write frag%0d tag high bits mismatch", i);
        error_count++;
      end
    end

    rsp1_frag[0] = 32'h1000_0001;
    rsp1_frag[1] = 32'h1000_0002;
    rsp1_frag[2] = 32'h1000_0003;
    rsp1_frag[3] = 32'h1000_0004;

    rsp2_frag[0] = 32'h2000_0001;
    rsp2_frag[1] = 32'h2000_0002;
    rsp2_frag[2] = 32'h2000_0003;
    rsp2_frag[3] = 32'h2000_0004;

    exp_rsp1_data = rsp1_frag;
    exp_rsp2_data = rsp2_frag;

    // Out-of-order fragment arrivals across two slots.
    n_send_dst_rsp(rsp2_frag[2], req2_tag_f[2]);
    n_send_dst_rsp(rsp1_frag[1], req1_tag_f[1]);
    n_send_dst_rsp(rsp2_frag[0], req2_tag_f[0]);
    n_send_dst_rsp(rsp2_frag[3], req2_tag_f[3]);
    n_send_dst_rsp(rsp1_frag[3], req1_tag_f[3]);
    n_send_dst_rsp(rsp2_frag[1], req2_tag_f[1]);
    n_expect_src_rsp(exp_rsp2_data, req2_tag);

    n_send_dst_rsp(rsp1_frag[0], req1_tag_f[0]);
    n_send_dst_rsp(rsp1_frag[2], req1_tag_f[2]);
    n_expect_src_rsp(exp_rsp1_data, req1_tag);

    repeat (3) begin
      @(posedge clk);
      if (n_mem_rsp_valid_in) begin
        $error("unexpected extra assembled response");
        error_count++;
      end
    end
  end
  endtask

  task automatic test_passthru;
    logic [P_SRC_AW-1:0]    req_addr;
    logic                   req_rw;
    logic [P_SRC_DW/8-1:0]  req_byteen;
    logic [P_SRC_DW-1:0]    req_data;
    logic [P_SRC_TAG_W-1:0] req_tag;

    logic [P_SRC_DW-1:0]    rsp_data;
    logic [P_SRC_TAG_W-1:0] rsp_tag;

    bit in_done;
    bit out_done;
    bit dst_rsp_done;
    bit src_rsp_done;
    int t;
  begin
    $display("[TB] Case C: same width passthrough");

    req_addr   = 9'h12;
    req_rw     = 1'b0;
    req_byteen = 8'hA5;
    req_data   = 64'h0123_4567_89ab_cdef;
    req_tag    = 5'h13;

    // Request backpressure check
    p_mem_req_ready_out = 1'b0;

    @(negedge clk);
    p_mem_req_addr_in   = req_addr;
    p_mem_req_rw_in     = req_rw;
    p_mem_req_byteen_in = req_byteen;
    p_mem_req_data_in   = req_data;
    p_mem_req_tag_in    = req_tag;
    p_mem_req_valid_in  = 1'b1;

    repeat (2) begin
      @(posedge clk);
      if (p_mem_req_ready_in !== 1'b0) begin
        $error("passthru req_ready_in expected 0 while downstream stalled");
        error_count++;
      end
      if (p_mem_req_valid_out !== 1'b1) begin
        $error("passthru req_valid_out expected 1 while request pending");
        error_count++;
      end
    end

    p_mem_req_ready_out = 1'b1;

    in_done = 1'b0;
    out_done = 1'b0;
    for (t = 0; t < TIMEOUT_CYCLES; ++t) begin
      @(posedge clk);
      if (!out_done && p_mem_req_valid_out && p_mem_req_ready_out) begin
        if (p_mem_req_addr_out !== req_addr) begin
          $error("p_req_addr mismatch: got=0x%0h exp=0x%0h", p_mem_req_addr_out, req_addr);
          error_count++;
        end
        if (p_mem_req_rw_out !== req_rw) begin
          $error("p_req_rw mismatch: got=%0b exp=%0b", p_mem_req_rw_out, req_rw);
          error_count++;
        end
        if (p_mem_req_byteen_out !== req_byteen) begin
          $error("p_req_byteen mismatch: got=0x%0h exp=0x%0h", p_mem_req_byteen_out, req_byteen);
          error_count++;
        end
        if (p_mem_req_data_out !== req_data) begin
          $error("p_req_data mismatch: got=0x%0h exp=0x%0h", p_mem_req_data_out, req_data);
          error_count++;
        end
        if (p_mem_req_tag_out !== req_tag) begin
          $error("p_req_tag mismatch: got=0x%0h exp=0x%0h", p_mem_req_tag_out, req_tag);
          error_count++;
        end
        out_done = 1'b1;
      end
      if (!in_done && p_mem_req_valid_in && p_mem_req_ready_in)
        in_done = 1'b1;

      if (in_done && out_done)
        break;
    end

    if (!(in_done && out_done)) begin
      $error("passthru request handshake timeout");
      error_count++;
    end

    @(negedge clk);
    p_mem_req_valid_in = 1'b0;

    // Response backpressure check
    rsp_data = 64'hfeed_face_dead_beef;
    rsp_tag  = 5'h0e;

    p_mem_rsp_ready_in = 1'b0;

    @(negedge clk);
    p_mem_rsp_data_out  = rsp_data;
    p_mem_rsp_tag_out   = rsp_tag;
    p_mem_rsp_valid_out = 1'b1;

    repeat (2) begin
      @(posedge clk);
      if (p_mem_rsp_ready_out !== 1'b0) begin
        $error("passthru rsp_ready_out expected 0 while upstream stalled");
        error_count++;
      end
    end

    p_mem_rsp_ready_in = 1'b1;

    dst_rsp_done = 1'b0;
    src_rsp_done = 1'b0;
    for (t = 0; t < TIMEOUT_CYCLES; ++t) begin
      @(posedge clk);

      if (!dst_rsp_done && p_mem_rsp_valid_out && p_mem_rsp_ready_out)
        dst_rsp_done = 1'b1;

      if (!src_rsp_done && p_mem_rsp_valid_in && p_mem_rsp_ready_in) begin
        if (p_mem_rsp_data_in !== rsp_data) begin
          $error("p_rsp_data mismatch: got=0x%0h exp=0x%0h", p_mem_rsp_data_in, rsp_data);
          error_count++;
        end
        if (p_mem_rsp_tag_in !== rsp_tag) begin
          $error("p_rsp_tag mismatch: got=0x%0h exp=0x%0h", p_mem_rsp_tag_in, rsp_tag);
          error_count++;
        end
        src_rsp_done = 1'b1;
      end

      if (dst_rsp_done && src_rsp_done)
        break;
    end

    if (!(dst_rsp_done && src_rsp_done)) begin
      $error("passthru response handshake timeout");
      error_count++;
    end

    @(negedge clk);
    p_mem_rsp_valid_out = 1'b0;
  end
  endtask

  // ==========================================================================
  // Main
  // ==========================================================================

  initial begin
    error_count = 0;

    w_mem_req_valid_in  = 1'b0;
    w_mem_req_addr_in   = '0;
    w_mem_req_rw_in     = 1'b0;
    w_mem_req_byteen_in = '0;
    w_mem_req_data_in   = '0;
    w_mem_req_tag_in    = '0;
    w_mem_rsp_ready_in  = 1'b1;
    w_mem_req_ready_out = 1'b1;
    w_mem_rsp_valid_out = 1'b0;
    w_mem_rsp_data_out  = '0;
    w_mem_rsp_tag_out   = '0;

    n_mem_req_valid_in  = 1'b0;
    n_mem_req_addr_in   = '0;
    n_mem_req_rw_in     = 1'b0;
    n_mem_req_byteen_in = '0;
    n_mem_req_data_in   = '0;
    n_mem_req_tag_in    = '0;
    n_mem_rsp_ready_in  = 1'b1;
    n_mem_req_ready_out = 1'b1;
    n_mem_rsp_valid_out = 1'b0;
    n_mem_rsp_data_out  = '0;
    n_mem_rsp_tag_out   = '0;

    p_mem_req_valid_in  = 1'b0;
    p_mem_req_addr_in   = '0;
    p_mem_req_rw_in     = 1'b0;
    p_mem_req_byteen_in = '0;
    p_mem_req_data_in   = '0;
    p_mem_req_tag_in    = '0;
    p_mem_rsp_ready_in  = 1'b1;
    p_mem_req_ready_out = 1'b1;
    p_mem_rsp_valid_out = 1'b0;
    p_mem_rsp_data_out  = '0;
    p_mem_rsp_tag_out   = '0;

    wait (reset == 1'b0);
    repeat (2) @(posedge clk);

    test_wider_dst();
    test_wider_src_ooo();
    test_passthru();

    repeat (5) @(posedge clk);

    if (error_count == 0) begin
      $display("[TB] PASS: tb_VX_mem_data_adapter2");
    end else begin
      $display("[TB] FAIL: tb_VX_mem_data_adapter2 errors=%0d", error_count);
      $fatal(1);
    end

    $finish;
  end

endmodule
