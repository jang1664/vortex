`timescale 1ns/1ps

`include "VX_define.vh"

module tb_VX_tmem_read_req_reservation import VX_gpu_pkg::*; ();
    localparam int DATA_SIZE = 64;
    localparam int TAG_WIDTH = 8;
    localparam int MEM_ADDR_WIDTH = 34;
    localparam int ADDR_WIDTH = MEM_ADDR_WIDTH - $clog2(DATA_SIZE);
    localparam int TAG_VALUE_WIDTH = TAG_WIDTH - `UP(UUID_WIDTH);
    localparam int NUM_REQUESTS = 5;

    typedef struct packed {
        logic [ADDR_WIDTH-1:0] addr;
        logic [TAG_VALUE_WIDTH-1:0] tag_value;
        logic [GEMM_SCHED_PRIORITY_WIDTH-1:0] priority_value;
        logic urgent;
        logic [31:0] work_seq;
    } expected_req_t;

    logic clk = 1'b0;
    logic reset = 1'b1;
    always #5 clk = ~clk;

    VX_mem_bus_if #(
        .DATA_SIZE      (DATA_SIZE),
        .TAG_WIDTH      (TAG_WIDTH),
        .MEM_ADDR_WIDTH (MEM_ADDR_WIDTH)
    ) upstream_if ();

    VX_mem_bus_if #(
        .DATA_SIZE      (DATA_SIZE),
        .TAG_WIDTH      (TAG_WIDTH),
        .MEM_ADDR_WIDTH (MEM_ADDR_WIDTH)
    ) downstream_if ();

    logic [GEMM_SCHED_PRIORITY_WIDTH-1:0] upstream_priority;
    logic upstream_urgent;
    logic [31:0] upstream_work_seq;
    wire [GEMM_SCHED_PRIORITY_WIDTH-1:0] downstream_priority;
    wire downstream_urgent;
    wire [31:0] downstream_work_seq;

    expected_req_t accepted_req[16];
    integer accepted_count;
    integer issued_count;

    VX_tmem_read_req_reservation #(
        .INSTANCE_ID    ("reservation_tb"),
        .DATA_SIZE      (DATA_SIZE),
        .TAG_WIDTH      (TAG_WIDTH),
        .MEM_ADDR_WIDTH (MEM_ADDR_WIDTH)
    ) dut (
        .clk            (clk),
        .reset          (reset),
        .req_priority_i (upstream_priority),
        .req_urgent_i   (upstream_urgent),
        .req_work_seq_i (upstream_work_seq),
        .req_priority_o (downstream_priority),
        .req_urgent_o   (downstream_urgent),
        .req_work_seq_o (downstream_work_seq),
        .upstream_if    (upstream_if),
        .downstream_if  (downstream_if)
    );

    task automatic drive_request(input int request_id);
        upstream_if.req_valid = 1'b1;
        upstream_if.req_data.rw = 1'b0;
        upstream_if.req_data.addr = ADDR_WIDTH'(28'h100 + request_id);
        upstream_if.req_data.data = '0;
        upstream_if.req_data.byteen = '1;
        upstream_if.req_data.flags = '0;
        upstream_if.req_data.tag.uuid = '0;
        upstream_if.req_data.tag.value
            = TAG_VALUE_WIDTH'(7'h21 + request_id);
        upstream_priority = GEMM_SCHED_PRIORITY_WIDTH'(request_id % 4);
        upstream_urgent = request_id[0];
        upstream_work_seq = 32'habc0_0000 + 32'(request_id);
    endtask

    task automatic expect_occupancy(input int expected);
        #1;
        if (dut.occupancy_r !== 2'(expected))
            $fatal(1, "occupancy=%0d expected=%0d",
                   dut.occupancy_r, expected);
    endtask

    task automatic expect_simultaneous_transfer;
        #1;
        if (!(upstream_if.req_valid && upstream_if.req_ready
           && downstream_if.req_valid && downstream_if.req_ready))
            $fatal(1, "expected simultaneous enqueue/dequeue");
    endtask

    // The monitor is also the ordering/duplication scoreboard.  It compares
    // the complete variable head metadata on every valid cycle, including
    // cycles stalled by downstream backpressure.
    always @(posedge clk) begin
        if (reset) begin
            accepted_count = 0;
            issued_count = 0;
        end else begin
            if (downstream_if.req_valid) begin
                if (issued_count >= accepted_count)
                    $fatal(1, "request issued without a prior reservation");
                if (downstream_if.req_data.addr
                    !== accepted_req[issued_count].addr)
                    $fatal(1, "request %0d address changed or reordered",
                           issued_count);
                if (downstream_if.req_data.tag.value
                    !== accepted_req[issued_count].tag_value)
                    $fatal(1, "request %0d tag changed or reordered",
                           issued_count);
                if (downstream_priority
                    !== accepted_req[issued_count].priority_value)
                    $fatal(1, "request %0d priority mismatched its entry",
                           issued_count);
                if (downstream_urgent
                    !== accepted_req[issued_count].urgent)
                    $fatal(1, "request %0d urgency mismatched its entry",
                           issued_count);
                if (downstream_work_seq
                    !== accepted_req[issued_count].work_seq)
                    $fatal(1, "request %0d work sequence mismatched its entry",
                           issued_count);
                if ((downstream_if.req_data.rw !== 1'b0)
                 || (downstream_if.req_data.data !== '0)
                 || (downstream_if.req_data.byteen !== '1)
                 || (downstream_if.req_data.flags !== '0)
                 || (downstream_if.req_data.tag.uuid !== '0))
                    $fatal(1, "request %0d read constants not reconstructed",
                           issued_count);
            end

            if (downstream_if.req_valid && downstream_if.req_ready)
                issued_count = issued_count + 1;

            if (upstream_if.req_valid && upstream_if.req_ready) begin
                accepted_req[accepted_count].addr
                    = upstream_if.req_data.addr;
                accepted_req[accepted_count].tag_value
                    = upstream_if.req_data.tag.value;
                accepted_req[accepted_count].priority_value
                    = upstream_priority;
                accepted_req[accepted_count].urgent = upstream_urgent;
                accepted_req[accepted_count].work_seq = upstream_work_seq;
                accepted_count = accepted_count + 1;
            end
        end
    end

    initial begin
        upstream_if.req_valid = 1'b0;
        upstream_if.req_data = '0;
        upstream_if.rsp_ready = 1'b0;
        upstream_priority = GEMM_SCHED_PRIORITY_BACKGROUND;
        upstream_urgent = 1'b0;
        upstream_work_seq = '0;
        downstream_if.req_ready = 1'b0;
        downstream_if.rsp_valid = 1'b0;
        downstream_if.rsp_data = '0;

        repeat (3) @(posedge clk);
        @(negedge clk);
        reset = 1'b0;

        // Empty reservations have credit but do not bypass a live request to
        // the downstream interface.  The request appears one cycle later.
        drive_request(0);
        #1;
        if (!upstream_if.req_ready)
            $fatal(1, "empty reservation did not advertise credit");
        if (downstream_if.req_valid)
            $fatal(1, "empty reservation used a fall-through path");
        @(posedge clk);
        expect_occupancy(1);
        if (!downstream_if.req_valid)
            $fatal(1, "reserved request missing after one-cycle latency");

        // Fill the second entry while the first head is stalled.  The monitor
        // checks that the head remains request 0 while request 1 is accepted.
        @(negedge clk);
        drive_request(1);
        if (!upstream_if.req_ready)
            $fatal(1, "one-entry reservation did not expose second credit");
        @(posedge clk);
        expect_occupancy(2);
        if (upstream_if.req_ready)
            $fatal(1, "full reservation exposed upstream credit");

        // Change every live upstream metadata field during backpressure.  It
        // must not alter the registered downstream head.
        @(negedge clk);
        drive_request(2);
        downstream_if.req_ready = 1'b0;
        repeat (2) begin
            @(posedge clk);
            expect_occupancy(2);
            if (upstream_if.req_ready)
                $fatal(1, "downstream ready leaked into full upstream ready");
            @(negedge clk);
            drive_request(3);
        end
        drive_request(2);

        // A full reservation beginning to drain must remain not-ready for
        // this cycle.  Request 2 is therefore not accepted on request 0's
        // dequeue edge.
        downstream_if.req_ready = 1'b1;
        #1;
        if (upstream_if.req_ready)
            $fatal(1, "full-drain cycle used a combinational ready bypass");
        @(posedge clk);
        expect_occupancy(1);
        if (!upstream_if.req_ready)
            $fatal(1, "registered credit did not recover after full drain");
        if (accepted_count != 2 || issued_count != 1)
            $fatal(1, "full-drain cycle accepted or issued the wrong count");

        // Once recovered and primed, sustain one enqueue and one dequeue on
        // every cycle.  Occupancy remains one throughout the stream.
        expect_simultaneous_transfer();
        @(posedge clk);
        expect_occupancy(1);

        @(negedge clk);
        drive_request(3);
        expect_simultaneous_transfer();
        @(posedge clk);
        expect_occupancy(1);

        @(negedge clk);
        drive_request(4);
        expect_simultaneous_transfer();
        @(posedge clk);
        expect_occupancy(1);

        // Stop enqueueing and drain the final registered request.
        @(negedge clk);
        upstream_if.req_valid = 1'b0;
        #1;
        if (!downstream_if.req_valid || !downstream_if.req_ready)
            $fatal(1, "final registered request did not remain drainable");
        @(posedge clk);
        expect_occupancy(0);
        if ((accepted_count != NUM_REQUESTS)
         || (issued_count != NUM_REQUESTS))
            $fatal(1,
                "ordering/count mismatch accepted=%0d issued=%0d expected=%0d",
                accepted_count, issued_count, NUM_REQUESTS);
        if (downstream_if.req_valid)
            $fatal(1, "empty reservation duplicated the final request");

        // Responses pass through without changing their complete tag or data,
        // and backpressure returns directly to the downstream response source.
        @(negedge clk);
        downstream_if.req_ready = 1'b0;
        downstream_if.rsp_valid = 1'b1;
        downstream_if.rsp_data.data = {DATA_SIZE{8'h5a}};
        downstream_if.rsp_data.tag.uuid = '1;
        downstream_if.rsp_data.tag.value = TAG_VALUE_WIDTH'(7'h6d);
        upstream_if.rsp_ready = 1'b0;
        #1;
        if (!upstream_if.rsp_valid
         || (upstream_if.rsp_data.data !== downstream_if.rsp_data.data)
         || (upstream_if.rsp_data.tag !== downstream_if.rsp_data.tag))
            $fatal(1, "response data/tag did not pass through unchanged");
        if (downstream_if.rsp_ready)
            $fatal(1, "response ready ignored upstream backpressure");
        upstream_if.rsp_ready = 1'b1;
        #1;
        if (!downstream_if.rsp_ready)
            $fatal(1, "response ready did not pass through");
        @(posedge clk);

        $display("TEST PASSED: tmem read-request reservation directed test");
        $finish;
    end

    initial begin
        #5000;
        $fatal(1, "timeout");
    end

endmodule
