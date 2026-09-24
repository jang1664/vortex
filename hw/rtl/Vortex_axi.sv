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

`include "axi/typedef.svh"
`include "axi/assign.svh"

module Vortex_axi import VX_gpu_pkg::*; #(
    parameter AXI_DATA_WIDTH  = `PLATFORM_MEMORY_DATA_SIZE * 8,
    parameter AXI_ADDR_WIDTH  = `PLATFORM_MEMORY_ADDR_WIDTH,
    parameter AXI_TID_WIDTH   = VX_MEM_TAG_WIDTH,
    parameter NUM_HBM_PORTS   = `NUM_HBM_PORTS,
    parameter AXI_DMA_ID_WIDTH = 8
)(
    `SCOPE_IO_DECL

    // Clock
    input  wire                         clk,
    input  wire                         reset,

    // HBM AXI output ports (one per HBM channel)
    // AXI write request address channel
    output wire                         m_axi_awvalid [NUM_HBM_PORTS],
    input wire                          m_axi_awready [NUM_HBM_PORTS],
    output wire [AXI_ADDR_WIDTH-1:0]    m_axi_awaddr [NUM_HBM_PORTS],
    output wire [AXI_TID_WIDTH-1:0]     m_axi_awid [NUM_HBM_PORTS],
    output wire [7:0]                   m_axi_awlen [NUM_HBM_PORTS],
    output wire [2:0]                   m_axi_awsize [NUM_HBM_PORTS],
    output wire [1:0]                   m_axi_awburst [NUM_HBM_PORTS],
    output wire [1:0]                   m_axi_awlock [NUM_HBM_PORTS],
    output wire [3:0]                   m_axi_awcache [NUM_HBM_PORTS],
    output wire [2:0]                   m_axi_awprot [NUM_HBM_PORTS],
    output wire [3:0]                   m_axi_awqos [NUM_HBM_PORTS],
    output wire [3:0]                   m_axi_awregion [NUM_HBM_PORTS],

    // AXI write request data channel
    output wire                         m_axi_wvalid [NUM_HBM_PORTS],
    input wire                          m_axi_wready [NUM_HBM_PORTS],
    output wire [AXI_DATA_WIDTH-1:0]    m_axi_wdata [NUM_HBM_PORTS],
    output wire [AXI_DATA_WIDTH/8-1:0]  m_axi_wstrb [NUM_HBM_PORTS],
    output wire                         m_axi_wlast [NUM_HBM_PORTS],

    // AXI write response channel
    input wire                          m_axi_bvalid [NUM_HBM_PORTS],
    output wire                         m_axi_bready [NUM_HBM_PORTS],
    input wire [AXI_TID_WIDTH-1:0]      m_axi_bid [NUM_HBM_PORTS],
    input wire [1:0]                    m_axi_bresp [NUM_HBM_PORTS],

    // AXI read request channel
    output wire                         m_axi_arvalid [NUM_HBM_PORTS],
    input wire                          m_axi_arready [NUM_HBM_PORTS],
    output wire [AXI_ADDR_WIDTH-1:0]    m_axi_araddr [NUM_HBM_PORTS],
    output wire [AXI_TID_WIDTH-1:0]     m_axi_arid [NUM_HBM_PORTS],
    output wire [7:0]                   m_axi_arlen [NUM_HBM_PORTS],
    output wire [2:0]                   m_axi_arsize [NUM_HBM_PORTS],
    output wire [1:0]                   m_axi_arburst [NUM_HBM_PORTS],
    output wire [1:0]                   m_axi_arlock [NUM_HBM_PORTS],
    output wire [3:0]                   m_axi_arcache [NUM_HBM_PORTS],
    output wire [2:0]                   m_axi_arprot [NUM_HBM_PORTS],
    output wire [3:0]                   m_axi_arqos [NUM_HBM_PORTS],
    output wire [3:0]                   m_axi_arregion [NUM_HBM_PORTS],

    // AXI read response channel
    input wire                          m_axi_rvalid [NUM_HBM_PORTS],
    output wire                         m_axi_rready [NUM_HBM_PORTS],
    input wire [AXI_DATA_WIDTH-1:0]     m_axi_rdata [NUM_HBM_PORTS],
    input wire                          m_axi_rlast [NUM_HBM_PORTS],
    input wire [AXI_TID_WIDTH-1:0]      m_axi_rid [NUM_HBM_PORTS],
    input wire [1:0]                    m_axi_rresp [NUM_HBM_PORTS],

    // DCR write request
    input  wire                         dcr_wr_valid,
    input  wire [VX_DCR_ADDR_WIDTH-1:0] dcr_wr_addr,
    input  wire [VX_DCR_DATA_WIDTH-1:0] dcr_wr_data,

`ifdef ENABLE_HW_DEBUG_PC
	    output wire                         hw_debug_pc_valid [HW_DEBUG_NUM_PC_SOURCES],
	    output wire [HW_DEBUG_CORE_ID_WIDTH-1:0] hw_debug_pc_core_id [HW_DEBUG_NUM_PC_SOURCES],
		    output wire [NW_WIDTH-1:0]          hw_debug_pc_wid [HW_DEBUG_NUM_PC_SOURCES],
		    output wire [`XLEN-1:0]             hw_debug_pc [HW_DEBUG_NUM_PC_SOURCES],
`endif
`ifdef ENABLE_HW_DEBUG_CORE
		    output core_pipeline_debug_t        core_pipeline_debug [HW_DEBUG_NUM_PC_SOURCES],
`endif
`ifdef ENABLE_HW_DEBUG_GEMM
            output gemm_unit_debug_t           gemm_unit_debug [HW_DEBUG_NUM_PC_SOURCES],
`endif
`ifdef ENABLE_HW_DEBUG_CACHE
		    output cache_debug_t                cache_debug [HW_DEBUG_CACHE_NUM_SOURCES],
