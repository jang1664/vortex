// Copyright 2019-2023
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

`include "VX_define.vh"

// Converts one wide TMEM request into a parallel request to an aligned group
// of narrow banks. Only one wide transaction may be outstanding at a time.
module VX_tmem_wide_read_switch import VX_gpu_pkg::*; #(
    parameter `STRING INSTANCE_ID = "",
    parameter NUM_BANKS      = 8,
    parameter DATA_SIZE      = 64,
    parameter WIDE_DATA_SIZE = NUM_BANKS * DATA_SIZE,
    parameter TAG_WIDTH      = 8,
    parameter MEM_ADDR_WIDTH = `MEM_ADDR_WIDTH
) (
    input wire clk,
    input wire reset,

    VX_mem_bus_if.slave  bus_in_if,
    VX_mem_bus_if.master bus_out_if [NUM_BANKS]
);

    localparam BANK_SEL_BITS    = `CLOG2(NUM_BANKS);
    localparam DATA_WIDTH       = DATA_SIZE * 8;
    localparam WIDE_DATA_WIDTH  = WIDE_DATA_SIZE * 8;
    localparam BANKS_PER_BEAT   = WIDE_DATA_SIZE / DATA_SIZE;
    localparam NUM_BANK_GROUPS  = NUM_BANKS / BANKS_PER_BEAT;
    localparam GROUP_SEL_BITS   = (NUM_BANK_GROUPS > 1) ? `CLOG2(NUM_BANK_GROUPS) : 1;
    localparam GROUP_ADDR_SHIFT = (NUM_BANK_GROUPS > 1) ? `CLOG2(NUM_BANK_GROUPS) : 0;
    localparam IN_ADDR_WIDTH    = MEM_ADDR_WIDTH - `CLOG2(WIDE_DATA_SIZE);
    localparam OUT_ADDR_WIDTH   = MEM_ADDR_WIDTH - `CLOG2(DATA_SIZE);
    localparam logic [NUM_BANKS-1:0] BANK_GROUP_MASK =
        {NUM_BANKS{1'b1}} >> (NUM_BANKS - BANKS_PER_BEAT);

    `UNUSED_SPARAM (INSTANCE_ID)
    `UNUSED_PARAM (MEM_ADDR_WIDTH)

    initial begin
        if ((NUM_BANKS < 1) || ((NUM_BANKS & (NUM_BANKS - 1)) != 0))
            $fatal(1, "VX_tmem_wide_read_switch requires power-of-two NUM_BANKS (%0d)", NUM_BANKS);
        if ((WIDE_DATA_SIZE < DATA_SIZE) || ((WIDE_DATA_SIZE % DATA_SIZE) != 0))
            $fatal(1, "VX_tmem_wide_read_switch requires WIDE_DATA_SIZE (%0d) to be a multiple of DATA_SIZE (%0d)",
                   WIDE_DATA_SIZE, DATA_SIZE);
        if ((BANKS_PER_BEAT < 1) || (BANKS_PER_BEAT > 8)
         || ((BANKS_PER_BEAT & (BANKS_PER_BEAT - 1)) != 0))
            $fatal(1, "VX_tmem_wide_read_switch supports 1/2/4/8 banks per beat, got %0d",
                   BANKS_PER_BEAT);
        if ((BANKS_PER_BEAT > NUM_BANKS) || ((NUM_BANKS % BANKS_PER_BEAT) != 0))
            $fatal(1, "VX_tmem_wide_read_switch BANKS_PER_BEAT (%0d) must divide NUM_BANKS (%0d)",
                   BANKS_PER_BEAT, NUM_BANKS);
    end

    typedef struct packed {
        logic [`UP(UUID_WIDTH)-1:0]           uuid;
        logic [TAG_WIDTH-`UP(UUID_WIDTH)-1:0] value;
    } in_tag_t;

    typedef struct packed {
        logic                         rw;
        logic [IN_ADDR_WIDTH-1:0]     addr;
        logic [WIDE_DATA_WIDTH-1:0]   data;
        logic [WIDE_DATA_SIZE-1:0]    byteen;
        logic [MEM_FLAGS_WIDTH-1:0]   flags;
        in_tag_t                      tag;
    } wide_req_data_t;

    logic [NUM_BANKS-1:0]                 req_bank_mask_r;
    logic [NUM_BANKS-1:0]                 req_issued_r;
    logic                                 req_pending_r;
    logic                                 req_is_read_r;
    wide_req_data_t                       req_data_r;

    logic [NUM_BANKS-1:0]                 rsp_seen_r;
    logic [BANKS_PER_BEAT-1:0][DATA_WIDTH-1:0] rsp_data_r;
    logic [TAG_WIDTH-1:0]                 rsp_tag_r;
    logic                                 rsp_active_r;
    logic                                 rsp_valid_r;

    wire [GROUP_SEL_BITS-1:0] incoming_group_sel =
        (NUM_BANK_GROUPS > 1) ? GROUP_SEL_BITS'(bus_in_if.req_data.addr) : '0;
    wire [BANK_SEL_BITS-1:0] incoming_bank_base =
        BANK_SEL_BITS'(incoming_group_sel * BANKS_PER_BEAT);
    wire [NUM_BANKS-1:0] incoming_bank_mask = BANK_GROUP_MASK << incoming_bank_base;

    wire [NUM_BANKS-1:0] req_ready_bank;
    wire [NUM_BANKS-1:0] req_fire_bank;
    wire [NUM_BANKS-1:0] rsp_fire_bank;
    wire [NUM_BANKS-1:0][DATA_WIDTH-1:0] rsp_data_bank;
    wire can_accept = !req_pending_r && !rsp_active_r && !rsp_valid_r;
    wire req_accept = bus_in_if.req_valid && bus_in_if.req_ready;
    wire [NUM_BANKS-1:0] req_issued_next = req_issued_r | req_fire_bank;
    wire req_issue_done = req_pending_r
                       && ((req_issued_next & req_bank_mask_r) == req_bank_mask_r);
    wire [NUM_BANKS-1:0] rsp_seen_next = rsp_seen_r | rsp_fire_bank;
    wire rsp_complete = rsp_active_r
                     && ((rsp_seen_next & req_bank_mask_r) == req_bank_mask_r);

    assign bus_in_if.req_ready = can_accept;

    for (genvar b = 0; b < NUM_BANKS; ++b) begin : g_bank_req
        localparam BANK_LANE = b % BANKS_PER_BEAT;
        localparam logic [BANK_SEL_BITS-1:0] BANK_ID = b;

        assign req_ready_bank[b] = bus_out_if[b].req_ready;
        assign req_fire_bank[b] = bus_out_if[b].req_valid && bus_out_if[b].req_ready;
        assign rsp_fire_bank[b] = bus_out_if[b].rsp_valid && bus_out_if[b].rsp_ready;
        assign rsp_data_bank[b] = bus_out_if[b].rsp_data.data;

        assign bus_out_if[b].req_valid = req_pending_r
                                      && req_bank_mask_r[b]
                                      && !req_issued_r[b];
        assign bus_out_if[b].req_data.rw = req_data_r.rw;
        assign bus_out_if[b].req_data.addr =
            OUT_ADDR_WIDTH'(req_data_r.addr >> GROUP_ADDR_SHIFT);
        assign bus_out_if[b].req_data.data =
            req_data_r.data[BANK_LANE*DATA_WIDTH +: DATA_WIDTH];
        assign bus_out_if[b].req_data.byteen =
            req_data_r.byteen[BANK_LANE*DATA_SIZE +: DATA_SIZE];
        assign bus_out_if[b].req_data.flags = req_data_r.flags;
        assign bus_out_if[b].req_data.tag =
            {BANK_ID, req_data_r.tag.uuid, req_data_r.tag.value};

        assign bus_out_if[b].rsp_ready = rsp_active_r
                                      && req_bank_mask_r[b]
                                      && !rsp_seen_r[b]
                                      && !rsp_valid_r;

    end

    assign bus_in_if.rsp_valid = rsp_valid_r;
    assign bus_in_if.rsp_data.tag = rsp_tag_r;

    for (genvar lane = 0; lane < BANKS_PER_BEAT; ++lane) begin : g_rsp_pack
        assign bus_in_if.rsp_data.data[lane*DATA_WIDTH +: DATA_WIDTH] =
            rsp_data_r[lane];
    end

    always_ff @(posedge clk) begin
        if (reset) begin
            req_bank_mask_r <= '0;
            req_issued_r    <= '0;
            req_pending_r   <= 1'b0;
            req_is_read_r   <= 1'b0;
            req_data_r      <= '0;
            rsp_seen_r      <= '0;
            rsp_data_r      <= '0;
            rsp_tag_r       <= '0;
            rsp_active_r    <= 1'b0;
            rsp_valid_r     <= 1'b0;
        end else begin
            if (req_accept) begin
                req_bank_mask_r <= incoming_bank_mask;
                req_issued_r    <= '0;
                req_pending_r   <= 1'b1;
                req_is_read_r   <= !bus_in_if.req_data.rw;
                req_data_r      <= bus_in_if.req_data;
            end else begin
                req_issued_r <= req_issued_next;
            end

            if (req_issue_done) begin
                req_issued_r  <= '0;
                req_pending_r <= 1'b0;
                rsp_seen_r    <= '0;
                rsp_tag_r     <= {req_data_r.tag.uuid, req_data_r.tag.value};
                rsp_active_r  <= req_is_read_r;
            end

            for (int b = 0; b < NUM_BANKS; ++b) begin
                if (rsp_fire_bank[b]) begin
                    rsp_seen_r[b] <= 1'b1;
                    rsp_data_r[b % BANKS_PER_BEAT] <= rsp_data_bank[b];
                end
            end

            if (rsp_complete) begin
                rsp_seen_r   <= '0;
                rsp_active_r <= 1'b0;
                rsp_valid_r  <= 1'b1;
            end else if (bus_in_if.rsp_valid && bus_in_if.rsp_ready) begin
                rsp_valid_r <= 1'b0;
            end
        end
    end

`ifdef DBG_TRACE_MEM
    always @(posedge clk) begin
        if (req_accept) begin
            `TRACE(1, ("%t: %s wide accept: addr=0x%0h, banks=0x%0h, rw=%0b\n",
                $time, INSTANCE_ID, bus_in_if.req_data.addr,
                incoming_bank_mask, bus_in_if.req_data.rw))
        end
        if (|req_fire_bank) begin
            `TRACE(1, ("%t: %s wide bank_req: fired=0x%0h, ready=0x%0h, issued=0x%0h\n",
                $time, INSTANCE_ID, req_fire_bank, req_ready_bank, req_issued_next))
        end
        if (bus_in_if.rsp_valid && bus_in_if.rsp_ready) begin
            `TRACE(1, ("%t: %s wide rsp: tag=0x%0h\n",
                $time, INSTANCE_ID, bus_in_if.rsp_data.tag))
        end
    end
`endif

endmodule
