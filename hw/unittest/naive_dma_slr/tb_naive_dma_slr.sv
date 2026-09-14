`timescale 1ns/1ps
`include "VX_define.vh"
module tb_naive_dma_slr;
    import VX_gpu_pkg::*;
    logic clk = 0;
    always #5 clk = ~clk;
    logic reset = 1;
    int cycle = 0;
    int epoch = 0;
    localparam int COUNT = 80;
    VX_lsu_mem_if #(.NUM_LANES(2), .DATA_SIZE(8), .TAG_WIDTH(16)) mmio_up[2]();
    VX_lsu_mem_if #(.NUM_LANES(2), .DATA_SIZE(8), .TAG_WIDTH(16)) mmio_down[2]();
    VX_mem_bus_if #(.DATA_SIZE(8), .TAG_WIDTH(16)) lmem_up[2]();
    VX_mem_bus_if #(.DATA_SIZE(8), .TAG_WIDTH(16)) lmem_down[2]();
    VX_mem_bus_if #(.DATA_SIZE(32), .TAG_WIDTH(16)) global_up();
    VX_mem_bus_if #(.DATA_SIZE(32), .TAG_WIDTH(16)) global_down();
    logic [`LMEM_NUM_BANKS-1:0][2:0] commit_in;
    wire [`LMEM_NUM_BANKS-1:0][2:0] commit_out;
    wire requests_drained;
    wire [9:0] finished;
`ifdef PERF_ENABLE
    dma_perf_t perf_in, perf_out;
    assign perf_in = {$bits(dma_perf_t){1'b1}} ^ $bits(dma_perf_t)'(cycle);
`endif
    VX_naive_dma_slr #(.INSTANCE_ID("tb"), .N_MASTER(2), .NUM_LANES(2)) dut (
        .clk(clk), .reset(reset), .mmio_up(mmio_up), .mmio_down(mmio_down),
        .lmem_up(lmem_up), .lmem_down(lmem_down),
        .global_up(global_up), .global_down(global_down),
        .commit_in(commit_in), .commit_out(commit_out), .requests_drained(requests_drained)
