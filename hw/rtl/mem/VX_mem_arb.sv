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

module VX_mem_arb import VX_gpu_pkg::*; #(
    parameter NUM_INPUTS     = 1,
    parameter NUM_OUTPUTS    = 1,
    parameter DATA_SIZE      = 1,
    parameter TAG_WIDTH      = 1,
    parameter TAG_SEL_IDX    = 0,
    parameter REQ_OUT_BUF    = 0,
    parameter RSP_OUT_BUF    = 0,
    parameter `STRING ARBITER = "R",
    parameter MEM_ADDR_WIDTH = `MEM_ADDR_WIDTH,
    parameter ADDR_WIDTH     = (MEM_ADDR_WIDTH-`CLOG2(DATA_SIZE)),
    parameter FLAGS_WIDTH    = MEM_FLAGS_WIDTH
`ifdef GEMM_SRAM_FUSION
    ,parameter bit FUSION_LANE_REQUEST_LINK = 1'b0
`endif
) (
    input wire              clk,
    input wire              reset,

    VX_mem_bus_if.slave     bus_in_if [NUM_INPUTS],
    VX_mem_bus_if.master    bus_out_if [NUM_OUTPUTS]
);
    localparam DATA_WIDTH   = (8 * DATA_SIZE);
    localparam LOG_NUM_REQS = `ARB_SEL_BITS(NUM_INPUTS, NUM_OUTPUTS);
    localparam REQ_DATAW    = 1 + ADDR_WIDTH + DATA_WIDTH + DATA_SIZE + FLAGS_WIDTH + TAG_WIDTH;
    localparam RSP_DATAW    = DATA_WIDTH + TAG_WIDTH;
    localparam SEL_COUNT    = `MIN(NUM_INPUTS, NUM_OUTPUTS);
`ifdef GEMM_SRAM_FUSION
    `VX_STATIC_ASSERT(!FUSION_LANE_REQUEST_LINK || (NUM_INPUTS == 2 && NUM_OUTPUTS == 1
        && DATA_SIZE == 8 && REQ_OUT_BUF == 3 && RSP_OUT_BUF == 3 && ARBITER == "P"
        && TAG_WIDTH == GEMM_LMEM_TAG_WIDTH && TAG_SEL_IDX == GEMM_LMEM_TAG_WIDTH-UUID_WIDTH
        && MEM_ADDR_WIDTH == `MEM_ADDR_WIDTH && FLAGS_WIDTH == MEM_FLAGS_WIDTH
        && `NUM_LSU_LANES == 16 && `LMEM_NUM_PORTS == 16 && `LMEM_NUM_BANKS == 16),
        ("request-only lane link requires C4 CPU/DMA arbiter geometry"))
`endif

    wire [NUM_INPUTS-1:0]                 req_valid_in;
    wire [NUM_INPUTS-1:0][REQ_DATAW-1:0]  req_data_in;
    wire [NUM_INPUTS-1:0]                 req_ready_in;

    wire [NUM_OUTPUTS-1:0]                req_valid_out;
    wire [NUM_OUTPUTS-1:0][REQ_DATAW-1:0] req_data_out;
    wire [SEL_COUNT-1:0][`UP(LOG_NUM_REQS)-1:0] req_sel_out;
    wire [NUM_OUTPUTS-1:0]                req_ready_out;

    for (genvar i = 0; i < NUM_INPUTS; ++i) begin : g_req_data_in
`ifdef GEMM_SRAM_FUSION
        if (FUSION_LANE_REQUEST_LINK && i == 0) begin : g_fusion_lane_request
            wire [REQ_DATAW-1:0] link_data;
            wire link_valid, link_credit, tx_ready, rx_valid;
            assign bus_in_if[i].req_ready = !reset && tx_ready;
            assign req_valid_in[i] = !reset && rx_valid;
            VX_slr_stream_tx #(.INSTANCE_ID("c4-lane-request"), .DATAW(REQ_DATAW), .DEPTH(4)) u_tx (
                .clk(clk), .reset(reset),
                .valid_in(bus_in_if[i].req_valid && !reset), .ready_in(tx_ready),
                .data_in(bus_in_if[i].req_data),
                .link_data(link_data), .link_valid(link_valid), .link_credit(link_credit), .idle_out()
            );
            VX_slr_stream_rx #(.INSTANCE_ID("c4-lane-request"), .DATAW(REQ_DATAW), .DEPTH(4)) u_rx (
                .clk(clk), .reset(reset),
                .link_data(link_data), .link_valid(link_valid), .link_credit(link_credit),
                .valid_out(rx_valid), .ready_out(req_ready_in[i] && !reset),
                .data_out(req_data_in[i])
            );
        end else begin : g_fusion_request_direct
            assign req_valid_in[i] = bus_in_if[i].req_valid
                                  && !(FUSION_LANE_REQUEST_LINK && reset);
            assign req_data_in[i] = bus_in_if[i].req_data;
            assign bus_in_if[i].req_ready = req_ready_in[i]
                                       && !(FUSION_LANE_REQUEST_LINK && reset);
        end
