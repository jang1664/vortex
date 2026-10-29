`include "VX_define.vh"

`ifdef GEMM_SRAM_FUSION
// Ordinary C4 LMEM vector link. The two scheduler tags each own at most
// sixteen lanes; partial response packets are counted by mask population.
// Both endpoint resets must assert together and release on the same clock
// edge. Original-epoch publication/physical store completion stays external.
module VX_sram_lmem_vector_transport #(
    parameter `STRING INSTANCE_ID = ""
) (
    input wire clk,
    input wire source_reset,
    input wire destination_reset,
    VX_lsu_mem_if.slave source_if,
    VX_lsu_mem_if.master destination_if,
    output wire source_owned_o
);
    localparam int REQW = $bits(source_if.req_data);
    localparam int RSPW = $bits(source_if.rsp_data);
    localparam int DEPTH = 4;
    localparam int LANES = $bits(source_if.req_data.mask);
    localparam int MAX_READ_LANES = `LSUQ_IN_SIZE * LANES;
    localparam int READ_COUNTW = $clog2(MAX_READ_LANES + 1);
    localparam int ARITHW = READ_COUNTW + 1;

    wire launch_valid, launch_ready, launch_accept;
    wire [REQW-1:0] launch_data;
    wire [REQW-1:0] request_data;
    wire request_valid, request_credit, request_idle;
    wire [RSPW-1:0] response_data;
    wire response_valid, response_credit;
    logic [READ_COUNTW-1:0] read_lanes_pending_q;

    assign source_if.req_ready = !source_reset && launch_accept;
    VX_elastic_buffer #(.DATAW(REQW), .SIZE(1), .OUT_REG(1)) u_launch (
        .clk(clk), .reset(source_reset),
        .valid_in(source_if.req_valid && !source_reset),
        .ready_in(launch_accept), .data_in(source_if.req_data),
        .valid_out(launch_valid), .ready_out(launch_ready), .data_out(launch_data)
    );
    VX_slr_stream_tx #(.INSTANCE_ID(INSTANCE_ID), .DATAW(REQW), .DEPTH(DEPTH)) u_request_tx (
        .clk(clk), .reset(source_reset),
        .valid_in(launch_valid), .ready_in(launch_ready), .data_in(launch_data),
        .link_data(request_data), .link_valid(request_valid),
        .link_credit(request_credit), .idle_out(request_idle)
    );
    VX_slr_stream_rx #(.INSTANCE_ID(INSTANCE_ID), .DATAW(REQW), .DEPTH(DEPTH)) u_request_rx (
        .clk(clk), .reset(destination_reset),
        .link_data(request_data), .link_valid(request_valid), .link_credit(request_credit),
        .valid_out(destination_if.req_valid), .ready_out(destination_if.req_ready),
        .data_out(destination_if.req_data)
    );
    VX_slr_stream_tx #(.INSTANCE_ID(INSTANCE_ID), .DATAW(RSPW), .DEPTH(DEPTH)) u_response_tx (
        .clk(clk), .reset(destination_reset),
        .valid_in(destination_if.rsp_valid), .ready_in(destination_if.rsp_ready),
        .data_in(destination_if.rsp_data),
        .link_data(response_data), .link_valid(response_valid),
        .link_credit(response_credit), .idle_out()
    );
    VX_slr_stream_rx #(.INSTANCE_ID(INSTANCE_ID), .DATAW(RSPW), .DEPTH(DEPTH)) u_response_rx (
        .clk(clk), .reset(source_reset),
        .link_data(response_data), .link_valid(response_valid), .link_credit(response_credit),
        .valid_out(source_if.rsp_valid), .ready_out(source_if.rsp_ready),
        .data_out(source_if.rsp_data)
    );

    wire accept_read = source_if.req_valid && source_if.req_ready && !source_if.req_data.rw;
    wire consume_response = source_if.rsp_valid && source_if.rsp_ready;
    wire [ARITHW-1:0] added_lanes = accept_read
        ? ARITHW'($countones(source_if.req_data.mask)) : '0;
    wire [ARITHW-1:0] returned_lanes = consume_response
        ? ARITHW'($countones(source_if.rsp_data.mask)) : '0;
    wire [ARITHW-1:0] available_lanes = ARITHW'(read_lanes_pending_q) + added_lanes;
    wire [ARITHW-1:0] next_lanes = available_lanes - returned_lanes;

    always_ff @(posedge clk) begin
        if (source_reset)
            read_lanes_pending_q <= '0;
        else
            read_lanes_pending_q <= READ_COUNTW'(next_lanes);
    end

    // All operands are source-local. The caller must separately retain real
    // upstream offers and publication pending/same-cycle admissions.
    // Idle is NOT store commit.
    assign source_owned_o = !source_reset && (source_if.req_valid || launch_valid
        || !request_idle || (read_lanes_pending_q != 0) || source_if.rsp_valid);

