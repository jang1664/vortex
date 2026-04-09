`timescale 1ns / 1ps
`include "VX_define.vh"

module tb_VX_tensor_mem_bank import VX_gpu_pkg::*; ();

  localparam int PERIOD     = 10;
  localparam int NUM_PORTS  = 5;
  localparam int DATA_SIZE  = 8;     // 64-bit beats for readable checks
  localparam int TAG_WIDTH  = 8;
  localparam int BANK_BYTES = 1024;
  localparam int DATA_WIDTH = DATA_SIZE * 8;
  localparam int ADDR_WIDTH = `MEM_ADDR_WIDTH - `CLOG2(DATA_SIZE);
  localparam int TAG_VAL_W  = TAG_WIDTH - `UP(UUID_WIDTH);

  logic clk   = 1'b0;
  logic reset = 1'b1;

  always #(PERIOD / 2) clk = ~clk;

  VX_mem_bus_if #(
      .DATA_SIZE (DATA_SIZE),
      .TAG_WIDTH (TAG_WIDTH)
  ) mem_bus_if [NUM_PORTS] ();

  VX_tensor_mem_bank #(
      .INSTANCE_ID ("tb_tensor_mem_bank"),
      .SIZE        (BANK_BYTES),
      .DATA_SIZE   (DATA_SIZE),
      .NUM_PORTS   (NUM_PORTS),
      .TAG_WIDTH   (TAG_WIDTH)
  ) dut (
      .clk        (clk),
      .reset      (reset),
      .mem_bus_if (mem_bus_if)
  );

  logic [NUM_PORTS-1:0]                  req_valid;
  logic [NUM_PORTS-1:0]                  req_rw;
  logic [NUM_PORTS-1:0][ADDR_WIDTH-1:0]  req_addr;
  logic [NUM_PORTS-1:0][DATA_WIDTH-1:0]  req_data;
  logic [NUM_PORTS-1:0][DATA_SIZE-1:0]   req_byteen;
  logic [NUM_PORTS-1:0][MEM_FLAGS_WIDTH-1:0] req_flags;
  logic [NUM_PORTS-1:0][TAG_WIDTH-1:0]   req_tag;
  logic [NUM_PORTS-1:0]                  req_ready;

  logic [NUM_PORTS-1:0]                  rsp_valid;
  logic [NUM_PORTS-1:0][DATA_WIDTH-1:0]  rsp_data;
  logic [NUM_PORTS-1:0][TAG_WIDTH-1:0]   rsp_tag;
  logic [NUM_PORTS-1:0]                  rsp_ready;

  for (genvar p = 0; p < NUM_PORTS; ++p) begin : g_bus_bind
    assign mem_bus_if[p].req_valid       = req_valid[p];
    assign mem_bus_if[p].req_data.rw     = req_rw[p];
    assign mem_bus_if[p].req_data.addr   = req_addr[p];
    assign mem_bus_if[p].req_data.data   = req_data[p];
    assign mem_bus_if[p].req_data.byteen = req_byteen[p];
    assign mem_bus_if[p].req_data.flags  = req_flags[p];
    assign mem_bus_if[p].req_data.tag.uuid = req_tag[p][TAG_WIDTH-1 -: `UP(UUID_WIDTH)];
    if (TAG_VAL_W > 0) begin : g_tag_val_req
      assign mem_bus_if[p].req_data.tag.value = req_tag[p][TAG_VAL_W-1:0];
    end

    assign req_ready[p] = mem_bus_if[p].req_ready;

    assign rsp_valid[p] = mem_bus_if[p].rsp_valid;
    assign rsp_data[p]  = mem_bus_if[p].rsp_data.data;
    if (TAG_VAL_W > 0) begin : g_tag_val_rsp
      assign rsp_tag[p] = {mem_bus_if[p].rsp_data.tag.uuid, mem_bus_if[p].rsp_data.tag.value};
    end else begin : g_tag_val_rsp0
      assign rsp_tag[p] = mem_bus_if[p].rsp_data.tag.uuid;
    end
    assign mem_bus_if[p].rsp_ready = rsp_ready[p];
  end

  function automatic logic [TAG_WIDTH-1:0] mk_tag(input logic [TAG_WIDTH-1:0] t);
    return t;
  endfunction

  task automatic init_ports;
    for (int p = 0; p < NUM_PORTS; ++p) begin
      req_valid[p]   = 1'b0;
      req_rw[p]      = 1'b0;
      req_addr[p]    = '0;
      req_data[p]    = '0;
      req_byteen[p]  = '0;
      req_flags[p]   = '0;
      req_tag[p]     = '0;
      rsp_ready[p]   = 1'b1;
    end
  endtask

  task automatic set_req(
      input int p,
      input logic rw,
      input logic [ADDR_WIDTH-1:0] addr,
      input logic [DATA_WIDTH-1:0] data,
      input logic [DATA_SIZE-1:0] byteen,
      input logic [TAG_WIDTH-1:0] tag
  );
    req_valid[p]  = 1'b1;
    req_rw[p]     = rw;
    req_addr[p]   = addr;
    req_data[p]   = data;
    req_byteen[p] = byteen;
    req_flags[p]  = '0;
    req_tag[p]    = tag;
  endtask

  task automatic clear_req(input int p);
    req_valid[p]  = 1'b0;
    req_rw[p]     = 1'b0;
    req_addr[p]   = '0;
    req_data[p]   = '0;
    req_byteen[p] = '0;
    req_flags[p]  = '0;
    req_tag[p]    = '0;
  endtask

  task automatic wait_req_accept(input int p, input string msg);
    bit accepted;
    accepted = 1'b0;
    for (int t = 0; t < 80; ++t) begin
      @(posedge clk);
      if (req_valid[p] && req_ready[p]) begin
        accepted = 1'b1;
        break;
      end
    end
    if (!accepted) begin
      $fatal(1, "%s: request timeout on port %0d", msg, p);
    end
  endtask

  task automatic check_rsp(
      input int p,
      input logic [TAG_WIDTH-1:0] exp_tag,
      input logic [DATA_WIDTH-1:0] exp_data,
      input string msg
  );
    bit seen;
    logic [TAG_WIDTH-1:0] got_tag;
    seen = 1'b0;
    for (int t = 0; t < 80; ++t) begin
      @(posedge clk);
      if (rsp_valid[p]) begin
        seen = 1'b1;
        got_tag = rsp_tag[p];
        if (got_tag !== exp_tag) begin
          $fatal(1, "%s: tag mismatch on p%0d exp=0x%0h got=0x%0h", msg, p, exp_tag, got_tag);
        end
        if (rsp_data[p] !== exp_data) begin
          $fatal(1, "%s: data mismatch on p%0d exp=0x%0h got=0x%0h", msg, p, exp_data, rsp_data[p]);
        end
        break;
      end
    end
    if (!seen) begin
      $fatal(1, "%s: response timeout on port %0d", msg, p);
    end
  endtask

  task automatic do_write(
      input int p,
      input logic [ADDR_WIDTH-1:0] addr,
      input logic [DATA_WIDTH-1:0] data,
      input logic [DATA_SIZE-1:0] byteen,
      input logic [TAG_WIDTH-1:0] tag,
      input string msg
  );
    set_req(p, 1'b1, addr, data, byteen, tag);
    wait_req_accept(p, msg);
    @(negedge clk);
    clear_req(p);
    check_rsp(p, tag, '0, msg);
  endtask

  task automatic do_read(
      input int p,
      input logic [ADDR_WIDTH-1:0] addr,
      input logic [TAG_WIDTH-1:0] tag,
      input logic [DATA_WIDTH-1:0] exp_data,
      input string msg
  );
    set_req(p, 1'b0, addr, '0, '0, tag);
    wait_req_accept(p, msg);
    @(negedge clk);
    clear_req(p);
    check_rsp(p, tag, exp_data, msg);
  endtask

  initial begin
    logic [DATA_WIDTH-1:0] w0;
    logic [DATA_WIDTH-1:0] w1;
    logic [DATA_WIDTH-1:0] exp_partial;
    int blocked_cycles;

    init_ports();

    repeat (5) @(posedge clk);
    reset = 1'b0;
    repeat (2) @(posedge clk);

    // 1) Basic write/read
    w0 = 64'h1122_3344_5566_7788;
    do_write(0, ADDR_WIDTH'(4), w0, 8'hFF, mk_tag(8'h11), "basic_write");
    do_read (0, ADDR_WIDTH'(4), mk_tag(8'h12), w0, "basic_read");

    // 2) Cross-port visibility + byte-enable update
    do_read (3, ADDR_WIDTH'(4), mk_tag(8'h13), w0, "cross_port_read_before_partial");
    w1 = 64'hAABB_CCDD_EEFF_0011;
    do_write(1, ADDR_WIDTH'(4), w1, 8'b0000_1111, mk_tag(8'h21), "partial_write");
    exp_partial = (w0 & 64'hFFFF_FFFF_0000_0000) | (w1 & 64'h0000_0000_FFFF_FFFF);
    do_read (2, ADDR_WIDTH'(4), mk_tag(8'h22), exp_partial, "partial_readback");

    // 3) Concurrent reads from multiple ports (arbiter exercise)
    do_write(0, ADDR_WIDTH'(8), 64'h0102_0304_0506_0708, 8'hFF, mk_tag(8'h30), "prep_a");
    do_write(0, ADDR_WIDTH'(9), 64'h1112_1314_1516_1718, 8'hFF, mk_tag(8'h31), "prep_b");
    do_write(0, ADDR_WIDTH'(10),64'h2122_2324_2526_2728, 8'hFF, mk_tag(8'h32), "prep_c");
    do_write(0, ADDR_WIDTH'(11),64'h3132_3334_3536_3738, 8'hFF, mk_tag(8'h33), "prep_d");

    fork
      do_read(0, ADDR_WIDTH'(8),  mk_tag(8'h40), 64'h0102_0304_0506_0708, "concurrent_p0");
      do_read(1, ADDR_WIDTH'(9),  mk_tag(8'h41), 64'h1112_1314_1516_1718, "concurrent_p1");
      do_read(2, ADDR_WIDTH'(10), mk_tag(8'h42), 64'h2122_2324_2526_2728, "concurrent_p2");
      do_read(3, ADDR_WIDTH'(11), mk_tag(8'h43), 64'h3132_3334_3536_3738, "concurrent_p3");
    join

    // 4) Response backpressure should block new request acceptance
    rsp_ready[4] = 1'b1;
    set_req(4, 1'b0, ADDR_WIDTH'(8), '0, '0, mk_tag(8'h50));
    wait_req_accept(4, "bp_issue");
    @(negedge clk);
    clear_req(4);
    rsp_ready[4] = 1'b0;

    // Wait until response appears and remains stalled.
    wait (rsp_valid[4] == 1'b1);
    if (rsp_data[4] !== 64'h0102_0304_0506_0708) begin
      $fatal(1, "bp_rsp_data mismatch exp=0x0102030405060708 got=0x%0h", rsp_data[4]);
    end

    // Try issuing from another port while stalled; expect it to be blocked.
    set_req(0, 1'b0, ADDR_WIDTH'(9), '0, '0, mk_tag(8'h51));
    blocked_cycles = 0;
    repeat (4) begin
      @(posedge clk);
      if (!req_ready[0])
        blocked_cycles++;
    end
    if (blocked_cycles == 0) begin
      $fatal(1, "backpressure check failed: port0 was never blocked");
    end

    // Release stalled response and complete the pending read.
    rsp_ready[4] = 1'b1;
    wait_req_accept(0, "bp_followup_accept");
    @(negedge clk);
    clear_req(0);
    check_rsp(0, mk_tag(8'h51), 64'h1112_1314_1516_1718, "bp_followup_rsp");
    rsp_ready[4] = 1'b1;

    $display("%0t [tb_VX_tensor_mem_bank] all checks passed", $time);
    $display("TEST PASSED");
    $finish;
  end

endmodule
