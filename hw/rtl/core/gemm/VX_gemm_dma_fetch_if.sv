`include "VX_define.vh"

// Backend-independent source-fetch contract for a bounded GEMM operand DMA.
// Addresses and backend-specific descriptor fields are opaque payload bits.
// Progress is reported for the authoritative fetch head; response ownership
// is resolved by the bounded slot/tag owner before a response is accepted.
interface VX_gemm_dma_fetch_if #(
    parameter `STRING INSTANCE_ID = "",
    parameter int CMD_PAYLOADW = 1,
    parameter int REQ_PAYLOADW = 1,
    parameter int RSP_PAYLOADW = 1,
    parameter int TAGW = 1,
    parameter int COUNTW = 32,
    parameter int SLOT_COUNTW = 1,
    parameter int SLOT_CAPACITY = 1
) (
    input wire clk,
    input wire reset
);

    logic                    cmd_valid;
    logic                    cmd_ready;
    logic [31:0]             cmd_id;
    logic [COUNTW-1:0]       cmd_total_beats;
    logic [CMD_PAYLOADW-1:0] cmd_payload;

    logic                    req_valid;
    logic                    req_ready;
    logic [TAGW-1:0]         req_tag;
    logic [REQ_PAYLOADW-1:0] req_payload;

    logic                    rsp_valid;
    logic                    rsp_ready;
    logic [TAGW-1:0]         rsp_tag;
    logic [RSP_PAYLOADW-1:0] rsp_payload;
    logic                    rsp_owned;
    logic                    rsp_last;

    logic                    progress_valid;
    logic [COUNTW-1:0]       progress_total_beats;
    logic [COUNTW-1:0]       progress_request_beats;
    logic [COUNTW-1:0]       progress_response_beats;
    logic [SLOT_COUNTW-1:0]  slot_occupancy;
    logic                    fetch_complete;

    modport queue (
        input  cmd_valid,
        output cmd_ready,
        input  cmd_id,
        input  cmd_total_beats,
        input  cmd_payload,
        output req_valid,
        input  req_ready,
        output req_tag,
        output req_payload,
        input  rsp_valid,
        output rsp_ready,
        input  rsp_tag,
        input  rsp_payload,
        output rsp_owned,
        output rsp_last,
        output progress_valid,
        output progress_total_beats,
        output progress_request_beats,
        output progress_response_beats,
        output slot_occupancy,
        output fetch_complete
    );

    modport source (
        input  req_valid,
        output req_ready,
        input  req_tag,
        input  req_payload,
        output rsp_valid,
        input  rsp_ready,
        output rsp_tag,
        output rsp_payload
    );

    modport monitor (
        input cmd_valid,
        input cmd_ready,
        input cmd_id,
        input cmd_total_beats,
        input cmd_payload,
        input req_valid,
        input req_ready,
        input req_tag,
        input req_payload,
        input rsp_valid,
        input rsp_ready,
        input rsp_tag,
        input rsp_payload,
        input rsp_owned,
        input rsp_last,
        input progress_valid,
        input progress_total_beats,
        input progress_request_beats,
        input progress_response_beats,
        input slot_occupancy,
        input fetch_complete
    );

    initial begin
        if ((CMD_PAYLOADW < 1) || (REQ_PAYLOADW < 1)
         || (RSP_PAYLOADW < 1) || (TAGW < 1) || (COUNTW < 1)
         || (SLOT_COUNTW < 1) || (SLOT_CAPACITY < 1))
            $fatal(1, "%s: invalid GEMM DMA fetch interface parameters",
                   INSTANCE_ID);
        if ($clog2(SLOT_CAPACITY + 1) > SLOT_COUNTW)
            $fatal(1, "%s: fetch slot count width cannot encode capacity %0d",
                   INSTANCE_ID, SLOT_CAPACITY);
    end

