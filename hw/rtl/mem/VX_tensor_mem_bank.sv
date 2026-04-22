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
// Arbitrates multiple requestors (DMA, input_read, weight_read, sz_read,
// output_write) into a single-port SRAM via VX_mem_arb.

module VX_tensor_mem_bank import VX_gpu_pkg::*; #(
    parameter `STRING INSTANCE_ID = "",
    parameter SIZE       = 4*1024,   // Bank size in bytes (4KB default)
    parameter DATA_SIZE  = 64,       // Data width in bytes (512-bit = 64 bytes)
    parameter NUM_PORTS  = 5,        // Number of requestors
    parameter TAG_WIDTH  = 8,
    parameter `STRING ARBITER = "R"  // Round-robin arbitration
) (
    input wire clk,
    input wire reset,

    VX_mem_bus_if.slave mem_bus_if [NUM_PORTS]
);

    localparam DATA_WIDTH    = DATA_SIZE * 8;           // 512 bits
    localparam NUM_WORDS     = SIZE / DATA_SIZE;        // Number of SRAM words
    localparam ADDR_WIDTH    = `CLOG2(NUM_WORDS);       // Word address width
    localparam ARB_SEL_BITS  = `ARB_SEL_BITS(NUM_PORTS, 1);
    localparam ARB_TAG_WIDTH = TAG_WIDTH + ARB_SEL_BITS;
    localparam MEM_ADDR_WIDTH = `MEM_ADDR_WIDTH;
    localparam MEM_ADDR_W    = MEM_ADDR_WIDTH - `CLOG2(DATA_SIZE);

    `UNUSED_SPARAM (INSTANCE_ID)

    // ---------------------------------------------------------------
    // Arbiter: NUM_PORTS → 1
    // ---------------------------------------------------------------

    VX_mem_bus_if #(
        .DATA_SIZE  (DATA_SIZE),
        .TAG_WIDTH  (ARB_TAG_WIDTH)
    ) arb_bus_if [1]();

    VX_mem_arb #(
        .NUM_INPUTS  (NUM_PORTS),
        .NUM_OUTPUTS (1),
        .DATA_SIZE   (DATA_SIZE),
        .TAG_WIDTH   (TAG_WIDTH),
        .ARBITER     (ARBITER)
    ) mem_arb (
        .clk        (clk),
        .reset      (reset),
        .bus_in_if  (mem_bus_if),
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

endmodule
