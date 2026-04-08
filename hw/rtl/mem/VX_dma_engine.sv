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
//  Each channel instantiates VX_dma_unit_misal for the 3D strided FSM
//  and VX_axi_adapter for membus-to-AXI conversion.

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

    localparam DATA_SIZE         = DATA_WIDTH / 8;
    localparam LOG2_DATA_SIZE    = `CLOG2(DATA_SIZE);
    // VX_mem_bus_if uses word-addressable addresses
    localparam HBM_ADDR_WIDTH    = MEM_ADDR_WIDTH - LOG2_DATA_SIZE;
    localparam AXI_TAG_WIDTH     = AXI_ID_WIDTH;

    for (genvar ch = 0; ch < NUM_CHANNELS; ++ch) begin : g_channel

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
        //   dcache_bus_if -> hbm_bus_if (will be adapted to AXI)
        //   lmem_bus_if   -> tmem_bus_if[ch] (direct connection)
        // --------------------------------------------------------
        VX_dma_unit_misal #(
            .INSTANCE_ID (INSTANCE_ID)
        ) u_dma_unit (
            .clk            (clk),
            .reset          (reset),
            .cfg_reg_if     (cfg_reg_if[ch]),
            .dcache_bus_if  (hbm_bus_if),
            .lmem_bus_if    (tmem_bus_if[ch]),
            .done_if        (done_if[ch])
        );

        // --------------------------------------------------------
        // Extract flat signals from hbm_bus_if for VX_axi_adapter
        // --------------------------------------------------------
        wire                        hbm_req_valid;
        wire                        hbm_req_rw;
        wire [DATA_SIZE-1:0]        hbm_req_byteen;
        wire [HBM_ADDR_WIDTH-1:0]   hbm_req_addr;
        wire [DATA_WIDTH-1:0]       hbm_req_data;
        wire [TAG_WIDTH-1:0]        hbm_req_tag;
        wire                        hbm_req_ready;

        wire                        hbm_rsp_valid;
        wire [DATA_WIDTH-1:0]       hbm_rsp_data;
        wire [TAG_WIDTH-1:0]        hbm_rsp_tag;
        wire                        hbm_rsp_ready;

        assign hbm_req_valid    = hbm_bus_if.req_valid;
        assign hbm_req_rw       = hbm_bus_if.req_data.rw;
        assign hbm_req_byteen   = hbm_bus_if.req_data.byteen;
        assign hbm_req_addr     = hbm_bus_if.req_data.addr;
        assign hbm_req_data     = hbm_bus_if.req_data.data;
        assign hbm_req_tag      = TAG_WIDTH'(hbm_bus_if.req_data.tag);
        assign hbm_bus_if.req_ready = hbm_req_ready;

        assign hbm_bus_if.rsp_valid     = hbm_rsp_valid;
        assign hbm_bus_if.rsp_data.data = hbm_rsp_data;
        assign hbm_bus_if.rsp_data.tag  = hbm_rsp_tag;
        assign hbm_rsp_ready            = hbm_bus_if.rsp_ready;

        // --------------------------------------------------------
        // VX_axi_adapter: membus flat signals -> AXI flat signals
        //   NUM_PORTS_IN=1, NUM_BANKS_OUT=1
        // --------------------------------------------------------
        wire                            axi_awvalid;
        wire                            axi_awready;
        wire [AXI_ADDR_WIDTH-1:0]       axi_awaddr;
        wire [AXI_TAG_WIDTH-1:0]        axi_awid;
        wire [7:0]                      axi_awlen;
        wire [2:0]                      axi_awsize;
        wire [1:0]                      axi_awburst;
        wire [1:0]                      axi_awlock;
        wire [3:0]                      axi_awcache;
        wire [2:0]                      axi_awprot;
        wire [3:0]                      axi_awqos;
        wire [3:0]                      axi_awregion;

        wire                            axi_wvalid;
        wire                            axi_wready;
        wire [AXI_DATA_WIDTH-1:0]       axi_wdata;
        wire [AXI_DATA_WIDTH/8-1:0]     axi_wstrb;
        wire                            axi_wlast;

        wire                            axi_bvalid;
        wire                            axi_bready;
        wire [AXI_TAG_WIDTH-1:0]        axi_bid;
        wire [1:0]                      axi_bresp;

        wire                            axi_arvalid;
        wire                            axi_arready;
        wire [AXI_ADDR_WIDTH-1:0]       axi_araddr;
        wire [AXI_TAG_WIDTH-1:0]        axi_arid;
        wire [7:0]                      axi_arlen;
        wire [2:0]                      axi_arsize;
        wire [1:0]                      axi_arburst;
        wire [1:0]                      axi_arlock;
        wire [3:0]                      axi_arcache;
        wire [2:0]                      axi_arprot;
        wire [3:0]                      axi_arqos;
        wire [3:0]                      axi_arregion;

        wire                            axi_rvalid;
        wire                            axi_rready;
        wire [AXI_DATA_WIDTH-1:0]       axi_rdata;
        wire                            axi_rlast;
        wire [AXI_TAG_WIDTH-1:0]        axi_rid;
        wire [1:0]                      axi_rresp;

        // Wrap flat signals into unpacked arrays of size 1 for VX_axi_adapter
        wire                        mem_req_valid_arr [1];
        wire                        mem_req_rw_arr    [1];
        wire [DATA_SIZE-1:0]        mem_req_byteen_arr[1];
        wire [HBM_ADDR_WIDTH-1:0]   mem_req_addr_arr  [1];
        wire [DATA_WIDTH-1:0]       mem_req_data_arr  [1];
        wire [TAG_WIDTH-1:0]        mem_req_tag_arr   [1];
        wire                        mem_req_ready_arr [1];
        wire                        mem_rsp_valid_arr [1];
        wire [DATA_WIDTH-1:0]       mem_rsp_data_arr  [1];
        wire [TAG_WIDTH-1:0]        mem_rsp_tag_arr   [1];
        wire                        mem_rsp_ready_arr [1];

        assign mem_req_valid_arr[0]  = hbm_req_valid;
        assign mem_req_rw_arr[0]     = hbm_req_rw;
        assign mem_req_byteen_arr[0] = hbm_req_byteen;
        assign mem_req_addr_arr[0]   = hbm_req_addr;
        assign mem_req_data_arr[0]   = hbm_req_data;
        assign mem_req_tag_arr[0]    = hbm_req_tag;
        assign hbm_req_ready         = mem_req_ready_arr[0];

        assign hbm_rsp_valid = mem_rsp_valid_arr[0];
        assign hbm_rsp_data  = mem_rsp_data_arr[0];
        assign hbm_rsp_tag   = mem_rsp_tag_arr[0];
        assign mem_rsp_ready_arr[0] = hbm_rsp_ready;

        // AXI adapter flat output arrays (size 1)
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
            // Membus request
            .mem_req_valid    (mem_req_valid_arr),
            .mem_req_rw       (mem_req_rw_arr),
            .mem_req_byteen   (mem_req_byteen_arr),
            .mem_req_addr     (mem_req_addr_arr),
            .mem_req_data     (mem_req_data_arr),
            .mem_req_tag      (mem_req_tag_arr),
            .mem_req_ready    (mem_req_ready_arr),
            // Membus response
            .mem_rsp_valid    (mem_rsp_valid_arr),
            .mem_rsp_data     (mem_rsp_data_arr),
            .mem_rsp_tag      (mem_rsp_tag_arr),
            .mem_rsp_ready    (mem_rsp_ready_arr),
            // AXI master
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

        // Extract from unpacked arrays
        assign axi_awvalid  = m_axi_awvalid_arr[0];
        assign axi_awaddr   = m_axi_awaddr_arr[0];
        assign axi_awid     = m_axi_awid_arr[0];
        assign axi_awlen    = m_axi_awlen_arr[0];
        assign axi_awsize   = m_axi_awsize_arr[0];
        assign axi_awburst  = m_axi_awburst_arr[0];
        assign axi_awlock   = m_axi_awlock_arr[0];
        assign axi_awcache  = m_axi_awcache_arr[0];
        assign axi_awprot   = m_axi_awprot_arr[0];
        assign axi_awqos    = m_axi_awqos_arr[0];
        assign axi_awregion = m_axi_awregion_arr[0];
        assign m_axi_awready_arr[0] = axi_awready;

        assign axi_wvalid   = m_axi_wvalid_arr[0];
        assign axi_wdata    = m_axi_wdata_arr[0];
        assign axi_wstrb    = m_axi_wstrb_arr[0];
        assign axi_wlast    = m_axi_wlast_arr[0];
        assign m_axi_wready_arr[0] = axi_wready;

        assign m_axi_bvalid_arr[0]  = axi_bvalid;
        assign m_axi_bid_arr[0]     = axi_bid;
        assign m_axi_bresp_arr[0]   = axi_bresp;
        assign axi_bready           = m_axi_bready_arr[0];

        assign axi_arvalid  = m_axi_arvalid_arr[0];
        assign axi_araddr   = m_axi_araddr_arr[0];
        assign axi_arid     = m_axi_arid_arr[0];
        assign axi_arlen    = m_axi_arlen_arr[0];
        assign axi_arsize   = m_axi_arsize_arr[0];
        assign axi_arburst  = m_axi_arburst_arr[0];
        assign axi_arlock   = m_axi_arlock_arr[0];
        assign axi_arcache  = m_axi_arcache_arr[0];
        assign axi_arprot   = m_axi_arprot_arr[0];
        assign axi_arqos    = m_axi_arqos_arr[0];
        assign axi_arregion = m_axi_arregion_arr[0];
        assign m_axi_arready_arr[0] = axi_arready;

        assign m_axi_rvalid_arr[0]  = axi_rvalid;
        assign m_axi_rdata_arr[0]   = axi_rdata;
        assign m_axi_rlast_arr[0]   = axi_rlast;
        assign m_axi_rid_arr[0]     = axi_rid;
        assign m_axi_rresp_arr[0]   = axi_rresp;
        assign axi_rready           = m_axi_rready_arr[0];

        // --------------------------------------------------------
        // Connect flat AXI signals to AXI_BUS.Master interface
        // Note: AXI_BUS.aw_lock is 1-bit, adapter outputs 2-bit
        // --------------------------------------------------------

        // AW channel
        assign axi_m[ch].aw_valid   = axi_awvalid;
        assign axi_m[ch].aw_addr    = axi_awaddr;
        assign axi_m[ch].aw_id      = AXI_ID_WIDTH'(axi_awid);
        assign axi_m[ch].aw_len     = axi_awlen;
        assign axi_m[ch].aw_size    = axi_awsize;
        assign axi_m[ch].aw_burst   = axi_awburst;
        assign axi_m[ch].aw_lock    = axi_awlock[0];
        assign axi_m[ch].aw_cache   = axi_awcache;
        assign axi_m[ch].aw_prot    = axi_awprot;
        assign axi_m[ch].aw_qos     = axi_awqos;
        assign axi_m[ch].aw_region  = axi_awregion;
        assign axi_m[ch].aw_atop    = '0;
        assign axi_m[ch].aw_user    = '0;
        assign axi_awready          = axi_m[ch].aw_ready;

        // W channel
        assign axi_m[ch].w_valid    = axi_wvalid;
        assign axi_m[ch].w_data     = axi_wdata;
        assign axi_m[ch].w_strb     = axi_wstrb;
        assign axi_m[ch].w_last     = axi_wlast;
        assign axi_m[ch].w_user     = '0;
        assign axi_wready           = axi_m[ch].w_ready;

        // B channel
        assign axi_bvalid           = axi_m[ch].b_valid;
        assign axi_bid              = AXI_TAG_WIDTH'(axi_m[ch].b_id);
        assign axi_bresp            = axi_m[ch].b_resp;
        assign axi_m[ch].b_ready    = axi_bready;

        // AR channel
        assign axi_m[ch].ar_valid   = axi_arvalid;
        assign axi_m[ch].ar_addr    = axi_araddr;
        assign axi_m[ch].ar_id      = AXI_ID_WIDTH'(axi_arid);
        assign axi_m[ch].ar_len     = axi_arlen;
        assign axi_m[ch].ar_size    = axi_arsize;
        assign axi_m[ch].ar_burst   = axi_arburst;
        assign axi_m[ch].ar_lock    = axi_arlock[0];
        assign axi_m[ch].ar_cache   = axi_arcache;
        assign axi_m[ch].ar_prot    = axi_arprot;
        assign axi_m[ch].ar_qos     = axi_arqos;
        assign axi_m[ch].ar_region  = axi_arregion;
        assign axi_m[ch].ar_user    = '0;
        assign axi_arready          = axi_m[ch].ar_ready;

        // R channel
        assign axi_rvalid           = axi_m[ch].r_valid;
        assign axi_rdata            = axi_m[ch].r_data;
        assign axi_rid              = AXI_TAG_WIDTH'(axi_m[ch].r_id);
        assign axi_rlast            = axi_m[ch].r_last;
        assign axi_rresp            = axi_m[ch].r_resp;
        assign axi_m[ch].r_ready    = axi_rready;

    end // g_channel

endmodule
