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

// Places a compact byte stream into destination-aligned output beats. The
// runtime offset is split into coarse lane and fine byte phases. Each input
// lane fans out only to two adjacent destination lanes; no output-wide
// variable shifter or byte read-modify-write network is used.

`timescale 1ns / 1ps

`include "VX_platform.vh"

module VX_dma_lane_assembler #(
    parameter int IN_LANES   = 1,
    parameter int OUT_LANES  = 1,
    parameter int LANE_BYTES = 64
) (
    input  wire clk,
    input  wire reset,

    input  wire                                      in_valid,
    output wire                                      in_ready,
    input  wire [IN_LANES*LANE_BYTES*8-1:0]          in_data,
    input  wire [IN_LANES*LANE_BYTES-1:0]            in_byte_valid,
    input  wire [((OUT_LANES*LANE_BYTES > 1)
                ? $clog2(OUT_LANES*LANE_BYTES)
                : 1)-1:0]                           in_offset,
    input  wire                                      in_eop,

    output wire                                      out_valid,
    input  wire                                      out_ready,
    output wire [OUT_LANES*LANE_BYTES*8-1:0]         out_data,
    output wire [OUT_LANES*LANE_BYTES-1:0]           out_byteen,
    output wire                                      out_eop,
    output wire                                      idle
);
    localparam int IN_BYTES     = IN_LANES * LANE_BYTES;
    localparam int OUT_BYTES    = OUT_LANES * LANE_BYTES;
    localparam int LANE_BITS    = LANE_BYTES * 8;
    localparam int OUT_BITS     = OUT_BYTES * 8;
    localparam int OFFSET_WIDTH = `LOG2UP(OUT_BYTES);
    localparam int FINE_WIDTH   = `LOG2UP(LANE_BYTES);
    localparam int COARSE_WIDTH = `LOG2UP(OUT_LANES);

    initial begin
        if (!`IS_POW2(IN_LANES) || (IN_LANES > 8))
            $fatal(1, "IN_LANES(%0d) must be one of 1, 2, 4, or 8", IN_LANES);
        if (!`IS_POW2(OUT_LANES) || (OUT_LANES > 8))
            $fatal(1, "OUT_LANES(%0d) must be one of 1, 2, 4, or 8", OUT_LANES);
        if ((OUT_LANES < IN_LANES) || ((OUT_LANES % IN_LANES) != 0)) begin
            $fatal(1, "OUT_LANES(%0d) must be an integer multiple of IN_LANES(%0d)",
                   OUT_LANES, IN_LANES);
        end
        if (!`IS_POW2(LANE_BYTES) || (LANE_BYTES > 64)) begin
            $fatal(1, "LANE_BYTES(%0d) must be a power of two no greater than 64",
                   LANE_BYTES);
        end
    end

    logic [OUT_LANES-1:0][LANE_BITS-1:0] bank_data_r;
    logic [OUT_LANES-1:0][LANE_BYTES-1:0] bank_byteen_r;
    logic [OFFSET_WIDTH-1:0] phase_r;
