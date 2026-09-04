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

// Fixed 2:1 adapter between one HBM-DMA TMEM port and the two consecutive
// physical TMEM banks owned by that DMA channel.  Unlike VX_mem_bus_split,
// both bank ports receive the same already-bank-local address.  The low/high
// data and byte-enable halves map to lane 0/1 respectively.
module VX_tmem_dma_pair_adapter import VX_gpu_pkg::*; #(
    parameter `STRING INSTANCE_ID = "",
    parameter HBM_DMA_DATA_SIZE = 64,
    parameter DATA_SIZE = 32,
    parameter TAG_WIDTH = 8,
    parameter BANK_TAG_WIDTH = TAG_WIDTH,
    parameter MEM_ADDR_WIDTH = `MEM_ADDR_WIDTH,
    parameter RSP_FIFO_DEPTH = 2
) (
    input wire clk,
    input wire reset,

    VX_mem_bus_if.slave  dma_bus_if,
    VX_mem_bus_if.master bank_bus_if [2]
);
    localparam int NUM_LANES = 2;
    localparam int DATA_WIDTH = DATA_SIZE * 8;
    localparam int DMA_ADDR_WIDTH = MEM_ADDR_WIDTH
                                  - `CLOG2(HBM_DMA_DATA_SIZE);
    localparam int BANK_ADDR_WIDTH = MEM_ADDR_WIDTH - `CLOG2(DATA_SIZE);
    localparam int TAG_PAD = BANK_TAG_WIDTH - TAG_WIDTH;
    localparam int RSP_COUNT_W = $clog2(RSP_FIFO_DEPTH + 1);
    logic [NUM_LANES-1:0] req_sent_r;
    wire [NUM_LANES-1:0] req_fire;
    wire req_all_done;

    for (genvar lane = 0; lane < NUM_LANES; ++lane) begin : g_request
        assign bank_bus_if[lane].req_valid = dma_bus_if.req_valid
                                           && !req_sent_r[lane];
        assign bank_bus_if[lane].req_data.rw = dma_bus_if.req_data.rw;
        // The output interface already selects the physical bank.  Preserve
        // the aggregate 64-byte word address instead of appending a lane bit.
        assign bank_bus_if[lane].req_data.addr
            = BANK_ADDR_WIDTH'(dma_bus_if.req_data.addr);
        assign bank_bus_if[lane].req_data.data
            = dma_bus_if.req_data.data[lane*DATA_WIDTH +: DATA_WIDTH];
        assign bank_bus_if[lane].req_data.byteen
            = dma_bus_if.req_data.byteen[lane*DATA_SIZE +: DATA_SIZE];
        assign bank_bus_if[lane].req_data.flags = dma_bus_if.req_data.flags;
        if (TAG_PAD == 0) begin : g_tag_equal
            assign bank_bus_if[lane].req_data.tag = dma_bus_if.req_data.tag;
        end else begin : g_tag_pad
            assign bank_bus_if[lane].req_data.tag
                = {{TAG_PAD{1'b0}}, dma_bus_if.req_data.tag};
        end
        assign req_fire[lane] = bank_bus_if[lane].req_valid
                              && bank_bus_if[lane].req_ready;
    end

    // req_ready denotes physical acceptance by both banks.  A half accepted
    // in an earlier cycle is suppressed until its partner accepts.
    assign req_all_done = dma_bus_if.req_valid
                       && (&(req_sent_r | req_fire));
    assign dma_bus_if.req_ready = req_all_done;

    always_ff @(posedge clk) begin
        if (reset) begin
            req_sent_r <= '0;
        end else if (req_all_done) begin
            req_sent_r <= '0;
        end else if (dma_bus_if.req_valid) begin
            req_sent_r <= req_sent_r | req_fire;
        end
    end

    logic [RSP_COUNT_W-1:0] rsp_count_r[NUM_LANES];
    logic rsp_read_ptr_r[NUM_LANES];
    logic rsp_write_ptr_r[NUM_LANES];
    logic [DATA_WIDTH-1:0] rsp_data_r[NUM_LANES][RSP_FIFO_DEPTH];
    logic [BANK_TAG_WIDTH-1:0] rsp_tag_r[NUM_LANES][RSP_FIFO_DEPTH];
    wire [NUM_LANES-1:0] rsp_push;
    wire rsp_heads_valid = (rsp_count_r[0] != 0)
                         && (rsp_count_r[1] != 0);
    wire rsp_heads_match = rsp_tag_r[0][rsp_read_ptr_r[0]]
                         == rsp_tag_r[1][rsp_read_ptr_r[1]];
    wire rsp_pop = dma_bus_if.rsp_valid && dma_bus_if.rsp_ready;

    assign dma_bus_if.rsp_valid = rsp_heads_valid && rsp_heads_match;
    assign dma_bus_if.rsp_data.data = {
        rsp_data_r[1][rsp_read_ptr_r[1]],
        rsp_data_r[0][rsp_read_ptr_r[0]]
    };
    assign dma_bus_if.rsp_data.tag
        = rsp_tag_r[0][rsp_read_ptr_r[0]][TAG_WIDTH-1:0];

    for (genvar lane = 0; lane < NUM_LANES; ++lane) begin : g_response
        // A retiring head exposes same-cycle FIFO space, allowing continuous
        // one-response-per-cycle traffic after the two FIFOs are primed.
        assign bank_bus_if[lane].rsp_ready
            = (rsp_count_r[lane] < RSP_COUNT_W'(RSP_FIFO_DEPTH)) || rsp_pop;
        assign rsp_push[lane] = bank_bus_if[lane].rsp_valid
                              && bank_bus_if[lane].rsp_ready;

        always_ff @(posedge clk) begin
            if (reset) begin
                rsp_count_r[lane] <= '0;
                rsp_read_ptr_r[lane] <= 1'b0;
                rsp_write_ptr_r[lane] <= 1'b0;
            end else begin
                if (rsp_push[lane]) begin
                    rsp_data_r[lane][rsp_write_ptr_r[lane]]
                        <= bank_bus_if[lane].rsp_data.data;
                    rsp_tag_r[lane][rsp_write_ptr_r[lane]]
                        <= bank_bus_if[lane].rsp_data.tag;
                    rsp_write_ptr_r[lane] <= ~rsp_write_ptr_r[lane];
                end
                if (rsp_pop)
                    rsp_read_ptr_r[lane] <= ~rsp_read_ptr_r[lane];

                unique case ({rsp_push[lane], rsp_pop})
                    2'b10: rsp_count_r[lane]
                        <= rsp_count_r[lane] + RSP_COUNT_W'(1);
                    2'b01: rsp_count_r[lane]
                        <= rsp_count_r[lane] - RSP_COUNT_W'(1);
                    default:;
                endcase
            end
        end
    end

`ifdef DBG_TRACE_MEM
    always_ff @(posedge clk) begin
        if (!reset) begin
            if (|req_fire) begin
                `TRACE(1, ("%t: %s pair request: accepted=%b addr=0x%0h tag=0x%0h\n",
                    $time, INSTANCE_ID, req_fire, dma_bus_if.req_data.addr,
                    dma_bus_if.req_data.tag))
            end
            if (rsp_pop) begin
                `TRACE(1, ("%t: %s pair response: tag=0x%0h\n",
                    $time, INSTANCE_ID, dma_bus_if.rsp_data.tag))
            end
        end
    end
`endif

`ifndef SYNTHESIS
    logic partial_req_rw_r;
    logic [DMA_ADDR_WIDTH-1:0] partial_req_addr_r;
    logic [HBM_DMA_DATA_SIZE*8-1:0] partial_req_data_r;
    logic [HBM_DMA_DATA_SIZE-1:0] partial_req_byteen_r;
    logic [MEM_FLAGS_WIDTH-1:0] partial_req_flags_r;
    logic [TAG_WIDTH-1:0] partial_req_tag_r;

    always_ff @(posedge clk) begin
        if (reset) begin
            partial_req_rw_r <= 1'b0;
            partial_req_addr_r <= '0;
            partial_req_data_r <= '0;
            partial_req_byteen_r <= '0;
            partial_req_flags_r <= '0;
            partial_req_tag_r <= '0;
        end else begin
            if ((req_sent_r == '0) && (|req_fire) && !req_all_done) begin
                partial_req_rw_r <= dma_bus_if.req_data.rw;
                partial_req_addr_r <= dma_bus_if.req_data.addr;
                partial_req_data_r <= dma_bus_if.req_data.data;
                partial_req_byteen_r <= dma_bus_if.req_data.byteen;
                partial_req_flags_r <= dma_bus_if.req_data.flags;
                partial_req_tag_r <= dma_bus_if.req_data.tag;
            end

            if (req_sent_r != '0) begin
                assert (dma_bus_if.req_valid
                     && (dma_bus_if.req_data.rw == partial_req_rw_r)
                     && (dma_bus_if.req_data.addr == partial_req_addr_r)
                     && (dma_bus_if.req_data.byteen == partial_req_byteen_r)
                     && (dma_bus_if.req_data.flags == partial_req_flags_r)
                     && (dma_bus_if.req_data.tag == partial_req_tag_r)
                     && (!partial_req_rw_r
                      || (dma_bus_if.req_data.data == partial_req_data_r)))
                    else $fatal(1,
                        "%s: aggregate request changed after partial bank acceptance",
                        INSTANCE_ID);
            end
            if (req_all_done) begin
                assert (&(req_sent_r | req_fire))
                    else $fatal(1,
                        "%s: aggregate request completed before both bank handshakes",
                        INSTANCE_ID);
            end
            if (dma_bus_if.req_valid && (req_sent_r == '0)) begin
                assert (bank_bus_if[0].req_valid
                     && bank_bus_if[1].req_valid)
                    else $fatal(1,
                        "%s: aggregate request did not activate both bank lanes",
                        INSTANCE_ID);
                assert ({bank_bus_if[1].req_data.byteen,
                         bank_bus_if[0].req_data.byteen}
                     == dma_bus_if.req_data.byteen)
                    else $fatal(1,
                        "%s: pair request changed lane byte enables",
                        INSTANCE_ID);
            end
            for (int lane = 0; lane < NUM_LANES; ++lane) begin
                assert (rsp_count_r[lane] <= RSP_COUNT_W'(RSP_FIFO_DEPTH))
                    else $fatal(1, "%s: response FIFO %0d overflow",
                                INSTANCE_ID, lane);
            end
            if (bank_bus_if[0].req_valid && bank_bus_if[1].req_valid) begin
                assert (bank_bus_if[0].req_data.addr
                     == bank_bus_if[1].req_data.addr)
                    else $fatal(1,
                        "%s: pair lanes used different bank-local addresses",
                        INSTANCE_ID);
            end
            if (rsp_heads_valid) begin
                assert (rsp_heads_match)
                    else $fatal(1,
                        "%s: pair response tags do not match (low=0x%0h high=0x%0h)",
                        INSTANCE_ID,
                        rsp_tag_r[0][rsp_read_ptr_r[0]],
                        rsp_tag_r[1][rsp_read_ptr_r[1]]);
            end
        end
    end

    for (genvar lane = 0; lane < NUM_LANES; ++lane) begin : g_lane_assert
        always_ff @(posedge clk) begin
            if (!reset && bank_bus_if[lane].req_valid) begin
                assert (bank_bus_if[lane].req_data.addr
                     == BANK_ADDR_WIDTH'(dma_bus_if.req_data.addr))
                    else $fatal(1,
                        "%s: bank lane %0d changed the bank-local address",
                        INSTANCE_ID, lane);
            end
        end
    end
`endif

    `VX_STATIC_ASSERT(HBM_DMA_DATA_SIZE == (2 * DATA_SIZE),
        ("pair adapter requires a 2:1 data-size ratio"));
    `VX_STATIC_ASSERT((DATA_SIZE > 0) && `IS_POW2(DATA_SIZE),
        ("pair adapter DATA_SIZE must be a positive power of two"));
    `VX_STATIC_ASSERT(BANK_TAG_WIDTH >= TAG_WIDTH,
        ("pair adapter bank tag cannot be narrower than the DMA tag"));
    `VX_STATIC_ASSERT(RSP_FIFO_DEPTH == 2,
        ("pair adapter currently requires two-entry response FIFOs"));

endmodule
