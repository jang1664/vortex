`timescale 1ns/1ps

module early_release_case #(
    parameter bit EARLY = 1,
    parameter bit BYPASS = 0,
    parameter int DATAW = 512
) (
    input wire clk,
    input wire reset,
    output logic done = 0
);
    localparam int SLOTS = 8;
    localparam int COUNTW = 5;
    localparam int SEQW = 3;
    localparam int META = 8;
    VX_gemm_dma_fetch_if #(
        .CMD_PAYLOADW(2*META), .REQ_PAYLOADW(META+COUNTW),
        .RSP_PAYLOADW(DATAW), .TAGW(3), .COUNTW(COUNTW),
        .SLOT_COUNTW(4), .SLOT_CAPACITY(SLOTS)
    ) fetch_if (clk, reset);
    VX_gemm_dma_sink_if #(
        .PAYLOADW(META+COUNTW+DATAW), .TAGW(SEQW+COUNTW), .COUNTW(COUNTW)
    ) sink_if (clk, reset);
    logic writer_release;
    wire [3:0] slots, ready_ahead;
    VX_gemm_stream_dma_queue #(
        .INSTANCE_ID("early_release_test"), .CMD_FIFO_DEPTH(2),
        .RESPONSE_SLOTS(SLOTS), .SOURCE_METAW(META), .DEST_METAW(META),
        .DATAW(DATAW), .COUNTW(COUNTW), .SEQW(SEQW), .FETCH_TAGW(3),
        .RING_SLOT_ORDER(1), .SINK_PIPELINE(1), .RESPONSE_DATA_RAM(1),
        .SAME_CYCLE_SLOT_RECYCLE(EARLY), .EARLY_SLOT_RELEASE(EARLY),
        .RESPONSE_STAGE_BYPASS(BYPASS)
    ) dut (
        .clk(clk), .reset(reset), .writer_release_i(writer_release),
        .fetch_if(fetch_if), .sink_if(sink_if),
        .writer_head_valid_o(), .writer_head_cmd_id_o(),
        .writer_head_cmd_payload_o(), .writer_head_sequence_o(),
        .fetch_complete_valid_o(), .fetch_complete_cmd_id_o(),
        .fetch_complete_sequence_o(), .install_complete_valid_o(),
        .install_complete_cmd_id_o(), .install_complete_sequence_o(),
        .fetch_head_write_beats_o(), .install_ready_ahead_o(ready_ahead),
        .cmd_occupancy_o(), .slot_occupancy_o(slots)
    );
    typedef struct packed {
        logic [2:0] slot;
        int index;
    } response_t;
    response_t waiting[$];
    int cycle = 0;
    int commands = 0;
    int requested = 0;
    int installed = 0;
    int completions = 0;
    int reused_at_capture = 0;
    int overwritten_while_held = 0;
    int reads_writes_parallel = 0;
    int bypass_captures = 0;
    int ram_captures = 0;
    int bypass_recycles = 0;

    function automatic logic [DATAW-1:0] payload(input int index);
        logic [DATAW-1:0] value;
        for (int b = 0; b < DATAW/8; ++b)
            value[b*8 +: 8] = 8'(index * 7 + b);
        return value;
    endfunction

    always @(posedge clk) begin : monitor
        int expected_beat, expected_sequence;
        if (!reset) begin
            cycle++;
            if (fetch_if.cmd_valid && fetch_if.cmd_ready)
                commands++;
            if (fetch_if.req_valid && fetch_if.req_ready) begin
                assert (fetch_if.req_tag == 3'(requested % SLOTS))
                    else $fatal(1, "ring allocation changed");
                waiting.push_back('{fetch_if.req_tag, requested});
                requested++;
                if (dut.stage_found && fetch_if.req_tag == dut.stage_slot)
                    reused_at_capture++;
            end
            if (dut.stage_response_found) begin
                assert (fetch_if.rsp_valid && !dut.stage_ram_found)
                    else $fatal(1, "response bypass also enabled RAM read");
                bypass_captures++;
                if (fetch_if.req_valid && fetch_if.req_ready
                 && fetch_if.req_tag == fetch_if.rsp_tag)
                    bypass_recycles++;
            end
            if (dut.stage_ram_found)
                ram_captures++;
            if (fetch_if.rsp_valid && dut.stage_ram_found) begin
                assert (fetch_if.rsp_tag != dut.stage_slot)
                    else $fatal(1, "RAM read/write same-slot collision");
                reads_writes_parallel++;
            end
            if (EARLY && fetch_if.rsp_valid && dut.drain_stage_valid_r
             && fetch_if.rsp_tag == dut.drain_stage_slot_r && !sink_if.write_ready)
                overwritten_while_held++;
            // Physical slot zero is reused and rewritten while its old beat
            // remains in the RAM output or private bypass register. Check every
            // metadata and payload bit even while the writer fence is closed.
            if (dut.drain_stage_valid_r && installed == 0) begin
                assert (sink_if.write_payload === {8'ha0, COUNTW'(0), payload(0)}
                     && sink_if.write_tag === {SEQW'(0), COUNTW'(0)}
                     && !sink_if.write_last)
                    else $fatal(1, "reallocated RAM slot corrupted held stage");
            end
            if (sink_if.write_valid && sink_if.write_ready) begin
                expected_sequence = installed < 12 ? 0 : 1;
                expected_beat = installed < 12 ? installed : installed - 12;
                assert (sink_if.write_payload === {
                    8'(8'ha0 + expected_sequence), COUNTW'(expected_beat), payload(installed)})
                    else $fatal(1, "ordered sink payload mismatch early=%0b index=%0d", EARLY, installed);
                assert (sink_if.write_tag == {SEQW'(expected_sequence), COUNTW'(expected_beat)})
                    else $fatal(1, "stage tag changed after slot reuse");
                assert (sink_if.write_last == (installed == 11 || installed == 22))
                    else $fatal(1, "early command completion");
                installed++;
            end
            if (sink_if.install_complete)
                completions++;
            if (cycle == 50) begin
                assert (installed == 0 && completions == 0)
                    else $fatal(1, "physical slot release committed a stalled write");
                assert (requested == (EARLY ? 9 : 8))
                    else $fatal(1, "expected existing sink-stage capacity early=%0b req=%0d", EARLY, requested);
                assert (ready_ahead == 8)
                    else $fatal(1, "ready prefix omitted staged beat or exceeded public capacity");
            end
            if (installed == 23) begin
                assert (commands == 2 && completions == 2)
                    else $fatal(1, "command completion count mismatch");
                if (EARLY)
                    assert (reused_at_capture > 0 && overwritten_while_held > 0
                         && reads_writes_parallel > 0)
                        else $fatal(1, "early release coverage missing");
                if (BYPASS)
                    assert (bypass_captures > 0 && ram_captures > 0
                         && bypass_recycles > 0)
                        else $fatal(1, "mixed RAM/bypass/recycle coverage missing");
                else
                    assert (bypass_captures == 0)
                        else $fatal(1, "disabled bypass changed legacy path");
                if (!done)
                    $display("EARLY_RELEASE_CASE_PASS early=%0b bypass=%0b dataw=%0d fast=%0d ram=%0d recycle=%0d held_overwrite=%0d",
                             EARLY, BYPASS, DATAW, bypass_captures, ram_captures,
                             reused_at_capture, overwritten_while_held);
                done = 1;
            end
            if (cycle > 500)
                $fatal(1, "early release timeout");
        end
    end

    always @(negedge clk) begin : drive
        response_t rsp;
        if (reset) begin
            fetch_if.cmd_valid = 0;
            fetch_if.cmd_id = 0;
            fetch_if.cmd_payload = 0;
            fetch_if.cmd_total_beats = 0;
            fetch_if.req_ready = 0;
            fetch_if.rsp_valid = 0;
            fetch_if.rsp_tag = 0;
            fetch_if.rsp_payload = 0;
            sink_if.write_ready = 0;
            writer_release = 0;
        end else begin
            fetch_if.cmd_valid = commands < 2;
            fetch_if.cmd_id = 32'(commands);
            fetch_if.cmd_payload = {8'(commands), 8'(8'ha0 + commands)};
            fetch_if.cmd_total_beats = COUNTW'(commands == 0 ? 12 : 11);
            fetch_if.req_ready = cycle < 80 || cycle % 7 != 0;
            writer_release = cycle >= 25;
            sink_if.write_ready = cycle >= 60 && cycle % 4 != 0;
            fetch_if.rsp_valid = 0;
            // Fill all eight physical slots first, then return their responses
            // in reverse order. Subsequent responses overlap stage captures.
            if (requested >= 8 && waiting.size() != 0) begin
                rsp = waiting.pop_back();
                fetch_if.rsp_valid = 1;
                fetch_if.rsp_tag = rsp.slot;
                fetch_if.rsp_payload = payload(rsp.index);
            end
        end
    end
endmodule

// Directed fast-path schedule: ten ordered response captures, three incoming
// responses while the fast stage is stalled, exactly three RAM-drain clocks,
// then an ordered response on the last RAM-stage consumption edge. This
// requires real fast->RAM->fast turnovers, not just one fast initial beat.
module ordered_bypass_case (
    input wire clk,
    input wire reset,
    output logic done = 0
);
    localparam int DATAW = 512;
    localparam int COUNTW = 4;
    localparam int SEQW = 2;
    localparam int COMMANDS = 8;
    localparam int BEATS = 4;
    localparam int TOTAL = COMMANDS * BEATS;
    VX_gemm_dma_fetch_if #(
        .CMD_PAYLOADW(16), .REQ_PAYLOADW(8+COUNTW),
        .RSP_PAYLOADW(DATAW), .TAGW(3), .COUNTW(COUNTW),
        .SLOT_COUNTW(4), .SLOT_CAPACITY(8)
    ) fetch_if (clk, reset);
    VX_gemm_dma_sink_if #(
        .PAYLOADW(8+COUNTW+DATAW), .TAGW(SEQW+COUNTW), .COUNTW(COUNTW)
    ) sink_if (clk, reset);
    VX_gemm_stream_dma_queue #(
        .INSTANCE_ID("ordered_bypass_test"), .CMD_FIFO_DEPTH(4),
        .RESPONSE_SLOTS(8), .SOURCE_METAW(8), .DEST_METAW(8),
        .DATAW(DATAW), .COUNTW(COUNTW), .SEQW(SEQW), .FETCH_TAGW(3),
        .RING_SLOT_ORDER(1), .SINK_PIPELINE(1), .RESPONSE_DATA_RAM(1),
        .SAME_CYCLE_SLOT_RECYCLE(1), .EARLY_SLOT_RELEASE(1),
        .RESPONSE_STAGE_BYPASS(1)
    ) dut (
        .clk(clk), .reset(reset), .writer_release_i(1'b1),
        .fetch_if(fetch_if), .sink_if(sink_if),
        .writer_head_valid_o(), .writer_head_cmd_id_o(),
        .writer_head_cmd_payload_o(), .writer_head_sequence_o(),
        .fetch_complete_valid_o(), .fetch_complete_cmd_id_o(),
        .fetch_complete_sequence_o(), .install_complete_valid_o(),
        .install_complete_cmd_id_o(), .install_complete_sequence_o(),
        .fetch_head_write_beats_o(), .install_ready_ahead_o(),
        .cmd_occupancy_o(), .slot_occupancy_o()
    );
    typedef struct packed {
        logic [2:0] slot;
        int index;
    } response_t;
    response_t waiting[$];
    int cycle = 0;
    int commands = 0;
    int requests = 0;
    int responses = 0;
    int installed = 0;
    int completed = 0;
    int pause_cycles = 0;
    int fast_count = 0;
    int ram_count = 0;
    int fast_streak = 0;
    int max_fast_streak = 0;
    int fast_to_ram = 0;
    int ram_to_fast = 0;
    int fast_stall_cycles = 0;
    int wrapped_sequence_writes = 0;

    function automatic logic [DATAW-1:0] payload(input int index);
        logic [DATAW-1:0] value;
        for (int b = 0; b < DATAW/8; ++b)
            value[b*8 +: 8] = 8'(index * 13 + b * 3);
        return value;
    endfunction

    always @(posedge clk) begin : check
        if (!reset) begin
            cycle++;
            if (fetch_if.cmd_valid && fetch_if.cmd_ready)
                commands++;
            if (fetch_if.req_valid && fetch_if.req_ready) begin
                assert (fetch_if.req_tag == 3'(requests % 8)
                     && fetch_if.req_payload == {8'(requests / BEATS), COUNTW'(requests % BEATS)})
                    else $fatal(1, "ordered bypass request metadata mismatch");
                waiting.push_back('{fetch_if.req_tag, requests});
                requests++;
            end
            if (fetch_if.rsp_valid)
                responses++;
            if (dut.stage_response_found) begin
                fast_count++;
                fast_streak++;
                if (fast_streak > max_fast_streak)
                    max_fast_streak = fast_streak;
            end else begin
                fast_streak = 0;
            end
            if (dut.stage_ram_found)
                ram_count++;
            if (dut.sink_write_fire && dut.stage_found) begin
                if (dut.g_response_stage_bypass.selected_r && dut.stage_ram_found)
                    fast_to_ram++;
                if (!dut.g_response_stage_bypass.selected_r && dut.stage_response_found)
                    ram_to_fast++;
            end
            if (sink_if.write_valid && !sink_if.write_ready
             && dut.g_response_stage_bypass.selected_r)
                fast_stall_cycles++;
            if (sink_if.write_valid && sink_if.write_ready) begin
                assert (sink_if.write_payload === {
                    8'(8'hb0 + installed / BEATS), COUNTW'(installed % BEATS), payload(installed)})
                    else $fatal(1, "ordered bypass payload mismatch beat=%0d", installed);
                assert (sink_if.write_tag == {SEQW'(installed / BEATS), COUNTW'(installed % BEATS)}
                     && sink_if.write_last == (installed % BEATS == BEATS-1))
                    else $fatal(1, "ordered bypass tag/last mismatch beat=%0d", installed);
                if (installed / BEATS >= (1 << SEQW))
                    wrapped_sequence_writes++;
                installed++;
            end
            if (sink_if.install_complete)
                completed++;
            if (installed == TOTAL && !done) begin
                assert (commands == COMMANDS && completed == COMMANDS
                     && requests == TOTAL && responses == TOTAL
                     && max_fast_streak >= 8 && fast_to_ram > 0 && ram_to_fast > 0
                     && fast_stall_cycles >= 3 && wrapped_sequence_writes > 0
                     && ram_count >= 3)
                    else $fatal(1, "ordered bypass coverage gap fast_streak=%0d f2r=%0d r2f=%0d stalls=%0d ram=%0d wrap=%0d",
                                max_fast_streak, fast_to_ram, ram_to_fast,
                                fast_stall_cycles, ram_count, wrapped_sequence_writes);
                $display("ORDERED_BYPASS_CASE_PASS fast=%0d ram=%0d consecutive_fast=%0d fast_to_ram=%0d ram_to_fast=%0d fast_stalls=%0d wrapped_sequence_writes=%0d",
                         fast_count, ram_count, max_fast_streak, fast_to_ram,
                         ram_to_fast, fast_stall_cycles, wrapped_sequence_writes);
                done = 1;
            end
            if (cycle > 500)
                $fatal(1, "ordered bypass timeout");
        end
    end

    always @(negedge clk) begin : drive
        response_t rsp;
        bit offer_response;
        if (reset) begin
            fetch_if.cmd_valid = 0;
            fetch_if.cmd_id = 0;
            fetch_if.cmd_payload = 0;
            fetch_if.cmd_total_beats = 0;
            fetch_if.req_ready = 0;
            fetch_if.rsp_valid = 0;
            fetch_if.rsp_tag = 0;
            fetch_if.rsp_payload = 0;
            sink_if.write_ready = 0;
        end else begin
            fetch_if.cmd_valid = commands < COMMANDS;
            fetch_if.cmd_id = 32'(commands);
            fetch_if.cmd_payload = {8'(commands), 8'(8'hb0 + commands)};
            fetch_if.cmd_total_beats = COUNTW'(BEATS);
            fetch_if.req_ready = 1;
            sink_if.write_ready = !(responses >= 10 && responses < 13);
            offer_response = requests >= 8 && waiting.size() != 0;
            if (responses == 13 && pause_cycles < 3) begin
                offer_response = 0;
                pause_cycles++;
            end
            fetch_if.rsp_valid = 0;
            if (offer_response) begin
                rsp = waiting.pop_front();
                fetch_if.rsp_valid = 1;
                fetch_if.rsp_tag = rsp.slot;
                fetch_if.rsp_payload = payload(rsp.index);
            end
        end
    end
endmodule

module tb_gemm_stream_dma_early_release;
    logic clk = 0, reset = 1;
    wire early32_done, early64_done, legacy_done, bypass32_done, bypass64_done;
    wire ordered_done;
    always #5 clk = ~clk;
    early_release_case #(.EARLY(1), .DATAW(256)) u_early32 (
        .clk(clk), .reset(reset), .done(early32_done));
    early_release_case #(.EARLY(1), .DATAW(512)) u_early64 (
        .clk(clk), .reset(reset), .done(early64_done));
    early_release_case #(.EARLY(0), .DATAW(512)) u_legacy (
        .clk(clk), .reset(reset), .done(legacy_done));
    early_release_case #(.EARLY(1), .BYPASS(1), .DATAW(256)) u_bypass32 (
        .clk(clk), .reset(reset), .done(bypass32_done));
    early_release_case #(.EARLY(1), .BYPASS(1), .DATAW(512)) u_bypass64 (
        .clk(clk), .reset(reset), .done(bypass64_done));
    ordered_bypass_case u_ordered (
        .clk(clk), .reset(reset), .done(ordered_done));
    initial begin
        repeat (4) @(negedge clk);
        #1 reset = 0;
        wait (early32_done && early64_done && legacy_done && bypass32_done && bypass64_done && ordered_done);
        $display("TEST PASSED: RAM/ordered-response stage capture, early slot reuse, held metadata, OoO responses, ring and completion");
        $finish;
    end
endmodule
