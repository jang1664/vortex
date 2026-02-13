`timescale 1ns/1ps
`include "VX_define.vh"

module tb_VX_job_frontend;
  import VX_gpu_pkg::*;

  localparam int NUM_ENTRIES = 4;
  localparam int NUM_REGS32  = 16;
  localparam int ENTRYID_W   = 4;
  localparam int NUM_MASTERS = 2;

  localparam int TB_NUM_LANES = `NUM_LSU_LANES;
  localparam int TB_DATA_SIZE = LSU_WORD_SIZE;
  localparam int TB_TAG_WIDTH = LSU_TAG_WIDTH;

  localparam logic [63:0] TB_CFG_BASE_ADDR = 64'h0;

  localparam int WORDS_PER_BEAT = (TB_DATA_SIZE / 4);
  localparam int NUM_BEATS      = (NUM_REGS32 + WORDS_PER_BEAT - 1) / WORDS_PER_BEAT;
  localparam int ENTRY_BASE_BEAT= 1; // beat0 is global alloc register

  logic clk, reset;

  initial clk = 1'b0;
  always #5 clk = ~clk;

  VX_lsu_mem_if #(
    .NUM_LANES (TB_NUM_LANES),
    .DATA_SIZE (TB_DATA_SIZE),
    .TAG_WIDTH (TB_TAG_WIDTH)
  ) mmio_if[NUM_MASTERS]();

  VX_config_reg_if #(
    .NUM (NUM_REGS32),
    .DW  (32)
  ) issue_if();

  VX_node_done_if done_if();

  logic [NUM_MASTERS-1:0] mmio_rsp_ready;

  for (genvar m = 0; m < NUM_MASTERS; ++m) begin : g_mmio_rsp_ready
    assign mmio_if[m].rsp_ready = mmio_rsp_ready[m];
  end

  VX_job_frontend #(
    .INSTANCE_ID("tb_job_frontend"),
    .NUM_MASTERS(NUM_MASTERS),
    .NUM_ENTRIES(NUM_ENTRIES),
    .NUM_REGS32 (NUM_REGS32),
    .ENTRYID_W  (ENTRYID_W),
    .CFG_BASE_ADDR(TB_CFG_BASE_ADDR)
  ) dut (
    .clk(clk),
    .reset(reset),
    .mmio_if(mmio_if),
    .issue_if(issue_if),
    .done_if(done_if)
  );

  function automatic logic [mmio_if[0].ADDR_WIDTH-1:0] alloc_addr();
    return mmio_if[0].ADDR_WIDTH'(0);
  endfunction

  function automatic logic [mmio_if[0].ADDR_WIDTH-1:0] entry_beat_addr(input int entry, input int beat_idx);
    logic [mmio_if[0].ADDR_WIDTH-1:0] a;
    begin
      a = mmio_if[0].ADDR_WIDTH'(ENTRY_BASE_BEAT)
        + mmio_if[0].ADDR_WIDTH'(entry * NUM_BEATS)
        + mmio_if[0].ADDR_WIDTH'(beat_idx);
      return a;
    end
  endfunction

  task automatic do_reset();
    begin
      reset = 1'b1;

      mmio_if[0].req_valid = 1'b0;
      mmio_if[0].req_data  = '0;
      mmio_if[1].req_valid = 1'b0;
      mmio_if[1].req_data  = '0;
      mmio_rsp_ready       = '1;

      issue_if.ready = 1'b0;

      done_if.valid    = 1'b0;
      done_if.entry_id = '0;

      repeat (5) @(posedge clk);
      reset = 1'b0;
      repeat (2) @(posedge clk);
    end
  endtask

  task automatic mmio_write_multilane_m0(
    input logic [TB_NUM_LANES-1:0] lane_mask,
    input logic [TB_NUM_LANES-1:0][mmio_if[0].ADDR_WIDTH-1:0] lane_addr,
    input logic [TB_NUM_LANES-1:0][TB_DATA_SIZE*8-1:0] lane_data,
    input logic [TB_NUM_LANES-1:0][TB_DATA_SIZE-1:0] lane_byteen
  );
    int guard;
    begin
      mmio_if[0].req_data          = '0;
      mmio_if[0].req_data.rw       = 1'b1;
      mmio_if[0].req_data.mask     = lane_mask;
      mmio_if[0].req_data.addr     = lane_addr;
      mmio_if[0].req_data.data     = lane_data;
      mmio_if[0].req_data.byteen   = lane_byteen;

      @(negedge clk);
      mmio_if[0].req_valid = 1'b1;
      guard = 0;
      while (!(mmio_if[0].req_valid && mmio_if[0].req_ready)) begin
        @(posedge clk);
        guard++;
        if (guard > 200) $fatal(1, "mmio_write_multilane_m0 timeout waiting req_ready");
      end
      @(negedge clk); // deassert after handshake edge
      mmio_if[0].req_valid = 1'b0;
      @(posedge clk);
    end
  endtask

  task automatic mmio_write_lane0(
    input logic [mmio_if[0].ADDR_WIDTH-1:0] addr,
    input logic [TB_DATA_SIZE*8-1:0]     data,
    input logic [TB_DATA_SIZE-1:0]       byteen
  );
    int guard;
    begin
      mmio_if[0].req_data        = '0;
      mmio_if[0].req_data.rw     = 1'b1;
      mmio_if[0].req_data.mask   = '0;
      mmio_if[0].req_data.mask[0]= 1'b1;
      mmio_if[0].req_data.addr[0]= addr;
      mmio_if[0].req_data.data[0]= data;
      mmio_if[0].req_data.byteen[0] = byteen;

      @(negedge clk);
      mmio_if[0].req_valid = 1'b1;
      guard = 0;
      while (!(mmio_if[0].req_valid && mmio_if[0].req_ready)) begin
        @(posedge clk);
        guard++;
        if (guard > 200) $fatal(1, "mmio_write_lane0 timeout waiting req_ready");
      end
      @(negedge clk); // deassert after handshake edge
      mmio_if[0].req_valid = 1'b0;
      @(posedge clk);
    end
  endtask

  task automatic mmio_write_lane0_m1(
    input logic [mmio_if[1].ADDR_WIDTH-1:0] addr,
    input logic [TB_DATA_SIZE*8-1:0]        data,
    input logic [TB_DATA_SIZE-1:0]          byteen
  );
    int guard;
    begin
      mmio_if[1].req_data          = '0;
      mmio_if[1].req_data.rw       = 1'b1;
      mmio_if[1].req_data.mask     = '0;
      mmio_if[1].req_data.mask[0]  = 1'b1;
      mmio_if[1].req_data.addr[0]  = addr;
      mmio_if[1].req_data.data[0]  = data;
      mmio_if[1].req_data.byteen[0]= byteen;

      @(negedge clk);
      mmio_if[1].req_valid = 1'b1;
      guard = 0;
      while (!(mmio_if[1].req_valid && mmio_if[1].req_ready)) begin
        @(posedge clk);
        guard++;
        if (guard > 200) $fatal(1, "mmio_write_lane0_m1 timeout waiting req_ready");
      end
      @(negedge clk); // deassert after handshake edge
      mmio_if[1].req_valid = 1'b0;
      @(posedge clk);
    end
  endtask

  task automatic mmio_dual_master_write_lane0_sync(
    input logic [mmio_if[0].ADDR_WIDTH-1:0] addr0,
    input logic [TB_DATA_SIZE*8-1:0]        data0,
    input logic [TB_DATA_SIZE-1:0]          byteen0,
    input logic [mmio_if[1].ADDR_WIDTH-1:0] addr1,
    input logic [TB_DATA_SIZE*8-1:0]        data1,
    input logic [TB_DATA_SIZE-1:0]          byteen1
  );
    int guard;
    logic done0, done1;
    begin
      mmio_if[0].req_data          = '0;
      mmio_if[0].req_data.rw       = 1'b1;
      mmio_if[0].req_data.mask     = '0;
      mmio_if[0].req_data.mask[0]  = 1'b1;
      mmio_if[0].req_data.addr[0]  = addr0;
      mmio_if[0].req_data.data[0]  = data0;
      mmio_if[0].req_data.byteen[0]= byteen0;

      mmio_if[1].req_data          = '0;
      mmio_if[1].req_data.rw       = 1'b1;
      mmio_if[1].req_data.mask     = '0;
      mmio_if[1].req_data.mask[0]  = 1'b1;
      mmio_if[1].req_data.addr[0]  = addr1;
      mmio_if[1].req_data.data[0]  = data1;
      mmio_if[1].req_data.byteen[0]= byteen1;

      @(negedge clk);
      mmio_if[0].req_valid = 1'b1;
      mmio_if[1].req_valid = 1'b1;

      done0 = 1'b0;
      done1 = 1'b0;
      guard = 0;
      while (!(done0 && done1)) begin
        @(posedge clk);
        if (!done0 && mmio_if[0].req_valid && mmio_if[0].req_ready) done0 = 1'b1;
        if (!done1 && mmio_if[1].req_valid && mmio_if[1].req_ready) done1 = 1'b1;

        guard++;
        if (guard > 200) $fatal(1, "mmio_dual_master_write_lane0_sync timeout waiting req_ready");

        @(negedge clk);
        if (done0) mmio_if[0].req_valid = 1'b0;
        if (done1) mmio_if[1].req_valid = 1'b0;
      end

      @(posedge clk);
    end
  endtask

  task automatic mmio_read_lane0(
    input  logic [mmio_if[0].ADDR_WIDTH-1:0] addr,
    output logic [TB_DATA_SIZE*8-1:0]     data
  );
    int guard;
    begin
      mmio_if[0].req_data        = '0;
      mmio_if[0].req_data.rw     = 1'b0;
      mmio_if[0].req_data.mask   = '0;
      mmio_if[0].req_data.mask[0]= 1'b1;
      mmio_if[0].req_data.addr[0]= addr;

      @(negedge clk);
      mmio_if[0].req_valid = 1'b1;
      guard = 0;
      while (!(mmio_if[0].req_valid && mmio_if[0].req_ready)) begin
        @(posedge clk);
        guard++;
        if (guard > 200) $fatal(1, "mmio_read_lane0 timeout waiting req_ready");
      end
      @(negedge clk); // deassert after handshake edge
      mmio_if[0].req_valid = 1'b0;

      if (!mmio_if[0].rsp_valid) begin
        guard = 0;
        do begin
          @(posedge clk);
          guard++;
          if (guard > 200) $fatal(1, "mmio_read_lane0 timeout waiting rsp_valid");
        end while (!mmio_if[0].rsp_valid);
      end
      data = mmio_if[0].rsp_data.data[0];
    end
  endtask

  task automatic check_rsp_hold(input logic [mmio_if[0].ADDR_WIDTH-1:0] addr);
    int guard;
    logic [TB_DATA_SIZE*8-1:0] hold_data;
    begin
      mmio_rsp_ready[0] = 1'b0;

      mmio_if[0].req_data        = '0;
      mmio_if[0].req_data.rw     = 1'b0;
      mmio_if[0].req_data.mask   = '0;
      mmio_if[0].req_data.mask[0]= 1'b1;
      mmio_if[0].req_data.addr[0]= addr;

      @(negedge clk);
      mmio_if[0].req_valid = 1'b1;
      guard = 0;
      while (!(mmio_if[0].req_valid && mmio_if[0].req_ready)) begin
        @(posedge clk);
        guard++;
        if (guard > 200) $fatal(1, "check_rsp_hold timeout waiting req_ready");
      end
      @(negedge clk); // deassert after handshake edge
      mmio_if[0].req_valid = 1'b0;

      guard = 0;
      do begin
        @(posedge clk);
        guard++;
        if (guard > 200) $fatal(1, "check_rsp_hold timeout waiting rsp_valid");
      end while (!mmio_if[0].rsp_valid);

      hold_data = mmio_if[0].rsp_data.data[0];
      repeat (3) begin
        @(posedge clk);
        if (!mmio_if[0].rsp_valid)
          $fatal(1, "rsp_valid dropped while rsp_ready=0");
        if (mmio_if[0].rsp_data.data[0] !== hold_data)
          $fatal(1, "rsp_data changed while rsp_ready=0");
      end

      mmio_rsp_ready[0] = 1'b1;

      @(posedge clk);
      if (mmio_if[0].rsp_valid) begin
        @(posedge clk);
      end
      if (mmio_if[0].rsp_valid)
        $fatal(1, "rsp_valid did not clear after rsp_ready=1");
    end
  endtask

  task automatic alloc_try(
    output logic success,
    output int   entry_id
  );
    logic [TB_DATA_SIZE*8-1:0] rd;
    logic [31:0] w;
    begin
      mmio_read_lane0(alloc_addr(), rd);
      w = rd[31:0];
      success  = w[0];
      entry_id = int'(w[ENTRYID_W:1]);
      $display("[%0t] ALLOC success=%0d entry=%0d", $time, success, entry_id);
    end
  endtask

  task automatic set_entry_valid(input int entry);
    logic [TB_DATA_SIZE*8-1:0] beat0;
    logic [31:0] w0;
    begin
      mmio_read_lane0(entry_beat_addr(entry, 0), beat0);
      w0 = beat0[31:0];
      w0[0] = 1'b1;
      beat0[31:0] = w0;
      mmio_write_lane0(entry_beat_addr(entry, 0), beat0, '1);
    end
  endtask

  task automatic read_control_word(input int entry, output logic [31:0] ctrl);
    logic [TB_DATA_SIZE*8-1:0] beat0;
    begin
      mmio_read_lane0(entry_beat_addr(entry, 0), beat0);
      ctrl = beat0[31:0];
    end
  endtask

  task automatic send_done(input int entry_id);
    begin
      done_if.entry_id = 32'(entry_id);
      done_if.valid    = 1'b1;
      @(posedge clk);
      done_if.valid    = 1'b0;
      $display("[%0t] DONE entry=%0d", $time, entry_id);
    end
  endtask

  int issues_seen;
  int issue_entry_q[$];

  always_ff @(posedge clk) begin
    if (reset) begin
      issues_seen <= 0;
      issue_entry_q.delete();
    end else begin
      if (issue_if.valid && issue_if.ready) begin
        issues_seen <= issues_seen + 1;
        issue_entry_q.push_back(int'(issue_if.entry_id));
        $display("[%0t] ISSUE entry=%0d valid=%0b", $time, int'(issue_if.entry_id), issue_if.regs[0][0]);
      end
    end
  end

  task automatic wait_issues(input int n, input int max_cycles);
    int c;
    begin
      c = 0;
      while (issues_seen < n) begin
        @(posedge clk);
        c++;
        if (c > max_cycles) $fatal(1, "Timeout waiting issues_seen >= %0d (got %0d)", n, issues_seen);
      end
    end
  endtask

  initial begin : test_main
    logic ok;
    int eid;
    int l;
    int ml_used;
    logic [31:0] ctrl;
    logic [TB_DATA_SIZE*8-1:0] rd;
    logic [TB_DATA_SIZE*8-1:0] wr_pat;
    logic [TB_DATA_SIZE*8-1:0] wr_init;
    logic [TB_DATA_SIZE*8-1:0] wr_lo32;
    logic [TB_DATA_SIZE*8-1:0] wr_hi32;
    logic [TB_DATA_SIZE*8-1:0] exp_pat;
    logic [TB_DATA_SIZE*8-1:0] m0_pat, m1_pat;
    logic [TB_NUM_LANES-1:0] ml_mask;
    logic [TB_NUM_LANES-1:0][mmio_if[0].ADDR_WIDTH-1:0] ml_addr;
    logic [TB_NUM_LANES-1:0][TB_DATA_SIZE*8-1:0] ml_data;
    logic [TB_NUM_LANES-1:0][TB_DATA_SIZE-1:0] ml_byteen;

`ifdef VCS
    $fsdbDumpfile("wave.fsdb");
    $fsdbDumpvars(0, "+all", "+parameter", "+functions");
