`timescale 1ns/1ps

`include "VX_define.vh"

module tb_VX_lmem_dma_qparam_overlap import VX_gpu_pkg::*; #(
  parameter bit TEST_ZP = 1'b0
) ();

  localparam int NDIM = 3;
  localparam int BUS_BYTES = 64;
  localparam int TAG_WIDTH = 8;
  localparam int BUS_ADDR_WIDTH = `MEM_ADDR_WIDTH - $clog2(BUS_BYTES);
  localparam int RID0 = TEST_ZP ? GEMM_RID_ZP_CONSUME0
                                : GEMM_RID_SC_CONSUME0;
  localparam int RID1 = TEST_ZP ? GEMM_RID_ZP_CONSUME1
                                : GEMM_RID_SC_CONSUME1;

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

  gemm_wait_meta_t writer_wait;
  logic [31:0] consume_value0;
  logic [31:0] consume_value1;

  VX_lmem_dma_qparam_overlap #(
    .INSTANCE_ID("qparam_overlap_tb"),
    .NDIM(NDIM),
    .TAG_WIDTH(TAG_WIDTH),
    .CMD_FIFO_DEPTH(4),
    .RESPONSE_SLOTS(8),
    .WRITER_RID0(RID0),
    .WRITER_RID1(RID1),
    .LMEM_ADDR_WIDTH_P(BUS_ADDR_WIDTH),
    .GEMM_ADDR_WIDTH_P(BUS_ADDR_WIDTH),
    .LMEM_TAG_WIDTH_P(TAG_WIDTH),
    .GEMM_TAG_WIDTH_P(TAG_WIDTH)
  ) dut (
    .clk(clk),
    .reset(reset),
    .sched_priority_i(GEMM_SCHED_PRIORITY_BACKGROUND),
    .ctrl_if(ctrl_if),
    .writer_wait_i(writer_wait),
    .writer_consume_value0_i(consume_value0),
    .writer_consume_value1_i(consume_value1),
    .gemm_sync_if(sync_if),
    .lmem_bus_if(lmem_bus_if),
    .gemm_bus_if(gemm_bus_if),
    .sched_source_valid_o(),
    .sched_source_work_seq_o(),
    .sched_source_total_beats_o(),
    .sched_source_request_beats_o(),
    .sched_source_response_beats_o(),
    .sched_source_writer_beats_o(),
    .sched_slot_occupancy_o(),
    .sched_fetch_complete_o(),
    .sched_fetch_complete_work_seq_o(),
    .lmem_req_priority_o()
  );

  logic pending_valid[8];
  logic [BUS_BYTES*8-1:0] pending_payload[8];
  logic response_release;
  logic destination_ready;
  int source_count;
  int destination_count;
  int done_count;
  int pending_count;
  int response_slot;

  function automatic logic [BUS_BYTES*8-1:0]
      make_payload(input int beat);
    logic [BUS_BYTES*8-1:0] value;
    begin
      value = '0;
      for (int lane = 0; lane < BUS_BYTES; ++lane)
        value[lane*8 +: 8] = 8'(beat * 17 + lane + 1);
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
      writer_wait = '0;
    end
  endtask

  task automatic enqueue_descriptor(
      input int seq_id,
      input logic bank,
      input int target,
      input int beats,
      input int destination_stride
  );
    begin
      while (!ctrl_if.idle)
        @(posedge clk);
      @(negedge clk);
      ctrl_if.src_base_addr = 64'h1000 + 64'(seq_id * BUS_BYTES);
      ctrl_if.dst_base_addr = 64'(bank * BUS_BYTES);
      ctrl_if.src_strides[0] = BUS_BYTES;
      ctrl_if.dst_strides[0] = destination_stride;
      ctrl_if.bounds[0] = beats;
      ctrl_if.bounds[1] = 1;
      ctrl_if.bounds[2] = 1;
      ctrl_if.seg_size = BUS_BYTES;
      ctrl_if.scheduler_work_seq = 32'(seq_id);
      writer_wait.valid = 1'b1;
      writer_wait.reg_id = bank
                         ? GEMM_SYNC_REG_ID_WIDTH'(RID1)
                         : GEMM_SYNC_REG_ID_WIDTH'(RID0);
      writer_wait.target = 32'(target);
      ctrl_if.start = 1'b1;
      @(posedge clk);
      @(negedge clk);
      ctrl_if.start = 1'b0;
      writer_wait = '0;
    end
  endtask

  task automatic enqueue_command(
      input int seq_id,
      input logic bank,
      input int target
  );
    begin
      enqueue_descriptor(seq_id, bank, target, 1, BUS_BYTES);
    end
  endtask

  function automatic int expected_destination_addr(input int beat);
    begin
      unique case (beat)
        0: expected_destination_addr = 0;
        1: expected_destination_addr = 1;
        2: expected_destination_addr = 0;
        3: expected_destination_addr = 1;
        // The directed two-beat descriptor uses bound[0]=2 and a 128-byte
        // destination stride, proving N-D address progression independently
        // of the current one-beat qparam schedule.
        4: expected_destination_addr = 0;
        5: expected_destination_addr = 2;
        default: expected_destination_addr = -1;
      endcase
    end
  endfunction

  always_comb begin
    response_slot = -1;
    if (response_release) begin
      for (int slot = 7; slot >= 0; --slot) begin
        if ((response_slot < 0) && pending_valid[slot])
          response_slot = slot;
      end
    end
    lmem_bus_if.rsp_valid = response_slot >= 0;
    lmem_bus_if.rsp_data = '0;
    if (response_slot >= 0) begin
      lmem_bus_if.rsp_data.tag = TAG_WIDTH'(response_slot);
      lmem_bus_if.rsp_data.data = pending_payload[response_slot];
    end
  end

  assign lmem_bus_if.req_ready = 1'b1;
  assign gemm_bus_if.req_ready = destination_ready;
  assign gemm_bus_if.rsp_valid = 1'b0;
  assign gemm_bus_if.rsp_data = '0;
  assign sync_if.ready = 1'b1;

  always @(posedge clk) begin
    if (!reset) begin
      if (lmem_bus_if.req_valid && lmem_bus_if.req_ready) begin
        int slot;
        slot = int'(lmem_bus_if.req_data.tag.value[2:0]);
        if (pending_valid[slot])
          $fatal(1, "Qparam source reused a live response slot");
        if (lmem_bus_if.req_data.addr
            != BUS_ADDR_WIDTH'((64'h1000
                              + 64'(source_count * BUS_BYTES)) >> 6))
          $fatal(1, "Qparam source command order mismatch");
        // These arrays drive the combinational response source.  NBA updates
        // keep a request/response accepted at this edge stable for every DUT
        // sampling process in the active region.
        pending_valid[slot] <= 1'b1;
        pending_payload[slot] <= make_payload(source_count);
        source_count++;
        pending_count++;
      end
      if (lmem_bus_if.rsp_valid && lmem_bus_if.rsp_ready) begin
        pending_valid[response_slot] <= 1'b0;
        pending_count--;
      end
      if (gemm_bus_if.req_valid && gemm_bus_if.req_ready) begin
        if (gemm_bus_if.req_data.addr
            != BUS_ADDR_WIDTH'(expected_destination_addr(destination_count)))
          $fatal(1, "Qparam destination bank/order mismatch");
        if (gemm_bus_if.req_data.data !== make_payload(destination_count))
          $fatal(1, "Qparam destination payload/order mismatch");
        destination_count++;
      end
      if (ctrl_if.done)
        done_count++;
    end
  end

  initial begin
    clear_ctrl();
    consume_value0 = 0;
    consume_value1 = 0;
    response_release = 1'b0;
    destination_ready = 1'b1;
    source_count = 0;
    destination_count = 0;
    done_count = 0;
    pending_count = 0;
    for (int slot = 0; slot < 8; ++slot) begin
      pending_valid[slot] = 1'b0;
      pending_payload[slot] = '0;
    end
    repeat (4) @(posedge clk);
    @(negedge clk);
    reset = 1'b0;

    enqueue_command(0, 1'b0, 1);
    enqueue_command(1, 1'b1, 1);
    enqueue_command(2, 1'b0, 2);
    enqueue_command(3, 1'b1, 2);
    wait (source_count == 4);
    @(negedge clk);
    for (int entry = 0; entry < 4; ++entry) begin
      if (!dut.u_overlap.cmd_valid_r[entry]
          || dut.u_overlap.cmd_total_beats_r[entry] != 1
          || dut.u_overlap.cmd_wr_count_r[entry] != 0
          || !dut.u_overlap.u_stream_queue.cmd_valid_r[entry]
          || dut.u_overlap.u_stream_queue.cmd_total_r[entry] != 1
          || dut.u_overlap.u_stream_queue.cmd_write_r[entry] != 0)
        $fatal(1, "Qparam one-beat descriptor state mismatch entry=%0d", entry);
    end
    if (!dut.u_overlap.dbg_overlap_shared_queue_bound
     || (dut.u_overlap.dbg_overlap_fetch_tag_width
         != $bits(lmem_bus_if.req_data.tag.value))
     || !dut.u_overlap.dbg_overlap_ring_slot_order
     || !dut.u_overlap.dbg_overlap_sink_pipeline)
      $fatal(1, "Qparam shared-queue mode binding mismatch");
    $display("PASS: qparam mode=%s owns independent VX_gemm_stream_dma_queue depth4/slots8",
             TEST_ZP ? "zero-point" : "scale");
    response_release = 1'b1;
    wait (pending_count == 0);
    repeat (3) @(posedge clk);
    if (destination_count != 0 || done_count != 0)
      $fatal(1, "Qparam write/completion preceded writer fence");

    @(negedge clk);
    consume_value1 = 1;
    repeat (2) @(posedge clk);
    if (destination_count != 0)
      $fatal(1, "Later-bank consume released the writer head");

    @(negedge clk);
    consume_value0 = 1;
    wait (destination_count == 1);
    wait (destination_count == 2);
    @(negedge clk);
    destination_ready = 1'b0;
    consume_value0 = 2;
    repeat (3) @(posedge clk);
    if (!gemm_bus_if.req_valid)
      $fatal(1, "Qparam writer did not hold a released request");
    if ((dut.u_overlap.dbg_overlap_writer_sequence != 2)
        || (dut.u_overlap.dbg_overlap_writer_total_beats != 1)
        || (dut.u_overlap.dbg_overlap_writer_write_count != 0))
      $fatal(1, "Qparam stalled writer state mismatch");
    @(negedge clk);
    destination_ready = 1'b1;
    wait (destination_count == 3);
    @(negedge clk);
    consume_value1 = 2;
    wait (destination_count == 4);
    wait (done_count == 4);

    // Preserve descriptor-generic behavior: the first beat must not complete
    // this command, the second beat must use the programmed N-D stride and be
    // the sole completion point.
    enqueue_descriptor(4, 1'b0, 3, 2, 2 * BUS_BYTES);
    wait (source_count == 6);
    wait (pending_count == 0);
    repeat (2) @(posedge clk);
    if (destination_count != 4 || done_count != 4)
      $fatal(1, "Qparam multi-beat write preceded writer fence");
    @(negedge clk);
    consume_value0 = 3;
    wait (destination_count == 5);
    if (done_count != 4)
      $fatal(1, "Qparam multi-beat command completed on non-final beat");
    wait (destination_count == 6);
    wait (done_count == 5);

    enqueue_command(6, 1'b1, 3);
    wait (source_count == 7);
    @(negedge clk);
    reset = 1'b1;
    repeat (2) @(posedge clk);
    if ((dut.u_overlap.cmd_count_r != 0)
     || (dut.u_overlap.slot_occupancy_r != 0)
     || (dut.u_overlap.u_stream_queue.cmd_count_r != 0)
     || (dut.u_overlap.u_stream_queue.slot_count_r != 0)
     || gemm_bus_if.req_valid)
      $fatal(1, "Qparam live-reset cleanup failed");

    $display("VX_lmem_dma_qparam_overlap unittest PASSED mode=%s",
             TEST_ZP ? "zero-point" : "scale");
    $finish;
  end

  initial begin
    repeat (2000) @(posedge clk);
    $fatal(1, "VX_lmem_dma_qparam_overlap unittest timeout");
  end

endmodule
