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

module VX_socket import VX_gpu_pkg::*; #(
    parameter SOCKET_ID = 0,
    parameter `STRING INSTANCE_ID = ""
) (
    `SCOPE_IO_DECL

    // Clock
    input wire              clk,
    input wire              reset,

`ifdef PERF_ENABLE
    input sysmem_perf_t     sysmem_perf,
`endif

    // DCRs
    VX_dcr_bus_if.slave     dcr_bus_if,

    // Memory
    VX_mem_bus_if.master    mem_bus_if [`L1_MEM_PORTS],

    // DMA AXI ports (cache bypass, from all cores)
    AXI_BUS.Master          dma_axi_m [`SOCKET_SIZE * `NUM_DMA_CHANNELS],

`ifdef GBAR_ENABLE
    // Barrier
    VX_gbar_bus_if.master   gbar_bus_if,
`endif

`ifdef ENABLE_HW_DEBUG_MODULE
	    output wire                         hw_debug_pc_valid [`SOCKET_SIZE],
	    output wire [HW_DEBUG_CORE_ID_WIDTH-1:0] hw_debug_pc_core_id [`SOCKET_SIZE],
		    output wire [NW_WIDTH-1:0]          hw_debug_pc_wid [`SOCKET_SIZE],
		    output wire [`XLEN-1:0]             hw_debug_pc [`SOCKET_SIZE],
		    output core_pipeline_debug_t        core_pipeline_debug [`SOCKET_SIZE],
		    output cache_debug_t                cache_debug [HW_DEBUG_SOCKET_CACHE_SOURCES],
		`endif

    // Status
    output wire             busy,
    output wire             dcache_drain
);

`ifdef SCOPE
    localparam scope_core = 0;
    `SCOPE_IO_SWITCH (`SOCKET_SIZE);
