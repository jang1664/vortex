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
    parameter bit ENABLE_LANE_MASK = 0
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

    reg  [NUM_LANES-1:0] req_sent_r;
    wire [NUM_LANES-1:0] req_lane_fire;
    wire [NUM_LANES-1:0] req_lane_active;
    wire                 req_all_done;
    wire                 rsp_ctx_full;
    wire                 rsp_ctx_pop;
    wire                 req_context_ready = !ENABLE_LANE_MASK
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
            wide_bus_if.req_data.tag
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
        VX_elastic_buffer #(
            .DATAW   (LANE_DATA_W + TAG_WIDTH),
            .SIZE    (8),
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

    if (ENABLE_LANE_MASK) begin : g_masked_response
        localparam RSP_CTX_DEPTH = 8;
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
