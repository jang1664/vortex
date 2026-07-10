`timescale 1ns/1ps
`include "VX_define.vh"

module tb_VX_hw_debug import VX_gpu_pkg::*; ();

  localparam int NUM_AXI_PORTS = 2;
  localparam int AXI_ADDR_WIDTH = 64;
  localparam int AXI_ID_WIDTH = 4;
  localparam int PENDING_WR_SIZEW = 12;
  localparam int WR_TRACK_SIZEW = 32;
  localparam time PERIOD = 10ns;

  logic clk, reset;
  logic [31:0] debug_select;
  logic debug_clear, debug_freeze;
  wire [63:0] debug_rdata;
  wire [31:0] debug_status;
  logic ap_reset, ap_start, ap_done, ap_idle, ap_ready;
  logic [1:0] ap_state;
  logic ap_done_base, ap_done_wait_cache, vx_busy, vx_cache_drain;
  logic [PENDING_WR_SIZEW-1:0] vx_pending_writes;
  logic vx_pending_writes_empty;

  logic s_axi_ctrl_awvalid, s_axi_ctrl_awready;
  logic [7:0] s_axi_ctrl_awaddr;
  logic s_axi_ctrl_wvalid, s_axi_ctrl_wready;
  logic [31:0] s_axi_ctrl_wdata;
  logic [3:0] s_axi_ctrl_wstrb;
  logic s_axi_ctrl_bvalid, s_axi_ctrl_bready;
  logic [1:0] s_axi_ctrl_bresp;
  logic s_axi_ctrl_arvalid, s_axi_ctrl_arready;
  logic [7:0] s_axi_ctrl_araddr;
  logic s_axi_ctrl_rvalid, s_axi_ctrl_rready;
  logic [31:0] s_axi_ctrl_rdata;
  logic [1:0] s_axi_ctrl_rresp;

  logic m_axi_awvalid [NUM_AXI_PORTS];
  logic m_axi_awready [NUM_AXI_PORTS];
  logic [AXI_ADDR_WIDTH-1:0] m_axi_awaddr [NUM_AXI_PORTS];
  logic [AXI_ID_WIDTH-1:0] m_axi_awid [NUM_AXI_PORTS];
  logic [7:0] m_axi_awlen [NUM_AXI_PORTS];
  logic m_axi_wvalid [NUM_AXI_PORTS];
  logic m_axi_wready [NUM_AXI_PORTS];
  logic m_axi_wlast [NUM_AXI_PORTS];
  logic m_axi_bvalid [NUM_AXI_PORTS];
  logic m_axi_bready [NUM_AXI_PORTS];
  logic [AXI_ID_WIDTH-1:0] m_axi_bid [NUM_AXI_PORTS];
  logic [1:0] m_axi_bresp [NUM_AXI_PORTS];
  logic m_axi_arvalid [NUM_AXI_PORTS];
  logic m_axi_arready [NUM_AXI_PORTS];
  logic [AXI_ADDR_WIDTH-1:0] m_axi_araddr [NUM_AXI_PORTS];
  logic [AXI_ID_WIDTH-1:0] m_axi_arid [NUM_AXI_PORTS];
  logic [7:0] m_axi_arlen [NUM_AXI_PORTS];
  logic m_axi_rvalid [NUM_AXI_PORTS];
  logic m_axi_rready [NUM_AXI_PORTS];
  logic m_axi_rlast [NUM_AXI_PORTS];
  logic [AXI_ID_WIDTH-1:0] m_axi_rid [NUM_AXI_PORTS];
  logic [1:0] m_axi_rresp [NUM_AXI_PORTS];
  logic [NUM_AXI_PORTS-1:0] m_axi_wr_req_fire;
  logic [NUM_AXI_PORTS-1:0] m_axi_wr_pending_empty;
  logic [WR_TRACK_SIZEW-1:0] m_axi_wr_aw_handshake_cnt [NUM_AXI_PORTS];
  logic [WR_TRACK_SIZEW-1:0] m_axi_wr_aw_burst_total_cnt [NUM_AXI_PORTS];
  logic [WR_TRACK_SIZEW-1:0] m_axi_wr_w_handshake_cnt [NUM_AXI_PORTS];
  logic [WR_TRACK_SIZEW-1:0] m_axi_wr_wlast_cnt [NUM_AXI_PORTS];
  logic [WR_TRACK_SIZEW-1:0] m_axi_wr_b_handshake_cnt [NUM_AXI_PORTS];

  VX_hw_debug #(
    .NUM_AXI_PORTS    (NUM_AXI_PORTS),
    .AXI_ADDR_WIDTH   (AXI_ADDR_WIDTH),
    .AXI_ID_WIDTH     (AXI_ID_WIDTH),
    .PENDING_WR_SIZEW (PENDING_WR_SIZEW),
    .WR_TRACK_SIZEW   (WR_TRACK_SIZEW)
  ) dut (.*);

  initial begin
    clk = 1'b0;
    forever #(PERIOD / 2) clk = ~clk;
  end

  task automatic expect_flag(input logic actual, input logic expected, input string label);
    if (actual !== expected)
      $fatal(1, "%s: expected %0b, got %0b", label, expected, actual);
  endtask

  initial begin
    reset = 1'b1;
    debug_select = '0;
    debug_clear = 1'b0;
    debug_freeze = 1'b0;
    ap_reset = 1'b0;
    ap_start = 1'b0;
    ap_done = 1'b0;
    ap_idle = 1'b1;
    ap_ready = 1'b1;
    ap_state = '0;
    ap_done_base = 1'b0;
    ap_done_wait_cache = 1'b0;
    vx_busy = 1'b0;
    vx_cache_drain = 1'b0;
    vx_pending_writes = '0;
    vx_pending_writes_empty = 1'b1;
    s_axi_ctrl_awvalid = 1'b0; s_axi_ctrl_awready = 1'b0; s_axi_ctrl_awaddr = '0;
    s_axi_ctrl_wvalid = 1'b0; s_axi_ctrl_wready = 1'b0; s_axi_ctrl_wdata = '0; s_axi_ctrl_wstrb = '0;
    s_axi_ctrl_bvalid = 1'b0; s_axi_ctrl_bready = 1'b0; s_axi_ctrl_bresp = '0;
    s_axi_ctrl_arvalid = 1'b0; s_axi_ctrl_arready = 1'b0; s_axi_ctrl_araddr = '0;
    s_axi_ctrl_rvalid = 1'b0; s_axi_ctrl_rready = 1'b0; s_axi_ctrl_rdata = '0; s_axi_ctrl_rresp = '0;
    m_axi_wr_req_fire = '0;
    m_axi_wr_pending_empty = '1;
    for (int i = 0; i < NUM_AXI_PORTS; ++i) begin
      m_axi_awvalid[i] = 1'b0; m_axi_awready[i] = 1'b0; m_axi_awaddr[i] = '0; m_axi_awid[i] = '0; m_axi_awlen[i] = '0;
      m_axi_wvalid[i] = 1'b0; m_axi_wready[i] = 1'b0; m_axi_wlast[i] = 1'b0;
      m_axi_bvalid[i] = 1'b0; m_axi_bready[i] = 1'b0; m_axi_bid[i] = '0; m_axi_bresp[i] = '0;
      m_axi_arvalid[i] = 1'b0; m_axi_arready[i] = 1'b0; m_axi_araddr[i] = '0; m_axi_arid[i] = '0; m_axi_arlen[i] = '0;
      m_axi_rvalid[i] = 1'b0; m_axi_rready[i] = 1'b0; m_axi_rlast[i] = 1'b0; m_axi_rid[i] = '0; m_axi_rresp[i] = '0;
      m_axi_wr_aw_handshake_cnt[i] = '0;
      m_axi_wr_aw_burst_total_cnt[i] = '0;
      m_axi_wr_w_handshake_cnt[i] = '0;
      m_axi_wr_wlast_cnt[i] = '0;
      m_axi_wr_b_handshake_cnt[i] = '0;
    end

    repeat (4) @(posedge clk);
    reset = 1'b0;
    repeat (2) @(posedge clk);

    // Establish an AR stall baseline, then violate payload stability.
    @(negedge clk);
    m_axi_arvalid[0] = 1'b1;
    m_axi_arready[0] = 1'b0;
    m_axi_araddr[0] = 64'h100;
    @(posedge clk);
    @(negedge clk);
    m_axi_araddr[0] = 64'h200;
    @(posedge clk);
    #1;
    expect_flag(dut.axi_flags[0][3], 1'b0, "per-port flag must be registered");
    expect_flag(dut.global_anomaly_flags[5], 1'b0, "global flag must be pipelined");

    @(posedge clk);
    #1;
    expect_flag(dut.axi_flags[0][3], 1'b1, "registered AR stability flag");
    expect_flag(dut.global_anomaly_flags[5], 1'b0, "global reduction stage");

    @(posedge clk);
    #1;
    expect_flag(dut.global_anomaly_flags[5], 1'b1, "registered global AXI protocol flag");
    if (dut.anomaly_first_cycle > dut.anomaly_last_cycle)
      $fatal(1, "invalid anomaly cycle ordering");

    // Clear must remove sticky and in-flight pipeline state.
    @(negedge clk);
    debug_clear = 1'b1;
    m_axi_arvalid[0] = 1'b0;
    @(posedge clk);
    @(negedge clk);
    debug_clear = 1'b0;
    repeat (3) @(posedge clk);
    #1;
    expect_flag(dut.axi_flags[0][3], 1'b0, "clear per-port flag");
    expect_flag(dut.global_anomaly_flags[5], 1'b0, "clear global flag");

    // A response error is captured per port before reaching the global flag.
    @(negedge clk);
    m_axi_bvalid[1] = 1'b1;
    m_axi_bready[1] = 1'b1;
    m_axi_bresp[1] = 2'b10;
    @(posedge clk);
    #1;
    expect_flag(dut.axi_flags[1][7], 1'b0, "response flag input stage");
    @(negedge clk);
    m_axi_bvalid[1] = 1'b0;
    m_axi_bready[1] = 1'b0;
    m_axi_bresp[1] = '0;
    @(posedge clk);
    #1;
    expect_flag(dut.axi_flags[1][7], 1'b1, "registered BRESP error");
    expect_flag(dut.global_anomaly_flags[7], 1'b0, "response global reduction stage");
    @(posedge clk);
    #1;
    expect_flag(dut.global_anomaly_flags[7], 1'b1, "registered global AXI response flag");

    $display("TEST PASSED");
    $finish;
  end

  initial begin
    #20000;
    $fatal(1, "timeout");
  end

endmodule
