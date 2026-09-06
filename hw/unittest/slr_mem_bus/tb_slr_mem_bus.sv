`timescale 1ns/1ps
`include "VX_define.vh"

module slr_mem_bus_case #(
    parameter int DATA_SIZE = 32
) (
    input wire clk,
    input wire reset,
    output logic finished = 0
);
    import VX_gpu_pkg::*;
    localparam int TAGW = `UP(UUID_WIDTH) + 8;
    localparam int SIDEW = GEMM_SCHED_PRIORITY_WIDTH + 1 + 32;
    localparam int TRANSACTIONS = 128;
    VX_mem_bus_if #(.DATA_SIZE(DATA_SIZE), .TAG_WIDTH(TAGW)) upstream_if ();
    VX_mem_bus_if #(.DATA_SIZE(DATA_SIZE), .TAG_WIDTH(TAGW)) downstream_if ();
    logic [SIDEW-1:0] side_in;
    wire [SIDEW-1:0] side_out;
    wire request_idle;
    VX_slr_mem_bus #(
        .INSTANCE_ID("memory_crossing"), .SIDEW(SIDEW)
    ) dut (
        .clk(clk), .reset(reset),
        .upstream_if(upstream_if), .downstream_if(downstream_if),
        .side_in(side_in), .side_out(side_out), .request_idle(request_idle)
    );
    localparam int REQW = $bits(upstream_if.req_data);
    localparam int RSPW = $bits(upstream_if.rsp_data);
    logic [REQW+SIDEW-1:0] expected_request[$];
    logic [RSPW-1:0] waiting_responses[$];
    logic [RSPW-1:0] expected_response[$];
    int cycle = 0;
    int enqueued = 0;
    int accepted = 0;
    int returned = 0;
    int expected_reads = 0;
    int writes_enqueued = 0;
    int writes_committed = 0;
    int high_rate_beats = 0;
    int previous_accept = -1;
    bit stalled_request = 0;
    bit stalled_response = 0;
    bit backend_response_fire = 0;
    logic [REQW+SIDEW-1:0] held_request;
    logic [RSPW-1:0] held_response;

    always @(posedge clk) begin : scoreboard
        logic [REQW+SIDEW-1:0] expected_req;
        logic [RSPW-1:0] expected_rsp;
        logic [DATA_SIZE*8-1:0] response_data;
        if (!reset) begin
            cycle++;
            if (upstream_if.req_valid && upstream_if.req_ready) begin
                expected_request.push_back({side_in, upstream_if.req_data});
                enqueued++;
                if (upstream_if.req_data.rw)
                    writes_enqueued++;
                else
                    expected_reads++;
            end
            if (downstream_if.req_valid && downstream_if.req_ready) begin
                assert (expected_request.size() > 0) else $fatal(1, "unexpected request");
                expected_req = expected_request.pop_front();
                assert ({side_out, downstream_if.req_data} === expected_req)
                    else $fatal(1, "%0dB request/provenance changed", DATA_SIZE);
                accepted++;
                if (cycle > 80 && accepted < TRANSACTIONS) begin
                    if (previous_accept >= 80)
                        assert (cycle == previous_accept + 1)
                            else $fatal(1, "%0dB request throughput bubble", DATA_SIZE);
                    high_rate_beats++;
                end
                previous_accept = cycle;
                if (downstream_if.req_data.rw) begin
                    writes_committed++;
                end else begin
                    for (int b = 0; b < DATA_SIZE; ++b)
                        response_data[b*8 +: 8] = 8'(b) ^ downstream_if.req_data.tag.value;
                    waiting_responses.push_back({response_data, downstream_if.req_data.tag});
                end
            end
            backend_response_fire = downstream_if.rsp_valid && downstream_if.rsp_ready;
            if (backend_response_fire)
                expected_response.push_back(downstream_if.rsp_data);
            if (upstream_if.rsp_valid && upstream_if.rsp_ready) begin
                assert (expected_response.size() > 0) else $fatal(1, "unexpected response");
                expected_rsp = expected_response.pop_front();
                assert (upstream_if.rsp_data === expected_rsp)
                    else $fatal(1, "%0dB reordered response/tag changed", DATA_SIZE);
                returned++;
            end
            if (stalled_request)
                assert (downstream_if.req_valid
                     && {side_out, downstream_if.req_data} === held_request)
                    else $fatal(1, "request changed under backpressure");
            if (stalled_response)
                assert (upstream_if.rsp_valid && upstream_if.rsp_data === held_response)
                    else $fatal(1, "response changed under backpressure");
            stalled_request = downstream_if.req_valid && !downstream_if.req_ready;
            stalled_response = upstream_if.rsp_valid && !upstream_if.rsp_ready;
            held_request = {side_out, downstream_if.req_data};
            held_response = upstream_if.rsp_data;
            // request_idle reports previously accepted items, not a same-edge
            // new enqueue. A completed output descriptor has no new enqueue.
            if (request_idle && !(upstream_if.req_valid && upstream_if.req_ready))
                assert (expected_request.size() == 0 && writes_enqueued == writes_committed)
                    else $fatal(1, "%0dB write drain before physical acceptance", DATA_SIZE);
            if (enqueued == TRANSACTIONS && accepted == TRANSACTIONS
             && returned == expected_reads && request_idle) begin
                assert (high_rate_beats > 16) else $fatal(1, "insufficient throughput coverage");
                finished = 1;
            end
            if (cycle > 2000)
                $fatal(1, "%0dB memory crossing timeout", DATA_SIZE);
        end
    end

    always @(negedge clk) begin
        if (reset) begin
            upstream_if.req_valid = 0;
            upstream_if.req_data = '0;
            upstream_if.rsp_ready = 0;
            downstream_if.req_ready = 0;
            downstream_if.rsp_valid = 0;
            downstream_if.rsp_data = '0;
            side_in = '0;
        end else begin
            // enqueued changes only on a true handshake, hence a stalled
            // source offer remains stable without combinational remote ready.
            upstream_if.req_valid = enqueued < TRANSACTIONS;
            upstream_if.req_data = '0;
            upstream_if.req_data.rw = enqueued < 16 || enqueued[0];
            upstream_if.req_data.addr = enqueued;
            upstream_if.req_data.tag.uuid = '1;
            upstream_if.req_data.tag.value = 8'(enqueued);
            upstream_if.req_data.flags = enqueued;
            for (int b = 0; b < DATA_SIZE; ++b) begin
                upstream_if.req_data.data[b*8 +: 8] = 8'(enqueued + b);
                upstream_if.req_data.byteen[b] = (b + enqueued) % 3 != 0;
            end
            side_in = {GEMM_SCHED_PRIORITY_WIDTH'(enqueued), enqueued[0], 32'(enqueued)};
            downstream_if.req_ready = cycle > 12 && (cycle >= 80 || cycle % 5 != 0);
            upstream_if.rsp_ready = cycle > 35 && cycle % 7 < 4;

            // A reverse-order burst is generated from physically accepted
            // reads, while writes and further requests continue in parallel.
            if (!downstream_if.rsp_valid || backend_response_fire) begin
                downstream_if.rsp_valid = 0;
                if (waiting_responses.size() >= 2
                 || (accepted == TRANSACTIONS && waiting_responses.size() != 0)) begin
                    downstream_if.rsp_data = waiting_responses.pop_back();
                    downstream_if.rsp_valid = 1;
                end
            end
        end
    end
endmodule

module tb_slr_mem_bus;
    logic clk = 0;
    logic reset = 1;
    wire finished32, finished64;
    always #5 clk = ~clk;
    slr_mem_bus_case #(.DATA_SIZE(32)) u_32 (.clk(clk), .reset(reset), .finished(finished32));
    slr_mem_bus_case #(.DATA_SIZE(64)) u_64 (.clk(clk), .reset(reset), .finished(finished64));
    initial begin
        repeat (5) @(negedge clk);
        #1 reset = 0;
        wait (finished32 && finished64);
        $display("PASSED: 32B/64B SLR memory transport, tags, sidebands, reorder and write drain");
        $finish;
    end
endmodule
