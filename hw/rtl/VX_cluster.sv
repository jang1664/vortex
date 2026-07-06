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

module VX_cluster import VX_gpu_pkg::*; #(
    parameter CLUSTER_ID = 0,
    parameter `STRING INSTANCE_ID = ""
) (
    `SCOPE_IO_DECL

    // Clock
    input  wire                 clk,
    input  wire                 reset,

`ifdef PERF_ENABLE
    input sysmem_perf_t         sysmem_perf,
`endif

    // DCRs
    VX_dcr_bus_if.slave         dcr_bus_if,

    // Memory
    VX_mem_bus_if.master        mem_bus_if [`L2_MEM_PORTS],

    // DMA AXI ports (cache bypass, from all cores in cluster)
    AXI_BUS.Master              dma_axi_m [NUM_SOCKETS * `SOCKET_SIZE * `NUM_DMA_CHANNELS],

`ifdef ENABLE_HW_DEBUG_MODULE
	    output wire                         hw_debug_pc_valid [NUM_SOCKETS * `SOCKET_SIZE],
	    output wire [HW_DEBUG_CORE_ID_WIDTH-1:0] hw_debug_pc_core_id [NUM_SOCKETS * `SOCKET_SIZE],
		    output wire [NW_WIDTH-1:0]          hw_debug_pc_wid [NUM_SOCKETS * `SOCKET_SIZE],
		    output wire [`XLEN-1:0]             hw_debug_pc [NUM_SOCKETS * `SOCKET_SIZE],
		    output core_pipeline_debug_t        core_pipeline_debug [NUM_SOCKETS * `SOCKET_SIZE],
            output gemm_unit_debug_t           gemm_unit_debug [NUM_SOCKETS * `SOCKET_SIZE],
		    output cache_debug_t                cache_debug [HW_DEBUG_CLUSTER_CACHE_SOURCES],
		`endif

    // Status
    output wire                 busy,
    output wire                 cache_drain
);

`ifdef SCOPE
    localparam scope_socket = 0;
    `SCOPE_IO_SWITCH (NUM_SOCKETS);
`endif

`ifdef PERF_ENABLE
    cache_perf_t l2_perf;
    sysmem_perf_t sysmem_perf_tmp;
    always @(*) begin
        sysmem_perf_tmp = sysmem_perf;
        sysmem_perf_tmp.l2cache = l2_perf;
    end
`endif

`ifdef GBAR_ENABLE

    VX_gbar_bus_if per_socket_gbar_bus_if[NUM_SOCKETS]();
    VX_gbar_bus_if gbar_bus_if();

    VX_gbar_arb #(
        .NUM_REQS (NUM_SOCKETS),
        .OUT_BUF  ((NUM_SOCKETS > 2) ? 1 : 0) // bgar_unit has no backpressure
    ) gbar_arb (
        .clk        (clk),
        .reset      (reset),
        .bus_in_if  (per_socket_gbar_bus_if),
        .bus_out_if (gbar_bus_if)
    );

    VX_gbar_unit #(
        .INSTANCE_ID (`SFORMATF(("gbar%0d", CLUSTER_ID)))
    ) gbar_unit (
        .clk         (clk),
        .reset       (reset),
        .gbar_bus_if (gbar_bus_if)
    );

`endif

    VX_mem_bus_if #(
        .DATA_SIZE (`L1_LINE_SIZE),
        .TAG_WIDTH (L1_MEM_ARB_TAG_WIDTH)
    ) per_socket_mem_bus_if[NUM_SOCKETS * `L1_MEM_PORTS]();

	    `RESET_RELAY (l2_reset, reset);
	    wire l2_cache_drain;

	`ifdef ENABLE_HW_DEBUG_MODULE
	    cache_debug_t l2_cache_debug;
	    cache_debug_t socket_cache_debug [NUM_SOCKETS * HW_DEBUG_SOCKET_CACHE_SOURCES];
	`endif

	    VX_cache_wrap #(
        .INSTANCE_ID    (`SFORMATF(("%s-l2cache", INSTANCE_ID))),
        .CACHE_SIZE     (`L2_CACHE_SIZE),
        .LINE_SIZE      (`L2_LINE_SIZE),
        .NUM_BANKS      (`L2_NUM_BANKS),
        .NUM_WAYS       (`L2_NUM_WAYS),
        .WORD_SIZE      (L2_WORD_SIZE),
        .NUM_REQS       (L2_NUM_REQS),
        .MEM_PORTS      (`L2_MEM_PORTS),
        .CRSQ_SIZE      (`L2_CRSQ_SIZE),
        .MSHR_SIZE      (`L2_MSHR_SIZE),
        .MRSQ_SIZE      (`L2_MRSQ_SIZE),
        .MREQ_SIZE      (`L2_WRITEBACK ? `L2_MSHR_SIZE : `L2_MREQ_SIZE),
        .TAG_WIDTH      (L2_TAG_WIDTH),
        .WRITE_ENABLE   (1),
        .WRITEBACK      (`L2_WRITEBACK),
        .DIRTY_BYTES    (`L2_DIRTYBYTES),
        .REPL_POLICY    (`L2_REPL_POLICY),
	        .CORE_OUT_BUF   (3),
	        .MEM_OUT_BUF    (3),
	        .NC_ENABLE      (1),
	        .PASSTHRU       (!`L2_ENABLED),
	        .DEBUG_CACHE_KIND     (HW_DBG_CACHE_KIND_L2),
	        .DEBUG_CACHE_LOCATION (CLUSTER_ID),
	        .DEBUG_CACHE_UNIT     (0)
	    ) l2cache (
        .clk            (clk),
        .reset          (l2_reset),
    `ifdef PERF_ENABLE
        .cache_perf     (l2_perf),
	`endif
	        .core_bus_if    (per_socket_mem_bus_if),
	        .mem_bus_if     (mem_bus_if),
	    `ifdef ENABLE_HW_DEBUG_MODULE
	        .cache_debug    (l2_cache_debug),
	    `endif
	        .cache_drain    (l2_cache_drain)
	    );

    ///////////////////////////////////////////////////////////////////////////

    wire [NUM_SOCKETS-1:0] per_socket_busy;
    wire [NUM_SOCKETS-1:0] per_socket_dcache_drain;

    // Generate all sockets
    for (genvar socket_id = 0; socket_id < NUM_SOCKETS; ++socket_id) begin : g_sockets

        `RESET_RELAY (socket_reset, reset);

        VX_dcr_bus_if socket_dcr_bus_if();
        wire is_base_dcr_addr = (dcr_bus_if.write_addr >= `VX_DCR_BASE_STATE_BEGIN && dcr_bus_if.write_addr < `VX_DCR_BASE_STATE_END);
        `BUFFER_DCR_BUS_IF (socket_dcr_bus_if, dcr_bus_if, is_base_dcr_addr, (NUM_SOCKETS > 1))

        localparam SOCKET_DMA_PORTS = `SOCKET_SIZE * `NUM_DMA_CHANNELS;

        VX_socket #(
            .SOCKET_ID ((CLUSTER_ID * NUM_SOCKETS) + socket_id),
            .INSTANCE_ID (`SFORMATF(("%s-socket%0d", INSTANCE_ID, socket_id)))
        ) socket (
            `SCOPE_IO_BIND  (scope_socket+socket_id)

            .clk            (clk),
            .reset          (socket_reset),

        `ifdef PERF_ENABLE
            .sysmem_perf    (sysmem_perf_tmp),
        `endif

            .dcr_bus_if     (socket_dcr_bus_if),

            .mem_bus_if     (per_socket_mem_bus_if[socket_id * `L1_MEM_PORTS +: `L1_MEM_PORTS]),

            .dma_axi_m      (dma_axi_m[socket_id * SOCKET_DMA_PORTS +: SOCKET_DMA_PORTS]),

        `ifdef GBAR_ENABLE
            .gbar_bus_if    (per_socket_gbar_bus_if[socket_id]),
        `endif

	        `ifdef ENABLE_HW_DEBUG_MODULE
	            .hw_debug_pc_valid   (hw_debug_pc_valid[socket_id * `SOCKET_SIZE +: `SOCKET_SIZE]),
		            .hw_debug_pc_core_id (hw_debug_pc_core_id[socket_id * `SOCKET_SIZE +: `SOCKET_SIZE]),
		            .hw_debug_pc_wid     (hw_debug_pc_wid[socket_id * `SOCKET_SIZE +: `SOCKET_SIZE]),
		            .hw_debug_pc         (hw_debug_pc[socket_id * `SOCKET_SIZE +: `SOCKET_SIZE]),
		            .core_pipeline_debug (core_pipeline_debug[socket_id * `SOCKET_SIZE +: `SOCKET_SIZE]),
                    .gemm_unit_debug     (gemm_unit_debug[socket_id * `SOCKET_SIZE +: `SOCKET_SIZE]),
		            .cache_debug         (socket_cache_debug[socket_id * HW_DEBUG_SOCKET_CACHE_SOURCES +: HW_DEBUG_SOCKET_CACHE_SOURCES]),
		        `endif

	            .busy           (per_socket_busy[socket_id]),
	            .dcache_drain   (per_socket_dcache_drain[socket_id])
	        );
	    end

	`ifdef ENABLE_HW_DEBUG_MODULE
	    for (genvar cache_dbg_i = 0; cache_dbg_i < (NUM_SOCKETS * HW_DEBUG_SOCKET_CACHE_SOURCES); ++cache_dbg_i) begin : g_hw_debug_socket_cache
	        assign cache_debug[cache_dbg_i] = socket_cache_debug[cache_dbg_i];
	    end

	    assign cache_debug[NUM_SOCKETS * HW_DEBUG_SOCKET_CACHE_SOURCES] = l2_cache_debug;
	`endif

	    wire [NUM_SOCKETS * `L1_MEM_PORTS-1:0] l1_req_pending;
    wire [NUM_SOCKETS * `L1_MEM_PORTS-1:0] l1_rsp_pending;
    wire [`L2_MEM_PORTS-1:0] l2_req_pending;
    wire [`L2_MEM_PORTS-1:0] l2_rsp_pending;

    for (genvar i = 0; i < (NUM_SOCKETS * `L1_MEM_PORTS); ++i) begin : g_drain_l1_pending
        assign l1_req_pending[i] = per_socket_mem_bus_if[i].req_valid;
        assign l1_rsp_pending[i] = per_socket_mem_bus_if[i].rsp_valid;
    end

    for (genvar i = 0; i < `L2_MEM_PORTS; ++i) begin : g_drain_l2_pending
        assign l2_req_pending[i] = mem_bus_if[i].req_valid;
        assign l2_rsp_pending[i] = mem_bus_if[i].rsp_valid;
    end

    wire cluster_pending = (| l1_req_pending)
                        || (| l1_rsp_pending)
                        || (| l2_req_pending)
                        || (| l2_rsp_pending);

    `BUFFER_EX(busy, (| per_socket_busy), 1'b1, 1, (NUM_SOCKETS > 1));
    assign cache_drain = (& per_socket_dcache_drain) && l2_cache_drain && ~cluster_pending;

endmodule
