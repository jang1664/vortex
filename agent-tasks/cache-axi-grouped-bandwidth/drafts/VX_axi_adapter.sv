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

`TRACING_OFF
module VX_axi_adapter #(
    parameter DATA_WIDTH     = 512,
    parameter ADDR_WIDTH_IN  = 26, // word-addressable
    parameter ADDR_WIDTH_OUT = 32, // byte-addressable
    parameter TAG_WIDTH_IN   = 8,
    parameter TAG_WIDTH_OUT  = 8,
    parameter NUM_PORTS_IN   = 1,
    parameter NUM_BANKS_OUT  = 1, // intermediate transport groups
    parameter NUM_HBM_PORTS  = `NUM_HBM_PORTS,
    parameter INTERLEAVE     = 0,
    parameter TAG_BUFFER_SIZE= 16,
    parameter ARBITER        = "R",
    parameter REQ_OUT_BUF    = 0,
    parameter RSP_OUT_BUF    = 0,
    parameter DATA_SIZE      = DATA_WIDTH/8
 ) (
    input  wire                     clk,
    input  wire                     reset,
    output wire                     busy,

    // Vortex request
    input wire                      mem_req_valid [NUM_PORTS_IN],
    input wire                      mem_req_rw [NUM_PORTS_IN],
    input wire [DATA_SIZE-1:0]      mem_req_byteen [NUM_PORTS_IN],
    input wire [ADDR_WIDTH_IN-1:0]  mem_req_addr [NUM_PORTS_IN],
    input wire [DATA_WIDTH-1:0]     mem_req_data [NUM_PORTS_IN],
    input wire [TAG_WIDTH_IN-1:0]   mem_req_tag [NUM_PORTS_IN],
    output wire                     mem_req_ready [NUM_PORTS_IN],

    // Vortex response
    output wire                     mem_rsp_valid [NUM_PORTS_IN],
    output wire [DATA_WIDTH-1:0]    mem_rsp_data [NUM_PORTS_IN],
    output wire [TAG_WIDTH_IN-1:0]  mem_rsp_tag [NUM_PORTS_IN],
    input wire                      mem_rsp_ready [NUM_PORTS_IN],

    // AXI write request address channel
    output wire                     m_axi_awvalid [NUM_HBM_PORTS],
    input wire                      m_axi_awready [NUM_HBM_PORTS],
    output wire [ADDR_WIDTH_OUT-1:0] m_axi_awaddr [NUM_HBM_PORTS],
    output wire [TAG_WIDTH_OUT-1:0] m_axi_awid [NUM_HBM_PORTS],
    output wire [7:0]               m_axi_awlen [NUM_HBM_PORTS],
    output wire [2:0]               m_axi_awsize [NUM_HBM_PORTS],
    output wire [1:0]               m_axi_awburst [NUM_HBM_PORTS],
    output wire [1:0]               m_axi_awlock [NUM_HBM_PORTS],
    output wire [3:0]               m_axi_awcache [NUM_HBM_PORTS],
    output wire [2:0]               m_axi_awprot [NUM_HBM_PORTS],
    output wire [3:0]               m_axi_awqos [NUM_HBM_PORTS],
    output wire [3:0]               m_axi_awregion [NUM_HBM_PORTS],

    // AXI write request data channel
    output wire                     m_axi_wvalid [NUM_HBM_PORTS],
    input wire                      m_axi_wready [NUM_HBM_PORTS],
    output wire [DATA_WIDTH-1:0]    m_axi_wdata [NUM_HBM_PORTS],
    output wire [DATA_SIZE-1:0]     m_axi_wstrb [NUM_HBM_PORTS],
    output wire                     m_axi_wlast [NUM_HBM_PORTS],

    // AXI write response channel
    input wire                      m_axi_bvalid [NUM_HBM_PORTS],
    output wire                     m_axi_bready [NUM_HBM_PORTS],
    input wire [TAG_WIDTH_OUT-1:0]  m_axi_bid [NUM_HBM_PORTS],
    input wire [1:0]                m_axi_bresp [NUM_HBM_PORTS],

    // AXI read address channel
    output wire                     m_axi_arvalid [NUM_HBM_PORTS],
    input wire                      m_axi_arready [NUM_HBM_PORTS],
    output wire [ADDR_WIDTH_OUT-1:0] m_axi_araddr [NUM_HBM_PORTS],
    output wire [TAG_WIDTH_OUT-1:0] m_axi_arid [NUM_HBM_PORTS],
    output wire [7:0]               m_axi_arlen [NUM_HBM_PORTS],
    output wire [2:0]               m_axi_arsize [NUM_HBM_PORTS],
    output wire [1:0]               m_axi_arburst [NUM_HBM_PORTS],
    output wire [1:0]               m_axi_arlock [NUM_HBM_PORTS],
    output wire [3:0]               m_axi_arcache [NUM_HBM_PORTS],
    output wire [2:0]               m_axi_arprot [NUM_HBM_PORTS],
    output wire [3:0]               m_axi_arqos [NUM_HBM_PORTS],
    output wire [3:0]               m_axi_arregion [NUM_HBM_PORTS],

    // AXI read response channel
    input wire                      m_axi_rvalid [NUM_HBM_PORTS],
    output wire                     m_axi_rready [NUM_HBM_PORTS],
    input wire [DATA_WIDTH-1:0]     m_axi_rdata [NUM_HBM_PORTS],
    input wire                      m_axi_rlast [NUM_HBM_PORTS],
    input wire [TAG_WIDTH_OUT-1:0]  m_axi_rid [NUM_HBM_PORTS],
    input wire [1:0]                m_axi_rresp [NUM_HBM_PORTS]
);
    localparam LOG2_DATA_SIZE = `CLOG2(DATA_SIZE);
    localparam BANK_SEL_BITS  = `CLOG2(NUM_BANKS_OUT);
    localparam BANK_SEL_WIDTH = `UP(BANK_SEL_BITS);
    localparam HBM_SEL_WIDTH = `LOG2UP(NUM_HBM_PORTS);
    localparam PORTS_PER_GROUP = NUM_HBM_PORTS / NUM_BANKS_OUT;
    localparam SLOT_WIDTH = `LOG2UP(PORTS_PER_GROUP);
    localparam NUM_PORTS_IN_BITS = `CLOG2(NUM_PORTS_IN);
    localparam NUM_PORTS_IN_WIDTH = `UP(NUM_PORTS_IN_BITS);
    localparam TAG_BUFFER_ADDRW = `LOG2UP(TAG_BUFFER_SIZE);
    localparam NEEDED_TAG_WIDTH = TAG_WIDTH_IN + NUM_PORTS_IN_BITS;
    localparam READ_TAG_WIDTH = (NEEDED_TAG_WIDTH > TAG_WIDTH_OUT) ? TAG_BUFFER_ADDRW : TAG_WIDTH_IN;
    localparam READ_FULL_TAG_WIDTH = READ_TAG_WIDTH + NUM_PORTS_IN_BITS;
    localparam WRITE_TAG_WIDTH = `MIN(TAG_WIDTH_IN, TAG_WIDTH_OUT);
    localparam DST_TAG_WIDTH  = `MAX(READ_FULL_TAG_WIDTH, WRITE_TAG_WIDTH);
    localparam XBAR_TAG_WIDTH = `MAX(READ_TAG_WIDTH, WRITE_TAG_WIDTH);
    localparam REQ_XBAR_DATAW = 1 + ADDR_WIDTH_IN + HBM_SEL_WIDTH + DATA_SIZE + DATA_WIDTH + XBAR_TAG_WIDTH;
    localparam RSP_XBAR_DATAW = DATA_WIDTH + READ_TAG_WIDTH;

    `VX_STATIC_ASSERT ((ADDR_WIDTH_OUT >= ADDR_WIDTH_IN + LOG2_DATA_SIZE), ("invalid address width"))
    `VX_STATIC_ASSERT ((ADDR_WIDTH_OUT >= `PLATFORM_MEMORY_ADDR_WIDTH), ("output address width cannot represent the physical HBM map"))
    `VX_STATIC_ASSERT ((TAG_WIDTH_OUT >= DST_TAG_WIDTH), ("invalid output tag width: current=%0d, expected=%0d", TAG_WIDTH_OUT, DST_TAG_WIDTH))
    `VX_STATIC_ASSERT ((TAG_BUFFER_SIZE > 0 && (TAG_BUFFER_SIZE & (TAG_BUFFER_SIZE-1)) == 0), ("TAG_BUFFER_SIZE must be a positive power of two"))
    `VX_STATIC_ASSERT ((NUM_PORTS_IN > 0), ("NUM_PORTS_IN must be positive"))
    `VX_STATIC_ASSERT ((NUM_BANKS_OUT > 0 && (NUM_BANKS_OUT & (NUM_BANKS_OUT-1)) == 0), ("NUM_BANKS_OUT must be a positive power of two"))
    `VX_STATIC_ASSERT ((NUM_HBM_PORTS > 0 && (NUM_HBM_PORTS & (NUM_HBM_PORTS-1)) == 0), ("NUM_HBM_PORTS must be a positive power of two"))
    `VX_STATIC_ASSERT ((NUM_BANKS_OUT <= NUM_HBM_PORTS && NUM_HBM_PORTS % NUM_BANKS_OUT == 0), ("invalid transport/HBM geometry"))
    `VX_STATIC_ASSERT ((DATA_WIDTH == DATA_SIZE * 8 && DATA_SIZE == 64 && DATA_SIZE == `MEM_BLOCK_SIZE), ("grouped AXI requires a 64-byte cache line and AXI beat"))
    `VX_STATIC_ASSERT ((`PLATFORM_MEMORY_NUM_BANKS > 0 && (`PLATFORM_MEMORY_NUM_BANKS & (`PLATFORM_MEMORY_NUM_BANKS-1)) == 0), ("physical bank count must be a positive power of two"))
    `VX_STATIC_ASSERT ((NUM_HBM_PORTS <= `PLATFORM_MEMORY_NUM_BANKS && `PLATFORM_MEMORY_NUM_BANKS % NUM_HBM_PORTS == 0), ("invalid physical bank/HBM geometry"))
    `VX_STATIC_ASSERT ((`PLATFORM_MEMORY_INTERLEAVE || NUM_HBM_PORTS == 1), ("grouped HBM routing requires PLATFORM_MEMORY_INTERLEAVE=1"))
    `VX_STATIC_ASSERT ((INTERLEAVE || NUM_HBM_PORTS == 1), ("grouped HBM routing requires INTERLEAVE=1"))

    // Keep the entire software block address. K changes arbitration, never mapping.
    wire [NUM_PORTS_IN-1:0][BANK_SEL_WIDTH-1:0] req_bank_sel;
    wire [NUM_PORTS_IN-1:0][HBM_SEL_WIDTH-1:0] req_hbm_sel;
    for (genvar i = 0; i < NUM_PORTS_IN; ++i) begin : g_bank_sel
        assign req_hbm_sel[i] = HBM_SEL_WIDTH'(mem_req_addr[i] & ADDR_WIDTH_IN'(NUM_HBM_PORTS-1));
        assign req_bank_sel[i] = BANK_SEL_WIDTH'(req_hbm_sel[i] & HBM_SEL_WIDTH'(NUM_BANKS_OUT-1));
    end

    // Tag handling logic

    wire [NUM_PORTS_IN-1:0] mem_rd_req_tag_ready;
    wire [NUM_PORTS_IN-1:0][READ_TAG_WIDTH-1:0] mem_rd_req_tag;
    wire [NUM_PORTS_IN-1:0][READ_TAG_WIDTH-1:0] mem_rd_rsp_tag;

    for (genvar i = 0; i < NUM_PORTS_IN; ++i) begin : g_tag_buf
        if (NEEDED_TAG_WIDTH > TAG_WIDTH_OUT) begin : g_enabled
            wire [TAG_BUFFER_ADDRW-1:0] tbuf_waddr, tbuf_raddr;
            wire tbuf_full;
            VX_index_buffer #(
                .DATAW (TAG_WIDTH_IN),
                .SIZE  (TAG_BUFFER_SIZE)
            ) tag_buf (
                .clk        (clk),
                .reset      (reset),
                .acquire_en (mem_req_valid[i] && ~mem_req_rw[i] && mem_req_ready[i]),
                .write_addr (tbuf_waddr),
                .write_data (mem_req_tag[i]),
                .read_data  (mem_rsp_tag[i]),
                .read_addr  (tbuf_raddr),
                .release_en (mem_rsp_valid[i] && mem_rsp_ready[i]),
                .full       (tbuf_full),
                `UNUSED_PIN (empty)
            );
            assign mem_rd_req_tag_ready[i] = ~tbuf_full;
            assign mem_rd_req_tag[i] = tbuf_waddr;
            assign tbuf_raddr = mem_rd_rsp_tag[i];
        end else begin : g_none
            assign mem_rd_req_tag_ready[i] = 1;
            assign mem_rd_req_tag[i] = mem_req_tag[i];
            assign mem_rsp_tag[i] = mem_rd_rsp_tag[i];
        end
    end

    // AXI request handling

    wire [NUM_PORTS_IN-1:0] req_xbar_valid_in;
    wire [NUM_PORTS_IN-1:0][REQ_XBAR_DATAW-1:0] req_xbar_data_in;
    wire [NUM_PORTS_IN-1:0] req_xbar_ready_in;

    wire [NUM_BANKS_OUT-1:0] req_xbar_valid_out;
    wire [NUM_BANKS_OUT-1:0][REQ_XBAR_DATAW-1:0] req_xbar_data_out;
    wire [NUM_BANKS_OUT-1:0][NUM_PORTS_IN_WIDTH-1:0] req_xbar_sel_out;
    wire [NUM_BANKS_OUT-1:0] req_xbar_ready_out;

    for (genvar i = 0; i < NUM_PORTS_IN; ++i) begin : g_req_xbar_data_in
        wire tag_ready = mem_req_rw[i] || mem_rd_req_tag_ready[i];
        wire [XBAR_TAG_WIDTH-1:0] tag_value = mem_req_rw[i] ? XBAR_TAG_WIDTH'(mem_req_tag[i]) : XBAR_TAG_WIDTH'(mem_rd_req_tag[i]);
        assign req_xbar_valid_in[i] = mem_req_valid[i] && tag_ready;
        assign req_xbar_data_in[i]  = {mem_req_rw[i], mem_req_addr[i], req_hbm_sel[i], mem_req_byteen[i], mem_req_data[i], tag_value};
        assign mem_req_ready[i]  = req_xbar_ready_in[i] && tag_ready;
    end

    VX_stream_xbar #(
        .NUM_INPUTS (NUM_PORTS_IN),
        .NUM_OUTPUTS(NUM_BANKS_OUT),
        .DATAW      (REQ_XBAR_DATAW),
        .ARBITER    (ARBITER),
        .OUT_BUF    ((`TO_OUT_BUF_SIZE(REQ_OUT_BUF) == 0) ? 2 : REQ_OUT_BUF)
    ) req_xbar (
        .clk       (clk),
        .reset     (reset),
        .sel_in    (req_bank_sel),
        .valid_in  (req_xbar_valid_in),
        .data_in   (req_xbar_data_in),
        .ready_in  (req_xbar_ready_in),
        .valid_out (req_xbar_valid_out),
        .data_out  (req_xbar_data_out),
        .ready_out (req_xbar_ready_out),
        .sel_out   (req_xbar_sel_out),
        `UNUSED_PIN (collisions)
    );

    // Each group retains its request until both write channels have completed.
    // The request xbar has storage even when REQ_OUT_BUF=0, preventing a new
    // contender from changing the selected request during a partial AXI write.
    for (genvar g = 0; g < NUM_BANKS_OUT; ++g) begin : g_axi_reqs
        wire xbar_rw_out;
        wire [ADDR_WIDTH_IN-1:0] xbar_addr_out;
        wire [HBM_SEL_WIDTH-1:0] xbar_hbm_out;
        wire [XBAR_TAG_WIDTH-1:0] xbar_tag_out;
        wire [DATA_WIDTH-1:0] xbar_data_out;
        wire [DATA_SIZE-1:0] xbar_byteen_out;
        assign {xbar_rw_out, xbar_addr_out, xbar_hbm_out,
                xbar_byteen_out, xbar_data_out, xbar_tag_out} = req_xbar_data_out[g];

        wire [ADDR_WIDTH_OUT-1:0] software_addr = ADDR_WIDTH_OUT'(xbar_addr_out) << LOG2_DATA_SIZE;
        wire [ADDR_WIDTH_OUT-1:0] remapped_addr;
        VX_mem_remap #(
            .ADDR_W    (ADDR_WIDTH_OUT),
            .NUM_PORTS (NUM_HBM_PORTS)
        ) address_remap (
            .m_address   (software_addr),
            .hbm_address (remapped_addr)
        );

        wire [SLOT_WIDTH-1:0] slot = SLOT_WIDTH'(xbar_hbm_out >> BANK_SEL_BITS);
        wire [PORTS_PER_GROUP-1:0] aw_ready, w_ready, ar_ready;
        wire group_awready, group_wready, group_arready;
        if (PORTS_PER_GROUP == 1) begin : g_direct
            assign group_awready = aw_ready[0];
            assign group_wready = w_ready[0];
            assign group_arready = ar_ready[0];
        end else begin : g_select
            assign group_awready = aw_ready[slot];
            assign group_wready = w_ready[slot];
            assign group_arready = ar_ready[slot];
        end
        wire aw_ack, w_ack, write_ready;
        wire group_awvalid = req_xbar_valid_out[g] && xbar_rw_out && ~aw_ack;
        wire group_wvalid = req_xbar_valid_out[g] && xbar_rw_out && ~w_ack;
        wire group_arvalid = req_xbar_valid_out[g] && ~xbar_rw_out;
        VX_axi_write_ack axi_write_ack (
            .clk (clk), .reset (reset),
            .awvalid (group_awvalid), .awready (group_awready),
            .wvalid (group_wvalid), .wready (group_wready),
            .aw_ack (aw_ack), .w_ack (w_ack), .tx_rdy (write_ready),
            `UNUSED_PIN (tx_ack)
        );
        assign req_xbar_ready_out[g] = xbar_rw_out ? write_ready : group_arready;

        wire [READ_FULL_TAG_WIDTH-1:0] read_id;
        if (NUM_PORTS_IN > 1) begin : g_read_id
            assign read_id = {READ_TAG_WIDTH'(xbar_tag_out), req_xbar_sel_out[g]};
        end else begin : g_single_input
            assign read_id = READ_TAG_WIDTH'(xbar_tag_out);
            `UNUSED_VAR (req_xbar_sel_out[g])
        end
        for (genvar s = 0; s < PORTS_PER_GROUP; ++s) begin : g_hbm
            localparam P = g + s * NUM_BANKS_OUT;
            wire selected = (PORTS_PER_GROUP == 1) || (slot == SLOT_WIDTH'(s));
            assign aw_ready[s] = m_axi_awready[P];
            assign w_ready[s] = m_axi_wready[P];
            assign ar_ready[s] = m_axi_arready[P];
            assign m_axi_awvalid[P] = selected && group_awvalid;
            assign m_axi_awaddr[P] = remapped_addr;
            assign m_axi_awid[P] = TAG_WIDTH_OUT'(xbar_tag_out);
            assign m_axi_awlen[P] = 0;
            assign m_axi_awsize[P] = 3'(LOG2_DATA_SIZE);
            assign m_axi_awburst[P] = 2'b01;
            assign m_axi_awlock[P] = 0;
            assign m_axi_awcache[P] = 0;
            assign m_axi_awprot[P] = 0;
            assign m_axi_awqos[P] = 0;
            assign m_axi_awregion[P] = 0;
            assign m_axi_wvalid[P] = selected && group_wvalid;
            assign m_axi_wdata[P] = xbar_data_out;
            assign m_axi_wstrb[P] = xbar_byteen_out;
            assign m_axi_wlast[P] = 1;
            assign m_axi_arvalid[P] = selected && group_arvalid;
            assign m_axi_araddr[P] = remapped_addr;
            assign m_axi_arid[P] = TAG_WIDTH_OUT'(read_id);
            assign m_axi_arlen[P] = 0;
            assign m_axi_arsize[P] = 3'(LOG2_DATA_SIZE);
            assign m_axi_arburst[P] = 2'b01;
            assign m_axi_arlock[P] = 0;
            assign m_axi_arcache[P] = 0;
            assign m_axi_arprot[P] = 0;
            assign m_axi_arqos[P] = 0;
            assign m_axi_arregion[P] = 0;
        end
    end

    // AXI write response channel (ignore)

    for (genvar i = 0; i < NUM_HBM_PORTS; ++i) begin : g_axi_write_rsp
        `UNUSED_VAR (m_axi_bvalid[i])
        `UNUSED_VAR (m_axi_bid[i])
        `UNUSED_VAR (m_axi_bresp[i])
        assign m_axi_bready[i] = 1'b1;
        `VX_RUNTIME_ASSERT(~m_axi_bvalid[i] || m_axi_bresp[i] == 0, ("%t: *** AXI response error", $time))
    end

    // AXI read response channel

    wire [NUM_BANKS_OUT-1:0] rsp_xbar_valid_in;
    wire [NUM_BANKS_OUT-1:0][RSP_XBAR_DATAW-1:0] rsp_xbar_data_in;
    wire [NUM_BANKS_OUT-1:0][NUM_PORTS_IN_WIDTH-1:0] rsp_xbar_sel_in;
    wire [NUM_BANKS_OUT-1:0] rsp_xbar_ready_in;

    for (genvar g = 0; g < NUM_BANKS_OUT; ++g) begin : g_rsp_groups
        wire [PORTS_PER_GROUP-1:0] valid_in, ready_in;
        wire [PORTS_PER_GROUP-1:0][DATA_WIDTH+TAG_WIDTH_OUT-1:0] data_in;
        wire [DATA_WIDTH+TAG_WIDTH_OUT-1:0] data_out;
        wire [DATA_WIDTH-1:0] read_data;
        wire [TAG_WIDTH_OUT-1:0] read_id;
        for (genvar s = 0; s < PORTS_PER_GROUP; ++s) begin : g_hbm
            localparam P = g + s * NUM_BANKS_OUT;
            assign valid_in[s] = m_axi_rvalid[P];
            assign data_in[s] = {m_axi_rdata[P], m_axi_rid[P]};
            assign m_axi_rready[P] = ready_in[s];
            `VX_RUNTIME_ASSERT(~m_axi_rvalid[P] || m_axi_rlast[P], ("%t: *** AXI response is not single beat", $time))
            `VX_RUNTIME_ASSERT(~m_axi_rvalid[P] || m_axi_rresp[P] == 0, ("%t: *** AXI read response error", $time))
        end
        if (PORTS_PER_GROUP == 1) begin : g_direct
            assign rsp_xbar_valid_in[g] = valid_in[0];
            assign data_out = data_in[0];
            assign ready_in[0] = rsp_xbar_ready_in[g];
        end else begin : g_merge
            VX_stream_arb #(
                .NUM_INPUTS (PORTS_PER_GROUP),
                .DATAW      (DATA_WIDTH + TAG_WIDTH_OUT),
                .ARBITER    (ARBITER),
                .OUT_BUF    (2)
            ) response_arb (
                .clk (clk), .reset (reset),
                .valid_in (valid_in), .data_in (data_in), .ready_in (ready_in),
                .valid_out (rsp_xbar_valid_in[g]), .data_out (data_out),
                .ready_out (rsp_xbar_ready_in[g]),
                `UNUSED_PIN (sel_out)
            );
        end
        assign {read_data, read_id} = data_out;
        assign rsp_xbar_data_in[g] = {read_data, read_id[NUM_PORTS_IN_BITS +: READ_TAG_WIDTH]};
        if (NUM_PORTS_IN > 1) begin : g_input_sel
            assign rsp_xbar_sel_in[g] = read_id[0 +: NUM_PORTS_IN_BITS];
        end else begin : g_no_input_sel
            assign rsp_xbar_sel_in[g] = 0;
        end
    end

    wire [NUM_PORTS_IN-1:0] rsp_xbar_valid_out;
    wire [NUM_PORTS_IN-1:0][DATA_WIDTH+READ_TAG_WIDTH-1:0] rsp_xbar_data_out;
    wire [NUM_PORTS_IN-1:0] rsp_xbar_ready_out;

    VX_stream_xbar #(
        .NUM_INPUTS (NUM_BANKS_OUT),
        .NUM_OUTPUTS(NUM_PORTS_IN),
        .DATAW      (RSP_XBAR_DATAW),
        .ARBITER    (ARBITER),
        .OUT_BUF    ((`TO_OUT_BUF_SIZE(RSP_OUT_BUF) == 0) ? 2 : RSP_OUT_BUF)
    ) rsp_xbar (
        .clk       (clk),
        .reset     (reset),
        .valid_in  (rsp_xbar_valid_in),
        .data_in   (rsp_xbar_data_in),
        .ready_in  (rsp_xbar_ready_in),
        .sel_in    (rsp_xbar_sel_in),
        .data_out  (rsp_xbar_data_out),
        .valid_out (rsp_xbar_valid_out),
        .ready_out (rsp_xbar_ready_out),
        `UNUSED_PIN (collisions),
        `UNUSED_PIN (sel_out)
    );

    for (genvar i = 0; i < NUM_PORTS_IN; ++i) begin : g_rsp_xbar_data_out
        assign mem_rsp_valid[i] = rsp_xbar_valid_out[i];
        assign {mem_rsp_data[i], mem_rd_rsp_tag[i]} = rsp_xbar_data_out[i];
        assign rsp_xbar_ready_out[i] = mem_rsp_ready[i];
    end

    // Track complete transactions, including every buffer and the output cuts.
    // Reads retire at the cache handshake; writes retire at B (not at AW/W).
    // This is occupancy bookkeeping only: it stores no response data or order.
    reg [31:0] pending_transactions;
    reg [32:0] accepted_count, completed_count;
    reg input_pending;
    always @(*) begin
        accepted_count = 0;
        completed_count = 0;
        input_pending = 0;
        for (integer p = 0; p < NUM_PORTS_IN; ++p) begin
            accepted_count = accepted_count + 33'(mem_req_valid[p] && mem_req_ready[p]);
            completed_count = completed_count + 33'(mem_rsp_valid[p] && mem_rsp_ready[p]);
            input_pending = input_pending || mem_req_valid[p];
        end
        for (integer p = 0; p < NUM_HBM_PORTS; ++p) begin
            completed_count = completed_count + 33'(m_axi_bvalid[p] && m_axi_bready[p]);
        end
    end
    wire [32:0] pending_next = {1'b0, pending_transactions} + accepted_count - completed_count;
    always @(posedge clk) begin
        if (reset) begin
            pending_transactions <= 0;
        end else begin
            pending_transactions <= pending_next[31:0];
        end
    end
    assign busy = input_pending || (pending_transactions != 0);
    `VX_RUNTIME_ASSERT(~pending_next[32], ("%t: *** AXI pending transaction count overflow/underflow", $time))

endmodule
`TRACING_ON
