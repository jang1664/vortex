`timescale 1ns/1ps

module tb_ulp_vortex_afu_1_0_post #(
  parameter string SDF_FILE = ""
);

  localparam int CLK_HALF_PERIOD_NS = 5;
  localparam int AXI_TIMEOUT_CYCLES = 10000;

  logic         ap_clk;
  logic         ap_rst_n;

  logic         m_axi_mem_0_awvalid;
  logic         m_axi_mem_0_awready;
  logic [63:0]  m_axi_mem_0_awaddr;
  logic [31:0]  m_axi_mem_0_awid;
  logic [7:0]   m_axi_mem_0_awlen;
  logic         m_axi_mem_0_wvalid;
  logic         m_axi_mem_0_wready;
  logic [511:0] m_axi_mem_0_wdata;
  logic [63:0]  m_axi_mem_0_wstrb;
  logic         m_axi_mem_0_wlast;
  logic         m_axi_mem_0_arvalid;
  logic         m_axi_mem_0_arready;
  logic [63:0]  m_axi_mem_0_araddr;
  logic [31:0]  m_axi_mem_0_arid;
  logic [7:0]   m_axi_mem_0_arlen;
  logic         m_axi_mem_0_rvalid;
  logic         m_axi_mem_0_rready;
  logic [511:0] m_axi_mem_0_rdata;
  logic         m_axi_mem_0_rlast;
  logic [31:0]  m_axi_mem_0_rid;
  logic [1:0]   m_axi_mem_0_rresp;
  logic         m_axi_mem_0_bvalid;
  logic         m_axi_mem_0_bready;
  logic [1:0]   m_axi_mem_0_bresp;
  logic [31:0]  m_axi_mem_0_bid;

  logic         s_axi_ctrl_awvalid;
  logic         s_axi_ctrl_awready;
  logic [7:0]   s_axi_ctrl_awaddr;
  logic         s_axi_ctrl_wvalid;
  logic         s_axi_ctrl_wready;
  logic [31:0]  s_axi_ctrl_wdata;
  logic [3:0]   s_axi_ctrl_wstrb;
  logic         s_axi_ctrl_arvalid;
  logic         s_axi_ctrl_arready;
  logic [7:0]   s_axi_ctrl_araddr;
  logic         s_axi_ctrl_rvalid;
  logic         s_axi_ctrl_rready;
  logic [31:0]  s_axi_ctrl_rdata;
  logic [1:0]   s_axi_ctrl_rresp;
  logic         s_axi_ctrl_bvalid;
  logic         s_axi_ctrl_bready;
  logic [1:0]   s_axi_ctrl_bresp;
  logic         interrupt;

  logic         wr_active_q;
  logic [31:0]  wr_id_q;
  logic         rd_active_q;
  logic [31:0]  rd_id_q;
  logic [63:0]  rd_addr_q;
  logic [8:0]   rd_beats_left_q;

  ulp_vortex_afu_1_0 dut (
    .ap_clk(ap_clk),
    .ap_rst_n(ap_rst_n),
    .m_axi_mem_0_awvalid(m_axi_mem_0_awvalid),
    .m_axi_mem_0_awready(m_axi_mem_0_awready),
    .m_axi_mem_0_awaddr(m_axi_mem_0_awaddr),
    .m_axi_mem_0_awid(m_axi_mem_0_awid),
    .m_axi_mem_0_awlen(m_axi_mem_0_awlen),
    .m_axi_mem_0_wvalid(m_axi_mem_0_wvalid),
    .m_axi_mem_0_wready(m_axi_mem_0_wready),
    .m_axi_mem_0_wdata(m_axi_mem_0_wdata),
    .m_axi_mem_0_wstrb(m_axi_mem_0_wstrb),
    .m_axi_mem_0_wlast(m_axi_mem_0_wlast),
    .m_axi_mem_0_arvalid(m_axi_mem_0_arvalid),
    .m_axi_mem_0_arready(m_axi_mem_0_arready),
    .m_axi_mem_0_araddr(m_axi_mem_0_araddr),
    .m_axi_mem_0_arid(m_axi_mem_0_arid),
    .m_axi_mem_0_arlen(m_axi_mem_0_arlen),
    .m_axi_mem_0_rvalid(m_axi_mem_0_rvalid),
    .m_axi_mem_0_rready(m_axi_mem_0_rready),
    .m_axi_mem_0_rdata(m_axi_mem_0_rdata),
    .m_axi_mem_0_rlast(m_axi_mem_0_rlast),
    .m_axi_mem_0_rid(m_axi_mem_0_rid),
    .m_axi_mem_0_rresp(m_axi_mem_0_rresp),
    .m_axi_mem_0_bvalid(m_axi_mem_0_bvalid),
    .m_axi_mem_0_bready(m_axi_mem_0_bready),
    .m_axi_mem_0_bresp(m_axi_mem_0_bresp),
    .m_axi_mem_0_bid(m_axi_mem_0_bid),
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
  initial begin : annotate_runtime_sdf
    if (SDF_FILE == "") begin
      $fatal(1, "[TB] Missing non-empty SDF_FILE parameter for runtime SDF annotation");
    end
    $display("[TB] Annotating SDF: %0s", SDF_FILE);
    $sdf_annotate(SDF_FILE, dut,,, "MAXIMUM");
  end
`endif

