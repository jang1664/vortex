// Copyright 2019-2023
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
// http://www.apache.org/licenses/LICENSE-2.0

`include "VX_define.vh"

// VX_mem_bus_split
//
// Spatial scatter from one wide VX_mem_bus_if to NUM_LANES narrow
// VX_mem_bus_if instances. Used when an upstream client operates on a single
// aggregate bus but downstream local memory is organized as per-lane buses.
//
// Semantics:
//   - One wide request carries NUM_LANES contiguous LANE_DATA_SIZE-byte beats.
//   - lane[i].addr = {wide.addr, lane_index}; data/byteen are sliced.
//   - wide.req_ready waits until every active lane has accepted the request.
//   - wide.rsp_valid waits until every active read lane has produced a response.
//   - ENABLE_LANE_MASK uses each lane's byte enables as the active-lane mask.
//     The upstream client must provide valid byte enables for reads as metadata.

module VX_mem_bus_split import VX_gpu_pkg::*; #(
    parameter NUM_LANES        = 1,
    parameter LANE_DATA_SIZE   = 1,
    parameter TAG_WIDTH        = 1,
    parameter MEM_ADDR_WIDTH_P = `MEM_ADDR_WIDTH,
    parameter bit ENABLE_LANE_MASK = 0,
    parameter RSP_DEPTH       = 8,
    parameter bit RSP_REORDER = 0
) (
    input wire           clk,
    input wire           reset,

    VX_mem_bus_if.slave  wide_bus_if,
    VX_mem_bus_if.master lane_bus_if [NUM_LANES]
);
    localparam LANE_INDEX_BITS = (NUM_LANES > 1) ? `CLOG2(NUM_LANES) : 1;
    localparam LANE_DATA_W     = LANE_DATA_SIZE * 8;
    localparam LANE_ADDR_W     = MEM_ADDR_WIDTH_P - `CLOG2(LANE_DATA_SIZE);
    localparam LANE_REQ_DATAW  = 1 + LANE_ADDR_W + LANE_DATA_W + LANE_DATA_SIZE
                               + MEM_FLAGS_WIDTH + TAG_WIDTH;

    // Keep payload buffering and active-lane contexts at the same capacity.
    `VX_STATIC_ASSERT(RSP_DEPTH >= 2 && `IS_POW2(RSP_DEPTH),
        ("response depth must be a power of two >= 2"))

    reg  [NUM_LANES-1:0] req_sent_r;
    wire [NUM_LANES-1:0] req_lane_fire;
    wire [NUM_LANES-1:0] req_lane_active;
    wire                 req_all_done;
    wire                 rsp_ctx_full;
    wire                 rsp_ctx_pop;
    wire [TAG_WIDTH-1:0] request_tag;
    wire                 req_context_ready = (!ENABLE_LANE_MASK && !RSP_REORDER)
                                           || wide_bus_if.req_data.rw
                                           || !rsp_ctx_full
                                           || rsp_ctx_pop;

    for (genvar i = 0; i < NUM_LANES; ++i) begin : g_lane_req
        wire [LANE_ADDR_W-1:0] lane_addr_in = (NUM_LANES > 1)
            ? {wide_bus_if.req_data.addr, LANE_INDEX_BITS'(i)}
            : wide_bus_if.req_data.addr;

        wire [LANE_REQ_DATAW-1:0] lane_req_in = {
            wide_bus_if.req_data.rw,
            lane_addr_in,
            wide_bus_if.req_data.data[i*LANE_DATA_W +: LANE_DATA_W],
            wide_bus_if.req_data.byteen[i*LANE_DATA_SIZE +: LANE_DATA_SIZE],
            wide_bus_if.req_data.flags,
            request_tag
        };

        wire lane_has_bytes = |wide_bus_if.req_data.byteen[i*LANE_DATA_SIZE +: LANE_DATA_SIZE];
        assign req_lane_active[i] = !ENABLE_LANE_MASK || lane_has_bytes;

        wire skid_in_valid = wide_bus_if.req_valid
                          && req_context_ready
                          && req_lane_active[i]
                          && ~req_sent_r[i];
        wire skid_in_ready;

        VX_elastic_buffer #(
            .DATAW   (LANE_REQ_DATAW),
            .SIZE    (2),
            .OUT_REG (1)
        ) req_skid (
            .clk       (clk),
            .reset     (reset),
            .valid_in  (skid_in_valid),
            .data_in   (lane_req_in),
            .ready_in  (skid_in_ready),
            .valid_out (lane_bus_if[i].req_valid),
            .data_out  ({
                lane_bus_if[i].req_data.rw,
                lane_bus_if[i].req_data.addr,
                lane_bus_if[i].req_data.data,
                lane_bus_if[i].req_data.byteen,
                lane_bus_if[i].req_data.flags,
                lane_bus_if[i].req_data.tag
            }),
            .ready_out (lane_bus_if[i].req_ready)
        );

        assign req_lane_fire[i] = skid_in_valid && skid_in_ready;
    end

    assign req_all_done = wide_bus_if.req_valid
                       && req_context_ready
                       && (&(req_sent_r | req_lane_fire | ~req_lane_active));
    assign wide_bus_if.req_ready = req_all_done;

    always @(posedge clk) begin
        if (reset) begin
            req_sent_r <= '0;
        end else if (req_all_done) begin
            req_sent_r <= '0;
        end else if (wide_bus_if.req_valid) begin
            req_sent_r <= req_sent_r | req_lane_fire;
        end
    end

    wire [NUM_LANES-1:0]                  skid_valid;
    wire [NUM_LANES-1:0][LANE_DATA_W-1:0] skid_data;
    wire [NUM_LANES-1:0][TAG_WIDTH-1:0]   skid_tag;
    wire [NUM_LANES-1:0]                  skid_pop;

    for (genvar i = 0; i < NUM_LANES; ++i) begin : g_lane_rsp
      if (!RSP_REORDER) begin : g_fifo
        VX_elastic_buffer #(
            .DATAW   (LANE_DATA_W + TAG_WIDTH),
            .SIZE    (RSP_DEPTH),
            .OUT_REG (1)
        ) rsp_skid (
            .clk       (clk),
            .reset     (reset),
            .valid_in  (lane_bus_if[i].rsp_valid),
            .data_in   ({lane_bus_if[i].rsp_data.data, lane_bus_if[i].rsp_data.tag}),
            .ready_in  (lane_bus_if[i].rsp_ready),
            .valid_out (skid_valid[i]),
            .data_out  ({skid_data[i], skid_tag[i]}),
            .ready_out (skid_pop[i])
        );
    end

    end

    if (!RSP_REORDER) begin : g_original_tag
        assign request_tag = wide_bus_if.req_data.tag;
    end

    if (RSP_REORDER) begin : g_reorder_response
        wire [NUM_LANES-1:0] lane_valid, lane_ready;
        wire [NUM_LANES-1:0][LANE_DATA_W-1:0] lane_data;
        wire [NUM_LANES-1:0][TAG_WIDTH-1:0] lane_tag;
        for (genvar i=0; i<NUM_LANES; ++i) begin : g_response_wires
            assign lane_valid[i] = lane_bus_if[i].rsp_valid;
            assign lane_data[i] = lane_bus_if[i].rsp_data.data;
            assign lane_tag[i] = lane_bus_if[i].rsp_data.tag;
            assign lane_bus_if[i].rsp_ready = lane_ready[i];
        end
        VX_mem_bus_split_reorder #(
            .NUM_LANES(NUM_LANES), .DATAW(LANE_DATA_W),
            .TAG_WIDTH(TAG_WIDTH), .DEPTH(RSP_DEPTH)
        ) response_store (
            .clk(clk), .reset(reset),
            .request_tag(request_tag),
            .request_done(req_all_done), .request_write(wide_bus_if.req_data.rw),
            .original_tag(wide_bus_if.req_data.tag),
            .request_mask(req_lane_active), .request_lane_fire(req_lane_fire),
            .context_full(rsp_ctx_full), .context_pop(rsp_ctx_pop),
            .lane_valid(lane_valid), .lane_ready(lane_ready),
            .lane_data(lane_data), .lane_tag(lane_tag),
            .response_valid(wide_bus_if.rsp_valid),
            .response_ready(wide_bus_if.rsp_ready),
            .response_data(wide_bus_if.rsp_data.data),
            .response_tag(wide_bus_if.rsp_data.tag)
        );
    end else if (ENABLE_LANE_MASK) begin : g_masked_response
        localparam RSP_CTX_DEPTH = RSP_DEPTH;
        localparam RSP_CTX_DATAW = TAG_WIDTH + NUM_LANES;

        wire [NUM_LANES-1:0] rsp_ctx_mask;
        wire [TAG_WIDTH-1:0] rsp_ctx_tag;
        wire rsp_ctx_empty;
        wire rsp_ctx_push = req_all_done && !wide_bus_if.req_data.rw;

        VX_fifo_queue #(
            .DATAW   (RSP_CTX_DATAW),
            .DEPTH   (RSP_CTX_DEPTH),
            .OUT_REG (1)
        ) rsp_context_queue (
            .clk       (clk),
            .reset     (reset),
            .push      (rsp_ctx_push),
            .pop       (rsp_ctx_pop),
            .data_in   ({wide_bus_if.req_data.tag, req_lane_active}),
            .data_out  ({rsp_ctx_tag, rsp_ctx_mask}),
            .empty     (rsp_ctx_empty),
            .alm_empty (),
            .full      (rsp_ctx_full),
            .alm_full  (),
            .size      ()
        );

        wire active_rsp_valid = &(~rsp_ctx_mask | skid_valid);
        assign wide_bus_if.rsp_valid = !rsp_ctx_empty && active_rsp_valid;
        assign rsp_ctx_pop = wide_bus_if.rsp_valid && wide_bus_if.rsp_ready;
        assign skid_pop = {NUM_LANES{rsp_ctx_pop}} & rsp_ctx_mask;
        assign wide_bus_if.rsp_data.tag = rsp_ctx_tag;

        for (genvar i = 0; i < NUM_LANES; ++i) begin : g_masked_rsp_data
            assign wide_bus_if.rsp_data.data[i*LANE_DATA_W +: LANE_DATA_W]
                = rsp_ctx_mask[i] ? skid_data[i] : '0;
        end
    end else begin : g_all_lane_response
        wire all_skid_valid = &skid_valid;
        wire all_skid_pop = all_skid_valid && wide_bus_if.rsp_ready;

        assign rsp_ctx_full = 1'b0;
        assign rsp_ctx_pop = 1'b0;
        assign skid_pop = {NUM_LANES{all_skid_pop}};
        assign wide_bus_if.rsp_valid = all_skid_valid;
        assign wide_bus_if.rsp_data.tag = skid_tag[0];

        for (genvar i = 0; i < NUM_LANES; ++i) begin : g_all_rsp_data
            assign wide_bus_if.rsp_data.data[i*LANE_DATA_W +: LANE_DATA_W] = skid_data[i];
        end
    end

