// Copyright © 2019-2023
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

// VCS co-simulation testbench.
// Bridges AXI-Lite ctrl and AXI memory interfaces to App process via TCP sockets.
// RAM and DramSim live in the App process; this TB only relays AXI transactions.
//
// IMPORTANT: The main loop must NEVER block on ctrl tasks, because the DUT
// actively issues AXI memory requests that must be serviced every cycle.
// Both AXI-Lite ctrl and AXI memory are handled as non-blocking state machines
// within a single forever loop.

`timescale 1ns/1ps

`include "vortex_afu.vh"

module tb_vcs_xrtsim #(
  parameter C_S_AXI_CTRL_ADDR_WIDTH = 8,
  parameter C_S_AXI_CTRL_DATA_WIDTH = 32,
  parameter C_M_AXI_MEM_ID_WIDTH    = `PLATFORM_MEMORY_ID_WIDTH,
  parameter C_M_AXI_MEM_DATA_WIDTH  = (`PLATFORM_MEMORY_DATA_SIZE * 8),
  parameter C_M_AXI_MEM_ADDR_WIDTH  = 64,
  parameter C_M_AXI_MEM_NUM_BANKS   = `PLATFORM_MEMORY_NUM_BANKS
);

  localparam int CLK_HALF_PERIOD_NS = 5;
  localparam int DATA_SIZE = `PLATFORM_MEMORY_DATA_SIZE;
  localparam int NUM_BANKS = `PLATFORM_MEMORY_NUM_BANKS;

  // Packet type constants (must match vcs_protocol.h)
  localparam int CMD_REG_WRITE     = 8'h01;
  localparam int CMD_REG_WRITE_ACK = 8'h02;
  localparam int CMD_REG_READ      = 8'h03;
  localparam int CMD_REG_READ_RESP = 8'h04;
  localparam int CMD_SHUTDOWN      = 8'h05;
  localparam int RSP_AXI_R         = 8'h20;
  localparam int RSP_AXI_B         = 8'h21;

  // AXI-Lite ctrl state machine states
  localparam int CTRL_IDLE       = 0;
  localparam int CTRL_WRITE_ADDR = 1;
  localparam int CTRL_WRITE_RESP = 2;
  localparam int CTRL_WRITE_DONE = 3;
  localparam int CTRL_READ_ADDR  = 4;
  localparam int CTRL_READ_DATA  = 5;
  localparam int CTRL_READ_DONE  = 6;

  // ---- DPI imports ----
  import "DPI-C" function int socket_server_init(int ctrl_port, int mem_port);
  import "DPI-C" function int socket_server_accept();
  import "DPI-C" function int ctrl_has_command();
  import "DPI-C" function int ctrl_recv_command(output int cmd_type, output int offset, output int value);
  import "DPI-C" function int ctrl_send_ack();
  import "DPI-C" function int ctrl_send_reg_value(int value);
  import "DPI-C" function int mem_send_axi_ar(int bank, longint addr, int id, int len);
  import "DPI-C" function int mem_send_axi_aw(int bank, longint addr, int id, int len);
  import "DPI-C" function int mem_send_axi_w(input int bank, input byte unsigned data_bytes[], input longint strb, input int last, input int data_size);
  import "DPI-C" function int mem_has_response();
  import "DPI-C" function int mem_recv_response(output int rsp_type, output int bank, output int id, output byte unsigned data_bytes[], output int last, input int data_size);
  import "DPI-C" function void socket_server_close();

  // ---- Clock & Reset ----
  logic ap_clk;
  logic ap_rst_n;

  always #(CLK_HALF_PERIOD_NS) ap_clk = ~ap_clk;

  // ---- AXI Memory signals (per-bank) ----
  logic         m_axi_mem_awvalid [NUM_BANKS];
  logic         m_axi_mem_awready [NUM_BANKS];
  logic [C_M_AXI_MEM_ADDR_WIDTH-1:0]  m_axi_mem_awaddr [NUM_BANKS];
  logic [C_M_AXI_MEM_ID_WIDTH-1:0]    m_axi_mem_awid   [NUM_BANKS];
  logic [7:0]   m_axi_mem_awlen   [NUM_BANKS];
  logic         m_axi_mem_wvalid  [NUM_BANKS];
  logic         m_axi_mem_wready  [NUM_BANKS];
  logic [C_M_AXI_MEM_DATA_WIDTH-1:0]  m_axi_mem_wdata  [NUM_BANKS];
  logic [C_M_AXI_MEM_DATA_WIDTH/8-1:0] m_axi_mem_wstrb [NUM_BANKS];
  logic         m_axi_mem_wlast   [NUM_BANKS];
  logic         m_axi_mem_arvalid [NUM_BANKS];
  logic         m_axi_mem_arready [NUM_BANKS];
  logic [C_M_AXI_MEM_ADDR_WIDTH-1:0]  m_axi_mem_araddr [NUM_BANKS];
  logic [C_M_AXI_MEM_ID_WIDTH-1:0]    m_axi_mem_arid   [NUM_BANKS];
  logic [7:0]   m_axi_mem_arlen   [NUM_BANKS];
  logic         m_axi_mem_rvalid  [NUM_BANKS];
  logic         m_axi_mem_rready  [NUM_BANKS];
  logic [C_M_AXI_MEM_DATA_WIDTH-1:0]  m_axi_mem_rdata  [NUM_BANKS];
  logic         m_axi_mem_rlast   [NUM_BANKS];
  logic [C_M_AXI_MEM_ID_WIDTH-1:0]    m_axi_mem_rid    [NUM_BANKS];
  logic [1:0]   m_axi_mem_rresp   [NUM_BANKS];
  logic         m_axi_mem_bvalid  [NUM_BANKS];
  logic         m_axi_mem_bready  [NUM_BANKS];
  logic [1:0]   m_axi_mem_bresp   [NUM_BANKS];
  logic [C_M_AXI_MEM_ID_WIDTH-1:0]    m_axi_mem_bid    [NUM_BANKS];

  // ---- AXI-Lite Ctrl signals ----
  logic         s_axi_ctrl_awvalid;
  logic         s_axi_ctrl_awready;
  logic [C_S_AXI_CTRL_ADDR_WIDTH-1:0] s_axi_ctrl_awaddr;
  logic         s_axi_ctrl_wvalid;
  logic         s_axi_ctrl_wready;
  logic [C_S_AXI_CTRL_DATA_WIDTH-1:0] s_axi_ctrl_wdata;
  logic [C_S_AXI_CTRL_DATA_WIDTH/8-1:0] s_axi_ctrl_wstrb;
  logic         s_axi_ctrl_arvalid;
  logic         s_axi_ctrl_arready;
  logic [C_S_AXI_CTRL_ADDR_WIDTH-1:0] s_axi_ctrl_araddr;
  logic         s_axi_ctrl_rvalid;
  logic         s_axi_ctrl_rready;
  logic [C_S_AXI_CTRL_DATA_WIDTH-1:0] s_axi_ctrl_rdata;
  logic [1:0]   s_axi_ctrl_rresp;
  logic         s_axi_ctrl_bvalid;
  logic         s_axi_ctrl_bready;
  logic [1:0]   s_axi_ctrl_bresp;
  logic         interrupt;

  // ---- Macro for connecting numbered DUT ports to array-indexed TB signals ----
`define TB_AXI_MEM_CONNECT(i) \
    .m_axi_mem_``i``_awvalid(m_axi_mem_awvalid[i]), \
    .m_axi_mem_``i``_awready(m_axi_mem_awready[i]), \
    .m_axi_mem_``i``_awaddr(m_axi_mem_awaddr[i]), \
    .m_axi_mem_``i``_awid(m_axi_mem_awid[i]), \
    .m_axi_mem_``i``_awlen(m_axi_mem_awlen[i]), \
    .m_axi_mem_``i``_wvalid(m_axi_mem_wvalid[i]), \
    .m_axi_mem_``i``_wready(m_axi_mem_wready[i]), \
    .m_axi_mem_``i``_wdata(m_axi_mem_wdata[i]), \
    .m_axi_mem_``i``_wstrb(m_axi_mem_wstrb[i]), \
    .m_axi_mem_``i``_wlast(m_axi_mem_wlast[i]), \
    .m_axi_mem_``i``_arvalid(m_axi_mem_arvalid[i]), \
    .m_axi_mem_``i``_arready(m_axi_mem_arready[i]), \
    .m_axi_mem_``i``_araddr(m_axi_mem_araddr[i]), \
    .m_axi_mem_``i``_arid(m_axi_mem_arid[i]), \
    .m_axi_mem_``i``_arlen(m_axi_mem_arlen[i]), \
    .m_axi_mem_``i``_rvalid(m_axi_mem_rvalid[i]), \
    .m_axi_mem_``i``_rready(m_axi_mem_rready[i]), \
    .m_axi_mem_``i``_rdata(m_axi_mem_rdata[i]), \
    .m_axi_mem_``i``_rlast(m_axi_mem_rlast[i]), \
    .m_axi_mem_``i``_rid(m_axi_mem_rid[i]), \
    .m_axi_mem_``i``_rresp(m_axi_mem_rresp[i]), \
    .m_axi_mem_``i``_bvalid(m_axi_mem_bvalid[i]), \
    .m_axi_mem_``i``_bready(m_axi_mem_bready[i]), \
    .m_axi_mem_``i``_bresp(m_axi_mem_bresp[i]), \
    .m_axi_mem_``i``_bid(m_axi_mem_bid[i])

  // ---- DUT Instantiation ----
