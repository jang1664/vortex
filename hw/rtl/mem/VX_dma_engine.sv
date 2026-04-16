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

// VX_dma_engine
//  Multi-channel DMA engine bridging HBM (AXI) and TMEM (VX_mem_bus_if).
//  Each channel instantiates VX_dma_unit_misal for the 3D strided FSM.
//  For the TMEM DMA pattern (SEG_SIZE=64, stride=512, BND0<=8), both HBM reads
//  and HBM writes are handled locally so the logical DMA address can be remapped
//  and coalesced into remapped AXI bursts.  Non-burst writes fall back to
//  VX_axi_adapter.

module VX_dma_engine import VX_gpu_pkg::*; #(
    parameter `STRING INSTANCE_ID   = "",
    parameter NUM_CHANNELS          = 8,
    parameter DATA_WIDTH            = 512,
    parameter AXI_ADDR_WIDTH        = `PLATFORM_MEMORY_ADDR_WIDTH,
    parameter AXI_DATA_WIDTH        = `PLATFORM_MEMORY_DATA_SIZE * 8,
    parameter AXI_ID_WIDTH          = `PLATFORM_MEMORY_ID_WIDTH,
    parameter AXI_USER_WIDTH        = 1,
    parameter MEM_ADDR_WIDTH        = `MEM_ADDR_WIDTH,
    parameter TAG_WIDTH             = 8
) (
    input wire clk,
    input wire reset,

    // Config register interface per channel (from gemm_dma_ctrl)
    VX_config_reg_if.slave  cfg_reg_if [NUM_CHANNELS],

    // Done interface per channel
    VX_node_done_if.master  done_if [NUM_CHANNELS],

    // HBM side: AXI master per channel
    AXI_BUS.Master          axi_m [NUM_CHANNELS],

    // TMEM side: VX_mem_bus_if master per channel
    VX_mem_bus_if.master    tmem_bus_if [NUM_CHANNELS]
);

    localparam DATA_SIZE      = DATA_WIDTH / 8;
    localparam LOG2_DATA_SIZE = `CLOG2(DATA_SIZE);
    // VX_mem_bus_if uses word-addressable addresses
    localparam HBM_ADDR_WIDTH = MEM_ADDR_WIDTH - LOG2_DATA_SIZE;
    localparam AXI_TAG_WIDTH  = AXI_ID_WIDTH;

    localparam int DMA_R_CONTROL     = 0;
    localparam int DMA_R_DST_BASE_LO = 1;
    localparam int DMA_R_DST_BASE_HI = 2;
    localparam int DMA_R_SRC_BASE_LO = 3;
    localparam int DMA_R_SRC_BASE_HI = 4;
    localparam int DMA_R_SRC_ST0     = 5;
    localparam int DMA_R_DST_ST0     = 6;
    localparam int DMA_R_SRC_ST1     = 7;
    localparam int DMA_R_DST_ST1     = 8;
    localparam int DMA_R_SRC_ST2     = 9;
    localparam int DMA_R_DST_ST2     = 10;
    localparam int DMA_R_BND0        = 11;
    localparam int DMA_R_BND1        = 12;
    localparam int DMA_R_BND2        = 13;
    localparam int DMA_R_SEG_SIZE    = 14;
    localparam int DMA_R_PAD         = 15;
    localparam int DMA_R_DIR         = 16;

    localparam int READ_WINDOW_WORDS = 8;
    localparam int READ_BURST_GROUPS = 4;
    localparam int READ_GROUP_CAP    = READ_WINDOW_WORDS / READ_BURST_GROUPS;

    function automatic [1:0] calc_group_words(
        input logic [3:0] window_words,
        input logic [1:0] group_idx
    );
        logic [4:0] words_left;
        begin
            if (window_words <= {2'd0, group_idx}) begin
                calc_group_words = 2'd0;
            end else begin
                words_left = window_words - {2'd0, group_idx} - 5'd1;
                calc_group_words = words_left[4:2] + 2'd1;
            end
        end
    endfunction

    function automatic [AXI_ADDR_WIDTH-1:0] calc_remap_byte_addr(
        input logic [AXI_ADDR_WIDTH-1:0] byte_addr
    );
        logic [AXI_ADDR_WIDTH-1:0] block_idx;
        logic [AXI_ADDR_WIDTH-1:0] byte_offset;
        logic [4:0]                bank_idx;
        logic [AXI_ADDR_WIDTH-1:0] bank_offset;
        begin
            block_idx   = byte_addr >> 6;
            byte_offset = byte_addr & AXI_ADDR_WIDTH'(64'h3f);
            bank_idx    = block_idx[4:0];
            bank_offset = (block_idx >> 5) << 6;
            calc_remap_byte_addr =
                ({ {(AXI_ADDR_WIDTH-5){1'b0}}, bank_idx } << 29)
              | bank_offset
              | byte_offset;
        end
    endfunction

    for (genvar ch = 0; ch < NUM_CHANNELS; ++ch) begin : g_channel

        typedef enum logic [2:0] {
            RD_IDLE,
            RD_DIRECT_AR,
            RD_DIRECT_R,
            RD_BURST_CAPTURE,
            RD_BURST_AR,
            RD_BURST_R
        } read_state_t;

        typedef enum logic [2:0] {
            WR_IDLE,
            WR_BURST_CAPTURE,
            WR_BURST_AW,
            WR_BURST_W,
            WR_BURST_B
        } write_state_t;

        // --------------------------------------------------------
        // Internal membus interface for HBM side (dcache port)
        // --------------------------------------------------------
        VX_mem_bus_if #(
            .DATA_SIZE      (DATA_SIZE),
            .TAG_WIDTH      (TAG_WIDTH),
            .MEM_ADDR_WIDTH (MEM_ADDR_WIDTH)
        ) hbm_bus_if ();

        // --------------------------------------------------------
        // VX_dma_unit_misal instance
        //   dcache_bus_if -> hbm_bus_if
        //   lmem_bus_if   -> tmem_bus_if[ch]
        //   done gated by burst write completion
        // --------------------------------------------------------
        VX_node_done_if internal_done_if();

        VX_dma_unit_misal #(
            .INSTANCE_ID (INSTANCE_ID)
        ) u_dma_unit (
            .clk            (clk),
            .reset          (reset),
            .cfg_reg_if     (cfg_reg_if[ch]),
            .dcache_bus_if  (hbm_bus_if),
            .lmem_bus_if    (tmem_bus_if[ch]),
            .done_if        (internal_done_if)
        );

        // --------------------------------------------------------
        // Extract flat signals from hbm_bus_if
        // --------------------------------------------------------
        wire                      hbm_req_valid;
        wire                      hbm_req_rw;
        wire [DATA_SIZE-1:0]      hbm_req_byteen;
        wire [HBM_ADDR_WIDTH-1:0] hbm_req_addr;
        wire [DATA_WIDTH-1:0]     hbm_req_data;
        wire [TAG_WIDTH-1:0]      hbm_req_tag;
        wire                      hbm_req_ready;

        wire                      hbm_rsp_valid;
        wire [DATA_WIDTH-1:0]     hbm_rsp_data;
        wire [TAG_WIDTH-1:0]      hbm_rsp_tag;
        wire                      hbm_rsp_ready;

        assign hbm_req_valid         = hbm_bus_if.req_valid;
        assign hbm_req_rw            = hbm_bus_if.req_data.rw;
        assign hbm_req_byteen        = hbm_bus_if.req_data.byteen;
        assign hbm_req_addr          = hbm_bus_if.req_data.addr;
        assign hbm_req_data          = hbm_bus_if.req_data.data;
        assign hbm_req_tag           = TAG_WIDTH'(hbm_bus_if.req_data.tag);
        assign hbm_bus_if.req_ready  = hbm_req_ready;

        assign hbm_bus_if.rsp_valid     = hbm_rsp_valid;
        assign hbm_bus_if.rsp_data.data = hbm_rsp_data;
        assign hbm_bus_if.rsp_data.tag  = hbm_rsp_tag;
        assign hbm_rsp_ready            = hbm_bus_if.rsp_ready;

        wire [AXI_ADDR_WIDTH-1:0] hbm_req_byte_addr;
        wire [AXI_ADDR_WIDTH-1:0] hbm_req_remap_byte_addr;
        wire [HBM_ADDR_WIDTH-1:0] hbm_req_remap_word_addr;

        assign hbm_req_byte_addr       = AXI_ADDR_WIDTH'(hbm_req_addr) << LOG2_DATA_SIZE;
        assign hbm_req_remap_word_addr = HBM_ADDR_WIDTH'(hbm_req_remap_byte_addr >> LOG2_DATA_SIZE);

        VX_mem_remap #(
            .ADDR_W (AXI_ADDR_WIDTH)
        ) u_mem_remap (
            .m_address   (hbm_req_byte_addr),
            .hbm_address (hbm_req_remap_byte_addr)
        );

        // --------------------------------------------------------
        // Descriptor latch for read-burst scheduling
        // --------------------------------------------------------
        wire cfg_fire = cfg_reg_if[ch].valid && cfg_reg_if[ch].ready;

        wire cfg_is_read = ~cfg_reg_if[ch].regs[DMA_R_DIR][0];

        logic [31:0] desc_words_r;
        logic        burst_read_enable_r;
        logic        burst_write_enable_r;

        // --------------------------------------------------------
        // Write path: existing adapter, but fed with remapped addresses
        // --------------------------------------------------------
        wire                      wr_req_valid;
        wire                      wr_req_ready;
        wire                      wr_burst_req_ready;

        assign wr_req_valid = hbm_req_valid && hbm_req_rw;

        wire                       mem_req_valid_arr [1];
        wire                       mem_req_rw_arr    [1];
        wire [DATA_SIZE-1:0]       mem_req_byteen_arr[1];
        wire [HBM_ADDR_WIDTH-1:0]  mem_req_addr_arr  [1];
        wire [DATA_WIDTH-1:0]      mem_req_data_arr  [1];
        wire [TAG_WIDTH-1:0]       mem_req_tag_arr   [1];
        wire                       mem_req_ready_arr [1];
        wire                       mem_rsp_valid_arr [1];
        wire [DATA_WIDTH-1:0]      mem_rsp_data_arr  [1];
        wire [TAG_WIDTH-1:0]       mem_rsp_tag_arr   [1];
        wire                       mem_rsp_ready_arr [1];

        assign mem_req_valid_arr[0]  = wr_req_valid && ~burst_write_enable_r;
        assign mem_req_rw_arr[0]     = 1'b1;
        assign mem_req_byteen_arr[0] = hbm_req_byteen;
        assign mem_req_addr_arr[0]   = hbm_req_remap_word_addr;
        assign mem_req_data_arr[0]   = hbm_req_data;
        assign mem_req_tag_arr[0]    = hbm_req_tag;
        assign wr_req_ready          = burst_write_enable_r ? wr_burst_req_ready : mem_req_ready_arr[0];

        assign mem_rsp_ready_arr[0]  = 1'b0;

        wire                            m_axi_awvalid_arr [1];
        wire                            m_axi_awready_arr [1];
        wire [AXI_ADDR_WIDTH-1:0]       m_axi_awaddr_arr  [1];
        wire [AXI_TAG_WIDTH-1:0]        m_axi_awid_arr    [1];
        wire [7:0]                      m_axi_awlen_arr   [1];
        wire [2:0]                      m_axi_awsize_arr  [1];
        wire [1:0]                      m_axi_awburst_arr [1];
        wire [1:0]                      m_axi_awlock_arr  [1];
        wire [3:0]                      m_axi_awcache_arr [1];
        wire [2:0]                      m_axi_awprot_arr  [1];
        wire [3:0]                      m_axi_awqos_arr   [1];
        wire [3:0]                      m_axi_awregion_arr[1];

        wire                            m_axi_wvalid_arr  [1];
        wire                            m_axi_wready_arr  [1];
        wire [AXI_DATA_WIDTH-1:0]       m_axi_wdata_arr   [1];
        wire [AXI_DATA_WIDTH/8-1:0]     m_axi_wstrb_arr   [1];
        wire                            m_axi_wlast_arr   [1];

        wire                            m_axi_bvalid_arr  [1];
        wire                            m_axi_bready_arr  [1];
        wire [AXI_TAG_WIDTH-1:0]        m_axi_bid_arr     [1];
        wire [1:0]                      m_axi_bresp_arr   [1];

        wire                            m_axi_arvalid_arr [1];
        wire                            m_axi_arready_arr [1];
        wire [AXI_ADDR_WIDTH-1:0]       m_axi_araddr_arr  [1];
        wire [AXI_TAG_WIDTH-1:0]        m_axi_arid_arr    [1];
        wire [7:0]                      m_axi_arlen_arr   [1];
        wire [2:0]                      m_axi_arsize_arr  [1];
        wire [1:0]                      m_axi_arburst_arr [1];
        wire [1:0]                      m_axi_arlock_arr  [1];
        wire [3:0]                      m_axi_arcache_arr [1];
        wire [2:0]                      m_axi_arprot_arr  [1];
        wire [3:0]                      m_axi_arqos_arr   [1];
        wire [3:0]                      m_axi_arregion_arr[1];

        wire                            m_axi_rvalid_arr  [1];
        wire                            m_axi_rready_arr  [1];
        wire [AXI_DATA_WIDTH-1:0]       m_axi_rdata_arr   [1];
        wire                            m_axi_rlast_arr   [1];
        wire [AXI_TAG_WIDTH-1:0]        m_axi_rid_arr     [1];
        wire [1:0]                      m_axi_rresp_arr   [1];

        assign m_axi_arready_arr[0] = 1'b0;
        assign m_axi_rvalid_arr[0]  = 1'b0;
        assign m_axi_rdata_arr[0]   = '0;
        assign m_axi_rlast_arr[0]   = 1'b0;
        assign m_axi_rid_arr[0]     = '0;
        assign m_axi_rresp_arr[0]   = 2'b00;

        VX_axi_adapter #(
            .DATA_WIDTH      (DATA_WIDTH),
            .ADDR_WIDTH_IN   (HBM_ADDR_WIDTH),
            .ADDR_WIDTH_OUT  (AXI_ADDR_WIDTH),
            .TAG_WIDTH_IN    (TAG_WIDTH),
            .TAG_WIDTH_OUT   (AXI_TAG_WIDTH),
            .NUM_PORTS_IN    (1),
            .NUM_BANKS_OUT   (1),
            .TAG_BUFFER_SIZE (16)
        ) u_axi_adapter (
            .clk              (clk),
            .reset            (reset),
            .mem_req_valid    (mem_req_valid_arr),
            .mem_req_rw       (mem_req_rw_arr),
            .mem_req_byteen   (mem_req_byteen_arr),
            .mem_req_addr     (mem_req_addr_arr),
            .mem_req_data     (mem_req_data_arr),
            .mem_req_tag      (mem_req_tag_arr),
            .mem_req_ready    (mem_req_ready_arr),
            .mem_rsp_valid    (mem_rsp_valid_arr),
            .mem_rsp_data     (mem_rsp_data_arr),
            .mem_rsp_tag      (mem_rsp_tag_arr),
            .mem_rsp_ready    (mem_rsp_ready_arr),
            .m_axi_awvalid    (m_axi_awvalid_arr),
            .m_axi_awready    (m_axi_awready_arr),
            .m_axi_awaddr     (m_axi_awaddr_arr),
            .m_axi_awid       (m_axi_awid_arr),
            .m_axi_awlen      (m_axi_awlen_arr),
            .m_axi_awsize     (m_axi_awsize_arr),
            .m_axi_awburst    (m_axi_awburst_arr),
            .m_axi_awlock     (m_axi_awlock_arr),
            .m_axi_awcache    (m_axi_awcache_arr),
            .m_axi_awprot     (m_axi_awprot_arr),
            .m_axi_awqos      (m_axi_awqos_arr),
            .m_axi_awregion   (m_axi_awregion_arr),
            .m_axi_wvalid     (m_axi_wvalid_arr),
            .m_axi_wready     (m_axi_wready_arr),
            .m_axi_wdata      (m_axi_wdata_arr),
            .m_axi_wstrb      (m_axi_wstrb_arr),
            .m_axi_wlast      (m_axi_wlast_arr),
            .m_axi_bvalid     (m_axi_bvalid_arr),
            .m_axi_bready     (m_axi_bready_arr),
            .m_axi_bid        (m_axi_bid_arr),
            .m_axi_bresp      (m_axi_bresp_arr),
            .m_axi_arvalid    (m_axi_arvalid_arr),
            .m_axi_arready    (m_axi_arready_arr),
            .m_axi_araddr     (m_axi_araddr_arr),
            .m_axi_arid       (m_axi_arid_arr),
            .m_axi_arlen      (m_axi_arlen_arr),
            .m_axi_arsize     (m_axi_arsize_arr),
            .m_axi_arburst    (m_axi_arburst_arr),
            .m_axi_arlock     (m_axi_arlock_arr),
            .m_axi_arcache    (m_axi_arcache_arr),
            .m_axi_arprot     (m_axi_arprot_arr),
            .m_axi_arqos      (m_axi_arqos_arr),
            .m_axi_arregion   (m_axi_arregion_arr),
            .m_axi_rvalid     (m_axi_rvalid_arr),
            .m_axi_rready     (m_axi_rready_arr),
            .m_axi_rdata      (m_axi_rdata_arr),
            .m_axi_rlast      (m_axi_rlast_arr),
            .m_axi_rid        (m_axi_rid_arr),
            .m_axi_rresp      (m_axi_rresp_arr)
        );

        // --------------------------------------------------------
        // Read path: remap-aware AXI bridge with limited burst reordering
        // --------------------------------------------------------
        logic [AXI_ADDR_WIDTH-1:0] direct_read_addr_r;
        logic [TAG_WIDTH-1:0]      direct_read_tag_r;

        logic [AXI_ADDR_WIDTH-1:0] burst_src_base_byte_r;
        logic [31:0]               burst_words_served_r;
        logic                      burst_prefetch_started_r;
        logic                      burst_req_pending_r;
        logic [TAG_WIDTH-1:0]      burst_req_tag_r;
        logic                      burst_rsp_valid_r;
        logic [DATA_WIDTH-1:0]     burst_rsp_data_r;
        logic [TAG_WIDTH-1:0]      burst_rsp_tag_r;
        logic [31:0]               burst_window_base_r;
        logic [3:0]                burst_accept_count_r;
        logic [1:0]                burst_issue_group_r;
        logic [1:0]                burst_issue_beat_r;
        logic [READ_BURST_GROUPS-1:0][1:0]                          burst_group_count_r;
        logic [READ_BURST_GROUPS-1:0][AXI_ADDR_WIDTH-1:0]           burst_group_base_addr_r;
        logic [READ_BURST_GROUPS-1:0][READ_GROUP_CAP-1:0][TAG_WIDTH-1:0] burst_group_tag_r;
        logic [READ_WINDOW_WORDS-1:0][DATA_WIDTH-1:0]               burst_window_data_r;
        logic [READ_WINDOW_WORDS-1:0]                               burst_window_valid_r;

        read_state_t read_state_r;

        // --------------------------------------------------------
        // Write burst registers
        // --------------------------------------------------------
        write_state_t write_state_r;
        logic [AXI_ADDR_WIDTH-1:0] burst_wr_dst_base_byte_r;
        logic [31:0]               burst_wr_words_captured_r;
        logic [31:0]               burst_wr_window_base_r;
        logic                      burst_wr_prefetch_started_r;
        logic [1:0]                burst_wr_issue_group_r;
        logic [1:0]                burst_wr_issue_beat_r;
        logic [READ_BURST_GROUPS-1:0][1:0]                burst_wr_group_count_r;
        logic [READ_BURST_GROUPS-1:0][AXI_ADDR_WIDTH-1:0] burst_wr_group_base_addr_r;
        logic [READ_WINDOW_WORDS-1:0][DATA_WIDTH-1:0]     burst_wr_window_data_r;
        logic [READ_WINDOW_WORDS-1:0][DATA_SIZE-1:0]      burst_wr_window_byteen_r;

        // Hold done until burst writes drain to AXI
        wire wr_burst_idle = ~burst_write_enable_r | (write_state_r == WR_IDLE);
        assign done_if[ch].valid      = internal_done_if.valid & wr_burst_idle;
        assign done_if[ch].entry_id   = internal_done_if.entry_id;
        assign internal_done_if.ready = done_if[ch].ready & wr_burst_idle;

        wire                       rd_req_valid;
        wire [3:0]                 burst_window_words;
        wire [31:0]                burst_words_remaining;
        wire [1:0]                 burst_group_words [READ_BURST_GROUPS];
        wire [2:0]                 burst_service_word;
        wire [AXI_ADDR_WIDTH-1:0]  burst_expected_byte_addr;
        wire                       burst_service_data_ready;
        wire                       rd_req_ready;
        wire                       axi_r_fire;
        wire                       burst_rsp_active;

        assign rd_req_valid         = hbm_req_valid && ~hbm_req_rw;
        assign burst_words_remaining = (desc_words_r > burst_window_base_r)
                                     ? (desc_words_r - burst_window_base_r)
                                     : 32'd0;
        assign burst_window_words    = (burst_words_remaining > READ_WINDOW_WORDS)
                                     ? READ_WINDOW_WORDS[3:0]
                                     : burst_words_remaining[3:0];
        assign burst_service_word   = burst_words_served_r[2:0];
        assign burst_expected_byte_addr = burst_src_base_byte_r + (AXI_ADDR_WIDTH'(burst_words_served_r) << 9);
        assign burst_service_data_ready = burst_window_valid_r[burst_service_word];
        assign burst_rsp_active     = (read_state_r == RD_DIRECT_R)
                                   || (burst_read_enable_r && burst_req_pending_r && burst_service_data_ready);

        for (genvar g = 0; g < READ_BURST_GROUPS; ++g) begin : g_burst_group_words
            assign burst_group_words[g] = calc_group_words(burst_window_words, g[1:0]);
        end

        // Write burst combinational logic
        wire [3:0]                 burst_wr_window_words;
        wire [1:0]                 burst_wr_group_words [READ_BURST_GROUPS];
        wire [AXI_ADDR_WIDTH-1:0]  burst_wr_expected_byte_addr;
        wire [3:0]                 burst_wr_word_idx;

        wire [31:0] burst_wr_words_remaining = (desc_words_r > burst_wr_window_base_r)
                                         ? (desc_words_r - burst_wr_window_base_r) : 32'd0;
        assign burst_wr_window_words = (burst_wr_words_remaining > READ_WINDOW_WORDS)
                                     ? READ_WINDOW_WORDS[3:0]
                                     : burst_wr_words_remaining[3:0];

        assign burst_wr_expected_byte_addr = burst_wr_dst_base_byte_r
                                           + (AXI_ADDR_WIDTH'(burst_wr_words_captured_r) << 9);

        assign wr_burst_req_ready = (write_state_r == WR_BURST_CAPTURE)
                                 && (burst_wr_words_captured_r < desc_words_r)
                                 && ((burst_wr_words_captured_r == 32'd0)
                                  || (hbm_req_byte_addr == burst_wr_expected_byte_addr));

        assign burst_wr_word_idx = {2'd0, burst_wr_issue_group_r}
                                 + ({2'd0, burst_wr_issue_beat_r} << 2);

        for (genvar g = 0; g < READ_BURST_GROUPS; ++g) begin : g_wr_burst_group_words
            assign burst_wr_group_words[g] = calc_group_words(burst_wr_window_words, g[1:0]);
        end

        assign rd_req_ready =
            burst_read_enable_r
                ? ((read_state_r == RD_BURST_CAPTURE)
                && ~burst_req_pending_r
                && (burst_words_served_r < desc_words_r)
                && (((~burst_prefetch_started_r))
                 || (burst_service_data_ready && (hbm_req_byte_addr == burst_expected_byte_addr))))
                : (read_state_r == RD_IDLE);

        assign axi_r_fire = axi_m[ch].r_valid && axi_m[ch].r_ready;

        always_ff @(posedge clk) begin
            if (reset) begin
                desc_words_r         <= '0;
                burst_read_enable_r  <= 1'b0;
                direct_read_addr_r   <= '0;
                direct_read_tag_r    <= '0;
                burst_window_base_r  <= '0;
                burst_accept_count_r <= '0;
                burst_issue_group_r  <= '0;
                burst_issue_beat_r   <= '0;
                read_state_r         <= RD_IDLE;
                for (int i = 0; i < READ_BURST_GROUPS; ++i) begin
                    burst_group_count_r[i]     <= '0;
                    burst_group_base_addr_r[i] <= '0;
                    for (int j = 0; j < READ_GROUP_CAP; ++j) begin
                        burst_group_tag_r[i][j] <= '0;
                    end
                end
                burst_write_enable_r        <= 1'b0;
                write_state_r               <= WR_IDLE;
                burst_wr_dst_base_byte_r    <= '0;
                burst_wr_words_captured_r   <= '0;
                burst_wr_window_base_r      <= '0;
                burst_wr_prefetch_started_r <= 1'b0;
                burst_wr_issue_group_r      <= '0;
                burst_wr_issue_beat_r       <= '0;
                for (int i = 0; i < READ_BURST_GROUPS; ++i) begin
                    burst_wr_group_count_r[i]     <= '0;
                    burst_wr_group_base_addr_r[i] <= '0;
                end
            end else begin
                if (cfg_fire) begin
                    logic cfg_burst_read_eligible_v;
                    logic cfg_burst_write_eligible_v;
                    cfg_burst_read_eligible_v =
                        cfg_is_read
                     && (cfg_reg_if[ch].regs[DMA_R_SEG_SIZE] == 32'd64)
                     && (cfg_reg_if[ch].regs[DMA_R_PAD]      == 32'd0)
                     && (cfg_reg_if[ch].regs[DMA_R_BND2]     == 32'd1)
                     && (cfg_reg_if[ch].regs[DMA_R_SRC_ST0]  == 32'd512)
                     && (cfg_reg_if[ch].regs[DMA_R_SRC_ST2]  == 32'd0)
                     && (cfg_reg_if[ch].regs[DMA_R_DST_ST2]  == 32'd0)
                     && (cfg_reg_if[ch].regs[DMA_R_SRC_BASE_LO][5:0] == 6'd0)
                     && (cfg_reg_if[ch].regs[DMA_R_SRC_ST1][5:0]     == 6'd0)
                     && (cfg_reg_if[ch].regs[DMA_R_BND0] != 32'd0);
                    cfg_burst_write_eligible_v =
                        ~cfg_is_read
                     && (cfg_reg_if[ch].regs[DMA_R_SEG_SIZE] == 32'd64)
                     && (cfg_reg_if[ch].regs[DMA_R_PAD]      == 32'd0)
                     && (cfg_reg_if[ch].regs[DMA_R_BND2]     == 32'd1)
                     && (cfg_reg_if[ch].regs[DMA_R_DST_ST0]  == 32'd512)
                     && (cfg_reg_if[ch].regs[DMA_R_SRC_ST2]  == 32'd0)
                     && (cfg_reg_if[ch].regs[DMA_R_DST_ST2]  == 32'd0)
                     && (cfg_reg_if[ch].regs[DMA_R_DST_BASE_LO][5:0] == 6'd0)
                     && (cfg_reg_if[ch].regs[DMA_R_DST_ST1][5:0]     == 6'd0)
                     && (cfg_reg_if[ch].regs[DMA_R_BND0] != 32'd0);
                    desc_words_r         <= cfg_reg_if[ch].regs[DMA_R_BND0];
                    burst_read_enable_r  <= cfg_burst_read_eligible_v;
                    burst_write_enable_r <= cfg_burst_write_eligible_v;
                    direct_read_addr_r   <= '0;
                    direct_read_tag_r    <= '0;
                    burst_src_base_byte_r <= '0;
                    burst_words_served_r  <= '0;
                    burst_prefetch_started_r <= 1'b0;
                    burst_req_pending_r   <= 1'b0;
                    burst_req_tag_r       <= '0;
                    burst_rsp_valid_r     <= 1'b0;
                    burst_rsp_data_r      <= '0;
                    burst_rsp_tag_r       <= '0;
                    burst_window_base_r  <= '0;
                    burst_accept_count_r <= '0;
                    burst_issue_group_r  <= '0;
                    burst_issue_beat_r   <= '0;
                    read_state_r         <= cfg_burst_read_eligible_v ? RD_BURST_CAPTURE : RD_IDLE;
                    for (int i = 0; i < READ_BURST_GROUPS; ++i) begin
                        burst_group_count_r[i]     <= '0;
                        burst_group_base_addr_r[i] <= '0;
                        for (int j = 0; j < READ_GROUP_CAP; ++j) begin
                            burst_group_tag_r[i][j] <= '0;
                        end
                    end
                    for (int i = 0; i < READ_WINDOW_WORDS; ++i) begin
                        burst_window_data_r[i]  <= '0;
                        burst_window_valid_r[i] <= 1'b0;
                    end
                    write_state_r               <= cfg_burst_write_eligible_v ? WR_BURST_CAPTURE : WR_IDLE;
                    burst_wr_dst_base_byte_r    <= '0;
                    burst_wr_words_captured_r   <= '0;
                    burst_wr_window_base_r      <= '0;
                    burst_wr_prefetch_started_r <= 1'b0;
                    burst_wr_issue_group_r      <= '0;
                    burst_wr_issue_beat_r       <= '0;
                    for (int i = 0; i < READ_BURST_GROUPS; ++i) begin
                        burst_wr_group_count_r[i]     <= '0;
                        burst_wr_group_base_addr_r[i] <= '0;
                    end
                    for (int i = 0; i < READ_WINDOW_WORDS; ++i) begin
                        burst_wr_window_data_r[i]   <= '0;
                        burst_wr_window_byteen_r[i] <= '0;
                    end
                end else begin
                    if (burst_read_enable_r) begin
                        if (burst_rsp_valid_r && hbm_rsp_ready) begin
                            burst_rsp_valid_r <= 1'b0;
                            burst_window_valid_r[burst_service_word] <= 1'b0;
                            burst_req_pending_r <= 1'b0;
                            burst_words_served_r <= burst_words_served_r + 32'd1;
                            // Advance to next window if this was the last word of the current window
                            if (burst_words_served_r + 32'd1 == burst_window_base_r + {28'd0, burst_window_words}
                                && burst_words_served_r + 32'd1 < desc_words_r) begin
                                burst_window_base_r      <= burst_window_base_r + {28'd0, burst_window_words};
                                burst_prefetch_started_r <= 1'b0;
                                for (int i = 0; i < READ_WINDOW_WORDS; ++i)
                                    burst_window_valid_r[i] <= 1'b0;
                            end
                        end

                        if (burst_req_pending_r && !burst_rsp_valid_r && burst_service_data_ready) begin
                            burst_rsp_valid_r <= 1'b1;
                            burst_rsp_data_r  <= burst_window_data_r[burst_service_word];
                            burst_rsp_tag_r   <= burst_req_tag_r;
                        end

                        case (read_state_r)
                            RD_BURST_CAPTURE: begin
                                if (rd_req_valid && rd_req_ready) begin
                                    burst_req_pending_r <= 1'b1;
                                    burst_req_tag_r     <= hbm_req_tag;

                                    if (!burst_prefetch_started_r) begin
                                        if (burst_words_served_r == 32'd0)
                                            burst_src_base_byte_r <= hbm_req_byte_addr;
                                        burst_prefetch_started_r <= 1'b1;
                                        burst_accept_count_r     <= 4'd1;
                                        burst_issue_group_r <= '0;
                                        burst_issue_beat_r  <= '0;
                                        read_state_r        <= RD_BURST_AR;
                                        for (int i = 0; i < READ_BURST_GROUPS; ++i) begin
                                            burst_group_count_r[i]     <= burst_group_words[i];
                                            burst_group_base_addr_r[i] <= calc_remap_byte_addr(
                                                hbm_req_byte_addr + (AXI_ADDR_WIDTH'(i) << 9)
                                            );
                                        end
                                    end
                                end
                            end
                            RD_BURST_AR: begin
                                if (burst_group_count_r[burst_issue_group_r] == 0) begin
                                    if (burst_issue_group_r == READ_BURST_GROUPS-1) begin
                                        burst_issue_group_r  <= '0;
                                        burst_issue_beat_r   <= '0;
                                        read_state_r         <= RD_BURST_CAPTURE;
                                    end else begin
                                        burst_issue_group_r <= burst_issue_group_r + 2'd1;
                                    end
                                end else if (axi_m[ch].ar_ready) begin
                                    burst_issue_beat_r <= '0;
                                    read_state_r       <= RD_BURST_R;
                                end
                            end
                            RD_BURST_R: begin
                                if (axi_r_fire) begin
                                    logic [3:0] rsp_word_idx;
                                    rsp_word_idx = {2'd0, burst_issue_group_r} + ({2'd0, burst_issue_beat_r} << 2);
                                    burst_window_data_r[rsp_word_idx]  <= axi_m[ch].r_data;
                                    burst_window_valid_r[rsp_word_idx] <= 1'b1;

                                    if (burst_issue_beat_r + 2'd1 < burst_group_count_r[burst_issue_group_r]) begin
                                        burst_issue_beat_r <= burst_issue_beat_r + 2'd1;
                                    end else begin
                                        burst_issue_beat_r <= '0;
                                        if (burst_issue_group_r == READ_BURST_GROUPS-1) begin
                                            burst_issue_group_r  <= '0;
                                            read_state_r         <= RD_BURST_CAPTURE;
                                        end else begin
                                            burst_issue_group_r <= burst_issue_group_r + 2'd1;
                                            read_state_r        <= RD_BURST_AR;
                                        end
                                    end
                                end
                            end
                            default: begin
                                read_state_r <= RD_BURST_CAPTURE;
                            end
                        endcase
                    end else begin
                        case (read_state_r)
                            RD_IDLE: begin
                                if (rd_req_valid && rd_req_ready) begin
                                    direct_read_addr_r <= hbm_req_remap_byte_addr;
                                    direct_read_tag_r  <= hbm_req_tag;
                                    read_state_r       <= RD_DIRECT_AR;
                                end
                            end
                            RD_DIRECT_AR: begin
                                if (axi_m[ch].ar_ready) begin
                                    read_state_r <= RD_DIRECT_R;
                                end
                            end
                            RD_DIRECT_R: begin
                                if (axi_r_fire) begin
                                    read_state_r <= RD_IDLE;
                                end
                            end
                            default: begin
                                read_state_r <= RD_IDLE;
                            end
                        endcase
                    end
                    // ------------------------------------------------
                    // Write burst state machine
                    // ------------------------------------------------
                    if (burst_write_enable_r) begin
                        case (write_state_r)
                            WR_BURST_CAPTURE: begin
                                if (burst_wr_prefetch_started_r
                                    && (burst_wr_words_captured_r >= burst_wr_window_base_r + {28'd0, burst_wr_window_words})) begin
                                    // Window full (or all words captured) — start issuing
                                    burst_wr_issue_group_r <= '0;
                                    burst_wr_issue_beat_r  <= '0;
                                    write_state_r          <= WR_BURST_AW;
                                end else if (wr_req_valid && wr_burst_req_ready) begin
                                    burst_wr_window_data_r[burst_wr_words_captured_r[2:0]]   <= hbm_req_data;
                                    burst_wr_window_byteen_r[burst_wr_words_captured_r[2:0]] <= hbm_req_byteen;
                                    if (!burst_wr_prefetch_started_r) begin
                                        if (burst_wr_words_captured_r == 32'd0)
                                            burst_wr_dst_base_byte_r <= hbm_req_byte_addr;
                                        burst_wr_prefetch_started_r <= 1'b1;
                                        for (int i = 0; i < READ_BURST_GROUPS; ++i) begin
                                            burst_wr_group_count_r[i]     <= burst_wr_group_words[i];
                                            burst_wr_group_base_addr_r[i] <= calc_remap_byte_addr(
                                                hbm_req_byte_addr + (AXI_ADDR_WIDTH'(i) << 9)
                                            );
                                        end
                                    end
                                    burst_wr_words_captured_r <= burst_wr_words_captured_r + 32'd1;
                                end
                            end
                            WR_BURST_AW: begin
                                if (burst_wr_group_count_r[burst_wr_issue_group_r] == 0) begin
                                    if (burst_wr_issue_group_r == READ_BURST_GROUPS-1) begin
                                        // All groups done for this window
                                        if (burst_wr_words_captured_r < desc_words_r) begin
                                            burst_wr_window_base_r      <= burst_wr_window_base_r + {28'd0, burst_wr_window_words};
                                            burst_wr_prefetch_started_r <= 1'b0;
                                            write_state_r               <= WR_BURST_CAPTURE;
                                        end else begin
                                            write_state_r <= WR_IDLE;
                                        end
                                    end else begin
                                        burst_wr_issue_group_r <= burst_wr_issue_group_r + 2'd1;
                                    end
                                end else if (axi_m[ch].aw_ready) begin
                                    burst_wr_issue_beat_r <= '0;
                                    write_state_r         <= WR_BURST_W;
                                end
                            end
                            WR_BURST_W: begin
                                if (axi_m[ch].w_ready) begin
                                    if (burst_wr_issue_beat_r + 2'd1 >= burst_wr_group_count_r[burst_wr_issue_group_r]) begin
                                        write_state_r <= WR_BURST_B;
                                    end else begin
                                        burst_wr_issue_beat_r <= burst_wr_issue_beat_r + 2'd1;
                                    end
                                end
                            end
                            WR_BURST_B: begin
                                if (axi_m[ch].b_valid) begin
                                    if (burst_wr_issue_group_r == READ_BURST_GROUPS-1) begin
                                        burst_wr_issue_group_r <= '0;
                                        if (burst_wr_words_captured_r < desc_words_r) begin
                                            burst_wr_window_base_r      <= burst_wr_window_base_r + {28'd0, burst_wr_window_words};
                                            burst_wr_prefetch_started_r <= 1'b0;
                                            write_state_r               <= WR_BURST_CAPTURE;
                                        end else begin
                                            write_state_r <= WR_IDLE;
                                        end
                                    end else begin
                                        burst_wr_issue_group_r <= burst_wr_issue_group_r + 2'd1;
                                        write_state_r          <= WR_BURST_AW;
                                    end
                                end
                            end
                            WR_IDLE: begin
                                // All bursts done — stay idle until next cfg_fire
                            end
                            default: begin
                                write_state_r <= WR_BURST_CAPTURE;
                            end
                        endcase
                    end
                end
            end
        end

        // --------------------------------------------------------
        // HBM request/response mux
        // --------------------------------------------------------
        assign hbm_req_ready = hbm_req_rw ? wr_req_ready : rd_req_ready;

        assign hbm_rsp_valid = burst_read_enable_r
                             ? burst_rsp_valid_r
                             : (burst_rsp_active ? axi_m[ch].r_valid : 1'b0);
        assign hbm_rsp_data  = burst_read_enable_r
                             ? burst_rsp_data_r
                             : axi_m[ch].r_data;
        assign hbm_rsp_tag   = burst_read_enable_r
                             ? burst_rsp_tag_r
                             : direct_read_tag_r;

        // --------------------------------------------------------
        // AXI write channel: mux between adapter (non-burst) and local burst logic
        // --------------------------------------------------------
        wire burst_aw_valid_w = (write_state_r == WR_BURST_AW)
                             && (burst_wr_group_count_r[burst_wr_issue_group_r] != 0);

        assign axi_m[ch].aw_valid   = burst_write_enable_r ? burst_aw_valid_w
                                     : m_axi_awvalid_arr[0];
        assign axi_m[ch].aw_addr    = burst_write_enable_r ? burst_wr_group_base_addr_r[burst_wr_issue_group_r]
                                     : m_axi_awaddr_arr[0];
        assign axi_m[ch].aw_id      = burst_write_enable_r ? '0
                                     : AXI_ID_WIDTH'(m_axi_awid_arr[0]);
        assign axi_m[ch].aw_len     = burst_write_enable_r ? (8'(burst_wr_group_count_r[burst_wr_issue_group_r]) - 8'd1)
                                     : m_axi_awlen_arr[0];
        assign axi_m[ch].aw_size    = burst_write_enable_r ? 3'(LOG2_DATA_SIZE)
                                     : m_axi_awsize_arr[0];
        assign axi_m[ch].aw_burst   = burst_write_enable_r ? 2'b01
                                     : m_axi_awburst_arr[0];
        assign axi_m[ch].aw_lock    = burst_write_enable_r ? 1'b0
                                     : m_axi_awlock_arr[0][0];
        assign axi_m[ch].aw_cache   = burst_write_enable_r ? 4'b0000
                                     : m_axi_awcache_arr[0];
        assign axi_m[ch].aw_prot    = burst_write_enable_r ? 3'b000
                                     : m_axi_awprot_arr[0];
        assign axi_m[ch].aw_qos     = burst_write_enable_r ? 4'b0000
                                     : m_axi_awqos_arr[0];
        assign axi_m[ch].aw_region  = burst_write_enable_r ? 4'b0000
                                     : m_axi_awregion_arr[0];
        assign axi_m[ch].aw_atop    = '0;
        assign axi_m[ch].aw_user    = '0;
        assign m_axi_awready_arr[0] = burst_write_enable_r ? 1'b0 : axi_m[ch].aw_ready;

        assign axi_m[ch].w_valid    = burst_write_enable_r ? (write_state_r == WR_BURST_W)
                                     : m_axi_wvalid_arr[0];
        assign axi_m[ch].w_data     = burst_write_enable_r ? burst_wr_window_data_r[burst_wr_word_idx]
                                     : m_axi_wdata_arr[0];
        assign axi_m[ch].w_strb     = burst_write_enable_r ? burst_wr_window_byteen_r[burst_wr_word_idx]
                                     : m_axi_wstrb_arr[0];
        assign axi_m[ch].w_last     = burst_write_enable_r
                                     ? (burst_wr_issue_beat_r + 2'd1 >= burst_wr_group_count_r[burst_wr_issue_group_r])
                                     : m_axi_wlast_arr[0];
        assign axi_m[ch].w_user     = '0;
        assign m_axi_wready_arr[0]  = burst_write_enable_r ? 1'b0 : axi_m[ch].w_ready;

        assign m_axi_bvalid_arr[0]  = burst_write_enable_r ? 1'b0 : axi_m[ch].b_valid;
        assign m_axi_bid_arr[0]     = AXI_TAG_WIDTH'(axi_m[ch].b_id);
        assign m_axi_bresp_arr[0]   = axi_m[ch].b_resp;
        assign axi_m[ch].b_ready    = burst_write_enable_r ? (write_state_r == WR_BURST_B)
                                     : m_axi_bready_arr[0];

        // --------------------------------------------------------
        // AXI read channel comes from the local read bridge
        // --------------------------------------------------------
        assign axi_m[ch].ar_valid   = (read_state_r == RD_DIRECT_AR)
                                   || ((read_state_r == RD_BURST_AR) && (burst_group_count_r[burst_issue_group_r] != 0));
        assign axi_m[ch].ar_addr    = (read_state_r == RD_DIRECT_AR)
                                   ? direct_read_addr_r
                                   : burst_group_base_addr_r[burst_issue_group_r];
        assign axi_m[ch].ar_id      = '0;
        assign axi_m[ch].ar_len     = (read_state_r == RD_DIRECT_AR)
                                   ? 8'd0
                                   : (8'(burst_group_count_r[burst_issue_group_r]) - 8'd1);
        assign axi_m[ch].ar_size    = 3'(LOG2_DATA_SIZE);
        assign axi_m[ch].ar_burst   = 2'b01;
        assign axi_m[ch].ar_lock    = 1'b0;
        assign axi_m[ch].ar_cache   = 4'b0000;
        assign axi_m[ch].ar_prot    = 3'b000;
        assign axi_m[ch].ar_qos     = 4'b0000;
        assign axi_m[ch].ar_region  = 4'b0000;
        assign axi_m[ch].ar_user    = '0;

        assign axi_m[ch].r_ready    = burst_read_enable_r
                                   ? (read_state_r == RD_BURST_R)
                                   : (hbm_rsp_ready && burst_rsp_active);

    end // g_channel

    `UNUSED_PARAM (AXI_USER_WIDTH)

endmodule