`ifndef SYNTHESIS
    initial begin
        assert (`NUM_LSU_BLOCKS == 1 && `NUM_LSU_LANES == 16
             && `LSUQ_IN_SIZE == 2 && LANES == 16 && MAX_READ_LANES == 32)
            else $fatal(1, "%s: ordinary LMEM read bound requires exact C4 LSU geometry", INSTANCE_ID);
        assert ($bits(destination_if.req_data) == REQW
             && $bits(destination_if.rsp_data) == RSPW
             && $bits(source_if.rsp_data.mask) == LANES
             && $bits(destination_if.req_data.mask) == LANES
             && $bits(destination_if.rsp_data.mask) == LANES)
            else $fatal(1, "%s: ordinary LMEM interface width mismatch", INSTANCE_ID);
    end
    // The response carries no byte enables. Retain each accepted read's full
    // tag/UUID and per-lane byte enables until its source response is consumed.
    // These two records are assertions only, not transport storage or RTL.
    localparam int CHECK_SLOTS = `LSUQ_IN_SIZE;
    localparam int CHECK_TAGW = $bits(source_if.req_data.tag);
    localparam int CHECK_BYTES = $bits(source_if.req_data.byteen[0]);
    logic [CHECK_SLOTS-1:0] check_valid_q;
    logic [CHECK_SLOTS-1:0][CHECK_TAGW-1:0] check_tag_q;
    logic [CHECK_SLOTS-1:0][LANES-1:0][CHECK_BYTES-1:0] check_byteen_q;
    logic [CHECK_SLOTS-1:0][LANES-1:0] check_ingress_q, check_egress_q;

    function automatic int check_find_tag(input logic [CHECK_TAGW-1:0] tag);
        check_find_tag = -1;
        for (int slot = 0; slot < CHECK_SLOTS; ++slot)
            if (check_valid_q[slot] && check_tag_q[slot] == tag)
                check_find_tag = slot;
    endfunction

    task automatic check_response(
        input bit ingress,
        input logic [LANES-1:0] mask,
        input logic [CHECK_TAGW-1:0] tag,
        input logic [LANES-1:0][CHECK_BYTES*8-1:0] data,
        output int slot
    );
        string endpoint;
        logic [LANES-1:0] remaining;
        endpoint = ingress ? "ingress" : "egress";
        assert (!$isunknown(mask) && (|mask))
            else $fatal(1, "%s: ordinary LMEM %s response mask unknown or empty", INSTANCE_ID, endpoint);
        assert (!$isunknown(tag))
            else $fatal(1, "%s: ordinary LMEM %s response tag unknown", INSTANCE_ID, endpoint);
        slot = check_find_tag(tag);
        assert (slot >= 0)
            else $fatal(1, "%s: ordinary LMEM %s response tag has no accepted read", INSTANCE_ID, endpoint);
        remaining = ingress ? check_ingress_q[slot] : check_egress_q[slot];
        assert ((mask & ~remaining) == '0)
            else $fatal(1, "%s: ordinary LMEM %s response lanes not pending", INSTANCE_ID, endpoint);
        if (!ingress)
            assert ((mask & check_ingress_q[slot]) == '0)
                else $fatal(1, "%s: ordinary LMEM egress response before ingress acceptance", INSTANCE_ID);
        for (int lane = 0; lane < LANES; ++lane)
            if (mask[lane])
                for (int byte_idx = 0; byte_idx < CHECK_BYTES; ++byte_idx)
                    if (check_byteen_q[slot][lane][byte_idx])
                        assert (!$isunknown(data[lane][byte_idx*8 +: 8]))
                            else $fatal(1, "%s: ordinary LMEM %s response requested byte unknown lane=%0d byte=%0d",
                                INSTANCE_ID, endpoint, lane, byte_idx);
    endtask

    // Offers are checked even while stalled. The packer may change an
    // UNACCEPTED offer, so only handshakes consume the corresponding masks.
    // Generic RX still compares every bit, including unused bytes, with ===.
    always @(posedge clk) begin : g_check_read_bytes
        int ingress_slot, egress_slot, free_slot;
        if (source_reset) begin
            check_valid_q = '0;
            check_tag_q = '0;
            check_byteen_q = '0;
            check_ingress_q = '0;
            check_egress_q = '0;
        end else begin
            ingress_slot = -1;
            egress_slot = -1;
            if (!destination_reset && destination_if.rsp_valid)
                check_response(1'b1, destination_if.rsp_data.mask,
                    destination_if.rsp_data.tag, destination_if.rsp_data.data, ingress_slot);
            if (source_if.rsp_valid)
                check_response(1'b0, source_if.rsp_data.mask,
                    source_if.rsp_data.tag, source_if.rsp_data.data, egress_slot);
            if (!destination_reset && destination_if.rsp_valid && destination_if.rsp_ready)
                check_ingress_q[ingress_slot] &= ~destination_if.rsp_data.mask;
            if (consume_response)
                check_egress_q[egress_slot] &= ~source_if.rsp_data.mask;
            for (int slot = 0; slot < CHECK_SLOTS; ++slot)
                if (check_valid_q[slot] && check_ingress_q[slot] == '0 && check_egress_q[slot] == '0)
                    check_valid_q[slot] = 1'b0;

            // Retiring responses above use OLD metadata. A simultaneous new
            // read may then reuse the freed record/tag with NEW byte enables.
            if (source_if.req_valid && source_if.req_ready)
                assert (!$isunknown(source_if.req_data.rw))
                    else $fatal(1, "%s: ordinary LMEM accepted request direction unknown", INSTANCE_ID);
            if (accept_read) begin
                assert (!$isunknown(source_if.req_data.mask) && (|source_if.req_data.mask))
                    else $fatal(1, "%s: ordinary LMEM accepted read mask unknown or empty", INSTANCE_ID);
                assert (!$isunknown(source_if.req_data.tag))
                    else $fatal(1, "%s: ordinary LMEM accepted read tag unknown", INSTANCE_ID);
                for (int lane = 0; lane < LANES; ++lane)
                    if (source_if.req_data.mask[lane])
                        assert (!$isunknown(source_if.req_data.byteen[lane]) && (|source_if.req_data.byteen[lane]))
                            else $fatal(1, "%s: ordinary LMEM accepted read byte enable unknown or empty lane=%0d", INSTANCE_ID, lane);
                assert (check_find_tag(source_if.req_data.tag) < 0)
                    else $fatal(1, "%s: ordinary LMEM accepted read tag reused before retirement", INSTANCE_ID);
                free_slot = -1;
                for (int slot = 0; slot < CHECK_SLOTS; ++slot)
                    if (!check_valid_q[slot] && free_slot < 0)
                        free_slot = slot;
                assert (free_slot >= 0)
                    else $fatal(1, "%s: ordinary LMEM assertion read records exhausted", INSTANCE_ID);
                check_valid_q[free_slot] = 1'b1;
                check_tag_q[free_slot] = source_if.req_data.tag;
                check_byteen_q[free_slot] = source_if.req_data.byteen;
                check_ingress_q[free_slot] = source_if.req_data.mask;
                check_egress_q[free_slot] = source_if.req_data.mask;
            end
        end
    end
    always_ff @(posedge clk) if (!source_reset) begin
        assert (returned_lanes <= available_lanes)
            else $fatal(1, "%s: ordinary LMEM returned lanes exceed ownership", INSTANCE_ID);
        assert (next_lanes <= ARITHW'(MAX_READ_LANES))
            else $fatal(1, "%s: ordinary LMEM read lane capacity exceeded", INSTANCE_ID);
        assert (!consume_response || (|source_if.rsp_data.mask))
            else $fatal(1, "%s: ordinary LMEM empty response packet", INSTANCE_ID);
    end
`endif
endmodule
`endif
