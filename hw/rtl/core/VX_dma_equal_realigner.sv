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

// Equal-width source and destination realigner. Source bytes are placed
// directly into destination-aligned banks using the modulo displacement
// (destination offset - source offset). This fuses the general source-align
// and destination-assemble permutations into one lane-bounded network while
// retaining one full input and output beat per cycle.

`timescale 1ns / 1ps

`include "VX_platform.vh"

module VX_dma_equal_realigner #(
    parameter int NUM_LANES  = 1,
    parameter int LANE_BYTES = 64
) (
    input  wire clk,
    input  wire reset,

    input  wire                                    slot_valid,
    output wire                                    slot_ready,
    input  wire [NUM_LANES*LANE_BYTES*8-1:0]       slot_data,
    input  wire [NUM_LANES*LANE_BYTES-1:0]         slot_byteen,
    input  wire [31:0]                             slot_lane,
    input  wire [31:0]                             slot_bytes,
    input  wire                                    slot_segment_eop,
    input  wire [`LOG2UP(NUM_LANES*LANE_BYTES)-1:0] slot_src_offset,

    input  wire [31:0]                             seg_size,
    input  wire [31:0]                             valid_total,
    input  wire                                    zero_segment_start,
    input  wire [`LOG2UP(NUM_LANES*LANE_BYTES)-1:0] dst_offset,

    output wire                                    out_valid,
    input  wire                                    out_ready,
    output wire [NUM_LANES*LANE_BYTES*8-1:0]       out_data,
    output wire [NUM_LANES*LANE_BYTES-1:0]         out_byteen,
    output wire                                    out_eop,
    output wire                                    idle
);
    localparam int WIDTH_BYTES = NUM_LANES * LANE_BYTES;
    localparam int OFFSET_W = `LOG2UP(WIDTH_BYTES);

    initial begin
        if (!`IS_POW2(WIDTH_BYTES))
            $fatal(1, "equal DMA realigner width must be a power of two");
    end

    logic padding_active_r;
    logic [31:0] padding_remaining_r;
    logic [OFFSET_W-1:0] padding_lane_r;
    logic [OFFSET_W-1:0] displacement_r;

    wire [31:0] padding_room = 32'(WIDTH_BYTES) - 32'(padding_lane_r);
    wire [31:0] padding_bytes = (padding_remaining_r < padding_room)
        ? padding_remaining_r : padding_room;
    wire padding_eop = padding_remaining_r <= padding_room;

    wire [WIDTH_BYTES-1:0] padding_byteen;
    for (genvar byte_idx = 0; byte_idx < WIDTH_BYTES; ++byte_idx) begin : g_padding_mask
        assign padding_byteen[byte_idx]
            = (32'(byte_idx) >= 32'(padding_lane_r))
           && (32'(byte_idx) < (32'(padding_lane_r) + padding_bytes));
    end

    wire source_has_padding = valid_total < seg_size;
    wire [31:0] source_padding_total = seg_size - valid_total;
    wire [31:0] source_end_lane = slot_lane + slot_bytes;
    wire [31:0] source_padding_room = 32'(WIDTH_BYTES) - source_end_lane;
    wire [31:0] source_padding_bytes
        = (source_padding_total < source_padding_room)
        ? source_padding_total : source_padding_room;
    wire source_padding_spills = source_padding_total > source_padding_room;
    wire [WIDTH_BYTES-1:0] source_padding_byteen;
    wire [WIDTH_BYTES*8-1:0] masked_slot_data;
    for (genvar byte_idx = 0; byte_idx < WIDTH_BYTES; ++byte_idx) begin : g_source_merge
        assign source_padding_byteen[byte_idx]
            = slot_segment_eop && source_has_padding
           && (32'(byte_idx) >= source_end_lane)
           && (32'(byte_idx) < (source_end_lane + source_padding_bytes));
        assign masked_slot_data[byte_idx*8 +: 8]
            = slot_data[byte_idx*8 +: 8] & {8{slot_byteen[byte_idx]}};
    end
    wire [OFFSET_W-1:0] source_displacement
        = OFFSET_W'(dst_offset - slot_src_offset);
    wire asm_in_valid = padding_active_r ? 1'b1 : slot_valid;
    wire [WIDTH_BYTES*8-1:0] asm_in_data
        = padding_active_r ? '0 : masked_slot_data;
    wire [WIDTH_BYTES-1:0] asm_in_byteen
        = padding_active_r ? padding_byteen
                           : (slot_byteen | source_padding_byteen);
    wire [OFFSET_W-1:0] asm_in_offset
        = padding_active_r ? displacement_r : source_displacement;
    wire asm_in_eop = padding_active_r ? padding_eop
        : (slot_segment_eop && !source_padding_spills);
    wire asm_in_ready;
    wire asm_in_fire = asm_in_valid && asm_in_ready;

    assign slot_ready = !padding_active_r && asm_in_ready;

    wire assembler_idle;
    wire asm_out_valid;
    wire [WIDTH_BYTES*8-1:0] asm_out_data;
    wire [WIDTH_BYTES-1:0] asm_out_byteen;
    wire asm_out_eop;
    wire asm_out_keep = (|asm_out_byteen) || asm_out_eop;
    wire asm_out_ready = asm_out_keep ? out_ready : 1'b1;
    VX_dma_lane_assembler #(
        .IN_LANES   (NUM_LANES),
        .OUT_LANES  (NUM_LANES),
        .LANE_BYTES (LANE_BYTES)
    ) destination_assembler (
        .clk           (clk),
        .reset         (reset),
        .in_valid      (asm_in_valid),
        .in_ready      (asm_in_ready),
        .in_data       (asm_in_data),
        .in_byte_valid (asm_in_byteen),
        .in_offset     (asm_in_offset),
        .in_eop        (asm_in_eop),
        .out_valid     (asm_out_valid),
        .out_ready     (asm_out_ready),
        .out_data      (asm_out_data),
        .out_byteen    (asm_out_byteen),
        .out_eop       (asm_out_eop),
        .idle          (assembler_idle)
    );

    // A negative modulo displacement may produce one empty physical beat
    // before enough source data exists to form the first destination beat.
    // Consume only that empty non-EOP beat locally; preserve the assembler's
    // public empty-beat contract for every other user.
    assign out_valid = asm_out_valid && asm_out_keep;
    assign out_data = asm_out_data;
    assign out_byteen = asm_out_byteen;
    assign out_eop = asm_out_eop;
    assign idle = !padding_active_r && assembler_idle;

    always_ff @(posedge clk) begin
        if (reset) begin
            padding_active_r <= 1'b0;
            padding_remaining_r <= '0;
            padding_lane_r <= '0;
            displacement_r <= '0;
        end else begin
            if (asm_in_fire && !padding_active_r && slot_segment_eop
             && source_padding_spills) begin
                padding_active_r <= 1'b1;
                padding_remaining_r <= source_padding_total
                                     - source_padding_bytes;
                padding_lane_r <= '0;
                displacement_r <= source_displacement;
            end else if (asm_in_fire && padding_active_r) begin
                if (padding_eop) begin
                    padding_active_r <= 1'b0;
                    padding_remaining_r <= '0;
                    padding_lane_r <= '0;
                end else begin
                    padding_remaining_r <= padding_remaining_r - padding_bytes;
                    padding_lane_r <= '0;
                end
            end

            if (zero_segment_start) begin
                padding_active_r <= 1'b1;
                padding_remaining_r <= seg_size;
                padding_lane_r <= '0;
                displacement_r <= dst_offset;
            end
        end
    end

endmodule
