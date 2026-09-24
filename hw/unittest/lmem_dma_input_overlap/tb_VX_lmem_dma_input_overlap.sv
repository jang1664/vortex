`timescale 1ns/1ps

`include "VX_define.vh"

module tb_VX_lmem_dma_input_overlap import VX_gpu_pkg::*; #(
  parameter bit TB_RESPONSE_DATA_RAM = 1'b1
) ();

  localparam int NDIM = 3;
  localparam int BUS_BYTES = 64;
  localparam int TAG_WIDTH = 8;
  localparam int BUS_ADDR_WIDTH = `MEM_ADDR_WIDTH - $clog2(BUS_BYTES);
  localparam int MAIN_COMMANDS = 4;
  localparam int MAIN_BEATS = 16;

  logic clk = 1'b0;
  logic reset = 1'b1;
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
  wire lmem_req_urgent;
  wire [GEMM_SCHED_PRIORITY_WIDTH-1:0] lmem_req_priority;
  logic sched_source_enable;
  logic [GEMM_SCHED_PRIORITY_WIDTH-1:0] sched_priority;
  wire [3:0] ready_ahead;
  wire sched_source_valid;
  wire [31:0] sched_source_work_seq;
  wire [31:0] sched_source_total_beats;
  wire [31:0] sched_source_request_beats;
  wire [31:0] sched_source_response_beats;
  wire [31:0] sched_source_writer_beats;

  VX_lmem_dma_input_overlap #(
    .INSTANCE_ID("input_overlap_tb"),
    .NDIM(NDIM),
    .MAX_DIMS(1),
    .TAG_WIDTH(TAG_WIDTH),
    .CMD_FIFO_DEPTH(4),
    .RESPONSE_SLOTS(8),
    .RESPONSE_DATA_RAM(TB_RESPONSE_DATA_RAM),
    .ENABLE_TMEM_URGENCY(1'b1),
    .ENABLE_SCHED_SOURCE_GATE(1'b1),
    .READY_AHEAD_LOW_WATERMARK(4),
    .LMEM_ADDR_WIDTH_P(BUS_ADDR_WIDTH),
    .GEMM_ADDR_WIDTH_P(BUS_ADDR_WIDTH),
    .LMEM_TAG_WIDTH_P(TAG_WIDTH),
    .GEMM_TAG_WIDTH_P(TAG_WIDTH)
  ) dut (
    .clk(clk),
    .reset(reset),
    .sched_source_enable_i(sched_source_enable),
    .sched_priority_i(sched_priority),
    .ctrl_if(ctrl_if),
    .writer_wait_i('0),
    .writer_consume_value0_i('0),
    .writer_consume_value1_i('0),
    .gemm_sync_if(sync_if),
    .lmem_bus_if(lmem_bus_if),
    .gemm_bus_if(gemm_bus_if),
    .lmem_req_urgent_o(lmem_req_urgent),
    .lmem_req_priority_o(lmem_req_priority),
    .ready_ahead_o(ready_ahead),
    .sched_source_valid_o(sched_source_valid),
    .sched_source_work_seq_o(sched_source_work_seq),
    .sched_source_total_beats_o(sched_source_total_beats),
    .sched_source_request_beats_o(sched_source_request_beats),
    .sched_source_response_beats_o(sched_source_response_beats),
    .sched_source_writer_beats_o(sched_source_writer_beats),
    .sched_slot_occupancy_o(),
    .sched_fetch_complete_o(),
    .sched_fetch_complete_work_seq_o()
  );

  logic lmem_req_ready_r;
  logic lmem_rsp_valid_r;
  logic [BUS_BYTES*8-1:0] lmem_rsp_payload_r;
  logic [TAG_WIDTH-1:0] lmem_rsp_tag_r;
  logic gemm_req_ready_r;

  assign lmem_bus_if.req_ready = lmem_req_ready_r;
  assign lmem_bus_if.rsp_valid = lmem_rsp_valid_r;
  assign lmem_bus_if.rsp_data.data = lmem_rsp_payload_r;
  assign lmem_bus_if.rsp_data.tag = lmem_rsp_tag_r;
  assign gemm_bus_if.req_ready = gemm_req_ready_r;
  assign gemm_bus_if.rsp_valid = 1'b0;
  assign gemm_bus_if.rsp_data = '0;
  assign sync_if.ready = 1'b1;

  logic pending_valid[8];
  logic [BUS_BYTES*8-1:0] pending_payload[8];
  int source_count;
  int destination_count;
  int done_count;
  int start_count;
  int pending_count;
  int response_count;
  int next_response_slot;
  logic response_release;
  logic response_lowest_first;
  logic [BUS_BYTES*8-1:0] expected_payload[64];

  function automatic logic [BUS_BYTES*8-1:0]
      make_payload(input int beat);
    logic [BUS_BYTES*8-1:0] value;
    begin
      value = '0;
      for (int lane = 0; lane < BUS_BYTES; ++lane)
        value[lane*8 +: 8] = 8'(beat + lane + 1);
      return value;
    end
  endfunction

  task automatic clear_ctrl;
    begin
      ctrl_if.start = 1'b0;
      ctrl_if.prepare = 1'b0;
      ctrl_if.prepare_max_beats = '0;
      ctrl_if.src_base_addr = '0;
      ctrl_if.dst_base_addr = '0;
      ctrl_if.src_strides = '{default:'0};
      ctrl_if.dst_strides = '{default:'0};
      ctrl_if.bounds = '{default:'0};
      ctrl_if.seg_size = '0;
      ctrl_if.reg_idx = '0;
      ctrl_if.reg_value = '0;
      ctrl_if.scheduler_work_seq = '0;
    end
  endtask

  task automatic enqueue_command(input int seq, input int beats);
    begin
      while (!ctrl_if.idle)
        @(posedge clk);
      @(negedge clk);
      ctrl_if.src_base_addr = 64'h0001_0000 + 64'(seq * 16'h1000);
      ctrl_if.dst_base_addr = '0;
      ctrl_if.src_strides[0] = BUS_BYTES;
      ctrl_if.src_strides[1] = 0;
      ctrl_if.src_strides[2] = 0;
      ctrl_if.dst_strides = '{default:'0};
      ctrl_if.bounds[0] = beats;
      ctrl_if.bounds[1] = 1;
      ctrl_if.bounds[2] = 1;
      ctrl_if.seg_size = BUS_BYTES;
      ctrl_if.scheduler_work_seq = 32'(seq);
      ctrl_if.start = 1'b1;
      @(posedge clk);
      #1;
      if (!ctrl_if.idle && (seq < 3)) begin
        // A full result after command four is expected; earlier commands must
        // leave lookahead capacity.
        $fatal(1, "Input overlap FIFO filled before four descriptors");
      end
      start_count++;
      @(negedge clk);
      ctrl_if.start = 1'b0;
    end
  endtask

  always_comb begin
    next_response_slot = -1;
    if (response_release) begin
      if (response_lowest_first) begin
        for (int slot = 0; slot < 8; ++slot) begin
          if ((next_response_slot < 0) && pending_valid[slot])
            next_response_slot = slot;
        end
      end else begin
        for (int slot = 7; slot >= 0; --slot) begin
          if ((next_response_slot < 0) && pending_valid[slot])
            next_response_slot = slot;
        end
      end
    end
    lmem_rsp_valid_r = next_response_slot >= 0;
    lmem_rsp_tag_r = '0;
    lmem_rsp_payload_r = '0;
    if (next_response_slot >= 0) begin
      lmem_rsp_tag_r = TAG_WIDTH'(next_response_slot);
      lmem_rsp_payload_r = pending_payload[next_response_slot];
    end
  end

  task automatic release_one_response(input bit lowest_first);
    int old_pending_count;
    old_pending_count = pending_count;
    @(negedge clk);
    response_lowest_first = lowest_first;
    response_release = 1'b1;
    wait (pending_count == (old_pending_count - 1));
    @(negedge clk);
    response_release = 1'b0;
  endtask

  always @(posedge clk) begin
    if (!reset) begin
      if (lmem_bus_if.req_valid && lmem_bus_if.req_ready) begin
        int slot;
        slot = lmem_bus_if.req_data.tag.value[2:0];
        if (pending_valid[slot])
          $fatal(1, "Input source reused a live response tag");
        pending_valid[slot] = 1'b1;
        pending_payload[slot] = make_payload(source_count);
        expected_payload[source_count] = make_payload(source_count);
        source_count++;
        pending_count++;
      end
      if (lmem_rsp_valid_r && lmem_bus_if.rsp_ready) begin
        if ((next_response_slot < 0) || !pending_valid[next_response_slot])
          $fatal(1, "Input response model emitted a stale/duplicate tag");
        pending_valid[next_response_slot] = 1'b0;
        pending_count--;
        response_count++;
      end
      if (gemm_bus_if.req_valid && gemm_bus_if.req_ready) begin
        if (gemm_bus_if.req_data.data !== expected_payload[destination_count])
          $fatal(1, "Input destination payload/order mismatch at beat %0d",
                 destination_count);
        destination_count++;
      end
      if (ctrl_if.done)
        done_count++;
    end
  end

  initial begin
    clear_ctrl();
    sched_source_enable = 1'b1;
    sched_priority = GEMM_SCHED_PRIORITY_NEAR;
    lmem_req_ready_r = 1'b1;
    gemm_req_ready_r = 1'b0;
    response_release = 1'b0;
    response_lowest_first = 1'b0;
    source_count = 0;
    destination_count = 0;
    done_count = 0;
    start_count = 0;
    pending_count = 0;
    response_count = 0;
    for (int slot = 0; slot < 8; ++slot) begin
      pending_valid[slot] = 1'b0;
      pending_payload[slot] = '0;
    end
    repeat (4) @(posedge clk);
    reset = 1'b0;

    // Once a request is presented, both the fixed tier and complete payload
    // must survive TMEM backpressure even if the scheduler disables new
    // source admission.  After that request fires, the disabled scheduler
    // must suppress the following request until re-enabled.
    begin : source_gate_stability
      logic held_rw;
      logic [BUS_ADDR_WIDTH-1:0] held_addr;
      logic [BUS_BYTES*8-1:0] held_data;
      logic [BUS_BYTES-1:0] held_byteen;
      logic [MEM_FLAGS_WIDTH-1:0] held_flags;
      logic [TAG_WIDTH-1:0] held_tag;
      logic held_urgent;
      logic [31:0] held_sched_work_seq;
      logic [31:0] held_sched_total;
      logic [31:0] held_sched_request;
      logic [31:0] held_sched_response;
      logic [31:0] held_sched_writer;
      int held_source_count;

    lmem_req_ready_r = 1'b0;
    enqueue_command(0, 4);
    wait (lmem_bus_if.req_valid);
    #1;
    if (lmem_req_priority != GEMM_SCHED_PRIORITY_NEAR)
      $fatal(1, "Input initial held priority mismatch");
    held_rw = lmem_bus_if.req_data.rw;
    held_addr = lmem_bus_if.req_data.addr;
    held_data = lmem_bus_if.req_data.data;
    held_byteen = lmem_bus_if.req_data.byteen;
    held_flags = lmem_bus_if.req_data.flags;
    held_tag = lmem_bus_if.req_data.tag;
    held_urgent = lmem_req_urgent;
    held_sched_work_seq = sched_source_work_seq;
    held_sched_total = sched_source_total_beats;
    held_sched_request = sched_source_request_beats;
    held_sched_response = sched_source_response_beats;
    held_sched_writer = sched_source_writer_beats;
    if (!sched_source_valid || (held_sched_work_seq != 0)
     || (held_sched_total != 4) || (held_sched_request != 0)
     || (held_sched_response != 0) || (held_sched_writer != 0))
      $fatal(1, "Input initial scheduler progress mismatch");
    // Let the executor sample the request context at the first stalled edge,
    // matching a scheduler state transition on a clock boundary.
    @(posedge clk);
    #1;
    sched_priority = GEMM_SCHED_PRIORITY_BLOCKED;
    sched_source_enable = 1'b0;
    repeat (2) @(posedge clk);
    #1;
    if (!lmem_bus_if.req_valid
     || (lmem_bus_if.req_data.rw != held_rw)
     || (lmem_bus_if.req_data.addr != held_addr)
     || (lmem_bus_if.req_data.data != held_data)
     || (lmem_bus_if.req_data.byteen != held_byteen)
     || (lmem_bus_if.req_data.flags != held_flags)
     || (lmem_bus_if.req_data.tag != held_tag)
     || (lmem_req_urgent != held_urgent)
     || (lmem_req_priority != GEMM_SCHED_PRIORITY_NEAR)
     || !sched_source_valid
     || (sched_source_work_seq != held_sched_work_seq)
     || (sched_source_total_beats != held_sched_total)
     || (sched_source_request_beats != held_sched_request)
     || (sched_source_response_beats != held_sched_response)
     || (sched_source_writer_beats != held_sched_writer))
      $fatal(1, "Input source request changed when scheduler disabled under stall");
    @(negedge clk);
    lmem_req_ready_r = 1'b1;
    wait (source_count == 1);
    #1;
    if (lmem_bus_if.req_valid)
      $fatal(1, "Input admitted a new source request while scheduler disabled");
    held_source_count = source_count;
    repeat (2) begin
      @(posedge clk);
      #1;
      if (lmem_bus_if.req_valid || (source_count != held_source_count))
        $fatal(1, "Input scheduler gate did not suppress subsequent request");
    end
    @(negedge clk);
    sched_source_enable = 1'b1;
    wait (lmem_bus_if.req_valid);
    #1;
    if (lmem_req_priority != GEMM_SCHED_PRIORITY_BLOCKED)
      $fatal(1, "Input next request did not sample raised priority");
    $display("PASS marker: Input request/payload/priority holds when scheduler disables under stall; next request remains gated until re-enable");
    end

    // Four descriptors must enqueue before admission.  The source fills all
    // eight shared slots while the GEMM side remains fenced.
    for (int cmd = 1; cmd < MAIN_COMMANDS; ++cmd)
      enqueue_command(cmd, 4);
    wait (source_count == 8);
    #1;  // Sample DUT occupancy after the eighth allocation NBA commits.
    if ((start_count != 4) || (dut.cmd_count_r != 4)
        || (dut.slot_occupancy_r != 8)
        || (dut.u_stream_queue.cmd_count_r != 4)
        || (dut.u_stream_queue.slot_count_r != 8))
      $fatal(1, "Input depth-four/eight-slot preload coverage failed");
    $display("PASS marker: Input descriptor/slot ownership is bound to VX_gemm_stream_dma_queue depth4/slots8");
    if ((ready_ahead != 0) || !lmem_req_urgent)
      $fatal(1, "Input WAIT_RSP occupancy incorrectly counted as ready-ahead");
    repeat (3) @(posedge clk);
    if (destination_count != 0)
      $fatal(1, "Input admitted data before the modeled fence released");

    // Return high tags first so occupancy falls while the writer-ready prefix
    // remains zero. Then return slots 0..3 individually to cover 1,
    // threshold-1, threshold, and finally full ready-ahead.
    repeat (4)
      release_one_response(1'b0);
    if ((ready_ahead != 0) || !lmem_req_urgent)
      $fatal(1, "Input nonconsecutive READY slots changed ready-ahead");
    release_one_response(1'b1);
    if ((ready_ahead != 1) || !lmem_req_urgent)
      $fatal(1, "Input ready-ahead=1 urgency mismatch");
    release_one_response(1'b1);
    release_one_response(1'b1);
    if ((ready_ahead != 3) || !lmem_req_urgent)
      $fatal(1, "Input threshold-1 urgency mismatch count=%0d", ready_ahead);
    release_one_response(1'b1);
    wait (ready_ahead == 8);
    if (lmem_req_urgent)
      $fatal(1, "Input urgency remained set with sufficient consecutive lead");
    $display("PASS marker: Input ready-ahead covers 0/1/threshold-1/threshold/full and excludes WAIT_RSP");
    // The controlled checkpoint is complete. Continue returning every later
    // tagged request so seq2/seq3 and variable-length commands can reuse the
    // circular response slots. This enable occurs on the negedge reached by
    // release_one_response, away from the response sampling edge.
    response_lowest_first = 1'b1;
    response_release = 1'b1;
    gemm_req_ready_r = 1'b1;
    wait (destination_count == MAIN_BEATS);
    wait (done_count == MAIN_COMMANDS);
    if (source_count != MAIN_BEATS)
      $fatal(1, "Input source count mismatch");
    if ((response_count != MAIN_BEATS) || (pending_count != 0))
      $fatal(1, "Input main response accounting mismatch rsp=%0d pending=%0d",
             response_count, pending_count);

    // Variable-length commands reuse the same ring and exercise pointer wrap.
    enqueue_command(4, 1);
    enqueue_command(5, 3);
    enqueue_command(6, 5);
    wait (destination_count == MAIN_BEATS + 9);
    wait (done_count == MAIN_COMMANDS + 3);
    if ((response_count != source_count) || (pending_count != 0))
      $fatal(1, "Input recycled-slot response accounting mismatch req=%0d rsp=%0d pending=%0d",
             source_count, response_count, pending_count);
    $display("PASS marker: Input recycled slots received one response per later tagged request");

    // Live reset must invalidate descriptors, slots, and staged output.
    @(negedge clk);
    gemm_req_ready_r = 1'b0;
    response_release = 1'b0;
    enqueue_command(7, 4);
    wait (lmem_bus_if.req_valid);
    @(negedge clk);
    reset = 1'b1;
    repeat (2) @(posedge clk);
    if ((dut.cmd_count_r != 0) || (dut.slot_occupancy_r != 0)
        || (dut.u_stream_queue.cmd_count_r != 0)
        || (dut.u_stream_queue.slot_count_r != 0)
        || gemm_bus_if.req_valid)
      $fatal(1, "Input live-reset cleanup failed");

    $display("VX_lmem_dma_input_overlap unittest PASSED");
    $finish;
  end

  initial begin
    repeat (3000) @(posedge clk);
    $fatal(1, "VX_lmem_dma_input_overlap unittest timeout");
  end

endmodule
