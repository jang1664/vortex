`include "VX_define.vh"
`include "VX_naive_qparam_types.vh"

`ifdef GEMM_NAIVE
// One independent native-beat operand engine (Input, Scale, or Zero-point). No state or payload is shared
// between instances. Source completion is response capture, not installation.
// Full native-beat reads avoid a payload realigner. Only useful bytes are
// selected combinationally from the one registered response-RAM output.
module VX_naive_qparam_dma import VX_gpu_pkg::*; #(
    parameter `STRING INSTANCE_ID = "",
    parameter integer DATA_BYTES = `GEMM_SCALE_ZERO_DATA_SIZE,
    parameter integer RESPONSE_SLOTS = 8,
    parameter integer LANE_FIFO_DEPTH = 4,
    parameter integer PIPELINED_ISSUE = 0,
    parameter integer TAG_WIDTH = GEMM_BASE_TAG_WIDTH
) (
    input wire clk,
    input wire reset,
    input wire cmd_valid_i,
    output wire cmd_ready_o,
    input wire [31:0] cmd_id_i,
    input wire [234:0] cmd_payload_i,
    input wire activate_valid_i,
    input wire [31:0] activate_id_i,
    output wire activate_ready_o,
    output wire writer_head_valid_o,
    output wire [234:0] writer_head_payload_o,
    output wire [31:0] writer_head_id_o,
    input wire writer_release_i,
    VX_mem_bus_if.master lane_bus_if [DATA_BYTES / 8],
    output wire install_valid_o,
    input wire install_ready_i,
    output wire [DATA_BYTES*8-1:0] install_data_o,
    output wire [DATA_BYTES-1:0] install_byteen_o,
    output wire [15:0] install_addr_o,
    output wire install_bank_o,
    output wire [31:0] install_id_o,
    output wire [31:0] install_sequence_o,
    output wire [15:0] install_segment_o,
    output wire install_last_o,
    output logic source_done_valid_o,
    output logic [31:0] source_done_id_o,
    output logic [31:0] source_done_sequence_o,
    output logic source_done_buffer_o,
    output logic [31:0] source_done_generation_o,
    output logic install_done_valid_o,
    input wire install_done_ready_i,
    output logic [31:0] install_done_id_o,
    output logic [31:0] install_done_sequence_o,
    output logic install_done_bank_o,
    output logic [31:0] install_done_target_o,
    output wire [2:0] cmd_occupancy_o,
    output wire [$clog2(RESPONSE_SLOTS+1)-1:0] slot_occupancy_o
);
    `VX_NAIVE_QPARAM_TYPES
    localparam integer LANES = DATA_BYTES / 8;
    localparam integer BYTE_SHIFT = $clog2(DATA_BYTES);
    localparam integer COMMANDS = 4;
    localparam integer SLOTS = RESPONSE_SLOTS;
    localparam integer SLOT_BITS = $clog2(SLOTS);
    localparam integer SLOT_COUNT_BITS = $clog2(SLOTS+1);
    naive_qparam_desc_t cmd_r [COMMANDS];
    logic [31:0] cmd_id_r [COMMANDS];
    logic [31:0] cmd_sequence_r [COMMANDS];
    logic [15:0] issued_r [COMMANDS], captured_r [COMMANDS], installed_r [COMMANDS];
    logic [COMMANDS-1:0] valid_r, source_reported_r, activated_r;
    logic [1:0] tail_r, issue_head_r, source_head_r, install_head_r;
    logic [2:0] cmd_count_r;
    logic [31:0] next_sequence_r;
    logic [SLOTS-1:0] slot_valid_r;
    logic [1:0] slot_owner_r [SLOTS];
    logic [31:0] slot_sequence_r [SLOTS];
    logic [15:0] slot_segment_r [SLOTS];
    logic [LANES-1:0] arrived_r [SLOTS], arrived_next [SLOTS];
    logic fetch_active_r;
    logic [SLOT_BITS-1:0] fetch_slot_r;
    logic [LANES-1:0] sent_r;
    wire [LANES-1:0] request_fire;
    wire request_done = fetch_active_r && (&(sent_r | request_fire));
    logic free_found;
    logic [SLOT_BITS-1:0] free_slot;
    // Input may reserve the following row while the current row's last
    // outstanding lane is accepted. Requests still use registered slot state.
    logic [1:0] allocate_owner;
    logic [15:0] allocate_segment;
    always_comb begin
        allocate_owner = issue_head_r;
        allocate_segment = issued_r[issue_head_r];
        if (PIPELINED_ISSUE && request_done) begin
            if ((issued_r[issue_head_r] + 16'd1) == cmd_r[issue_head_r].source.segments) begin
                allocate_owner = issue_head_r + 2'd1;
                allocate_segment = issued_r[allocate_owner];
            end else begin
                allocate_segment = issued_r[issue_head_r] + 16'd1;
            end
        end
    end
    // Only an already free slot and an already admitted command qualify.
    wire allocate = (!fetch_active_r || (PIPELINED_ISSUE && request_done))
                 && free_found && valid_r[allocate_owner]
                 && (allocate_segment < cmd_r[allocate_owner].source.segments);
    wire [33:0] request_byte_addr = cmd_r[slot_owner_r[fetch_slot_r]].source.base
        + 34'(slot_segment_r[fetch_slot_r]) * 34'(cmd_r[slot_owner_r[fetch_slot_r]].source.stride);

    wire [LANES-1:0] response_valid;
    wire [LANES-1:0][TAG_WIDTH-1:0] response_tag;
    wire [LANES-1:0][63:0] response_data;
    wire [LANES-1:0][63:0] ram_data;
    logic stage_valid_r;
    logic [SLOT_BITS-1:0] stage_slot_r;
    logic writer_released_r;
    logic drain_found;
    logic [SLOT_BITS-1:0] drain_slot;
    wire install_fire = install_valid_o && install_ready_i;
    wire retire = install_fire && install_last_o;
    wire load_stage = (!stage_valid_r || install_fire) && drain_found;
    wire source_complete = valid_r[source_head_r] && !source_reported_r[source_head_r]
                        && (captured_r[source_head_r] == cmd_r[source_head_r].source.segments);
    wire admit = cmd_valid_i && cmd_ready_o;
    logic activate_found;
    logic [1:0] activate_slot;
    always_comb begin
        activate_found = 1'b0;
        activate_slot = '0;
        for (int command = 0; command < COMMANDS; ++command)
            if (valid_r[command] && !activated_r[command] && cmd_id_r[command] == activate_id_i) begin
                activate_found = 1'b1;
                activate_slot = 2'(command);
            end
    end
    assign activate_ready_o = activate_found || (admit && cmd_id_i == activate_id_i);
    wire [COMMANDS-1:0][SLOT_COUNT_BITS-1:0] captured_increment;
    assign cmd_ready_o = cmd_count_r < 3'(COMMANDS);
    assign cmd_occupancy_o = cmd_count_r;
    assign writer_head_valid_o = valid_r[install_head_r];
    assign writer_head_payload_o = cmd_r[install_head_r];
    assign writer_head_id_o = cmd_id_r[install_head_r];

    always_comb begin
        free_found = 1'b0;
        free_slot = '0;
        drain_found = 1'b0;
        drain_slot = '0;
        for (int slot = 0; slot < SLOTS; ++slot) begin
            if (!free_found && !slot_valid_r[slot]) begin
                free_found = 1'b1;
                free_slot = SLOT_BITS'(slot);
            end
            if (!drain_found && slot_valid_r[slot] && (&arrived_r[slot])
             && slot_owner_r[slot] == install_head_r
             && slot_sequence_r[slot] == cmd_sequence_r[install_head_r]
             && slot_segment_r[slot] == installed_r[install_head_r] + 16'(install_fire)
             && !(stage_valid_r && stage_slot_r == SLOT_BITS'(slot))) begin
                drain_found = 1'b1;
                drain_slot = SLOT_BITS'(slot);
            end
        end
    end
    logic [SLOT_COUNT_BITS-1:0] slot_count;
    always_comb begin
        slot_count = '0;
        for (int slot = 0; slot < SLOTS; ++slot)
            slot_count += SLOT_COUNT_BITS'(slot_valid_r[slot]);
    end
    assign slot_occupancy_o = slot_count;

    for (genvar lane = 0; lane < LANES; ++lane) begin : g_lane
        assign lane_bus_if[lane].req_valid = fetch_active_r && !sent_r[lane];
        assign lane_bus_if[lane].req_data.rw = 1'b0;
        assign lane_bus_if[lane].req_data.addr = (`MEM_ADDR_WIDTH-3)'(
            ((request_byte_addr >> BYTE_SHIFT) << (BYTE_SHIFT-3)) + lane);
        assign lane_bus_if[lane].req_data.data = '0;
        assign lane_bus_if[lane].req_data.byteen = '1;
        assign lane_bus_if[lane].req_data.flags = '0;
        assign lane_bus_if[lane].req_data.tag = TAG_WIDTH'(fetch_slot_r);
        assign request_fire[lane] = lane_bus_if[lane].req_valid && lane_bus_if[lane].req_ready;
        // FIFO payload accounting: LANE_FIFO_DEPTH x 8 B RAM + one 8 B head per lane.
        VX_fifo_queue #(.DATAW(64 + TAG_WIDTH), .DEPTH(LANE_FIFO_DEPTH), .OUT_REG(1)) response_fifo (
            .clk(clk), .reset(reset),
            .push(lane_bus_if[lane].rsp_valid && lane_bus_if[lane].rsp_ready),
            .pop(response_valid[lane]),
            .data_in({lane_bus_if[lane].rsp_data.tag, lane_bus_if[lane].rsp_data.data}),
            .data_out({response_tag[lane], response_data[lane]}),
            .empty(response_empty), .full(response_full),
            .alm_empty(), .alm_full(), .size()
        );
        wire response_empty, response_full;
        assign response_valid[lane] = !response_empty;
        assign lane_bus_if[lane].rsp_ready = !response_full;
        // Each physical lane writes its own bank of the reserved wide slot.
        // Distinct lanes/tags may arrive in any order; no FIFO-head tag join.
        VX_dp_ram #(.DATAW(64), .SIZE(SLOTS), .OUT_REG(1), .RDW_MODE("R"),
                    .RADDR_REG(1), .RESET_RAM(0)) response_ram (
            .clk(clk), .reset(reset), .read(load_stage),
            .write(response_valid[lane]), .wren(1'b1),
            .waddr(SLOT_BITS'(response_tag[lane])), .wdata(response_data[lane]),
            .raddr(drain_slot), .rdata(ram_data[lane])
        );
    end

    always_comb begin
        for (int slot = 0; slot < SLOTS; ++slot) begin
            arrived_next[slot] = arrived_r[slot];
            for (int lane = 0; lane < LANES; ++lane)
                if (response_valid[lane] && response_tag[lane] == TAG_WIDTH'(slot))
                    arrived_next[slot][lane] = 1'b1;
        end
    end
    for (genvar command = 0; command < COMMANDS; ++command) begin : g_capture_count
        logic [SLOT_COUNT_BITS-1:0] increment;
        always_comb begin
            increment = '0;
            for (int slot = 0; slot < SLOTS; ++slot)
                if (slot_valid_r[slot] && slot_owner_r[slot] == 2'(command)
                 && !(&arrived_r[slot]) && (&arrived_next[slot]))
                    increment += SLOT_COUNT_BITS'(1);
        end
        assign captured_increment[command] = increment;
    end

    wire [15:0] sink_segment = slot_segment_r[stage_slot_r];
    wire [33:0] sink_source = cmd_r[install_head_r].source.base
        + 34'(sink_segment) * 34'(cmd_r[install_head_r].source.stride);
    wire [31:0] sink_destination = 32'(cmd_r[install_head_r].dest.offset)
        + 32'(sink_segment) * 32'(cmd_r[install_head_r].dest.stride);
    wire [BYTE_SHIFT-1:0] source_offset = sink_source[BYTE_SHIFT-1:0];
    wire [BYTE_SHIFT-1:0] destination_offset = sink_destination[BYTE_SHIFT-1:0];
    wire [DATA_BYTES*8-1:0] selected_data = (DATA_BYTES*8)'(ram_data) >> (source_offset * 8);
    assign install_data_o = selected_data << (destination_offset * 8);
    assign install_byteen_o = (DATA_BYTES'({DATA_BYTES{1'b1}})
        >> (DATA_BYTES - int'(cmd_r[install_head_r].source.useful_bytes))) << destination_offset;
    assign install_addr_o = 16'(sink_destination >> BYTE_SHIFT);
    assign install_bank_o = cmd_r[install_head_r].dest.bank;
    assign install_id_o = cmd_id_r[install_head_r];
    assign install_sequence_o = cmd_sequence_r[install_head_r];
    assign install_segment_o = sink_segment;
    assign install_last_o = (sink_segment + 16'd1) == cmd_r[install_head_r].source.segments;
    assign install_valid_o = stage_valid_r && writer_released_r
                         && (!install_last_o || (source_reported_r[install_head_r]
                            && (!install_done_valid_o || install_done_ready_i)));

    always_ff @(posedge clk) begin
        if (reset) begin
            valid_r <= '0;
            source_reported_r <= '0;
            activated_r <= '0;
            tail_r <= '0;
            issue_head_r <= '0;
            source_head_r <= '0;
            install_head_r <= '0;
            cmd_count_r <= '0;
            next_sequence_r <= '0;
            slot_valid_r <= '0;
            fetch_active_r <= 1'b0;
            fetch_slot_r <= '0;
            sent_r <= '0;
            stage_valid_r <= 1'b0;
            stage_slot_r <= '0;
            writer_released_r <= 1'b0;
            source_done_valid_o <= 1'b0;
            install_done_valid_o <= 1'b0;
            source_done_id_o <= '0;
            source_done_sequence_o <= '0;
            source_done_buffer_o <= '0;
            source_done_generation_o <= '0;
            install_done_id_o <= '0;
            install_done_sequence_o <= '0;
            install_done_bank_o <= '0;
            install_done_target_o <= '0;
            for (int command = 0; command < COMMANDS; ++command) begin
                cmd_r[command] <= '0;
                cmd_id_r[command] <= '0;
                cmd_sequence_r[command] <= '0;
                issued_r[command] <= '0;
                captured_r[command] <= '0;
                installed_r[command] <= '0;
            end
            for (int slot = 0; slot < SLOTS; ++slot) begin
                slot_owner_r[slot] <= '0;
                slot_sequence_r[slot] <= '0;
                slot_segment_r[slot] <= '0;
                arrived_r[slot] <= '0;
            end
        end else begin
            case ({admit, retire})
                2'b10: cmd_count_r <= cmd_count_r + 3'd1;
                2'b01: cmd_count_r <= cmd_count_r - 3'd1;
                default: begin end
            endcase
            source_done_valid_o <= source_complete;
            if (install_done_ready_i)
                install_done_valid_o <= 1'b0;
            if (retire)
                install_done_valid_o <= 1'b1;
            if (activate_valid_i && activate_found)
                activated_r[activate_slot] <= 1'b1;
            for (int command = 0; command < COMMANDS; ++command)
                captured_r[command] <= captured_r[command] + 16'(captured_increment[command]);
            for (int slot = 0; slot < SLOTS; ++slot)
                arrived_r[slot] <= arrived_next[slot];
            if (admit) begin
                valid_r[tail_r] <= 1'b1;
                source_reported_r[tail_r] <= 1'b0;
                activated_r[tail_r] <= activate_valid_i && activate_id_i == cmd_id_i;
                cmd_r[tail_r] <= naive_qparam_desc_t'(cmd_payload_i);
                cmd_id_r[tail_r] <= cmd_id_i;
                cmd_sequence_r[tail_r] <= next_sequence_r;
                issued_r[tail_r] <= '0;
                captured_r[tail_r] <= '0;
                installed_r[tail_r] <= '0;
                next_sequence_r <= next_sequence_r + 32'd1;
                tail_r <= tail_r + 2'd1;
            end
            if (allocate) begin
                slot_valid_r[free_slot] <= 1'b1;
                slot_owner_r[free_slot] <= allocate_owner;
                slot_sequence_r[free_slot] <= cmd_sequence_r[allocate_owner];
                slot_segment_r[free_slot] <= allocate_segment;
                arrived_r[free_slot] <= '0;
                fetch_active_r <= 1'b1;
                fetch_slot_r <= free_slot;
                sent_r <= '0;
            end else if (fetch_active_r) begin
                sent_r <= sent_r | request_fire;
                if (request_done) begin
                    fetch_active_r <= 1'b0;
                end
            end
            // Completion must advance issue accounting even when allocation
            // keeps fetch_active_r asserted for a consecutive request.
            if (request_done) begin
                issued_r[issue_head_r] <= issued_r[issue_head_r] + 16'd1;
                if ((issued_r[issue_head_r] + 16'd1) == cmd_r[issue_head_r].source.segments)
                    issue_head_r <= issue_head_r + 2'd1;
            end
            if (source_complete) begin
                source_reported_r[source_head_r] <= 1'b1;
                source_done_id_o <= cmd_id_r[source_head_r];
                source_done_sequence_o <= cmd_sequence_r[source_head_r];
                source_done_buffer_o <= cmd_r[source_head_r].source.buffer_id;
                source_done_generation_o <= cmd_r[source_head_r].source.generation;
                source_head_r <= source_head_r + 2'd1;
            end
            if (writer_head_valid_o && activated_r[install_head_r] && writer_release_i)
                writer_released_r <= 1'b1;
            if (install_fire) begin
                stage_valid_r <= 1'b0;
                slot_valid_r[stage_slot_r] <= 1'b0;
                installed_r[install_head_r] <= installed_r[install_head_r] + 16'd1;
            end
            if (load_stage) begin
                stage_valid_r <= 1'b1;
                stage_slot_r <= drain_slot;
            end
            if (retire) begin
                valid_r[install_head_r] <= 1'b0;
                writer_released_r <= 1'b0;
                install_done_id_o <= cmd_id_r[install_head_r];
                install_done_sequence_o <= cmd_sequence_r[install_head_r];
                install_done_bank_o <= cmd_r[install_head_r].dest.bank;
                install_done_target_o <= cmd_r[install_head_r].dest.install_target;
                install_head_r <= install_head_r + 2'd1;
            end
        end
    end

`ifndef SYNTHESIS
    initial begin
        assert ($bits(naive_qparam_desc_t) == 235 && `MEM_ADDR_WIDTH == 34);
        assert ((DATA_BYTES == 32 || DATA_BYTES == 64) && TAG_WIDTH >= 3);
        assert ((RESPONSE_SLOTS == 8 || RESPONSE_SLOTS == 16)
             && (LANE_FIFO_DEPTH == 4 || LANE_FIFO_DEPTH == 8 || LANE_FIFO_DEPTH == 16)
             && TAG_WIDTH >= SLOT_BITS);
    end
    always @(posedge clk) begin
        if (!reset) begin
            if (admit) begin : check_descriptor
                naive_qparam_desc_t d;
                d = naive_qparam_desc_t'(cmd_payload_i);
                for (int command = 0; command < COMMANDS; ++command)
                    assert (!valid_r[command] || cmd_id_r[command] != cmd_id_i)
                        else $fatal(1, "%s: duplicate prepared command identity", INSTANCE_ID);
                assert (d.source.segments != 0 && d.source.useful_bytes != 0
                     && d.source.useful_bytes <= 16'(DATA_BYTES))
                    else $fatal(1, "%s: invalid descriptor bounds", INSTANCE_ID);
                assert (!d.source.base[0] && !d.source.stride[0]
                     && !d.source.useful_bytes[0] && !d.dest.offset[0] && !d.dest.stride[0])
                    else $fatal(1, "%s: FP16 segment is not element aligned", INSTANCE_ID);
                for (int segment = 0; segment < int'(d.source.segments); ++segment) begin
                    assert ((64'(d.source.base) + 64'(segment) * 64'(d.source.stride)
                              + 64'(d.source.useful_bytes)) <= (64'd1 << 34))
                        else $fatal(1, "%s: physical address overflow", INSTANCE_ID);
                    assert (((64'(d.dest.offset) + 64'(segment) * 64'(d.dest.stride))
                              >> BYTE_SHIFT) < (64'd1 << 16))
                        else $fatal(1, "%s: destination address overflow", INSTANCE_ID);
                    assert (((d.source.base + 34'(segment) * 34'(d.source.stride)) % 34'(DATA_BYTES))
                              + 34'(d.source.useful_bytes) <= 34'(DATA_BYTES))
                        else $fatal(1, "%s: source segment crosses native beat", INSTANCE_ID);
                    assert (((32'(d.dest.offset) + 32'(segment) * 32'(d.dest.stride)) % DATA_BYTES)
                              + 32'(d.source.useful_bytes) <= DATA_BYTES)
                        else $fatal(1, "%s: destination segment crosses native beat", INSTANCE_ID);
                end
            end
            for (int lane = 0; lane < LANES; ++lane) begin
                if (response_valid[lane]) begin
                    assert ((TAG_WIDTH+1)'(response_tag[lane]) < (TAG_WIDTH+1)'(SLOTS)
                         && slot_valid_r[SLOT_BITS'(response_tag[lane])]
                         && !arrived_r[SLOT_BITS'(response_tag[lane])][lane]
                         && slot_sequence_r[SLOT_BITS'(response_tag[lane])]
                             == cmd_sequence_r[slot_owner_r[SLOT_BITS'(response_tag[lane])]])
                        else $fatal(1, "%s: unowned/duplicate lane response", INSTANCE_ID);
                end
            end
            assert (cmd_count_r <= 3'(COMMANDS) && slot_count <= SLOT_COUNT_BITS'(SLOTS));
        end
    end
`endif
endmodule
`endif