`ifndef SYNTHESIS
    logic [OFFSET_WIDTH-1:0] segment_offset_r;
`endif
    logic segment_active_r;

    logic [OUT_BITS-1:0] out_data_r;
    logic [OUT_BYTES-1:0] out_byteen_r;
    logic out_valid_r;
    logic out_eop_r;

    logic flush_pending_r;

    wire [OFFSET_WIDTH-1:0] current_phase
        = segment_active_r ? phase_r : in_offset;
    wire [FINE_WIDTH-1:0] fine_phase = (LANE_BYTES > 1)
        ? FINE_WIDTH'(current_phase)
        : '0;
    wire [COARSE_WIDTH-1:0] coarse_phase = (OUT_LANES > 1)
        ? COARSE_WIDTH'(current_phase >> $clog2(LANE_BYTES))
        : '0;

    wire [IN_LANES-1:0][LANE_BITS-1:0] masked_input_data;
    for (genvar lane = 0; lane < IN_LANES; ++lane) begin : g_masked_input_lanes
        for (genvar byte_idx = 0; byte_idx < LANE_BYTES; ++byte_idx) begin : g_bytes
            assign masked_input_data[lane][byte_idx*8 +: 8]
                = in_data[(lane*LANE_BYTES+byte_idx)*8 +: 8]
                & {8{in_byte_valid[lane*LANE_BYTES+byte_idx]}};
        end
    end

    // A lane-local fine shifter has a fixed two-lane window. Its low half
    // remains in the coarse destination lane and its high half carries to the
    // immediately adjacent lane.
    wire [IN_LANES-1:0][2*LANE_BITS-1:0] shifted_lane_data;
    wire [IN_LANES-1:0][2*LANE_BYTES-1:0] shifted_lane_byteen;
    for (genvar lane = 0; lane < IN_LANES; ++lane) begin : g_shifted_input_lanes
        wire [2*LANE_BITS-1:0] extended_data = {{LANE_BITS{1'b0}},
                                                masked_input_data[lane]};
        wire [2*LANE_BYTES-1:0] extended_byteen = {{LANE_BYTES{1'b0}},
                                                   in_byte_valid[lane*LANE_BYTES
                                                               +: LANE_BYTES]};
        assign shifted_lane_data[lane]
            = extended_data << (8 * fine_phase);
        assign shifted_lane_byteen[lane]
            = extended_byteen << fine_phase;
    end

    wire [OUT_LANES-1:0][LANE_BITS-1:0] current_add_data;
    wire [OUT_LANES-1:0][LANE_BYTES-1:0] current_add_byteen;
    wire [OUT_LANES-1:0][LANE_BITS-1:0] spill_add_data;
    wire [OUT_LANES-1:0][LANE_BYTES-1:0] spill_add_byteen;

    // Generate one fixed destination slice per output lane. Runtime steering
    // chooses among at most IN_LANES bounded lane contributions; data never
    // traverses a bus-wide byte barrel shifter.
    for (genvar out_lane = 0; out_lane < OUT_LANES; ++out_lane) begin : g_output_lanes
        logic [LANE_BITS-1:0] current_data;
        logic [LANE_BYTES-1:0] current_byteen;
        logic [LANE_BITS-1:0] spill_data;
        logic [LANE_BYTES-1:0] spill_byteen;

        always_comb begin
            current_data = '0;
            current_byteen = '0;
            spill_data = '0;
            spill_byteen = '0;

            for (integer in_lane = 0; in_lane < IN_LANES; ++in_lane) begin
                if ((integer'(coarse_phase) + in_lane) == out_lane) begin
                    current_data |= shifted_lane_data[in_lane][LANE_BITS-1:0];
                    current_byteen |= shifted_lane_byteen[in_lane][LANE_BYTES-1:0];
                end
                if ((integer'(coarse_phase) + in_lane + 1) == out_lane) begin
                    current_data |= shifted_lane_data[in_lane][2*LANE_BITS-1
                                                               -: LANE_BITS];
                    current_byteen |= shifted_lane_byteen[in_lane][2*LANE_BYTES-1
                                                                   -: LANE_BYTES];
                end
                if ((integer'(coarse_phase) + in_lane)
                    == (OUT_LANES + out_lane)) begin
                    spill_data |= shifted_lane_data[in_lane][LANE_BITS-1:0];
                    spill_byteen |= shifted_lane_byteen[in_lane][LANE_BYTES-1:0];
                end
                if ((integer'(coarse_phase) + in_lane + 1)
                    == (OUT_LANES + out_lane)) begin
                    spill_data |= shifted_lane_data[in_lane][2*LANE_BITS-1
                                                             -: LANE_BITS];
                    spill_byteen |= shifted_lane_byteen[in_lane][2*LANE_BYTES-1
                                                                 -: LANE_BYTES];
                end
            end
        end

        assign current_add_data[out_lane] = current_data;
        assign current_add_byteen[out_lane] = current_byteen;
        assign spill_add_data[out_lane] = spill_data;
        assign spill_add_byteen[out_lane] = spill_byteen;
    end

    wire [OUT_LANES-1:0][LANE_BITS-1:0] assembled_data
        = bank_data_r | current_add_data;
    wire [OUT_LANES-1:0][LANE_BYTES-1:0] assembled_byteen
        = bank_byteen_r | current_add_byteen;

    wire [OFFSET_WIDTH:0] phase_sum
        = (OFFSET_WIDTH+1)'(current_phase) + (OFFSET_WIDTH+1)'(IN_BYTES);
    wire crosses_boundary = (phase_sum >= (OFFSET_WIDTH+1)'(OUT_BYTES));
    wire spill_has_bytes = |spill_add_byteen;
    // Even an empty non-crossing final chunk emits an EOP beat so the consumer
    // cannot lose the segment boundary. An empty spill after a crossing is not
    // emitted; the completed main beat receives EOP instead.
    wire input_needs_output = crosses_boundary || in_eop;
    wire output_slot_available = !out_valid_r || out_ready;
    wire in_fire = in_valid && in_ready;

    assign in_ready = !flush_pending_r
                   && (!input_needs_output || output_slot_available);
    assign out_valid = out_valid_r;
    assign out_data = out_data_r;
    assign out_byteen = out_byteen_r;
    assign out_eop = out_eop_r;
    assign idle = !segment_active_r
               && !out_valid_r
               && !flush_pending_r
               && !(|bank_byteen_r);

    always_ff @(posedge clk) begin
        if (reset) begin
            bank_data_r <= '0;
            bank_byteen_r <= '0;
            phase_r <= '0;
`ifndef SYNTHESIS
            segment_offset_r <= '0;
`endif
            segment_active_r <= 1'b0;
            out_data_r <= '0;
            out_byteen_r <= '0;
            out_valid_r <= 1'b0;
            out_eop_r <= 1'b0;
            flush_pending_r <= 1'b0;
        end else begin
            if (out_valid_r && out_ready) begin
                out_valid_r <= 1'b0;
                out_eop_r <= 1'b0;
            end

            if (flush_pending_r && output_slot_available) begin
                out_data_r <= bank_data_r;
                out_byteen_r <= bank_byteen_r;
                out_valid_r <= 1'b1;
                out_eop_r <= 1'b1;
                bank_data_r <= '0;
                bank_byteen_r <= '0;
                flush_pending_r <= 1'b0;
            end else if (in_fire) begin
                if (input_needs_output) begin
                    out_data_r <= assembled_data;
                    out_byteen_r <= assembled_byteen;
                    out_valid_r <= 1'b1;
                    out_eop_r <= in_eop
                              && !(crosses_boundary && spill_has_bytes);
                end

`ifndef SYNTHESIS
                if (!segment_active_r)
                    segment_offset_r <= in_offset;
`endif

                if (in_eop) begin
                    phase_r <= '0;
                    segment_active_r <= 1'b0;

                    if (crosses_boundary && spill_has_bytes) begin
                        bank_data_r <= spill_add_data;
                        bank_byteen_r <= spill_add_byteen;
                        flush_pending_r <= 1'b1;
                    end else begin
                        bank_data_r <= '0;
                        bank_byteen_r <= '0;
                    end
                end else begin
                    segment_active_r <= 1'b1;
                    if (crosses_boundary) begin
                        bank_data_r <= spill_add_data;
                        bank_byteen_r <= spill_add_byteen;
                        phase_r <= OFFSET_WIDTH'(phase_sum
                                                 - (OFFSET_WIDTH+1)'(OUT_BYTES));
                    end else begin
                        bank_data_r <= assembled_data;
                        bank_byteen_r <= assembled_byteen;
                        phase_r <= OFFSET_WIDTH'(phase_sum);
                    end
                end
            end
        end
    end

`ifndef SYNTHESIS
    always @(posedge clk) begin
        if (!reset && in_fire && segment_active_r) begin
            assert (in_offset == segment_offset_r)
                else $fatal(1, "in_offset changed within a destination segment");
        end
    end
`endif

endmodule