`endif

`ifdef GBAR_ENABLE
    VX_gbar_bus_if per_core_gbar_bus_if[`SOCKET_SIZE]();

    VX_gbar_arb #(
        .NUM_REQS (`SOCKET_SIZE),
        .OUT_BUF  ((`SOCKET_SIZE > 1) ? 2 : 0)
    ) gbar_arb (
        .clk        (clk),
        .reset      (reset),
        .bus_in_if  (per_core_gbar_bus_if),
        .bus_out_if (gbar_bus_if)
    );
`endif

    ///////////////////////////////////////////////////////////////////////////

`ifdef PERF_ENABLE
    cache_perf_t icache_perf, dcache_perf;
    sysmem_perf_t sysmem_perf_tmp;
    always_comb begin
        sysmem_perf_tmp = sysmem_perf;
        sysmem_perf_tmp.icache = icache_perf;
        sysmem_perf_tmp.dcache = dcache_perf;
    end
`endif

    ///////////////////////////////////////////////////////////////////////////

    VX_mem_bus_if #(
        .DATA_SIZE (ICACHE_WORD_SIZE),
        .TAG_WIDTH (ICACHE_TAG_WIDTH)
    ) per_core_icache_bus_if[`SOCKET_SIZE]();

    VX_mem_bus_if #(
        .DATA_SIZE (ICACHE_LINE_SIZE),
        .TAG_WIDTH (ICACHE_MEM_TAG_WIDTH)
    ) icache_mem_bus_if[1]();

	    wire icache_drain;

	`ifdef ENABLE_HW_DEBUG_MODULE
	    cache_debug_t icache_cache_debug [HW_DEBUG_L1I_CACHE_SOURCES_PER_SOCKET];
	`endif

	    `RESET_RELAY (icache_reset, reset);

	    VX_cache_cluster #(
        .INSTANCE_ID    (`SFORMATF(("%s-icache", INSTANCE_ID))),
        .NUM_UNITS      (`NUM_ICACHES),
        .NUM_INPUTS     (`SOCKET_SIZE),
        .TAG_SEL_IDX    (0),
        .CACHE_SIZE     (`ICACHE_SIZE),
        .LINE_SIZE      (ICACHE_LINE_SIZE),
        .NUM_BANKS      (1),
        .NUM_WAYS       (`ICACHE_NUM_WAYS),
        .WORD_SIZE      (ICACHE_WORD_SIZE),
        .NUM_REQS       (1),
        .MEM_PORTS      (1),
        .CRSQ_SIZE      (`ICACHE_CRSQ_SIZE),
        .MSHR_SIZE      (`ICACHE_MSHR_SIZE),
        .MRSQ_SIZE      (`ICACHE_MRSQ_SIZE),
        .MREQ_SIZE      (`ICACHE_MREQ_SIZE),
        .TAG_WIDTH      (ICACHE_TAG_WIDTH),
        .WRITE_ENABLE   (0),
	        .REPL_POLICY    (`ICACHE_REPL_POLICY),
	        .NC_ENABLE      (0),
	        .CORE_OUT_BUF   (3),
	        .MEM_OUT_BUF    (2),
	        .DEBUG_CACHE_KIND     (HW_DBG_CACHE_KIND_L1I),
	        .DEBUG_CACHE_LOCATION (SOCKET_ID)
	    ) icache (
    `ifdef PERF_ENABLE
        .cache_perf     (icache_perf),
    `endif
        .clk            (clk),
	        .reset          (icache_reset),
	        .core_bus_if    (per_core_icache_bus_if),
	        .mem_bus_if     (icache_mem_bus_if),
	    `ifdef ENABLE_HW_DEBUG_MODULE
	        .cache_debug    (icache_cache_debug),
	    `endif
	        .cache_drain    (icache_drain)
	    );

    ///////////////////////////////////////////////////////////////////////////

    VX_mem_bus_if #(
        .DATA_SIZE (DCACHE_WORD_SIZE),
        .TAG_WIDTH (DCACHE_CORE_TAG_WIDTH)
    ) per_core_dcache_bus_if[`SOCKET_SIZE * DCACHE_NUM_REQS]();

    VX_mem_bus_if #(
        .DATA_SIZE (DCACHE_LINE_SIZE),
        .TAG_WIDTH (DCACHE_MEM_TAG_WIDTH)
    ) dcache_mem_bus_if[`L1_MEM_PORTS]();

	    wire dcache_cache_drain;

	`ifdef ENABLE_HW_DEBUG_MODULE
	    cache_debug_t dcache_cache_debug [HW_DEBUG_L1D_CACHE_SOURCES_PER_SOCKET];
	`endif

	    `RESET_RELAY (dcache_reset, reset);

    VX_cache_cluster #(
        .INSTANCE_ID    (`SFORMATF(("%s-dcache", INSTANCE_ID))),
        .NUM_UNITS      (`NUM_DCACHES),
        .NUM_INPUTS     (`SOCKET_SIZE),
        .TAG_SEL_IDX    (0),
        .CACHE_SIZE     (`DCACHE_SIZE),
        .LINE_SIZE      (DCACHE_LINE_SIZE),
        .NUM_BANKS      (`DCACHE_NUM_BANKS),
        .NUM_WAYS       (`DCACHE_NUM_WAYS),
        .WORD_SIZE      (DCACHE_WORD_SIZE),
        .NUM_REQS       (DCACHE_NUM_REQS),
        .MEM_PORTS      (`L1_MEM_PORTS),
        .CRSQ_SIZE      (`DCACHE_CRSQ_SIZE),
        .MSHR_SIZE      (`DCACHE_MSHR_SIZE),
        .MRSQ_SIZE      (`DCACHE_MRSQ_SIZE),
        .MREQ_SIZE      (`DCACHE_WRITEBACK ? `DCACHE_MSHR_SIZE : `DCACHE_MREQ_SIZE),
        .TAG_WIDTH      (DCACHE_CORE_TAG_WIDTH),
        .WRITE_ENABLE   (1),
        .WRITEBACK      (`DCACHE_WRITEBACK),
        .DIRTY_BYTES    (`DCACHE_DIRTYBYTES),
	        .REPL_POLICY    (`DCACHE_REPL_POLICY),
	        .NC_ENABLE      (1),
	        .CORE_OUT_BUF   (3),
	        .MEM_OUT_BUF    (2),
	        .DEBUG_CACHE_KIND     (HW_DBG_CACHE_KIND_L1D),
	        .DEBUG_CACHE_LOCATION (SOCKET_ID)
	    ) dcache (
    `ifdef PERF_ENABLE
        .cache_perf     (dcache_perf),
    `endif
        .clk            (clk),
	        .reset          (dcache_reset),
	        .core_bus_if    (per_core_dcache_bus_if),
	        .mem_bus_if     (dcache_mem_bus_if),
	    `ifdef ENABLE_HW_DEBUG_MODULE
	        .cache_debug    (dcache_cache_debug),
	    `endif
	        .cache_drain    (dcache_cache_drain)
	    );

	`ifdef ENABLE_HW_DEBUG_MODULE
	    for (genvar cache_dbg_i = 0; cache_dbg_i < HW_DEBUG_L1I_CACHE_SOURCES_PER_SOCKET; ++cache_dbg_i) begin : g_hw_debug_icache
	        assign cache_debug[cache_dbg_i] = icache_cache_debug[cache_dbg_i];
	    end

	    for (genvar cache_dbg_i = 0; cache_dbg_i < HW_DEBUG_L1D_CACHE_SOURCES_PER_SOCKET; ++cache_dbg_i) begin : g_hw_debug_dcache
	        assign cache_debug[HW_DEBUG_L1I_CACHE_SOURCES_PER_SOCKET + cache_dbg_i] = dcache_cache_debug[cache_dbg_i];
	    end
	`endif

	    `UNUSED_VAR (icache_drain)

    ///////////////////////////////////////////////////////////////////////////

    for (genvar i = 0; i < `L1_MEM_PORTS; ++i) begin : g_mem_bus_if
        if (i == 0) begin : g_i0
            VX_mem_bus_if #(
                .DATA_SIZE (`L1_LINE_SIZE),
                .TAG_WIDTH (L1_MEM_TAG_WIDTH)
            ) l1_mem_bus_if[2]();

            VX_mem_bus_if #(
                .DATA_SIZE (`L1_LINE_SIZE),
                .TAG_WIDTH (L1_MEM_ARB_TAG_WIDTH)
            ) l1_mem_arb_bus_if[1]();

            `ASSIGN_VX_MEM_BUS_IF_EX (l1_mem_bus_if[0], icache_mem_bus_if[0], L1_MEM_TAG_WIDTH, ICACHE_MEM_TAG_WIDTH, UUID_WIDTH);
            `ASSIGN_VX_MEM_BUS_IF_EX (l1_mem_bus_if[1], dcache_mem_bus_if[0], L1_MEM_TAG_WIDTH, DCACHE_MEM_TAG_WIDTH, UUID_WIDTH);

            VX_mem_arb #(
                .NUM_INPUTS (2),
                .NUM_OUTPUTS(1),
                .DATA_SIZE  (`L1_LINE_SIZE),
                .TAG_WIDTH  (L1_MEM_TAG_WIDTH),
                .TAG_SEL_IDX(0),
                .ARBITER    ("P"), // prioritize the icache
                .REQ_OUT_BUF(3),
                .RSP_OUT_BUF(3)
            ) mem_arb (
                .clk        (clk),
                .reset      (reset),
                .bus_in_if  (l1_mem_bus_if),
                .bus_out_if (l1_mem_arb_bus_if)
            );

            `ASSIGN_VX_MEM_BUS_IF (mem_bus_if[0], l1_mem_arb_bus_if[0]);
        end else begin : g_i
            VX_mem_bus_if #(
                .DATA_SIZE (`L1_LINE_SIZE),
                .TAG_WIDTH (L1_MEM_ARB_TAG_WIDTH)
            ) l1_mem_arb_bus_if();

            `ASSIGN_VX_MEM_BUS_IF_EX (l1_mem_arb_bus_if, dcache_mem_bus_if[i], L1_MEM_ARB_TAG_WIDTH, DCACHE_MEM_TAG_WIDTH, UUID_WIDTH);
            `ASSIGN_VX_MEM_BUS_IF (mem_bus_if[i], l1_mem_arb_bus_if);
        end
    end

    wire [`L1_MEM_PORTS-1:0] dcache_mem_req_pending;
    wire [`L1_MEM_PORTS-1:0] dcache_mem_rsp_pending;
    wire [`L1_MEM_PORTS-1:0] l1_mem_req_pending;
    wire [`L1_MEM_PORTS-1:0] l1_mem_rsp_pending;

    for (genvar i = 0; i < `L1_MEM_PORTS; ++i) begin : g_dcache_drain_pending
        assign dcache_mem_req_pending[i] = dcache_mem_bus_if[i].req_valid;
        assign dcache_mem_rsp_pending[i] = dcache_mem_bus_if[i].rsp_valid;
        assign l1_mem_req_pending[i] = mem_bus_if[i].req_valid;
        assign l1_mem_rsp_pending[i] = mem_bus_if[i].rsp_valid;
    end

    wire dcache_pending = (| dcache_mem_req_pending)
                       || (| dcache_mem_rsp_pending)
                       || (| l1_mem_req_pending)
                       || (| l1_mem_rsp_pending);

    assign dcache_drain = dcache_cache_drain && ~dcache_pending;

    ///////////////////////////////////////////////////////////////////////////

    wire [`SOCKET_SIZE-1:0] per_core_busy;

    // Generate all cores
    for (genvar core_id = 0; core_id < `SOCKET_SIZE; ++core_id) begin : g_cores

        `RESET_RELAY (core_reset, reset);

        VX_dcr_bus_if core_dcr_bus_if();
        `BUFFER_DCR_BUS_IF (core_dcr_bus_if, dcr_bus_if, 1'b1, (`SOCKET_SIZE > 1))

        VX_core #(
            .CORE_ID  ((SOCKET_ID * `SOCKET_SIZE) + core_id),
            .INSTANCE_ID (`SFORMATF(("%s-core%0d", INSTANCE_ID, core_id))),
            .NUM_TMEM_BANKS (`NUM_DMA_CHANNELS)
        ) core (
            `SCOPE_IO_BIND  (scope_core + core_id)

            .clk            (clk),
            .reset          (core_reset),

        `ifdef PERF_ENABLE
            .sysmem_perf    (sysmem_perf_tmp),
        `endif

            .dcr_bus_if     (core_dcr_bus_if),

            .dcache_bus_if  (per_core_dcache_bus_if[core_id * DCACHE_NUM_REQS +: DCACHE_NUM_REQS]),

            .icache_bus_if  (per_core_icache_bus_if[core_id]),

            .dma_axi_m      (dma_axi_m[core_id * `NUM_DMA_CHANNELS +: `NUM_DMA_CHANNELS]),

        `ifdef GBAR_ENABLE
            .gbar_bus_if    (per_core_gbar_bus_if[core_id]),
        `endif

        `ifdef ENABLE_HW_DEBUG_MODULE
            .hw_debug_pc_valid   (hw_debug_pc_valid[core_id]),
	            .hw_debug_pc_core_id (hw_debug_pc_core_id[core_id]),
	            .hw_debug_pc_wid     (hw_debug_pc_wid[core_id]),
	            .hw_debug_pc         (hw_debug_pc[core_id]),
	            .core_pipeline_debug (core_pipeline_debug[core_id]),
	        `endif

            .busy           (per_core_busy[core_id])
        );
    end

    `BUFFER_EX(busy, (| per_core_busy), 1'b1, 1, (`SOCKET_SIZE > 1));

endmodule
