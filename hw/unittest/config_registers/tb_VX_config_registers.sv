`timescale 1ns/1ps
`include "VX_define.vh"

// -----------------------------------------------------------------------------
// tb_VX_config_registers.sv  (FULL VERSION)
//
// Verifies end-to-end behavior of VX_config_registers with multi-lane MMIO.
//
// Goals:
//  1) alloc_if Round-Robin (RR): allocate empty entries in RR order
//  2) MMIO beat-split mapping with DATA_SIZE=8 (64b beat => 2x32b regs32):
//     - write/read on beats map to regs32 slots correctly
//  3) Multi-lane MMIO on SAME entry:
//     - one transaction writes 4 beats of the same entry using 4 lanes
//     - one transaction reads 4 beats of the same entry using 4 lanes
//     - 2 transactions cover the whole entry (NUM_BEATS=8)
//  4) Issue RR:
//     - when multiple entries have start=1 (occupy=1, working=0), DUT issues them
//       in RR order (rr_issue pointer), one per (valid&ready) handshake
//  5) Done-by-wid frees the matching entry:
//     - occupy cleared (not directly visible)
//     - CONTROL.start bit cleared (regs32[0][0] => read back beat0 word0 == 0)
//
// Notes / Assumptions (must match your RTL interfaces):
//  - alloc_if: valid, ready, owner_warp, entry_id
//  - mmio_if : req_valid, req_ready, req_data.{mask,addr,data,rw}, rsp_valid, rsp_data.data
//  - dma_issue_if: valid, ready, wid, tid, regs[]
//  - dma_done_if : valid, ready, wid
// -----------------------------------------------------------------------------

