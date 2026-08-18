// Copyright 2019-2023
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

// VX_tmem_switch
//  Address-based 1:N memory bus demux for TMEM bank routing.
//  Routes requests from a single local DMA port to one of NUM_BANKS
//  TMEM banks based on the lower address bits (interleaved addressing).
//  The bank select bits are stored in the tag for response routing.

module VX_tmem_switch import VX_gpu_pkg::*; #(
    parameter `STRING INSTANCE_ID = "",
    parameter NUM_BANKS      = 8,
    parameter DATA_SIZE      = 64,
    parameter TAG_WIDTH      = 8,
    parameter MEM_ADDR_WIDTH = `MEM_ADDR_WIDTH
) (
    input wire clk,
    input wire reset,
    input wire req_urgent_i,
    output wire [NUM_BANKS-1:0] bank_req_urgent_o,

    // Single input from local DMA
    VX_mem_bus_if.slave     bus_in_if,

    // Per-bank output to TMEM banks
    VX_mem_bus_if.master    bus_out_if [NUM_BANKS]
);

    localparam BANK_SEL_BITS  = `CLOG2(NUM_BANKS);
    localparam DATA_WIDTH     = DATA_SIZE * 8;
    localparam ADDR_WIDTH     = MEM_ADDR_WIDTH - `CLOG2(DATA_SIZE);
    // Output tag includes bank_sel bits for response routing
    localparam OUT_TAG_WIDTH  = TAG_WIDTH + BANK_SEL_BITS;

    `UNUSED_SPARAM (INSTANCE_ID)

    // ---------------------------------------------------------------
    // Request path: decode bank_sel, strip bank bits, route to bank
    // ---------------------------------------------------------------

    wire                    req_valid = bus_in_if.req_valid;
    wire [ADDR_WIDTH-1:0]  req_addr  = bus_in_if.req_data.addr;

    // Bank selection from lower address bits (interleaved)
    wire [BANK_SEL_BITS-1:0] bank_sel = req_addr[BANK_SEL_BITS-1:0];

    // Bank-local address: strip the bank select bits
    wire [ADDR_WIDTH-1:0] bank_addr = req_addr >> BANK_SEL_BITS;

    // Demux requests to the selected bank
    for (genvar i = 0; i < NUM_BANKS; ++i) begin : g_req_demux
        assign bus_out_if[i].req_valid       = req_valid && (bank_sel == BANK_SEL_BITS'(i));
        assign bus_out_if[i].req_data.rw     = bus_in_if.req_data.rw;
        assign bus_out_if[i].req_data.addr   = ADDR_WIDTH'(bank_addr);
        assign bus_out_if[i].req_data.data   = bus_in_if.req_data.data;
        assign bus_out_if[i].req_data.byteen = bus_in_if.req_data.byteen;
        assign bus_out_if[i].req_data.flags  = bus_in_if.req_data.flags;
        // Append bank_sel to the tag for response routing
        assign bus_out_if[i].req_data.tag    = OUT_TAG_WIDTH'({bank_sel, bus_in_if.req_data.tag});
        assign bank_req_urgent_o[i] = req_urgent_i
                                    && (bank_sel == BANK_SEL_BITS'(i));
    end

    // Ready from the selected bank — extract into wire array via genvar
    wire [NUM_BANKS-1:0] bank_req_ready;
    for (genvar i = 0; i < NUM_BANKS; ++i) begin : g_req_ready
        assign bank_req_ready[i] = bus_out_if[i].req_ready;
    end
    assign bus_in_if.req_ready = bank_req_ready[bank_sel];

    // ---------------------------------------------------------------
    // Response path: arbitrate responses from all banks back to input
    // ---------------------------------------------------------------
    // Use round-robin arbitration among bank responses.
    // Extract bank_sel from the tag and restore original tag.

    localparam RSP_DATAW = DATA_WIDTH + OUT_TAG_WIDTH;

    wire [NUM_BANKS-1:0]                rsp_valid_in;
    wire [NUM_BANKS-1:0][RSP_DATAW-1:0] rsp_data_in;
    wire [NUM_BANKS-1:0]                rsp_ready_in;

    wire                    rsp_valid_out;
    wire [RSP_DATAW-1:0]   rsp_data_out;
    wire                    rsp_ready_out;

    for (genvar i = 0; i < NUM_BANKS; ++i) begin : g_rsp_in
        assign rsp_valid_in[i] = bus_out_if[i].rsp_valid;
        assign rsp_data_in[i]  = {bus_out_if[i].rsp_data.data, bus_out_if[i].rsp_data.tag};
        assign bus_out_if[i].rsp_ready = rsp_ready_in[i];
    end

    VX_stream_arb #(
        .NUM_INPUTS  (NUM_BANKS),
        .NUM_OUTPUTS (1),
        .DATAW       (RSP_DATAW),
        .ARBITER     ("R"),
        .OUT_BUF     (0)
    ) rsp_arb (
        .clk       (clk),
        .reset     (reset),
        .valid_in  (rsp_valid_in),
        .ready_in  (rsp_ready_in),
        .data_in   (rsp_data_in),
        .data_out  ({rsp_data_out}),
        .valid_out ({rsp_valid_out}),
        .ready_out ({rsp_ready_out}),
        `UNUSED_PIN (sel_out)
    );

    // Unpack the arbitrated response and restore original tag
    wire [DATA_WIDTH-1:0]    rsp_data;
    wire [OUT_TAG_WIDTH-1:0] rsp_tag_full;

    assign {rsp_data, rsp_tag_full} = rsp_data_out;

    // Strip bank_sel bits from tag to restore original TAG_WIDTH
    wire [TAG_WIDTH-1:0]     rsp_tag_orig = rsp_tag_full[TAG_WIDTH-1:0];
    wire [BANK_SEL_BITS-1:0] rsp_bank_sel_unused = rsp_tag_full[OUT_TAG_WIDTH-1:TAG_WIDTH];
    `UNUSED_VAR (rsp_bank_sel_unused)

    assign bus_in_if.rsp_valid     = rsp_valid_out;
    assign bus_in_if.rsp_data.data = rsp_data;
    assign bus_in_if.rsp_data.tag  = rsp_tag_orig;
    assign rsp_ready_out           = bus_in_if.rsp_ready;

`ifdef DBG_TRACE_MEM
    always @(posedge clk) begin
        if (req_valid && bus_in_if.req_ready) begin
            `TRACE(1, ("%t: %s req: bank=%0d, addr=0x%0h, rw=%0b\n",
                $time, INSTANCE_ID, bank_sel, req_addr, bus_in_if.req_data.rw))
        end
        if (bus_in_if.rsp_valid && bus_in_if.rsp_ready) begin
            `TRACE(1, ("%t: %s rsp: tag=0x%0h\n",
                $time, INSTANCE_ID, rsp_tag_orig))
        end
    end
`endif

`ifndef SYNTHESIS
    localparam int REQ_DATA_WIDTH = 1 + ADDR_WIDTH + (DATA_SIZE * 9)
                                  + MEM_FLAGS_WIDTH + TAG_WIDTH;
    logic req_stall_r;
    logic req_stall_urgent_r;
    logic [REQ_DATA_WIDTH-1:0] req_stall_data_r;
    always_ff @(posedge clk) begin
        if (reset) begin
            req_stall_r <= 1'b0;
            req_stall_urgent_r <= 1'b0;
            req_stall_data_r <= '0;
        end else begin
            if (req_stall_r) begin
                assert (bus_in_if.req_valid
                     && (req_urgent_i == req_stall_urgent_r)
                     && (bus_in_if.req_data == req_stall_data_r))
                    else $fatal(1, "%t: %s request data/urgency changed while switch input stalled",
                                $time, INSTANCE_ID);
            end
            req_stall_r <= bus_in_if.req_valid && !bus_in_if.req_ready;
            req_stall_urgent_r <= req_urgent_i;
            req_stall_data_r <= bus_in_if.req_data;
        end
    end
`endif

endmodule
