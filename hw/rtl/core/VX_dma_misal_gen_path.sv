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

`timescale 1ns / 1ps

`include "VX_platform.vh"

// Generated response-to-write datapath for VX_dma_unit_misal. A tagged source
// response is statically sliced by a direction-specific gearbox, compacted by
// the shared source aligner, extended with enabled zero padding, and placed by
// a direction-specific destination assembler.
module VX_dma_misal_gen_path #(
    parameter `STRING INSTANCE_ID = "",
    parameter int DCACHE_BYTES = 64,
    parameter int LMEM_BYTES   = 64,
    parameter int MAX_BYTES    = 64
) (
    input  wire clk,
    input  wire reset,
    input  wire active_dir,

    input  wire                     slot_valid,
    output wire                     slot_ready,
    input  wire [MAX_BYTES*8-1:0]   slot_data,
    input  wire [31:0]              slot_lane,
    input  wire [31:0]              slot_bytes,
    input  wire                     slot_segment_eop,
    input  wire [`LOG2UP((DCACHE_BYTES < LMEM_BYTES)
                         ? DCACHE_BYTES : LMEM_BYTES)-1:0] slot_src_offset,

    input  wire [31:0] seg_size,
    input  wire [31:0] valid_total,
    input  wire        zero_segment_start,
    input  wire [`LOG2UP(DCACHE_BYTES)-1:0] dcache_dst_offset,
    input  wire [`LOG2UP(LMEM_BYTES)-1:0]   lmem_dst_offset,

    output wire                       dcache_wr_valid,
    input  wire                       dcache_wr_ready,
    output wire [DCACHE_BYTES*8-1:0]  dcache_wr_data,
    output wire [DCACHE_BYTES-1:0]    dcache_wr_byteen,
    output wire                       dcache_wr_eop,

    output wire                       lmem_wr_valid,
    input  wire                       lmem_wr_ready,
    output wire [LMEM_BYTES*8-1:0]    lmem_wr_data,
    output wire [LMEM_BYTES-1:0]      lmem_wr_byteen,
    output wire                       lmem_wr_eop
);
    localparam int MIN_BYTES = (DCACHE_BYTES < LMEM_BYTES)
                             ? DCACHE_BYTES : LMEM_BYTES;
    localparam int MIN_BITS = MIN_BYTES * 8;
    localparam int CANON_LANE_BYTES = (MIN_BYTES >= 64) ? 64 : MIN_BYTES;
    localparam int CANON_LANES = MIN_BYTES / CANON_LANE_BYTES;
    localparam int DCACHE_LANES = DCACHE_BYTES / CANON_LANE_BYTES;
    localparam int LMEM_LANES = LMEM_BYTES / CANON_LANE_BYTES;
    localparam int DCACHE_RATIO = DCACHE_BYTES / MIN_BYTES;
    localparam int LMEM_RATIO = LMEM_BYTES / MIN_BYTES;
    localparam int MAX_RATIO = (DCACHE_RATIO > LMEM_RATIO)
                             ? DCACHE_RATIO : LMEM_RATIO;
    localparam int PHASE_WIDTH = `LOG2UP(MAX_RATIO);

    initial begin
        if ((DCACHE_BYTES < 16) || (LMEM_BYTES < 16)
         || !`IS_POW2(DCACHE_BYTES) || !`IS_POW2(LMEM_BYTES)) begin
            $fatal(1, "%s: generalized DMA widths must be powers of two >=16B",
                   INSTANCE_ID);
        end
        if ((DCACHE_BYTES > 512) || (LMEM_BYTES > 512)
         || (MAX_RATIO > 8)) begin
            $fatal(1, "%s: generalized DMA supports <=512B and <=8:1 ratio",
                   INSTANCE_ID);
        end
        if (MAX_BYTES < DCACHE_BYTES || MAX_BYTES < LMEM_BYTES) begin
            $fatal(1, "%s: MAX_BYTES(%0d) must cover both interfaces (%0d, %0d)",
                   INSTANCE_ID, MAX_BYTES, DCACHE_BYTES, LMEM_BYTES);
        end
    end

    wire [DCACHE_BYTES-1:0] dcache_slot_byteen;
    wire [LMEM_BYTES-1:0] lmem_slot_byteen;
    for (genvar byte_idx = 0; byte_idx < DCACHE_BYTES; ++byte_idx) begin : g_dcache_mask
        assign dcache_slot_byteen[byte_idx]
            = (32'(byte_idx) >= slot_lane)
           && (32'(byte_idx) < (slot_lane + slot_bytes));
    end
    for (genvar byte_idx = 0; byte_idx < LMEM_BYTES; ++byte_idx) begin : g_lmem_mask
        assign lmem_slot_byteen[byte_idx]
            = (32'(byte_idx) >= slot_lane)
           && (32'(byte_idx) < (slot_lane + slot_bytes));
    end

    // Kept at module scope for throughput assertions in the focused DMA
    // regression. Equal-width aligned traffic uses aligned_fast_path; all
    // other accepted input beats are reported through stream_fire/byten.
    wire aligned_fast_path;
    wire stream_fire;
    wire [MIN_BYTES-1:0] stream_byteen;

    if (DCACHE_BYTES == LMEM_BYTES) begin : g_equal_width_direct
        wire direct_slot_ready;
        wire direct_out_valid;
        wire [DCACHE_BYTES*8-1:0] direct_out_data;
        wire [DCACHE_BYTES-1:0] direct_out_byteen;
        wire direct_out_eop;
        wire direct_idle;
        wire direct_out_ready = active_dir ? dcache_wr_ready : lmem_wr_ready;
        // wr_dst_seg_base_r advances when the previous EOP write fires. Do
        // not let the next segment sample its old destination offset on that
        // same edge.
        wire direct_segment_block = direct_out_valid && direct_out_eop;
        wire [DCACHE_BYTES-1:0] selected_slot_byteen
            = active_dir ? lmem_slot_byteen : dcache_slot_byteen;

        assign aligned_fast_path = (valid_total == seg_size)
                                && slot_valid
                                && (slot_lane == 0)
                                && (slot_src_offset == '0)
                                && direct_idle
                                && (active_dir ? (dcache_dst_offset == '0)
                                               : (lmem_dst_offset == '0));
        wire aligned_fast_ready = active_dir ? dcache_wr_ready : lmem_wr_ready;

        VX_dma_equal_realigner #(
            .NUM_LANES  (CANON_LANES),
            .LANE_BYTES (CANON_LANE_BYTES)
        ) equal_width_realigner (
            .clk                (clk),
            .reset              (reset),
            .slot_valid         (slot_valid && !aligned_fast_path
                              && !direct_segment_block),
            .slot_ready         (direct_slot_ready),
            .slot_data          (slot_data[0 +: DCACHE_BYTES*8]),
            .slot_byteen        (selected_slot_byteen),
            .slot_lane          (slot_lane),
            .slot_bytes         (slot_bytes),
            .slot_segment_eop   (slot_segment_eop),
            .slot_src_offset    (slot_src_offset),
            .seg_size           (seg_size),
            .valid_total        (valid_total),
            .zero_segment_start (zero_segment_start),
            .dst_offset         (active_dir ? dcache_dst_offset
                                            : lmem_dst_offset),
            .out_valid          (direct_out_valid),
            .out_ready          (direct_out_ready),
            .out_data           (direct_out_data),
            .out_byteen         (direct_out_byteen),
            .out_eop            (direct_out_eop),
            .idle               (direct_idle)
        );

        assign slot_ready = aligned_fast_path ? aligned_fast_ready
                          : (direct_slot_ready && !direct_segment_block);
        assign dcache_wr_valid = active_dir
                               && (aligned_fast_path ? slot_valid
                                                     : direct_out_valid);
        assign dcache_wr_data = aligned_fast_path
                              ? slot_data[0 +: DCACHE_BYTES*8]
                              : direct_out_data;
        assign dcache_wr_byteen = aligned_fast_path
                                ? dcache_slot_byteen : direct_out_byteen;
        assign dcache_wr_eop = aligned_fast_path ? slot_segment_eop
                                                  : direct_out_eop;
        assign lmem_wr_valid = !active_dir
                             && (aligned_fast_path ? slot_valid
                                                   : direct_out_valid);
        assign lmem_wr_data = aligned_fast_path
                            ? slot_data[0 +: LMEM_BYTES*8]
                            : direct_out_data;
        assign lmem_wr_byteen = aligned_fast_path
                              ? lmem_slot_byteen : direct_out_byteen;
        assign lmem_wr_eop = aligned_fast_path ? slot_segment_eop
                                                : direct_out_eop;

        assign stream_fire = slot_valid && !aligned_fast_path
                          && direct_slot_ready;
        assign stream_byteen = selected_slot_byteen;

    end else begin : g_unequal_width

    wire align_out_valid;
    logic segment_write_pending_r;

    // Equal-width, naturally aligned, non-padded segments need no realignment
    // or assembly. Keeping this case combinational preserves the established
    // response-SRAM-to-write latency while all genuinely misaligned traffic
    // continues through the generated aligner/assembler pipeline.
    assign aligned_fast_path = 1'b0;
    wire aligned_fast_ready = active_dir ? dcache_wr_ready : lmem_wr_ready;

    wire selected_gb_valid;
    wire [MIN_BITS-1:0] selected_gb_data;
    wire [MIN_BYTES-1:0] selected_gb_byteen;
    wire selected_gb_ready;
    wire generated_slot_ready;

    if (DCACHE_BYTES == LMEM_BYTES) begin : g_equal_width_source
        assign selected_gb_valid = slot_valid && !aligned_fast_path;
        assign selected_gb_data = slot_data[0 +: MIN_BITS];
        assign selected_gb_byteen = active_dir
                                  ? lmem_slot_byteen : dcache_slot_byteen;
        assign generated_slot_ready = selected_gb_ready;
    end else begin : g_unequal_width_source
        wire dcache_gb_in_ready;
        wire dcache_gb_out_valid;
        wire dcache_gb_out_ready;
        wire [MIN_BITS-1:0] dcache_gb_out_data;
        wire [MIN_BYTES-1:0] dcache_gb_out_byteen;
        wire lmem_gb_in_ready;
        wire lmem_gb_out_valid;
        wire lmem_gb_out_ready;
        wire [MIN_BITS-1:0] lmem_gb_out_data;
        wire [MIN_BYTES-1:0] lmem_gb_out_byteen;

        VX_dma_gearbox #(
            .INSTANCE_ID ({INSTANCE_ID, ".dcache_source"}),
            .IN_BYTES    (DCACHE_BYTES),
            .OUT_BYTES   (MIN_BYTES)
        ) dcache_source_gearbox (
            .clk(clk), .reset(reset),
            .in_valid(slot_valid && !active_dir),
            .in_ready(dcache_gb_in_ready),
            .in_data(slot_data[0 +: DCACHE_BYTES*8]),
            .in_byteen(dcache_slot_byteen),
            .in_last(slot_segment_eop),
            .out_valid(dcache_gb_out_valid),
            .out_ready(dcache_gb_out_ready),
            .out_data(dcache_gb_out_data),
            .out_byteen(dcache_gb_out_byteen),
            .out_last()
        );

        VX_dma_gearbox #(
            .INSTANCE_ID ({INSTANCE_ID, ".lmem_source"}),
            .IN_BYTES    (LMEM_BYTES),
            .OUT_BYTES   (MIN_BYTES)
        ) lmem_source_gearbox (
            .clk(clk), .reset(reset),
            .in_valid(slot_valid && active_dir),
            .in_ready(lmem_gb_in_ready),
            .in_data(slot_data[0 +: LMEM_BYTES*8]),
            .in_byteen(lmem_slot_byteen),
            .in_last(slot_segment_eop),
            .out_valid(lmem_gb_out_valid),
            .out_ready(lmem_gb_out_ready),
            .out_data(lmem_gb_out_data),
            .out_byteen(lmem_gb_out_byteen),
            .out_last()
        );

        assign selected_gb_valid = active_dir ? lmem_gb_out_valid
                                              : dcache_gb_out_valid;
        assign selected_gb_data = active_dir ? lmem_gb_out_data
                                             : dcache_gb_out_data;
        assign selected_gb_byteen = active_dir ? lmem_gb_out_byteen
                                               : dcache_gb_out_byteen;
        assign dcache_gb_out_ready = !active_dir && selected_gb_ready;
        assign lmem_gb_out_ready = active_dir && selected_gb_ready;
        assign generated_slot_ready = active_dir ? lmem_gb_in_ready
                                                 : dcache_gb_in_ready;
    end

    wire selected_gb_fire = selected_gb_valid && selected_gb_ready;

    logic [PHASE_WIDTH-1:0] source_phase_r;
    wire [31:0] first_source_slice = slot_lane / 32'(MIN_BYTES);
    wire [31:0] last_source_slice
        = (slot_lane + slot_bytes - 32'd1) / 32'(MIN_BYTES);
    wire source_slice_relevant = (32'(source_phase_r) >= first_source_slice)
                              && (32'(source_phase_r) <= last_source_slice);

    wire align_in_ready;
    assign selected_gb_ready = source_slice_relevant ? align_in_ready : 1'b1;
    assign slot_ready = aligned_fast_path
                      ? aligned_fast_ready
                      : generated_slot_ready;

    always_ff @(posedge clk) begin
        if (reset) begin
            source_phase_r <= '0;
        end else if (selected_gb_fire) begin
            if (slot_valid && slot_ready)
                source_phase_r <= '0;
            else
                source_phase_r <= source_phase_r + PHASE_WIDTH'(1);
        end
    end

    wire align_out_ready;
    wire [MIN_BITS-1:0] align_out_data;
    wire [MIN_BYTES-1:0] align_out_byteen;
    wire align_out_eop;

    VX_dma_lane_aligner #(
        .NUM_LANES  (CANON_LANES),
        .LANE_BYTES (CANON_LANE_BYTES)
    ) source_lane_aligner (
        .clk            (clk),
        .reset          (reset),
        .in_valid       (selected_gb_valid && source_slice_relevant),
        .in_ready       (align_in_ready),
        .in_data        (selected_gb_data),
        .in_byte_valid  (selected_gb_byteen),
        .in_offset      (slot_src_offset),
        .in_eop         (slot_segment_eop
                      && (32'(source_phase_r) == last_source_slice)),
        .out_valid      (align_out_valid),
        .out_ready      (align_out_ready),
        .out_data       (align_out_data),
        .out_byte_valid (align_out_byteen),
        .out_eop        (align_out_eop)
    );

    logic [31:0] stream_offset_r;
    logic padding_active_r;
    wire [31:0] stream_remaining = (stream_offset_r < seg_size)
        ? (seg_size - stream_offset_r) : 32'd0;
    wire [31:0] stream_bytes = (stream_remaining < 32'(MIN_BYTES))
        ? stream_remaining : 32'(MIN_BYTES);
    wire stream_source_valid = padding_active_r ? 1'b1 : align_out_valid;
    wire [MIN_BITS-1:0] stream_data;
    wire stream_eop = (stream_bytes >= stream_remaining);
    wire stream_ready;
    assign stream_fire = stream_source_valid && stream_ready;

    for (genvar byte_idx = 0; byte_idx < MIN_BYTES; ++byte_idx) begin : g_padding_bytes
        wire enabled = 32'(byte_idx) < stream_bytes;
        assign stream_byteen[byte_idx] = enabled;
        assign stream_data[byte_idx*8 +: 8]
            = (!padding_active_r && enabled && align_out_byteen[byte_idx])
            ? align_out_data[byte_idx*8 +: 8] : 8'd0;
    end

    assign align_out_ready = !padding_active_r && stream_ready;

    always_ff @(posedge clk) begin
        if (reset) begin
            stream_offset_r <= '0;
            padding_active_r <= 1'b0;
        end else begin
            if (stream_fire) begin
                if (stream_eop) begin
                    stream_offset_r <= '0;
                    padding_active_r <= 1'b0;
                end else begin
                    stream_offset_r <= stream_offset_r + stream_bytes;
                    if (!padding_active_r && align_out_eop)
                        padding_active_r <= 1'b1;
                end
            end

            // A completed zero-payload segment may launch the next one on the
            // same edge. The new kickoff must win over the old segment's EOP.
            if (zero_segment_start) begin
                stream_offset_r <= '0;
                padding_active_r <= 1'b1;
            end
        end
    end

    wire dcache_asm_in_ready;
    wire dcache_asm_out_valid;
    wire [DCACHE_BYTES*8-1:0] dcache_asm_out_data;
    wire [DCACHE_BYTES-1:0] dcache_asm_out_byteen;
    wire dcache_asm_out_eop;

    wire lmem_asm_in_ready;
    wire lmem_asm_out_valid;
    wire [LMEM_BYTES*8-1:0] lmem_asm_out_data;
    wire [LMEM_BYTES-1:0] lmem_asm_out_byteen;
    wire lmem_asm_out_eop;

    if (DCACHE_BYTES == LMEM_BYTES) begin : g_equal_width_destination
        wire shared_asm_in_ready;
        wire shared_asm_out_valid;
        wire [DCACHE_BYTES*8-1:0] shared_asm_out_data;
        wire [DCACHE_BYTES-1:0] shared_asm_out_byteen;
        wire shared_asm_out_eop;

        VX_dma_lane_assembler #(
            .IN_LANES   (CANON_LANES),
            .OUT_LANES  (DCACHE_LANES),
            .LANE_BYTES (CANON_LANE_BYTES)
        ) shared_destination_assembler (
            .clk           (clk),
            .reset         (reset),
            .in_valid      (stream_source_valid && !aligned_fast_path
                         && !segment_write_pending_r),
            .in_ready      (shared_asm_in_ready),
            .in_data       (stream_data),
            .in_byte_valid (stream_byteen),
            .in_offset     (active_dir ? dcache_dst_offset
                                       : lmem_dst_offset),
            .in_eop        (stream_eop),
            .out_valid     (shared_asm_out_valid),
            .out_ready     (active_dir ? dcache_wr_ready : lmem_wr_ready),
            .out_data      (shared_asm_out_data),
            .out_byteen    (shared_asm_out_byteen),
            .out_eop       (shared_asm_out_eop)
        );

        assign dcache_asm_in_ready = shared_asm_in_ready;
        assign dcache_asm_out_valid = shared_asm_out_valid;
        assign dcache_asm_out_data = shared_asm_out_data;
        assign dcache_asm_out_byteen = shared_asm_out_byteen;
        assign dcache_asm_out_eop = shared_asm_out_eop;
        assign lmem_asm_in_ready = shared_asm_in_ready;
        assign lmem_asm_out_valid = shared_asm_out_valid;
        assign lmem_asm_out_data = shared_asm_out_data;
        assign lmem_asm_out_byteen = shared_asm_out_byteen;
        assign lmem_asm_out_eop = shared_asm_out_eop;
    end else begin : g_unequal_width_destination
        VX_dma_lane_assembler #(
            .IN_LANES   (CANON_LANES),
            .OUT_LANES  (DCACHE_LANES),
            .LANE_BYTES (CANON_LANE_BYTES)
        ) dcache_destination_assembler (
            .clk(clk), .reset(reset),
            .in_valid(stream_source_valid && !segment_write_pending_r
                   && active_dir),
            .in_ready(dcache_asm_in_ready),
            .in_data(stream_data),
            .in_byte_valid(stream_byteen),
            .in_offset(dcache_dst_offset),
            .in_eop(stream_eop),
            .out_valid(dcache_asm_out_valid),
            .out_ready(dcache_wr_ready),
            .out_data(dcache_asm_out_data),
            .out_byteen(dcache_asm_out_byteen),
            .out_eop(dcache_asm_out_eop)
        );

        VX_dma_lane_assembler #(
            .IN_LANES   (CANON_LANES),
            .OUT_LANES  (LMEM_LANES),
            .LANE_BYTES (CANON_LANE_BYTES)
        ) lmem_destination_assembler (
            .clk(clk), .reset(reset),
            .in_valid(stream_source_valid && !segment_write_pending_r
                   && !active_dir),
            .in_ready(lmem_asm_in_ready),
            .in_data(stream_data),
            .in_byte_valid(stream_byteen),
            .in_offset(lmem_dst_offset),
            .in_eop(stream_eop),
            .out_valid(lmem_asm_out_valid),
            .out_ready(lmem_wr_ready),
            .out_data(lmem_asm_out_data),
            .out_byteen(lmem_asm_out_byteen),
            .out_eop(lmem_asm_out_eop)
        );
    end

    assign stream_ready = !segment_write_pending_r
                       && (active_dir ? dcache_asm_in_ready
                                      : lmem_asm_in_ready);
    assign dcache_wr_valid = active_dir
                           && (aligned_fast_path ? slot_valid
                                                 : dcache_asm_out_valid);
    assign dcache_wr_data = aligned_fast_path
                          ? slot_data[0 +: DCACHE_BYTES*8]
                          : dcache_asm_out_data;
    assign dcache_wr_byteen = aligned_fast_path
                            ? dcache_slot_byteen
                            : dcache_asm_out_byteen;
    assign dcache_wr_eop = aligned_fast_path ? slot_segment_eop
                                              : dcache_asm_out_eop;
    assign lmem_wr_valid = !active_dir
                         && (aligned_fast_path ? slot_valid
                                               : lmem_asm_out_valid);
    assign lmem_wr_data = aligned_fast_path
                        ? slot_data[0 +: LMEM_BYTES*8]
                        : lmem_asm_out_data;
    assign lmem_wr_byteen = aligned_fast_path
                          ? lmem_slot_byteen
                          : lmem_asm_out_byteen;
    assign lmem_wr_eop = aligned_fast_path ? slot_segment_eop
                                            : lmem_asm_out_eop;

    wire destination_eop_fire = active_dir
        ? (dcache_asm_out_valid && dcache_wr_ready && dcache_asm_out_eop)
        : (lmem_asm_out_valid && lmem_wr_ready && lmem_asm_out_eop);

    // Do not let the next discontinuous segment sample the old destination
    // offset while the previous segment's final assembled beat is pending.
    always_ff @(posedge clk) begin
        if (reset) begin
            segment_write_pending_r <= 1'b0;
        end else begin
            if (destination_eop_fire)
                segment_write_pending_r <= 1'b0;
            if (stream_fire && stream_eop)
                segment_write_pending_r <= 1'b1;
        end
    end

    end

endmodule