`else
        assign req_valid_in[i] = bus_in_if[i].req_valid;
        assign req_data_in[i]  = bus_in_if[i].req_data;
        assign bus_in_if[i].req_ready = req_ready_in[i];
`endif
    end

    VX_stream_arb #(
        .NUM_INPUTS  (NUM_INPUTS),
        .NUM_OUTPUTS (NUM_OUTPUTS),
        .DATAW       (REQ_DATAW),
        .ARBITER     (ARBITER),
        .OUT_BUF     (REQ_OUT_BUF)
    ) req_arb (
        .clk       (clk),
        .reset     (reset),
        .valid_in  (req_valid_in),
        .ready_in  (req_ready_in),
        .data_in   (req_data_in),
        .data_out  (req_data_out),
        .sel_out   (req_sel_out),
        .valid_out (req_valid_out),
        .ready_out (req_ready_out)
    );

    for (genvar i = 0; i < NUM_OUTPUTS; ++i) begin : g_bus_out_if
        wire [TAG_WIDTH-1:0] req_tag_out;
`ifdef GEMM_SRAM_FUSION
        assign bus_out_if[i].req_valid = req_valid_out[i]
                                      && !(FUSION_LANE_REQUEST_LINK && reset);
`else
        assign bus_out_if[i].req_valid = req_valid_out[i];
`endif
        assign {
            bus_out_if[i].req_data.rw,
            bus_out_if[i].req_data.addr,
            bus_out_if[i].req_data.data,
            bus_out_if[i].req_data.byteen,
            bus_out_if[i].req_data.flags,
            req_tag_out
        } = req_data_out[i];
`ifdef GEMM_SRAM_FUSION
        assign req_ready_out[i] = bus_out_if[i].req_ready
                               && !(FUSION_LANE_REQUEST_LINK && reset);