`ifdef FSDB_DUMP
  initial begin : fsdb_dump
    string fsdb_file;
    if (!$value$plusargs("fsdb_file=%s", fsdb_file))
      fsdb_file = "pgsim.fsdb";
    $fsdbDumpfile(fsdb_file);
    $fsdbDumpvars(0, tb_ulp_vortex_afu_1_0_post, "+all");
    $display("[TB] FSDB dump enabled: %0s", fsdb_file);
  end
`endif

  always #(CLK_HALF_PERIOD_NS) ap_clk = ~ap_clk;

  function automatic [511:0] mem_read_data(input [63:0] addr);
    mem_read_data = {8{addr}};
  endfunction

  task automatic axi_ctrl_write(input [7:0] addr, input [31:0] data);
    int aw_stall_cyc;
    int w_stall_cyc;
    int b_stall_cyc;
    bit aw_done;
    bit w_done;
    begin
      aw_done = 1'b0;
      w_done  = 1'b0;
      aw_stall_cyc = 0;
      w_stall_cyc  = 0;
      b_stall_cyc  = 0;

      s_axi_ctrl_awaddr  <= addr;
      s_axi_ctrl_awvalid <= 1'b1;
      s_axi_ctrl_wdata   <= data;
      s_axi_ctrl_wstrb   <= 4'hf;
      s_axi_ctrl_wvalid  <= 1'b1;

      while (!(aw_done && w_done)) begin
        @(posedge ap_clk);
        if (!aw_done && s_axi_ctrl_awvalid && s_axi_ctrl_awready) begin
          s_axi_ctrl_awvalid <= 1'b0;
          aw_done = 1'b1;
        end
        if (!aw_done && s_axi_ctrl_awvalid && !s_axi_ctrl_awready) begin
          aw_stall_cyc++;
          if (aw_stall_cyc >= AXI_TIMEOUT_CYCLES) begin
            $fatal(1, "[TB] AXI-Lite AW handshake stall timeout");
          end
        end
        if (!w_done && s_axi_ctrl_wvalid && s_axi_ctrl_wready) begin
          s_axi_ctrl_wvalid <= 1'b0;
          w_done = 1'b1;
        end
        if (!w_done && s_axi_ctrl_wvalid && !s_axi_ctrl_wready) begin
          w_stall_cyc++;
          if (w_stall_cyc >= AXI_TIMEOUT_CYCLES) begin
            $fatal(1, "[TB] AXI-Lite W handshake stall timeout");
          end
        end
      end

      s_axi_ctrl_bready <= 1'b1;
      while (1) begin
        @(posedge ap_clk);
        if (s_axi_ctrl_bvalid && s_axi_ctrl_bready)
          break;
        if (s_axi_ctrl_bvalid && !s_axi_ctrl_bready) begin
          b_stall_cyc++;
          if (b_stall_cyc >= AXI_TIMEOUT_CYCLES) begin
            $fatal(1, "[TB] AXI-Lite B handshake stall timeout");
          end
        end
      end
      @(posedge ap_clk);
      s_axi_ctrl_bready <= 1'b0;
    end
  endtask

  task automatic axi_ctrl_read(input [7:0] addr, output [31:0] data);
    int ar_stall_cyc;
    int r_stall_cyc;
    begin
      ar_stall_cyc = 0;
      r_stall_cyc  = 0;
      s_axi_ctrl_araddr  <= addr;
      s_axi_ctrl_arvalid <= 1'b1;

      while (s_axi_ctrl_arvalid) begin
        @(posedge ap_clk);
        if (s_axi_ctrl_arvalid && s_axi_ctrl_arready) begin
          s_axi_ctrl_arvalid <= 1'b0;
        end
        if (s_axi_ctrl_arvalid && !s_axi_ctrl_arready) begin
          ar_stall_cyc++;
          if (ar_stall_cyc >= AXI_TIMEOUT_CYCLES) begin
            $fatal(1, "[TB] AXI-Lite AR handshake stall timeout");
          end
        end
      end

      s_axi_ctrl_rready <= 1'b1;
      while (1) begin
        @(posedge ap_clk);
        if (s_axi_ctrl_rvalid && s_axi_ctrl_rready) begin
          data = s_axi_ctrl_rdata;
          break;
        end
        if (s_axi_ctrl_rvalid && !s_axi_ctrl_rready) begin
          r_stall_cyc++;
          if (r_stall_cyc >= AXI_TIMEOUT_CYCLES) begin
            $fatal(1, "[TB] AXI-Lite R handshake stall timeout");
          end
        end
      end
      @(posedge ap_clk);
      s_axi_ctrl_rready <= 1'b0;
    end
  endtask

  initial begin
    $display("Start AFU post impl simulation!!!");
    ap_clk            = 1'b0;
    ap_rst_n          = 1'b0;

    m_axi_mem_0_awready = 1'b1;
    m_axi_mem_0_wready  = 1'b1;
    m_axi_mem_0_arready = 1'b1;
    s_axi_ctrl_awvalid = 1'b0;
    s_axi_ctrl_awaddr  = '0;
    s_axi_ctrl_wvalid  = 1'b0;
    s_axi_ctrl_wdata   = '0;
    s_axi_ctrl_wstrb   = '0;
    s_axi_ctrl_bready  = 1'b0;
    s_axi_ctrl_arvalid = 1'b0;
    s_axi_ctrl_araddr  = '0;
    s_axi_ctrl_rready  = 1'b0;

    repeat (20) @(posedge ap_clk);
    ap_rst_n <= 1'b1;
    repeat (20) @(posedge ap_clk);

    begin
      logic [31:0] rd_data;
      axi_ctrl_read(8'h00, rd_data);
      $display("[%0t] AXI-Lite read @0x00 = 0x%08x", $time, rd_data);
      axi_ctrl_write(8'h10, 32'h0000_0001);
      axi_ctrl_write(8'h18, 32'h0000_0001);
    end

    repeat (5000) @(posedge ap_clk);
    $display("[%0t] TB done. interrupt=%0b", $time, interrupt);
    $finish;
  end

  always_ff @(posedge ap_clk) begin
    if (!ap_rst_n) begin
      wr_active_q      <= 1'b0;
      wr_id_q          <= '0;
      rd_active_q      <= 1'b0;
      rd_id_q          <= '0;
      rd_addr_q        <= '0;
      rd_beats_left_q  <= '0;
      m_axi_mem_0_bvalid <= 1'b0;
      m_axi_mem_0_bresp  <= 2'b00;
      m_axi_mem_0_bid    <= '0;
      m_axi_mem_0_rvalid <= 1'b0;
      m_axi_mem_0_rlast  <= 1'b0;
      m_axi_mem_0_rid    <= '0;
      m_axi_mem_0_rresp  <= 2'b00;
      m_axi_mem_0_rdata  <= '0;
    end else begin
      if (m_axi_mem_0_awvalid && m_axi_mem_0_awready) begin
        wr_active_q <= 1'b1;
        wr_id_q <= m_axi_mem_0_awid;
      end

      if (m_axi_mem_0_wvalid && m_axi_mem_0_wready && m_axi_mem_0_wlast && wr_active_q) begin
        m_axi_mem_0_bvalid <= 1'b1;
        m_axi_mem_0_bresp  <= 2'b00;
        m_axi_mem_0_bid    <= wr_id_q;
        wr_active_q        <= 1'b0;
      end

      if (m_axi_mem_0_bvalid && m_axi_mem_0_bready) begin
        m_axi_mem_0_bvalid <= 1'b0;
      end

      if (!rd_active_q && m_axi_mem_0_arvalid && m_axi_mem_0_arready) begin
        rd_active_q      <= 1'b1;
        rd_id_q          <= m_axi_mem_0_arid;
        rd_addr_q        <= m_axi_mem_0_araddr;
        rd_beats_left_q  <= {1'b0, m_axi_mem_0_arlen} + 9'd1;

        m_axi_mem_0_rvalid <= 1'b1;
        m_axi_mem_0_rid    <= m_axi_mem_0_arid;
        m_axi_mem_0_rresp  <= 2'b00;
        m_axi_mem_0_rdata  <= mem_read_data(m_axi_mem_0_araddr);
        m_axi_mem_0_rlast  <= (m_axi_mem_0_arlen == 8'd0);
      end else if (rd_active_q && m_axi_mem_0_rvalid && m_axi_mem_0_rready) begin
        if (rd_beats_left_q == 9'd1) begin
          rd_active_q      <= 1'b0;
          rd_beats_left_q  <= '0;
          m_axi_mem_0_rvalid <= 1'b0;
          m_axi_mem_0_rlast  <= 1'b0;
        end else begin
          rd_beats_left_q  <= rd_beats_left_q - 9'd1;
          rd_addr_q        <= rd_addr_q + 64'd64;
          m_axi_mem_0_rvalid <= 1'b1;
          m_axi_mem_0_rid    <= rd_id_q;
          m_axi_mem_0_rresp  <= 2'b00;
          m_axi_mem_0_rdata  <= mem_read_data(rd_addr_q + 64'd64);
          m_axi_mem_0_rlast  <= (rd_beats_left_q == 9'd2);
        end
      end
    end
  end

endmodule
