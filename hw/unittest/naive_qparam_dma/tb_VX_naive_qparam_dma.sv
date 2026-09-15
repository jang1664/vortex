`include "VX_define.vh"
`include "VX_naive_qparam_types.vh"
`ifndef TB_RESPONSE_SLOTS
`define TB_RESPONSE_SLOTS 8
`endif
`ifndef TB_LANE_FIFO_DEPTH
`define TB_LANE_FIFO_DEPTH 4
`endif
`ifndef TB_TAG_WIDTH
`define TB_TAG_WIDTH GEMM_BASE_TAG_WIDTH
`endif
module tb_VX_naive_qparam_dma;
    import VX_gpu_pkg::*;
    `VX_NAIVE_QPARAM_TYPES
    localparam integer BYTES = `GEMM_SCALE_ZERO_DATA_SIZE;
    localparam integer LANES = BYTES / 8;
    localparam integer TAGW = `TB_TAG_WIDTH;
    localparam integer RELEASE = 257;
    localparam integer RESPONSE_SLOTS = `TB_RESPONSE_SLOTS;
    localparam integer LANE_FIFO_DEPTH = `TB_LANE_FIFO_DEPTH;
    logic clk = 0;
    always #5 clk = ~clk;
    logic reset;
    logic [1:0] cmd_valid, activate_valid, writer_release, sink_ready, done_ready;
    wire [1:0] cmd_ready, activate_ready, head_valid, sink_valid, sink_last, sink_bank;
    logic [1:0][31:0] cmd_id, activate_id;
    logic [1:0][234:0] cmd_payload;
    wire [1:0][234:0] head_payload;
    wire [1:0][31:0] head_id, sink_id, sink_sequence;
    wire [1:0][15:0] sink_addr, sink_segment;
    wire [1:0][BYTES*8-1:0] sink_data;
    wire [1:0][BYTES-1:0] sink_mask;
    wire [1:0] source_done, source_buffer, install_done, done_bank;
    wire [1:0][31:0] source_id, source_sequence, source_generation;
    wire [1:0][31:0] done_id, done_sequence, done_target;
    wire [1:0][2:0] occupancy;
    wire [1:0][$clog2(RESPONSE_SLOTS+1)-1:0] slots;
    wire [1:0][LANES-1:0] req_valid;
    logic [1:0][LANES-1:0] req_ready, rsp_valid;
    wire [1:0][LANES-1:0] rsp_ready;
    wire [1:0][LANES-1:0][`MEM_ADDR_WIDTH-4:0] req_addr;
    wire [1:0][LANES-1:0][TAGW-1:0] req_tag;
    logic [1:0][LANES-1:0][TAGW-1:0] rsp_tag;
    logic [1:0][LANES-1:0][63:0] rsp_data;
    wire [1:0][LANES-1:0][7:0] req_mask;
    for (genvar engine = 0; engine < 2; ++engine) begin : g_engine
        VX_mem_bus_if #(.DATA_SIZE(8), .TAG_WIDTH(TAGW)) memory[LANES]();
        VX_naive_qparam_dma #(.INSTANCE_ID("qparam_test"),
            .RESPONSE_SLOTS(RESPONSE_SLOTS), .LANE_FIFO_DEPTH(LANE_FIFO_DEPTH),
            .TAG_WIDTH(TAGW)) dut (
            .clk(clk), .reset(reset), .cmd_valid_i(cmd_valid[engine]),
            .cmd_ready_o(cmd_ready[engine]), .cmd_id_i(cmd_id[engine]),
            .cmd_payload_i(cmd_payload[engine]),
            .activate_valid_i(activate_valid[engine]), .activate_ready_o(activate_ready[engine]),
            .activate_id_i(activate_id[engine]),
            .writer_head_valid_o(head_valid[engine]), .writer_head_payload_o(head_payload[engine]),
            .writer_head_id_o(head_id[engine]), .writer_release_i(writer_release[engine]),
            .lane_bus_if(memory), .install_valid_o(sink_valid[engine]),
            .install_ready_i(sink_ready[engine]), .install_data_o(sink_data[engine]),
            .install_byteen_o(sink_mask[engine]), .install_addr_o(sink_addr[engine]),
            .install_bank_o(sink_bank[engine]), .install_id_o(sink_id[engine]),
            .install_sequence_o(sink_sequence[engine]), .install_segment_o(sink_segment[engine]),
            .install_last_o(sink_last[engine]), .source_done_valid_o(source_done[engine]),
            .source_done_id_o(source_id[engine]), .source_done_sequence_o(source_sequence[engine]),
            .source_done_buffer_o(source_buffer[engine]), .source_done_generation_o(source_generation[engine]),
            .install_done_valid_o(install_done[engine]), .install_done_ready_i(done_ready[engine]),
            .install_done_id_o(done_id[engine]), .install_done_sequence_o(done_sequence[engine]),
            .install_done_bank_o(done_bank[engine]), .install_done_target_o(done_target[engine]),
            .cmd_occupancy_o(occupancy[engine]), .slot_occupancy_o(slots[engine])
        );
        for (genvar lane = 0; lane < LANES; ++lane) begin : g_lane
            assign req_valid[engine][lane] = memory[lane].req_valid;
            assign req_addr[engine][lane] = memory[lane].req_data.addr;
            assign req_tag[engine][lane] = memory[lane].req_data.tag;
            assign req_mask[engine][lane] = memory[lane].req_data.byteen;
            assign memory[lane].req_ready = req_ready[engine][lane];
            assign memory[lane].rsp_valid = rsp_valid[engine][lane];
            assign memory[lane].rsp_data.data = rsp_data[engine][lane];
            assign memory[lane].rsp_data.tag = rsp_tag[engine][lane];
            assign rsp_ready[engine][lane] = memory[lane].rsp_ready;
        end
    end

    // Test-only immutable byte image: resource, descriptor generation and
    // physical source coordinates all participate; no DUT payload is an oracle.
    function automatic byte image_byte(input longint unsigned address);
        return 8'((address * 13) ^ (address >> 5) ^ (address >> 11) ^ (address >> 15));
    endfunction
    function automatic naive_qparam_desc_t descriptor(input int engine, command, qrow);
        naive_qparam_desc_t d;
        d = '0;
        d.source.base = 34'('h10000 + engine * 'h10000 + command * 'h1000);
        d.source.stride = (qrow != 0) ? 8 : BYTES;
        d.source.segments = 16'((qrow != 0) ? BYTES / 2 : RESPONSE_SLOTS / 2);
        d.source.useful_bytes = 16'((qrow != 0) ? 2 : (command == 3 ? BYTES - 2 : BYTES));
        if (qrow != 0)
            d.source.base += 34'd6;
        else if (command == 3)
            d.source.base += 34'd2;
        d.source.buffer_id = 1'(command / 2);
        d.source.generation = 32'(command + 1);
        d.dest.bank = 1'(command / 2);
        d.dest.qrow = 1'(qrow);
        d.dest.offset = 16'((qrow != 0) || command == 3 ? 2 : 0);
        d.dest.stride = 16'((qrow != 0) ? 2 : BYTES);
        d.dest.writer_wait = {37'd0, command[0]};
        d.dest.install_target = 32'(command % 2 + 1);
        return d;
    endfunction

    bit pending[2][LANES][RESPONSE_SLOTS];
    bit response_taken[2][LANES];
    longint unsigned address_r[2][LANES][RESPONSE_SLOTS];
    int accepted_at[2][LANES][RESPONSE_SLOTS], due_at[2][LANES][RESPONSE_SLOTS];
    int submitted[2], activated[2], installed[2][4], returned[2][4];
    int requests[2][4][LANES], request_number[2][LANES];
    int source_completions[2], install_completions[2], consumed[2];
    int peak_commands[2], peak_slots[2], first_complement_request, release_edge, blocked_edge;
    bit sink_was_stalled[2];
    logic [BYTES*8+BYTES+16+1+32+32+16:0] stalled_sink[2];
    bit request_was_stalled[2][LANES];
    logic [`MEM_ADDR_WIDTH-3+TAGW+8-1:0] stalled_request[2][LANES];
    bit seen_request_delay[16];
    bit seen_sink_delay[16];
    int sink_age[2], desired_sink_delay;
    int eligible_age[2][LANES], actual_wait[2][LANES];
    bit overlap_response, overlap_install, reorder_seen, preactivate_fetch;

    task automatic run_case(input int qrow, blocked);
        int complementary, cycle, chosen, generation, segment, bank, total;
        longint unsigned source_address, destination_address;
        naive_qparam_desc_t d, head;
        bit finished, blocked_now;
        logic [BYTES-1:0] expected_mask;
        complementary = 1 - blocked;
        reset = 1;
        cmd_valid = '0; activate_valid = '0; writer_release = '0;
        sink_ready = '0; done_ready = '0; req_ready = '0; rsp_valid = '0;
        cmd_id = '0; activate_id = '0; cmd_payload = '0; rsp_tag = '0; rsp_data = '0;
        foreach (pending[e,l,t]) pending[e][l][t] = 0;
        foreach (submitted[e]) begin
            submitted[e] = 0; activated[e] = 0;
            source_completions[e] = 0; install_completions[e] = 0;
            peak_commands[e] = 0; peak_slots[e] = 0; sink_was_stalled[e] = 0; sink_age[e] = 0;
        end
        foreach (installed[e,c]) begin installed[e][c] = 0; returned[e][c] = 0; end
        foreach (requests[e,c,l]) requests[e][c][l] = 0;
        foreach (request_number[e,l]) begin
            request_number[e][l] = 0; eligible_age[e][l] = 0;
            actual_wait[e][l] = 0; request_was_stalled[e][l] = 0; response_taken[e][l] = 0;
        end
        consumed[0] = 0; consumed[1] = 0;
        foreach (seen_request_delay[i]) begin seen_request_delay[i] = 0; seen_sink_delay[i] = 0; end
        first_complement_request = -1; release_edge = -1; blocked_edge = -1;
        overlap_response = 0; overlap_install = 0;
        reorder_seen = 0; preactivate_fetch = 0; finished = 0;
        repeat (4) @(negedge clk);
        reset = 0;
        for (cycle = 0; cycle < 524288; ++cycle) begin
            // This task exclusively drives the memory/consumer environment.
            // All responses are stable once selected until physical acceptance.
            for (int e = 0; e < 2; ++e) begin
                cmd_valid[e] = submitted[e] < 4;
                cmd_id[e] = 32'(submitted[e]);
                cmd_payload[e] = descriptor(e, submitted[e], qrow);
                if (e == complementary) begin
                    // Ordinary command / simultaneous prepare+issue path:
                    // one admission and activation on that same edge.
                    activate_valid[e] = cmd_valid[e];
                    activate_id[e] = cmd_id[e];
                end else begin
                    activate_valid[e] = cycle >= 32 && activated[e] < submitted[e];
                    activate_id[e] = 32'(activated[e]);
                end
                head = naive_qparam_desc_t'(head_payload[e]);
                writer_release[e] = head_valid[e] && consumed[head.dest.bank] >= int'(head.dest.writer_wait);
                case (int'(sink_segment[e]) % 4)
                    0: desired_sink_delay = 0;
                    1: desired_sink_delay = 1;
                    2: desired_sink_delay = 7;
                    default: desired_sink_delay = 15;
                endcase
                sink_ready[e] = sink_age[e] >= desired_sink_delay;
                done_ready[e] = cycle % 8 == e;
                for (int l = 0; l < LANES; ++l) begin
                    req_ready[e][l] = !(e == complementary && (release_edge < 0 || cycle < release_edge))
                        && eligible_age[e][l] >= (request_number[e][l] + l) % 16;
                    if (response_taken[e][l]) begin
                        rsp_valid[e][l] = 0;
                        response_taken[e][l] = 0;
                    end
                    if (!rsp_valid[e][l]) begin
                        chosen = -1;
                        for (int t = 0; t < RESPONSE_SLOTS; ++t)
                            if (pending[e][l][t] && cycle >= due_at[e][l][t]
                             && (chosen < 0 || accepted_at[e][l][t] > accepted_at[e][l][chosen]))
                                chosen = t;
                        if (chosen >= 0) begin
                            rsp_valid[e][l] = 1;
                            rsp_tag[e][l] = TAGW'(chosen);
                            for (int b = 0; b < 8; ++b)
                                rsp_data[e][l][b*8 +: 8] = image_byte(address_r[e][l][chosen] + 64'(b));
                            for (int t = 0; t < RESPONSE_SLOTS; ++t)
                                if (pending[e][l][t] && accepted_at[e][l][t] < accepted_at[e][l][chosen])
                                    reorder_seen = 1;
                        end
                    end
                end
            end
            // Both engines contend for one request port per physical lane.
            // Resolve a collision before either reaches its 16-cycle deadline.
            for (int l = 0; l < LANES; ++l) begin
                if (req_valid[0][l] && req_valid[1][l]
                 && release_edge >= 0 && cycle >= release_edge) begin
                    if (eligible_age[0][l] >= 14 || eligible_age[1][l] >= 14) begin
                        chosen = eligible_age[0][l] >= eligible_age[1][l] ? 0 : 1;
                        req_ready[chosen][l] = 1;
                        req_ready[1-chosen][l] = 0;
                    end else if (req_ready[0][l] && req_ready[1][l]) begin
                        chosen = eligible_age[0][l] >= eligible_age[1][l] ? 0 : 1;
                        req_ready[1-chosen][l] = 0;
                    end
                end
            end
            @(posedge clk);
            blocked_now = head_valid[blocked] && head_id[blocked] == 1 && !writer_release[blocked];
            if (blocked_now && blocked_edge < 0) begin
                blocked_edge = cycle;
                release_edge = cycle + RELEASE;
            end
            for (int e = 0; e < 2; ++e) begin
                if (int'(occupancy[e]) > peak_commands[e]) peak_commands[e] = int'(occupancy[e]);
                if (int'(slots[e]) > peak_slots[e]) peak_slots[e] = int'(slots[e]);
                if (cmd_valid[e] && cmd_ready[e]) submitted[e]++;
                if (activate_valid[e] && activate_ready[e]) activated[e]++;
                for (int l = 0; l < LANES; ++l) begin
                    if (request_was_stalled[e][l])
                        assert (req_valid[e][l] && {req_addr[e][l],req_tag[e][l],req_mask[e][l]} === stalled_request[e][l])
                            else $fatal(1, "Unstable stalled request");
                    request_was_stalled[e][l] = req_valid[e][l] && !req_ready[e][l];
                    stalled_request[e][l] = {req_addr[e][l],req_tag[e][l],req_mask[e][l]};
                    if (req_valid[e][l] && !(e == complementary && (release_edge < 0 || cycle < release_edge))) eligible_age[e][l]++;
                    if (req_valid[e][l] && req_ready[e][l]) begin
                        chosen = int'(req_tag[e][l]);
                        assert (chosen < RESPONSE_SLOTS && !pending[e][l][chosen]) else $fatal(1, "Unreserved/reused tag");
                        assert (req_mask[e][l] == 255) else $fatal(1, "Not a full-lane source read");
                        source_address = 64'(req_addr[e][l]) * 8;
                        generation = int'((source_address - 'h10000 - e * 'h10000) / 'h1000);
                        assert (generation >= 0 && generation < submitted[e]) else $fatal(1, "Wrong engine/descriptor source");
                        d = descriptor(e, generation, qrow);
                        segment = requests[e][generation][l];
                        assert (source_address == ((64'(d.source.base) + segment * d.source.stride) / 64'(BYTES)) * BYTES + l*8)
                            else $fatal(1, "Physical source mapping mismatch");
                        requests[e][generation][l]++;
                        pending[e][l][chosen] = 1;
                        address_r[e][l][chosen] = source_address;
                        accepted_at[e][l][chosen] = cycle;
                        due_at[e][l][chosen] = cycle + (request_number[e][l] % 2 == 0 ? 45 : 1) + l;
                        request_number[e][l]++;
                        assert (eligible_age[e][l] <= 16) else $fatal(1, "Request fairness bound");
                        seen_request_delay[eligible_age[e][l]-1] = 1;
                        eligible_age[e][l] = 0;
                        if (activated[e] == 0) preactivate_fetch = 1;
                        if (e == complementary && first_complement_request < 0) first_complement_request = cycle;
                    end
                    if (rsp_valid[e][l] && rsp_ready[e][l]) begin
                        chosen = int'(rsp_tag[e][l]);
                        assert (pending[e][l][chosen] && cycle - accepted_at[e][l][chosen] <= 64)
                            else $fatal(1, "Response ownership/fairness bound");
                        generation = int'((address_r[e][l][chosen] - 'h10000 - e * 'h10000) / 'h1000);
                        returned[e][generation]++;
                        pending[e][l][chosen] = 0;
                        response_taken[e][l] = 1;
                        if (e == complementary && blocked_now) overlap_response = 1;
                    end
                end
                if (sink_was_stalled[e])
                    assert (sink_valid[e] && {sink_data[e],sink_mask[e],sink_addr[e],sink_bank[e],sink_id[e],sink_sequence[e],sink_segment[e],sink_last[e]} === stalled_sink[e])
                        else $fatal(1, "Unstable stalled install");
                sink_was_stalled[e] = sink_valid[e] && !sink_ready[e];
                stalled_sink[e] = {sink_data[e],sink_mask[e],sink_addr[e],sink_bank[e],sink_id[e],sink_sequence[e],sink_segment[e],sink_last[e]};
                if (sink_valid[e]) sink_age[e]++;
                if (sink_valid[e] && sink_ready[e]) begin
                    assert (sink_age[e] <= 16) else $fatal(1, "Sink fairness bound");
                    seen_sink_delay[sink_age[e]-1] = 1;
                    sink_age[e] = 0;
                    generation = int'(sink_id[e]);
                    d = descriptor(e, generation, qrow);
                    segment = installed[e][generation];
                    destination_address = 64'(d.dest.offset) + 64'(segment) * 64'(d.dest.stride);
                    source_address = 64'(d.source.base) + 64'(segment) * 64'(d.source.stride);
                    expected_mask = (({BYTES{1'b1}} >> (BYTES-int'(d.source.useful_bytes))) << (destination_address % 64'(BYTES)));
                    assert (sink_sequence[e] == 32'(generation) && sink_bank[e] == d.dest.bank
                         && sink_segment[e] == 16'(segment) && sink_mask[e] == expected_mask
                         && sink_addr[e] == 16'(destination_address / 64'(BYTES))
                         && sink_last[e] == (segment+1 == int'(d.source.segments)))
                        else $fatal(1, "Install identity/address/mask mismatch");
                    assert (consumed[d.dest.bank] >= int'(d.dest.writer_wait)) else $fatal(1, "Premature bank overwrite");
                    for (int b = 0; b < int'(d.source.useful_bytes); ++b)
                        assert (sink_data[e][(int'(destination_address % 64'(BYTES))+b)*8 +: 8] === image_byte(source_address+64'(b)))
                            else $fatal(1, "Immutable payload mismatch engine=%0d command=%0d segment=%0d byte=%0d",e,generation,segment,b);
                    installed[e][generation]++;
                    if (e == complementary && blocked_now) overlap_install = 1;
                end
                if (source_done[e]) begin
                    generation = source_completions[e];
                    d = descriptor(e, generation, qrow);
                    assert (source_id[e] == 32'(generation) && source_sequence[e] == 32'(generation)
                         && source_buffer[e] == d.source.buffer_id && source_generation[e] == d.source.generation
                         && returned[e][generation] == int'(d.source.segments)*LANES)
                        else $fatal(1, "Source completion lost identity or preceded lane capture");
                    source_completions[e]++;
                end
                if (install_done[e] && done_ready[e]) begin
                    generation = install_completions[e];
                    d = descriptor(e, generation, qrow);
                    assert (done_id[e] == 32'(generation) && done_sequence[e] == 32'(generation)
                         && done_bank[e] == d.dest.bank && done_target[e] == d.dest.install_target
                         && installed[e][generation] == int'(d.source.segments))
                        else $fatal(1, "Install completion lost/duplicated owner");
                    install_completions[e]++;
                end
            end
            // Reachable consumer: only consume after BOTH actual operand
            // commands have completed installs. This releases the next writer.
            for (int c = 0; c < 4; ++c) begin
                d = descriptor(0,c,qrow);
                if (install_completions[0] > c && install_completions[1] > c
                 && consumed[d.dest.bank] < c%2+1)
                    consumed[d.dest.bank] = c%2+1;
            end
            if (release_edge >= 0 && cycle == release_edge + 64)
                assert (first_complement_request >= release_edge && first_complement_request <= release_edge + 64)
                    else $fatal(1, "Complementary request progress timeout");
            if (release_edge >= 0 && cycle == release_edge + 32768)
                assert (install_completions[complementary] > 0 && overlap_response && overlap_install)
                    else $fatal(1, "Complementary capture/install progress timeout");
            if (release_edge >= 0 && cycle > release_edge + 262144)
                $fatal(1, "All-owner retirement bound");
            if (install_completions[0] == 4 && install_completions[1] == 4) begin
                finished = 1;
                break;
            end
            @(negedge clk);
        end
        assert (finished && source_completions[0] == 4 && source_completions[1] == 4)
            else $fatal(1, "Finite full retirement bound");
        assert (peak_commands[0] == 4 && peak_commands[1] == 4 && peak_slots[blocked] == RESPONSE_SLOTS)
            else $fatal(1, "Required queue saturation not reached commands=%0d,%0d slots=%0d,%0d expected_slots=%0d",
                peak_commands[0], peak_commands[1], peak_slots[0], peak_slots[1], RESPONSE_SLOTS);
        assert (overlap_response && overlap_install && reorder_seen && preactivate_fetch
             && first_complement_request >= release_edge && first_complement_request <= release_edge + 64)
            else $fatal(1, "Missing independent progress/reordering/prepare coverage");
        foreach (seen_request_delay[i]) assert (seen_request_delay[i])
            else $fatal(1, "Missing request service delay %0d", i);
        assert (seen_sink_delay[0] && seen_sink_delay[1] && seen_sink_delay[7] && seen_sink_delay[15])
            else $fatal(1, "Missing frozen install delay coverage");
        foreach (pending[e,l,t]) assert (!pending[e][l][t]) else $fatal(1, "Leaked physical ownership");
        $display("CASE PASS bytes=%0d qrow=%0d blocked=%0d cycles=%0d peak_slots=%0d,%0d fifo_depth=%0d", BYTES,qrow,blocked,cycle,peak_slots[0],peak_slots[1],LANE_FIFO_DEPTH);
        @(negedge clk);
    endtask
    bit reset_case_mode = 0;
    int reset_case_sources = 0, reset_case_installs = 0, reset_case_dones = 0;
    always @(posedge clk) if (reset_case_mode) begin
        if (reset) begin
            reset_case_sources = 0; reset_case_installs = 0; reset_case_dones = 0;
        end else begin
            if (source_done[0]) reset_case_sources++;
            if (sink_valid[0] && sink_ready[0]) reset_case_installs++;
            if (install_done[0] && done_ready[0]) reset_case_dones++;
            assert (!source_done[1] && !sink_valid[1] && !install_done[1])
                else $fatal(1,"Idle engine produced work in reset test");
        end
    end
    task automatic run_reset_case;
        naive_qparam_desc_t d;
        bit [LANES-1:0] captured, responded;
        logic [TAGW-1:0] old_tag[LANES], tag[LANES];
        longint unsigned address[LANES];
        int cycles, flushed;
        reset_case_mode=1;
        reset=1;cmd_valid='0;activate_valid='0;writer_release='0;
        sink_ready='0;done_ready='0;req_ready='0;rsp_valid='0;
        cmd_id='0;activate_id='0;cmd_payload='0;rsp_tag='0;rsp_data='0;
        foreach(pending[e,l,t]) pending[e][l][t]=0;
        repeat(4) @(negedge clk);reset=0;
        for(int epoch=0;epoch<2;epoch++) begin
            d=descriptor(0,epoch,0);
            d.source.segments=1;d.source.useful_bytes=BYTES;
            d.dest.offset=0;d.dest.writer_wait='0;
            cmd_payload[0]=d;cmd_id[0]=0;activate_id[0]=0;
            cmd_valid[0]=1;activate_valid[0]=1;writer_release[0]=1;
            req_ready[0]='1;
            @(posedge clk);
            assert(cmd_ready[0] && activate_ready[0])else $fatal(1,"Reset test command not accepted");
            @(negedge clk);cmd_valid='0;activate_valid='0;
            captured='0;cycles=0;
            while(!(&captured)) begin
                @(posedge clk);
                for(int lane=0;lane<LANES;lane++) if(req_valid[0][lane] && req_ready[0][lane]) begin
                    assert(!captured[lane])else $fatal(1,"Duplicate reset-test request");
                    captured[lane]=1;tag[lane]=req_tag[0][lane];
                    address[lane]=64'(req_addr[0][lane])*8;
                    assert(address[lane]==64'(d.source.base)+64'(lane*8) && req_mask[0][lane]==8'hff)
                        else $fatal(1,"Reset-test request address or mask mismatch");
                    pending[0][lane][int'(tag[lane])]=1;
                    if(epoch==0)old_tag[lane]=tag[lane];
                    else assert(tag[lane]==old_tag[lane])else $fatal(1,"Reset test did not exercise tag reuse");
                end
                @(negedge clk);cycles++;
                if(cycles>256)$fatal(1,"Reset-test request timeout");
            end
            req_ready='0;
            if(epoch==0) begin
                assert(occupancy[0]==1 && slots[0]==1 && !sink_valid[0]
                    && reset_case_sources==0 && reset_case_installs==0)
                    else $fatal(1,"Reset test never reached occupied response domain");
                // Joint flush: no request or selected old response may survive.
                reset=1;rsp_valid='0;writer_release='0;flushed=0;
                foreach(pending[e,l,t])begin if(pending[e][l][t])flushed++;pending[e][l][t]=0;end
                assert(flushed==LANES)else $fatal(1,"Reset test missing outstanding lane responses");
                repeat(4) @(negedge clk);
                assert(occupancy=='0 && slots=='0 && sink_valid=='0 && source_done=='0 && install_done=='0)
                    else $fatal(1,"Occupied adapter state survived joint reset");
                foreach(pending[e,l,t])assert(!pending[e][l][t])else $fatal(1,"Old response survived model flush");
                $display("JOINT_RESET_FLUSHED pending_lanes=%0d",flushed);
                reset=0;repeat(2) @(negedge clk);
            end else begin
                for(int lane=0;lane<LANES;lane++)begin
                    assert(pending[0][lane][int'(tag[lane])])else $fatal(1,"New response has no owner");
                    rsp_valid[0][lane]=1;rsp_tag[0][lane]=tag[lane];
                    for(int byte_index=0;byte_index<8;byte_index++)
                        rsp_data[0][lane][8*byte_index+:8]=image_byte(address[lane]+64'(byte_index));
                end
                responded='0;cycles=0;
                while(!(&responded))begin
                    @(posedge clk);
                    for(int lane=0;lane<LANES;lane++)if(rsp_valid[0][lane]&&rsp_ready[0][lane])begin
                        responded[lane]=1;pending[0][lane][int'(tag[lane])]=0;
                    end
                    @(negedge clk);
                    for(int lane=0;lane<LANES;lane++)if(responded[lane])rsp_valid[0][lane]=0;
                    cycles++;if(cycles>256)$fatal(1,"Reset-test response timeout");
                end
                wait(sink_valid[0]);@(negedge clk);
                assert(sink_mask[0]=={BYTES{1'b1}} && sink_addr[0]==0 && sink_id[0]==0 && sink_last[0])
                    else $fatal(1,"Post-reset install metadata mismatch");
                for(int byte_index=0;byte_index<BYTES;byte_index++)
                    assert(sink_data[0][8*byte_index+:8]==image_byte(64'(d.source.base)+64'(byte_index)))
                        else $fatal(1,"Old payload reached post-reset install");
                sink_ready[0]=1;done_ready[0]=1;
                wait(install_done[0]);@(posedge clk);#1;@(negedge clk);
                sink_ready='0;done_ready='0;
                repeat(4) @(negedge clk);
                assert(occupancy=='0 && slots=='0 && reset_case_sources==1
                    && reset_case_installs==1 && reset_case_dones==1)
                    else $fatal(1,"Post-reset command did not retire exactly once");
                foreach(pending[e,l,t])assert(!pending[e][l][t])else $fatal(1,"Leaked reset-test response");
            end
        end
        $display("TEST PASSED occupied adapter joint reset and fresh payload with reused tags bytes=%0d",BYTES);
    endtask
    initial begin
        if($test$plusargs("RESET_ONLY")) begin
            run_reset_case();$finish;
        end
        run_case(0,0);
        run_case(0,1);
        run_case(1,0);
        run_case(1,1);
        $display("TEST PASSED naive_qparam_dma");
        $finish;
    end
endmodule
