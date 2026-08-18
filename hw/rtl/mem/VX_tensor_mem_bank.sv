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

`include "VX_define.vh"

// Single tensor memory bank for the GEMM unit's dedicated memory subsystem.
// Arbitrates multiple requestors (DMA, input_read, weight_read, scale_read,
// zero_point_read, output_write) into a single-port SRAM via VX_mem_arb.

module VX_tensor_mem_bank import VX_gpu_pkg::*; #(
    parameter `STRING INSTANCE_ID = "",
    parameter SIZE       = 4*1024,   // Bank size in bytes (4KB default)
    parameter DATA_SIZE  = 64,       // Data width in bytes (512-bit = 64 bytes)
    parameter NUM_PORTS  = 6,        // Number of requestors
    parameter TAG_WIDTH  = 8,
    parameter `STRING ARBITER = "R", // Round-robin arbitration
    parameter bit ENABLE_URGENCY = 1'b0,
    parameter int MAX_CONSECUTIVE_URGENT = 4
) (
    input wire clk,
    input wire reset,

    input wire [NUM_PORTS-1:0] req_urgent_i,

    VX_mem_bus_if.slave mem_bus_if [NUM_PORTS]
);

    localparam DATA_WIDTH    = DATA_SIZE * 8;           // 512 bits
    localparam NUM_WORDS     = SIZE / DATA_SIZE;        // Number of SRAM words
    localparam ADDR_WIDTH    = `CLOG2(NUM_WORDS);       // Word address width
    localparam ARB_SEL_BITS  = `ARB_SEL_BITS(NUM_PORTS, 1);
    localparam ARB_TAG_WIDTH = TAG_WIDTH + ARB_SEL_BITS;
    localparam MEM_ADDR_WIDTH = `MEM_ADDR_WIDTH;
    localparam MEM_ADDR_W    = MEM_ADDR_WIDTH - `CLOG2(DATA_SIZE);
    localparam PORT_PTR_W     = `CLOG2(NUM_PORTS);
    localparam URGENT_COUNT_W = (MAX_CONSECUTIVE_URGENT > 0)
                              ? $clog2(MAX_CONSECUTIVE_URGENT + 1) : 1;

    `UNUSED_SPARAM (INSTANCE_ID)

    initial begin
        if (MAX_CONSECUTIVE_URGENT < 1)
            $fatal(1, "%s: MAX_CONSECUTIVE_URGENT must be positive",
                   INSTANCE_ID);
    end

    // ---------------------------------------------------------------
    // Arbiter: NUM_PORTS → 1
    // ---------------------------------------------------------------

    VX_mem_bus_if #(
        .DATA_SIZE  (DATA_SIZE),
        .TAG_WIDTH  (TAG_WIDTH)
    ) eligible_bus_if [NUM_PORTS]();

    VX_mem_bus_if #(
        .DATA_SIZE  (DATA_SIZE),
        .TAG_WIDTH  (ARB_TAG_WIDTH)
    ) arb_bus_if [1]();

    wire [NUM_PORTS-1:0] request_valid;
    wire [NUM_PORTS-1:0] request_ready;
    localparam int REQ_DATA_WIDTH = 1 + MEM_ADDR_W + (DATA_SIZE * 9)
                                  + MEM_FLAGS_WIDTH + TAG_WIDTH;
    wire [NUM_PORTS-1:0][REQ_DATA_WIDTH-1:0] request_data;
    wire [NUM_PORTS-1:0] urgent_valid;
    wire [NUM_PORTS-1:0] normal_valid;
    logic [NUM_PORTS-1:0] urgent_rr_mask;
    logic [NUM_PORTS-1:0] normal_rr_mask;
    logic [PORT_PTR_W-1:0] urgent_rr_ptr_r;
    logic [PORT_PTR_W-1:0] normal_rr_ptr_r;
    wire any_urgent = |urgent_valid;
    wire any_normal = |normal_valid;
    logic [URGENT_COUNT_W-1:0] consecutive_urgent_r;
    wire force_normal = ENABLE_URGENCY && any_normal && any_urgent
                     && (consecutive_urgent_r
                         >= URGENT_COUNT_W'(MAX_CONSECUTIVE_URGENT));
    wire select_urgent = ENABLE_URGENCY && any_urgent && !force_normal;
    wire [NUM_PORTS-1:0] eligible_mask = ENABLE_URGENCY
        ? (select_urgent ? urgent_rr_mask : normal_rr_mask)
        : request_valid;

    // Keep independent RR cursors for the two priority classes.  A shared
    // cursor can be repeatedly displaced by urgent grants and therefore does
    // not bound progress among multiple persistent normal requesters.
    always_comb begin
        urgent_rr_mask = '0;
        normal_rr_mask = '0;
        begin
            logic urgent_found;
            logic normal_found;
            int urgent_candidate;
            int normal_candidate;
            urgent_found = 1'b0;
            normal_found = 1'b0;
            for (int offset = 0; offset < NUM_PORTS; ++offset) begin
                urgent_candidate = int'(urgent_rr_ptr_r) + offset;
                normal_candidate = int'(normal_rr_ptr_r) + offset;
                if (urgent_candidate >= NUM_PORTS)
                    urgent_candidate = urgent_candidate - NUM_PORTS;
                if (normal_candidate >= NUM_PORTS)
                    normal_candidate = normal_candidate - NUM_PORTS;
                if (!urgent_found && urgent_valid[urgent_candidate]) begin
                    urgent_rr_mask[urgent_candidate] = 1'b1;
                    urgent_found = 1'b1;
                end
                if (!normal_found && normal_valid[normal_candidate]) begin
                    normal_rr_mask[normal_candidate] = 1'b1;
                    normal_found = 1'b1;
                end
            end
        end
    end

    for (genvar p = 0; p < NUM_PORTS; ++p) begin : g_urgency_filter
        assign request_valid[p] = mem_bus_if[p].req_valid;
        assign request_data[p] = mem_bus_if[p].req_data;
        assign urgent_valid[p] = mem_bus_if[p].req_valid && req_urgent_i[p];
        assign normal_valid[p] = mem_bus_if[p].req_valid && !req_urgent_i[p];

        assign eligible_bus_if[p].req_valid = mem_bus_if[p].req_valid
                                            && eligible_mask[p];
        assign eligible_bus_if[p].req_data = mem_bus_if[p].req_data;
        assign mem_bus_if[p].req_ready = eligible_bus_if[p].req_ready
                                       && eligible_mask[p];
        assign request_ready[p] = eligible_bus_if[p].req_ready
                                && eligible_mask[p];

        assign mem_bus_if[p].rsp_valid = eligible_bus_if[p].rsp_valid;
        assign mem_bus_if[p].rsp_data = eligible_bus_if[p].rsp_data;
        assign eligible_bus_if[p].rsp_ready = mem_bus_if[p].rsp_ready;
    end

    VX_mem_arb #(
        .NUM_INPUTS  (NUM_PORTS),
        .NUM_OUTPUTS (1),
        .DATA_SIZE   (DATA_SIZE),
        .TAG_WIDTH   (TAG_WIDTH),
        .ARBITER     (ARBITER)
    ) mem_arb (
        .clk        (clk),
        .reset      (reset),
        .bus_in_if  (eligible_bus_if),
        .bus_out_if (arb_bus_if)
    );

    // ---------------------------------------------------------------
    // Response pipeline state (declared first for forward reference)
    // ---------------------------------------------------------------

    reg                       rsp_valid_r;
    reg [ARB_TAG_WIDTH-1:0]   rsp_tag_r;
    reg                       rsp_rw_r;

    wire rsp_stall = rsp_valid_r && ~arb_bus_if[0].rsp_ready;

    // ---------------------------------------------------------------
    // Request path: arb output → VX_sp_ram
    // ---------------------------------------------------------------

    wire                    req_valid  = arb_bus_if[0].req_valid;
    wire                    req_rw     = arb_bus_if[0].req_data.rw;
    wire [MEM_ADDR_W-1:0]  req_addr   = arb_bus_if[0].req_data.addr;
    wire [DATA_WIDTH-1:0]  req_wdata  = arb_bus_if[0].req_data.data;
    wire [DATA_SIZE-1:0]   req_byteen = arb_bus_if[0].req_data.byteen;

    // Accept a request when we can forward the response (no stall)
    wire req_fire = req_valid && ~rsp_stall;
    wire grant_was_urgent = ENABLE_URGENCY && select_urgent && req_fire;
    wire grant_was_normal = ENABLE_URGENCY && !select_urgent && req_fire;

    always_ff @(posedge clk) begin
        if (reset) begin
            consecutive_urgent_r <= '0;
            urgent_rr_ptr_r <= '0;
            normal_rr_ptr_r <= '0;
        end else if (grant_was_normal || !any_normal) begin
            consecutive_urgent_r <= '0;
        end else if (grant_was_urgent
                  && (consecutive_urgent_r
                      < URGENT_COUNT_W'(MAX_CONSECUTIVE_URGENT))) begin
            consecutive_urgent_r <= consecutive_urgent_r
                                  + URGENT_COUNT_W'(1);
        end
        if (!reset && req_fire && ENABLE_URGENCY) begin
            for (int p = 0; p < NUM_PORTS; ++p) begin
                if (eligible_mask[p]) begin
                    if (select_urgent)
                        urgent_rr_ptr_r <= (p == (NUM_PORTS - 1))
                                         ? '0 : PORT_PTR_W'(p + 1);
                    else
                        normal_rr_ptr_r <= (p == (NUM_PORTS - 1))
                                         ? '0 : PORT_PTR_W'(p + 1);
                end
            end
        end
    end

    // Backpressure: don't accept new requests when response is stalled
    assign arb_bus_if[0].req_ready = ~rsp_stall;

    // SRAM control signals
    wire sram_read  = req_fire && ~req_rw;
    wire sram_write = req_fire &&  req_rw;

    // Truncate the memory address to the local word address
    wire [ADDR_WIDTH-1:0] sram_addr = req_addr[ADDR_WIDTH-1:0];
    `UNUSED_VAR (req_addr)

    wire [DATA_WIDTH-1:0] sram_rdata;

    // Single-port bank: sram_read and sram_write are mutually exclusive
    // (gated by req_rw), so RDW_MODE has no observable effect. We set
    // RDW_MODE="R" and USE_URAM=1 to force URAM mapping — URAM primitives
    // only support read-first / no-change semantics, and 8 banks of
    // 512-word x 512-bit fit into 64 URAM288 (8 per bank). This offloads
    // the 512 RAMB36 that would otherwise be consumed by these banks.
    VX_sp_ram #(
        .DATAW    (DATA_WIDTH),
        .SIZE     (NUM_WORDS),
        .WRENW    (DATA_SIZE),
        .OUT_REG  (1),
        .USE_URAM (1),
        .RDW_MODE ("R")
    ) sp_ram (
        .clk    (clk),
        .reset  (reset),
        .read   (sram_read),
        .write  (sram_write),
        .wren   (req_byteen),
        .addr   (sram_addr),
        .wdata  (req_wdata),
        .rdata  (sram_rdata)
    );

    // ---------------------------------------------------------------
    // Response path: 1-cycle pipeline (data register is inside VX_sp_ram)
    // ---------------------------------------------------------------
    // We accept a request in cycle N and produce the response in cycle N+1.
    // With OUT_REG=1, VX_sp_ram provides the read-data register internally,
    // so only valid/tag/rw are latched externally. When rsp_stall holds,
    // req_fire=0 keeps both the internal addr/data reg and the ram array
    // unchanged, so sram_rdata remains stable across the stall.

    always @(posedge clk) begin
        if (reset) begin
            rsp_valid_r <= 1'b0;
        end else begin
            if (~rsp_stall) begin
                rsp_valid_r <= req_fire;
            end
        end
    end

    always @(posedge clk) begin
        if (~rsp_stall && req_fire) begin
            rsp_tag_r <= arb_bus_if[0].req_data.tag;
            rsp_rw_r  <= req_rw;
        end
    end

    // Response output
    assign arb_bus_if[0].rsp_valid     = rsp_valid_r;
    assign arb_bus_if[0].rsp_data.tag  = rsp_tag_r;
    assign arb_bus_if[0].rsp_data.data = rsp_rw_r ? '0 : sram_rdata;

