`timescale 1ns/1ps

`include "VX_define.vh"

module tb_VX_lmem_dma_input_overlap import VX_gpu_pkg::*; ();

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

  VX_lmem_dma_input_overlap #(
    .INSTANCE_ID("input_overlap_tb"),
    .NDIM(NDIM),
    .TAG_WIDTH(TAG_WIDTH),
    .CMD_FIFO_DEPTH(4),
    .RESPONSE_SLOTS(8),
    .LMEM_ADDR_WIDTH_P(BUS_ADDR_WIDTH),
    .GEMM_ADDR_WIDTH_P(BUS_ADDR_WIDTH),
    .LMEM_TAG_WIDTH_P(TAG_WIDTH),
    .GEMM_TAG_WIDTH_P(TAG_WIDTH)
  ) dut (
    .clk(clk),
    .reset(reset),
    .ctrl_if(ctrl_if),
    .writer_wait_i('0),
    .writer_consume_value0_i('0),
    .writer_consume_value1_i('0),
    .gemm_sync_if(sync_if),
    .lmem_bus_if(lmem_bus_if),
    .gemm_bus_if(gemm_bus_if)
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
  int next_response_slot;
  logic response_release;
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
      for (int slot = 7; slot >= 0; --slot) begin
        if ((next_response_slot < 0) && pending_valid[slot])
          next_response_slot = slot;
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
        pending_valid[next_response_slot] = 1'b0;
        pending_count--;
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
    lmem_req_ready_r = 1'b1;
    gemm_req_ready_r = 1'b0;
    response_release = 1'b0;
    source_count = 0;
    destination_count = 0;
    done_count = 0;
    start_count = 0;
    pending_count = 0;
    for (int slot = 0; slot < 8; ++slot) begin
      pending_valid[slot] = 1'b0;
      pending_payload[slot] = '0;
    end
    repeat (4) @(posedge clk);
    reset = 1'b0;

    // Four descriptors must enqueue before admission.  The source fills all
    // eight shared slots while the GEMM side remains fenced.
    for (int cmd = 0; cmd < MAIN_COMMANDS; ++cmd)
      enqueue_command(cmd, 4);
    wait (source_count == 8);
    #1;  // Sample DUT occupancy after the eighth allocation NBA commits.
    if ((start_count != 4) || (dut.cmd_count_r != 4)
        || (dut.slot_occupancy_r != 8))
      $fatal(1, "Input depth-four/eight-slot preload coverage failed");
    repeat (3) @(posedge clk);
    if (destination_count != 0)
      $fatal(1, "Input admitted data before the modeled fence released");

    // Return the first slot set in reverse-tag order, then release admission.
    response_release = 1'b1;
    wait (pending_count == 0);
    gemm_req_ready_r = 1'b1;
    wait (destination_count == MAIN_BEATS);
    wait (done_count == MAIN_COMMANDS);
    if (source_count != MAIN_BEATS)
      $fatal(1, "Input source count mismatch");

    // Variable-length commands reuse the same ring and exercise pointer wrap.
    enqueue_command(4, 1);
    enqueue_command(5, 3);
    enqueue_command(6, 5);
    wait (destination_count == MAIN_BEATS + 9);
    wait (done_count == MAIN_COMMANDS + 3);

    // Live reset must invalidate descriptors, slots, and staged output.
    gemm_req_ready_r = 1'b0;
    response_release = 1'b0;
    enqueue_command(7, 4);
    wait (lmem_bus_if.req_valid);
    @(negedge clk);
    reset = 1'b1;
    repeat (2) @(posedge clk);
    if ((dut.cmd_count_r != 0) || (dut.slot_occupancy_r != 0)
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
