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

`include "VX_platform.vh"

module VX_dma_gearbox #(
    parameter `STRING INSTANCE_ID = "",
    parameter int IN_BYTES  = 64,
    parameter int OUT_BYTES = 64
) (
    input wire clk,
    input wire reset,

    input  wire                  in_valid,
    output wire                  in_ready,
    input  wire [IN_BYTES*8-1:0] in_data,
    input  wire [IN_BYTES-1:0]   in_byteen,
    input  wire                  in_last,

    output wire                   out_valid,
    input  wire                   out_ready,
    output wire [OUT_BYTES*8-1:0] out_data,
    output wire [OUT_BYTES-1:0]   out_byteen,
    output wire                   out_last
);

    localparam int MIN_QUALIFIED_BYTES = 16;
    localparam int MAX_QUALIFIED_BYTES = 512;
    localparam int MAX_QUALIFIED_RATIO = 8;
    localparam int IN_BITS  = IN_BYTES * 8;
    localparam int OUT_BITS = OUT_BYTES * 8;
    localparam int WIDTH_RATIO = (IN_BYTES < OUT_BYTES)
                               ? (OUT_BYTES / IN_BYTES)
                               : (IN_BYTES / OUT_BYTES);

    initial begin
        if ((IN_BYTES < MIN_QUALIFIED_BYTES)
         || (IN_BYTES > MAX_QUALIFIED_BYTES)
         || (OUT_BYTES < MIN_QUALIFIED_BYTES)
         || (OUT_BYTES > MAX_QUALIFIED_BYTES)) begin
            $fatal(1, "%s: gearbox widths must be in [%0d, %0d] bytes; in=%0d out=%0d",
                   INSTANCE_ID, MIN_QUALIFIED_BYTES, MAX_QUALIFIED_BYTES,
                   IN_BYTES, OUT_BYTES);
        end
        if (((IN_BYTES >= OUT_BYTES) && ((IN_BYTES % OUT_BYTES) != 0))
         || ((OUT_BYTES > IN_BYTES) && ((OUT_BYTES % IN_BYTES) != 0))) begin
            $fatal(1, "%s: gearbox widths must be evenly divisible; in=%0d out=%0d",
                   INSTANCE_ID, IN_BYTES, OUT_BYTES);
        end
        if (!`IS_POW2(IN_BYTES) || !`IS_POW2(OUT_BYTES)) begin
            $fatal(1, "%s: gearbox widths must be powers of two; in=%0d out=%0d",
                   INSTANCE_ID, IN_BYTES, OUT_BYTES);
        end
        if (WIDTH_RATIO > MAX_QUALIFIED_RATIO) begin
            $fatal(1, "%s: gearbox width ratio exceeds %0d:1; in=%0d out=%0d",
                   INSTANCE_ID, MAX_QUALIFIED_RATIO, IN_BYTES, OUT_BYTES);
        end
    end

    if (IN_BYTES == OUT_BYTES) begin : g_same_width
        `UNUSED_VAR ({clk, reset})

        assign in_ready   = out_ready;
        assign out_valid  = in_valid;
        assign out_data   = in_data;
        assign out_byteen = in_byteen;
        assign out_last   = in_last;

    end else if (IN_BYTES < OUT_BYTES) begin : g_narrow_to_wide
        localparam int RATIO   = OUT_BYTES / IN_BYTES;
        localparam int PHASE_W = $clog2(RATIO);

        logic [RATIO-1:0][IN_BITS-1:0] data_r;
        logic [RATIO-1:0][IN_BYTES-1:0] byteen_r;
        logic [PHASE_W-1:0] phase_r;
        logic valid_r;
        logic last_r;

        wire in_fire = in_valid && in_ready;
        wire out_fire = out_valid && out_ready;
        wire completes_word = in_last || (phase_r == PHASE_W'(RATIO - 1));

        assign in_ready   = !valid_r || out_ready;
        assign out_valid  = valid_r;
        assign out_data   = data_r;
        assign out_byteen = byteen_r;
        assign out_last   = last_r;

        for (genvar slice = 0; slice < RATIO; ++slice) begin : g_slice
            always_ff @(posedge clk) begin
                if (in_fire && (phase_r == PHASE_W'(slice))) begin
                    data_r[slice] <= in_data;
                    byteen_r[slice] <= in_byteen;
                end else if (in_fire && (phase_r == '0)) begin
                    byteen_r[slice] <= '0;
                end
            end
        end

        always_ff @(posedge clk) begin
            if (reset) begin
                phase_r <= '0;
                valid_r <= 1'b0;
                last_r <= 1'b0;
            end else begin
                if (out_fire) begin
                    valid_r <= 1'b0;
                    last_r <= 1'b0;
                end

                if (in_fire) begin
                    if (completes_word) begin
                        phase_r <= '0;
                        valid_r <= 1'b1;
                        last_r <= in_last;
                    end else begin
                        phase_r <= phase_r + PHASE_W'(1);
                    end
                end
            end
        end

    end else begin : g_wide_to_narrow
        localparam int RATIO   = IN_BYTES / OUT_BYTES;
        localparam int PHASE_W = $clog2(RATIO);

        wire [RATIO-1:0][OUT_BITS-1:0] data_slices = in_data;
        wire [RATIO-1:0][OUT_BYTES-1:0] byteen_slices = in_byteen;
        logic [PHASE_W-1:0] phase_r;

        wire out_fire = out_valid && out_ready;
        wire final_slice = (phase_r == PHASE_W'(RATIO - 1));

        // Do not copy a wide response beat into another full-width register.
        // The upstream ready/valid contract holds the beat until its final
        // static slice is consumed, at which point in_ready completes it.
        assign in_ready   = out_ready && final_slice;
        assign out_valid  = in_valid;
        assign out_data   = data_slices[phase_r];
        assign out_byteen = byteen_slices[phase_r];
        assign out_last   = in_last && final_slice;

        always_ff @(posedge clk) begin
            if (reset) begin
                phase_r <= '0;
            end else if (out_fire) begin
                if (final_slice) begin
                    phase_r <= '0;
                end else begin
                    phase_r <= phase_r + PHASE_W'(1);
                end
            end
        end
    end

`ifdef DBG_TRACE_GEMM
    always @(posedge clk) begin
        if (!reset && in_valid && in_ready) begin
            `TRACE(3, ("%t: %s gearbox input: byteen=0x%0h last=%0b\n",
                       $time, INSTANCE_ID, in_byteen, in_last))
        end
        if (!reset && out_valid && out_ready) begin
            `TRACE(3, ("%t: %s gearbox output: byteen=0x%0h last=%0b\n",
                       $time, INSTANCE_ID, out_byteen, out_last))
        end
    end
`endif

`ifdef CHIPSCOPE
`ifdef DBG_SCOPE_GEMM
    (* keep = "true", mark_debug = "true" *) wire [5:0] dbg_dma_gearbox = {
        reset, in_valid, in_ready, out_valid, out_ready, out_last
    };
`endif
`endif

endmodule
