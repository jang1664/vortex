`include "VX_define.vh"

// Layout- and source-agnostic bounded queue for GEMM operand streams.
// Command payload layout at this boundary is only:
//   {source_metadata, destination_metadata}
// Request and sink payloads are correspondingly:
//   {source_metadata, beat_index}
//   {destination_metadata, beat_index, response_data}
// The queue never interprets any metadata bit.
module VX_gemm_stream_dma_queue #(
    parameter `STRING INSTANCE_ID = "",
    parameter int CMD_FIFO_DEPTH = 4,
    parameter int RESPONSE_SLOTS = 8,
    parameter int SOURCE_METAW = 64,
    parameter int DEST_METAW = 64,
    parameter int DATAW = 512,
    parameter int COUNTW = 32,
    parameter int SEQW = 32,
    parameter int FETCH_TAGW = $clog2(RESPONSE_SLOTS),
    // Some adapters expose the physical slot number as a sequential external
    // tag.  Keep the generic queue's lowest-free allocation by default and
    // select modulo-ring ownership only for those adapters.
    parameter bit RING_SLOT_ORDER = 1'b0,
    // Preserve backends whose response storage has one registered read stage.
    // Zero keeps the original direct slot-to-sink contract.
    parameter bit SINK_PIPELINE = 1'b0,
    // Store wide response payloads in a registered-read 1R1W RAM.  Metadata
    // remains in registers and the existing sink stage owns the RAM output.
    parameter bit RESPONSE_DATA_RAM = 1'b1,
    // Most migrated executors can issue into a slot on the same edge that the
    // ordered sink releases it.  Legacy Weight exposes the newly FREE slot on
    // the following cycle, so it opts out to preserve its bank-offer schedule.
    parameter bit SAME_CYCLE_SLOT_RECYCLE = 1'b1
) (
    input wire clk,
    input wire reset,
    input wire writer_release_i,

    VX_gemm_dma_fetch_if.queue fetch_if,
    VX_gemm_dma_sink_if.queue  sink_if,

    output wire writer_head_valid_o,
    output wire [31:0] writer_head_cmd_id_o,
    output wire [SOURCE_METAW+DEST_METAW-1:0]
                       writer_head_cmd_payload_o,
    output wire [SEQW-1:0] writer_head_sequence_o,
    output wire fetch_complete_valid_o,
    output wire [31:0] fetch_complete_cmd_id_o,
    output wire [SEQW-1:0] fetch_complete_sequence_o,
    output wire install_complete_valid_o,
    output wire [31:0] install_complete_cmd_id_o,
    output wire [SEQW-1:0] install_complete_sequence_o,
    output wire [COUNTW-1:0] fetch_head_write_beats_o,
    output wire [$clog2(RESPONSE_SLOTS + 1)-1:0]
                       install_ready_ahead_o,
    output wire [$clog2(CMD_FIFO_DEPTH + 1)-1:0] cmd_occupancy_o,
    output wire [$clog2(RESPONSE_SLOTS + 1)-1:0] slot_occupancy_o
);

    localparam int CMD_PAYLOADW = SOURCE_METAW + DEST_METAW;
    localparam int REQ_PAYLOADW = SOURCE_METAW + COUNTW;
    localparam int SINK_PAYLOADW = DEST_METAW + COUNTW + DATAW;
    localparam int CMD_PTRW = (CMD_FIFO_DEPTH > 1)
                            ? $clog2(CMD_FIFO_DEPTH) : 1;
    localparam int CMD_COUNTW = $clog2(CMD_FIFO_DEPTH + 1);
    localparam int SLOT_PTRW = (RESPONSE_SLOTS > 1)
                             ? $clog2(RESPONSE_SLOTS) : 1;
    localparam int SLOT_COUNTW = $clog2(RESPONSE_SLOTS + 1);
    localparam int SINK_TAGW = SEQW + COUNTW;
    localparam int RESPONSE_RANGEW = FETCH_TAGW + 1;
    localparam bit USE_SINK_STAGE = SINK_PIPELINE || RESPONSE_DATA_RAM;

    function automatic logic [CMD_PTRW-1:0] cmd_ptr_next(
        input logic [CMD_PTRW-1:0] ptr
    );
        if ((CMD_FIFO_DEPTH == 1)
         || (ptr == CMD_PTRW'(CMD_FIFO_DEPTH - 1)))
            return '0;
        return ptr + CMD_PTRW'(1);
    endfunction

    typedef enum logic [1:0] {
        SLOT_FREE,
        SLOT_WAIT_RSP,
        SLOT_READY,
        SLOT_DRAINING
    } slot_state_e;

    logic [CMD_FIFO_DEPTH-1:0] cmd_valid_r;
    logic [CMD_FIFO_DEPTH-1:0] cmd_fetch_done_r;
    logic [31:0] cmd_id_r[CMD_FIFO_DEPTH];
    logic [CMD_PAYLOADW-1:0] cmd_payload_r[CMD_FIFO_DEPTH];
    logic [COUNTW-1:0] cmd_total_r[CMD_FIFO_DEPTH];
    logic [COUNTW-1:0] cmd_request_r[CMD_FIFO_DEPTH];
    logic [COUNTW-1:0] cmd_response_r[CMD_FIFO_DEPTH];
    logic [COUNTW-1:0] cmd_write_r[CMD_FIFO_DEPTH];
    logic [SEQW-1:0] cmd_sequence_r[CMD_FIFO_DEPTH];

    logic [CMD_PTRW-1:0] fetch_ptr_r;
    logic [CMD_PTRW-1:0] install_ptr_r;
    logic [CMD_PTRW-1:0] tail_ptr_r;
    logic [CMD_COUNTW-1:0] cmd_count_r;
    logic [SEQW-1:0] next_sequence_r;

    slot_state_e slot_state_r[RESPONSE_SLOTS];
    logic [CMD_PTRW-1:0] slot_owner_cmd_r[RESPONSE_SLOTS];
    logic [SEQW-1:0] slot_owner_sequence_r[RESPONSE_SLOTS];
    logic [COUNTW-1:0] slot_owner_beat_r[RESPONSE_SLOTS];
    logic [SLOT_COUNTW-1:0] slot_count_r;

    logic [SLOT_PTRW-1:0] alloc_slot_r;
    logic [SLOT_PTRW-1:0] install_slot_r;
    logic drain_stage_valid_r;
    logic [SLOT_PTRW-1:0] drain_stage_slot_r;
    logic drain_found;
    logic [SLOT_PTRW-1:0] drain_slot;
    logic stage_found;
    logic [SLOT_PTRW-1:0] stage_slot;
    logic [SLOT_COUNTW-1:0] install_ready_ahead;

    wire fetch_head_valid = cmd_valid_r[fetch_ptr_r]
                         && !cmd_fetch_done_r[fetch_ptr_r];
    wire install_head_valid = cmd_valid_r[install_ptr_r];

    always_comb begin
        drain_found = 1'b0;
        drain_slot = RING_SLOT_ORDER ? install_slot_r : '0;
        for (int slot = 0; slot < RESPONSE_SLOTS; ++slot) begin
            if (!drain_found
             && (!RING_SLOT_ORDER
              || (SLOT_PTRW'(slot) == install_slot_r))
             && (slot_state_r[slot] == SLOT_READY)
             && install_head_valid
             && (slot_owner_cmd_r[slot] == install_ptr_r)
             && (slot_owner_sequence_r[slot]
                 == cmd_sequence_r[install_ptr_r])
             && (slot_owner_beat_r[slot]
                 == cmd_write_r[install_ptr_r])) begin
                drain_found = 1'b1;
                drain_slot = SLOT_PTRW'(slot);
            end
        end
    end

    wire sink_owner_valid = USE_SINK_STAGE
        ? drain_stage_valid_r : drain_found;
    wire [SLOT_PTRW-1:0] sink_slot = USE_SINK_STAGE
        ? drain_stage_slot_r : drain_slot;
    wire [DATAW-1:0] sink_slot_data;

    wire sink_write_last = install_head_valid && sink_owner_valid
        && ((slot_owner_beat_r[sink_slot] + COUNTW'(1))
            == cmd_total_r[install_ptr_r]);

    assign sink_if.write_valid = install_head_valid
                              && sink_owner_valid
                              && writer_release_i;
    assign sink_if.write_tag = {
        cmd_sequence_r[install_ptr_r], slot_owner_beat_r[sink_slot]
    };
    assign sink_if.write_payload = {
        cmd_payload_r[install_ptr_r][DEST_METAW-1:0],
        slot_owner_beat_r[sink_slot], sink_slot_data
    };
    assign sink_if.write_owned = install_head_valid && sink_owner_valid;
    assign sink_if.writer_released = writer_release_i;
    assign sink_if.write_last = sink_write_last;
    assign sink_if.progress_valid = install_head_valid;
    assign sink_if.progress_total_beats = cmd_total_r[install_ptr_r];
    assign sink_if.progress_write_beats = cmd_write_r[install_ptr_r];
    assign sink_if.install_complete = sink_if.write_valid
                                   && sink_if.write_ready
                                   && sink_write_last;

    wire sink_write_fire = sink_if.write_valid && sink_if.write_ready;
    wire install_pop = sink_if.install_complete;

    // Registered sink stage, selected explicitly or required by RAM storage.
    // On a sink turnover, select the next ordered slot using the post-write
    // command/beat without waiting for the registered counters to update.
    // This preserves one beat/cycle drain.
    wire stage_ready = !drain_stage_valid_r || sink_write_fire;
    wire [CMD_PTRW-1:0] stage_cmd = install_pop
        ? cmd_ptr_next(install_ptr_r) : install_ptr_r;
    wire [COUNTW-1:0] stage_beat = sink_write_fire
        ? (install_pop ? '0
                       : (cmd_write_r[install_ptr_r] + COUNTW'(1)))
        : cmd_write_r[install_ptr_r];
    always_comb begin
        stage_found = 1'b0;
        stage_slot = RING_SLOT_ORDER
            ? (sink_write_fire ? (install_slot_r + SLOT_PTRW'(1))
                               : install_slot_r)
            : '0;
        for (int slot = 0; slot < RESPONSE_SLOTS; ++slot) begin
            if (!stage_found && USE_SINK_STAGE && stage_ready
             && (!RING_SLOT_ORDER
              || (SLOT_PTRW'(slot) == stage_slot))
             && cmd_valid_r[stage_cmd]
             && (slot_state_r[slot] == SLOT_READY)
             && (slot_owner_cmd_r[slot] == stage_cmd)
             && (slot_owner_sequence_r[slot]
                 == cmd_sequence_r[stage_cmd])
             && (slot_owner_beat_r[slot] == stage_beat)) begin
                stage_found = 1'b1;
                stage_slot = SLOT_PTRW'(slot);
            end
        end
    end

    // When enabled, a just-consumed ordered slot may be allocated in the same
    // cycle.  This is a one-way sink-ready -> source-valid path; neither
    // source ready nor source response ready feeds the sink channel, so no
    // ready loop exists.  Disabled adapters observe the registered FREE state.
    logic request_slot_available;
    logic [SLOT_PTRW-1:0] request_slot;
    always_comb begin
        request_slot_available = 1'b0;
        request_slot = RING_SLOT_ORDER ? alloc_slot_r : '0;
        for (int slot = 0; slot < RESPONSE_SLOTS; ++slot) begin
            if (!request_slot_available
             && (!RING_SLOT_ORDER || (SLOT_PTRW'(slot) == alloc_slot_r))
             && ((slot_state_r[slot] == SLOT_FREE)
              || (SAME_CYCLE_SLOT_RECYCLE
               && sink_write_fire
               && (sink_slot == SLOT_PTRW'(slot))))) begin
                request_slot_available = 1'b1;
                request_slot = SLOT_PTRW'(slot);
            end
        end
    end

    assign fetch_if.req_valid = fetch_head_valid && request_slot_available;
    assign fetch_if.req_tag = $bits(fetch_if.req_tag)'(request_slot);
    assign fetch_if.req_payload = {
        cmd_payload_r[fetch_ptr_r][CMD_PAYLOADW-1 -: SOURCE_METAW],
        cmd_request_r[fetch_ptr_r]
    };
    wire source_request_fire = fetch_if.req_valid && fetch_if.req_ready;

    wire response_tag_in_range = {1'b0, fetch_if.rsp_tag}
                              < RESPONSE_RANGEW'(RESPONSE_SLOTS);
    wire [SLOT_PTRW-1:0] response_slot
        = SLOT_PTRW'(fetch_if.rsp_tag);
    assign fetch_if.rsp_owned = response_tag_in_range
        && (slot_state_r[response_slot] == SLOT_WAIT_RSP)
        && cmd_valid_r[slot_owner_cmd_r[response_slot]]
        && (cmd_sequence_r[slot_owner_cmd_r[response_slot]]
            == slot_owner_sequence_r[response_slot]);
    // Every issued request owns a response slot until its single response
    // arrives.  The source therefore never needs ownership feedback to decide
    // whether the response channel is ready.  Simulation checks the protocol
    // contract below without retaining the tag/state cone in synthesis.
    assign fetch_if.rsp_ready = 1'b1;
    assign fetch_if.rsp_last = fetch_if.rsp_owned
        && ((cmd_response_r[slot_owner_cmd_r[response_slot]] + COUNTW'(1))
            == cmd_total_r[slot_owner_cmd_r[response_slot]]);
    wire source_response_fire = fetch_if.rsp_valid;
    assign fetch_if.fetch_complete = source_response_fire
                                  && fetch_if.rsp_last;

    if (RESPONSE_DATA_RAM) begin : g_response_data_ram
        VX_dp_ram #(
            .DATAW     (DATAW),
            .SIZE      (RESPONSE_SLOTS),
            .WRENW     (1),
            .OUT_REG   (1),
            .LUTRAM    (0),
            .RDW_MODE  ("R"),
            .RADDR_REG (1),
            .RESET_RAM (0)
        ) response_payload_ram (
            .clk   (clk),
            .reset (reset),
            .read  (stage_found),
            .write (source_response_fire),
            .wren  (1'b1),
            .waddr (response_slot),
            .wdata (fetch_if.rsp_payload),
            .raddr (stage_slot),
            .rdata (sink_slot_data)
        );
    end else begin : g_response_data_ff
        logic [DATAW-1:0] slot_data_r[RESPONSE_SLOTS];

        assign sink_slot_data = slot_data_r[sink_slot];

        always_ff @(posedge clk) begin
            if (reset) begin
                for (int slot = 0; slot < RESPONSE_SLOTS; ++slot)
                    slot_data_r[slot] <= '0;
            end else if (source_response_fire) begin
                slot_data_r[response_slot] <= fetch_if.rsp_payload;
            end
        end
    end

    wire zero_size_cmd = fetch_if.cmd_total_beats == 0;
    assign fetch_if.cmd_ready = zero_size_cmd
                             || (cmd_count_r < CMD_COUNTW'(CMD_FIFO_DEPTH))
                             || install_pop;
    wire command_accept = fetch_if.cmd_valid && fetch_if.cmd_ready;
    wire command_enqueue = command_accept && !zero_size_cmd;

    assign fetch_if.progress_valid = fetch_head_valid;
    assign fetch_if.progress_total_beats = cmd_total_r[fetch_ptr_r];
    assign fetch_if.progress_request_beats = cmd_request_r[fetch_ptr_r];
    assign fetch_if.progress_response_beats = cmd_response_r[fetch_ptr_r];
    assign fetch_if.slot_occupancy = slot_count_r;

    assign writer_head_valid_o = install_head_valid;
    assign writer_head_cmd_id_o = cmd_id_r[install_ptr_r];
    assign writer_head_cmd_payload_o = cmd_payload_r[install_ptr_r];
    assign writer_head_sequence_o = cmd_sequence_r[install_ptr_r];
    assign fetch_complete_valid_o = fetch_if.fetch_complete;
    assign fetch_complete_cmd_id_o
        = cmd_id_r[slot_owner_cmd_r[response_slot]];
    assign fetch_complete_sequence_o
        = slot_owner_sequence_r[response_slot];
    assign install_complete_valid_o = sink_if.install_complete;
    assign install_complete_cmd_id_o = cmd_id_r[install_ptr_r];
    assign install_complete_sequence_o = cmd_sequence_r[install_ptr_r];
    assign fetch_head_write_beats_o = fetch_head_valid
        ? cmd_write_r[fetch_ptr_r] : '0;
    assign cmd_occupancy_o = cmd_count_r;
    assign slot_occupancy_o = slot_count_r;

    // Count the registered sink beat, when enabled, and the consecutive READY
    // ring prefix behind it.  WAIT_RSP occupancy is intentionally excluded.
    always_comb begin
        install_ready_ahead = USE_SINK_STAGE
            ? SLOT_COUNTW'(drain_stage_valid_r) : '0;
        for (int offset = 0; offset < RESPONSE_SLOTS; ++offset) begin
            if ((offset >= ((USE_SINK_STAGE && drain_stage_valid_r) ? 1 : 0))
             && (slot_state_r[SLOT_PTRW'(install_slot_r
                                      + SLOT_PTRW'(offset))]
                 == SLOT_READY)
             && (install_ready_ahead == SLOT_COUNTW'(offset))) begin
                install_ready_ahead = install_ready_ahead
                                    + SLOT_COUNTW'(1);
            end
        end
    end
    assign install_ready_ahead_o = install_ready_ahead;

    initial begin
        if ((CMD_FIFO_DEPTH != 1) && (CMD_FIFO_DEPTH != 2)
         && (CMD_FIFO_DEPTH != 4))
            $fatal(1, "%s: stream DMA command depth must be 1, 2, or 4",
                   INSTANCE_ID);
        if ((RESPONSE_SLOTS < 1)
         || ((RESPONSE_SLOTS & (RESPONSE_SLOTS - 1)) != 0))
            $fatal(1, "%s: response slots must be a positive power of two",
                   INSTANCE_ID);
        if ((SOURCE_METAW < 1) || (DEST_METAW < 1) || (DATAW < 1)
         || (COUNTW < 2) || (SEQW < 1))
            $fatal(1, "%s: invalid stream DMA field widths", INSTANCE_ID);
        if (($bits(fetch_if.req_tag) != FETCH_TAGW)
         || ($bits(fetch_if.rsp_tag) != FETCH_TAGW)
         || ($clog2(RESPONSE_SLOTS) > FETCH_TAGW))
            $fatal(1, "%s: fetch tag cannot encode response slots",
                   INSTANCE_ID);
        if (($bits(fetch_if.cmd_payload) != CMD_PAYLOADW)
         || ($bits(fetch_if.req_payload) != REQ_PAYLOADW)
         || ($bits(fetch_if.rsp_payload) != DATAW)
         || ($bits(fetch_if.progress_total_beats) != COUNTW)
         || ($bits(sink_if.write_payload) != SINK_PAYLOADW)
         || ($bits(sink_if.write_tag) != SINK_TAGW)
         || ($bits(sink_if.progress_total_beats) != COUNTW))
            $fatal(1, "%s: stream DMA interface width mismatch", INSTANCE_ID);
    end

    always_ff @(posedge clk) begin
        if (reset) begin
            cmd_valid_r <= '0;
            cmd_fetch_done_r <= '0;
            fetch_ptr_r <= '0;
            install_ptr_r <= '0;
            tail_ptr_r <= '0;
            cmd_count_r <= '0;
            next_sequence_r <= '0;
            slot_count_r <= '0;
            alloc_slot_r <= '0;
            install_slot_r <= '0;
            drain_stage_valid_r <= 1'b0;
            drain_stage_slot_r <= '0;
            for (int cmd = 0; cmd < CMD_FIFO_DEPTH; ++cmd) begin
                cmd_id_r[cmd] <= '0;
                cmd_payload_r[cmd] <= '0;
                cmd_total_r[cmd] <= '0;
                cmd_request_r[cmd] <= '0;
                cmd_response_r[cmd] <= '0;
                cmd_write_r[cmd] <= '0;
                cmd_sequence_r[cmd] <= '0;
            end
            for (int slot = 0; slot < RESPONSE_SLOTS; ++slot) begin
                slot_state_r[slot] <= SLOT_FREE;
                slot_owner_cmd_r[slot] <= '0;
                slot_owner_sequence_r[slot] <= '0;
                slot_owner_beat_r[slot] <= '0;
            end
        end else begin
            unique case ({command_enqueue, install_pop})
                2'b10: cmd_count_r <= cmd_count_r + CMD_COUNTW'(1);
                2'b01: cmd_count_r <= cmd_count_r - CMD_COUNTW'(1);
                default:;
            endcase
            unique case ({source_request_fire, sink_write_fire})
                2'b10: slot_count_r <= slot_count_r + SLOT_COUNTW'(1);
                2'b01: slot_count_r <= slot_count_r - SLOT_COUNTW'(1);
                default:;
            endcase

            if (source_response_fire) begin
                slot_state_r[response_slot] <= SLOT_READY;
                cmd_response_r[slot_owner_cmd_r[response_slot]]
                    <= cmd_response_r[slot_owner_cmd_r[response_slot]]
                     + COUNTW'(1);
            end

            if (sink_write_fire) begin
                slot_state_r[sink_slot] <= SLOT_FREE;
                install_slot_r <= install_slot_r + SLOT_PTRW'(1);
                if (sink_write_last) begin
                    cmd_valid_r[install_ptr_r] <= 1'b0;
                    cmd_fetch_done_r[install_ptr_r] <= 1'b0;
                    cmd_request_r[install_ptr_r] <= '0;
                    cmd_response_r[install_ptr_r] <= '0;
                    cmd_write_r[install_ptr_r] <= '0;
                    install_ptr_r <= cmd_ptr_next(install_ptr_r);
                end else begin
                    cmd_write_r[install_ptr_r]
                        <= cmd_write_r[install_ptr_r] + COUNTW'(1);
                end
            end

            if (USE_SINK_STAGE) begin
                if (sink_write_fire && !stage_found)
                    drain_stage_valid_r <= 1'b0;
                if (stage_found) begin
                    drain_stage_valid_r <= 1'b1;
                    drain_stage_slot_r <= stage_slot;
                    slot_state_r[stage_slot] <= SLOT_DRAINING;
                end
            end

            // Request allocation follows sink release so same-cycle slot
            // recycle leaves the slot owned by the new request.
            if (source_request_fire) begin
                slot_state_r[request_slot] <= SLOT_WAIT_RSP;
                slot_owner_cmd_r[request_slot] <= fetch_ptr_r;
                slot_owner_sequence_r[request_slot]
                    <= cmd_sequence_r[fetch_ptr_r];
                slot_owner_beat_r[request_slot]
                    <= cmd_request_r[fetch_ptr_r];
                alloc_slot_r <= alloc_slot_r + SLOT_PTRW'(1);
                cmd_request_r[fetch_ptr_r]
                    <= cmd_request_r[fetch_ptr_r] + COUNTW'(1);
                if ((cmd_request_r[fetch_ptr_r] + COUNTW'(1))
                    == cmd_total_r[fetch_ptr_r]) begin
                    cmd_fetch_done_r[fetch_ptr_r] <= 1'b1;
                    fetch_ptr_r <= cmd_ptr_next(fetch_ptr_r);
                end
            end

            // Enqueue last so a simultaneous install pop can reuse the entry.
            if (command_enqueue) begin
                cmd_valid_r[tail_ptr_r] <= 1'b1;
                cmd_fetch_done_r[tail_ptr_r] <= 1'b0;
                cmd_id_r[tail_ptr_r] <= fetch_if.cmd_id;
                cmd_payload_r[tail_ptr_r] <= fetch_if.cmd_payload;
                cmd_total_r[tail_ptr_r] <= fetch_if.cmd_total_beats;
                cmd_request_r[tail_ptr_r] <= '0;
                cmd_response_r[tail_ptr_r] <= '0;
                cmd_write_r[tail_ptr_r] <= '0;
                cmd_sequence_r[tail_ptr_r] <= next_sequence_r;
                tail_ptr_r <= cmd_ptr_next(tail_ptr_r);
                next_sequence_r <= next_sequence_r + SEQW'(1);
            end
        end
    end

`ifndef SYNTHESIS
    logic [CMD_COUNTW-1:0] live_cmd_count;
    logic [SLOT_COUNTW-1:0] live_slot_count;
    logic sink_stall_r;
    logic [SINK_TAGW-1:0] sink_stall_tag_r;
    logic [SINK_PAYLOADW-1:0] sink_stall_payload_r;
    logic sink_stall_last_r;
    always_comb begin
        live_cmd_count = '0;
        live_slot_count = '0;
        for (int cmd = 0; cmd < CMD_FIFO_DEPTH; ++cmd)
            if (cmd_valid_r[cmd])
                live_cmd_count = live_cmd_count + CMD_COUNTW'(1);
        for (int slot = 0; slot < RESPONSE_SLOTS; ++slot)
            if (slot_state_r[slot] != SLOT_FREE)
                live_slot_count = live_slot_count + SLOT_COUNTW'(1);
    end

    always_ff @(posedge clk) begin
        if (reset) begin
            sink_stall_r <= 1'b0;
            sink_stall_tag_r <= '0;
            sink_stall_payload_r <= '0;
            sink_stall_last_r <= 1'b0;
        end else begin
            assert (cmd_count_r <= CMD_COUNTW'(CMD_FIFO_DEPTH))
                else $fatal(1, "%s: stream DMA descriptor overflow",
                            INSTANCE_ID);
            assert (slot_count_r <= SLOT_COUNTW'(RESPONSE_SLOTS))
                else $fatal(1, "%s: stream DMA slot overflow", INSTANCE_ID);
            assert (live_cmd_count == cmd_count_r)
                else $fatal(1, "%s: stream DMA descriptor count mismatch",
                            INSTANCE_ID);
            assert (live_slot_count == slot_count_r)
                else $fatal(1, "%s: stream DMA slot count mismatch",
                            INSTANCE_ID);
            if (command_accept && zero_size_cmd) begin
                assert (!command_enqueue)
                    else $fatal(1, "%s: zero-size no-op allocated a descriptor",
                                INSTANCE_ID);
            end
            if (source_request_fire) begin
                assert (fetch_head_valid && request_slot_available)
                    else $fatal(1, "%s: source request had no descriptor/slot",
                                INSTANCE_ID);
                assert (cmd_request_r[fetch_ptr_r]
                     < cmd_total_r[fetch_ptr_r])
                    else $fatal(1, "%s: source request exceeded descriptor",
                                INSTANCE_ID);
            end
            if (source_response_fire) begin
                assert (fetch_if.rsp_owned)
                    else $fatal(1, "%s: accepted stale stream response",
                                INSTANCE_ID);
                assert (cmd_response_r[slot_owner_cmd_r[response_slot]]
                     < cmd_total_r[slot_owner_cmd_r[response_slot]])
                    else $fatal(1, "%s: response exceeded descriptor",
                                INSTANCE_ID);
            end
            if (RESPONSE_DATA_RAM && source_response_fire && stage_found) begin
                assert (response_slot != stage_slot)
                    else $fatal(1, "%s: response RAM read/write collision slot=%0d",
                                INSTANCE_ID, response_slot);
            end
            if (sink_stall_r) begin
                assert (sink_if.write_valid
                     && (sink_if.write_tag == sink_stall_tag_r)
                     && (sink_if.write_payload == sink_stall_payload_r)
                     && (sink_if.write_last == sink_stall_last_r))
                    else $fatal(1, "%s: destination write changed while stalled",
                                INSTANCE_ID);
            end
            if (sink_write_fire) begin
                assert (install_head_valid && sink_owner_valid
                     && writer_release_i)
                    else $fatal(1, "%s: destination write owner/fence violation",
                                INSTANCE_ID);
                assert (cmd_write_r[install_ptr_r]
                     < cmd_total_r[install_ptr_r])
                    else $fatal(1, "%s: destination write exceeded descriptor",
                                INSTANCE_ID);
            end
            for (int cmd = 0; cmd < CMD_FIFO_DEPTH; ++cmd) begin
                if (cmd_valid_r[cmd]) begin
                    assert ((cmd_total_r[cmd] != 0)
                         && (cmd_response_r[cmd] <= cmd_request_r[cmd])
                         && (cmd_write_r[cmd] <= cmd_response_r[cmd])
                         && (cmd_request_r[cmd] <= cmd_total_r[cmd]))
                        else $fatal(1, "%s: descriptor progress invariant failed cmd=%0d",
                                    INSTANCE_ID, cmd);
                end
            end

            sink_stall_r <= sink_if.write_valid && !sink_if.write_ready;
            if (sink_if.write_valid && !sink_if.write_ready) begin
                sink_stall_tag_r <= sink_if.write_tag;
                sink_stall_payload_r <= sink_if.write_payload;
                sink_stall_last_r <= sink_if.write_last;
            end
        end
    end
`endif

endmodule
