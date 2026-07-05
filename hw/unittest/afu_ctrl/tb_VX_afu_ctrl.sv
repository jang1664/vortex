`timescale 1ns / 1ps

module tb_VX_afu_ctrl ();

  localparam int PERIOD = 10;
  localparam logic [7:0] ADDR_AP_CTRL = 8'h00;
  localparam logic [7:0] ADDR_GIE     = 8'h04;
  localparam logic [7:0] ADDR_IER     = 8'h08;

  logic clk = 1'b0;
  logic reset = 1'b1;

  logic        s_axi_awvalid;
  logic [7:0]  s_axi_awaddr;
  wire         s_axi_awready;
  logic        s_axi_wvalid;
  logic [31:0] s_axi_wdata;
  logic [3:0]  s_axi_wstrb;
  wire         s_axi_wready;
  wire         s_axi_bvalid;
  wire [1:0]   s_axi_bresp;
  logic        s_axi_bready;
  logic        s_axi_arvalid;
  logic [7:0]  s_axi_araddr;
  wire         s_axi_arready;
  wire         s_axi_rvalid;
  wire [31:0]  s_axi_rdata;
  wire [1:0]   s_axi_rresp;
  logic        s_axi_rready;

  wire         ap_reset;
  wire         ap_start;
  logic        ap_done;
  logic        ap_ready;
  logic        ap_idle;
  wire         interrupt;
  wire         ap_ctrl_read;
  wire         dcr_wr_valid;
  wire [VX_gpu_pkg::VX_DCR_ADDR_WIDTH-1:0] dcr_wr_addr;
  wire [VX_gpu_pkg::VX_DCR_DATA_WIDTH-1:0] dcr_wr_data;

  always #(PERIOD / 2) clk <= ~clk;

  VX_afu_ctrl #(
      .S_AXI_ADDR_WIDTH (8),
      .S_AXI_DATA_WIDTH (32)
  ) dut (
      .clk            (clk),
      .reset          (reset),
      .s_axi_awvalid  (s_axi_awvalid),
      .s_axi_awaddr   (s_axi_awaddr),
      .s_axi_awready  (s_axi_awready),
      .s_axi_wvalid   (s_axi_wvalid),
      .s_axi_wdata    (s_axi_wdata),
      .s_axi_wstrb    (s_axi_wstrb),
      .s_axi_wready   (s_axi_wready),
      .s_axi_bvalid   (s_axi_bvalid),
      .s_axi_bresp    (s_axi_bresp),
      .s_axi_bready   (s_axi_bready),
      .s_axi_arvalid  (s_axi_arvalid),
      .s_axi_araddr   (s_axi_araddr),
      .s_axi_arready  (s_axi_arready),
      .s_axi_rvalid   (s_axi_rvalid),
      .s_axi_rdata    (s_axi_rdata),
      .s_axi_rresp    (s_axi_rresp),
      .s_axi_rready   (s_axi_rready),
      .ap_reset       (ap_reset),
      .ap_start       (ap_start),
      .ap_done        (ap_done),
      .ap_ready       (ap_ready),
      .ap_idle        (ap_idle),
      .interrupt      (interrupt),
      .ap_ctrl_read   (ap_ctrl_read),
      .dcr_wr_valid   (dcr_wr_valid),
      .dcr_wr_addr    (dcr_wr_addr),
      .dcr_wr_data    (dcr_wr_data)
  );

  task automatic clear_inputs();
    begin
      s_axi_awvalid = 1'b0;
      s_axi_awaddr  = '0;
      s_axi_wvalid  = 1'b0;
      s_axi_wdata   = '0;
      s_axi_wstrb   = '0;
      s_axi_bready  = 1'b1;
      s_axi_arvalid = 1'b0;
      s_axi_araddr  = '0;
      s_axi_rready  = 1'b1;
      ap_done       = 1'b0;
      ap_ready      = 1'b0;
      ap_idle       = 1'b1;
    end
  endtask

  task automatic tick();
    begin
      @(posedge clk);
      #1;
    end
  endtask

  task automatic axi_write(input [7:0] addr, input [31:0] data, input [3:0] strb);
    int timeout;
    begin
      s_axi_awaddr  = addr;
      s_axi_awvalid = 1'b1;
      timeout = 16;
      while (!s_axi_awready) begin
        if (timeout == 0)
          $fatal(1, "AW channel timeout");
        timeout--;
        tick();
      end
      tick();
      s_axi_awvalid = 1'b0;
      s_axi_awaddr  = '0;

      s_axi_wdata   = data;
      s_axi_wstrb   = strb;
      s_axi_wvalid  = 1'b1;
      timeout = 16;
      while (!s_axi_wready) begin
        if (timeout == 0)
          $fatal(1, "W channel timeout");
        timeout--;
        tick();
      end
      tick();
      if (addr == ADDR_AP_CTRL && strb[0] && data[4] && ap_reset !== 1'b1)
        $fatal(1, "soft reset should pulse ap_reset");
      s_axi_wvalid = 1'b0;
      s_axi_wdata  = '0;
      s_axi_wstrb  = '0;

      timeout = 16;
      while (!s_axi_bvalid) begin
        if (timeout == 0)
          $fatal(1, "B response timeout");
        timeout--;
        tick();
      end
      if (!s_axi_bvalid || s_axi_bresp != 2'b00)
        $fatal(1, "B response missing or not OKAY");
      tick();
    end
  endtask

  task automatic axi_read(input [7:0] addr, output [31:0] data);
    int timeout;
    begin
      s_axi_araddr  = addr;
      s_axi_arvalid = 1'b1;
      timeout = 16;
      while (!s_axi_arready) begin
        if (timeout == 0)
          $fatal(1, "AR channel timeout");
        timeout--;
        tick();
      end
      tick();
      s_axi_arvalid = 1'b0;
      s_axi_araddr  = '0;

      timeout = 16;
      while (!s_axi_rvalid) begin
        if (timeout == 0)
          $fatal(1, "R response timeout");
        timeout--;
        tick();
      end
      if (!s_axi_rvalid || s_axi_rresp != 2'b00)
        $fatal(1, "R response missing or not OKAY");
      data = s_axi_rdata;
      tick();
    end
  endtask

  logic [31:0] ctrl;
  logic [31:0] gie;
  logic [31:0] ier;

  initial begin
    clear_inputs();
    repeat (3) tick();
    reset = 1'b0;
    tick();

    axi_write(ADDR_GIE, 32'h1, 4'h1);
    axi_write(ADDR_IER, 32'h3, 4'h1);
    axi_write(ADDR_AP_CTRL, 32'h81, 4'h1);
    if (ap_start !== 1'b1)
      $fatal(1, "ap_start should be set before soft reset");

    axi_write(ADDR_AP_CTRL, 32'h10, 4'h1);
    if (ap_reset !== 1'b0)
      $fatal(1, "ap_reset should self-clear after write response");

    axi_read(ADDR_AP_CTRL, ctrl);
    if (ctrl[0] !== 1'b0)
      $fatal(1, "soft reset should clear ap_start");
    if (ctrl[7] !== 1'b0)
      $fatal(1, "soft reset should clear auto_restart");

    axi_read(ADDR_GIE, gie);
    if (gie[0] !== 1'b1)
      $fatal(1, "soft reset should preserve GIE");
    axi_read(ADDR_IER, ier);
    if (ier[1:0] !== 2'b11)
      $fatal(1, "soft reset should preserve IER");

    $display("PASS");
    $finish;
  end

endmodule