endmodule


// Opt-in response reorder store. Allocate private read tags in issue order;
// independent lane SRAM writes use the echoed private tag as their address.
// Preserve the original tag/mask in the context queue. A slot is recycled only
// after its data is captured by the synchronous RAM output registers.
module VX_mem_bus_split_reorder #(
    parameter NUM_LANES=4,
    parameter DATAW=512,
    parameter TAG_WIDTH=8,
    parameter DEPTH=8
) (
    input wire clk, reset,
    output wire [TAG_WIDTH-1:0] request_tag,
    input wire request_done, request_write,
    input wire [TAG_WIDTH-1:0] original_tag,
    input wire [NUM_LANES-1:0] request_mask, request_lane_fire,
    output wire context_full, context_pop,
    input wire [NUM_LANES-1:0] lane_valid,
    output wire [NUM_LANES-1:0] lane_ready,
    input wire [NUM_LANES-1:0][DATAW-1:0] lane_data,
    input wire [NUM_LANES-1:0][TAG_WIDTH-1:0] lane_tag,
    output wire response_valid,
    input wire response_ready,
    output wire [NUM_LANES-1:0][DATAW-1:0] response_data,
    output wire [TAG_WIDTH-1:0] response_tag
);
    // The transport tag is private until reassembly. Retain its existing width;
    // capacity above its namespace is unreachable (also bounded by DMA slots).
    localparam SLOT_BITS = `MIN(`CLOG2(DEPTH), TAG_WIDTH);
    localparam SLOTS = 1 << SLOT_BITS;
    reg [SLOT_BITS-1:0] write_slot_r, read_slot_r;
    wire context_push = request_done && !request_write;
    wire context_empty;
    wire [NUM_LANES-1:0] head_mask;
    wire [TAG_WIDTH-1:0] head_tag;
    wire [NUM_LANES-1:0] lane_complete;
    wire all_complete = &(lane_complete | ~head_mask);
    reg output_valid_r;
    reg [NUM_LANES-1:0] output_mask_r;
    reg [TAG_WIDTH-1:0] output_tag_r;
    wire read_payload = !context_empty && all_complete
                     && (!output_valid_r || response_ready);
    assign context_pop = read_payload;
    assign request_tag = request_write ? original_tag : TAG_WIDTH'(write_slot_r);
    assign response_valid = output_valid_r;
    assign response_tag = output_tag_r;

    VX_fifo_queue #(
        .DATAW(TAG_WIDTH+NUM_LANES), .DEPTH(SLOTS), .OUT_REG(1)
    ) contexts (
        .clk(clk), .reset(reset), .push(context_push), .pop(context_pop),
        .data_in({original_tag,request_mask}), .data_out({head_tag,head_mask}),
        .empty(context_empty), .full(context_full),
        .alm_empty(), .alm_full(), .size()
    );

    always @(posedge clk) begin
        if (reset) begin
            write_slot_r <= '0;
            read_slot_r <= '0;
            output_valid_r <= 0;
        end else begin
            if(context_push) write_slot_r <= write_slot_r+1'b1;
            if(read_payload) read_slot_r <= read_slot_r+1'b1;
            if(!output_valid_r || response_ready) output_valid_r <= read_payload;
        end
        if(read_payload) begin
            output_tag_r <= head_tag;
            output_mask_r <= head_mask;
        end
    end

    for(genvar i=0; i<NUM_LANES; ++i) begin : g_lane
        reg [SLOTS-1:0] received_r;
        wire [SLOT_BITS-1:0] response_slot = SLOT_BITS'(lane_tag[i]);
        wire write_payload = lane_valid[i] && lane_ready[i];
        wire [DATAW-1:0] payload;
        assign lane_ready[i] = !reset;
        assign lane_complete[i] = received_r[read_slot_r];
        assign response_data[i] = output_mask_r[i] ? payload : '0;
        always @(posedge clk) begin
            if(reset) received_r <= '0;
            else begin
                if(read_payload) received_r[read_slot_r] <= 0;
                if(write_payload) received_r[response_slot] <= 1;
            end
        end
        VX_dp_ram #(
            .DATAW(DATAW), .SIZE(SLOTS), .WRENW(1),
            .OUT_REG(1), .LUTRAM(0), .RDW_MODE("R"),
            .RADDR_REG(1), .RESET_RAM(0)
        ) payload_ram (
            .clk(clk), .reset(reset), .read(read_payload && head_mask[i]),
            .write(write_payload), .wren(1'b1),
            .waddr(response_slot), .wdata(lane_data[i]),
            .raddr(read_slot_r), .rdata(payload)
        );
`ifdef SIMULATION
        reg [SLOTS-1:0] waiting_r;
        always @(posedge clk) begin
            if(reset) waiting_r <= '0;
            else begin
                if(write_payload) begin
                    assert(lane_tag[i] < TAG_WIDTH'(SLOTS) || SLOT_BITS==TAG_WIDTH)
                        else $fatal(1,"%m: response tag outside reorder slots");
                    assert(waiting_r[response_slot] && !received_r[response_slot])
                        else $fatal(1,"%m: unexpected/duplicate response slot %0d",response_slot);
                    assert(!read_payload || response_slot!=read_slot_r)
                        else $fatal(1,"%m: simultaneous SRAM read/write collision");
                    waiting_r[response_slot] <= 0;
                end
                if(request_lane_fire[i] && !request_write)
                    waiting_r[write_slot_r] <= 1;
            end
        end
`endif
    end
endmodule