`ifdef PERF_ENABLE
        ,.perf_in(perf_in), .perf_out(perf_out)
`endif
    );
    always @(posedge clk) begin
        if (reset) cycle <= 0;
        else cycle <= cycle + 1;
    end
    // Distinct events every cycle, including non-DMA owners and simultaneous
    // DMA bank commits. The receiving mask must retain both timing and count.
    for (genvar b = 0; b < `LMEM_NUM_BANKS; ++b) begin : g_commit_check
        logic expect_tx, expect_rx;
        assign commit_in[b] = 3'((cycle + b) % 8);
        always @(posedge clk) begin
            if (reset) begin
                expect_tx <= 0;
                expect_rx <= 0;
            end else begin
                assert (commit_out[b] === {expect_rx, expect_rx, 1'b0})
                    else $fatal(1, "commit event timing/data mismatch bank=%0d", b);
                expect_tx <= commit_in[b][2:1] == 2'b11;
                expect_rx <= expect_tx;
            end
        end
    end
`ifdef PERF_ENABLE
    dma_perf_t expected_perf_tx, expected_perf_rx;
    always @(posedge clk) begin
        if (reset) begin
            expected_perf_tx <= '0;
            expected_perf_rx <= '0;
        end else begin
            assert (perf_out === expected_perf_rx) else $fatal(1, "PERF snapshot mismatch");
            expected_perf_tx <= perf_in;
            expected_perf_rx <= expected_perf_tx;
        end
    end
`endif
    if (1) begin : g_check_0
        localparam int WIDTH = $bits(mmio_up[0].req_data);
        int sent = 0, received = 0;
        function automatic logic [WIDTH-1:0] packet(input int n);
            for (int bitidx = 0; bitidx < WIDTH; ++bitidx)
                packet[bitidx] = (((n + epoch * 97 + 0 * 13) * 1103515245 + bitidx * 12345) >> (bitidx % 27)) & 1;
        endfunction
        assign mmio_up[0].req_valid = !reset && sent < COUNT;
        assign mmio_up[0].req_data = packet(sent);
        // Initial blocked interval forces all four credits to fill. Subsequent
        // independent stalls exercise every field while the source is held.
        assign mmio_down[0].req_ready = !reset && cycle > 20
                                              && ((cycle + 0 * 3) % 7 < 4);
        assign finished[0] = received == COUNT;
        always @(posedge clk) begin
            if (reset) begin
                sent <= 0;
                received <= 0;
            end else begin
                if (mmio_up[0].req_valid && mmio_up[0].req_ready) sent <= sent + 1;
                if (mmio_down[0].req_valid && mmio_down[0].req_ready) begin
                    assert (received < sent) else $fatal(1, "unexpected packet link=0");
                    assert (mmio_down[0].req_data === packet(received))
                        else $fatal(1, "packet corruption/order link=0 item=%0d", received);
                    received <= received + 1;
                end
            end
        end
    end
    if (1) begin : g_check_1
        localparam int WIDTH = $bits(mmio_down[0].rsp_data);
        int sent = 0, received = 0;
        function automatic logic [WIDTH-1:0] packet(input int n);
            for (int bitidx = 0; bitidx < WIDTH; ++bitidx)
                packet[bitidx] = (((n + epoch * 97 + 1 * 13) * 1103515245 + bitidx * 12345) >> (bitidx % 27)) & 1;
        endfunction
        assign mmio_down[0].rsp_valid = !reset && sent < COUNT;
        assign mmio_down[0].rsp_data = packet(sent);
        // Initial blocked interval forces all four credits to fill. Subsequent
        // independent stalls exercise every field while the source is held.
        assign mmio_up[0].rsp_ready = !reset && cycle > 20
                                              && ((cycle + 1 * 3) % 7 < 4);
        assign finished[1] = received == COUNT;
        always @(posedge clk) begin
            if (reset) begin
                sent <= 0;
                received <= 0;
            end else begin
                if (mmio_down[0].rsp_valid && mmio_down[0].rsp_ready) sent <= sent + 1;
                if (mmio_up[0].rsp_valid && mmio_up[0].rsp_ready) begin
                    assert (received < sent) else $fatal(1, "unexpected packet link=1");
                    assert (mmio_up[0].rsp_data === packet(received))
                        else $fatal(1, "packet corruption/order link=1 item=%0d", received);
                    received <= received + 1;
                end
            end
        end
    end
    if (1) begin : g_check_2
        localparam int WIDTH = $bits(mmio_up[1].req_data);
        int sent = 0, received = 0;
        function automatic logic [WIDTH-1:0] packet(input int n);
            for (int bitidx = 0; bitidx < WIDTH; ++bitidx)
                packet[bitidx] = (((n + epoch * 97 + 2 * 13) * 1103515245 + bitidx * 12345) >> (bitidx % 27)) & 1;
        endfunction
        assign mmio_up[1].req_valid = !reset && sent < COUNT;
        assign mmio_up[1].req_data = packet(sent);
        // Initial blocked interval forces all four credits to fill. Subsequent
        // independent stalls exercise every field while the source is held.
        assign mmio_down[1].req_ready = !reset && cycle > 20
                                              && ((cycle + 2 * 3) % 7 < 4);
        assign finished[2] = received == COUNT;
        always @(posedge clk) begin
            if (reset) begin
                sent <= 0;
                received <= 0;
            end else begin
                if (mmio_up[1].req_valid && mmio_up[1].req_ready) sent <= sent + 1;
                if (mmio_down[1].req_valid && mmio_down[1].req_ready) begin
                    assert (received < sent) else $fatal(1, "unexpected packet link=2");
                    assert (mmio_down[1].req_data === packet(received))
                        else $fatal(1, "packet corruption/order link=2 item=%0d", received);
                    received <= received + 1;
                end
            end
        end
    end
    if (1) begin : g_check_3
        localparam int WIDTH = $bits(mmio_down[1].rsp_data);
        int sent = 0, received = 0;
        function automatic logic [WIDTH-1:0] packet(input int n);
            for (int bitidx = 0; bitidx < WIDTH; ++bitidx)
                packet[bitidx] = (((n + epoch * 97 + 3 * 13) * 1103515245 + bitidx * 12345) >> (bitidx % 27)) & 1;
        endfunction
        assign mmio_down[1].rsp_valid = !reset && sent < COUNT;
        assign mmio_down[1].rsp_data = packet(sent);
        // Initial blocked interval forces all four credits to fill. Subsequent
        // independent stalls exercise every field while the source is held.
        assign mmio_up[1].rsp_ready = !reset && cycle > 20
                                              && ((cycle + 3 * 3) % 7 < 4);
        assign finished[3] = received == COUNT;
        always @(posedge clk) begin
            if (reset) begin
                sent <= 0;
                received <= 0;
            end else begin
                if (mmio_down[1].rsp_valid && mmio_down[1].rsp_ready) sent <= sent + 1;
                if (mmio_up[1].rsp_valid && mmio_up[1].rsp_ready) begin
                    assert (received < sent) else $fatal(1, "unexpected packet link=3");
                    assert (mmio_up[1].rsp_data === packet(received))
                        else $fatal(1, "packet corruption/order link=3 item=%0d", received);
                    received <= received + 1;
                end
            end
        end
    end
    if (1) begin : g_check_4
        localparam int WIDTH = $bits(lmem_up[0].req_data);
        int sent = 0, received = 0;
        function automatic logic [WIDTH-1:0] packet(input int n);
            for (int bitidx = 0; bitidx < WIDTH; ++bitidx)
                packet[bitidx] = (((n + epoch * 97 + 4 * 13) * 1103515245 + bitidx * 12345) >> (bitidx % 27)) & 1;
        endfunction
        assign lmem_up[0].req_valid = !reset && sent < COUNT;
        assign lmem_up[0].req_data = packet(sent);
        // Initial blocked interval forces all four credits to fill. Subsequent
        // independent stalls exercise every field while the source is held.
        assign lmem_down[0].req_ready = !reset && cycle > 20
                                              && ((cycle + 4 * 3) % 7 < 4);
        assign finished[4] = received == COUNT;
        always @(posedge clk) begin
            if (reset) begin
                sent <= 0;
                received <= 0;
            end else begin
                if (lmem_up[0].req_valid && lmem_up[0].req_ready) sent <= sent + 1;
                if (lmem_down[0].req_valid && lmem_down[0].req_ready) begin
                    assert (received < sent) else $fatal(1, "unexpected packet link=4");
                    assert (lmem_down[0].req_data === packet(received))
                        else $fatal(1, "packet corruption/order link=4 item=%0d", received);
                    received <= received + 1;
                end
            end
        end
    end
    if (1) begin : g_check_5
        localparam int WIDTH = $bits(lmem_down[0].rsp_data);
        int sent = 0, received = 0;
        function automatic logic [WIDTH-1:0] packet(input int n);
            for (int bitidx = 0; bitidx < WIDTH; ++bitidx)
                packet[bitidx] = (((n + epoch * 97 + 5 * 13) * 1103515245 + bitidx * 12345) >> (bitidx % 27)) & 1;
        endfunction
        assign lmem_down[0].rsp_valid = !reset && sent < COUNT;
        assign lmem_down[0].rsp_data = packet(sent);
        // Initial blocked interval forces all four credits to fill. Subsequent
        // independent stalls exercise every field while the source is held.
        assign lmem_up[0].rsp_ready = !reset && cycle > 20
                                              && ((cycle + 5 * 3) % 7 < 4);
        assign finished[5] = received == COUNT;
        always @(posedge clk) begin
            if (reset) begin
                sent <= 0;
                received <= 0;
            end else begin
                if (lmem_down[0].rsp_valid && lmem_down[0].rsp_ready) sent <= sent + 1;
                if (lmem_up[0].rsp_valid && lmem_up[0].rsp_ready) begin
                    assert (received < sent) else $fatal(1, "unexpected packet link=5");
                    assert (lmem_up[0].rsp_data === packet(received))
                        else $fatal(1, "packet corruption/order link=5 item=%0d", received);
                    received <= received + 1;
                end
            end
        end
    end
    if (1) begin : g_check_6
        localparam int WIDTH = $bits(lmem_up[1].req_data);
        int sent = 0, received = 0;
        function automatic logic [WIDTH-1:0] packet(input int n);
            for (int bitidx = 0; bitidx < WIDTH; ++bitidx)
                packet[bitidx] = (((n + epoch * 97 + 6 * 13) * 1103515245 + bitidx * 12345) >> (bitidx % 27)) & 1;
        endfunction
        assign lmem_up[1].req_valid = !reset && sent < COUNT;
        assign lmem_up[1].req_data = packet(sent);
        // Initial blocked interval forces all four credits to fill. Subsequent
        // independent stalls exercise every field while the source is held.
        assign lmem_down[1].req_ready = !reset && cycle > 20
                                              && ((cycle + 6 * 3) % 7 < 4);
        assign finished[6] = received == COUNT;
        always @(posedge clk) begin
            if (reset) begin
                sent <= 0;
                received <= 0;
            end else begin
                if (lmem_up[1].req_valid && lmem_up[1].req_ready) sent <= sent + 1;
                if (lmem_down[1].req_valid && lmem_down[1].req_ready) begin
                    assert (received < sent) else $fatal(1, "unexpected packet link=6");
                    assert (lmem_down[1].req_data === packet(received))
                        else $fatal(1, "packet corruption/order link=6 item=%0d", received);
                    received <= received + 1;
                end
            end
        end
    end
    if (1) begin : g_check_7
        localparam int WIDTH = $bits(lmem_down[1].rsp_data);
        int sent = 0, received = 0;
        function automatic logic [WIDTH-1:0] packet(input int n);
            for (int bitidx = 0; bitidx < WIDTH; ++bitidx)
                packet[bitidx] = (((n + epoch * 97 + 7 * 13) * 1103515245 + bitidx * 12345) >> (bitidx % 27)) & 1;
        endfunction
        assign lmem_down[1].rsp_valid = !reset && sent < COUNT;
        assign lmem_down[1].rsp_data = packet(sent);
        // Initial blocked interval forces all four credits to fill. Subsequent
        // independent stalls exercise every field while the source is held.
        assign lmem_up[1].rsp_ready = !reset && cycle > 20
                                              && ((cycle + 7 * 3) % 7 < 4);
        assign finished[7] = received == COUNT;
        always @(posedge clk) begin
            if (reset) begin
                sent <= 0;
                received <= 0;
            end else begin
                if (lmem_down[1].rsp_valid && lmem_down[1].rsp_ready) sent <= sent + 1;
                if (lmem_up[1].rsp_valid && lmem_up[1].rsp_ready) begin
                    assert (received < sent) else $fatal(1, "unexpected packet link=7");
                    assert (lmem_up[1].rsp_data === packet(received))
                        else $fatal(1, "packet corruption/order link=7 item=%0d", received);
                    received <= received + 1;
                end
            end
        end
    end
    if (1) begin : g_check_8
        localparam int WIDTH = $bits(global_up.req_data);
        int sent = 0, received = 0;
        function automatic logic [WIDTH-1:0] packet(input int n);
            for (int bitidx = 0; bitidx < WIDTH; ++bitidx)
                packet[bitidx] = (((n + epoch * 97 + 8 * 13) * 1103515245 + bitidx * 12345) >> (bitidx % 27)) & 1;
        endfunction
        assign global_up.req_valid = !reset && sent < COUNT;
        assign global_up.req_data = packet(sent);
        // Initial blocked interval forces all four credits to fill. Subsequent
        // independent stalls exercise every field while the source is held.
        assign global_down.req_ready = !reset && cycle > 20
                                              && ((cycle + 8 * 3) % 7 < 4);
        assign finished[8] = received == COUNT;
        always @(posedge clk) begin
            if (reset) begin
                sent <= 0;
                received <= 0;
            end else begin
                if (global_up.req_valid && global_up.req_ready) sent <= sent + 1;
                if (global_down.req_valid && global_down.req_ready) begin
                    assert (received < sent) else $fatal(1, "unexpected packet link=8");
                    assert (global_down.req_data === packet(received))
                        else $fatal(1, "packet corruption/order link=8 item=%0d", received);
                    received <= received + 1;
                end
            end
        end
    end
    if (1) begin : g_check_9
        localparam int WIDTH = $bits(global_down.rsp_data);
        int sent = 0, received = 0;
        function automatic logic [WIDTH-1:0] packet(input int n);
            for (int bitidx = 0; bitidx < WIDTH; ++bitidx)
                packet[bitidx] = (((n + epoch * 97 + 9 * 13) * 1103515245 + bitidx * 12345) >> (bitidx % 27)) & 1;
        endfunction
        assign global_down.rsp_valid = !reset && sent < COUNT;
        assign global_down.rsp_data = packet(sent);
        // Initial blocked interval forces all four credits to fill. Subsequent
        // independent stalls exercise every field while the source is held.
        assign global_up.rsp_ready = !reset && cycle > 20
                                              && ((cycle + 9 * 3) % 7 < 4);
        assign finished[9] = received == COUNT;
        always @(posedge clk) begin
            if (reset) begin
                sent <= 0;
                received <= 0;
            end else begin
                if (global_down.rsp_valid && global_down.rsp_ready) sent <= sent + 1;
                if (global_up.rsp_valid && global_up.rsp_ready) begin
                    assert (received < sent) else $fatal(1, "unexpected packet link=9");
                    assert (global_up.rsp_data === packet(received))
                        else $fatal(1, "packet corruption/order link=9 item=%0d", received);
                    received <= received + 1;
                end
            end
        end
    end
    always @(posedge clk) begin
        if (!reset && cycle > 5 && cycle < 20)
            assert (!requests_drained) else $fatal(1, "request drain before stalled downstream acceptance");
    end
    initial begin
        repeat (4) @(negedge clk);
        reset = 0;
        // Flush full links before they can deliver; old-epoch data must vanish.
        repeat (14) @(negedge clk);
        reset = 1;
        epoch = 1;
        repeat (4) @(negedge clk);
        reset = 0;
        wait (&finished);
        repeat (8) @(negedge clk);
        assert (requests_drained) else $fatal(1, "requests did not drain");
        $display("PASSED: naive DMA SLR: packets, backpressure, reset, commit and drain");
        $finish;
    end
    initial begin
        #200000;
        $fatal(1, "watchdog timeout");
    end
endmodule
