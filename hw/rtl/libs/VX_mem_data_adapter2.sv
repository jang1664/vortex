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

`TRACING_OFF
module VX_mem_data_adapter2 #(
    parameter SRC_DATA_WIDTH = 1,
    parameter SRC_ADDR_WIDTH = 1,
    parameter DST_DATA_WIDTH = 1,
    parameter DST_ADDR_WIDTH = 1,
    parameter SRC_TAG_WIDTH  = 1,
    parameter DST_TAG_WIDTH  = 1,
    // Number of outstanding parent requests tracked when SRC_DATA_WIDTH > DST_DATA_WIDTH.
    parameter OOO_SLOTS      = 8,
    parameter REQ_OUT_BUF    = 0,
    parameter RSP_OUT_BUF    = 0
) (
    input wire                          clk,
    input wire                          reset,

    input wire                          mem_req_valid_in,
    input wire [SRC_ADDR_WIDTH-1:0]     mem_req_addr_in,
    input wire                          mem_req_rw_in,
    input wire [SRC_DATA_WIDTH/8-1:0]   mem_req_byteen_in,
    input wire [SRC_DATA_WIDTH-1:0]     mem_req_data_in,
    input wire [SRC_TAG_WIDTH-1:0]      mem_req_tag_in,
    output wire                         mem_req_ready_in,

    output wire                         mem_rsp_valid_in,
    output wire [SRC_DATA_WIDTH-1:0]    mem_rsp_data_in,
    output wire [SRC_TAG_WIDTH-1:0]     mem_rsp_tag_in,
    input wire                          mem_rsp_ready_in,

    output wire                         mem_req_valid_out,
    output wire [DST_ADDR_WIDTH-1:0]    mem_req_addr_out,
    output wire                         mem_req_rw_out,
    output wire [DST_DATA_WIDTH/8-1:0]  mem_req_byteen_out,
    output wire [DST_DATA_WIDTH-1:0]    mem_req_data_out,
    output wire [DST_TAG_WIDTH-1:0]     mem_req_tag_out,
    input wire                          mem_req_ready_out,

    input wire                          mem_rsp_valid_out,
    input wire [DST_DATA_WIDTH-1:0]     mem_rsp_data_out,
    input wire [DST_TAG_WIDTH-1:0]      mem_rsp_tag_out,
    output wire                         mem_rsp_ready_out
);
    localparam DST_DATA_SIZE = (DST_DATA_WIDTH / 8);
    localparam DST_LDATAW = `CLOG2(DST_DATA_WIDTH);
    localparam SRC_LDATAW = `CLOG2(SRC_DATA_WIDTH);
    localparam D = `ABS(DST_LDATAW - SRC_LDATAW);
    localparam P = 2**D;
    localparam OOO_SLOT_BITS = (OOO_SLOTS > 1) ? `CLOG2(OOO_SLOTS) : 1;

    localparam EXPECTED_TAG_WIDTH = (DST_LDATAW > SRC_LDATAW) ? (SRC_TAG_WIDTH + D)
                                   : (DST_LDATAW < SRC_LDATAW) ? (D + OOO_SLOT_BITS)
                                   : SRC_TAG_WIDTH;

    `STATIC_ASSERT(OOO_SLOTS > 0, ("invalid OOO_SLOTS parameter, current=%0d", OOO_SLOTS))
    `STATIC_ASSERT(DST_TAG_WIDTH >= EXPECTED_TAG_WIDTH, ("invalid DST_TAG_WIDTH parameter, current=%0d, expected=%0d", DST_TAG_WIDTH, EXPECTED_TAG_WIDTH))

    wire                         mem_req_valid_out_w;
    wire [DST_ADDR_WIDTH-1:0]    mem_req_addr_out_w;
    wire                         mem_req_rw_out_w;
    wire [DST_DATA_WIDTH/8-1:0]  mem_req_byteen_out_w;
    wire [DST_DATA_WIDTH-1:0]    mem_req_data_out_w;
    wire [DST_TAG_WIDTH-1:0]     mem_req_tag_out_w;
    wire                         mem_req_ready_out_w;

    wire                         mem_rsp_valid_in_w;
    wire [SRC_DATA_WIDTH-1:0]    mem_rsp_data_in_w;
    wire [SRC_TAG_WIDTH-1:0]     mem_rsp_tag_in_w;
    wire                         mem_rsp_ready_in_w;

    `UNUSED_VAR (mem_req_tag_in)
    `UNUSED_VAR (mem_rsp_tag_out)

    if (DST_LDATAW > SRC_LDATAW) begin : g_wider_dst_data

        `UNUSED_VAR (clk)
        `UNUSED_VAR (reset)

        wire [D-1:0] req_idx = mem_req_addr_in[D-1:0];
        wire [D-1:0] rsp_idx = mem_rsp_tag_out[D-1:0];

        wire [SRC_ADDR_WIDTH-D-1:0] mem_req_addr_in_qual = mem_req_addr_in[SRC_ADDR_WIDTH-1:D];

        wire [P-1:0][SRC_DATA_WIDTH-1:0] mem_rsp_data_out_w = mem_rsp_data_out;

        if (DST_ADDR_WIDTH < (SRC_ADDR_WIDTH - D)) begin : g_mem_req_addr_out_w_src
            `UNUSED_VAR (mem_req_addr_in_qual)
            assign mem_req_addr_out_w = mem_req_addr_in_qual[DST_ADDR_WIDTH-1:0];
        end else if (DST_ADDR_WIDTH > (SRC_ADDR_WIDTH - D)) begin : g_mem_req_addr_out_w_dst
            assign mem_req_addr_out_w = DST_ADDR_WIDTH'(mem_req_addr_in_qual);
        end else begin : g_mem_req_addr_out_w
            assign mem_req_addr_out_w = mem_req_addr_in_qual;
        end

        VX_demux #(
            .DATAW (SRC_DATA_WIDTH/8),
            .N (P)
        ) req_be_demux (
            .sel_in   (req_idx),
            .data_in  (mem_req_byteen_in),
            .data_out (mem_req_byteen_out_w)
        );

        VX_demux #(
            .DATAW (SRC_DATA_WIDTH),
            .N (P)
        ) req_data_demux (
            .sel_in   (req_idx),
            .data_in  (mem_req_data_in),
            .data_out (mem_req_data_out_w)
        );

        assign mem_req_valid_out_w  = mem_req_valid_in;
        assign mem_req_rw_out_w     = mem_req_rw_in;
        assign mem_req_tag_out_w    = DST_TAG_WIDTH'({mem_req_tag_in, req_idx});
        assign mem_req_ready_in     = mem_req_ready_out_w;

        assign mem_rsp_valid_in_w   = mem_rsp_valid_out;
        assign mem_rsp_data_in_w    = mem_rsp_data_out_w[rsp_idx];
        assign mem_rsp_tag_in_w     = SRC_TAG_WIDTH'(mem_rsp_tag_out[DST_TAG_WIDTH-1:D]);
        assign mem_rsp_ready_out    = mem_rsp_ready_in_w;

    end else if (DST_LDATAW < SRC_LDATAW) begin : g_wider_src_data

        localparam TAG_HI_WIDTH = DST_TAG_WIDTH - D;

        reg [D-1:0] req_ctr;
        reg [OOO_SLOT_BITS-1:0] req_slot_r, req_slot_n;
        reg req_slot_valid_r, req_slot_valid_n;

        reg [OOO_SLOTS-1:0] slot_active_r, slot_active_n;
        reg [OOO_SLOTS-1:0][SRC_TAG_WIDTH-1:0] slot_tag_r, slot_tag_n;
        reg [OOO_SLOTS-1:0][P-1:0][DST_DATA_WIDTH-1:0] slot_rsp_frag_r, slot_rsp_frag_n;
        reg [OOO_SLOTS-1:0][P-1:0] slot_rsp_seen_r, slot_rsp_seen_n;

        reg rsp_out_valid_r, rsp_out_valid_n;
        reg [SRC_DATA_WIDTH-1:0] rsp_out_data_r, rsp_out_data_n;
        reg [SRC_TAG_WIDTH-1:0] rsp_out_tag_r, rsp_out_tag_n;

        reg free_slot_valid;
        reg [OOO_SLOT_BITS-1:0] free_slot_id;
        integer i;

        wire mem_req_issue_fire = mem_req_valid_out_w && mem_req_ready_out_w;
        wire mem_rsp_in_fire = mem_rsp_valid_out && mem_rsp_ready_out;
        wire [D-1:0] rsp_frag_idx = mem_rsp_tag_out[D-1:0];
        // Tag encoding when SRC_DATA_WIDTH > DST_DATA_WIDTH:
        //   mem_req_tag_out = {zero-pad, slot_id, frag_idx}
        // slot_id tracks an outstanding parent request, frag_idx identifies split fragment.
        // Any interconnect-inserted routing bits (e.g., VX_mem_arb) are expected to be
        // removed before returning mem_rsp_tag_out to this adapter.
        wire [OOO_SLOT_BITS-1:0] rsp_slot_id = OOO_SLOT_BITS'(mem_rsp_tag_out[D +: OOO_SLOT_BITS]);
        wire need_new_slot = (req_ctr == 0) && !req_slot_valid_r;
        wire [OOO_SLOT_BITS-1:0] req_slot_id = req_slot_valid_r ? req_slot_r : free_slot_id;
        wire req_slot_ready = req_slot_valid_r || free_slot_valid;

        wire [P-1:0][DST_DATA_WIDTH-1:0] mem_req_data_in_w = mem_req_data_in;
        wire [P-1:0][DST_DATA_SIZE-1:0] mem_req_byteen_in_w = mem_req_byteen_in;

        always @(*) begin
            free_slot_valid = 1'b0;
            free_slot_id = '0;
            for (i = 0; i < OOO_SLOTS; ++i) begin
                if (!free_slot_valid && !slot_active_r[i]) begin
                    free_slot_valid = 1'b1;
                    free_slot_id = OOO_SLOT_BITS'(i);
                end
            end
        end

        always @(*) begin
            req_slot_n = req_slot_r;
            req_slot_valid_n = req_slot_valid_r;
            slot_active_n = slot_active_r;
            slot_tag_n = slot_tag_r;
            slot_rsp_frag_n = slot_rsp_frag_r;
            slot_rsp_seen_n = slot_rsp_seen_r;
            rsp_out_valid_n = rsp_out_valid_r;
            rsp_out_data_n = rsp_out_data_r;
            rsp_out_tag_n = rsp_out_tag_r;

            if (rsp_out_valid_r && mem_rsp_ready_in_w) begin
                rsp_out_valid_n = 1'b0;
            end

            if (mem_req_issue_fire && need_new_slot) begin
                req_slot_n = free_slot_id;
                req_slot_valid_n = 1'b1;
                slot_active_n[free_slot_id] = 1'b1;
                slot_tag_n[free_slot_id] = mem_req_tag_in;
                slot_rsp_seen_n[free_slot_id] = '0;
            end

            if (mem_req_issue_fire && (req_ctr == (P-1))) begin
                req_slot_valid_n = 1'b0;
            end

            if (mem_rsp_in_fire) begin
                if (!slot_rsp_seen_n[rsp_slot_id][rsp_frag_idx]) begin
                    slot_rsp_frag_n[rsp_slot_id][rsp_frag_idx] = mem_rsp_data_out;
                    slot_rsp_seen_n[rsp_slot_id][rsp_frag_idx] = 1'b1;
                end

                if (&slot_rsp_seen_n[rsp_slot_id]) begin
                    rsp_out_valid_n = 1'b1;
                    rsp_out_data_n = slot_rsp_frag_n[rsp_slot_id];
                    rsp_out_tag_n = slot_tag_r[rsp_slot_id];
                    slot_rsp_seen_n[rsp_slot_id] = '0;
                    slot_active_n[rsp_slot_id] = 1'b0;
                end
            end
        end

        always @(posedge clk) begin
            if (reset) begin
                req_ctr <= '0;
                req_slot_r <= '0;
                req_slot_valid_r <= 1'b0;
                slot_active_r <= '0;
                slot_tag_r <= '0;
                slot_rsp_frag_r <= '0;
                slot_rsp_seen_r <= '0;
                rsp_out_valid_r <= 1'b0;
                rsp_out_data_r <= '0;
                rsp_out_tag_r <= '0;
            end else begin
                if (mem_req_issue_fire) begin
                    req_ctr <= req_ctr + 1;
                end
                req_slot_r <= req_slot_n;
                req_slot_valid_r <= req_slot_valid_n;
                slot_active_r <= slot_active_n;
                slot_tag_r <= slot_tag_n;
                slot_rsp_frag_r <= slot_rsp_frag_n;
                slot_rsp_seen_r <= slot_rsp_seen_n;
                rsp_out_valid_r <= rsp_out_valid_n;
                rsp_out_data_r <= rsp_out_data_n;
                rsp_out_tag_r <= rsp_out_tag_n;
            end
        end

        `RUNTIME_ASSERT(!mem_rsp_in_fire || slot_active_r[rsp_slot_id],
            ("%t: *** unexpected memory response slot_id=%0d, tag=0x%0h", $time, rsp_slot_id, mem_rsp_tag_out))

        wire [SRC_ADDR_WIDTH+D-1:0] mem_req_addr_in_qual = {mem_req_addr_in, req_ctr};

        if (DST_ADDR_WIDTH < (SRC_ADDR_WIDTH + D)) begin : g_mem_req_addr_out_w_src
            `UNUSED_VAR (mem_req_addr_in_qual)
            assign mem_req_addr_out_w = mem_req_addr_in_qual[DST_ADDR_WIDTH-1:0];
        end else if (DST_ADDR_WIDTH > (SRC_ADDR_WIDTH + D)) begin : g_mem_req_addr_out_w_dst
            assign mem_req_addr_out_w = DST_ADDR_WIDTH'(mem_req_addr_in_qual);
        end else begin : g_mem_req_addr_out_w
            assign mem_req_addr_out_w = mem_req_addr_in_qual;
        end

        assign mem_req_valid_out_w  = mem_req_valid_in && req_slot_ready;
        assign mem_req_rw_out_w     = mem_req_rw_in;
        assign mem_req_byteen_out_w = mem_req_byteen_in_w[req_ctr];
        assign mem_req_data_out_w   = mem_req_data_in_w[req_ctr];
        assign mem_req_tag_out_w    = DST_TAG_WIDTH'({TAG_HI_WIDTH'(req_slot_id), req_ctr});
        assign mem_req_ready_in     = mem_req_ready_out_w && (req_ctr == (P-1));

        assign mem_rsp_valid_in_w   = rsp_out_valid_r;
        assign mem_rsp_data_in_w    = rsp_out_data_r;
        assign mem_rsp_tag_in_w     = rsp_out_tag_r;
        assign mem_rsp_ready_out    = ~rsp_out_valid_r;

    end else begin : g_passthru

        `UNUSED_VAR (clk)
        `UNUSED_VAR (reset)

        if (DST_ADDR_WIDTH < SRC_ADDR_WIDTH) begin : g_mem_req_addr_out_w_src
            `UNUSED_VAR (mem_req_addr_in)
            assign mem_req_addr_out_w = mem_req_addr_in[DST_ADDR_WIDTH-1:0];
        end else if (DST_ADDR_WIDTH > SRC_ADDR_WIDTH) begin : g_mem_req_addr_out_w_dst
            assign mem_req_addr_out_w = DST_ADDR_WIDTH'(mem_req_addr_in);
        end else begin : g_mem_req_addr_out_w
            assign mem_req_addr_out_w = mem_req_addr_in;
        end

        assign mem_req_valid_out_w  = mem_req_valid_in;
        assign mem_req_rw_out_w     = mem_req_rw_in;
        assign mem_req_byteen_out_w = mem_req_byteen_in;
        assign mem_req_data_out_w   = mem_req_data_in;
        assign mem_req_tag_out_w    = DST_TAG_WIDTH'(mem_req_tag_in);
        assign mem_req_ready_in     = mem_req_ready_out_w;

        assign mem_rsp_valid_in_w   = mem_rsp_valid_out;
        assign mem_rsp_data_in_w    = mem_rsp_data_out;
        assign mem_rsp_tag_in_w     = SRC_TAG_WIDTH'(mem_rsp_tag_out);
        assign mem_rsp_ready_out    = mem_rsp_ready_in_w;

    end

    VX_elastic_buffer #(
        .DATAW    (1 + DST_DATA_SIZE + DST_ADDR_WIDTH + DST_DATA_WIDTH + DST_TAG_WIDTH),
        .SIZE     (`TO_OUT_BUF_SIZE(REQ_OUT_BUF)),
        .OUT_REG  (`TO_OUT_BUF_REG(REQ_OUT_BUF))
    ) req_out_buf (
        .clk       (clk),
        .reset     (reset),
        .valid_in  (mem_req_valid_out_w),
        .ready_in  (mem_req_ready_out_w),
        .data_in   ({mem_req_rw_out_w, mem_req_byteen_out_w, mem_req_addr_out_w, mem_req_data_out_w, mem_req_tag_out_w}),
        .data_out  ({mem_req_rw_out,   mem_req_byteen_out,   mem_req_addr_out,   mem_req_data_out,   mem_req_tag_out}),
        .valid_out (mem_req_valid_out),
        .ready_out (mem_req_ready_out)
    );

    VX_elastic_buffer #(
        .DATAW    (SRC_DATA_WIDTH + SRC_TAG_WIDTH),
        .SIZE     (`TO_OUT_BUF_SIZE(RSP_OUT_BUF)),
        .OUT_REG  (`TO_OUT_BUF_REG(RSP_OUT_BUF))
    ) rsp_in_buf (
        .clk       (clk),
        .reset     (reset),
        .valid_in  (mem_rsp_valid_in_w),
        .ready_in  (mem_rsp_ready_in_w),
        .data_in   ({mem_rsp_data_in_w, mem_rsp_tag_in_w}),
        .data_out  ({mem_rsp_data_in,   mem_rsp_tag_in}),
        .valid_out (mem_rsp_valid_in),
        .ready_out (mem_rsp_ready_in)
    );

endmodule
`TRACING_ON