`ifndef SYNTHESIS
    logic cmd_stall_r;
    logic [31:0] cmd_stall_id_r;
    logic [COUNTW-1:0] cmd_stall_total_r;
    logic [CMD_PAYLOADW-1:0] cmd_stall_payload_r;
    logic req_stall_r;
    logic [TAGW-1:0] req_stall_tag_r;
    logic [REQ_PAYLOADW-1:0] req_stall_payload_r;
    logic rsp_stall_r;
    logic [TAGW-1:0] rsp_stall_tag_r;
    logic [RSP_PAYLOADW-1:0] rsp_stall_payload_r;
    logic rsp_stall_owned_r;
    logic rsp_stall_last_r;
    logic [SLOT_CAPACITY-1:0] tag_live_r;
    logic [TAGW-1:0] tag_value_r[SLOT_CAPACITY];

    always_ff @(posedge clk) begin
        if (reset) begin
            cmd_stall_r <= 1'b0;
            req_stall_r <= 1'b0;
            rsp_stall_r <= 1'b0;
            cmd_stall_id_r <= '0;
            cmd_stall_total_r <= '0;
            cmd_stall_payload_r <= '0;
            req_stall_tag_r <= '0;
            req_stall_payload_r <= '0;
            rsp_stall_tag_r <= '0;
            rsp_stall_payload_r <= '0;
            rsp_stall_owned_r <= 1'b0;
            rsp_stall_last_r <= 1'b0;
            tag_live_r <= '0;
            for (int slot = 0; slot < SLOT_CAPACITY; ++slot)
                tag_value_r[slot] <= '0;
        end else begin
            automatic int req_hit = -1;
            automatic int rsp_hit = -1;
            automatic int free_hit = -1;
            for (int slot = 0; slot < SLOT_CAPACITY; ++slot) begin
                if (tag_live_r[slot] && (tag_value_r[slot] == req_tag))
                    req_hit = slot;
                if (tag_live_r[slot] && (tag_value_r[slot] == rsp_tag))
                    rsp_hit = slot;
                if (!tag_live_r[slot] && (free_hit < 0))
                    free_hit = slot;
            end

            if (cmd_stall_r) begin
                assert (cmd_valid
                     && (cmd_id == cmd_stall_id_r)
                     && (cmd_total_beats == cmd_stall_total_r)
                     && (cmd_payload == cmd_stall_payload_r))
                    else $fatal(1, "%s: DMA fetch command changed while held",
                                INSTANCE_ID);
            end
            if (req_stall_r) begin
                assert (req_valid
                     && (req_tag == req_stall_tag_r)
                     && (req_payload == req_stall_payload_r))
                    else $fatal(1, "%s: DMA fetch request changed while held",
                                INSTANCE_ID);
            end
            if (rsp_stall_r) begin
                assert (rsp_valid
                     && (rsp_tag == rsp_stall_tag_r)
                     && (rsp_payload == rsp_stall_payload_r)
                     && (rsp_owned == rsp_stall_owned_r)
                     && (rsp_last == rsp_stall_last_r))
                    else $fatal(1, "%s: DMA fetch response changed while held",
                                INSTANCE_ID);
            end

            // A zero-sized accepted descriptor is a legal no-op.  It must
            // never become progress_valid or allocate a request/slot; that
            // stateful requirement is enforced by the queue implementation.
            if (rsp_valid && rsp_ready) begin
                assert (rsp_owned)
                    else $fatal(1, "%s: duplicate/stale DMA response accepted tag=%0h",
                                INSTANCE_ID, rsp_tag);
                assert ((rsp_hit >= 0)
                     || ((req_valid && req_ready) && (req_tag == rsp_tag)))
                    else $fatal(1, "%s: DMA response had no accepted request tag=%0h",
                                INSTANCE_ID, rsp_tag);
            end
            if (req_valid && req_ready) begin
                assert ((req_hit < 0)
                     || ((rsp_valid && rsp_ready) && (rsp_hit == req_hit)))
                    else $fatal(1, "%s: duplicate live DMA request tag=%0h",
                                INSTANCE_ID, req_tag);
                assert ((req_hit >= 0) || (free_hit >= 0)
                     || ((rsp_valid && rsp_ready) && (rsp_hit >= 0)))
                    else $fatal(1, "%s: DMA request exceeded bounded tag slots",
                                INSTANCE_ID);
            end
            assert (fetch_complete
                 == (rsp_valid && rsp_ready && rsp_owned && rsp_last))
                else $fatal(1, "%s: DMA fetch completion did not match final owned response",
                            INSTANCE_ID);
            assert (slot_occupancy <= SLOT_COUNTW'(SLOT_CAPACITY))
                else $fatal(1, "%s: DMA fetch slot occupancy exceeded %0d",
                            INSTANCE_ID, SLOT_CAPACITY);
            if (progress_valid) begin
                assert ((progress_total_beats != 0)
                     && (progress_request_beats <= progress_total_beats)
                     && (progress_response_beats <= progress_request_beats))
                    else $fatal(1, "%s: DMA fetch progress escaped descriptor bounds",
                                INSTANCE_ID);
            end

            // Same-cycle response/request tag turnover retains ownership in
            // place.  A different new tag may reuse the slot freed by the
            // accepted response; a zero-latency response to a new request
            // creates no persistent entry.
            if (rsp_valid && rsp_ready && (rsp_hit >= 0)
             && !((req_valid && req_ready) && (req_tag == rsp_tag)))
                tag_live_r[rsp_hit] <= 1'b0;
            if (req_valid && req_ready) begin
                if (req_hit >= 0) begin
                    tag_live_r[req_hit] <= 1'b1;
                    tag_value_r[req_hit] <= req_tag;
                end else if (!((rsp_valid && rsp_ready)
                            && (rsp_hit < 0) && (req_tag == rsp_tag))) begin
                    if (free_hit >= 0) begin
                        tag_live_r[free_hit] <= 1'b1;
                        tag_value_r[free_hit] <= req_tag;
                    end else begin
                        tag_live_r[rsp_hit] <= 1'b1;
                        tag_value_r[rsp_hit] <= req_tag;
                    end
                end
            end

            cmd_stall_r <= cmd_valid && !cmd_ready;
            if (cmd_valid && !cmd_ready) begin
                cmd_stall_id_r <= cmd_id;
                cmd_stall_total_r <= cmd_total_beats;
                cmd_stall_payload_r <= cmd_payload;
            end
            req_stall_r <= req_valid && !req_ready;
            if (req_valid && !req_ready) begin
                req_stall_tag_r <= req_tag;
                req_stall_payload_r <= req_payload;
            end
            rsp_stall_r <= rsp_valid && !rsp_ready;
            if (rsp_valid && !rsp_ready) begin
                rsp_stall_tag_r <= rsp_tag;
                rsp_stall_payload_r <= rsp_payload;
                rsp_stall_owned_r <= rsp_owned;
                rsp_stall_last_r <= rsp_last;
            end
        end
    end
`endif

endinterface
