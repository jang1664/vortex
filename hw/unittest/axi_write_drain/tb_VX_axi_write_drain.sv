`timescale 1ns / 1ps

module tb_VX_axi_write_drain ();

  localparam int PERIOD        = 10;
  localparam int COUNT_WIDTH   = 16;
  localparam int PENDING_WIDTH = 8;

  logic clk = 1'b0;
  logic reset = 1'b1;

  logic       awvalid;
  logic       awready;
  logic [7:0] awlen;
  logic       wvalid;
  logic       wready;
  logic       wlast;
  logic       bvalid;
  logic       bready;

  wire        aw_fire;
  wire        w_fire;
  wire        wlast_fire;
  wire        b_fire;
  wire        pending_empty;
  wire [COUNT_WIDTH-1:0] aw_handshake_cnt;
  wire [COUNT_WIDTH-1:0] aw_burst_total_cnt;
  wire [COUNT_WIDTH-1:0] w_handshake_cnt;
  wire [COUNT_WIDTH-1:0] wlast_cnt;
  wire [COUNT_WIDTH-1:0] b_handshake_cnt;
  wire [PENDING_WIDTH-1:0] pending_writes;

  always #(PERIOD / 2) clk <= ~clk;

  VX_axi_write_drain #(
      .COUNT_WIDTH   (COUNT_WIDTH),
      .PENDING_WIDTH (PENDING_WIDTH)
  ) dut (
      .clk                (clk),
      .reset              (reset),
      .awvalid            (awvalid),
      .awready            (awready),
      .awlen              (awlen),
      .wvalid             (wvalid),
      .wready             (wready),
      .wlast              (wlast),
      .bvalid             (bvalid),
      .bready             (bready),
      .aw_fire            (aw_fire),
      .w_fire             (w_fire),
      .wlast_fire         (wlast_fire),
      .b_fire             (b_fire),
      .pending_empty      (pending_empty),
      .aw_handshake_cnt   (aw_handshake_cnt),
      .aw_burst_total_cnt (aw_burst_total_cnt),
      .w_handshake_cnt    (w_handshake_cnt),
      .wlast_cnt          (wlast_cnt),
      .b_handshake_cnt    (b_handshake_cnt),
      .pending_writes     (pending_writes)
  );

  task automatic clear_inputs();
    begin
      awvalid = 1'b0;
      awready = 1'b1;
      awlen   = '0;
      wvalid  = 1'b0;
      wready  = 1'b1;
      wlast   = 1'b0;
      bvalid  = 1'b0;
      bready  = 1'b1;
    end
  endtask

  task automatic tick();
    begin
      @(posedge clk);
      #1;
      if (aw_fire !== (awvalid && awready))
        $fatal(1, "aw_fire mismatch");
      if (w_fire !== (wvalid && wready))
        $fatal(1, "w_fire mismatch");
      if (wlast_fire !== (wvalid && wready && wlast))
        $fatal(1, "wlast_fire mismatch");
      if (b_fire !== (bvalid && bready))
        $fatal(1, "b_fire mismatch");
    end
  endtask

  task automatic expect_counts(
    input [COUNT_WIDTH-1:0] exp_aw,
    input [COUNT_WIDTH-1:0] exp_aw_beats,
    input [COUNT_WIDTH-1:0] exp_w,
    input [COUNT_WIDTH-1:0] exp_wlast,
    input [COUNT_WIDTH-1:0] exp_b,
    input                   exp_empty
  );
    begin
      if (aw_handshake_cnt !== exp_aw)
        $fatal(1, "aw_handshake_cnt expected %0d got %0d", exp_aw, aw_handshake_cnt);
      if (aw_burst_total_cnt !== exp_aw_beats)
        $fatal(1, "aw_burst_total_cnt expected %0d got %0d", exp_aw_beats, aw_burst_total_cnt);
      if (w_handshake_cnt !== exp_w)
        $fatal(1, "w_handshake_cnt expected %0d got %0d", exp_w, w_handshake_cnt);
      if (wlast_cnt !== exp_wlast)
        $fatal(1, "wlast_cnt expected %0d got %0d", exp_wlast, wlast_cnt);
      if (b_handshake_cnt !== exp_b)
        $fatal(1, "b_handshake_cnt expected %0d got %0d", exp_b, b_handshake_cnt);
      if (pending_writes !== PENDING_WIDTH'(exp_aw - exp_b))
        $fatal(1, "pending_writes expected %0d got %0d", exp_aw - exp_b, pending_writes);
      if (pending_empty !== exp_empty)
        $fatal(1, "pending_empty expected %0d got %0d", exp_empty, pending_empty);
    end
  endtask

  initial begin
    clear_inputs();
    repeat (2) tick();
    reset = 1'b0;
    tick();
    expect_counts(0, 0, 0, 0, 0, 1'b1);

    // AW can lead W by several transactions. The old latch-based helper could
    // collapse these into one remembered AW.
    awvalid = 1'b1;
    awlen = 8'd0;
    repeat (3) tick();
    awvalid = 1'b0;
    expect_counts(3, 3, 0, 0, 0, 1'b0);

    wvalid = 1'b1;
    wlast = 1'b1;
    repeat (3) tick();
    wvalid = 1'b0;
    wlast = 1'b0;
    expect_counts(3, 3, 3, 3, 0, 1'b0);

    bvalid = 1'b1;
    repeat (3) tick();
    bvalid = 1'b0;
    expect_counts(3, 3, 3, 3, 3, 1'b1);

    // A burst contributes AWLEN+1 expected W beats, one WLAST, and one B.
    awvalid = 1'b1;
    awlen = 8'd3;
    tick();
    awvalid = 1'b0;
    awlen = '0;
    expect_counts(4, 7, 3, 3, 3, 1'b0);

    wvalid = 1'b1;
    wlast = 1'b0;
    repeat (3) tick();
    wlast = 1'b1;
    tick();
    wvalid = 1'b0;
    wlast = 1'b0;
    expect_counts(4, 7, 7, 4, 3, 1'b0);

    bvalid = 1'b1;
    tick();
    bvalid = 1'b0;
    expect_counts(4, 7, 7, 4, 4, 1'b1);

    $display("PASS");
    $finish;
  end

endmodule
