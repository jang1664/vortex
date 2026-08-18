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

// Converts wide TMEM reads into parallel requests to aligned groups of narrow
// banks. Multiple requests may be outstanding, indexed by the read-slot ID in
// the low bits of the original tag value. Responses retire in acceptance order.
module VX_tmem_wide_read_switch import VX_gpu_pkg::*; #(
    parameter `STRING INSTANCE_ID = "",
    parameter NUM_BANKS      = 8,
    parameter DATA_SIZE      = 64,
    parameter WIDE_DATA_SIZE = NUM_BANKS * DATA_SIZE,
    parameter TAG_WIDTH      = 8,
    parameter MEM_ADDR_WIDTH = `MEM_ADDR_WIDTH,
    parameter int OUTSTANDING = 1
) (
    input wire clk,
    input wire reset,
    input wire req_urgent_i,
    output wire [NUM_BANKS-1:0] bank_req_urgent_o,

    VX_mem_bus_if.slave  bus_in_if,
    VX_mem_bus_if.master bus_out_if [NUM_BANKS]
);

    localparam BANK_SEL_BITS    = `CLOG2(NUM_BANKS);
    localparam DATA_WIDTH       = DATA_SIZE * 8;
    localparam BANKS_PER_BEAT   = WIDE_DATA_SIZE / DATA_SIZE;
    localparam NUM_BANK_GROUPS  = NUM_BANKS / BANKS_PER_BEAT;
    localparam GROUP_SEL_BITS   = (NUM_BANK_GROUPS > 1) ? `CLOG2(NUM_BANK_GROUPS) : 1;
    localparam GROUP_ADDR_SHIFT = (NUM_BANK_GROUPS > 1) ? `CLOG2(NUM_BANK_GROUPS) : 0;
    localparam IN_ADDR_WIDTH    = MEM_ADDR_WIDTH - `CLOG2(WIDE_DATA_SIZE);
    localparam OUT_ADDR_WIDTH   = MEM_ADDR_WIDTH - `CLOG2(DATA_SIZE);
    localparam CTX_BITS_CAP     = (OUTSTANDING > 1) ? $clog2(OUTSTANDING) : 0;
    localparam CTX_BITS         = (CTX_BITS_CAP > 0) ? CTX_BITS_CAP : 1;
    localparam FIFO_CNT_W       = $clog2(OUTSTANDING + 1);
    localparam TAG_VALUE_WIDTH  = TAG_WIDTH - `UP(UUID_WIDTH);
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
        if ((OUTSTANDING < 1) || ((OUTSTANDING & (OUTSTANDING - 1)) != 0))
            $fatal(1, "VX_tmem_wide_read_switch requires positive power-of-two OUTSTANDING (%0d)",
                   OUTSTANDING);
        if (TAG_VALUE_WIDTH < CTX_BITS_CAP)
            $fatal(1, "VX_tmem_wide_read_switch tag.value width (%0d) is smaller than context bits (%0d)",
                   TAG_VALUE_WIDTH, CTX_BITS_CAP);
    end

    logic [OUTSTANDING-1:0]                            ctx_valid_r, ctx_valid_n;
    logic [OUTSTANDING-1:0][TAG_WIDTH-1:0]             ctx_tag_r, ctx_tag_n;
    logic [OUTSTANDING-1:0][IN_ADDR_WIDTH-1:0]         ctx_addr_r, ctx_addr_n;
    logic [OUTSTANDING-1:0][WIDE_DATA_SIZE-1:0]        ctx_byteen_r, ctx_byteen_n;
    logic [OUTSTANDING-1:0][MEM_FLAGS_WIDTH-1:0]       ctx_flags_r, ctx_flags_n;
    logic [OUTSTANDING-1:0]                            ctx_urgent_r, ctx_urgent_n;
    logic [OUTSTANDING-1:0][NUM_BANKS-1:0]             ctx_bank_mask_r, ctx_bank_mask_n;
    logic [OUTSTANDING-1:0][NUM_BANKS-1:0]             ctx_issued_r, ctx_issued_n;
    logic [OUTSTANDING-1:0][NUM_BANKS-1:0]             ctx_rsp_seen_r, ctx_rsp_seen_n;
    logic [OUTSTANDING-1:0][BANKS_PER_BEAT-1:0][DATA_WIDTH-1:0]
                                                            ctx_rsp_data_r, ctx_rsp_data_n;

    logic [OUTSTANDING-1:0][CTX_BITS-1:0] issue_fifo_r, issue_fifo_n;
    logic [OUTSTANDING-1:0][CTX_BITS-1:0] order_fifo_r, order_fifo_n;
    logic [CTX_BITS-1:0] issue_rd_ptr_r, issue_rd_ptr_n;
    logic [CTX_BITS-1:0] issue_wr_ptr_r, issue_wr_ptr_n;
    logic [CTX_BITS-1:0] order_rd_ptr_r, order_rd_ptr_n;
    logic [CTX_BITS-1:0] order_wr_ptr_r, order_wr_ptr_n;
    logic [FIFO_CNT_W-1:0] issue_count_r, issue_count_n;
    logic [FIFO_CNT_W-1:0] order_count_r, order_count_n;

    wire [GROUP_SEL_BITS-1:0] incoming_group_sel =
        (NUM_BANK_GROUPS > 1) ? GROUP_SEL_BITS'(bus_in_if.req_data.addr) : '0;
    wire [BANK_SEL_BITS-1:0] incoming_bank_base =
        BANK_SEL_BITS'(incoming_group_sel * BANKS_PER_BEAT);
    wire [NUM_BANKS-1:0] incoming_bank_mask = BANK_GROUP_MASK << incoming_bank_base;
    wire [TAG_WIDTH-1:0] incoming_tag = bus_in_if.req_data.tag;
    wire [CTX_BITS-1:0] incoming_ctx_id =
        (OUTSTANDING > 1) ? CTX_BITS'(bus_in_if.req_data.tag.value) : '0;

    wire issue_head_valid = (issue_count_r != 0);
    wire [CTX_BITS-1:0] issue_head_ctx = issue_fifo_r[issue_rd_ptr_r];
    wire order_head_valid = (order_count_r != 0);
    wire [CTX_BITS-1:0] order_head_ctx = order_fifo_r[order_rd_ptr_r];

    wire [NUM_BANKS-1:0] req_ready_bank;
    wire [NUM_BANKS-1:0] req_valid_bank;
    wire [NUM_BANKS-1:0] req_fire_bank;
    wire [NUM_BANKS-1:0] rsp_valid_bank;
    wire [NUM_BANKS-1:0] rsp_fire_bank;
    wire [NUM_BANKS-1:0][DATA_WIDTH-1:0] rsp_data_bank;
    wire [NUM_BANKS-1:0][BANK_SEL_BITS-1:0] rsp_bank_id;
    wire [NUM_BANKS-1:0][TAG_WIDTH-1:0] rsp_original_tag;
    wire [NUM_BANKS-1:0][CTX_BITS-1:0] rsp_ctx_id;
    wire [NUM_BANKS-1:0] rsp_legal;

    wire [NUM_BANKS-1:0] issue_issued_next =
        ctx_issued_r[issue_head_ctx] | req_fire_bank;
    wire issue_pop = issue_head_valid
                  && ((issue_issued_next & ctx_bank_mask_r[issue_head_ctx])
                   == ctx_bank_mask_r[issue_head_ctx]);

    wire [OUTSTANDING-1:0] ctx_complete;
    for (genvar c = 0; c < OUTSTANDING; ++c) begin : g_ctx_complete
        assign ctx_complete[c] = ctx_valid_r[c]
                              && ((ctx_rsp_seen_r[c] & ctx_bank_mask_r[c])
                               == ctx_bank_mask_r[c]);
    end

    assign bus_in_if.req_ready = (issue_count_r < FIFO_CNT_W'(OUTSTANDING))
                              && (order_count_r < FIFO_CNT_W'(OUTSTANDING));
    wire req_accept = bus_in_if.req_valid && bus_in_if.req_ready;

    assign bus_in_if.rsp_valid = order_head_valid && ctx_complete[order_head_ctx];
    assign bus_in_if.rsp_data.data = ctx_rsp_data_r[order_head_ctx];
    assign bus_in_if.rsp_data.tag = ctx_tag_r[order_head_ctx];
    wire rsp_retire = bus_in_if.rsp_valid && bus_in_if.rsp_ready;

    for (genvar b = 0; b < NUM_BANKS; ++b) begin : g_bank
        localparam BANK_LANE = b % BANKS_PER_BEAT;
        localparam logic [BANK_SEL_BITS-1:0] BANK_ID = b;

        assign req_ready_bank[b] = bus_out_if[b].req_ready;
        assign req_valid_bank[b] = bus_out_if[b].req_valid;
        assign req_fire_bank[b] = bus_out_if[b].req_valid && bus_out_if[b].req_ready;
        assign rsp_valid_bank[b] = bus_out_if[b].rsp_valid;
        assign rsp_data_bank[b] = bus_out_if[b].rsp_data.data;

        assign bus_out_if[b].req_valid = issue_head_valid
                                      && ctx_bank_mask_r[issue_head_ctx][b]
                                      && !ctx_issued_r[issue_head_ctx][b];
        assign bus_out_if[b].req_data.rw = 1'b0;
        assign bus_out_if[b].req_data.addr =
            OUT_ADDR_WIDTH'(ctx_addr_r[issue_head_ctx]) >> GROUP_ADDR_SHIFT;
        assign bus_out_if[b].req_data.data = '0;
        assign bus_out_if[b].req_data.byteen =
            ctx_byteen_r[issue_head_ctx][BANK_LANE*DATA_SIZE +: DATA_SIZE];
        assign bus_out_if[b].req_data.flags = ctx_flags_r[issue_head_ctx];
        assign bus_out_if[b].req_data.tag = {BANK_ID, ctx_tag_r[issue_head_ctx]};
        assign bank_req_urgent_o[b] = issue_head_valid
                                    && ctx_urgent_r[issue_head_ctx]
                                    && ctx_bank_mask_r[issue_head_ctx][b]
                                    && !ctx_issued_r[issue_head_ctx][b];

        assign rsp_bank_id[b] =
            bus_out_if[b].rsp_data.tag[TAG_WIDTH +: BANK_SEL_BITS];
        assign rsp_original_tag[b] = bus_out_if[b].rsp_data.tag[TAG_WIDTH-1:0];
        assign rsp_ctx_id[b] =
            (OUTSTANDING > 1) ? CTX_BITS'(rsp_original_tag[b]) : '0;
        assign rsp_legal[b] = (rsp_bank_id[b] == BANK_ID)
                           && ctx_valid_r[rsp_ctx_id[b]]
                           && (ctx_tag_r[rsp_ctx_id[b]] == rsp_original_tag[b])
                           && ctx_bank_mask_r[rsp_ctx_id[b]][b]
                           && ctx_issued_r[rsp_ctx_id[b]][b]
                           && !ctx_rsp_seen_r[rsp_ctx_id[b]][b];
        assign bus_out_if[b].rsp_ready = rsp_legal[b];
        assign rsp_fire_bank[b] = bus_out_if[b].rsp_valid
                                && bus_out_if[b].rsp_ready;
    end

    function automatic logic [CTX_BITS-1:0] next_fifo_ptr(
        input logic [CTX_BITS-1:0] ptr
    );
        begin
            if ((OUTSTANDING == 1) || (ptr == CTX_BITS'(OUTSTANDING - 1)))
                next_fifo_ptr = '0;
            else
                next_fifo_ptr = ptr + CTX_BITS'(1);
        end
    endfunction

    always_comb begin
        ctx_valid_n = ctx_valid_r;
        ctx_tag_n = ctx_tag_r;
        ctx_addr_n = ctx_addr_r;
        ctx_byteen_n = ctx_byteen_r;
        ctx_flags_n = ctx_flags_r;
        ctx_urgent_n = ctx_urgent_r;
        ctx_bank_mask_n = ctx_bank_mask_r;
        ctx_issued_n = ctx_issued_r;
        ctx_rsp_seen_n = ctx_rsp_seen_r;
        ctx_rsp_data_n = ctx_rsp_data_r;

        issue_fifo_n = issue_fifo_r;
        issue_rd_ptr_n = issue_rd_ptr_r;
        issue_wr_ptr_n = issue_wr_ptr_r;
        issue_count_n = issue_count_r;
        order_fifo_n = order_fifo_r;
        order_rd_ptr_n = order_rd_ptr_r;
        order_wr_ptr_n = order_wr_ptr_r;
        order_count_n = order_count_r;

        if (issue_head_valid)
            ctx_issued_n[issue_head_ctx] = issue_issued_next;

        if (issue_pop)
            issue_rd_ptr_n = next_fifo_ptr(issue_rd_ptr_r);

        for (int b = 0; b < NUM_BANKS; ++b) begin
            if (rsp_fire_bank[b]) begin
                ctx_rsp_seen_n[rsp_ctx_id[b]][b] = 1'b1;
                ctx_rsp_data_n[rsp_ctx_id[b]][b % BANKS_PER_BEAT] =
                    rsp_data_bank[b];
            end
        end

        if (rsp_retire) begin
            ctx_valid_n[order_head_ctx] = 1'b0;
            ctx_tag_n[order_head_ctx] = '0;
            ctx_addr_n[order_head_ctx] = '0;
            ctx_byteen_n[order_head_ctx] = '0;
            ctx_flags_n[order_head_ctx] = '0;
            ctx_urgent_n[order_head_ctx] = 1'b0;
            ctx_bank_mask_n[order_head_ctx] = '0;
            ctx_issued_n[order_head_ctx] = '0;
            ctx_rsp_seen_n[order_head_ctx] = '0;
            ctx_rsp_data_n[order_head_ctx] = '0;
            order_rd_ptr_n = next_fifo_ptr(order_rd_ptr_r);
        end

        if (req_accept) begin
            ctx_valid_n[incoming_ctx_id] = 1'b1;
            ctx_tag_n[incoming_ctx_id] = incoming_tag;
            ctx_addr_n[incoming_ctx_id] = bus_in_if.req_data.addr;
            ctx_byteen_n[incoming_ctx_id] = bus_in_if.req_data.byteen;
            ctx_flags_n[incoming_ctx_id] = bus_in_if.req_data.flags;
            ctx_urgent_n[incoming_ctx_id] = req_urgent_i;
            ctx_bank_mask_n[incoming_ctx_id] = incoming_bank_mask;
            ctx_issued_n[incoming_ctx_id] = '0;
            ctx_rsp_seen_n[incoming_ctx_id] = '0;
            ctx_rsp_data_n[incoming_ctx_id] = '0;

            issue_fifo_n[issue_wr_ptr_r] = incoming_ctx_id;
            issue_wr_ptr_n = next_fifo_ptr(issue_wr_ptr_r);
            order_fifo_n[order_wr_ptr_r] = incoming_ctx_id;
            order_wr_ptr_n = next_fifo_ptr(order_wr_ptr_r);
        end

        unique case ({req_accept, issue_pop})
            2'b10: issue_count_n = issue_count_r + FIFO_CNT_W'(1);
            2'b01: issue_count_n = issue_count_r - FIFO_CNT_W'(1);
            default:;
        endcase

        unique case ({req_accept, rsp_retire})
            2'b10: order_count_n = order_count_r + FIFO_CNT_W'(1);
            2'b01: order_count_n = order_count_r - FIFO_CNT_W'(1);
            default:;
        endcase
    end

    always_ff @(posedge clk) begin
        if (reset) begin
            ctx_valid_r <= '0;
            ctx_tag_r <= '0;
            ctx_addr_r <= '0;
            ctx_byteen_r <= '0;
            ctx_flags_r <= '0;
            ctx_urgent_r <= '0;
            ctx_bank_mask_r <= '0;
            ctx_issued_r <= '0;
            ctx_rsp_seen_r <= '0;
            ctx_rsp_data_r <= '0;
            issue_fifo_r <= '0;
            issue_rd_ptr_r <= '0;
            issue_wr_ptr_r <= '0;
            issue_count_r <= '0;
            order_fifo_r <= '0;
            order_rd_ptr_r <= '0;
            order_wr_ptr_r <= '0;
            order_count_r <= '0;
        end else begin
            ctx_valid_r <= ctx_valid_n;
            ctx_tag_r <= ctx_tag_n;
            ctx_addr_r <= ctx_addr_n;
            ctx_byteen_r <= ctx_byteen_n;
            ctx_flags_r <= ctx_flags_n;
            ctx_urgent_r <= ctx_urgent_n;
            ctx_bank_mask_r <= ctx_bank_mask_n;
            ctx_issued_r <= ctx_issued_n;
            ctx_rsp_seen_r <= ctx_rsp_seen_n;
            ctx_rsp_data_r <= ctx_rsp_data_n;
            issue_fifo_r <= issue_fifo_n;
            issue_rd_ptr_r <= issue_rd_ptr_n;
            issue_wr_ptr_r <= issue_wr_ptr_n;
            issue_count_r <= issue_count_n;
            order_fifo_r <= order_fifo_n;
            order_rd_ptr_r <= order_rd_ptr_n;
            order_wr_ptr_r <= order_wr_ptr_n;
            order_count_r <= order_count_n;
        end
    end

`ifndef SYNTHESIS
    localparam int IN_REQ_DATA_WIDTH = 1 + IN_ADDR_WIDTH
                                     + (WIDE_DATA_SIZE * 9)
                                     + MEM_FLAGS_WIDTH + TAG_WIDTH;
    logic input_stall_r;
    logic input_stall_urgent_r;
    logic [IN_REQ_DATA_WIDTH-1:0] input_stall_data_r;

    always_ff @(posedge clk) begin
        if (reset) begin
            input_stall_r <= 1'b0;
            input_stall_urgent_r <= 1'b0;
            input_stall_data_r <= '0;
        end else begin
            if (input_stall_r) begin
                assert (bus_in_if.req_valid
                     && (req_urgent_i == input_stall_urgent_r)
                     && (bus_in_if.req_data == input_stall_data_r))
                    else $fatal(1, "%t: %s wide request data/urgency changed under input stall",
                                $time, INSTANCE_ID);
            end
            input_stall_r <= bus_in_if.req_valid && !bus_in_if.req_ready;
            input_stall_urgent_r <= req_urgent_i;
            input_stall_data_r <= bus_in_if.req_data;
        end
    end

    always @(posedge clk) begin
        if (!reset) begin
            assert (issue_count_r <= FIFO_CNT_W'(OUTSTANDING))
                else $fatal(1, "%t: %s issue FIFO overflow", $time, INSTANCE_ID);
            assert (order_count_r <= FIFO_CNT_W'(OUTSTANDING))
                else $fatal(1, "%t: %s order FIFO overflow", $time, INSTANCE_ID);
            assert (!(issue_pop && (issue_count_r == 0)))
                else $fatal(1, "%t: %s issue FIFO underflow", $time, INSTANCE_ID);
            assert (!(rsp_retire && (order_count_r == 0)))
                else $fatal(1, "%t: %s order FIFO underflow", $time, INSTANCE_ID);

            if (req_accept) begin
                assert (!bus_in_if.req_data.rw)
                    else $fatal(1, "%t: %s wide switch received a write request", $time, INSTANCE_ID);
                assert (!ctx_valid_r[incoming_ctx_id])
                    else $fatal(1, "%t: %s duplicate live context allocation: ctx=%0d tag=0x%0h",
                                $time, INSTANCE_ID, incoming_ctx_id, incoming_tag);
                assert (issue_count_r < FIFO_CNT_W'(OUTSTANDING))
                    else $fatal(1, "%t: %s issue FIFO push while full", $time, INSTANCE_ID);
                assert (order_count_r < FIFO_CNT_W'(OUTSTANDING))
                    else $fatal(1, "%t: %s order FIFO push while full", $time, INSTANCE_ID);
            end

            if (issue_head_valid) begin
                assert (ctx_valid_r[issue_head_ctx])
                    else $fatal(1, "%t: %s issue FIFO references free context %0d",
                                $time, INSTANCE_ID, issue_head_ctx);
                assert ((bank_req_urgent_o & req_valid_bank)
                     == (req_valid_bank
                       & {NUM_BANKS{ctx_urgent_r[issue_head_ctx]}}))
                    else $fatal(1, "%t: %s Weight context priority split across bank lanes",
                                $time, INSTANCE_ID);
                for (int b = 0; b < NUM_BANKS; ++b) begin
                    if (req_fire_bank[b]) begin
                        assert (ctx_bank_mask_r[issue_head_ctx][b])
                            else $fatal(1, "%t: %s request issued to non-target bank %0d",
                                        $time, INSTANCE_ID, b);
                        assert (!ctx_issued_r[issue_head_ctx][b])
                            else $fatal(1, "%t: %s duplicate bank request: ctx=%0d bank=%0d",
                                        $time, INSTANCE_ID, issue_head_ctx, b);
                    end
                end
            end

            if (order_head_valid) begin
                assert (ctx_valid_r[order_head_ctx])
                    else $fatal(1, "%t: %s order FIFO references free context %0d",
                                $time, INSTANCE_ID, order_head_ctx);
            end
            if (rsp_retire) begin
                assert (ctx_complete[order_head_ctx])
                    else $fatal(1, "%t: %s response retired before completion: ctx=%0d",
                                $time, INSTANCE_ID, order_head_ctx);
            end

            for (int b = 0; b < NUM_BANKS; ++b) begin
                if (rsp_valid_bank[b]) begin
                    assert (rsp_bank_id[b] == BANK_SEL_BITS'(b))
                        else $fatal(1, "%t: %s response bank tag mismatch: port=%0d tag_bank=%0d",
                                    $time, INSTANCE_ID, b, rsp_bank_id[b]);
                    assert (ctx_valid_r[rsp_ctx_id[b]])
                        else $fatal(1, "%t: %s response for free context: bank=%0d ctx=%0d",
                                    $time, INSTANCE_ID, b, rsp_ctx_id[b]);
                    if (ctx_valid_r[rsp_ctx_id[b]]) begin
                        assert (ctx_tag_r[rsp_ctx_id[b]] == rsp_original_tag[b])
                            else $fatal(1, "%t: %s response original tag mismatch: bank=%0d ctx=%0d",
                                        $time, INSTANCE_ID, b, rsp_ctx_id[b]);
                        if (ctx_tag_r[rsp_ctx_id[b]] == rsp_original_tag[b]) begin
                            assert (ctx_bank_mask_r[rsp_ctx_id[b]][b])
                                else $fatal(1, "%t: %s response from non-target bank: ctx=%0d bank=%0d",
                                            $time, INSTANCE_ID, rsp_ctx_id[b], b);
                            assert (ctx_issued_r[rsp_ctx_id[b]][b])
                                else $fatal(1, "%t: %s response from unissued bank: ctx=%0d bank=%0d",
                                            $time, INSTANCE_ID, rsp_ctx_id[b], b);
                            assert (!ctx_rsp_seen_r[rsp_ctx_id[b]][b])
                                else $fatal(1, "%t: %s duplicate bank response: ctx=%0d bank=%0d",
                                            $time, INSTANCE_ID, rsp_ctx_id[b], b);
                        end
                    end
                end
            end

            for (int b = 0; b < NUM_BANKS; ++b) begin
                for (int k = b + 1; k < NUM_BANKS; ++k) begin
                    assert (!(rsp_fire_bank[b] && rsp_fire_bank[k]
                           && (rsp_ctx_id[b] == rsp_ctx_id[k])
                           && ((b % BANKS_PER_BEAT) == (k % BANKS_PER_BEAT))))
                        else $fatal(1, "%t: %s simultaneous responses collide: ctx=%0d banks=%0d/%0d",
                                    $time, INSTANCE_ID, rsp_ctx_id[b], b, k);
                end
            end

            for (int c = 0; c < OUTSTANDING; ++c) begin
                if (ctx_valid_r[c] && !ctx_valid_n[c]) begin
                    assert (rsp_retire && (order_head_ctx == CTX_BITS'(c)))
                        else $fatal(1, "%t: %s context cleared without response retirement: ctx=%0d",
                                    $time, INSTANCE_ID, c);
                end
            end
        end
    end
`endif

`ifdef DBG_TRACE_MEM
    always @(posedge clk) begin
        if (req_accept) begin
            `TRACE(1, ("%t: %s wide accept: ctx=%0d addr=0x%0h banks=0x%0h issue_occ=%0d order_occ=%0d\n",
                $time, INSTANCE_ID, incoming_ctx_id, bus_in_if.req_data.addr,
                incoming_bank_mask, issue_count_r, order_count_r))
        end
        if (|req_fire_bank) begin
            `TRACE(1, ("%t: %s wide bank_req: ctx=%0d fired=0x%0h ready=0x%0h issued=0x%0h\n",
                $time, INSTANCE_ID, issue_head_ctx, req_fire_bank,
                req_ready_bank, issue_issued_next))
        end
        if (|rsp_fire_bank) begin
            `TRACE(1, ("%t: %s wide bank_rsp: fired=0x%0h\n",
                $time, INSTANCE_ID, rsp_fire_bank))
        end
        if (rsp_retire) begin
            `TRACE(1, ("%t: %s wide rsp: ctx=%0d tag=0x%0h\n",
                $time, INSTANCE_ID, order_head_ctx, bus_in_if.rsp_data.tag))
        end
    end
`endif

endmodule