`endif

    // Status
    output wire                         busy,
    output wire                         cache_drain
);

    ///////////////////////////////////////////////////////////////////////////
    // Parameters
    ///////////////////////////////////////////////////////////////////////////

    localparam DST_LDATAW = `CLOG2(AXI_DATA_WIDTH);
    localparam SRC_LDATAW = `CLOG2(VX_MEM_DATA_WIDTH);
    localparam SUB_LDATAW = DST_LDATAW - SRC_LDATAW;
    localparam VX_MEM_TAG_A_WIDTH  = VX_MEM_TAG_WIDTH + `MAX(SUB_LDATAW, 0);
    localparam VX_MEM_ADDR_A_WIDTH = VX_MEM_ADDR_WIDTH - SUB_LDATAW;

    localparam NUM_DMA_TOTAL = `NUM_CORES * `NUM_DMA_CHANNELS;
    localparam HBM_PORTS_PER_DMA = NUM_HBM_PORTS / `NUM_DMA_CHANNELS;
    localparam DMA_SEL_SHIFT = $clog2(`NUM_DMA_CHANNELS);
    localparam DMA_PORT_SLOT_BITS = (HBM_PORTS_PER_DMA > 1)
                                     ? $clog2(HBM_PORTS_PER_DMA) : 1;
    // One LSU input plus the statically-owned DMA channel from every core.
    localparam NUM_MUX_INPUTS = 1 + `NUM_CORES;

    // LSU AXI adapter outputs a single bank with TID width = AXI_TID_WIDTH
    // The demux does not change the ID width
    // The mux widens the ID by clog2(NUM_MUX_INPUTS)
    localparam SLV_ID_WIDTH = AXI_DMA_ID_WIDTH;
    localparam MUX_IDX_BITS = `CLOG2(NUM_MUX_INPUTS);
    localparam MST_ID_WIDTH = SLV_ID_WIDTH + MUX_IDX_BITS;

    // For the LSU path through the demux, we need its ID to fit in SLV_ID_WIDTH
    // The VX_axi_adapter TID width may differ; we use SLV_ID_WIDTH for the mux slave side
    localparam LSU_AXI_TID_WIDTH = SLV_ID_WIDTH;

    // Address select bits for demux: route based on address bits.
    // After VX_mem_remap below, the HBM bank index sits at REMAP_BANK_SHIFT.
    localparam HBM_SEL_BITS = `CLOG2(NUM_HBM_PORTS);
    localparam REMAP_BANK_SHIFT = `PLATFORM_MEMORY_ADDR_WIDTH - `CLOG2(`PLATFORM_MEMORY_NUM_BANKS);

    initial begin
        if ((`NUM_TMEM_BANKS < 1)
         || ((`NUM_TMEM_BANKS & (`NUM_TMEM_BANKS - 1)) != 0))
            $fatal(1, "NUM_TMEM_BANKS(%0d) must be a positive power of two", `NUM_TMEM_BANKS);
        if ((`NUM_DMA_CHANNELS < 1)
         || ((`NUM_DMA_CHANNELS & (`NUM_DMA_CHANNELS - 1)) != 0))
            $fatal(1, "NUM_DMA_CHANNELS(%0d) must be a positive power of two", `NUM_DMA_CHANNELS);
        if ((NUM_HBM_PORTS < 1)
         || ((NUM_HBM_PORTS & (NUM_HBM_PORTS - 1)) != 0))
            $fatal(1, "NUM_HBM_PORTS(%0d) must be a positive power of two", NUM_HBM_PORTS);
        if (`NUM_DMA_CHANNELS > `NUM_TMEM_BANKS)
            $fatal(1, "NUM_DMA_CHANNELS(%0d) exceeds NUM_TMEM_BANKS(%0d)",
                   `NUM_DMA_CHANNELS, `NUM_TMEM_BANKS);
        if (`NUM_DMA_CHANNELS > NUM_HBM_PORTS)
            $fatal(1, "NUM_DMA_CHANNELS(%0d) exceeds NUM_HBM_PORTS(%0d)",
                   `NUM_DMA_CHANNELS, NUM_HBM_PORTS);
        if ((`PLATFORM_MEMORY_NUM_BANKS % NUM_HBM_PORTS) != 0)
            $fatal(1, "PLATFORM_MEMORY_NUM_BANKS(%0d) is not divisible by NUM_HBM_PORTS(%0d)",
                   `PLATFORM_MEMORY_NUM_BANKS, NUM_HBM_PORTS);
`ifdef PLATFORM_MEMORY_NUM_PORTS
        if (`PLATFORM_MEMORY_NUM_PORTS != NUM_HBM_PORTS)
            $fatal(1, "legacy PLATFORM_MEMORY_NUM_PORTS(%0d) must match NUM_HBM_PORTS(%0d)",
                   `PLATFORM_MEMORY_NUM_PORTS, NUM_HBM_PORTS);
`endif
    end

    ///////////////////////////////////////////////////////////////////////////
    // AXI struct typedefs for axi_mux and axi_demux
    ///////////////////////////////////////////////////////////////////////////

    typedef logic [AXI_ADDR_WIDTH-1:0]   axi_addr_t;
    typedef logic [AXI_DATA_WIDTH-1:0]   axi_data_t;
    typedef logic [AXI_DATA_WIDTH/8-1:0] axi_strb_t;
    typedef logic                         axi_user_t;

    // Slave-side types (input to mux, output of demux)
    typedef logic [SLV_ID_WIDTH-1:0]     slv_id_t;
    `AXI_TYPEDEF_ALL(slv_axi, axi_addr_t, slv_id_t, axi_data_t, axi_strb_t, axi_user_t)

    // Master-side types (output of mux, wider ID)
    typedef logic [MST_ID_WIDTH-1:0]     mst_id_t;
    `AXI_TYPEDEF_ALL(mst_axi, axi_addr_t, mst_id_t, axi_data_t, axi_strb_t, axi_user_t)

    ///////////////////////////////////////////////////////////////////////////
    // Vortex core instantiation
    ///////////////////////////////////////////////////////////////////////////

    wire                            mem_req_valid [VX_MEM_PORTS];
    wire                            mem_req_rw [VX_MEM_PORTS];
    wire [VX_MEM_BYTEEN_WIDTH-1:0]  mem_req_byteen [VX_MEM_PORTS];
    wire [VX_MEM_ADDR_WIDTH-1:0]    mem_req_addr [VX_MEM_PORTS];
    wire [VX_MEM_DATA_WIDTH-1:0]    mem_req_data [VX_MEM_PORTS];
    wire [VX_MEM_TAG_WIDTH-1:0]     mem_req_tag [VX_MEM_PORTS];
    wire                            mem_req_ready [VX_MEM_PORTS];

    wire                            mem_rsp_valid [VX_MEM_PORTS];
    wire [VX_MEM_DATA_WIDTH-1:0]    mem_rsp_data [VX_MEM_PORTS];
    wire [VX_MEM_TAG_WIDTH-1:0]     mem_rsp_tag [VX_MEM_PORTS];
    wire                            mem_rsp_ready [VX_MEM_PORTS];
    wire                            vortex_cache_drain;

    // DMA AXI interfaces from all cores
    AXI_BUS #(
        .AXI_ADDR_WIDTH (AXI_ADDR_WIDTH),
        .AXI_DATA_WIDTH (AXI_DATA_WIDTH),
        .AXI_ID_WIDTH   (AXI_DMA_ID_WIDTH),
        .AXI_USER_WIDTH (1)
    ) dma_axi_m [NUM_DMA_TOTAL] ();

    `SCOPE_IO_SWITCH (1);

    Vortex vortex (
        `SCOPE_IO_BIND  (0)

        .clk            (clk),
        .reset          (reset),

        .mem_req_valid  (mem_req_valid),
        .mem_req_rw     (mem_req_rw),
        .mem_req_byteen (mem_req_byteen),
        .mem_req_addr   (mem_req_addr),
        .mem_req_data   (mem_req_data),
        .mem_req_tag    (mem_req_tag),
        .mem_req_ready  (mem_req_ready),

        .mem_rsp_valid  (mem_rsp_valid),
        .mem_rsp_data   (mem_rsp_data),
        .mem_rsp_tag    (mem_rsp_tag),
        .mem_rsp_ready  (mem_rsp_ready),

        .dma_axi_m      (dma_axi_m),

        .dcr_wr_valid   (dcr_wr_valid),
        .dcr_wr_addr    (dcr_wr_addr),
        .dcr_wr_data    (dcr_wr_data),

    `ifdef ENABLE_HW_DEBUG_PC
        .hw_debug_pc_valid   (hw_debug_pc_valid),
	        .hw_debug_pc_core_id (hw_debug_pc_core_id),
		        .hw_debug_pc_wid     (hw_debug_pc_wid),
		        .hw_debug_pc         (hw_debug_pc),
    `endif
    `ifdef ENABLE_HW_DEBUG_CORE
		        .core_pipeline_debug (core_pipeline_debug),
    `endif
    `ifdef ENABLE_HW_DEBUG_GEMM
                .gemm_unit_debug     (gemm_unit_debug),
    `endif
    `ifdef ENABLE_HW_DEBUG_CACHE
		        .cache_debug         (cache_debug),
		    `endif

        .busy           (busy),
        .cache_drain    (vortex_cache_drain)
    );

    ///////////////////////////////////////////////////////////////////////////
    // LSU path: data adapter + AXI adapter (single bank output)
    ///////////////////////////////////////////////////////////////////////////

    wire                            mem_req_valid_a [VX_MEM_PORTS];
    wire                            mem_req_rw_a [VX_MEM_PORTS];
    wire [(AXI_DATA_WIDTH/8)-1:0]   mem_req_byteen_a [VX_MEM_PORTS];
    wire [VX_MEM_ADDR_A_WIDTH-1:0]  mem_req_addr_a [VX_MEM_PORTS];
    wire [AXI_DATA_WIDTH-1:0]       mem_req_data_a [VX_MEM_PORTS];
    wire [VX_MEM_TAG_A_WIDTH-1:0]   mem_req_tag_a [VX_MEM_PORTS];
    wire                            mem_req_ready_a [VX_MEM_PORTS];

    wire                            mem_rsp_valid_a [VX_MEM_PORTS];
    wire [AXI_DATA_WIDTH-1:0]       mem_rsp_data_a [VX_MEM_PORTS];
    wire [VX_MEM_TAG_A_WIDTH-1:0]   mem_rsp_tag_a [VX_MEM_PORTS];
    wire                            mem_rsp_ready_a [VX_MEM_PORTS];

    // Adjust memory data width to match AXI interface
    for (genvar i = 0; i < VX_MEM_PORTS; i++) begin : g_mem_adapter
        VX_mem_data_adapter #(
            .SRC_DATA_WIDTH (VX_MEM_DATA_WIDTH),
            .DST_DATA_WIDTH (AXI_DATA_WIDTH),
            .SRC_ADDR_WIDTH (VX_MEM_ADDR_WIDTH),
            .DST_ADDR_WIDTH (VX_MEM_ADDR_A_WIDTH),
            .SRC_TAG_WIDTH  (VX_MEM_TAG_WIDTH),
            .DST_TAG_WIDTH  (VX_MEM_TAG_A_WIDTH),
            .REQ_OUT_BUF    (0),
            .RSP_OUT_BUF    (0)
        ) mem_data_adapter (
            .clk                (clk),
            .reset              (reset),

            .mem_req_valid_in   (mem_req_valid[i]),
            .mem_req_addr_in    (mem_req_addr[i]),
            .mem_req_rw_in      (mem_req_rw[i]),
            .mem_req_byteen_in  (mem_req_byteen[i]),
            .mem_req_data_in    (mem_req_data[i]),
            .mem_req_tag_in     (mem_req_tag[i]),
            .mem_req_ready_in   (mem_req_ready[i]),

            .mem_rsp_valid_in   (mem_rsp_valid[i]),
            .mem_rsp_data_in    (mem_rsp_data[i]),
            .mem_rsp_tag_in     (mem_rsp_tag[i]),
            .mem_rsp_ready_in   (mem_rsp_ready[i]),

            .mem_req_valid_out  (mem_req_valid_a[i]),
            .mem_req_addr_out   (mem_req_addr_a[i]),
            .mem_req_rw_out     (mem_req_rw_a[i]),
            .mem_req_byteen_out (mem_req_byteen_a[i]),
            .mem_req_data_out   (mem_req_data_a[i]),
            .mem_req_tag_out    (mem_req_tag_a[i]),
            .mem_req_ready_out  (mem_req_ready_a[i]),

            .mem_rsp_valid_out  (mem_rsp_valid_a[i]),
            .mem_rsp_data_out   (mem_rsp_data_a[i]),
            .mem_rsp_tag_out    (mem_rsp_tag_a[i]),
            .mem_rsp_ready_out  (mem_rsp_ready_a[i])
        );
    end

    // LSU AXI adapter: single bank output (flat signals)
    wire                            lsu_axi_awvalid;
    wire                            lsu_axi_awready;
    wire [AXI_ADDR_WIDTH-1:0]       lsu_axi_awaddr;
    wire [LSU_AXI_TID_WIDTH-1:0]    lsu_axi_awid;
    wire [7:0]                      lsu_axi_awlen;
    wire [2:0]                      lsu_axi_awsize;
    wire [1:0]                      lsu_axi_awburst;
    wire [1:0]                      lsu_axi_awlock;
    wire [3:0]                      lsu_axi_awcache;
    wire [2:0]                      lsu_axi_awprot;
    wire [3:0]                      lsu_axi_awqos;
    wire [3:0]                      lsu_axi_awregion;

    wire                            lsu_axi_wvalid;
    wire                            lsu_axi_wready;
    wire [AXI_DATA_WIDTH-1:0]       lsu_axi_wdata;
    wire [AXI_DATA_WIDTH/8-1:0]     lsu_axi_wstrb;
    wire                            lsu_axi_wlast;

    wire                            lsu_axi_bvalid;
    wire                            lsu_axi_bready;
    wire [LSU_AXI_TID_WIDTH-1:0]    lsu_axi_bid;
    wire [1:0]                      lsu_axi_bresp;

    wire                            lsu_axi_arvalid;
    wire                            lsu_axi_arready;
    wire [AXI_ADDR_WIDTH-1:0]       lsu_axi_araddr;
    wire [LSU_AXI_TID_WIDTH-1:0]    lsu_axi_arid;
    wire [7:0]                      lsu_axi_arlen;
    wire [2:0]                      lsu_axi_arsize;
    wire [1:0]                      lsu_axi_arburst;
    wire [1:0]                      lsu_axi_arlock;
    wire [3:0]                      lsu_axi_arcache;
    wire [2:0]                      lsu_axi_arprot;
    wire [3:0]                      lsu_axi_arqos;
    wire [3:0]                      lsu_axi_arregion;

    wire                            lsu_axi_rvalid;
    wire                            lsu_axi_rready;
    wire [AXI_DATA_WIDTH-1:0]       lsu_axi_rdata;
    wire                            lsu_axi_rlast;
    wire [LSU_AXI_TID_WIDTH-1:0]    lsu_axi_rid;
    wire [1:0]                      lsu_axi_rresp;

    // Wrap flat signals in unpacked arrays for VX_axi_adapter
    wire                            lsu_axi_awvalid_arr [1];
    wire                            lsu_axi_awready_arr [1];
    wire [AXI_ADDR_WIDTH-1:0]       lsu_axi_awaddr_arr [1];
    wire [LSU_AXI_TID_WIDTH-1:0]    lsu_axi_awid_arr [1];
    wire [7:0]                      lsu_axi_awlen_arr [1];
    wire [2:0]                      lsu_axi_awsize_arr [1];
    wire [1:0]                      lsu_axi_awburst_arr [1];
    wire [1:0]                      lsu_axi_awlock_arr [1];
    wire [3:0]                      lsu_axi_awcache_arr [1];
    wire [2:0]                      lsu_axi_awprot_arr [1];
    wire [3:0]                      lsu_axi_awqos_arr [1];
    wire [3:0]                      lsu_axi_awregion_arr [1];

    wire                            lsu_axi_wvalid_arr [1];
    wire                            lsu_axi_wready_arr [1];
    wire [AXI_DATA_WIDTH-1:0]       lsu_axi_wdata_arr [1];
    wire [AXI_DATA_WIDTH/8-1:0]     lsu_axi_wstrb_arr [1];
    wire                            lsu_axi_wlast_arr [1];

    wire                            lsu_axi_bvalid_arr [1];
    wire                            lsu_axi_bready_arr [1];
    wire [LSU_AXI_TID_WIDTH-1:0]    lsu_axi_bid_arr [1];
    wire [1:0]                      lsu_axi_bresp_arr [1];

    wire                            lsu_axi_arvalid_arr [1];
    wire                            lsu_axi_arready_arr [1];
    wire [AXI_ADDR_WIDTH-1:0]       lsu_axi_araddr_arr [1];
    wire [LSU_AXI_TID_WIDTH-1:0]    lsu_axi_arid_arr [1];
    wire [7:0]                      lsu_axi_arlen_arr [1];
    wire [2:0]                      lsu_axi_arsize_arr [1];
    wire [1:0]                      lsu_axi_arburst_arr [1];
    wire [1:0]                      lsu_axi_arlock_arr [1];
    wire [3:0]                      lsu_axi_arcache_arr [1];
    wire [2:0]                      lsu_axi_arprot_arr [1];
    wire [3:0]                      lsu_axi_arqos_arr [1];
    wire [3:0]                      lsu_axi_arregion_arr [1];

    wire                            lsu_axi_rvalid_arr [1];
    wire                            lsu_axi_rready_arr [1];
    wire [AXI_DATA_WIDTH-1:0]       lsu_axi_rdata_arr [1];
    wire                            lsu_axi_rlast_arr [1];
    wire [LSU_AXI_TID_WIDTH-1:0]    lsu_axi_rid_arr [1];
    wire [1:0]                      lsu_axi_rresp_arr [1];

    VX_axi_adapter #(
        .DATA_WIDTH     (AXI_DATA_WIDTH),
        .ADDR_WIDTH_IN  (VX_MEM_ADDR_A_WIDTH),
        .ADDR_WIDTH_OUT (AXI_ADDR_WIDTH),
        .TAG_WIDTH_IN   (VX_MEM_TAG_A_WIDTH),
        .TAG_WIDTH_OUT  (LSU_AXI_TID_WIDTH),
        .NUM_PORTS_IN   (VX_MEM_PORTS),
        .NUM_BANKS_OUT  (1),
        .INTERLEAVE     (`PLATFORM_MEMORY_INTERLEAVE),
        .REQ_OUT_BUF    ((VX_MEM_PORTS > 1) ? 2 : 0),
        .RSP_OUT_BUF    ((VX_MEM_PORTS > 1) ? 2 : 0)
    ) axi_adapter (
        .clk            (clk),
        .reset          (reset),

        .mem_req_valid  (mem_req_valid_a),
        .mem_req_rw     (mem_req_rw_a),
        .mem_req_byteen (mem_req_byteen_a),
        .mem_req_addr   (mem_req_addr_a),
        .mem_req_data   (mem_req_data_a),
        .mem_req_tag    (mem_req_tag_a),
        .mem_req_ready  (mem_req_ready_a),

        .mem_rsp_valid  (mem_rsp_valid_a),
        .mem_rsp_data   (mem_rsp_data_a),
        .mem_rsp_tag    (mem_rsp_tag_a),
        .mem_rsp_ready  (mem_rsp_ready_a),

        .m_axi_awvalid  (lsu_axi_awvalid_arr),
        .m_axi_awready  (lsu_axi_awready_arr),
        .m_axi_awaddr   (lsu_axi_awaddr_arr),
        .m_axi_awid     (lsu_axi_awid_arr),
        .m_axi_awlen    (lsu_axi_awlen_arr),
        .m_axi_awsize   (lsu_axi_awsize_arr),
        .m_axi_awburst  (lsu_axi_awburst_arr),
        .m_axi_awlock   (lsu_axi_awlock_arr),
        .m_axi_awcache  (lsu_axi_awcache_arr),
        .m_axi_awprot   (lsu_axi_awprot_arr),
        .m_axi_awqos    (lsu_axi_awqos_arr),
        .m_axi_awregion (lsu_axi_awregion_arr),

        .m_axi_wvalid   (lsu_axi_wvalid_arr),
        .m_axi_wready   (lsu_axi_wready_arr),
        .m_axi_wdata    (lsu_axi_wdata_arr),
        .m_axi_wstrb    (lsu_axi_wstrb_arr),
        .m_axi_wlast    (lsu_axi_wlast_arr),

        .m_axi_bvalid   (lsu_axi_bvalid_arr),
        .m_axi_bready   (lsu_axi_bready_arr),
        .m_axi_bid      (lsu_axi_bid_arr),
        .m_axi_bresp    (lsu_axi_bresp_arr),

        .m_axi_arvalid  (lsu_axi_arvalid_arr),
        .m_axi_arready  (lsu_axi_arready_arr),
        .m_axi_araddr   (lsu_axi_araddr_arr),
        .m_axi_arid     (lsu_axi_arid_arr),
        .m_axi_arlen    (lsu_axi_arlen_arr),
        .m_axi_arsize   (lsu_axi_arsize_arr),
        .m_axi_arburst  (lsu_axi_arburst_arr),
        .m_axi_arlock   (lsu_axi_arlock_arr),
        .m_axi_arcache  (lsu_axi_arcache_arr),
        .m_axi_arprot   (lsu_axi_arprot_arr),
        .m_axi_arqos    (lsu_axi_arqos_arr),
        .m_axi_arregion (lsu_axi_arregion_arr),

        .m_axi_rvalid   (lsu_axi_rvalid_arr),
        .m_axi_rready   (lsu_axi_rready_arr),
        .m_axi_rdata    (lsu_axi_rdata_arr),
        .m_axi_rlast    (lsu_axi_rlast_arr),
        .m_axi_rid      (lsu_axi_rid_arr),
        .m_axi_rresp    (lsu_axi_rresp_arr)
    );

    // Unpack array[1] to scalar signals
    assign lsu_axi_awvalid   = lsu_axi_awvalid_arr[0];
    assign lsu_axi_awready_arr[0] = lsu_axi_awready;
    assign lsu_axi_awaddr    = lsu_axi_awaddr_arr[0];
    assign lsu_axi_awid      = lsu_axi_awid_arr[0];
    assign lsu_axi_awlen     = lsu_axi_awlen_arr[0];
    assign lsu_axi_awsize    = lsu_axi_awsize_arr[0];
    assign lsu_axi_awburst   = lsu_axi_awburst_arr[0];
    assign lsu_axi_awlock    = lsu_axi_awlock_arr[0];
    assign lsu_axi_awcache   = lsu_axi_awcache_arr[0];
    assign lsu_axi_awprot    = lsu_axi_awprot_arr[0];
    assign lsu_axi_awqos     = lsu_axi_awqos_arr[0];
    assign lsu_axi_awregion  = lsu_axi_awregion_arr[0];

    assign lsu_axi_wvalid    = lsu_axi_wvalid_arr[0];
    assign lsu_axi_wready_arr[0] = lsu_axi_wready;
    assign lsu_axi_wdata     = lsu_axi_wdata_arr[0];
    assign lsu_axi_wstrb     = lsu_axi_wstrb_arr[0];
    assign lsu_axi_wlast     = lsu_axi_wlast_arr[0];

    assign lsu_axi_bvalid_arr[0] = lsu_axi_bvalid;
    assign lsu_axi_bready    = lsu_axi_bready_arr[0];
    assign lsu_axi_bid_arr[0] = lsu_axi_bid;
    assign lsu_axi_bresp_arr[0] = lsu_axi_bresp;

    assign lsu_axi_arvalid   = lsu_axi_arvalid_arr[0];
    assign lsu_axi_arready_arr[0] = lsu_axi_arready;
    assign lsu_axi_araddr    = lsu_axi_araddr_arr[0];
    assign lsu_axi_arid      = lsu_axi_arid_arr[0];
    assign lsu_axi_arlen     = lsu_axi_arlen_arr[0];
    assign lsu_axi_arsize    = lsu_axi_arsize_arr[0];
    assign lsu_axi_arburst   = lsu_axi_arburst_arr[0];
    assign lsu_axi_arlock    = lsu_axi_arlock_arr[0];
    assign lsu_axi_arcache   = lsu_axi_arcache_arr[0];
    assign lsu_axi_arprot    = lsu_axi_arprot_arr[0];
    assign lsu_axi_arqos     = lsu_axi_arqos_arr[0];
    assign lsu_axi_arregion  = lsu_axi_arregion_arr[0];

    assign lsu_axi_rvalid_arr[0] = lsu_axi_rvalid;
    assign lsu_axi_rready    = lsu_axi_rready_arr[0];
    assign lsu_axi_rdata_arr[0] = lsu_axi_rdata;
    assign lsu_axi_rlast_arr[0] = lsu_axi_rlast;
    assign lsu_axi_rid_arr[0] = lsu_axi_rid;
    assign lsu_axi_rresp_arr[0] = lsu_axi_rresp;

    ///////////////////////////////////////////////////////////////////////////
    // Remap LSU AXI addresses to HBM contiguous layout before demux.
    // Together with the DMA path's internal VX_mem_remap, this unifies the
    // post-remap coordinate system on the AXI bus so the sim inverse
    // transform (xrt_sim_vcs::remap_to_sw_addr) can recover sw_addr.
    ///////////////////////////////////////////////////////////////////////////

    wire [AXI_ADDR_WIDTH-1:0] lsu_axi_awaddr_remapped;
    wire [AXI_ADDR_WIDTH-1:0] lsu_axi_araddr_remapped;

    VX_mem_remap #(
        .ADDR_W     (AXI_ADDR_WIDTH),
        .NUM_PORTS  (NUM_HBM_PORTS),
        .BANK_SHIFT (REMAP_BANK_SHIFT)
    ) u_lsu_aw_remap (
        .m_address   (lsu_axi_awaddr),
        .hbm_address (lsu_axi_awaddr_remapped)
    );

    VX_mem_remap #(
        .ADDR_W     (AXI_ADDR_WIDTH),
        .NUM_PORTS  (NUM_HBM_PORTS),
        .BANK_SHIFT (REMAP_BANK_SHIFT)
    ) u_lsu_ar_remap (
        .m_address   (lsu_axi_araddr),
        .hbm_address (lsu_axi_araddr_remapped)
    );

    ///////////////////////////////////////////////////////////////////////////
    // Convert LSU flat AXI signals to struct for demux
    ///////////////////////////////////////////////////////////////////////////

    slv_axi_req_t  lsu_axi_req;
    slv_axi_resp_t lsu_axi_resp;

    // Pack LSU AXI signals into request struct
    always_comb begin
        lsu_axi_req = '0;
        // AW channel
        lsu_axi_req.aw.id     = lsu_axi_awid;
        lsu_axi_req.aw.addr   = lsu_axi_awaddr_remapped;
        lsu_axi_req.aw.len    = lsu_axi_awlen;
        lsu_axi_req.aw.size   = lsu_axi_awsize;
        lsu_axi_req.aw.burst  = lsu_axi_awburst;
        lsu_axi_req.aw.lock   = lsu_axi_awlock[0];
        lsu_axi_req.aw.cache  = lsu_axi_awcache;
        lsu_axi_req.aw.prot   = lsu_axi_awprot;
        lsu_axi_req.aw.qos    = lsu_axi_awqos;
        lsu_axi_req.aw.region = lsu_axi_awregion;
        lsu_axi_req.aw.atop   = '0;
        lsu_axi_req.aw.user   = '0;
        lsu_axi_req.aw_valid  = lsu_axi_awvalid;
        // W channel
        lsu_axi_req.w.data    = lsu_axi_wdata;
        lsu_axi_req.w.strb    = lsu_axi_wstrb;
        lsu_axi_req.w.last    = lsu_axi_wlast;
        lsu_axi_req.w.user    = '0;
        lsu_axi_req.w_valid   = lsu_axi_wvalid;
        // B channel ready
        lsu_axi_req.b_ready   = lsu_axi_bready;
        // AR channel
        lsu_axi_req.ar.id     = lsu_axi_arid;
        lsu_axi_req.ar.addr   = lsu_axi_araddr_remapped;
        lsu_axi_req.ar.len    = lsu_axi_arlen;
        lsu_axi_req.ar.size   = lsu_axi_arsize;
        lsu_axi_req.ar.burst  = lsu_axi_arburst;
        lsu_axi_req.ar.lock   = lsu_axi_arlock[0];
        lsu_axi_req.ar.cache  = lsu_axi_arcache;
        lsu_axi_req.ar.prot   = lsu_axi_arprot;
        lsu_axi_req.ar.qos    = lsu_axi_arqos;
        lsu_axi_req.ar.region = lsu_axi_arregion;
        lsu_axi_req.ar.user   = '0;
        lsu_axi_req.ar_valid  = lsu_axi_arvalid;
        // R channel ready
        lsu_axi_req.r_ready   = lsu_axi_rready;
    end

    // Unpack response struct to LSU AXI signals
    assign lsu_axi_awready = lsu_axi_resp.aw_ready;
    assign lsu_axi_wready  = lsu_axi_resp.w_ready;
    assign lsu_axi_bvalid  = lsu_axi_resp.b_valid;
    assign lsu_axi_bid     = lsu_axi_resp.b.id[LSU_AXI_TID_WIDTH-1:0];
    assign lsu_axi_bresp   = lsu_axi_resp.b.resp;
    assign lsu_axi_arready = lsu_axi_resp.ar_ready;
    assign lsu_axi_rvalid  = lsu_axi_resp.r_valid;
    assign lsu_axi_rid     = lsu_axi_resp.r.id[LSU_AXI_TID_WIDTH-1:0];
    assign lsu_axi_rdata   = lsu_axi_resp.r.data;
    assign lsu_axi_rresp   = lsu_axi_resp.r.resp;
    assign lsu_axi_rlast   = lsu_axi_resp.r.last;

    ///////////////////////////////////////////////////////////////////////////
    // LSU AXI demux: split LSU AXI into NUM_HBM_PORTS based on address
    ///////////////////////////////////////////////////////////////////////////

    // Address-based select for demux: after remap, the HBM bank index bits
    // live at [REMAP_BANK_SHIFT +: CLOG2(PLATFORM_MEMORY_NUM_BANKS)]. The new
    // VX_mem_remap packs bank_idx = {r[2:0], q[1:0]}, so the per-port "r"
    // field sits at the HIGH HBM_SEL_BITS of bank_idx (i.e. the top
    // HBM_SEL_BITS of the full address). Using the top bits keeps DMA
    // channel c routed to HBM port c (HBM_BUS_STRIDE stride invariant).
    localparam PORT_SEL_SHIFT = `PLATFORM_MEMORY_ADDR_WIDTH - HBM_SEL_BITS;
    wire [HBM_SEL_BITS-1:0] lsu_aw_select = lsu_axi_awaddr_remapped[PORT_SEL_SHIFT +: HBM_SEL_BITS];
    wire [HBM_SEL_BITS-1:0] lsu_ar_select = lsu_axi_araddr_remapped[PORT_SEL_SHIFT +: HBM_SEL_BITS];

    slv_axi_req_t  [NUM_HBM_PORTS-1:0] lsu_demux_req;
    slv_axi_resp_t [NUM_HBM_PORTS-1:0] lsu_demux_resp;

    axi_demux #(
        .AxiIdWidth  (SLV_ID_WIDTH),
        .AtopSupport (1'b0),
        .aw_chan_t   (slv_axi_aw_chan_t),
        .w_chan_t    (slv_axi_w_chan_t),
        .b_chan_t    (slv_axi_b_chan_t),
        .ar_chan_t   (slv_axi_ar_chan_t),
        .r_chan_t    (slv_axi_r_chan_t),
        .axi_req_t   (slv_axi_req_t),
        .axi_resp_t  (slv_axi_resp_t),
        .NoMstPorts  (NUM_HBM_PORTS),
        .MaxTrans    (8),
        .AxiLookBits (SLV_ID_WIDTH),
        .UniqueIds   (1'b0),
        .SpillAw     (1'b1),
        .SpillW      (1'b0),
        .SpillB      (1'b0),
        .SpillAr     (1'b1),
        .SpillR      (1'b0)
    ) u_lsu_demux (
        .clk_i              (clk),
        .rst_ni             (~reset),
        .test_i             (1'b0),
        .slv_req_i          (lsu_axi_req),
        .slv_aw_select_i    (lsu_aw_select),
        .slv_ar_select_i    (lsu_ar_select),
        .slv_resp_o         (lsu_axi_resp),
        .mst_reqs_o         (lsu_demux_req),
        .mst_resps_i        (lsu_demux_resp)
    );

    ///////////////////////////////////////////////////////////////////////////
    // Restricted DMA AXI routing for H>D
    ///////////////////////////////////////////////////////////////////////////

    // A DMA channel c may only reach ports c+kD.  Keep a direct, zero-demux
    // path when H==D; otherwise each core/channel gets an H/D-output demux.
    slv_axi_req_t  [NUM_DMA_TOTAL-1:0][HBM_PORTS_PER_DMA-1:0] dma_demux_req;
    slv_axi_resp_t [NUM_DMA_TOTAL-1:0][HBM_PORTS_PER_DMA-1:0] dma_demux_resp;

    if (NUM_HBM_PORTS > `NUM_DMA_CHANNELS) begin : g_dma_hbm_demux
        for (genvar core = 0; core < `NUM_CORES; ++core) begin : g_core
            for (genvar ch = 0; ch < `NUM_DMA_CHANNELS; ++ch) begin : g_channel
                localparam int DMA_IDX = core * `NUM_DMA_CHANNELS + ch;

                slv_axi_req_t dma_slv_req;
                slv_axi_resp_t dma_slv_resp;
                wire [HBM_SEL_BITS-1:0] dma_aw_global_port =
                    dma_axi_m[DMA_IDX].aw_addr[PORT_SEL_SHIFT +: HBM_SEL_BITS];
                wire [HBM_SEL_BITS-1:0] dma_ar_global_port =
                    dma_axi_m[DMA_IDX].ar_addr[PORT_SEL_SHIFT +: HBM_SEL_BITS];
                wire [DMA_PORT_SLOT_BITS-1:0] dma_aw_owned_slot =
                    DMA_PORT_SLOT_BITS'(dma_aw_global_port >> DMA_SEL_SHIFT);
                wire [DMA_PORT_SLOT_BITS-1:0] dma_ar_owned_slot =
                    DMA_PORT_SLOT_BITS'(dma_ar_global_port >> DMA_SEL_SHIFT);

                `AXI_ASSIGN_TO_REQ(dma_slv_req, dma_axi_m[DMA_IDX])
                `AXI_ASSIGN_FROM_RESP(dma_axi_m[DMA_IDX], dma_slv_resp)

                axi_demux #(
                    .AxiIdWidth  (SLV_ID_WIDTH),
                    .AtopSupport (1'b0),
                    .aw_chan_t   (slv_axi_aw_chan_t),
                    .w_chan_t    (slv_axi_w_chan_t),
                    .b_chan_t    (slv_axi_b_chan_t),
                    .ar_chan_t   (slv_axi_ar_chan_t),
                    .r_chan_t    (slv_axi_r_chan_t),
                    .axi_req_t   (slv_axi_req_t),
                    .axi_resp_t  (slv_axi_resp_t),
                    .NoMstPorts  (HBM_PORTS_PER_DMA),
                    .MaxTrans    (8),
                    .AxiLookBits (SLV_ID_WIDTH),
                    .UniqueIds   (1'b0),
                    .SpillAw     (1'b1),
                    .SpillW      (1'b0),
                    .SpillB      (1'b0),
                    .SpillAr     (1'b1),
                    .SpillR      (1'b0)
                ) u_dma_demux (
                    .clk_i              (clk),
                    .rst_ni             (~reset),
                    .test_i             (1'b0),
                    .slv_req_i          (dma_slv_req),
                    .slv_aw_select_i    (dma_aw_owned_slot),
                    .slv_ar_select_i    (dma_ar_owned_slot),
                    .slv_resp_o         (dma_slv_resp),
                    .mst_reqs_o         (dma_demux_req[DMA_IDX]),
                    .mst_resps_i        (dma_demux_resp[DMA_IDX])
                );

            `ifndef SYNTHESIS
                always_ff @(posedge clk) begin
                    if (!reset && dma_axi_m[DMA_IDX].aw_valid) begin
                        assert ((int'(dma_aw_global_port)
                                 % `NUM_DMA_CHANNELS) == ch)
                            else $fatal(1,
                                "%m: DMA ch%0d AW selected unowned HBM port %0d",
                                ch, dma_aw_global_port);
                    end
                    if (!reset && dma_axi_m[DMA_IDX].ar_valid) begin
                        assert ((int'(dma_ar_global_port)
                                 % `NUM_DMA_CHANNELS) == ch)
                            else $fatal(1,
                                "%m: DMA ch%0d AR selected unowned HBM port %0d",
                                ch, dma_ar_global_port);
                    end
                end
            `endif
            end
        end
    end

    ///////////////////////////////////////////////////////////////////////////
    // Per-HBM-port AXI mux: merge LSU demux + DMA channels
    ///////////////////////////////////////////////////////////////////////////

    // For each HBM port j, the mux has NUM_MUX_INPUTS slaves:
    //   slave[0]   = lsu_demux[j]
    //   slave[i+1] = core[i].dma[j]   for i in 0..NUM_CORES-1
    //
    // DMA port mapping: core i, channel j => dma_axi_m[i * NUM_DMA_CHANNELS + j]

    for (genvar j = 0; j < NUM_HBM_PORTS; ++j) begin : g_hbm_mux

        // Slave request/response arrays for axi_mux
        slv_axi_req_t  [NUM_MUX_INPUTS-1:0] mux_slv_reqs;
        slv_axi_resp_t [NUM_MUX_INPUTS-1:0] mux_slv_resps;

        // Master request/response from axi_mux
        mst_axi_req_t  mux_mst_req;
        mst_axi_resp_t mux_mst_resp;

        // Slave[0] = LSU demux output for this HBM port
        slv_axi_req_t  lsu_mux_req;
        slv_axi_resp_t lsu_mux_resp;

        axi_cut #(
            .Bypass     (1'b0),
            .aw_chan_t  (slv_axi_aw_chan_t),
            .w_chan_t   (slv_axi_w_chan_t),
            .b_chan_t   (slv_axi_b_chan_t),
            .ar_chan_t  (slv_axi_ar_chan_t),
            .r_chan_t   (slv_axi_r_chan_t),
            .axi_req_t  (slv_axi_req_t),
            .axi_resp_t (slv_axi_resp_t)
        ) u_lsu_mux_cut (
            .clk_i      (clk),
            .rst_ni     (~reset),
            .slv_req_i  (lsu_demux_req[j]),
            .slv_resp_o (lsu_demux_resp[j]),
            .mst_req_o  (lsu_mux_req),
            .mst_resp_i (lsu_mux_resp)
        );

        assign mux_slv_reqs[0] = lsu_mux_req;
        assign lsu_mux_resp = mux_slv_resps[0];

        // Slave[1..NUM_CORES] = the statically-owned DMA channel from each
        // core for this HBM port.
        if (NUM_HBM_PORTS == `NUM_DMA_CHANNELS) begin : g_dma_multi_port
            // Non-merged: each HBM port j gets DMA channel j from each core
            for (genvar i = 0; i < `NUM_CORES; ++i) begin : g_dma_to_mux
                localparam DMA_IDX = i * `NUM_DMA_CHANNELS + j;
                `AXI_ASSIGN_TO_REQ(mux_slv_reqs[1+i], dma_axi_m[DMA_IDX])
                `AXI_ASSIGN_FROM_RESP(dma_axi_m[DMA_IDX], mux_slv_resps[1+i])
            end
        end else begin : g_dma_restricted
            localparam int OWNER_CH = j % `NUM_DMA_CHANNELS;
            localparam int OWNED_SLOT = j / `NUM_DMA_CHANNELS;
            for (genvar i = 0; i < `NUM_CORES; ++i) begin : g_dma_to_mux
                localparam int DMA_IDX = i * `NUM_DMA_CHANNELS + OWNER_CH;
                assign mux_slv_reqs[1+i] = dma_demux_req[DMA_IDX][OWNED_SLOT];
                assign dma_demux_resp[DMA_IDX][OWNED_SLOT] = mux_slv_resps[1+i];
            end
        end

        axi_mux #(
            .SlvAxiIDWidth (SLV_ID_WIDTH),
            .slv_aw_chan_t (slv_axi_aw_chan_t),
            .mst_aw_chan_t (mst_axi_aw_chan_t),
            .w_chan_t      (slv_axi_w_chan_t),
            .slv_b_chan_t  (slv_axi_b_chan_t),
            .mst_b_chan_t  (mst_axi_b_chan_t),
            .slv_ar_chan_t (slv_axi_ar_chan_t),
            .mst_ar_chan_t (mst_axi_ar_chan_t),
            .slv_r_chan_t  (slv_axi_r_chan_t),
            .mst_r_chan_t  (mst_axi_r_chan_t),
            .slv_req_t     (slv_axi_req_t),
            .slv_resp_t    (slv_axi_resp_t),
            .mst_req_t     (mst_axi_req_t),
            .mst_resp_t    (mst_axi_resp_t),
            .NoSlvPorts    (NUM_MUX_INPUTS),
            .MaxWTrans     (8),
            .FallThrough   (1'b0),
            .SpillAw       (1'b1),
            .SpillW        (1'b0),
            .SpillB        (1'b0),
            .SpillAr       (1'b0),
            .SpillR        (1'b0)
        ) u_axi_mux (
            .clk_i       (clk),
            .rst_ni      (~reset),
            .test_i      (1'b0),
            .slv_reqs_i  (mux_slv_reqs),
            .slv_resps_o (mux_slv_resps),
            .mst_req_o   (mux_mst_req),
            .mst_resp_i  (mux_mst_resp)
        );

        ///////////////////////////////////////////////////////////////////
        // Convert mux master output to flat AXI signals (HBM port j)
        ///////////////////////////////////////////////////////////////////

        // AW channel
        assign m_axi_awvalid[j]  = mux_mst_req.aw_valid;
        assign m_axi_awaddr[j]   = mux_mst_req.aw.addr;
        assign m_axi_awid[j]     = AXI_TID_WIDTH'(mux_mst_req.aw.id);
        assign m_axi_awlen[j]    = mux_mst_req.aw.len;
        assign m_axi_awsize[j]   = mux_mst_req.aw.size;
        assign m_axi_awburst[j]  = mux_mst_req.aw.burst;
        assign m_axi_awlock[j]   = {1'b0, mux_mst_req.aw.lock};
        assign m_axi_awcache[j]  = mux_mst_req.aw.cache;
        assign m_axi_awprot[j]   = mux_mst_req.aw.prot;
        assign m_axi_awqos[j]    = mux_mst_req.aw.qos;
        assign m_axi_awregion[j] = mux_mst_req.aw.region;

        // W channel
        assign m_axi_wvalid[j]   = mux_mst_req.w_valid;
        assign m_axi_wdata[j]    = mux_mst_req.w.data;
        assign m_axi_wstrb[j]    = mux_mst_req.w.strb;
        assign m_axi_wlast[j]    = mux_mst_req.w.last;

        // B channel
        assign m_axi_bready[j]   = mux_mst_req.b_ready;

        // AR channel
        assign m_axi_arvalid[j]  = mux_mst_req.ar_valid;
        assign m_axi_araddr[j]   = mux_mst_req.ar.addr;
        assign m_axi_arid[j]     = AXI_TID_WIDTH'(mux_mst_req.ar.id);
        assign m_axi_arlen[j]    = mux_mst_req.ar.len;
        assign m_axi_arsize[j]   = mux_mst_req.ar.size;
        assign m_axi_arburst[j]  = mux_mst_req.ar.burst;
        assign m_axi_arlock[j]   = {1'b0, mux_mst_req.ar.lock};
        assign m_axi_arcache[j]  = mux_mst_req.ar.cache;
        assign m_axi_arprot[j]   = mux_mst_req.ar.prot;
        assign m_axi_arqos[j]    = mux_mst_req.ar.qos;
        assign m_axi_arregion[j] = mux_mst_req.ar.region;

        // R channel
        assign m_axi_rready[j]   = mux_mst_req.r_ready;

        // Pack all response signals into mux_mst_resp in a single block
        always_comb begin
            mux_mst_resp = '0;
            // Handshake ready signals
            mux_mst_resp.aw_ready = m_axi_awready[j];
            mux_mst_resp.w_ready  = m_axi_wready[j];
            mux_mst_resp.ar_ready = m_axi_arready[j];
            // B channel
            mux_mst_resp.b_valid  = m_axi_bvalid[j];
            mux_mst_resp.b.id     = MST_ID_WIDTH'(m_axi_bid[j]);
            mux_mst_resp.b.resp   = m_axi_bresp[j];
            mux_mst_resp.b.user   = '0;
            // R channel
            mux_mst_resp.r_valid  = m_axi_rvalid[j];
            mux_mst_resp.r.id     = MST_ID_WIDTH'(m_axi_rid[j]);
            mux_mst_resp.r.data   = m_axi_rdata[j];
            mux_mst_resp.r.resp   = m_axi_rresp[j];
            mux_mst_resp.r.last   = m_axi_rlast[j];
            mux_mst_resp.r.user   = '0;
        end

    end

    ///////////////////////////////////////////////////////////////////////////
    // Cache drain logic
    ///////////////////////////////////////////////////////////////////////////

    wire [VX_MEM_PORTS-1:0] mem_req_stall;
    wire [VX_MEM_PORTS-1:0] mem_rsp_stall;
    wire [VX_MEM_PORTS-1:0] mem_req_a_stall;
    wire [VX_MEM_PORTS-1:0] mem_rsp_a_stall;

    for (genvar i = 0; i < VX_MEM_PORTS; ++i) begin : g_drain_mem_stall
        assign mem_req_stall[i] = mem_req_valid[i] && ~mem_req_ready[i];
        assign mem_rsp_stall[i] = mem_rsp_valid[i] && ~mem_rsp_ready[i];
        assign mem_req_a_stall[i] = mem_req_valid_a[i] && ~mem_req_ready_a[i];
        assign mem_rsp_a_stall[i] = mem_rsp_valid_a[i] && ~mem_rsp_ready_a[i];
    end

    wire [NUM_HBM_PORTS-1:0] axi_aw_stall;
    wire [NUM_HBM_PORTS-1:0] axi_w_stall;
    wire [NUM_HBM_PORTS-1:0] axi_ar_stall;
    wire [NUM_HBM_PORTS-1:0] axi_b_stall;
    wire [NUM_HBM_PORTS-1:0] axi_r_stall;

    for (genvar i = 0; i < NUM_HBM_PORTS; ++i) begin : g_drain_axi_stall
        assign axi_aw_stall[i] = m_axi_awvalid[i] && ~m_axi_awready[i];
        assign axi_w_stall[i] = m_axi_wvalid[i] && ~m_axi_wready[i];
        assign axi_ar_stall[i] = m_axi_arvalid[i] && ~m_axi_arready[i];
        assign axi_b_stall[i] = m_axi_bvalid[i] && ~m_axi_bready[i];
        assign axi_r_stall[i] = m_axi_rvalid[i] && ~m_axi_rready[i];
    end

    assign cache_drain = vortex_cache_drain
                      && ~(| mem_req_stall)
                      && ~(| mem_rsp_stall)
                      && ~(| mem_req_a_stall)
                      && ~(| mem_rsp_a_stall)
                      && ~(| axi_aw_stall)
                      && ~(| axi_w_stall)
                      && ~(| axi_ar_stall)
                      && ~(| axi_b_stall)
                      && ~(| axi_r_stall);

endmodule
