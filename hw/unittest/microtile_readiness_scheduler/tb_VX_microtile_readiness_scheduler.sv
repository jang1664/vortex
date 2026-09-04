`timescale 1ns/1ps
`include "VX_define.vh"

module tb_VX_microtile_readiness_scheduler import VX_gpu_pkg::*; ();
  logic clk = 1'b0;
  logic reset = 1'b1;
  always #5 clk = ~clk;

  logic probe_valid;
  logic [31:0] probe_seq;
  wire probe_ready;
  logic cmd_fire;
  logic [1:0] cmd_resource;
  logic [31:0] cmd_seq;
  logic cmd_bank;
  logic [31:0] cmd_target;
  gemm_wait_meta_t cmd_writer_wait;
  gemm_wait_meta_t input_waits[4];
  logic retire_valid;
  logic [31:0] retire_seq;
  logic [3:0] fetch_valid;
  logic [31:0] fetch_seq[4];
  logic block_valid;
  logic [1:0] block_resource;
  logic [31:0] block_seq;
  logic block_bank;
  logic [31:0] block_target;
  logic [3:0] source_valid;
  logic [31:0] source_seq[4];
  logic [31:0] source_total[4];
  logic [31:0] source_request[4];
  logic [31:0] source_response[4];
  logic [31:0] source_writer[4];
  logic [3:0] input_occupancy;
  logic input_ahead_credit;
  logic input_admit_valid;
  logic [31:0] input_admit_seq;
  logic [31:0] w_load[2], s_load[2], z_load[2], acc_free[2];
  wire [GEMM_SCHED_PRIORITY_WIDTH-1:0] source_priority[4];
  wire input_enable;
  wire [2:0] entry_count;

  VX_microtile_readiness_scheduler #(
    .INSTANCE_ID("scheduler_tb"), .DEPTH(4), .INPUT_SLOTS(8)
  ) dut (
    .clk(clk), .reset(reset),
    .probe_valid_i(probe_valid), .probe_work_seq_i(probe_seq),
    .probe_ready_o(probe_ready),
    .cmd_fire_i(cmd_fire), .cmd_resource_i(cmd_resource),
    .cmd_work_seq_i(cmd_seq), .cmd_bank_i(cmd_bank),
    .cmd_target_i(cmd_target), .cmd_writer_wait_i(cmd_writer_wait),
    .input_waits_i(input_waits),
    .retire_valid_i(retire_valid), .retire_work_seq_i(retire_seq),
    .fetch_complete_valid_i(fetch_valid),
    .fetch_complete_work_seq_i(fetch_seq),
    .block_valid_i(block_valid), .block_resource_i(block_resource),
    .block_work_seq_i(block_seq), .block_bank_i(block_bank),
    .block_target_i(block_target),
    .source_valid_i(source_valid), .source_work_seq_i(source_seq),
    .source_total_beats_i(source_total),
    .source_request_beats_i(source_request),
    .source_response_beats_i(source_response),
    .source_writer_beats_i(source_writer),
    .input_slot_occupancy_i(input_occupancy),
    .input_ahead_credit_i(input_ahead_credit),
    .input_admit_valid_i(input_admit_valid),
    .input_admit_work_seq_i(input_admit_seq),
    .w_load_value_i(w_load), .s_load_value_i(s_load),
    .z_load_value_i(z_load), .acc_free_value_i(acc_free),
    .source_priority_o(source_priority),
    .input_source_enable_o(input_enable), .entry_count_o(entry_count)
  );

  task automatic clear_events;
    probe_valid = 1'b0;
    probe_seq = '0;
    cmd_fire = 1'b0;
    cmd_resource = '0;
    cmd_seq = '0;
    cmd_bank = 1'b0;
    cmd_target = '0;
    cmd_writer_wait = '0;
    retire_valid = 1'b0;
    retire_seq = '0;
    fetch_valid = '0;
    block_valid = 1'b0;
    block_resource = '0;
    block_seq = '0;
    block_bank = 1'b0;
    block_target = '0;
    source_valid = '0;
    input_occupancy = '0;
    input_ahead_credit = 1'b0;
    input_admit_valid = 1'b0;
    input_admit_seq = '0;
  endtask

  task automatic drive_source_progress(
    input int resource, input int seq, input int total,
    input int requested, input int responded, input int written
  );
    source_valid = '0;
    source_valid[resource] = 1'b1;
    source_seq[resource] = 32'(seq);
    source_total[resource] = 32'(total);
    source_request[resource] = 32'(requested);
    source_response[resource] = 32'(responded);
    source_writer[resource] = 32'(written);
  endtask

  task automatic drive_cmd(
    input int seq, input int resource, input logic bank,
    input int target, input bit expect_ready = 1'b1
  );
    @(negedge clk);
    probe_valid = 1'b1;
    probe_seq = 32'(seq);
    cmd_resource = 2'(resource);
    cmd_seq = 32'(seq);
    cmd_bank = bank;
    cmd_target = 32'(target);
    #1;
    if (probe_ready !== expect_ready)
      $fatal(1, "seq=%0d resource=%0d probe_ready=%0b expected=%0b",
             seq, resource, probe_ready, expect_ready);
    cmd_fire = expect_ready;
    @(posedge clk);
    @(negedge clk);
    probe_valid = 1'b0;
    cmd_fire = 1'b0;
  endtask

  task automatic expect_priority(input int resource, input int expected);
    #1;
    if (source_priority[resource] !== GEMM_SCHED_PRIORITY_WIDTH'(expected))
      $fatal(1, "resource=%0d priority=%0d expected=%0d",
             resource, source_priority[resource], expected);
  endtask

  initial begin
    clear_events();
    input_waits = '{default:'0};
    fetch_seq = '{default:'0};
    source_seq = '{default:'0};
    source_total = '{default:'0};
    source_request = '{default:'0};
    source_response = '{default:'0};
    source_writer = '{default:'0};
    w_load = '{default:'0};
    s_load = '{default:'0};
    z_load = '{default:'0};
    acc_free = '{default:'0};

    repeat (3) @(posedge clk);
    @(negedge clk);
    reset = 1'b0;

    // Retried probes do not allocate.  Only exact child enqueue fire does.
    repeat (2) begin
      probe_valid = 1'b1;
      probe_seq = 32'd10;
      #1;
      if (!probe_ready || (entry_count != 0))
        $fatal(1, "probe-only retry changed scoreboard");
      @(posedge clk);
      @(negedge clk);
    end
    probe_valid = 1'b0;
    drive_cmd(10, GEMM_SCHED_RESOURCE_WEIGHT, 1'b0, 10);
    if (entry_count != 1) $fatal(1, "first exact fire did not allocate");

    drive_cmd(10, GEMM_SCHED_RESOURCE_SCALE, 1'b0, 20);
    drive_cmd(10, GEMM_SCHED_RESOURCE_ZP, 1'b0, 30);
    input_waits[0] = '{valid:1'b1,
      reg_id:GEMM_SYNC_REG_ID_WIDTH'(GEMM_RID_W0), target:32'd10};
    input_waits[1] = '{valid:1'b1,
      reg_id:GEMM_SYNC_REG_ID_WIDTH'(GEMM_RID_SC0), target:32'd20};
    input_waits[2] = '{valid:1'b1,
      reg_id:GEMM_SYNC_REG_ID_WIDTH'(GEMM_RID_ZP0), target:32'd30};
    input_waits[3] = '{valid:1'b1,
      reg_id:GEMM_SYNC_REG_ID_WIDTH'(GEMM_RID_ACC_FREE0), target:32'd40};
    drive_cmd(10, GEMM_SCHED_RESOURCE_INPUT, 1'b0, 0);
    if (entry_count != 1) $fatal(1, "same-seq resource update duplicated entry");

    drive_source_progress(GEMM_SCHED_RESOURCE_WEIGHT, 10, 4, 1, 1, 0);
    expect_priority(GEMM_SCHED_RESOURCE_WEIGHT, GEMM_SCHED_PRIORITY_EARLIEST);
    block_valid = 1'b1;
    block_resource = GEMM_SCHED_RESOURCE_WEIGHT;
    block_seq = 32'd10;
    block_bank = 1'b0;
    block_target = 32'd10;
    expect_priority(GEMM_SCHED_RESOURCE_WEIGHT, GEMM_SCHED_PRIORITY_BLOCKED);
    block_bank = 1'b1;
    expect_priority(GEMM_SCHED_RESOURCE_WEIGHT, GEMM_SCHED_PRIORITY_EARLIEST);
    block_valid = 1'b0;

    // Descriptor-derived completion is authoritative.  Even if the target
    // generation is not installed, response==total is P0 and a blocker may
    // only promote the source while fetch work remains.
    drive_source_progress(GEMM_SCHED_RESOURCE_WEIGHT, 10, 4, 4, 4, 0);
    expect_priority(GEMM_SCHED_RESOURCE_WEIGHT, GEMM_SCHED_PRIORITY_BACKGROUND);
    block_valid = 1'b1;
    block_resource = GEMM_SCHED_RESOURCE_WEIGHT;
    block_seq = 32'd10;
    block_bank = 1'b0;
    block_target = 32'd10;
    expect_priority(GEMM_SCHED_RESOURCE_WEIGHT, GEMM_SCHED_PRIORITY_BACKGROUND);
    block_valid = 1'b0;
    source_valid = '0;

    // Buffered-but-writer-fenced work no longer consumes TMEM bandwidth.
    @(negedge clk);
    fetch_valid[GEMM_SCHED_RESOURCE_WEIGHT] = 1'b1;
    fetch_seq[GEMM_SCHED_RESOURCE_WEIGHT] = 32'd10;
    @(posedge clk);
    @(negedge clk);
    fetch_valid = '0;
    expect_priority(GEMM_SCHED_RESOURCE_WEIGHT, GEMM_SCHED_PRIORITY_BACKGROUND);
    source_valid = '0;

    // The descriptor length is live metadata, not a scheduler constant.
    // Cover one, two, four, slot-depth, and greater-than-slot-depth commands.
    for (int total_case = 0; total_case < 5; ++total_case) begin
      int total;
      unique case (total_case)
        0: total = 1;
        1: total = 2;
        2: total = 4;
        3: total = 8;
        default: total = 9;
      endcase
      drive_source_progress(GEMM_SCHED_RESOURCE_WEIGHT, 10,
                            total, 0, 0, 0);
      expect_priority(GEMM_SCHED_RESOURCE_WEIGHT,
                      GEMM_SCHED_PRIORITY_EARLIEST);
    end

    // Add near and far work, then verify W/S/Z distance mapping.  The bounded
    // issue guard preclassifies fetch-pending Weight at distance one or two as
    // P2 before a downstream request can sample priority.  Scale/ZP retain
    // their P1/P0 distance policy, and distance-three Weight stays P0.
    drive_cmd(11, GEMM_SCHED_RESOURCE_WEIGHT, 1'b1, 11);
    drive_cmd(11, GEMM_SCHED_RESOURCE_SCALE, 1'b1, 21);
    drive_cmd(11, GEMM_SCHED_RESOURCE_ZP, 1'b1, 31);
    drive_cmd(12, GEMM_SCHED_RESOURCE_WEIGHT, 1'b0, 12);
    drive_cmd(12, GEMM_SCHED_RESOURCE_SCALE, 1'b0, 22);
    drive_cmd(12, GEMM_SCHED_RESOURCE_ZP, 1'b0, 32);
    drive_cmd(13, GEMM_SCHED_RESOURCE_WEIGHT, 1'b1, 13);
    drive_cmd(13, GEMM_SCHED_RESOURCE_SCALE, 1'b1, 23);
    drive_cmd(13, GEMM_SCHED_RESOURCE_ZP, 1'b1, 33);
    for (int resource = GEMM_SCHED_RESOURCE_WEIGHT;
         resource <= GEMM_SCHED_RESOURCE_ZP; ++resource) begin
      drive_source_progress(resource, 10, 4, 1, 1, 0);
      expect_priority(resource, GEMM_SCHED_PRIORITY_EARLIEST);
      drive_source_progress(resource, 11, 4, 1, 1, 0);
      expect_priority(resource,
                      (resource == GEMM_SCHED_RESOURCE_WEIGHT)
                      ? GEMM_SCHED_PRIORITY_EARLIEST
                      : GEMM_SCHED_PRIORITY_NEAR);
      drive_source_progress(resource, 12, 4, 3, 2, 0);
      expect_priority(resource,
                      (resource == GEMM_SCHED_RESOURCE_WEIGHT)
                      ? GEMM_SCHED_PRIORITY_EARLIEST
                      : GEMM_SCHED_PRIORITY_BACKGROUND);
      drive_source_progress(resource, 13, 4, 3, 2, 0);
      expect_priority(resource, GEMM_SCHED_PRIORITY_BACKGROUND);
    end

    // A response-complete source is P0 while buffered, writer-fenced, or
    // installing, for every register resource.  Writer progress is debug
    // metadata and cannot re-promote TMEM service.
    for (int resource = GEMM_SCHED_RESOURCE_WEIGHT;
         resource <= GEMM_SCHED_RESOURCE_ZP; ++resource) begin
      drive_source_progress(resource, 12, 4, 4, 4, 2);
      expect_priority(resource, GEMM_SCHED_PRIORITY_BACKGROUND);
    end

    // Distance-zero and distance-one Input are P3 only when empty and P2
    // once one response slot is occupied.
    drive_source_progress(GEMM_SCHED_RESOURCE_INPUT, 10, 8, 1, 0, 0);
    input_occupancy = 4'd0;
    expect_priority(GEMM_SCHED_RESOURCE_INPUT, GEMM_SCHED_PRIORITY_BLOCKED);
    input_occupancy = 4'd1;
    expect_priority(GEMM_SCHED_RESOURCE_INPUT, GEMM_SCHED_PRIORITY_EARLIEST);
    drive_source_progress(GEMM_SCHED_RESOURCE_INPUT, 11, 8, 1, 0, 0);
    input_occupancy = 4'd0;
    expect_priority(GEMM_SCHED_RESOURCE_INPUT, GEMM_SCHED_PRIORITY_BLOCKED);
    input_occupancy = 4'd1;
    expect_priority(GEMM_SCHED_RESOURCE_INPUT, GEMM_SCHED_PRIORITY_EARLIEST);

    // A guarded distance-two Weight is P2 before request sampling.  Empty
    // Input retains P3 recovery, while occupancy one or two yields at P1.
    source_valid = '0;
    source_valid[GEMM_SCHED_RESOURCE_INPUT] = 1'b1;
    source_valid[GEMM_SCHED_RESOURCE_WEIGHT] = 1'b1;
    source_seq[GEMM_SCHED_RESOURCE_INPUT] = 32'd10;
    source_seq[GEMM_SCHED_RESOURCE_WEIGHT] = 32'd12;
    source_total[GEMM_SCHED_RESOURCE_INPUT] = 32'd8;
    source_request[GEMM_SCHED_RESOURCE_INPUT] = 32'd1;
    source_response[GEMM_SCHED_RESOURCE_INPUT] = 32'd0;
    source_writer[GEMM_SCHED_RESOURCE_INPUT] = 32'd0;
    source_total[GEMM_SCHED_RESOURCE_WEIGHT] = 32'd4;
    source_request[GEMM_SCHED_RESOURCE_WEIGHT] = 32'd1;
    source_response[GEMM_SCHED_RESOURCE_WEIGHT] = 32'd1;
    source_writer[GEMM_SCHED_RESOURCE_WEIGHT] = 32'd0;
    input_occupancy = 4'd0;
    expect_priority(GEMM_SCHED_RESOURCE_INPUT, GEMM_SCHED_PRIORITY_BLOCKED);
    expect_priority(GEMM_SCHED_RESOURCE_WEIGHT, GEMM_SCHED_PRIORITY_EARLIEST);
    input_occupancy = 4'd1;
    expect_priority(GEMM_SCHED_RESOURCE_INPUT, GEMM_SCHED_PRIORITY_NEAR);
    expect_priority(GEMM_SCHED_RESOURCE_WEIGHT, GEMM_SCHED_PRIORITY_EARLIEST);
    source_seq[GEMM_SCHED_RESOURCE_INPUT] = 32'd11;
    expect_priority(GEMM_SCHED_RESOURCE_INPUT, GEMM_SCHED_PRIORITY_NEAR);
    expect_priority(GEMM_SCHED_RESOURCE_WEIGHT, GEMM_SCHED_PRIORITY_EARLIEST);
    input_occupancy = 4'd2;
    expect_priority(GEMM_SCHED_RESOURCE_INPUT, GEMM_SCHED_PRIORITY_NEAR);
    expect_priority(GEMM_SCHED_RESOURCE_WEIGHT, GEMM_SCHED_PRIORITY_EARLIEST);

    // The explicit two-cycle response-to-write plus one-cycle install
    // contract makes ETA depend on both unrequested and outstanding beats.
    // At distance two with five Input slots of slack, ETA four is still NEAR,
    // but ETA+BANK_WAIT_BOUND crosses slack and preclassifies issue as P2.
    // One additional unrequested or outstanding beat is CRITICAL P2.
    source_valid = '0;
    drive_source_progress(GEMM_SCHED_RESOURCE_WEIGHT, 12, 8, 7, 7, 0);
    input_occupancy = 4'd5;
    #1;
    if (!dut.precritical_weight_fetch_pending)
      $fatal(1, "distance-two Weight did not exercise precritical issue guard");
    expect_priority(GEMM_SCHED_RESOURCE_WEIGHT, GEMM_SCHED_PRIORITY_EARLIEST);
    source_request[GEMM_SCHED_RESOURCE_WEIGHT] = 32'd6;
    source_response[GEMM_SCHED_RESOURCE_WEIGHT] = 32'd6;
    expect_priority(GEMM_SCHED_RESOURCE_WEIGHT, GEMM_SCHED_PRIORITY_EARLIEST);
    source_request[GEMM_SCHED_RESOURCE_WEIGHT] = 32'd7;
    source_response[GEMM_SCHED_RESOURCE_WEIGHT] = 32'd6;
    expect_priority(GEMM_SCHED_RESOURCE_WEIGHT, GEMM_SCHED_PRIORITY_EARLIEST);

    // A same-cycle exact Input admission turns the preclassified NEAR Weight
    // deadline into CRITICAL.  It was already P2 before the event and remains
    // P2 after the registered pulse is removed.  This is also the final
    // Weight request case (request == total - 1).
    source_response[GEMM_SCHED_RESOURCE_WEIGHT] = 32'd7;
    #1;
    if (!dut.precritical_weight_fetch_pending)
      $fatal(1, "final request was not guarded before Input admission");
    expect_priority(GEMM_SCHED_RESOURCE_WEIGHT, GEMM_SCHED_PRIORITY_EARLIEST);
    @(negedge clk);
    input_admit_valid = 1'b1;
    input_admit_seq = 32'd12;
    expect_priority(GEMM_SCHED_RESOURCE_WEIGHT, GEMM_SCHED_PRIORITY_EARLIEST);
    @(posedge clk);
    @(negedge clk);
    input_admit_valid = 1'b0;
    input_admit_seq = '0;
    expect_priority(GEMM_SCHED_RESOURCE_WEIGHT, GEMM_SCHED_PRIORITY_EARLIEST);
    source_response[GEMM_SCHED_RESOURCE_WEIGHT] = 32'd6;
    expect_priority(GEMM_SCHED_RESOURCE_WEIGHT, GEMM_SCHED_PRIORITY_EARLIEST);

    // With any nonempty Input occupancy, a guarded/critical Weight deadline
    // wins P2 and current Input is reduced to P1.  Occupancy one was checked
    // above; retain occupancy two here after persisted admission.
    source_valid[GEMM_SCHED_RESOURCE_INPUT] = 1'b1;
    source_seq[GEMM_SCHED_RESOURCE_INPUT] = 32'd10;
    source_total[GEMM_SCHED_RESOURCE_INPUT] = 32'd8;
    source_request[GEMM_SCHED_RESOURCE_INPUT] = 32'd1;
    source_response[GEMM_SCHED_RESOURCE_INPUT] = 32'd0;
    source_writer[GEMM_SCHED_RESOURCE_INPUT] = 32'd0;
    input_occupancy = 4'd2;
    expect_priority(GEMM_SCHED_RESOURCE_WEIGHT, GEMM_SCHED_PRIORITY_EARLIEST);
    expect_priority(GEMM_SCHED_RESOURCE_INPUT, GEMM_SCHED_PRIORITY_NEAR);

    // A registered writer blocker may raise an exact, still-fetching Weight
    // source to P3.  Fetch completion is authoritative: even while the blocker
    // matches and installation is still pending, it must immediately be P0.
    @(negedge clk);
    block_valid = 1'b1;
    block_resource = GEMM_SCHED_RESOURCE_WEIGHT;
    block_seq = 32'd12;
    block_bank = 1'b0;
    block_target = 32'd12;
    expect_priority(GEMM_SCHED_RESOURCE_WEIGHT, GEMM_SCHED_PRIORITY_BLOCKED);
    @(posedge clk);
    @(negedge clk);
    expect_priority(GEMM_SCHED_RESOURCE_WEIGHT, GEMM_SCHED_PRIORITY_BLOCKED);
    source_request[GEMM_SCHED_RESOURCE_WEIGHT] = 32'd8;
    source_response[GEMM_SCHED_RESOURCE_WEIGHT] = 32'd8;
    expect_priority(GEMM_SCHED_RESOURCE_WEIGHT, GEMM_SCHED_PRIORITY_BACKGROUND);
    block_valid = 1'b0;
    source_valid = '0;

    // Small/medium/large Input budgets are 4/6/8 without credit and
    // 5/7/8 with the single bounded registered credit.
    source_valid = '0;
    drive_source_progress(GEMM_SCHED_RESOURCE_INPUT, 10, 8, 1, 0, 0);
    input_occupancy = 4'd4;
    #1;
    if (input_enable) $fatal(1, "small input-ahead budget exceeded");
    input_occupancy = 4'd3;
    #1;
    if (!input_enable) $fatal(1, "small input-ahead budget underfilled");
    input_ahead_credit = 1'b1;
    input_occupancy = 4'd4;
    #1;
    if (!input_enable) $fatal(1, "small credited input-ahead budget closed early");
    input_occupancy = 4'd5;
    #1;
    if (input_enable) $fatal(1, "small credited input-ahead budget exceeded");
    input_ahead_credit = 1'b0;

    // Complete W/S/Z fetches: medium budget is six slots.
    @(negedge clk);
    fetch_valid[3:1] = 3'b111;
    fetch_seq[GEMM_SCHED_RESOURCE_WEIGHT] = 32'd10;
    fetch_seq[GEMM_SCHED_RESOURCE_SCALE] = 32'd10;
    fetch_seq[GEMM_SCHED_RESOURCE_ZP] = 32'd10;
    @(posedge clk);
    @(negedge clk);
    fetch_valid = '0;
    input_occupancy = 4'd6;
    #1;
    if (input_enable) $fatal(1, "medium input-ahead budget exceeded");
    input_occupancy = 4'd5;
    #1;
    if (!input_enable) $fatal(1, "medium input-ahead budget underfilled");
    input_ahead_credit = 1'b1;
    input_occupancy = 4'd6;
    #1;
    if (!input_enable) $fatal(1, "medium credited input-ahead budget closed early");
    input_occupancy = 4'd7;
    #1;
    if (input_enable) $fatal(1, "medium credited input-ahead budget exceeded");
    input_ahead_credit = 1'b0;

    // Exact generations plus ACC free make the earliest work runnable and
    // permit the full eight-slot budget.  Empty Input receives P3.
    w_load[0] = 32'd10;
    s_load[0] = 32'd20;
    z_load[0] = 32'd30;
    acc_free[0] = 32'd40;
    input_occupancy = 4'd7;
    #1;
    if (!input_enable) $fatal(1, "large input-ahead budget closed early");
    input_occupancy = 4'd8;
    #1;
    if (input_enable) $fatal(1, "large input-ahead budget overflowed slots");
    input_ahead_credit = 1'b1;
    input_occupancy = 4'd7;
    #1;
    if (!input_enable) $fatal(1, "large credited budget closed before slot cap");
    input_occupancy = 4'd8;
    #1;
    if (input_enable) $fatal(1, "large credited budget exceeded slot cap");
    input_ahead_credit = 1'b0;
    source_valid = '0;

    // Fill with W-before-Input works.  The fifth unseen sequence must block;
    // an ordered head Input completion can recycle it on the same edge.
    drive_cmd(13, GEMM_SCHED_RESOURCE_WEIGHT, 1'b1, 13);
    drive_cmd(14, GEMM_SCHED_RESOURCE_WEIGHT, 1'b0, 14, 1'b0);
    if (entry_count != 4) $fatal(1, "full scoreboard count mismatch");

    @(negedge clk);
    probe_valid = 1'b1;
    probe_seq = 32'd14;
    retire_valid = 1'b1;
    retire_seq = 32'd10;
    #1;
    if (!probe_ready) $fatal(1, "ordered retire did not unblock fifth work");
    cmd_fire = 1'b1;
    cmd_resource = GEMM_SCHED_RESOURCE_WEIGHT;
    cmd_seq = 32'd14;
    cmd_bank = 1'b0;
    cmd_target = 32'd14;
    @(posedge clk);
    @(negedge clk);
    clear_events();
    if (entry_count != 4) $fatal(1, "same-cycle retire/allocate changed occupancy");

    drive_cmd(14, GEMM_SCHED_RESOURCE_INPUT, 1'b0, 0);
    if (entry_count != 4)
      $fatal(1, "fifth W-before-Input sequence duplicated after recycle");

    $display("MICROTILE_READINESS_SCHEDULER PASSED");
    $finish;
  end
endmodule
