// Copyright © 2019-2026
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

// Compacts a source-aligned byte stream by removing the transaction's leading
// byte offset. Each output lane uses one fine-grained shifter over two adjacent
// lanes. Wider datapaths replicate the bounded lane shifter instead of growing
// one bus-wide barrel shifter.

`timescale 1ns / 1ps

`include "VX_platform.vh"

module VX_dma_lane_aligner #(
    parameter int NUM_LANES  = 1,
    parameter int LANE_BYTES = 64
) (
    input  wire clk,
    input  wire reset,

    input  wire                                    in_valid,
    output wire                                    in_ready,
    input  wire [NUM_LANES*LANE_BYTES*8-1:0]       in_data,
    input  wire [NUM_LANES*LANE_BYTES-1:0]         in_byte_valid,
    input  wire [((NUM_LANES*LANE_BYTES > 1)
                ? $clog2(NUM_LANES*LANE_BYTES)
                : 1)-1:0]                         in_offset,
    input  wire                                    in_eop,

    output wire                                    out_valid,
    input  wire                                    out_ready,
    output wire [NUM_LANES*LANE_BYTES*8-1:0]       out_data,
    output wire [NUM_LANES*LANE_BYTES-1:0]         out_byte_valid,
    output wire                                    out_eop
);
    localparam int VECTOR_BYTES     = NUM_LANES * LANE_BYTES;
    localparam int VECTOR_BITS      = VECTOR_BYTES * 8;
    localparam int LANE_BITS        = LANE_BYTES * 8;
    localparam int OFFSET_WIDTH     = `LOG2UP(VECTOR_BYTES);
    localparam int FINE_WIDTH       = `LOG2UP(LANE_BYTES);
    localparam int LANE_INDEX_WIDTH = `LOG2UP(NUM_LANES);

    initial begin
        if (!`IS_POW2(NUM_LANES) || (NUM_LANES > 8))
            $fatal(1, "NUM_LANES(%0d) must be one of 1, 2, 4, or 8", NUM_LANES);
        if (!`IS_POW2(LANE_BYTES) || (LANE_BYTES > 64))
            $fatal(1, "LANE_BYTES(%0d) must be a power of two no greater than 64", LANE_BYTES);
    end

    typedef struct packed {
        logic [VECTOR_BITS-1:0]  data;
        logic [VECTOR_BYTES-1:0] byte_valid;
        logic [OFFSET_WIDTH-1:0] offset;
        logic                    eop;
    } payload_t;

    wire payload_t in_payload = '{in_data, in_byte_valid, in_offset, in_eop};

    logic     q0_valid_r;
    payload_t q0_payload_r;
    logic     q1_valid_r;
    payload_t q1_payload_r;

    wire [FINE_WIDTH-1:0] fine_offset = (LANE_BYTES > 1)
        ? FINE_WIDTH'(q0_payload_r.offset)
        : '0;
    wire [LANE_INDEX_WIDTH-1:0] coarse_offset = (NUM_LANES > 1)
        ? LANE_INDEX_WIDTH'(q0_payload_r.offset >> $clog2(LANE_BYTES))
        : '0;

    wire use_next_vector = q1_valid_r && !q0_payload_r.eop;
    wire [VECTOR_BITS-1:0] next_data = use_next_vector ? q1_payload_r.data : '0;
    wire [VECTOR_BYTES-1:0] next_byte_valid = use_next_vector
        ? q1_payload_r.byte_valid
        : '0;

    wire [2*NUM_LANES-1:0][LANE_BITS-1:0] window_data_lanes;
    wire [2*NUM_LANES-1:0][LANE_BYTES-1:0] window_valid_lanes;

    for (genvar i = 0; i < NUM_LANES; ++i) begin : g_window_lanes
        assign window_data_lanes[i] = q0_payload_r.data[i*LANE_BITS +: LANE_BITS];
        assign window_data_lanes[NUM_LANES+i]
            = next_data[i*LANE_BITS +: LANE_BITS];
        assign window_valid_lanes[i]
            = q0_payload_r.byte_valid[i*LANE_BYTES +: LANE_BYTES];
        assign window_valid_lanes[NUM_LANES+i]
            = next_byte_valid[i*LANE_BYTES +: LANE_BYTES];
    end

    wire [NUM_LANES-1:0][LANE_BITS-1:0] aligned_data_lanes;
    wire [NUM_LANES-1:0][LANE_BYTES-1:0] aligned_valid_lanes;

    for (genvar i = 0; i < NUM_LANES; ++i) begin : g_aligned_lanes
        wire [LANE_INDEX_WIDTH:0] source_lane
            = (LANE_INDEX_WIDTH+1)'(coarse_offset) + (LANE_INDEX_WIDTH+1)'(i);
        wire [2*LANE_BITS-1:0] adjacent_data = {
            window_data_lanes[source_lane+1],
            window_data_lanes[source_lane]
        };
        wire [2*LANE_BYTES-1:0] adjacent_valid = {
            window_valid_lanes[source_lane+1],
            window_valid_lanes[source_lane]
        };

        assign aligned_data_lanes[i] = (fine_offset == 0)
            ? adjacent_data[LANE_BITS-1:0]
            : LANE_BITS'(adjacent_data >> (8 * fine_offset));
        assign aligned_valid_lanes[i] = (fine_offset == 0)
            ? adjacent_valid[LANE_BYTES-1:0]
            : LANE_BYTES'(adjacent_valid >> fine_offset);

        assign out_data[i*LANE_BITS +: LANE_BITS] = aligned_data_lanes[i];
        assign out_byte_valid[i*LANE_BYTES +: LANE_BYTES]
            = aligned_valid_lanes[i];
    end

    wire needs_next_vector = (q0_payload_r.offset != 0) && !q0_payload_r.eop;
    wire output_available = q0_valid_r && (!needs_next_vector || q1_valid_r);
    wire output_has_bytes = |out_byte_valid;
    wire output_fire = out_valid && out_ready;
    wire output_drop = output_available && !output_has_bytes;
    wire pop = output_fire || output_drop;
    wire push;
    wire [NUM_LANES-1:0] q1_has_remaining_bytes_by_lane;
    for (genvar i = 0; i < NUM_LANES; ++i) begin : g_q1_remaining_bytes
        wire [LANE_BYTES-1:0] lane_byte_valid
            = q1_payload_r.byte_valid[i*LANE_BYTES +: LANE_BYTES];
        assign q1_has_remaining_bytes_by_lane[i]
            = (LANE_INDEX_WIDTH'(i) < coarse_offset) ? 1'b0
            : (LANE_INDEX_WIDTH'(i) == coarse_offset)
                ? |(lane_byte_valid >> fine_offset)
                : |lane_byte_valid;
    end
    wire q1_has_remaining_bytes = |q1_has_remaining_bytes_by_lane;

    assign out_valid = output_available && output_has_bytes;
    assign out_eop = q0_payload_r.eop
                  || (use_next_vector && q1_payload_r.eop && !q1_has_remaining_bytes);

    // A simultaneous pop accepts the replacement for a full two-entry window.
    assign in_ready = !q1_valid_r || pop;
    assign push = in_valid && in_ready;

    always @(posedge clk) begin
        if (reset) begin
            q0_valid_r <= 1'b0;
            q1_valid_r <= 1'b0;
        end else begin
            case ({push, pop})
                2'b10: begin
                    if (q0_valid_r) begin
                        q1_valid_r <= 1'b1;
                        q1_payload_r <= in_payload;
                    end else begin
                        q0_valid_r <= 1'b1;
                        q0_payload_r <= in_payload;
                    end
                end
                2'b01: begin
                    if (q1_valid_r) begin
                        q0_valid_r <= 1'b1;
                        q0_payload_r <= q1_payload_r;
                    end else begin
                        q0_valid_r <= 1'b0;
                    end
                    q1_valid_r <= 1'b0;
                end
                2'b11: begin
                    if (q1_valid_r) begin
                        q0_valid_r <= 1'b1;
                        q0_payload_r <= q1_payload_r;
                        q1_valid_r <= 1'b1;
                        q1_payload_r <= in_payload;
                    end else begin
                        q0_valid_r <= 1'b1;
                        q0_payload_r <= in_payload;
                        q1_valid_r <= 1'b0;
                    end
                end
                default: begin
                end
            endcase
        end
    end

`ifndef SYNTHESIS
    always @(posedge clk) begin
        if (!reset && push) begin
            assert (!(q1_valid_r && !q1_payload_r.eop
                   && (in_offset != q1_payload_r.offset)))
                else $fatal(1, "in_offset changed before eop");
            assert (!(!q1_valid_r && q0_valid_r && !q0_payload_r.eop
                   && (in_offset != q0_payload_r.offset)))
                else $fatal(1, "in_offset changed before eop");
        end
    end
`endif

endmodule
