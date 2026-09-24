`timescale 1ns/1ps
`include "VX_define.vh"

module tb_lmem_weight_gather_dma;
    import VX_gpu_pkg::*;
    localparam int NUM_LANES = `GEMM_WEIGHT_DATA_SIZE / LSU_WORD_SIZE;
    localparam int TAG_WIDTH = GEMM_BASE_TAG_WIDTH;
    localparam int DEPTH = 4;
    localparam int NUM_GROUPS = 4;
    localparam int ROWS_PER_GROUP = `MXU_WLOAD_NUM;
    localparam logic [63:0] SRC_BASE = 64'h1000;
    localparam logic [31:0] SRC_STRIDE = 32'd64;
    localparam logic [63:0] DST_BASE = 64'h8000;
    localparam time LEGACY_FINISH_TIME = 515ns;

    logic clk = 0;
    logic reset = 1;
    logic [31:0] cycle_r;
    always #5 clk = ~clk;

    VX_lmem_dma_ctrl_if ctrl_if();
    VX_mem_bus_if #(.DATA_SIZE(8), .TAG_WIDTH(TAG_WIDTH)) lmem_if[NUM_LANES]();
    VX_mem_bus_if #(.DATA_SIZE(`GEMM_WEIGHT_DATA_SIZE), .TAG_WIDTH(TAG_WIDTH)) gemm_if();

    int lane_request_count[NUM_LANES];
    int lane_response_count[NUM_LANES];
    bit response_seen[NUM_GROUPS][NUM_LANES];
    bit held_req_valid[NUM_LANES];
    logic [63:0] held_req_addr[NUM_LANES];
    logic [TAG_WIDTH-1:0] held_req_tag[NUM_LANES];
    bit lane_saw_response_skew[NUM_LANES];

    VX_lmem_weight_gather_dma #(
        .INSTANCE_ID("weight_gather_test"),
        .NUM_LANES(NUM_LANES),
        .TAG_WIDTH(TAG_WIDTH),
        .RD_PREFETCH_DEPTH(DEPTH)
    ) dut (
        .clk(clk),
        .reset(reset),
        .ctrl_if(ctrl_if),
        .lmem_bus_if(lmem_if),
        .gemm_bus_if(gemm_if)
    );

    for (genvar lane = 0; lane < NUM_LANES; ++lane) begin : g_mem
        logic [63:0] rsp_data_fifo[8];
        logic [TAG_WIDTH-1:0] rsp_tag_fifo[8];
        logic [3:0] rsp_delay_fifo[8];
        logic [2:0] rsp_wr_ptr;
        logic [2:0] rsp_rd_ptr;
        logic [3:0] rsp_count;
        wire push = lmem_if[lane].req_valid && lmem_if[lane].req_ready;
        wire launch = !lmem_if[lane].rsp_valid
                   && (rsp_count != 0)
                   && (rsp_delay_fifo[rsp_rd_ptr] == 0);

        // Deterministic per-lane request backpressure exercises held address/tag
        // context while preserving enough throughput to fill all four slots.
        assign lmem_if[lane].req_ready = (rsp_count != 8)
                                           && (((cycle_r + lane) % 5) != 0);

        always_ff @(posedge clk) begin
            if (reset) begin
                rsp_wr_ptr <= '0;
                rsp_rd_ptr <= '0;
                rsp_count <= '0;
                lmem_if[lane].rsp_valid <= 1'b0;
                lmem_if[lane].rsp_data  <= '0;
            end else begin
                if (lmem_if[lane].rsp_valid && lmem_if[lane].rsp_ready) begin
                    lmem_if[lane].rsp_valid <= 1'b0;
                end

                if (push) begin
                    rsp_data_fifo[rsp_wr_ptr] <= 64'(lmem_if[lane].req_data.addr) << 3;
                    rsp_tag_fifo[rsp_wr_ptr] <= lmem_if[lane].req_data.tag;
                    // Lane-dependent delay intentionally skews responses.
                    rsp_delay_fifo[rsp_wr_ptr] <= 2 + ((NUM_LANES - lane) % 7);
                    rsp_wr_ptr <= rsp_wr_ptr + 1'b1;
                end

                if (launch) begin
                    lmem_if[lane].rsp_valid <= 1'b1;
                    lmem_if[lane].rsp_data.data <= rsp_data_fifo[rsp_rd_ptr];
                    lmem_if[lane].rsp_data.tag  <= rsp_tag_fifo[rsp_rd_ptr];
                    rsp_rd_ptr <= rsp_rd_ptr + 1'b1;
                end else if (!lmem_if[lane].rsp_valid && (rsp_count != 0)) begin
                    rsp_delay_fifo[rsp_rd_ptr] <= rsp_delay_fifo[rsp_rd_ptr] - 1'b1;
                end

                case ({push, launch})
                    2'b10: rsp_count <= rsp_count + 1'b1;
                    2'b01: rsp_count <= rsp_count - 1'b1;
                    default: rsp_count <= rsp_count;
                endcase
            end
        end

        // Keep interface-array references under a constant generate index;
        // VCS does not allow variable XMR indices for interface instances.
        always_ff @(posedge clk) begin
            if (reset) begin
                lane_request_count[lane] <= 0;
                lane_response_count[lane] <= 0;
                held_req_valid[lane] <= 0;
                lane_saw_response_skew[lane] <= 0;
                for (int group = 0; group < NUM_GROUPS; ++group)
                    response_seen[group][lane] <= 0;
            end else begin
                if (held_req_valid[lane]) begin
                    if (!lmem_if[lane].req_valid)
                        $fatal(1, "lane %0d dropped req_valid under backpressure", lane);
                    if (lmem_if[lane].req_data.addr !== held_req_addr[lane]
                     || lmem_if[lane].req_data.tag !== held_req_tag[lane])
                        $fatal(1, "lane %0d changed request address/tag while stalled", lane);
                end
                held_req_valid[lane] <= lmem_if[lane].req_valid
                                     && !lmem_if[lane].req_ready;
                if (lmem_if[lane].req_valid && !lmem_if[lane].req_ready) begin
                    held_req_addr[lane] <= lmem_if[lane].req_data.addr;
                    held_req_tag[lane] <= lmem_if[lane].req_data.tag;
                end

                if (lmem_if[lane].req_valid && lmem_if[lane].req_ready) begin
                    logic [63:0] request_byte_addr;
                    int expected_group;
                    request_byte_addr = 64'(lmem_if[lane].req_data.addr) << 3;
                    expected_group = lane_request_count[lane];
                    if (expected_group >= NUM_GROUPS)
                        $fatal(1, "lane %0d issued excess request %0d", lane, expected_group);
                    if (request_byte_addr !== (SRC_BASE
                        + (expected_group * ROWS_PER_GROUP * SRC_STRIDE)
                        + ((lane / 2) * SRC_STRIDE)
                        + ((lane % 2) * 8)))
                        $fatal(1, "group=%0d lane=%0d request byte addr=%h unexpected",
                               expected_group, lane, request_byte_addr);
                    lane_request_count[lane] <= lane_request_count[lane] + 1;
                end

                if (lmem_if[lane].rsp_valid && lmem_if[lane].rsp_ready) begin
                    int response_group;
                    response_group = int'(dut.lane_rsp_slot[lane]);
                    if (response_group >= NUM_GROUPS)
                        $fatal(1, "lane %0d response slot %0d out of range", lane, response_group);
                    if (response_seen[response_group][lane])
                        $fatal(1, "duplicate response group=%0d lane=%0d", response_group, lane);
                    response_seen[response_group][lane] <= 1;
                    lane_response_count[lane] <= lane_response_count[lane] + 1;
                    if (lane != 0
                     && !response_seen[response_group][(lane == 0) ? 0 : lane-1])
                        lane_saw_response_skew[lane] <= 1;
                end
            end
        end
    end

    int output_count;
    int total_request_count;
    int total_response_count;
    int output_stall_count;
    int logical_response_count;
    bit held_output_valid;
    logic [`GEMM_WEIGHT_DATA_SIZE*8-1:0] held_output_data;
    logic [63:0] held_output_addr;
    logic gemm_req_ready_r;
    logic [1:0] output_stall_remaining_r;
    bit output_stall_injected_r;
    bit saw_full_prefetch;
    bit saw_queue_full;

    always_comb begin
        total_request_count = 0;
        total_response_count = 0;
        for (int lane = 0; lane < NUM_LANES; ++lane) begin
            total_request_count += lane_request_count[lane];
            total_response_count += lane_response_count[lane];
        end
    end

    // Arm a deterministic two-cycle sink stall from the first completed
    // logical response.  The old cycle-modulo ready pattern only covered
    // backpressure when its phase happened to overlap an output valid.
    // Registering this control from logical_response_fire makes the sink
    // ready low before the following-cycle ordered drain becomes valid and
    // avoids a combinational valid-to-ready path.
    assign gemm_if.req_ready = gemm_req_ready_r;
    assign gemm_if.rsp_valid = 1'b0;
    assign gemm_if.rsp_data  = '0;

    always_ff @(posedge clk) begin
        if (reset) begin
            cycle_r <= '0;
            output_count <= 0;
            output_stall_count <= 0;
            logical_response_count <= 0;
            saw_full_prefetch <= 0;
            saw_queue_full <= 0;
            held_output_valid <= 0;
            gemm_req_ready_r <= 1;
            output_stall_remaining_r <= 0;
            output_stall_injected_r <= 0;
        end else begin
            cycle_r <= cycle_r + 1'b1;
            if (dut.slot_busy_r == 4'hf)
                saw_full_prefetch <= 1;
            if (dut.queue_slot_occupancy == DEPTH)
                saw_queue_full <= 1;
            if (dut.logical_response_fire)
                logical_response_count <= logical_response_count + 1;

            if (!output_stall_injected_r && dut.logical_response_fire) begin
                gemm_req_ready_r <= 0;
                output_stall_remaining_r <= 2;
                output_stall_injected_r <= 1;
            end else if (!gemm_req_ready_r && gemm_if.req_valid) begin
                if (output_stall_remaining_r == 1) begin
                    gemm_req_ready_r <= 1;
                    output_stall_remaining_r <= 0;
                end else begin
                    output_stall_remaining_r <= output_stall_remaining_r - 1'b1;
                end
            end

            if (held_output_valid) begin
                if (!gemm_if.req_valid)
                    $fatal(1, "GEMM output valid dropped under backpressure");
                if (gemm_if.req_data.addr !== held_output_addr
                 || gemm_if.req_data.data !== held_output_data)
                    $fatal(1, "GEMM output address/data changed under backpressure");
            end
            held_output_valid <= gemm_if.req_valid && !gemm_if.req_ready;
            if (gemm_if.req_valid && !gemm_if.req_ready) begin
                held_output_addr <= gemm_if.req_data.addr;
                held_output_data <= gemm_if.req_data.data;
                output_stall_count <= output_stall_count + 1;
            end

            if (gemm_if.req_valid && gemm_if.req_ready) begin
                if (gemm_if.req_data.addr !== (DST_BASE >> $clog2(`GEMM_WEIGHT_DATA_SIZE)))
                    $fatal(1, "group=%0d GEMM address=%h unexpected",
                           output_count, gemm_if.req_data.addr);
                for (int lane = 0; lane < NUM_LANES; ++lane) begin
                    logic [63:0] expected;
                    expected = SRC_BASE
                             + (output_count * ROWS_PER_GROUP * SRC_STRIDE)
                             + ((lane / 2) * SRC_STRIDE)
                             + ((lane % 2) * 8);
                    if (!response_seen[output_count][lane])
                        $fatal(1, "group=%0d retired before lane=%0d response", output_count, lane);
                    if (gemm_if.req_data.data[lane * 64 +: 64] !== expected) begin
                        $fatal(1, "group=%0d lane=%0d got=%h expected=%h",
                               output_count, lane,
                               gemm_if.req_data.data[lane * 64 +: 64], expected);
                    end
                end
                output_count <= output_count + 1;
            end
        end
    end

    initial begin
        ctrl_if.start = 0;
        ctrl_if.src_base_addr = SRC_BASE;
        ctrl_if.dst_base_addr = DST_BASE;
        ctrl_if.src_strides[0] = SRC_STRIDE;
        ctrl_if.src_strides[1] = 0;
        ctrl_if.src_strides[2] = 0;
        ctrl_if.dst_strides[0] = 0;
        ctrl_if.dst_strides[1] = 0;
        ctrl_if.dst_strides[2] = 0;
        ctrl_if.bounds[0] = 32;
        ctrl_if.bounds[1] = 1;
        ctrl_if.bounds[2] = 1;
        ctrl_if.seg_size = 16;
        ctrl_if.reg_idx = 0;
        ctrl_if.reg_value = 0;

        repeat (5) @(posedge clk);
        reset = 0;
        repeat (2) @(posedge clk);
        ctrl_if.start = 1;
        @(posedge clk);
        ctrl_if.start = 0;
        if (!dut.dbg_shared_queue_bound
         || (dut.dbg_cmd_fifo_depth != 1)
         || (dut.dbg_response_slots != DEPTH)
         || !dut.dbg_ring_slot_order
         || dut.dbg_sink_pipeline
         || dut.dbg_same_cycle_slot_recycle)
            $fatal(1, "NAIVE Weight shared-queue binding mismatch");
        $display("PASS marker: NAIVE Weight gather owns stream queue cmd_depth=1 slots=%0d",
                 DEPTH);

        fork
            begin
                wait (ctrl_if.done);
                @(posedge clk);
                if (`MXU_WLOAD_NUM != 8 || `GEMM_WEIGHT_DATA_SIZE != 128
                 || NUM_LANES != 16 || `W_LMEM_DMA_CMD_BEATS != 4)
                    $fatal(1, "bad WLOAD8 compile contract wload=%0d bytes=%0d lanes=%0d beats=%0d",
                           `MXU_WLOAD_NUM, `GEMM_WEIGHT_DATA_SIZE, NUM_LANES,
                           `W_LMEM_DMA_CMD_BEATS);
                if (output_count != NUM_GROUPS)
                    $fatal(1, "expected %0d output groups, got %0d", NUM_GROUPS, output_count);
                if (total_request_count != 64 || total_response_count != 64)
                    $fatal(1, "expected 64 requests/responses, got req=%0d rsp=%0d",
                           total_request_count, total_response_count);
                for (int lane = 0; lane < NUM_LANES; ++lane) begin
                    if (lane_request_count[lane] != NUM_GROUPS
                     || lane_response_count[lane] != NUM_GROUPS)
                        $fatal(1, "lane %0d counts req=%0d rsp=%0d expected=%0d",
                               lane, lane_request_count[lane], lane_response_count[lane],
                               NUM_GROUPS);
                end
                if (!saw_full_prefetch)
                    $fatal(1, "four gather slots were never occupied together");
                if (!saw_queue_full)
                    $fatal(1, "four common logical slots were never occupied together");
                if (logical_response_count != NUM_GROUPS)
                    $fatal(1, "expected %0d completed logical responses, got %0d",
                           NUM_GROUPS, logical_response_count);
                begin
                    bit any_response_skew;
                    any_response_skew = 0;
                    for (int lane = 0; lane < NUM_LANES; ++lane)
                        any_response_skew |= lane_saw_response_skew[lane];
                    if (!any_response_skew)
                        $fatal(1, "response skew was not observed");
                end
                if (!output_stall_injected_r || output_stall_count != 2
                 || output_stall_remaining_r != 0 || !gemm_req_ready_r)
                    $fatal(1, "expected exactly two GEMM output stall cycles, got %0d",
                           output_stall_count);
                if (dut.queue_cmd_occupancy != 0
                 || dut.queue_slot_occupancy != 0
                 || dut.slot_busy_r != 0)
                    $fatal(1, "terminal queue/assembly ownership is nonzero");
                if ($time != LEGACY_FINISH_TIME)
                    $fatal(1, "Weight gather cycle regression finish=%0t expected=%0t",
                           $time, LEGACY_FINISH_TIME);
                $display("WLOAD8_CONFIG lanes=%0d bytes=%0d rows_per_group=%0d cmd_beats=%0d",
                         NUM_LANES, `GEMM_WEIGHT_DATA_SIZE, ROWS_PER_GROUP,
                         `W_LMEM_DMA_CMD_BEATS);
                $display("WLOAD8_COUNTS groups=%0d requests=%0d responses=%0d output_stalls=%0d",
                         output_count, total_request_count, total_response_count,
                         output_stall_count);
                $display("WLOAD8_QUEUE logical_responses=%0d cmd_depth=1 slots=%0d terminal=0",
                         logical_response_count, DEPTH);
                $display("WLOAD8_CYCLES finish=%0t legacy=%0t",
                         $time, LEGACY_FINISH_TIME);
                $display("TEST PASSED: strided WLOAD8 128-byte/16-lane gather with depth-4 prefetch");
                $finish;
            end
            begin : watchdog_block
                integer watchdog;
                for (watchdog = 0; watchdog < 1000; ++watchdog)
                    @(posedge clk);
                $fatal(1, "timeout");
            end
        join_any
    end
endmodule