module tb_VX_config_registers;
  import VX_gpu_pkg::*;

  localparam int NUM_ENTRIES = 4;
  localparam int NUM_REGS32  = 16;
  localparam int ENTRYID_W   = 8;

  localparam int TB_NUM_LANES = 4;

  // DATA_SIZE=8: 64-bit beat => 2x32b words per beat
  localparam int TB_DATA_SIZE = 8;
  localparam logic [63:0] TB_DMA_CFG_BASE_ADDR = 64'h0;

  // Derived (match DUT math)
  localparam int WORDS_PER_BEAT = (TB_DATA_SIZE / 4); // 2
  localparam int NUM_BEATS      = (NUM_REGS32 + WORDS_PER_BEAT - 1) / WORDS_PER_BEAT; // 8
  localparam int ENTRY_STRIDE_B = NUM_BEATS * TB_DATA_SIZE; // 64 bytes (beat-aligned)
  localparam int LSU_ADDR_SHIFT = $clog2(TB_DATA_SIZE); // 3

  // Clock / Reset
  logic clk, reset;

  initial clk = 1'b0;
  always #5 clk = ~clk; // 10ns period

  // Interfaces
  VX_config_entry_alloc_if alloc_if();

  VX_lsu_mem_if #(
    .NUM_LANES (TB_NUM_LANES),
    .DATA_SIZE (TB_DATA_SIZE),
    .TAG_WIDTH (10)
  ) mmio_if();

  VX_config_reg_if #(
    .NUM (NUM_REGS32),
    .DW  (32)
  ) dma_issue_if();

  VX_node_done_if dma_done_if();

  // DUT
  VX_config_registers #(
    .INSTANCE_ID("tb_cfgregs"),
    .NUM_ENTRIES(NUM_ENTRIES),
    .NUM_REGS32 (NUM_REGS32),
    .ENTRYID_W  (ENTRYID_W),
    .DMA_CFG_BASE_ADDR(TB_DMA_CFG_BASE_ADDR)
  ) dut (
    .clk(clk),
    .reset(reset),
    .alloc_if(alloc_if),
    .mmio_if(mmio_if),
    .dma_issue_if(dma_issue_if),
    .dma_done_if(dma_done_if)
  );

  // -----------------------------
  // Helpers
  // -----------------------------

  // DUT assumes mmio_if.req_data.addr is in units of DATA_SIZE beats
  function automatic logic [mmio_if.ADDR_WIDTH-1:0] mmio_addr_beat(input int entry, input int beat_idx);
    int unsigned a;
    begin
      a = (entry * NUM_BEATS) + beat_idx; // beat address
      return a[mmio_if.ADDR_WIDTH-1:0];
    end
  endfunction

  function automatic logic [TB_DATA_SIZE*8-1:0] pack2(input logic [31:0] w0, input logic [31:0] w1);
    logic [TB_DATA_SIZE*8-1:0] x;
    begin
      x = '0;
      x[ 0 +: 32] = w0;
      x[32 +: 32] = w1;
      return x;
    end
  endfunction

  // 32-bit word index -> beat index
  function automatic int word32_to_beat(input int r32);
    return (r32 / WORDS_PER_BEAT);
  endfunction

  // 32-bit word index -> which 32-bit slot within beat (0..WORDS_PER_BEAT-1)
  function automatic int word32_to_lane_word(input int r32);
    return (r32 % WORDS_PER_BEAT);
  endfunction

  // -----------------------------
  // Reset / Basic drivers
  // -----------------------------
  task automatic do_reset();
    begin
      reset = 1'b1;

      alloc_if.valid      = 1'b0;
      alloc_if.owner_warp = '0;

      mmio_if.req_valid   = 1'b0;
      mmio_if.req_data    = '0;

      dma_done_if.valid   = 1'b0;
      dma_done_if.wid     = '0;

      // Always ready to accept issues (can be toggled later if desired)
      dma_issue_if.ready  = 1'b1;

      repeat (5) @(posedge clk);
      reset = 1'b0;
      repeat (2) @(posedge clk);
    end
  endtask

  // Alloc handshake: ensure at least one posedge happens with valid asserted
  task automatic alloc_one(input logic [31:0] wid, output int entry_id_out);
    int guard;
    begin
      alloc_if.owner_warp = wid;
      alloc_if.valid      = 1'b1;

      @(posedge clk); // ensure time advances with valid high

      guard = 0;
      while (!alloc_if.ready) begin
        @(posedge clk);
        guard++;
        if (guard > 1000) $fatal(1, "ALLOC timeout (wid=%0d).", wid);
      end

      entry_id_out = int'(alloc_if.entry_id);
      alloc_if.valid = 1'b0;

      $display("[%0t] ALLOC wid=%0d -> entry=%0d", $time, wid, entry_id_out);

      @(posedge clk); // spacing
    end
  endtask

  task automatic send_done(input logic [31:0] wid);
    begin
      dma_done_if.wid   = wid;
      dma_done_if.valid = 1'b1;
      @(posedge clk);
      dma_done_if.valid = 1'b0;
      $display("[%0t] DONE wid=%0d", $time, wid);
    end
  endtask

  // -----------------------------
  // Multi-lane MMIO: same entry, different beats per lane (one transaction)
  // -----------------------------
  task automatic mmio_write_entry_4beats_4lanes(
    input int entry,
    input int beat0, input logic [TB_DATA_SIZE*8-1:0] payload0,
    input int beat1, input logic [TB_DATA_SIZE*8-1:0] payload1,
    input int beat2, input logic [TB_DATA_SIZE*8-1:0] payload2,
    input int beat3, input logic [TB_DATA_SIZE*8-1:0] payload3
  );
    begin
      mmio_if.req_data      = '0;
      mmio_if.req_data.rw   = 1'b1;
      mmio_if.req_data.mask = 4'b1111;

      mmio_if.req_data.addr[0] = mmio_addr_beat(entry, beat0);
      mmio_if.req_data.addr[1] = mmio_addr_beat(entry, beat1);
      mmio_if.req_data.addr[2] = mmio_addr_beat(entry, beat2);
      mmio_if.req_data.addr[3] = mmio_addr_beat(entry, beat3);

      mmio_if.req_data.data[0] = payload0;
      mmio_if.req_data.data[1] = payload1;
      mmio_if.req_data.data[2] = payload2;
      mmio_if.req_data.data[3] = payload3;

      mmio_if.req_valid = 1'b1;

      do @(posedge clk); while (!mmio_if.req_ready);
      @(posedge clk);
      mmio_if.req_valid = 1'b0;

      do @(posedge clk); while (!mmio_if.rsp_valid);

      $display("[%0t] MMIO-W entry=%0d beats={%0d,%0d,%0d,%0d}",
               $time, entry, beat0, beat1, beat2, beat3);
    end
  endtask

  task automatic mmio_read_entry_4beats_4lanes(
    input int entry,
    input int beat0, output logic [TB_DATA_SIZE*8-1:0] rd0,
    input int beat1, output logic [TB_DATA_SIZE*8-1:0] rd1,
    input int beat2, output logic [TB_DATA_SIZE*8-1:0] rd2,
    input int beat3, output logic [TB_DATA_SIZE*8-1:0] rd3
  );
    begin
      mmio_if.req_data      = '0;
      mmio_if.req_data.rw   = 1'b0;
      mmio_if.req_data.mask = 4'b1111;

      mmio_if.req_data.addr[0] = mmio_addr_beat(entry, beat0);
      mmio_if.req_data.addr[1] = mmio_addr_beat(entry, beat1);
      mmio_if.req_data.addr[2] = mmio_addr_beat(entry, beat2);
      mmio_if.req_data.addr[3] = mmio_addr_beat(entry, beat3);

      mmio_if.req_valid = 1'b1;

      do @(posedge clk); while (!mmio_if.req_ready);
      @(posedge clk);
      mmio_if.req_valid = 1'b0;

      do @(posedge clk); while (!mmio_if.rsp_valid);

      rd0 = mmio_if.rsp_data.data[0];
      rd1 = mmio_if.rsp_data.data[1];
      rd2 = mmio_if.rsp_data.data[2];
      rd3 = mmio_if.rsp_data.data[3];

      $display("[%0t] MMIO-R entry=%0d beats={%0d,%0d,%0d,%0d}",
               $time, entry, beat0, beat1, beat2, beat3);
    end
  endtask

  // Program a whole entry (all NUM_BEATS beats) in two transactions:
  //  - tx0 writes beats 0..3 using lanes 0..3
  //  - tx1 writes beats 4..7 using lanes 0..3
  task automatic program_full_entry(
    input int entry,
    input logic [TB_DATA_SIZE*8-1:0] beat_payloads[NUM_BEATS-1:0]
  );
    begin
      // beats 0..3
      mmio_write_entry_4beats_4lanes(entry,
        0, beat_payloads[0],
        1, beat_payloads[1],
        2, beat_payloads[2],
        3, beat_payloads[3]
      );
      // beats 4..7
      mmio_write_entry_4beats_4lanes(entry,
        4, beat_payloads[4],
        5, beat_payloads[5],
        6, beat_payloads[6],
        7, beat_payloads[7]
      );
    end
  endtask

  task automatic read_full_entry_and_check(
    input int entry,
    input logic [TB_DATA_SIZE*8-1:0] exp_beats[NUM_BEATS-1:0]
  );
    logic [TB_DATA_SIZE*8-1:0] r0, r1, r2, r3;
    begin
      // beats 0..3
      mmio_read_entry_4beats_4lanes(entry, 0, r0, 1, r1, 2, r2, 3, r3);
      if (r0 !== exp_beats[0]) $fatal(1, "Entry%0d beat0 mismatch: got 0x%0h exp 0x%0h", entry, r0, exp_beats[0]);
      if (r1 !== exp_beats[1]) $fatal(1, "Entry%0d beat1 mismatch: got 0x%0h exp 0x%0h", entry, r1, exp_beats[1]);
      if (r2 !== exp_beats[2]) $fatal(1, "Entry%0d beat2 mismatch: got 0x%0h exp 0x%0h", entry, r2, exp_beats[2]);
      if (r3 !== exp_beats[3]) $fatal(1, "Entry%0d beat3 mismatch: got 0x%0h exp 0x%0h", entry, r3, exp_beats[3]);

      // beats 4..7
      mmio_read_entry_4beats_4lanes(entry, 4, r0, 5, r1, 6, r2, 7, r3);
      if (r0 !== exp_beats[4]) $fatal(1, "Entry%0d beat4 mismatch: got 0x%0h exp 0x%0h", entry, r0, exp_beats[4]);
      if (r1 !== exp_beats[5]) $fatal(1, "Entry%0d beat5 mismatch: got 0x%0h exp 0x%0h", entry, r1, exp_beats[5]);
      if (r2 !== exp_beats[6]) $fatal(1, "Entry%0d beat6 mismatch: got 0x%0h exp 0x%0h", entry, r2, exp_beats[6]);
      if (r3 !== exp_beats[7]) $fatal(1, "Entry%0d beat7 mismatch: got 0x%0h exp 0x%0h", entry, r3, exp_beats[7]);
    end
  endtask

  // -----------------------------
  // ISSUE monitor / scoreboard
  // -----------------------------
  int issues_seen;
  int issue_tid_q[$];
  int issue_wid_q[$];

  always_ff @(posedge clk) begin
    if (reset) begin
      issues_seen <= 0;
      issue_tid_q.delete();
      issue_wid_q.delete();
    end else begin
      if (dma_issue_if.valid && dma_issue_if.ready) begin
        issues_seen <= issues_seen + 1;
        issue_tid_q.push_back(int'(dma_issue_if.tid));
        issue_wid_q.push_back(int'(dma_issue_if.wid));
        $display("[%0t] ISSUE tid=%0d wid=%0d startbit=%0b",
                 $time, int'(dma_issue_if.tid), int'(dma_issue_if.wid),
                 dma_issue_if.regs[0][0]);
      end
    end
  end

  // Helper: wait until we have seen at least N issues (with timeout)
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

  // -----------------------------
  // TEST SEQUENCE (FULL)
  // -----------------------------
  initial begin : test_main
    int e0, e1, e2, e3;

    // For each entry, we will build expected beat payloads[0..7]
    logic [TB_DATA_SIZE*8-1:0] exp0[NUM_BEATS-1:0];
    logic [TB_DATA_SIZE*8-1:0] exp1[NUM_BEATS-1:0];
    logic [TB_DATA_SIZE*8-1:0] exp2[NUM_BEATS-1:0];
    logic [TB_DATA_SIZE*8-1:0] exp3[NUM_BEATS-1:0];

    // readback check after DONE
    logic [TB_DATA_SIZE*8-1:0] r0, r1, r2, r3;

    do_reset();

    // 1) Allocate 4 entries, expect 0,1,2,3
    alloc_one(32'd10, e0);
    alloc_one(32'd11, e1);
    alloc_one(32'd12, e2);
    alloc_one(32'd13, e3);

    if (e0 != 0 || e1 != 1 || e2 != 2 || e3 != 3) begin
      $fatal(1, "ALLOC RR failed: got %0d,%0d,%0d,%0d expected 0,1,2,3", e0, e1, e2, e3);
    end

    // 2) Build payloads for each entry.
    //    Beat0 contains CONTROL in word0; set start=1 there.
    //
    //    Each beat packs {word0, word1} into 64b.
    //    We'll give each entry unique patterns for easy debugging.

    // Entry0 patterns (start=1)
    exp0[0] = pack2(32'h0000_0001, 32'hA0A0_0001);
    exp0[1] = pack2(32'hA0A0_0002, 32'hA0A0_0003);
    exp0[2] = pack2(32'hA0A0_0004, 32'hA0A0_0005);
    exp0[3] = pack2(32'hA0A0_0006, 32'hA0A0_0007);
    exp0[4] = pack2(32'hA0A0_0008, 32'hA0A0_0009);
    exp0[5] = pack2(32'hA0A0_000A, 32'hA0A0_000B);
    exp0[6] = pack2(32'hA0A0_000C, 32'hA0A0_000D);
    exp0[7] = pack2(32'hA0A0_000E, 32'hA0A0_000F);

    // Entry1 patterns (start=1)
    exp1[0] = pack2(32'h0000_0001, 32'hB1B1_0001);
    exp1[1] = pack2(32'hB1B1_0002, 32'hB1B1_0003);
    exp1[2] = pack2(32'hB1B1_0004, 32'hB1B1_0005);
    exp1[3] = pack2(32'hB1B1_0006, 32'hB1B1_0007);
    exp1[4] = pack2(32'hB1B1_0008, 32'hB1B1_0009);
    exp1[5] = pack2(32'hB1B1_000A, 32'hB1B1_000B);
    exp1[6] = pack2(32'hB1B1_000C, 32'hB1B1_000D);
    exp1[7] = pack2(32'hB1B1_000E, 32'hB1B1_000F);

    // Entry2 patterns (start=1)
    exp2[0] = pack2(32'h0000_0001, 32'hC2C2_0001);
    exp2[1] = pack2(32'hC2C2_0002, 32'hC2C2_0003);
    exp2[2] = pack2(32'hC2C2_0004, 32'hC2C2_0005);
    exp2[3] = pack2(32'hC2C2_0006, 32'hC2C2_0007);
    exp2[4] = pack2(32'hC2C2_0008, 32'hC2C2_0009);
    exp2[5] = pack2(32'hC2C2_000A, 32'hC2C2_000B);
    exp2[6] = pack2(32'hC2C2_000C, 32'hC2C2_000D);
    exp2[7] = pack2(32'hC2C2_000E, 32'hC2C2_000F);

    // Entry3 patterns (start=1)
    exp3[0] = pack2(32'h0000_0001, 32'hD3D3_0001);
    exp3[1] = pack2(32'hD3D3_0002, 32'hD3D3_0003);
    exp3[2] = pack2(32'hD3D3_0004, 32'hD3D3_0005);
    exp3[3] = pack2(32'hD3D3_0006, 32'hD3D3_0007);
    exp3[4] = pack2(32'hD3D3_0008, 32'hD3D3_0009);
    exp3[5] = pack2(32'hD3D3_000A, 32'hD3D3_000B);
    exp3[6] = pack2(32'hD3D3_000C, 32'hD3D3_000D);
    exp3[7] = pack2(32'hD3D3_000E, 32'hD3D3_000F);

    // 3) Program full entries using 2 transactions per entry (multi-lane, same entry)
    program_full_entry(e0, exp0);
    program_full_entry(e1, exp1);
    program_full_entry(e2, exp2);
    program_full_entry(e3, exp3);

    // 4) Read back full entries and compare
    read_full_entry_and_check(e0, exp0);
    read_full_entry_and_check(e1, exp1);
    read_full_entry_and_check(e2, exp2);
    read_full_entry_and_check(e3, exp3);

    $display("====================================");
    $display("PASS: full-entry multi-lane MMIO program/readback");
    $display("====================================");

    // 5) ISSUE RR check
    // rr_issue starts at 0 after reset, and all four entries have start=1, occupy=1, working=0.
    // With dma_issue_if.ready=1, expect issues in order 0,1,2,3.
    wait_issues(4, 200);

    if (issue_tid_q.size() < 4) $fatal(1, "ISSUE queue size too small: %0d", issue_tid_q.size());

    if (issue_tid_q[0] != 0 || issue_tid_q[1] != 1 || issue_tid_q[2] != 2 || issue_tid_q[3] != 3) begin
      $fatal(1, "ISSUE RR failed: tids=%0d,%0d,%0d,%0d expected 0,1,2,3",
             issue_tid_q[0], issue_tid_q[1], issue_tid_q[2], issue_tid_q[3]);
    end

    if (issue_wid_q[0] != 10 || issue_wid_q[1] != 11 || issue_wid_q[2] != 12 || issue_wid_q[3] != 13) begin
      $fatal(1, "ISSUE wid mismatch: wids=%0d,%0d,%0d,%0d expected 10,11,12,13",
             issue_wid_q[0], issue_wid_q[1], issue_wid_q[2], issue_wid_q[3]);
    end

    $display("====================================");
    $display("PASS: issue RR order");
    $display("====================================");

    // 6) DONE-by-wid clears start bit (and frees entry)
    // We'll complete wid=11 (entry1) and wid=13 (entry3), then read back beat0 word0==0.
    send_done(32'd11);
    send_done(32'd13);

    // Read beat0 for entry1 and entry3 (use multi-lane read with some dummy beats)
    // lane0: entry1 beat0, lane1: entry1 beat1, lane2: entry3 beat0, lane3: entry3 beat1
    // We expect entry1 beat0 word0 start cleared => low 32b == 0
    // Similarly for entry3 beat0.
    mmio_read_entry_4beats_4lanes(e1, 0, r0, 1, r1, 0, r2, 1, r3); // NOTE: entry fixed; so do separately below

    // Because mmio_read_entry_4beats_4lanes reads SAME entry for all lanes, do two reads:
    mmio_read_entry_4beats_4lanes(e1, 0, r0, 1, r1, 2, r2, 3, r3);
    if (r0[0 +: 32] !== 32'h0000_0000) begin
      $fatal(1, "DONE did not clear start bit for entry1: beat0.word0=0x%08x", r0[0 +: 32]);
    end

    mmio_read_entry_4beats_4lanes(e3, 0, r0, 1, r1, 2, r2, 3, r3);
    if (r0[0 +: 32] !== 32'h0000_0000) begin
      $fatal(1, "DONE did not clear start bit for entry3: beat0.word0=0x%08x", r0[0 +: 32]);
    end

    $display("====================================");
    $display("PASS: done-by-wid clears start");
    $display("====================================");

    $display("====================================");
    $display("PASS: tb_VX_config_registers (FULL)");
    $display("====================================");

    #50;
    $finish;
  end

endmodule