`ifdef VCS_POST_IMPL
  ulp_vortex_afu_1_0 dut (
    .ap_clk(ap_clk),
    .ap_rst_n(ap_rst_n),
    `REPEAT (`PLATFORM_MEMORY_NUM_BANKS, TB_AXI_MEM_CONNECT, REPEAT_COMMA),
    .s_axi_ctrl_awvalid(s_axi_ctrl_awvalid),
    .s_axi_ctrl_awready(s_axi_ctrl_awready),
    .s_axi_ctrl_awaddr(s_axi_ctrl_awaddr),
    .s_axi_ctrl_wvalid(s_axi_ctrl_wvalid),
    .s_axi_ctrl_wready(s_axi_ctrl_wready),
    .s_axi_ctrl_wdata(s_axi_ctrl_wdata),
    .s_axi_ctrl_wstrb(s_axi_ctrl_wstrb),
    .s_axi_ctrl_arvalid(s_axi_ctrl_arvalid),
    .s_axi_ctrl_arready(s_axi_ctrl_arready),
    .s_axi_ctrl_araddr(s_axi_ctrl_araddr),
    .s_axi_ctrl_rvalid(s_axi_ctrl_rvalid),
    .s_axi_ctrl_rready(s_axi_ctrl_rready),
    .s_axi_ctrl_rdata(s_axi_ctrl_rdata),
    .s_axi_ctrl_rresp(s_axi_ctrl_rresp),
    .s_axi_ctrl_bvalid(s_axi_ctrl_bvalid),
    .s_axi_ctrl_bready(s_axi_ctrl_bready),
    .s_axi_ctrl_bresp(s_axi_ctrl_bresp),
    .interrupt(interrupt)
  );

  `ifdef PGSIM_RUNTIME_SDF_ANNOTATE
  parameter string SDF_FILE = "";
  initial begin : annotate_runtime_sdf
    if (SDF_FILE == "") begin
      $fatal(1, "[TB] Missing non-empty SDF_FILE parameter for runtime SDF annotation");
    end
    $display("[TB] Annotating SDF: %0s", SDF_FILE);
    $sdf_annotate(SDF_FILE, dut,,, "MAXIMUM");
  end
  `endif

`else
  // RTL simulation: use vortex_afu_shim
  vortex_afu_shim #(
    .C_S_AXI_CTRL_ADDR_WIDTH(C_S_AXI_CTRL_ADDR_WIDTH),
    .C_S_AXI_CTRL_DATA_WIDTH(C_S_AXI_CTRL_DATA_WIDTH),
    .C_M_AXI_MEM_ID_WIDTH(C_M_AXI_MEM_ID_WIDTH),
    .C_M_AXI_MEM_DATA_WIDTH(C_M_AXI_MEM_DATA_WIDTH),
    .C_M_AXI_MEM_ADDR_WIDTH(C_M_AXI_MEM_ADDR_WIDTH),
    .C_M_AXI_MEM_NUM_BANKS(C_M_AXI_MEM_NUM_BANKS)
  ) dut (
    .ap_clk(ap_clk),
    .ap_rst_n(ap_rst_n),
    `REPEAT (`PLATFORM_MEMORY_NUM_BANKS, TB_AXI_MEM_CONNECT, REPEAT_COMMA),
    .s_axi_ctrl_awvalid(s_axi_ctrl_awvalid),
    .s_axi_ctrl_awready(s_axi_ctrl_awready),
    .s_axi_ctrl_awaddr(s_axi_ctrl_awaddr),
    .s_axi_ctrl_wvalid(s_axi_ctrl_wvalid),
    .s_axi_ctrl_wready(s_axi_ctrl_wready),
    .s_axi_ctrl_wdata(s_axi_ctrl_wdata),
    .s_axi_ctrl_wstrb(s_axi_ctrl_wstrb),
    .s_axi_ctrl_arvalid(s_axi_ctrl_arvalid),
    .s_axi_ctrl_arready(s_axi_ctrl_arready),
    .s_axi_ctrl_araddr(s_axi_ctrl_araddr),
    .s_axi_ctrl_rvalid(s_axi_ctrl_rvalid),
    .s_axi_ctrl_rready(s_axi_ctrl_rready),
    .s_axi_ctrl_rdata(s_axi_ctrl_rdata),
    .s_axi_ctrl_rresp(s_axi_ctrl_rresp),
    .s_axi_ctrl_bvalid(s_axi_ctrl_bvalid),
    .s_axi_ctrl_bready(s_axi_ctrl_bready),
    .s_axi_ctrl_bresp(s_axi_ctrl_bresp),
    .interrupt(interrupt)
  );