`ifdef DBG_TRACE_MEM
    always @(posedge clk) begin
        if (req_fire) begin
            if (req_rw) begin
                `TRACE(1, ("%t: %s req: write addr=0x%0h, byteen=0x%0h, data=0x%0h, tag=0x%0h\n",
                    $time, INSTANCE_ID, req_addr, req_byteen, req_wdata, arb_bus_if[0].req_data.tag))
            end else begin
                `TRACE(1, ("%t: %s req: read addr=0x%0h, tag=0x%0h\n",
                    $time, INSTANCE_ID, req_addr, arb_bus_if[0].req_data.tag))
            end
        end
        if (arb_bus_if[0].rsp_valid && arb_bus_if[0].rsp_ready) begin
            `TRACE(1, ("%t: %s rsp: data=0x%0h, tag=0x%0h\n",
                $time, INSTANCE_ID, arb_bus_if[0].rsp_data.data, arb_bus_if[0].rsp_data.tag))
        end
    end
`endif

`ifndef SYNTHESIS
    localparam int NORMAL_GRANT_BOUND = NUM_PORTS
                                      * (MAX_CONSECUTIVE_URGENT + 1);
    localparam int NORMAL_WAIT_W = $clog2(NORMAL_GRANT_BOUND + 1);
    logic [NUM_PORTS-1:0] stalled_req_r;
    logic [NUM_PORTS-1:0] stalled_urgent_r;
    logic [NUM_PORTS-1:0][REQ_DATA_WIDTH-1:0] stalled_req_data_r;
    logic [NUM_PORTS-1:0][NORMAL_WAIT_W-1:0] normal_wait_grants_r;

    always_ff @(posedge clk) begin
        if (reset) begin
            stalled_req_r <= '0;
            stalled_urgent_r <= '0;
            stalled_req_data_r <= '0;
            normal_wait_grants_r <= '0;
        end else begin
            assert ((eligible_mask & ~request_valid) == '0)
                else $fatal(1, "%s: TMEM arbiter selected an invalid request",
                            INSTANCE_ID);
            assert (!force_normal
                 || ((eligible_mask != '0)
                  && ((eligible_mask & ~normal_valid) == '0)))
                else $fatal(1, "%s: TMEM bounded-fairness normal override failed",
                            INSTANCE_ID);
            assert (!ENABLE_URGENCY || $onehot0(eligible_mask))
                else $fatal(1, "%s: TMEM urgency frontend selected multiple ports",
                            INSTANCE_ID);
            for (int p = 0; p < NUM_PORTS; ++p) begin
                if (stalled_req_r[p]) begin
                    assert (request_valid[p]
                         && (req_urgent_i[p] == stalled_urgent_r[p])
                         && (request_data[p] == stalled_req_data_r[p]))
                        else $fatal(1, "%s: TMEM request data/urgency changed under stall on port %0d",
                                    INSTANCE_ID, p);
                end
                stalled_req_r[p] <= request_valid[p] && !request_ready[p];
                stalled_urgent_r[p] <= req_urgent_i[p];
                stalled_req_data_r[p] <= request_data[p];

                if (!ENABLE_URGENCY || !normal_valid[p]
                 || request_ready[p]) begin
                    normal_wait_grants_r[p] <= '0;
                end else if (req_fire) begin
                    normal_wait_grants_r[p] <= normal_wait_grants_r[p]
                                             + NORMAL_WAIT_W'(1);
                    assert (normal_wait_grants_r[p]
                         < NORMAL_WAIT_W'(NORMAL_GRANT_BOUND))
                        else $fatal(1, "%s: normal requester %0d exceeded bounded grant wait",
                                    INSTANCE_ID, p);
                end
            end
        end
    end
`endif

endmodule
