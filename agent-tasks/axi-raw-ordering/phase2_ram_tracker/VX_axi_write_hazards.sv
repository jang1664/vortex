// Copyright © 2026
// SPDX-License-Identifier: Apache-2.0

`include "VX_platform.vh"

`TRACING_OFF
// One physical AXI port. Its owning request group holds the read address until
// read_fire and cannot issue a younger write while that read is being checked.
module VX_axi_write_hazards #(
    parameter `STRING INSTANCE_ID = "",
    parameter ADDRW = 28,
    parameter IDW = 8,
    parameter SIZE = 16,
    parameter SLOTW = `LOG2UP(SIZE)
) (
    input wire clk,
    input wire reset,
    input wire write_fire,
    input wire [ADDRW-1:0] write_addr,
    input wire [IDW-1:0] write_id,
    output wire write_ready,
    input wire b_fire,
    input wire [IDW-1:0] b_id,
    input wire read_valid,
    input wire [ADDRW-1:0] read_addr,
    input wire read_fire,
    output wire read_allowed
);
    `VX_STATIC_ASSERT(SIZE > 0, ("write hazard table must have positive size"))
    `UNUSED_PARAM (INSTANCE_ID)

    reg [SIZE-1:0] valid, valid_n;
    reg [IDW-1:0] ids [SIZE];
    reg [SLOTW-1:0] alloc_slot;
    reg retire_found;
    reg [SLOTW-1:0] retire_slot;

    // Allocation advances in circular order without skipping occupied slots.
    // Starting at alloc_slot therefore visits live entries oldest-first, even
    // when B responses across IDs make holes. Same-ID B retires the oldest ID.
    always @(*) begin
        retire_found = 0;
        retire_slot = 0;
        for (integer n = 0; n < SIZE; ++n) begin : g_retire
            integer idx;
            idx = int'(alloc_slot) + n;
            if (idx >= SIZE)
                idx = idx - SIZE;
            if (!retire_found && valid[idx] && ids[idx] == b_id) begin
                retire_found = 1;
                retire_slot = SLOTW'(idx);
            end
        end
        valid_n = valid;
        if (b_fire && retire_found)
            valid_n[retire_slot] = 0;
        if (write_fire)
            valid_n[alloc_slot] = 1;
    end
    assign write_ready = ~valid[alloc_slot];
    always @(posedge clk) begin
        if (reset) begin
            valid <= 0;
            alloc_slot <= 0;
        end else begin
            valid <= valid_n;
            if (write_fire) begin
                ids[alloc_slot] <= write_id;
                alloc_slot <= (alloc_slot == SLOTW'(SIZE-1)) ? SLOTW'(0) : alloc_slot + SLOTW'(1);
            end
        end
    end
    `VX_RUNTIME_ASSERT(~write_fire || write_ready, ("%t: *** AXI write hazard table overflow", $time))
    `VX_RUNTIME_ASSERT(~b_fire || retire_found, ("%t: *** AXI B without outstanding ID", $time))
    `VX_RUNTIME_ASSERT(~write_fire || ~read_valid, ("%t: *** AXI read check overlapped a younger write", $time))

    reg checking, admitted, compare_valid;
    reg [SLOTW-1:0] compare_slot;
    reg [SIZE-1:0] remaining, hazard_matches;
    wire [SIZE-1:0] scan_mask = (checking ? remaining : valid) & valid;
    reg scan_found;
    reg [SLOTW-1:0] scan_slot;
    reg [SIZE-1:0] scan_onehot;
    always @(*) begin
        scan_found = 0;
        scan_slot = 0;
        scan_onehot = 0;
        for (integer s = 0; s < SIZE; ++s) begin
            if (!scan_found && scan_mask[s]) begin
                scan_found = 1;
                scan_slot = SLOTW'(s);
                scan_onehot[s] = 1;
            end
        end
    end
    wire scan_read = read_valid && ~admitted && scan_found;
    wire [ADDRW-1:0] scan_addr;
    VX_dp_ram #(
        .DATAW (ADDRW), .SIZE (SIZE), .OUT_REG (1), .RDW_MODE ("R")
    ) addresses (
        .clk (clk), .reset (reset),
        .read (scan_read), .raddr (scan_slot), .rdata (scan_addr),
        .write (write_fire), .wren (1'b1), .waddr (alloc_slot), .wdata (write_addr)
    );

    reg [SIZE-1:0] hazard_matches_n;
    always @(*) begin
        hazard_matches_n = hazard_matches;
        if (compare_valid && scan_addr == read_addr)
            hazard_matches_n[compare_slot] = 1;
        hazard_matches_n = hazard_matches_n & valid;
    end
    // Empty bypass also terminates a scan early when the final B arrives.
    assign read_allowed = ~(|valid) || admitted;
    always @(posedge clk) begin
        if (reset) begin
            checking <= 0;
            admitted <= 0;
            compare_valid <= 0;
            compare_slot <= 0;
            remaining <= 0;
            hazard_matches <= 0;
        end else if (read_fire || ~read_valid) begin
            checking <= 0;
            admitted <= 0;
            compare_valid <= 0;
            remaining <= 0;
            hazard_matches <= 0;
        end else begin
            checking <= 1;
            remaining <= scan_mask & ~scan_onehot;
            compare_valid <= scan_read;
            if (scan_read)
                compare_slot <= scan_slot;
            hazard_matches <= hazard_matches_n;
            // One active entry per cycle, with a one-cycle synchronous RAM
            // response. Never admit before the last response has been checked.
            if (!scan_found && !(|hazard_matches_n))
                admitted <= 1;
        end
    end
endmodule
`TRACING_ON
