// Copyright © 2019-2023
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

`include "VX_platform.vh"

// Multi-push / single-pop serialiser FIFO.
//
// Pushes up to MAX_PUSH_PER_CYCLE entries per cycle (selected by per-slot
// push_mask, packed in slot index order), pops 1 entry per cycle.
//
// The FIFO is implemented as an array of registers shifted down on pop,
// keeping the head at index 0. New entries are appended after the current
// occupancy.  This avoids needing a multi-port RAM for the wide push side.
//
// Free-slot accounting: `free_count` is the number of empty slots
// available right now.  Use `free_count >= push_count` for backpressure.
//
// Notes:
//   - DEPTH must be >= MAX_PUSH_PER_CYCLE.
//   - data_in[k] is appended in increasing-k order (k=0 first); inactive
//     slots (push_mask[k]=0) are skipped.  Within a single cycle, a partial
//     push is contiguous: e.g. push_mask=8'b0000_0011 pushes data_in[0]
//     then data_in[1].

`TRACING_OFF
module VX_multi_push_fifo #(
    parameter int WIDTH              = 64,
    parameter int DEPTH              = 16,
    parameter int MAX_PUSH_PER_CYCLE = 8,
    parameter int CNT_W              = `CLOG2(DEPTH+1),
    parameter int PUSHCNT_W          = `CLOG2(MAX_PUSH_PER_CYCLE+1)
) (
    input  wire                                       clk,
    input  wire                                       reset,

    // Push side
    input  wire [MAX_PUSH_PER_CYCLE-1:0]              push_mask,
    input  wire [MAX_PUSH_PER_CYCLE-1:0][WIDTH-1:0]   data_in,

    // Pop side
    input  wire                                       pop,
    output wire [WIDTH-1:0]                           data_out,
    output wire                                       empty,

    // Status
    output wire [CNT_W-1:0]                           count,
    output wire [CNT_W-1:0]                           free_count
);

    `VX_STATIC_ASSERT(DEPTH >= MAX_PUSH_PER_CYCLE,
        ("DEPTH must be >= MAX_PUSH_PER_CYCLE"))

    // Registered storage.
    reg  [WIDTH-1:0] mem_q [DEPTH-1:0];
    reg  [CNT_W-1:0] count_q;

    // Compute the number of pushes this cycle = popcount(push_mask).
    wire [PUSHCNT_W-1:0] push_count;
    VX_popcount #(
        .N (MAX_PUSH_PER_CYCLE)
    ) u_pcnt (
        .data_in  (push_mask),
        .data_out (push_count)
    );

    // Pack input data into a contiguous list (compress inactive slots).
    // packed_in[j] = the j-th active push, in increasing slot index.
    logic [WIDTH-1:0]              packed_in [MAX_PUSH_PER_CYCLE-1:0];
    logic [PUSHCNT_W-1:0]          packed_n;

    always_comb begin
        for (int j = 0; j < MAX_PUSH_PER_CYCLE; j++) begin
            packed_in[j] = '0;
        end
        packed_n = '0;
        for (int k = 0; k < MAX_PUSH_PER_CYCLE; k++) begin
            if (push_mask[k]) begin
                packed_in[packed_n] = data_in[k];
                packed_n            = packed_n + PUSHCNT_W'(1);
            end
        end
    end

    // Next-state shift register update.
    logic [WIDTH-1:0] mem_d   [DEPTH-1:0];
    logic [CNT_W-1:0] count_d;
    logic             pop_eff;

    assign empty   = (count_q == '0);
    assign pop_eff = pop & ~empty;

    always_comb begin
        // Default: hold previous values.
        for (int i = 0; i < DEPTH; i++) begin
            mem_d[i] = mem_q[i];
        end
        count_d = count_q;

        // Logical view after pop: if pop_eff, slot 0 leaves, all others
        // shift down by one.
        if (pop_eff) begin
            for (int i = 0; i < DEPTH-1; i++) begin
                mem_d[i] = mem_q[i+1];
            end
            mem_d[DEPTH-1] = '0;
        end

        // Append new pushes after the post-pop occupancy.
        // base = count_q - (pop_eff ? 1 : 0)
        // mem_d[base + j] = packed_in[j] for j in 0..packed_n-1
        for (int j = 0; j < MAX_PUSH_PER_CYCLE; j++) begin
            if (PUSHCNT_W'(j) < packed_n) begin
                logic [CNT_W-1:0] base;
                logic [CNT_W-1:0] idx;
                base = count_q - (pop_eff ? CNT_W'(1) : CNT_W'(0));
                idx  = base + CNT_W'(j);
                if (idx < CNT_W'(DEPTH)) begin
                    mem_d[idx] = packed_in[j];
                end
            end
        end

        count_d = count_q
                + CNT_W'(packed_n)
                - (pop_eff ? CNT_W'(1) : CNT_W'(0));
    end

    always_ff @(posedge clk) begin
        if (reset) begin
            for (int i = 0; i < DEPTH; i++) begin
                mem_q[i] <= '0;
            end
            count_q <= '0;
        end else begin
            for (int i = 0; i < DEPTH; i++) begin
                mem_q[i] <= mem_d[i];
            end
            count_q <= count_d;
        end
    end

    assign data_out   = mem_q[0];
    assign count      = count_q;
    assign free_count = CNT_W'(DEPTH) - count_q;

    `VX_RUNTIME_ASSERT(
        (CNT_W'(packed_n) <= (CNT_W'(DEPTH) - count_q + (pop_eff ? CNT_W'(1) : CNT_W'(0)))),
        ("%t: VX_multi_push_fifo overflow: count=%0d push=%0d pop=%0b",
            $time, count_q, packed_n, pop_eff)
    )

endmodule
`TRACING_ON