`else
        assign req_ready_out[i] = bus_out_if[i].req_ready;
`endif
        
        if (NUM_INPUTS > NUM_OUTPUTS) begin : g_req_tag_sel_out
            VX_bits_insert #(
            .N   (TAG_WIDTH),
            .S   (LOG_NUM_REQS),
            .POS (TAG_SEL_IDX)
            ) bits_insert (
                .data_in  (req_tag_out),
                .ins_in   (req_sel_out[i]),
                .data_out (bus_out_if[i].req_data.tag)
            );
        end else begin : g_req_tag_out
            `UNUSED_VAR (req_sel_out)
            assign bus_out_if[i].req_data.tag = req_tag_out;
        end
    end

`ifdef GEMM_SRAM_FUSION
`ifndef SYNTHESIS
    if (FUSION_LANE_REQUEST_LINK) begin : g_fusion_request_contract
        // VX_core initializes DMA lanes1..15 inactive in C4 fusion mode.
        // This narrow link is enabled only for lanes8..15, never DMA lane0.
        always @(posedge clk) begin
            if (!reset)
                assert (bus_in_if[1].req_valid === 1'b0)
                    else $fatal(1, "enabled CPU lane link requires inactive DMA input1");
            if (reset)
                assert (!(|req_valid_in) && !(|req_ready_out) && !bus_out_if[0].req_valid)
                    else $fatal(1, "lane request accepted/delivered during core reset");
        end
    end
`endif
`endif
    ///////////////////////////////////////////////////////////////////////////

    wire [NUM_INPUTS-1:0]                 rsp_valid_out;
    wire [NUM_INPUTS-1:0][RSP_DATAW-1:0]  rsp_data_out;
    wire [NUM_INPUTS-1:0]                 rsp_ready_out;

    wire [NUM_OUTPUTS-1:0]                rsp_valid_in;
    wire [NUM_OUTPUTS-1:0][RSP_DATAW-1:0] rsp_data_in;
    wire [NUM_OUTPUTS-1:0]                rsp_ready_in;

    if (NUM_INPUTS > NUM_OUTPUTS) begin : g_rsp_select

        wire [NUM_OUTPUTS-1:0][LOG_NUM_REQS-1:0] rsp_sel_in;

        for (genvar i = 0; i < NUM_OUTPUTS; ++i) begin : g_rsp_data_in
            wire [TAG_WIDTH-1:0] rsp_tag_out;
            VX_bits_remove #(
                .N   (TAG_WIDTH + LOG_NUM_REQS),
                .S   (LOG_NUM_REQS),
                .POS (TAG_SEL_IDX)
            ) bits_remove (
                .data_in  (bus_out_if[i].rsp_data.tag),
                .sel_out  (rsp_sel_in[i]),
                .data_out (rsp_tag_out)
            );
            assign rsp_valid_in[i] = bus_out_if[i].rsp_valid;
            assign rsp_data_in[i]  = {bus_out_if[i].rsp_data.data, rsp_tag_out};
            assign bus_out_if[i].rsp_ready = rsp_ready_in[i];
        end

        VX_stream_switch #(
            .NUM_INPUTS  (NUM_OUTPUTS),
            .NUM_OUTPUTS (NUM_INPUTS),
            .DATAW       (RSP_DATAW),
            .OUT_BUF     (RSP_OUT_BUF)
        ) rsp_switch (
            .clk       (clk),
            .reset     (reset),
            .sel_in    (rsp_sel_in),
            .valid_in  (rsp_valid_in),
            .ready_in  (rsp_ready_in),
            .data_in   (rsp_data_in),
            .data_out  (rsp_data_out),
            .valid_out (rsp_valid_out),
            .ready_out (rsp_ready_out)
        );

    end else begin : g_rsp_arb

        for (genvar i = 0; i < NUM_OUTPUTS; ++i) begin : g_rsp_data_in
            assign rsp_valid_in[i] = bus_out_if[i].rsp_valid;
            assign rsp_data_in[i]  = bus_out_if[i].rsp_data;
            assign bus_out_if[i].rsp_ready = rsp_ready_in[i];
        end

        VX_stream_arb #(
            .NUM_INPUTS  (NUM_OUTPUTS),
            .NUM_OUTPUTS (NUM_INPUTS),
            .DATAW       (RSP_DATAW),
            .ARBITER     (ARBITER),
            .OUT_BUF     (RSP_OUT_BUF)
        ) req_arb (
            .clk       (clk),
            .reset     (reset),
            .valid_in  (rsp_valid_in),
            .ready_in  (rsp_ready_in),
            .data_in   (rsp_data_in),
            .data_out  (rsp_data_out),
            .valid_out (rsp_valid_out),
            .ready_out (rsp_ready_out),
            `UNUSED_PIN (sel_out)
        );

    end

    for (genvar i = 0; i < NUM_INPUTS; ++i) begin : g_output
        assign bus_in_if[i].rsp_valid = rsp_valid_out[i];
        assign bus_in_if[i].rsp_data  = rsp_data_out[i];
        assign rsp_ready_out[i] = bus_in_if[i].rsp_ready;
    end

endmodule
