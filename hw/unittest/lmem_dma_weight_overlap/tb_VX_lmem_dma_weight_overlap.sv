`timescale 1ns/1ps

`include "VX_define.vh"

module tb_VX_lmem_dma_weight_overlap import VX_gpu_pkg::*; ();

  localparam int NDIM = 3;
  localparam int BUS_BYTES = 128;
  localparam int CMD_BEATS = 4;
  localparam int RESPONSE_SLOTS = 8;
  localparam int TAG_WIDTH = 8;
  localparam int BUS_ADDR_WIDTH = `MEM_ADDR_WIDTH - $clog2(BUS_BYTES);
  localparam int MAIN_COMMANDS = 6;
  localparam int MAIN_BEATS = MAIN_COMMANDS * CMD_BEATS;

  logic clk = 1'b0;
  logic reset = 1'b1;
  gemm_wait_meta_t writer_wait_i;
  logic [31:0] weight_consume_value0_i;
  logic [31:0] weight_consume_value1_i;
  always #5 clk = ~clk;

  VX_lmem_dma_ctrl_if #(.NDIM(NDIM)) ctrl_if();
  VX_gemm_sync_if sync_if();
  VX_mem_bus_if #(
    .DATA_SIZE(BUS_BYTES),
    .TAG_WIDTH(TAG_WIDTH)
  ) lmem_bus_if();
  VX_mem_bus_if #(
    .DATA_SIZE(BUS_BYTES),
    .TAG_WIDTH(TAG_WIDTH)
  ) gemm_bus_if();

  VX_lmem_dma_weight_overlap #(
    .INSTANCE_ID("weight_overlap_tb"),
    .NDIM(NDIM),
    .TAG_WIDTH(TAG_WIDTH),
    .CMD_FIFO_DEPTH(4),
    .CMD_BEATS(CMD_BEATS),
    .RESPONSE_SLOTS(RESPONSE_SLOTS),
    .LMEM_ADDR_WIDTH_P(BUS_ADDR_WIDTH),
    .GEMM_ADDR_WIDTH_P(BUS_ADDR_WIDTH),
    .LMEM_TAG_WIDTH_P(TAG_WIDTH),
    .GEMM_TAG_WIDTH_P(TAG_WIDTH)
  ) dut (
    .clk(clk),
    .reset(reset),
    .ctrl_if(ctrl_if),
    .writer_wait_i(writer_wait_i),
    .weight_consume_value0_i(weight_consume_value0_i),
    .weight_consume_value1_i(weight_consume_value1_i),
    .gemm_sync_if(sync_if),
    .lmem_bus_if(lmem_bus_if),
    .gemm_bus_if(gemm_bus_if)
  );

  logic lmem_req_ready_r;
  logic lmem_rsp_valid_r;
  logic [BUS_BYTES*8-1:0] lmem_rsp_data_r;
  logic [TAG_WIDTH-1:0] lmem_rsp_tag_r;
  logic gemm_req_ready_r;

  assign lmem_bus_if.req_ready = lmem_req_ready_r;
  assign lmem_bus_if.rsp_valid = lmem_rsp_valid_r;
  assign lmem_bus_if.rsp_data.data = lmem_rsp_data_r;
  assign lmem_bus_if.rsp_data.tag = lmem_rsp_tag_r;
  assign gemm_bus_if.req_ready = gemm_req_ready_r;
  assign gemm_bus_if.rsp_valid = 1'b0;
  assign gemm_bus_if.rsp_data = '0;
  assign sync_if.ready = 1'b1;

  function automatic logic [63:0] command_src_base(input int seq);
    return 64'h0001_0000 + 64'(seq * 16'h1000);
  endfunction

  function automatic logic [63:0] command_dst_base(input int seq);
    // Match the node's {load_dir, wreg_idx} selector encoding.  This test uses
    // load_dir=0 and alternates the two physical Weight registers.
    return 64'(seq & 1) << $clog2(BUS_BYTES);
  endfunction

  function automatic logic [GEMM_SYNC_REG_ID_WIDTH-1:0]
      weight_consume_rid(input int seq);
    return (seq & 1)
         ? GEMM_SYNC_REG_ID_WIDTH'(GEMM_RID_W_CONSUME1)
         : GEMM_SYNC_REG_ID_WIDTH'(GEMM_RID_W_CONSUME0);
  endfunction

  function automatic logic [BUS_BYTES*8-1:0] response_payload(
    input int seq,
    input int beat
  );
    logic [BUS_BYTES*8-1:0] value;
    value = '0;
    for (int word = 0; word < BUS_BYTES / 4; ++word)
      value[word*32 +: 32] = 32'((seq << 16) | (beat << 8) | word);
    return value;
  endfunction

  task automatic set_descriptor(input int seq);
    ctrl_if.src_base_addr = command_src_base(seq);
    ctrl_if.dst_base_addr = command_dst_base(seq);
    ctrl_if.seg_size = CMD_BEATS * BUS_BYTES;
    ctrl_if.reg_idx = 32'(100 + seq);
    ctrl_if.reg_value = 32'(200 + seq);
    writer_wait_i = '0;
    // Commands 2..5 arrive after value 3 is already visible, covering
    // consume-before-accept. Command 6 deliberately waits for a new buffer-0
    // target so its complete source phase can be checked independently of the
    // destination writer fence.
    if ((seq >= 2) && (seq <= 5)) begin
      writer_wait_i.valid = 1'b1;
      writer_wait_i.reg_id = weight_consume_rid(seq);
      writer_wait_i.target = 32'd3;
    end else if (seq == 6) begin
      writer_wait_i.valid = 1'b1;
      writer_wait_i.reg_id = weight_consume_rid(seq);
      writer_wait_i.target = 32'd4;
    end
    for (int d = 0; d < NDIM; ++d) begin
      ctrl_if.src_strides[d] = '0;
      ctrl_if.dst_strides[d] = '0;
      ctrl_if.bounds[d] = 32'd1;
    end
  endtask

  integer enqueue_count;
  integer pop_push_count;
  task automatic enqueue_command(input int seq);
    bit boundary_pop;
    @(negedge clk);
    while (ctrl_if.idle !== 1'b1)
      @(negedge clk);
    set_descriptor(seq);
    ctrl_if.start = 1'b1;
    #1;
    if (!ctrl_if.idle)
      $fatal(1, "command %0d lost idle before enqueue edge", seq);
    boundary_pop = dut.destination_last_write;
    @(posedge clk);
    enqueue_count = enqueue_count + 1;
    if (boundary_pop)
      pop_push_count = pop_push_count + 1;
    @(negedge clk);
    ctrl_if.start = 1'b0;
  endtask

  integer source_req_count;
  integer destination_req_count;
  integer completion_count;
  integer cycle_count;
  integer first_boundary_gap;
  integer previous_command_last_cycle;
  integer source_stall_cycles;
  integer destination_stall_cycles;
  logic source_stall_active_r;
  logic [BUS_ADDR_WIDTH-1:0] source_stall_addr_r;
  logic [TAG_WIDTH-1:0] source_stall_tag_r;
  logic destination_stall_active_r;
  logic [BUS_ADDR_WIDTH-1:0] destination_stall_addr_r;
  logic [BUS_BYTES*8-1:0] destination_stall_data_r;

  always @(posedge clk) begin
    int seq;
    int beat;
    bit dst_fire;
    bit expected_last;

    cycle_count = cycle_count + 1;
    if (!reset) begin
      if (source_stall_active_r) begin
        if (!lmem_bus_if.req_valid
         || lmem_bus_if.req_data.addr !== source_stall_addr_r
         || lmem_bus_if.req_data.tag !== source_stall_tag_r)
          $fatal(1, "source request changed under backpressure");
      end
      source_stall_active_r = lmem_bus_if.req_valid
                           && !lmem_bus_if.req_ready;
      source_stall_addr_r = lmem_bus_if.req_data.addr;
      source_stall_tag_r = lmem_bus_if.req_data.tag;
      if (source_stall_active_r)
        source_stall_cycles = source_stall_cycles + 1;

      if (lmem_bus_if.req_valid && lmem_bus_if.req_ready) begin
        seq = source_req_count / CMD_BEATS;
        beat = source_req_count % CMD_BEATS;
        if (lmem_bus_if.req_data.rw !== 1'b0)
          $fatal(1, "source request %0d is not a read", source_req_count);
        if (lmem_bus_if.req_data.addr !== BUS_ADDR_WIDTH'(
              (command_src_base(seq) + 64'(beat * BUS_BYTES))
              >> $clog2(BUS_BYTES)))
          $fatal(1, "source address order mismatch seq=%0d beat=%0d got=%0h",
                 seq, beat, lmem_bus_if.req_data.addr);
        if (lmem_bus_if.req_data.tag.value
            !== (source_req_count % RESPONSE_SLOTS))
          $fatal(1, "source slot order mismatch request=%0d tag=%0h",
                 source_req_count, lmem_bus_if.req_data.tag.value);
        source_req_count = source_req_count + 1;
      end

      if (destination_stall_active_r) begin
        if (!gemm_bus_if.req_valid
         || gemm_bus_if.req_data.addr !== destination_stall_addr_r
         || gemm_bus_if.req_data.data !== destination_stall_data_r)
          $fatal(1, "destination request changed under backpressure");
      end
      destination_stall_active_r = gemm_bus_if.req_valid
                                && !gemm_bus_if.req_ready;
      destination_stall_addr_r = gemm_bus_if.req_data.addr;
      destination_stall_data_r = gemm_bus_if.req_data.data;
      if (destination_stall_active_r)
        destination_stall_cycles = destination_stall_cycles + 1;

      dst_fire = gemm_bus_if.req_valid && gemm_bus_if.req_ready;
      seq = destination_req_count / CMD_BEATS;
      beat = destination_req_count % CMD_BEATS;
      expected_last = dst_fire && (beat == CMD_BEATS - 1);
      if (ctrl_if.write_done !== expected_last || ctrl_if.done !== expected_last)
        $fatal(1, "completion pulse mismatch dst_count=%0d done=%0b write_done=%0b expected=%0b",
               destination_req_count, ctrl_if.done, ctrl_if.write_done,
               expected_last);

      if (dst_fire) begin
        if (gemm_bus_if.req_data.rw !== 1'b1)
          $fatal(1, "destination request %0d is not a write",
                 destination_req_count);
        if (gemm_bus_if.req_data.addr !== BUS_ADDR_WIDTH'(
              command_dst_base(seq) >> $clog2(BUS_BYTES)))
          $fatal(1, "destination address order mismatch seq=%0d beat=%0d got=%0h",
                 seq, beat, gemm_bus_if.req_data.addr);
        if (gemm_bus_if.req_data.data !== response_payload(seq, beat))
          $fatal(1, "destination data mismatch seq=%0d beat=%0d", seq, beat);
        if (gemm_bus_if.req_data.byteen !== '1)
          $fatal(1, "destination byte enable mismatch seq=%0d beat=%0d", seq, beat);
        if (beat == 0 && seq == 1) begin
          first_boundary_gap = cycle_count - previous_command_last_cycle - 1;
          if (first_boundary_gap > 1)
            $fatal(1, "ready destination burst boundary gap=%0d exceeds one cycle",
                   first_boundary_gap);
        end
        if (beat == CMD_BEATS - 1) begin
          previous_command_last_cycle = cycle_count;
          if (sync_if.reg_idx !== 32'(100 + seq)
           || sync_if.value !== 32'(200 + seq))
            $fatal(1, "completion metadata mismatch seq=%0d reg=%0d value=%0d",
                   seq, sync_if.reg_idx, sync_if.value);
          completion_count = completion_count + 1;
        end
        destination_req_count = destination_req_count + 1;
      end
    end else begin
      source_stall_active_r = 1'b0;
      destination_stall_active_r = 1'b0;
    end
  end

  task automatic send_response(input int request_index);
    int seq;
    int beat;
    int slot;
    seq = request_index / CMD_BEATS;
    beat = request_index % CMD_BEATS;
    slot = request_index % RESPONSE_SLOTS;
    @(negedge clk);
    lmem_rsp_valid_r = 1'b1;
    lmem_rsp_data_r = response_payload(seq, beat);
    lmem_rsp_tag_r = '0;
    lmem_rsp_tag_r[TAG_WIDTH-`UP(UUID_WIDTH)-1:0] = slot;
    while (lmem_bus_if.rsp_ready !== 1'b1)
      @(negedge clk);
    @(posedge clk);
    @(negedge clk);
    lmem_rsp_valid_r = 1'b0;
  endtask

  task automatic wait_source_count(input int expected);
    while (source_req_count < expected)
      @(negedge clk);
  endtask

  task automatic wait_destination_count(input int expected);
    while (destination_req_count < expected)
      @(negedge clk);
  endtask

  initial begin
    ctrl_if.start = 1'b0;
    ctrl_if.prepare = 1'b0;
    ctrl_if.prepare_max_beats = '0;
    ctrl_if.src_base_addr = '0;
    ctrl_if.dst_base_addr = '0;
    ctrl_if.seg_size = '0;
    ctrl_if.reg_idx = '0;
    ctrl_if.reg_value = '0;
    writer_wait_i = '0;
    weight_consume_value0_i = 32'd0;
    weight_consume_value1_i = 32'd0;
    for (int d = 0; d < NDIM; ++d) begin
      ctrl_if.src_strides[d] = '0;
      ctrl_if.dst_strides[d] = '0;
      ctrl_if.bounds[d] = '0;
    end
    lmem_req_ready_r = 1'b0;
    lmem_rsp_valid_r = 1'b0;
    lmem_rsp_data_r = '0;
    lmem_rsp_tag_r = '0;
    gemm_req_ready_r = 1'b0;
    enqueue_count = 0;
    pop_push_count = 0;
    source_req_count = 0;
    destination_req_count = 0;
    completion_count = 0;
    cycle_count = 0;
    first_boundary_gap = -1;
    previous_command_last_cycle = -1;
    source_stall_cycles = 0;
    destination_stall_cycles = 0;
    source_stall_active_r = 1'b0;
    destination_stall_active_r = 1'b0;

    repeat (5) @(posedge clk);
    @(negedge clk);
    reset = 1'b0;
    repeat (2) @(posedge clk);

    // Fill all four command entries before any source request can fire.  The
    // later two entries remain descriptor-resident once the eight slots hold
    // the first two complete command payloads.
    enqueue_command(0);
    enqueue_command(1);
    enqueue_command(2);
    enqueue_command(3);
    @(negedge clk);
    if (ctrl_if.idle !== 1'b0 || dut.cmd_count_r != 4)
      $fatal(1, "Weight command FIFO did not report full after four enqueues");
    $display("PASS marker: four Weight descriptors enqueued before any completion");

    // Hold the first source request, then accept two commands' reads.  The
    // global tags must be exactly slots 0..7, all slots must be occupied, and
    // commands 2 and 3 must remain valid at the read head without issuing.
    repeat (3) @(posedge clk);
    @(negedge clk);
    lmem_req_ready_r = 1'b1;
    wait_source_count(8);
    @(negedge clk);
    lmem_req_ready_r = 1'b0;
    if (dut.slot_occupancy_r != RESPONSE_SLOTS)
      $fatal(1, "shared slot pool occupancy=%0d expected=%0d",
             dut.slot_occupancy_r, RESPONSE_SLOTS);
    if (dut.cmd_count_r != 4 || dut.cmd_valid_r !== 4'b1111
     || dut.cmd_rd_done_r !== 4'b0011 || dut.rd_cmd_ptr_r != 2)
      $fatal(1, "four-descriptor/eight-slot residency mismatch count=%0d valid=%0h rd_done=%0h rd_ptr=%0d",
             dut.cmd_count_r, dut.cmd_valid_r, dut.cmd_rd_done_r,
             dut.rd_cmd_ptr_r);
    $display("PASS marker: eight slots hold two payloads while two later descriptors remain resident");

    // Return all eight source responses in reverse tag order. Slot zero is
    // deliberately last, proving tagged out-of-order capture and ordered drain.
    for (int request_index = 7; request_index >= 0; --request_index)
      send_response(request_index);
    $display("PASS marker: delayed reverse-order tagged source responses accepted");

    // The writer has a valid staged request but must preserve it while the
    // destination is stalled.
    wait (gemm_bus_if.req_valid === 1'b1);
    repeat (3) @(posedge clk);
    @(negedge clk);
    gemm_req_ready_r = 1'b1;
    lmem_req_ready_r = 1'b1;
    // Later commands carry valid writer waits whose targets were reached
    // before their descriptors are accepted.  The executor must observe the
    // current level at accept rather than wait for a new release pulse.
    weight_consume_value0_i = 32'd3;
    weight_consume_value1_i = 32'd3;

    // Keep the command FIFO full by enqueueing on command-boundary pop cycles.
    // In parallel, return later responses in request order as their slots wrap.
    fork
      begin
        for (int seq = 4; seq < MAIN_COMMANDS; ++seq)
          enqueue_command(seq);
      end
      begin
        for (int request_index = 8; request_index < MAIN_BEATS;
             ++request_index) begin
          wait_source_count(request_index + 1);
          if ((request_index == 10) || (request_index == 19))
            repeat (2) @(posedge clk);
          send_response(request_index);
        end
      end
      begin
        wait_destination_count(9);
        @(negedge clk);
        gemm_req_ready_r = 1'b0;
        repeat (2) @(posedge clk);
        @(negedge clk);
        gemm_req_ready_r = 1'b1;
      end
    join

    wait_destination_count(MAIN_BEATS);
    @(negedge clk);
    if (completion_count != MAIN_COMMANDS)
      $fatal(1, "completion count=%0d expected=%0d",
             completion_count, MAIN_COMMANDS);
    if (enqueue_count != MAIN_COMMANDS || pop_push_count < 2)
      $fatal(1, "command wrap/pop-push coverage missing enq=%0d pop_push=%0d",
             enqueue_count, pop_push_count);
    if (source_stall_cycles == 0 || destination_stall_cycles == 0)
      $fatal(1, "backpressure coverage missing source=%0d destination=%0d",
             source_stall_cycles, destination_stall_cycles);
    if (first_boundary_gap < 0 || first_boundary_gap > 1)
      $fatal(1, "ready burst boundary coverage missing gap=%0d",
             first_boundary_gap);
    if (dut.cmd_count_r != 0 || dut.slot_occupancy_r != 0)
      $fatal(1, "executor not empty after wrap test commands=%0d slots=%0d",
             dut.cmd_count_r, dut.slot_occupancy_r);
    $display("PASS marker: six commands wrapped command/slot pointers with ordered writes and completions");
    $display("PASS marker: ready four-beat burst boundary idle cycles=%0d", first_boundary_gap);
    $display("PASS marker: source and destination backpressure held requests stable");

    // A source-ready buffer-0 command may fill all four response slots while
    // its exact consume target remains unresolved.  A stale target and a
    // wrong-buffer newer target must not release the writer; only W0 target 4
    // permits destination traffic.
    enqueue_command(6);
    wait_source_count(MAIN_BEATS + CMD_BEATS);
    @(negedge clk);
    lmem_req_ready_r = 1'b0;
    for (int request_index = MAIN_BEATS;
         request_index < MAIN_BEATS + CMD_BEATS; ++request_index)
      send_response(request_index);
    wait (dut.drain_valid_r === 1'b1);
    repeat (2) @(posedge clk);
    @(negedge clk);
    if (source_req_count != MAIN_BEATS + CMD_BEATS
     || destination_req_count != MAIN_BEATS
     || gemm_bus_if.req_valid)
      $fatal(1, "unreleased writer was not held after complete source preload");
    weight_consume_value1_i = 32'd4;
    repeat (2) @(posedge clk);
    @(negedge clk);
    if (destination_req_count != MAIN_BEATS || gemm_bus_if.req_valid)
      $fatal(1, "wrong-buffer consume value released buffer-0 writer");
    weight_consume_value0_i = 32'd3;
    repeat (2) @(posedge clk);
    @(negedge clk);
    if (destination_req_count != MAIN_BEATS || gemm_bus_if.req_valid)
      $fatal(1, "stale buffer-0 consume value released writer");
    weight_consume_value0_i = 32'd4;
    lmem_req_ready_r = 1'b1;
    wait_destination_count(MAIN_BEATS + CMD_BEATS);
    if (completion_count != MAIN_COMMANDS + 1)
      $fatal(1, "writer-fence command completion count mismatch got=%0d",
             completion_count);
    $display("PASS marker: source-before-consume, wrong/stale release rejection, and matching writer release");

    // Reset while a source request is stalled, one response is live, and one
    // destination payload is staged. No pre-reset owner may leak afterward.
    gemm_req_ready_r = 1'b0;
    lmem_req_ready_r = 1'b1;
    enqueue_command(7);
    enqueue_command(8);
    wait_source_count(MAIN_BEATS + CMD_BEATS + 3);
    @(negedge clk);
    lmem_req_ready_r = 1'b0;
    send_response(MAIN_BEATS + CMD_BEATS);
    wait (dut.drain_valid_r && gemm_bus_if.req_valid);
    @(negedge clk);
    lmem_rsp_valid_r = 1'b1;
    lmem_rsp_data_r = response_payload(7, 1);
    lmem_rsp_tag_r = '0;
    lmem_rsp_tag_r[TAG_WIDTH-`UP(UUID_WIDTH)-1:0] = 5;
    if (!lmem_bus_if.req_valid || !gemm_bus_if.req_valid)
      $fatal(1, "reset-live setup lacks source request or destination drain");
    reset = 1'b1;
    repeat (2) @(posedge clk);
    @(negedge clk);
    lmem_rsp_valid_r = 1'b0;
    repeat (2) @(posedge clk);
    @(negedge clk);
    reset = 1'b0;
    repeat (3) @(posedge clk);
    @(negedge clk);
    if (lmem_bus_if.req_valid || gemm_bus_if.req_valid
     || ctrl_if.done || ctrl_if.write_done || dut.cmd_count_r != 0
     || dut.slot_occupancy_r != 0 || ctrl_if.idle !== 1'b1)
      $fatal(1, "stale activity survived live reset");
    $display("PASS marker: live request/response/drain reset emitted no stale output");

    $display("PASSED: Weight LDMA four-command/eight-slot two-head overlap directed test");
    $finish;
  end

  initial begin
    repeat (5000) @(posedge clk);
    $display("timeout state: reset=%0b idle=%0b enq=%0d src=%0d dst=%0d done=%0d cmd_count=%0d slots=%0d rd_ptr=%0d wr_ptr=%0d tail=%0d req=%0b/%0b rsp=%0b/%0b dst_req=%0b/%0b",
             reset, ctrl_if.idle, enqueue_count, source_req_count,
             destination_req_count, completion_count, dut.cmd_count_r,
             dut.slot_occupancy_r, dut.rd_cmd_ptr_r, dut.wr_cmd_ptr_r,
             dut.cmd_tail_ptr_r, lmem_bus_if.req_valid,
             lmem_bus_if.req_ready, lmem_bus_if.rsp_valid,
             lmem_bus_if.rsp_ready, gemm_bus_if.req_valid,
             gemm_bus_if.req_ready);
    $fatal(1, "timeout in Weight LDMA overlap directed test");
  end

endmodule