`else
    $dumpfile("wave.fst");
    $dumpvars(0, tb_VX_job_frontend);
`endif

    do_reset();
    if (TB_DATA_SIZE != 8)
      $fatal(1, "This test expects LSU word size=64b (TB_DATA_SIZE=8). Build with XLEN_64.");
    if (TB_NUM_LANES < 2)
      $fatal(1, "This test expects TB_NUM_LANES >= 2 for multi-lane write check");
    if (NUM_MASTERS < 2)
      $fatal(1, "This test expects NUM_MASTERS >= 2 for arbitration check");

    // 1) Global ALLOC RR: expect 0,1,2,3 then fail
    alloc_try(ok, eid); if (!ok || eid != 0) $fatal(1, "alloc #0 mismatch");
    alloc_try(ok, eid); if (!ok || eid != 1) $fatal(1, "alloc #1 mismatch");
    alloc_try(ok, eid); if (!ok || eid != 2) $fatal(1, "alloc #2 mismatch");
    alloc_try(ok, eid); if (!ok || eid != 3) $fatal(1, "alloc #3 mismatch");
    alloc_try(ok, eid); if (ok)             $fatal(1, "alloc must fail when full");

    // 2) Basic MMIO write/read sanity on entry2 beat1
    wr_pat = (TB_DATA_SIZE*8)'(64'h1122_3344_AABB_CCDD);
    mmio_write_lane0(entry_beat_addr(2, 1), wr_pat, '1);
    mmio_read_lane0(entry_beat_addr(2, 1), rd);
    if (rd !== wr_pat)
      $fatal(1, "entry2 beat1 readback mismatch: got 0x%0h", rd);

    // 2b) 64b beat + byteen partial update: write one 32b reg at a time
    wr_init = (TB_DATA_SIZE*8)'(64'hDEAD_BEEF_CAFE_BABE);
    wr_lo32 = (TB_DATA_SIZE*8)'(64'h0000_0000_1234_5678);
    wr_hi32 = (TB_DATA_SIZE*8)'(64'h89AB_CDEF_0000_0000);
    mmio_write_lane0(entry_beat_addr(2, 2), wr_init, TB_DATA_SIZE'(8'hFF));

    mmio_write_lane0(entry_beat_addr(2, 2), wr_lo32, TB_DATA_SIZE'(8'h0F));
    mmio_read_lane0(entry_beat_addr(2, 2), rd);
    exp_pat = (TB_DATA_SIZE*8)'({wr_init[63:32], wr_lo32[31:0]});
    if (rd !== exp_pat)
      $fatal(1, "byteen low32 update mismatch: got=0x%0h exp=0x%0h", rd, exp_pat);

    mmio_write_lane0(entry_beat_addr(2, 2), wr_hi32, TB_DATA_SIZE'(8'hF0));
    mmio_read_lane0(entry_beat_addr(2, 2), rd);
    exp_pat = (TB_DATA_SIZE*8)'({wr_hi32[63:32], wr_lo32[31:0]});
    if (rd !== exp_pat)
      $fatal(1, "byteen high32 update mismatch: got=0x%0h exp=0x%0h", rd, exp_pat);

    // 2c) multi-lane single-request write to normal MMIO region
    ml_mask   = '0;
    ml_addr   = '0;
    ml_data   = '0;
    ml_byteen = '0;
    ml_used   = (TB_NUM_LANES < (NUM_BEATS - 1)) ? TB_NUM_LANES : (NUM_BEATS - 1);
    if (ml_used < 2)
      $fatal(1, "Need at least two writable beats for multi-lane check (NUM_BEATS=%0d)", NUM_BEATS);

    for (l = 0; l < ml_used; l++) begin
      ml_mask[l]   = 1'b1;
      ml_addr[l]   = entry_beat_addr(0, 1 + l); // normal region, not CONTROL beat
      ml_data[l]   = (TB_DATA_SIZE*8)'(64'hABCD_0000_0000_0000 | (64'(l) << 8) | 64'h5A);
      ml_byteen[l] = '1;
    end
    mmio_write_multilane_m0(ml_mask, ml_addr, ml_data, ml_byteen);

    for (l = 0; l < ml_used; l++) begin
      mmio_read_lane0(ml_addr[l], rd);
      if (rd !== ml_data[l])
        $fatal(1, "multi-lane write mismatch lane=%0d got=0x%0h exp=0x%0h", l, rd, ml_data[l]);
    end

    // 2d) multi-master concurrent write arbitration
    m0_pat = (TB_DATA_SIZE*8)'(64'h1111_2222_3333_4444);
    m1_pat = (TB_DATA_SIZE*8)'(64'hAAAA_BBBB_CCCC_DDDD);
    mmio_dual_master_write_lane0_sync(
      entry_beat_addr(1, 1), m0_pat, '1,
      entry_beat_addr(1, 2), m1_pat, '1
    );

    mmio_read_lane0(entry_beat_addr(1, 1), rd);
    if (rd !== m0_pat)
      $fatal(1, "arb write mismatch (master0) got=0x%0h exp=0x%0h", rd, m0_pat);
    mmio_read_lane0(entry_beat_addr(1, 2), rd);
    if (rd !== m1_pat)
      $fatal(1, "arb write mismatch (master1) got=0x%0h exp=0x%0h", rd, m1_pat);

    // 2e) rsp_ready=0: response must be held until handshake
    check_rsp_hold(entry_beat_addr(2, 1));

    // 3) Set valid=1 for all entries while issue is blocked
    set_entry_valid(0);
    set_entry_valid(1);
    set_entry_valid(2);
    set_entry_valid(3);

    // CONTROL[0]=valid, [1]=occupy, [2]=working
    read_control_word(0, ctrl);
    if ((ctrl[0] !== 1'b1) || (ctrl[1] !== 1'b1) || (ctrl[2] !== 1'b0))
      $fatal(1, "entry0 control mismatch before issue: ctrl=0x%08x", ctrl);

    // 4) Enable dispatch and check RR order
    // Drive ready away from posedge to avoid TB/DUT race on handshake sampling.
    @(negedge clk);
    issue_if.ready = 1'b1;
    wait_issues(4, 200);
    if (issue_entry_q[0] != 0 || issue_entry_q[1] != 1 || issue_entry_q[2] != 2 || issue_entry_q[3] != 3)
      $fatal(1, "issue RR mismatch: %0d,%0d,%0d,%0d", issue_entry_q[0], issue_entry_q[1], issue_entry_q[2], issue_entry_q[3]);

    // 5) done clears valid/occupy/working
    send_done(1);
    send_done(3);
    repeat (2) @(posedge clk);

    read_control_word(1, ctrl);
    if ((ctrl[0] !== 1'b0) || (ctrl[1] !== 1'b0) || (ctrl[2] !== 1'b0))
      $fatal(1, "entry1 control mismatch after done: ctrl=0x%08x", ctrl);

    read_control_word(3, ctrl);
    if ((ctrl[0] !== 1'b0) || (ctrl[1] !== 1'b0) || (ctrl[2] !== 1'b0))
      $fatal(1, "entry3 control mismatch after done: ctrl=0x%08x", ctrl);

    // 6) Re-alloc freed entries with RR pointer continuation: 1 then 3
    alloc_try(ok, eid); if (!ok || eid != 1) $fatal(1, "re-alloc #0 mismatch");
    alloc_try(ok, eid); if (!ok || eid != 3) $fatal(1, "re-alloc #1 mismatch");
    alloc_try(ok, eid); if (ok)              $fatal(1, "alloc must fail when full again");

    // valid is SW-owned, so set it again before re-dispatch
    set_entry_valid(1);
    set_entry_valid(3);

    wait_issues(6, 200);
    if (issue_entry_q[4] != 1 || issue_entry_q[5] != 3)
      $fatal(1, "re-issue order mismatch: %0d,%0d", issue_entry_q[4], issue_entry_q[5]);

    $display("====================================");
    $display("PASS: tb_VX_job_frontend");
    $display("====================================");

    #20;
`ifdef VCS
    $fsdbDumpoff();
`else
    $dumpoff();
`endif
    $finish;
  end

endmodule