`endif

`ifdef FSDB_DUMP
  initial begin : fsdb_dump
    string fsdb_file;
    if (!$value$plusargs("fsdb_file=%s", fsdb_file))
      fsdb_file = "vcs_cosim.fsdb";
    $fsdbDumpfile(fsdb_file);
    $fsdbDumpvars(0, tb_vcs_xrtsim, "+all");
    $display("[TB] FSDB dump enabled: %0s", fsdb_file);
  end
`endif

  // ---- AXI Memory responder ----
  byte unsigned w_data_buf [DATA_SIZE];
  byte unsigned r_data_buf [DATA_SIZE];

  // Next-cycle response staging
  logic next_rvalid [NUM_BANKS];
  logic [C_M_AXI_MEM_DATA_WIDTH-1:0] next_rdata [NUM_BANKS];
  logic [C_M_AXI_MEM_ID_WIDTH-1:0]   next_rid   [NUM_BANKS];
  logic next_rlast  [NUM_BANKS];
  logic next_bvalid [NUM_BANKS];
  logic [C_M_AXI_MEM_ID_WIDTH-1:0]   next_bid   [NUM_BANKS];

  // AXI-Lite ctrl state machine
  int ctrl_state;
  int ctrl_cmd_type, ctrl_cmd_offset, ctrl_cmd_value;
  bit ctrl_aw_done, ctrl_w_done;

  // ---- Main simulation flow ----

  initial begin : main_flow
    int socket_port;
    int ret;
    int rsp_type, rsp_bank, rsp_id, rsp_last;

    // Get socket port from plusarg (default 9999)
    if (!$value$plusargs("SOCKET_PORT=%d", socket_port))
      socket_port = 9999;

    $display("[TB] Starting VCS co-simulation testbench");
    $display("[TB] Socket port: ctrl=%0d, mem=%0d", socket_port, socket_port + 1);

    // Initialize all signals to known values (no x)
    ap_clk            = 1'b0;
    ap_rst_n          = 1'b0;
    s_axi_ctrl_awvalid = 1'b0;
    s_axi_ctrl_awaddr  = '0;
    s_axi_ctrl_wvalid  = 1'b0;
    s_axi_ctrl_wdata   = '0;
    s_axi_ctrl_wstrb   = '0;
    s_axi_ctrl_bready  = 1'b0;
    s_axi_ctrl_arvalid = 1'b0;
    s_axi_ctrl_araddr  = '0;
    s_axi_ctrl_rready  = 1'b0;

    ctrl_state = CTRL_IDLE;

    for (int b = 0; b < NUM_BANKS; b++) begin
      m_axi_mem_awready[b] = 1'b1;
      m_axi_mem_wready[b]  = 1'b1;
      m_axi_mem_arready[b] = 1'b1;
      m_axi_mem_rvalid[b]  = 1'b0;
      m_axi_mem_rdata[b]   = '0;
      m_axi_mem_rid[b]     = '0;
      m_axi_mem_rlast[b]   = 1'b0;
      m_axi_mem_rresp[b]   = 2'b00;
      m_axi_mem_bvalid[b]  = 1'b0;
      m_axi_mem_bid[b]     = '0;
      m_axi_mem_bresp[b]   = 2'b00;
      next_rvalid[b] = 1'b0;
      next_rdata[b]  = '0;
      next_rid[b]    = '0;
      next_rlast[b]  = 1'b0;
      next_bvalid[b] = 1'b0;
      next_bid[b]    = '0;
    end

    // Socket server init and accept
    ret = socket_server_init(socket_port, socket_port + 1);
    if (ret != 0) $fatal(1, "[TB] Failed to init socket server");

    ret = socket_server_accept();
    if (ret != 0) $fatal(1, "[TB] Failed to accept socket connections");

    // Reset sequence
    repeat (20) @(posedge ap_clk);
    ap_rst_n <= 1'b1;
    repeat (20) @(posedge ap_clk);

    $display("[TB] Reset done, entering command loop");

    // ---- Main loop: ALL handling is non-blocking per cycle ----
    forever begin
      @(posedge ap_clk);

      // === AXI Memory: drive response signals via NBA ===
      for (int b = 0; b < NUM_BANKS; b++) begin
        m_axi_mem_rvalid[b] <= next_rvalid[b];
        m_axi_mem_rdata[b]  <= next_rdata[b];
        m_axi_mem_rid[b]    <= next_rid[b];
        m_axi_mem_rlast[b]  <= next_rlast[b];
        m_axi_mem_bvalid[b] <= next_bvalid[b];
        m_axi_mem_bid[b]    <= next_bid[b];
      end

      `ifdef DEBUG_AXI
      // Diagnostic: check for unexpected non-zero on response valid signals
      for (int b = 0; b < NUM_BANKS; b++) begin
        if (m_axi_mem_rvalid[b] !== 1'b0 && m_axi_mem_rvalid[b] !== 1'b1)
          $display("[TB] WARN: rvalid[%0d]=x at t=%0t", b, $time);
        if (m_axi_mem_bvalid[b] !== 1'b0 && m_axi_mem_bvalid[b] !== 1'b1)
          $display("[TB] WARN: bvalid[%0d]=x at t=%0t", b, $time);
        if (m_axi_mem_rresp[b] !== 2'b00)
          $display("[TB] WARN: rresp[%0d]=%b at t=%0t", b, m_axi_mem_rresp[b], $time);
        if (m_axi_mem_bresp[b] !== 2'b00)
          $display("[TB] WARN: bresp[%0d]=%b at t=%0t", b, m_axi_mem_bresp[b], $time);
      end
      `endif

      // === AXI Memory: capture DUT requests ===
      for (int b = 0; b < NUM_BANKS; b++) begin
        if (m_axi_mem_arvalid[b] && m_axi_mem_arready[b]) begin
          `ifdef DEBUG_AXI
          $display("[TB] AR: bank=%0d addr=0x%016x id=%0d len=%0d t=%0t", b, m_axi_mem_araddr[b], m_axi_mem_arid[b], m_axi_mem_arlen[b], $time);
          `endif
          ret = mem_send_axi_ar(b, m_axi_mem_araddr[b], m_axi_mem_arid[b], m_axi_mem_arlen[b]);
        end
        if (m_axi_mem_awvalid[b] && m_axi_mem_awready[b]) begin
          `ifdef DEBUG_AXI
          $display("[TB] AW: bank=%0d addr=0x%016x id=%0d len=%0d t=%0t", b, m_axi_mem_awaddr[b], m_axi_mem_awid[b], m_axi_mem_awlen[b], $time);
          `endif
          ret = mem_send_axi_aw(b, m_axi_mem_awaddr[b], m_axi_mem_awid[b], m_axi_mem_awlen[b]);
        end
        if (m_axi_mem_wvalid[b] && m_axi_mem_wready[b]) begin
          for (int i = 0; i < DATA_SIZE; i++)
            w_data_buf[i] = m_axi_mem_wdata[b][i*8 +: 8];
          ret = mem_send_axi_w(b, w_data_buf, m_axi_mem_wstrb[b], m_axi_mem_wlast[b], DATA_SIZE);
        end
      end

      // === AXI Memory: compute next_* for next cycle ===
      for (int b = 0; b < NUM_BANKS; b++) begin
        if (m_axi_mem_rvalid[b] && m_axi_mem_rready[b])
          next_rvalid[b] = 1'b0;
        if (m_axi_mem_bvalid[b] && m_axi_mem_bready[b])
          next_bvalid[b] = 1'b0;
      end

      while (mem_has_response()) begin
        ret = mem_recv_response(rsp_type, rsp_bank, rsp_id, r_data_buf, rsp_last, DATA_SIZE);
        if (ret != 0) break;
        if (rsp_type == RSP_AXI_R) begin
          next_rvalid[rsp_bank] = 1'b1;
          next_rid[rsp_bank]    = rsp_id;
          next_rlast[rsp_bank]  = rsp_last;
          for (int i = 0; i < DATA_SIZE; i++)
            next_rdata[rsp_bank][i*8 +: 8] = r_data_buf[i];
          `ifdef DEBUG_AXI
          $display("[TB] R-RSP: bank=%0d id=%0d last=%0d data[0:7]=%02x%02x%02x%02x_%02x%02x%02x%02x t=%0t",
            rsp_bank, rsp_id, rsp_last,
            r_data_buf[7], r_data_buf[6], r_data_buf[5], r_data_buf[4],
            r_data_buf[3], r_data_buf[2], r_data_buf[1], r_data_buf[0], $time);
          `endif
        end else if (rsp_type == RSP_AXI_B) begin
          next_bvalid[rsp_bank] = 1'b1;
          next_bid[rsp_bank]    = rsp_id;
          `ifdef DEBUG_AXI
          $display("[TB] B-RSP: bank=%0d id=%0d t=%0t", rsp_bank, rsp_id, $time);
          `endif
        end
      end

      // === AXI-Lite Ctrl: non-blocking state machine ===
      case (ctrl_state)
        CTRL_IDLE: begin
          if (ctrl_has_command()) begin
            ret = ctrl_recv_command(ctrl_cmd_type, ctrl_cmd_offset, ctrl_cmd_value);
            if (ret != 0) begin
              // skip
            end else if (ctrl_cmd_type == CMD_SHUTDOWN) begin
              $display("[TB] Received SHUTDOWN command");
              socket_server_close();
              $finish;
            end else if (ctrl_cmd_type == CMD_REG_WRITE) begin
              $display("[TB] REG_WRITE: offset=0x%02x value=0x%08x", ctrl_cmd_offset, ctrl_cmd_value);
              // Start AXI-Lite write: assert awvalid + wvalid
              s_axi_ctrl_awaddr  <= ctrl_cmd_offset[C_S_AXI_CTRL_ADDR_WIDTH-1:0];
              s_axi_ctrl_awvalid <= 1'b1;
              s_axi_ctrl_wdata   <= ctrl_cmd_value;
              s_axi_ctrl_wstrb   <= '1;
              s_axi_ctrl_wvalid  <= 1'b1;
              ctrl_aw_done = 1'b0;
              ctrl_w_done  = 1'b0;
              ctrl_state = CTRL_WRITE_ADDR;
            end else if (ctrl_cmd_type == CMD_REG_READ) begin
              // Start AXI-Lite read: assert arvalid
              s_axi_ctrl_araddr  <= ctrl_cmd_offset[C_S_AXI_CTRL_ADDR_WIDTH-1:0];
              s_axi_ctrl_arvalid <= 1'b1;
              ctrl_state = CTRL_READ_ADDR;
            end
          end
        end

        CTRL_WRITE_ADDR: begin
          // Wait for AW + W handshake
          if (!ctrl_aw_done && s_axi_ctrl_awvalid && s_axi_ctrl_awready) begin
            s_axi_ctrl_awvalid <= 1'b0;
            ctrl_aw_done = 1'b1;
          end
          if (!ctrl_w_done && s_axi_ctrl_wvalid && s_axi_ctrl_wready) begin
            s_axi_ctrl_wvalid <= 1'b0;
            ctrl_w_done = 1'b1;
          end
          if (ctrl_aw_done && ctrl_w_done) begin
            s_axi_ctrl_bready <= 1'b1;
            ctrl_state = CTRL_WRITE_RESP;
          end
        end

        CTRL_WRITE_RESP: begin
          // Wait for B response
          if (s_axi_ctrl_bvalid) begin
            s_axi_ctrl_bready <= 1'b0;
            ctrl_state = CTRL_WRITE_DONE;
          end
        end

        CTRL_WRITE_DONE: begin
          // Send ACK to App
          ret = ctrl_send_ack();
          ctrl_state = CTRL_IDLE;
        end

        CTRL_READ_ADDR: begin
          // Wait for AR handshake
          if (s_axi_ctrl_arvalid && s_axi_ctrl_arready) begin
            s_axi_ctrl_arvalid <= 1'b0;
            s_axi_ctrl_rready  <= 1'b1;
            ctrl_state = CTRL_READ_DATA;
          end
        end

        CTRL_READ_DATA: begin
          // Wait for R response
          if (s_axi_ctrl_rvalid) begin
            ctrl_cmd_value = s_axi_ctrl_rdata;
            s_axi_ctrl_rready <= 1'b0;
            ctrl_state = CTRL_READ_DONE;
          end
        end

        CTRL_READ_DONE: begin
          // Send value to App
          $display("[TB] REG_READ: offset=0x%02x value=0x%08x", ctrl_cmd_offset, ctrl_cmd_value);
          ret = ctrl_send_reg_value(ctrl_cmd_value);
          ctrl_state = CTRL_IDLE;
        end

        default: ctrl_state = CTRL_IDLE;
      endcase

    end
  end

endmodule
