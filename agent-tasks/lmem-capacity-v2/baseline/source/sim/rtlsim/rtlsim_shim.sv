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

module rtlsim_shim import VX_gpu_pkg::*; #(
    parameter MEM_DATA_WIDTH = (`PLATFORM_MEMORY_DATA_SIZE * 8),
    parameter MEM_ADDR_WIDTH = `PLATFORM_MEMORY_ADDR_WIDTH - $clog2(`PLATFORM_MEMORY_NUM_BANKS),
    parameter MEM_NUM_BANKS  = `PLATFORM_MEMORY_NUM_BANKS,
    parameter MEM_TAG_WIDTH  = 64
) (
    `SCOPE_IO_DECL

    // Clock
    input  wire                             clk,
    input  wire                             reset,

    // Memory request
    output wire                             mem_req_valid [MEM_NUM_BANKS],
    output wire                             mem_req_rw [MEM_NUM_BANKS],
    output wire [(MEM_DATA_WIDTH/8)-1:0]    mem_req_byteen [MEM_NUM_BANKS],
    output wire [MEM_ADDR_WIDTH-1:0]        mem_req_addr [MEM_NUM_BANKS],
    output wire [MEM_DATA_WIDTH-1:0]        mem_req_data [MEM_NUM_BANKS],
    output wire [MEM_TAG_WIDTH-1:0]         mem_req_tag [MEM_NUM_BANKS],
    input  wire                             mem_req_ready [MEM_NUM_BANKS],

    // Memory response
    input  wire                             mem_rsp_valid [MEM_NUM_BANKS],
    input  wire [MEM_DATA_WIDTH-1:0]        mem_rsp_data [MEM_NUM_BANKS],
    input  wire [MEM_TAG_WIDTH-1:0]         mem_rsp_tag [MEM_NUM_BANKS],
    output wire                             mem_rsp_ready [MEM_NUM_BANKS],

    // DCR write request
    input  wire                             dcr_wr_valid,
    input  wire [VX_DCR_ADDR_WIDTH-1:0]     dcr_wr_addr,
    input  wire [VX_DCR_DATA_WIDTH-1:0]     dcr_wr_data,

    // Status
    output wire                             busy
);
    localparam DATA_SIZE = MEM_DATA_WIDTH / 8;
    localparam LOG2_DATA_SIZE = `CLOG2(DATA_SIZE);
    localparam BANK_SEL_BITS  = `CLOG2(MEM_NUM_BANKS);
    localparam AXI_ID_WIDTH   = MEM_TAG_WIDTH;

    wire                            m_axi_awvalid [MEM_NUM_BANKS];
    wire                            m_axi_awready [MEM_NUM_BANKS];
    wire [`PLATFORM_MEMORY_ADDR_WIDTH-1:0] m_axi_awaddr [MEM_NUM_BANKS];
    wire [AXI_ID_WIDTH-1:0]         m_axi_awid [MEM_NUM_BANKS];
    wire [7:0]                      m_axi_awlen [MEM_NUM_BANKS];
    wire [2:0]                      m_axi_awsize [MEM_NUM_BANKS];
    wire [1:0]                      m_axi_awburst [MEM_NUM_BANKS];
    wire [1:0]                      m_axi_awlock [MEM_NUM_BANKS];
    wire [3:0]                      m_axi_awcache [MEM_NUM_BANKS];
    wire [2:0]                      m_axi_awprot [MEM_NUM_BANKS];
    wire [3:0]                      m_axi_awqos [MEM_NUM_BANKS];
    wire [3:0]                      m_axi_awregion [MEM_NUM_BANKS];

    wire                            m_axi_wvalid [MEM_NUM_BANKS];
    wire                            m_axi_wready [MEM_NUM_BANKS];
    wire [MEM_DATA_WIDTH-1:0]       m_axi_wdata [MEM_NUM_BANKS];
    wire [DATA_SIZE-1:0]            m_axi_wstrb [MEM_NUM_BANKS];
    wire                            m_axi_wlast [MEM_NUM_BANKS];

    wire                            m_axi_bvalid [MEM_NUM_BANKS];
    wire                            m_axi_bready [MEM_NUM_BANKS];
    wire [AXI_ID_WIDTH-1:0]         m_axi_bid [MEM_NUM_BANKS];
    wire [1:0]                      m_axi_bresp [MEM_NUM_BANKS];

    wire                            m_axi_arvalid [MEM_NUM_BANKS];
    wire                            m_axi_arready [MEM_NUM_BANKS];
    wire [`PLATFORM_MEMORY_ADDR_WIDTH-1:0] m_axi_araddr [MEM_NUM_BANKS];
    wire [AXI_ID_WIDTH-1:0]         m_axi_arid [MEM_NUM_BANKS];
    wire [7:0]                      m_axi_arlen [MEM_NUM_BANKS];
    wire [2:0]                      m_axi_arsize [MEM_NUM_BANKS];
    wire [1:0]                      m_axi_arburst [MEM_NUM_BANKS];
    wire [1:0]                      m_axi_arlock [MEM_NUM_BANKS];
    wire [3:0]                      m_axi_arcache [MEM_NUM_BANKS];
    wire [2:0]                      m_axi_arprot [MEM_NUM_BANKS];
    wire [3:0]                      m_axi_arqos [MEM_NUM_BANKS];
    wire [3:0]                      m_axi_arregion [MEM_NUM_BANKS];

    wire                            m_axi_rvalid [MEM_NUM_BANKS];
    wire                            m_axi_rready [MEM_NUM_BANKS];
    wire [MEM_DATA_WIDTH-1:0]       m_axi_rdata [MEM_NUM_BANKS];
    wire                            m_axi_rlast [MEM_NUM_BANKS];
    wire [AXI_ID_WIDTH-1:0]         m_axi_rid [MEM_NUM_BANKS];
    wire [1:0]                      m_axi_rresp [MEM_NUM_BANKS];

    wire                            cache_drain;

    `SCOPE_IO_SWITCH (1);

    Vortex_axi #(
        .AXI_DATA_WIDTH  (MEM_DATA_WIDTH),
        .AXI_ADDR_WIDTH  (`PLATFORM_MEMORY_ADDR_WIDTH),
        .AXI_TID_WIDTH   (AXI_ID_WIDTH),
        .NUM_HBM_PORTS   (MEM_NUM_BANKS),
        .AXI_DMA_ID_WIDTH(`PLATFORM_MEMORY_ID_WIDTH)
    ) vortex (
        `SCOPE_IO_BIND  (0)

        .clk            (clk),
        .reset          (reset),

        .m_axi_awvalid  (m_axi_awvalid),
        .m_axi_awready  (m_axi_awready),
        .m_axi_awaddr   (m_axi_awaddr),
        .m_axi_awid     (m_axi_awid),
        .m_axi_awlen    (m_axi_awlen),
        .m_axi_awsize   (m_axi_awsize),
        .m_axi_awburst  (m_axi_awburst),
        .m_axi_awlock   (m_axi_awlock),
        .m_axi_awcache  (m_axi_awcache),
        .m_axi_awprot   (m_axi_awprot),
        .m_axi_awqos    (m_axi_awqos),
        .m_axi_awregion (m_axi_awregion),

        .m_axi_wvalid   (m_axi_wvalid),
        .m_axi_wready   (m_axi_wready),
        .m_axi_wdata    (m_axi_wdata),
        .m_axi_wstrb    (m_axi_wstrb),
        .m_axi_wlast    (m_axi_wlast),

        .m_axi_bvalid   (m_axi_bvalid),
        .m_axi_bready   (m_axi_bready),
        .m_axi_bid      (m_axi_bid),
        .m_axi_bresp    (m_axi_bresp),

        .m_axi_arvalid  (m_axi_arvalid),
        .m_axi_arready  (m_axi_arready),
        .m_axi_araddr   (m_axi_araddr),
        .m_axi_arid     (m_axi_arid),
        .m_axi_arlen    (m_axi_arlen),
        .m_axi_arsize   (m_axi_arsize),
        .m_axi_arburst  (m_axi_arburst),
        .m_axi_arlock   (m_axi_arlock),
        .m_axi_arcache  (m_axi_arcache),
        .m_axi_arprot   (m_axi_arprot),
        .m_axi_arqos    (m_axi_arqos),
        .m_axi_arregion (m_axi_arregion),

        .m_axi_rvalid   (m_axi_rvalid),
        .m_axi_rready   (m_axi_rready),
        .m_axi_rdata    (m_axi_rdata),
        .m_axi_rlast    (m_axi_rlast),
        .m_axi_rid      (m_axi_rid),
        .m_axi_rresp    (m_axi_rresp),

        .dcr_wr_valid   (dcr_wr_valid),
        .dcr_wr_addr    (dcr_wr_addr),
        .dcr_wr_data    (dcr_wr_data),

        .busy           (busy),
        .cache_drain    (cache_drain)
    );

    `UNUSED_VAR (cache_drain)
    `UNUSED_VAR (mem_rsp_tag)

    function automatic [MEM_ADDR_WIDTH-1:0] bank_addr_from_axi(input [`PLATFORM_MEMORY_ADDR_WIDTH-1:0] axi_addr);
    begin
        if (`PLATFORM_MEMORY_INTERLEAVE == 1) begin
            bank_addr_from_axi = MEM_ADDR_WIDTH'(axi_addr >> (LOG2_DATA_SIZE + BANK_SEL_BITS));
        end else begin
            bank_addr_from_axi = MEM_ADDR_WIDTH'(axi_addr >> LOG2_DATA_SIZE);
        end
    end
    endfunction

    for (genvar i = 0; i < MEM_NUM_BANKS; ++i) begin : g_axi_bridge
        reg                            wr_active;
        reg [MEM_ADDR_WIDTH-1:0]       wr_addr;
        reg [8:0]                      wr_beats_left;
        reg [AXI_ID_WIDTH-1:0]         wr_id;

        reg                            b_pending;
        reg [AXI_ID_WIDTH-1:0]         b_pending_id;
        reg                            b_valid_r;
        reg [AXI_ID_WIDTH-1:0]         b_id_r;

        reg                            rd_issue_active;
        reg [MEM_ADDR_WIDTH-1:0]       rd_issue_addr;
        reg [8:0]                      rd_issue_beats_left;
        reg [8:0]                      rd_rsp_beats_left;
        reg [AXI_ID_WIDTH-1:0]         rd_rsp_id;

        reg                            r_valid_r;
        reg [MEM_DATA_WIDTH-1:0]       r_data_r;
        reg [AXI_ID_WIDTH-1:0]         r_id_r;
        reg                            r_last_r;

        wire issue_write = wr_active && m_axi_wvalid[i];
        wire issue_read  = ~issue_write && rd_issue_active;
        wire mem_req_fire = mem_req_valid[i] && mem_req_ready[i];
        wire mem_rsp_fire = mem_rsp_valid[i] && mem_rsp_ready[i];

        assign mem_req_valid[i]  = issue_write || issue_read;
        assign mem_req_rw[i]     = issue_write;
        assign mem_req_byteen[i] = issue_write ? m_axi_wstrb[i] : {DATA_SIZE{1'b1}};
        assign mem_req_addr[i]   = issue_write ? wr_addr : rd_issue_addr;
        assign mem_req_data[i]   = issue_write ? m_axi_wdata[i] : '0;
        assign mem_req_tag[i]    = '0;

        assign mem_rsp_ready[i] = ~r_valid_r || m_axi_rready[i];

        assign m_axi_awready[i] = ~wr_active && ~b_pending && ~b_valid_r;
        assign m_axi_wready[i]  = issue_write && mem_req_ready[i];
        assign m_axi_bvalid[i]  = b_valid_r;
        assign m_axi_bid[i]     = b_id_r;
        assign m_axi_bresp[i]   = 2'b00;

        assign m_axi_arready[i] = ~rd_issue_active && (rd_rsp_beats_left == 0) && ~r_valid_r;
        assign m_axi_rvalid[i]  = r_valid_r;
        assign m_axi_rdata[i]   = r_data_r;
        assign m_axi_rid[i]     = r_id_r;
        assign m_axi_rlast[i]   = r_last_r;
        assign m_axi_rresp[i]   = 2'b00;

        `UNUSED_VAR (m_axi_awburst[i])
        `UNUSED_VAR (m_axi_awlock[i])
        `UNUSED_VAR (m_axi_awcache[i])
        `UNUSED_VAR (m_axi_awprot[i])
        `UNUSED_VAR (m_axi_awqos[i])
        `UNUSED_VAR (m_axi_awregion[i])
        `UNUSED_VAR (m_axi_arburst[i])
        `UNUSED_VAR (m_axi_arlock[i])
        `UNUSED_VAR (m_axi_arcache[i])
        `UNUSED_VAR (m_axi_arprot[i])
        `UNUSED_VAR (m_axi_arqos[i])
        `UNUSED_VAR (m_axi_arregion[i])
        `UNUSED_VAR (m_axi_wlast[i])
        `UNUSED_VAR (m_axi_arsize[i])
        `UNUSED_VAR (m_axi_awsize[i])

        always @(posedge clk) begin
            if (reset) begin
                wr_active          <= 0;
                wr_addr            <= '0;
                wr_beats_left      <= '0;
                wr_id              <= '0;
                b_pending          <= 0;
                b_pending_id       <= '0;
                b_valid_r          <= 0;
                b_id_r             <= '0;
                rd_issue_active    <= 0;
                rd_issue_addr      <= '0;
                rd_issue_beats_left<= '0;
                rd_rsp_beats_left  <= '0;
                rd_rsp_id          <= '0;
                r_valid_r          <= 0;
                r_data_r           <= '0;
                r_id_r             <= '0;
                r_last_r           <= 0;
            end else begin
                if (m_axi_awvalid[i] && m_axi_awready[i]) begin
                    wr_active     <= 1;
                    wr_addr       <= bank_addr_from_axi(m_axi_awaddr[i]);
                    wr_beats_left <= {1'b0, m_axi_awlen[i]} + 9'd1;
                    wr_id         <= m_axi_awid[i];
                end

                if (mem_req_fire && issue_write) begin
                    wr_addr <= wr_addr + MEM_ADDR_WIDTH'(1);
                    if (wr_beats_left == 9'd1) begin
                        wr_active    <= 0;
                        wr_beats_left<= '0;
                        b_pending    <= 1;
                        b_pending_id <= wr_id;
                    end else begin
                        wr_beats_left <= wr_beats_left - 9'd1;
                    end
                end

                if (m_axi_bvalid[i] && m_axi_bready[i]) begin
                    b_valid_r <= 0;
                end
                if (~b_valid_r && b_pending) begin
                    b_valid_r <= 1;
                    b_id_r    <= b_pending_id;
                    b_pending <= 0;
                end

                if (m_axi_arvalid[i] && m_axi_arready[i]) begin
                    rd_issue_active     <= 1;
                    rd_issue_addr       <= bank_addr_from_axi(m_axi_araddr[i]);
                    rd_issue_beats_left <= {1'b0, m_axi_arlen[i]} + 9'd1;
                    rd_rsp_beats_left   <= '0;
                    rd_rsp_id           <= m_axi_arid[i];
                end

                if (mem_req_fire && issue_read) begin
                    rd_issue_addr <= rd_issue_addr + MEM_ADDR_WIDTH'(1);
                    rd_rsp_beats_left <= rd_rsp_beats_left + 9'd1;
                    if (rd_issue_beats_left == 9'd1) begin
                        rd_issue_active     <= 0;
                        rd_issue_beats_left <= '0;
                    end else begin
                        rd_issue_beats_left <= rd_issue_beats_left - 9'd1;
                    end
                end

                if (m_axi_rvalid[i] && m_axi_rready[i]) begin
                    r_valid_r <= 0;
                end
                if (mem_rsp_fire) begin
                    r_valid_r <= 1;
                    r_data_r  <= mem_rsp_data[i];
                    r_id_r    <= rd_rsp_id;
                    r_last_r  <= (rd_rsp_beats_left == 9'd1);
                    rd_rsp_beats_left <= rd_rsp_beats_left - 9'd1;
                end
            end
        end
    end

endmodule
