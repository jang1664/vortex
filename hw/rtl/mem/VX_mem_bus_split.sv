// Copyright © 2019-2023
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
// http://www.apache.org/licenses/LICENSE-2.0

`include "VX_define.vh"

// VX_mem_bus_split
//
// Spatial scatter from one wide VX_mem_bus_if to NUM_LANES narrow
// VX_mem_bus_if instances. Used when an upstream client (e.g. GEMM/DMA
// engine) operates on a single (NUM_LANES * LANE_DATA_SIZE)-byte aggregate
// bus, but the downstream is organized as NUM_LANES per-lane buses
// (e.g. mem_unit per-lane 3:1 mux feeding LMEM banks).
//
// Semantics:
//   - One wide request carries NUM_LANES contiguous LANE_DATA_SIZE-byte
//     beats (vector load/store). All NUM_LANES lanes are issued in parallel.
//   - lane[i].addr = {wide.addr, i[CLOG2(NUM_LANES)-1:0]}; data/byteen are
//     sliced by lane index. flags/tag/rw are broadcast.
//   - wide.req_ready is asserted only after every lane has accepted its
//     request (per-lane backpressure tolerated; sent-mask tracker).
//   - wide.rsp_valid is asserted only after every lane has produced its
//     response (per-lane skid buffer + AND release). Tags are assumed
//     consistent across lanes (broadcast on req side, FIFO ordering on rsp).

module VX_mem_bus_split import VX_gpu_pkg::*; #(
    parameter NUM_LANES        = 1,
    parameter LANE_DATA_SIZE   = 1,
    parameter TAG_WIDTH        = 1,
    parameter MEM_ADDR_WIDTH_P = `MEM_ADDR_WIDTH
) (
    input wire           clk,
    input wire           reset,

    VX_mem_bus_if.slave  wide_bus_if,                 // DATA_SIZE = NUM_LANES * LANE_DATA_SIZE
    VX_mem_bus_if.master lane_bus_if [NUM_LANES]      // each DATA_SIZE = LANE_DATA_SIZE
);
    localparam LANE_INDEX_BITS = (NUM_LANES > 1) ? `CLOG2(NUM_LANES) : 1;
    localparam LANE_DATA_W     = LANE_DATA_SIZE * 8;

    // ----------------------------------------------------------------------
    // Request scatter with per-lane sent-mask tracker.
    // ----------------------------------------------------------------------
    reg  [NUM_LANES-1:0] req_sent_r;
    wire [NUM_LANES-1:0] req_lane_fire;
    wire                 req_all_done;

    for (genvar i = 0; i < NUM_LANES; ++i) begin : g_lane_req
        assign lane_bus_if[i].req_valid       = wide_bus_if.req_valid && ~req_sent_r[i];
        assign lane_bus_if[i].req_data.rw     = wide_bus_if.req_data.rw;
        assign lane_bus_if[i].req_data.addr   = (NUM_LANES > 1)
            ? {wide_bus_if.req_data.addr, LANE_INDEX_BITS'(i)}
            : wide_bus_if.req_data.addr;
        assign lane_bus_if[i].req_data.data   = wide_bus_if.req_data.data[i*LANE_DATA_W +: LANE_DATA_W];
        assign lane_bus_if[i].req_data.byteen = wide_bus_if.req_data.byteen[i*LANE_DATA_SIZE +: LANE_DATA_SIZE];
        assign lane_bus_if[i].req_data.flags  = wide_bus_if.req_data.flags;
        assign lane_bus_if[i].req_data.tag    = wide_bus_if.req_data.tag;
        assign req_lane_fire[i] = lane_bus_if[i].req_valid && lane_bus_if[i].req_ready;
    end

    assign req_all_done    = wide_bus_if.req_valid && (&(req_sent_r | req_lane_fire));
    assign wide_bus_if.req_ready = req_all_done;

    always @(posedge clk) begin
        if (reset) begin
            req_sent_r <= '0;
        end else if (req_all_done) begin
            // Handshake completed; reset for the next wide request.
            req_sent_r <= '0;
        end else if (wide_bus_if.req_valid) begin
            req_sent_r <= req_sent_r | req_lane_fire;
        end
    end

    // ----------------------------------------------------------------------
    // Response gather: per-lane size-2 skid buffer, AND-release.
    // Assumes FIFO ordering per lane and matching wide-request order across
    // lanes (guaranteed by broadcast tags on issue + per-lane FIFOs in lmem).
    // ----------------------------------------------------------------------
    wire [NUM_LANES-1:0]                     skid_valid;
    wire [NUM_LANES-1:0][LANE_DATA_W-1:0]    skid_data;
    wire [NUM_LANES-1:0][TAG_WIDTH-1:0]      skid_tag;
    wire                                     all_skid_valid;
    wire                                     skid_pop;

    for (genvar i = 0; i < NUM_LANES; ++i) begin : g_lane_rsp
        VX_elastic_buffer #(
            .DATAW   (LANE_DATA_W + TAG_WIDTH),
            .SIZE    (8),
            .OUT_REG (0)
        ) skid (
            .clk       (clk),
            .reset     (reset),
            .valid_in  (lane_bus_if[i].rsp_valid),
            .data_in   ({lane_bus_if[i].rsp_data.data, lane_bus_if[i].rsp_data.tag}),
            .ready_in  (lane_bus_if[i].rsp_ready),
            .valid_out (skid_valid[i]),
            .data_out  ({skid_data[i], skid_tag[i]}),
            .ready_out (skid_pop)
        );
        assign wide_bus_if.rsp_data.data[i*LANE_DATA_W +: LANE_DATA_W] = skid_data[i];
    end

    assign all_skid_valid       = &skid_valid;
    assign skid_pop             = all_skid_valid && wide_bus_if.rsp_ready;
    assign wide_bus_if.rsp_valid = all_skid_valid;
    assign wide_bus_if.rsp_data.tag = skid_tag[0];

endmodule
