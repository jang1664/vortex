`timescale 1ns/1ps

module tb_VX_gemm_dma_interfaces;
    localparam int TAGW = 2;
    localparam int COUNTW = 8;

    logic clk;
    logic reset;

    VX_gemm_dma_fetch_if #(
        .INSTANCE_ID   ("tb.fetch"),
        .CMD_PAYLOADW  (16),
        .REQ_PAYLOADW  (16),
        .RSP_PAYLOADW  (32),
        .TAGW          (TAGW),
        .COUNTW        (COUNTW),
        .SLOT_COUNTW   (3),
        .SLOT_CAPACITY (4)
    ) fetch_if (clk, reset);

    VX_gemm_dma_sink_if #(
        .INSTANCE_ID ("tb.sink"),
        .PAYLOADW    (32),
        .TAGW        (TAGW),
        .COUNTW      (COUNTW)
    ) sink_if (clk, reset);

    always #5 clk = ~clk;

    task automatic clear_inputs;
        fetch_if.cmd_valid = 1'b0;
        fetch_if.cmd_ready = 1'b0;
        fetch_if.cmd_id = '0;
        fetch_if.cmd_total_beats = '0;
        fetch_if.cmd_payload = '0;
        fetch_if.req_valid = 1'b0;
        fetch_if.req_ready = 1'b0;
        fetch_if.req_tag = '0;
        fetch_if.req_payload = '0;
        fetch_if.rsp_valid = 1'b0;
        fetch_if.rsp_ready = 1'b0;
        fetch_if.rsp_tag = '0;
        fetch_if.rsp_payload = '0;
        fetch_if.rsp_owned = 1'b0;
        fetch_if.rsp_last = 1'b0;
        fetch_if.progress_valid = 1'b0;
        fetch_if.progress_total_beats = '0;
        fetch_if.progress_request_beats = '0;
        fetch_if.progress_response_beats = '0;
        fetch_if.slot_occupancy = '0;
        fetch_if.fetch_complete = 1'b0;

        sink_if.write_valid = 1'b0;
        sink_if.write_ready = 1'b0;
        sink_if.write_tag = '0;
        sink_if.write_payload = '0;
        sink_if.write_owned = 1'b0;
        sink_if.writer_released = 1'b0;
        sink_if.write_last = 1'b0;
        sink_if.progress_valid = 1'b0;
        sink_if.progress_total_beats = '0;
        sink_if.progress_write_beats = '0;
        sink_if.install_complete = 1'b0;
    endtask

    task automatic step;
        @(negedge clk);
    endtask

    initial begin
        clk = 1'b0;
        reset = 1'b1;
        clear_inputs();
        repeat (3) step();
        reset = 1'b0;

        // A zero-sized descriptor may be presented but cannot be accepted.
        fetch_if.cmd_valid = 1'b1;
        fetch_if.cmd_ready = 1'b0;
        fetch_if.cmd_id = 32'h10;
        fetch_if.cmd_payload = 16'h1000;
        repeat (2) step();
        // Same-cycle acceptance after a held command, now with a legal size.
        // Reset cancels the deliberately unaccepted zero-size presentation.
        reset = 1'b1;
        step();
        clear_inputs();
        reset = 1'b0;
        fetch_if.cmd_valid = 1'b1;
        fetch_if.cmd_ready = 1'b0;
        fetch_if.cmd_id = 32'h20;
        fetch_if.cmd_total_beats = COUNTW'(4);
        fetch_if.cmd_payload = 16'h2000;
        repeat (2) step();
        fetch_if.cmd_ready = 1'b1;
        step();
        fetch_if.cmd_valid = 1'b0;
        fetch_if.cmd_ready = 1'b0;

        fetch_if.progress_valid = 1'b1;
        fetch_if.progress_total_beats = COUNTW'(4);
        // Request hold and same-cycle turnover into the next tag.
        for (int tag = 0; tag < 4; ++tag) begin
            fetch_if.req_valid = 1'b1;
            fetch_if.req_ready = (tag != 0);
            fetch_if.req_tag = TAGW'(tag);
            fetch_if.req_payload = 16'h3000 + 16'(tag);
            if (tag == 0) begin
                repeat (2) step();
                fetch_if.req_ready = 1'b1;
            end
            step();
            fetch_if.progress_request_beats = COUNTW'(tag + 1);
            fetch_if.slot_occupancy = 3'(tag + 1);
        end
        fetch_if.req_valid = 1'b0;
        fetch_if.req_ready = 1'b0;

        // Responses return out of order.  Tag 2 is held under backpressure;
        // a ready-high consecutive response turnover is legal.
        for (int index = 0; index < 4; ++index) begin
            automatic int tag = (index == 0) ? 2
                              : (index == 1) ? 0
                              : (index == 2) ? 3 : 1;
            fetch_if.rsp_valid = 1'b1;
            fetch_if.rsp_ready = (index != 0);
            fetch_if.rsp_tag = TAGW'(tag);
            fetch_if.rsp_payload = 32'(32'h40000000 + tag);
            fetch_if.rsp_owned = 1'b1;
            fetch_if.rsp_last = (index == 3);
            fetch_if.fetch_complete = fetch_if.rsp_ready
                                   && fetch_if.rsp_last;
            if (index == 0) begin
                repeat (2) step();
                fetch_if.rsp_ready = 1'b1;
            end
            fetch_if.fetch_complete = fetch_if.rsp_ready
                                   && fetch_if.rsp_last;
            step();
            fetch_if.progress_response_beats = COUNTW'(index + 1);
            fetch_if.slot_occupancy = 3'(3 - index);
        end
        fetch_if.rsp_valid = 1'b0;
        fetch_if.rsp_ready = 1'b0;
        fetch_if.rsp_owned = 1'b0;
        fetch_if.rsp_last = 1'b0;
        fetch_if.fetch_complete = 1'b0;
        fetch_if.progress_valid = 1'b0;

        // Ordered sink writes retain owner/release/last with the payload.
        sink_if.progress_valid = 1'b1;
        sink_if.progress_total_beats = COUNTW'(4);
        for (int beat = 0; beat < 4; ++beat) begin
            sink_if.write_valid = 1'b1;
            sink_if.write_ready = (beat != 0);
            sink_if.write_tag = TAGW'(beat);
            sink_if.write_payload = 32'(32'h50000000 + beat);
            sink_if.write_owned = 1'b1;
            sink_if.writer_released = 1'b1;
            sink_if.write_last = (beat == 3);
            sink_if.install_complete = sink_if.write_ready
                                    && sink_if.write_last;
            if (beat == 0) begin
                repeat (2) step();
                sink_if.write_ready = 1'b1;
            end
            sink_if.install_complete = sink_if.write_ready
                                    && sink_if.write_last;
            step();
            if (beat != 3)
                sink_if.progress_write_beats = COUNTW'(beat + 1);
        end
        sink_if.write_valid = 1'b0;
        sink_if.write_ready = 1'b0;
        sink_if.install_complete = 1'b0;
        sink_if.progress_valid = 1'b0;

        // Duplicate/stale ownership cannot be accepted.  Hold it stable and
        // prove reset cancels the outstanding protocol state without a leak.
        fetch_if.rsp_valid = 1'b1;
        fetch_if.rsp_ready = 1'b0;
        fetch_if.rsp_tag = TAGW'(2);
        fetch_if.rsp_payload = 32'hdead0002;
        fetch_if.rsp_owned = 1'b0;
        repeat (2) step();
        reset = 1'b1;
        step();
        clear_inputs();
        reset = 1'b0;
        repeat (2) step();

        // A response and a replacement request may turn over the same tag in
        // one cycle.  The second response still has exactly one live owner.
        fetch_if.progress_valid = 1'b1;
        fetch_if.progress_total_beats = COUNTW'(2);
        fetch_if.req_valid = 1'b1;
        fetch_if.req_ready = 1'b1;
        fetch_if.req_tag = TAGW'(0);
        fetch_if.req_payload = 16'h6000;
        step();
        fetch_if.progress_request_beats = COUNTW'(1);
        fetch_if.slot_occupancy = 3'(1);
        fetch_if.rsp_valid = 1'b1;
        fetch_if.rsp_ready = 1'b1;
        fetch_if.rsp_tag = TAGW'(0);
        fetch_if.rsp_payload = 32'h60000000;
        fetch_if.rsp_owned = 1'b1;
        fetch_if.req_payload = 16'h6001;
        step();
        fetch_if.progress_request_beats = COUNTW'(2);
        fetch_if.progress_response_beats = COUNTW'(1);
        fetch_if.req_valid = 1'b0;
        fetch_if.rsp_payload = 32'h60000001;
        fetch_if.rsp_last = 1'b1;
        fetch_if.fetch_complete = 1'b1;
        step();
        clear_inputs();
        repeat (2) step();

        $display("TEST PASSED: GEMM DMA fetch/sink interface contracts");
        $finish;
    end

endmodule
