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

`include "VX_cache_define.vh"

module VX_cache_wrap import VX_gpu_pkg::*; #(
    parameter `STRING INSTANCE_ID    = "",

    parameter TAG_SEL_IDX           = 0,

    // Number of Word requests per cycle
    parameter NUM_REQS              = 4,

    // Number of memory ports
    parameter MEM_PORTS             = 1,

    // Size of cache in bytes
    parameter CACHE_SIZE            = 4096,
    // Size of line inside a bank in bytes
    parameter LINE_SIZE             = 64,
    // Number of banks
    parameter NUM_BANKS             = 4,
    // Number of associative ways
    parameter NUM_WAYS              = 4,
    // Size of a word in bytes
    parameter WORD_SIZE             = 16,

    // Core Response Queue Size
    parameter CRSQ_SIZE             = 4,
    // Miss Reserv Queue Knob
    parameter MSHR_SIZE             = 16,
    // Memory Response Queue Size
    parameter MRSQ_SIZE             = 4,
    // Memory Request Queue Size
    parameter MREQ_SIZE             = 4,

    // Enable cache writeable
    parameter WRITE_ENABLE          = 1,

    // Enable cache writeback
    parameter WRITEBACK             = 0,

    // Enable dirty bytes on writeback
    parameter DIRTY_BYTES           = 0,

    // Replacement policy
    parameter REPL_POLICY           = `CS_REPL_FIFO,

    // core request tag size
    parameter TAG_WIDTH             = UUID_WIDTH + 1,

    // enable bypass for non-cacheable addresses
    parameter NC_ENABLE             = 0,

    // Force bypass for all requests
    parameter PASSTHRU              = 0,

    // Core response output buffer
    parameter CORE_OUT_BUF          = 3,

	    // Memory request output buffer
	    parameter MEM_OUT_BUF           = 3,

	    // Hardware debug source metadata
	    parameter DEBUG_CACHE_KIND      = HW_DBG_CACHE_KIND_NONE,
	    parameter DEBUG_CACHE_LOCATION  = 0,
	    parameter DEBUG_CACHE_UNIT      = 0
	 ) (

    input wire clk,
    input wire reset,

    // PERF
`ifdef PERF_ENABLE
    output cache_perf_t     cache_perf,
`endif

	    VX_mem_bus_if.slave     core_bus_if [NUM_REQS],
	    VX_mem_bus_if.master    mem_bus_if [MEM_PORTS],

	`ifdef ENABLE_HW_DEBUG_CACHE
	    output cache_debug_t    cache_debug,
	`endif

	    output wire             cache_drain
	);

    `VX_STATIC_ASSERT(NUM_BANKS == (1 << `CLOG2(NUM_BANKS)), ("invalid parameter"))

    localparam CACHE_MEM_TAG_WIDTH = `CACHE_MEM_TAG_WIDTH(MSHR_SIZE, NUM_BANKS, MEM_PORTS, UUID_WIDTH);
    localparam BYPASS_TAG_WIDTH = `CACHE_BYPASS_TAG_WIDTH(NUM_REQS, MEM_PORTS, LINE_SIZE, WORD_SIZE, TAG_WIDTH);
    localparam NC_TAG_WIDTH = `MAX(CACHE_MEM_TAG_WIDTH, BYPASS_TAG_WIDTH) + 1;
    localparam MEM_TAG_WIDTH = PASSTHRU ? BYPASS_TAG_WIDTH : (NC_ENABLE ? NC_TAG_WIDTH : CACHE_MEM_TAG_WIDTH);
    localparam BYPASS_ENABLE = (NC_ENABLE || PASSTHRU);

    VX_mem_bus_if #(
        .DATA_SIZE (WORD_SIZE),
        .TAG_WIDTH (TAG_WIDTH)
    ) core_bus_cache_if[NUM_REQS]();

    VX_mem_bus_if #(
        .DATA_SIZE (LINE_SIZE),
        .TAG_WIDTH (CACHE_MEM_TAG_WIDTH)
    ) mem_bus_cache_if[MEM_PORTS]();

    VX_mem_bus_if #(
        .DATA_SIZE (LINE_SIZE),
        .TAG_WIDTH (MEM_TAG_WIDTH)
    ) mem_bus_tmp_if[MEM_PORTS]();

    wire [NUM_REQS-1:0] core_in_req_pending;
    wire [NUM_REQS-1:0] core_in_rsp_pending;
    wire [NUM_REQS-1:0] core_cache_req_pending;
    wire [NUM_REQS-1:0] core_cache_rsp_pending;

    wire [MEM_PORTS-1:0] mem_cache_req_pending;
    wire [MEM_PORTS-1:0] mem_cache_rsp_pending;
    wire [MEM_PORTS-1:0] mem_out_req_pending;
    wire [MEM_PORTS-1:0] mem_out_rsp_pending;

    for (genvar i = 0; i < NUM_REQS; ++i) begin : g_drain_core_pending
        assign core_in_req_pending[i] = core_bus_if[i].req_valid;
        assign core_in_rsp_pending[i] = core_bus_if[i].rsp_valid;
        assign core_cache_req_pending[i] = core_bus_cache_if[i].req_valid;
        assign core_cache_rsp_pending[i] = core_bus_cache_if[i].rsp_valid;
    end

    for (genvar i = 0; i < MEM_PORTS; ++i) begin : g_drain_mem_pending
        assign mem_cache_req_pending[i] = mem_bus_cache_if[i].req_valid;
        assign mem_cache_rsp_pending[i] = mem_bus_cache_if[i].rsp_valid;
        assign mem_out_req_pending[i] = mem_bus_tmp_if[i].req_valid;
        assign mem_out_rsp_pending[i] = mem_bus_tmp_if[i].rsp_valid;
    end

    wire wrap_core_pending = (| core_in_req_pending)
                          || (| core_in_rsp_pending)
                          || (| core_cache_req_pending)
                          || (| core_cache_rsp_pending);

    wire wrap_mem_pending = (| mem_cache_req_pending)
                         || (| mem_cache_rsp_pending)
                         || (| mem_out_req_pending)
                         || (| mem_out_rsp_pending);

    if (BYPASS_ENABLE) begin : g_bypass

        VX_cache_bypass #(
            .NUM_REQS          (NUM_REQS),
            .MEM_PORTS         (MEM_PORTS),
            .TAG_SEL_IDX       (TAG_SEL_IDX),

            .CACHE_ENABLE      (!PASSTHRU),

            .WORD_SIZE         (WORD_SIZE),
            .LINE_SIZE         (LINE_SIZE),

            .CORE_ADDR_WIDTH   (`CS_WORD_ADDR_WIDTH),
            .CORE_TAG_WIDTH    (TAG_WIDTH),

            .MEM_ADDR_WIDTH    (`CS_MEM_ADDR_WIDTH),
            .MEM_TAG_IN_WIDTH  (CACHE_MEM_TAG_WIDTH),

            .CORE_OUT_BUF      (CORE_OUT_BUF),
            .MEM_OUT_BUF       (MEM_OUT_BUF)
        ) cache_bypass (
            .clk            (clk),
            .reset          (reset),

            .core_bus_in_if (core_bus_if),
            .core_bus_out_if(core_bus_cache_if),

            .mem_bus_in_if  (mem_bus_cache_if),
            .mem_bus_out_if (mem_bus_tmp_if)
        );

    end else begin : g_no_bypass

        for (genvar i = 0; i < NUM_REQS; ++i) begin : g_core_bus_cache_if
            `ASSIGN_VX_MEM_BUS_IF (core_bus_cache_if[i], core_bus_if[i]);
        end

        for (genvar i = 0; i < MEM_PORTS; ++i) begin : g_mem_bus_tmp_if
            `ASSIGN_VX_MEM_BUS_IF (mem_bus_tmp_if[i], mem_bus_cache_if[i]);
        end
    end

    for (genvar i = 0; i < MEM_PORTS; ++i) begin : g_mem_bus_if
        if (WRITE_ENABLE) begin : g_we
            `ASSIGN_VX_MEM_BUS_IF (mem_bus_if[i], mem_bus_tmp_if[i]);
        end else begin : g_ro
            `ASSIGN_VX_MEM_BUS_RO_IF (mem_bus_if[i], mem_bus_tmp_if[i]);
        end
    end

    if (PASSTHRU == 0) begin : g_cache
        wire cache_core_drain;

        VX_cache #(
            .INSTANCE_ID  (INSTANCE_ID),
            .CACHE_SIZE   (CACHE_SIZE),
            .LINE_SIZE    (LINE_SIZE),
            .NUM_BANKS    (NUM_BANKS),
            .NUM_WAYS     (NUM_WAYS),
            .WORD_SIZE    (WORD_SIZE),
            .NUM_REQS     (NUM_REQS),
            .MEM_PORTS    (MEM_PORTS),
            .WRITE_ENABLE (WRITE_ENABLE),
            .WRITEBACK    (WRITEBACK),
            .DIRTY_BYTES  (DIRTY_BYTES),
            .REPL_POLICY  (REPL_POLICY),
            .CRSQ_SIZE    (CRSQ_SIZE),
            .MSHR_SIZE    (MSHR_SIZE),
            .MRSQ_SIZE    (MRSQ_SIZE),
            .MREQ_SIZE    (MREQ_SIZE),
            .TAG_WIDTH    (TAG_WIDTH),
            .CORE_OUT_BUF (BYPASS_ENABLE ? 1 : CORE_OUT_BUF),
            .MEM_OUT_BUF  (BYPASS_ENABLE ? 1 : MEM_OUT_BUF)
        ) cache (
            .clk            (clk),
            .reset          (reset),
        `ifdef PERF_ENABLE
            .cache_perf     (cache_perf),
        `endif
            .core_bus_if    (core_bus_cache_if),
            .mem_bus_if     (mem_bus_cache_if),
            .cache_drain    (cache_core_drain)
        );

        assign cache_drain = cache_core_drain
                          && ~wrap_core_pending
                          && ~wrap_mem_pending;

    end else begin : g_passthru

        for (genvar i = 0; i < NUM_REQS; ++i) begin : g_core_bus_cache_if
            `UNUSED_VX_MEM_BUS_IF (core_bus_cache_if[i])
        end

        for (genvar i = 0; i < MEM_PORTS; ++i) begin : g_mem_bus_cache_if
            `INIT_VX_MEM_BUS_IF (mem_bus_cache_if[i])
        end

    `ifdef PERF_ENABLE
        wire [NUM_REQS-1:0]  perf_core_reads_per_req;
        wire [NUM_REQS-1:0]  perf_core_writes_per_req;
        wire [NUM_REQS-1:0]  perf_crsp_stall_per_req;
        wire [MEM_PORTS-1:0] perf_mem_stall_per_port;

        for (genvar i = 0; i < NUM_REQS; ++i) begin : g_perf_crsp_stall_per_req
            assign perf_core_reads_per_req[i] = core_bus_if[i].req_valid && core_bus_if[i].req_ready && ~core_bus_if[i].req_data.rw;
            assign perf_core_writes_per_req[i] = core_bus_if[i].req_valid && core_bus_if[i].req_ready && core_bus_if[i].req_data.rw;
            assign perf_crsp_stall_per_req[i] = core_bus_if[i].rsp_valid && ~core_bus_if[i].rsp_ready;
        end

        for (genvar i = 0; i < MEM_PORTS; ++i) begin : g_perf_mem_stall_per_port
            assign perf_mem_stall_per_port[i] = mem_bus_if[i].req_valid && ~mem_bus_if[i].req_ready;
        end

        // per cycle: read misses, write misses, msrq stalls, pipeline stalls
        wire [`CLOG2(NUM_REQS+1)-1:0]  perf_core_reads_per_cycle;
        wire [`CLOG2(NUM_REQS+1)-1:0]  perf_core_writes_per_cycle;
        wire [`CLOG2(NUM_REQS+1)-1:0]  perf_crsp_stall_per_cycle;
        wire [`CLOG2(MEM_PORTS+1)-1:0] perf_mem_stall_per_cycle;
        reg  [`CLOG2(NUM_REQS+1)-1:0]  perf_core_reads_per_cycle_q;

        `POP_COUNT(perf_core_reads_per_cycle, perf_core_reads_per_req);
        `POP_COUNT(perf_core_writes_per_cycle, perf_core_writes_per_req);
        `POP_COUNT(perf_crsp_stall_per_cycle, perf_crsp_stall_per_req);
        `POP_COUNT(perf_mem_stall_per_cycle, perf_mem_stall_per_port);

        reg [PERF_CTR_BITS-1:0] perf_core_reads;
        reg [PERF_CTR_BITS-1:0] perf_core_writes;
        reg [PERF_CTR_BITS-1:0] perf_mem_stalls;
        reg [PERF_CTR_BITS-1:0] perf_crsp_stalls;

        always @(posedge clk) begin
            if (reset) begin
                perf_core_reads_per_cycle_q <= '0;
                perf_core_reads   <= '0;
                perf_core_writes  <= '0;
                perf_mem_stalls   <= '0;
                perf_crsp_stalls  <= '0;
            end else begin
                perf_core_reads_per_cycle_q <= perf_core_reads_per_cycle;
                perf_core_reads   <= perf_core_reads   + PERF_CTR_BITS'(perf_core_reads_per_cycle_q);
                perf_core_writes  <= perf_core_writes  + PERF_CTR_BITS'(perf_core_writes_per_cycle);
                perf_mem_stalls   <= perf_mem_stalls   + PERF_CTR_BITS'(perf_mem_stall_per_cycle);
                perf_crsp_stalls  <= perf_crsp_stalls  + PERF_CTR_BITS'(perf_crsp_stall_per_cycle);
            end
        end

    `ifndef SYNTHESIS
        reg [PERF_CTR_BITS-1:0] perf_core_reads_ref_r;
        reg [PERF_CTR_BITS-1:0] perf_core_reads_ref_q;

        always @(posedge clk) begin
            if (reset) begin
                perf_core_reads_ref_r <= '0;
                perf_core_reads_ref_q <= '0;
            end else begin
                assert (perf_core_reads == perf_core_reads_ref_q)
                    else $fatal(1, "%s: staged bypass-cache read recurrence mismatch", INSTANCE_ID);

                perf_core_reads_ref_r <= perf_core_reads_ref_r
                    + PERF_CTR_BITS'(perf_core_reads_per_cycle);
                perf_core_reads_ref_q <= perf_core_reads_ref_r;
            end
        end
    `endif

        assign cache_perf.reads        = perf_core_reads;
        assign cache_perf.writes       = perf_core_writes;
        assign cache_perf.read_misses  = '0;
        assign cache_perf.write_misses = '0;
        assign cache_perf.bank_stalls  = '0;
        assign cache_perf.mshr_stalls  = '0;
        assign cache_perf.mem_stalls   = perf_mem_stalls;
        assign cache_perf.crsp_stalls  = perf_crsp_stalls;
    `endif

        assign cache_drain = ~wrap_core_pending
                          && ~wrap_mem_pending;

	    end

	`ifdef ENABLE_HW_DEBUG_CACHE
	    assign cache_debug.valid = 1'b1;
	    assign cache_debug.kind = 4'(DEBUG_CACHE_KIND);
	    assign cache_debug.location = 16'(DEBUG_CACHE_LOCATION);
	    assign cache_debug.unit = 8'(DEBUG_CACHE_UNIT);
	    assign cache_debug.passthru = PASSTHRU;
	    assign cache_debug.write_enable = WRITE_ENABLE;
	    assign cache_debug.core_port_count = 8'(NUM_REQS);
	    assign cache_debug.mem_port_count = 8'(MEM_PORTS);

	    for (genvar i = 0; i < HW_DEBUG_CACHE_MAX_PORTS; ++i) begin : g_hw_debug_cache_core_ports
	        if (i < NUM_REQS) begin : g_active
	            assign cache_debug.core_ports[i].req_valid = core_bus_if[i].req_valid;
	            assign cache_debug.core_ports[i].req_ready = core_bus_if[i].req_ready;
	            assign cache_debug.core_ports[i].req_fire = core_bus_if[i].req_valid && core_bus_if[i].req_ready;
	            assign cache_debug.core_ports[i].req_stall = core_bus_if[i].req_valid && !core_bus_if[i].req_ready;
	            assign cache_debug.core_ports[i].rsp_valid = core_bus_if[i].rsp_valid;
	            assign cache_debug.core_ports[i].rsp_ready = core_bus_if[i].rsp_ready;
	            assign cache_debug.core_ports[i].rsp_fire = core_bus_if[i].rsp_valid && core_bus_if[i].rsp_ready;
	            assign cache_debug.core_ports[i].rsp_stall = core_bus_if[i].rsp_valid && !core_bus_if[i].rsp_ready;
	            assign cache_debug.core_ports[i].req_rw = core_bus_if[i].req_data.rw;
	            assign cache_debug.core_ports[i].req_addr = 48'(core_bus_if[i].req_data.addr);
	            assign cache_debug.core_ports[i].req_tag = 16'(core_bus_if[i].req_data.tag.uuid)
	                                                     ^ 16'(core_bus_if[i].req_data.tag.value);
	            assign cache_debug.core_ports[i].rsp_tag = 16'(core_bus_if[i].rsp_data.tag.uuid)
	                                                     ^ 16'(core_bus_if[i].rsp_data.tag.value);
	            assign cache_debug.core_ports[i].req_payload_hash = 16'(core_bus_if[i].req_data.tag.uuid)
	                                                              ^ 16'(core_bus_if[i].req_data.tag.value)
	                                                              ^ 16'(core_bus_if[i].req_data.addr)
	                                                              ^ 16'(core_bus_if[i].req_data.byteen)
	                                                              ^ 16'(core_bus_if[i].req_data.flags)
	                                                              ^ {15'b0, core_bus_if[i].req_data.rw};
	            assign cache_debug.core_ports[i].rsp_payload_hash = 16'(core_bus_if[i].rsp_data.tag.uuid)
	                                                              ^ 16'(core_bus_if[i].rsp_data.tag.value)
	                                                              ^ 16'(core_bus_if[i].rsp_data.data);
	        end else begin : g_inactive
	            assign cache_debug.core_ports[i] = '0;
	        end
	    end

	    for (genvar i = 0; i < HW_DEBUG_CACHE_MAX_PORTS; ++i) begin : g_hw_debug_cache_mem_ports
	        if (i < MEM_PORTS) begin : g_active
	            assign cache_debug.mem_ports[i].req_valid = mem_bus_if[i].req_valid;
	            assign cache_debug.mem_ports[i].req_ready = mem_bus_if[i].req_ready;
	            assign cache_debug.mem_ports[i].req_fire = mem_bus_if[i].req_valid && mem_bus_if[i].req_ready;
	            assign cache_debug.mem_ports[i].req_stall = mem_bus_if[i].req_valid && !mem_bus_if[i].req_ready;
	            assign cache_debug.mem_ports[i].rsp_valid = mem_bus_if[i].rsp_valid;
	            assign cache_debug.mem_ports[i].rsp_ready = mem_bus_if[i].rsp_ready;
	            assign cache_debug.mem_ports[i].rsp_fire = mem_bus_if[i].rsp_valid && mem_bus_if[i].rsp_ready;
	            assign cache_debug.mem_ports[i].rsp_stall = mem_bus_if[i].rsp_valid && !mem_bus_if[i].rsp_ready;
	            assign cache_debug.mem_ports[i].req_rw = mem_bus_if[i].req_data.rw;
	            assign cache_debug.mem_ports[i].req_addr = 48'(mem_bus_if[i].req_data.addr);
	            assign cache_debug.mem_ports[i].req_tag = 16'(mem_bus_if[i].req_data.tag.uuid)
	                                                    ^ 16'(mem_bus_if[i].req_data.tag.value);
	            assign cache_debug.mem_ports[i].rsp_tag = 16'(mem_bus_if[i].rsp_data.tag.uuid)
	                                                    ^ 16'(mem_bus_if[i].rsp_data.tag.value);
	            assign cache_debug.mem_ports[i].req_payload_hash = 16'(mem_bus_if[i].req_data.tag.uuid)
	                                                             ^ 16'(mem_bus_if[i].req_data.tag.value)
	                                                             ^ 16'(mem_bus_if[i].req_data.addr)
	                                                             ^ 16'(mem_bus_if[i].req_data.byteen)
	                                                             ^ 16'(mem_bus_if[i].req_data.flags)
	                                                             ^ {15'b0, mem_bus_if[i].req_data.rw};
	            assign cache_debug.mem_ports[i].rsp_payload_hash = 16'(mem_bus_if[i].rsp_data.tag.uuid)
	                                                             ^ 16'(mem_bus_if[i].rsp_data.tag.value)
	                                                             ^ 16'(mem_bus_if[i].rsp_data.data);
	        end else begin : g_inactive
	            assign cache_debug.mem_ports[i] = '0;
	        end
	    end
	`endif

	`ifdef DBG_TRACE_CACHE
	    for (genvar i = 0; i < NUM_REQS; ++i) begin : g_trace_core
        always @(posedge clk) begin
            if (core_bus_if[i].req_valid && core_bus_if[i].req_ready) begin
                if (core_bus_if[i].req_data.rw) begin
                    `TRACE(2, ("%t: %s core-wr-req[%0d]: addr=0x%0h, tag=0x%0h, byteen=0x%h, data=0x%h (#%0d)\n", $time, INSTANCE_ID, i, `TO_FULL_ADDR(core_bus_if[i].req_data.addr), core_bus_if[i].req_data.tag.value, core_bus_if[i].req_data.byteen, core_bus_if[i].req_data.data, core_bus_if[i].req_data.tag.uuid))
                end else begin
                    `TRACE(2, ("%t: %s core-rd-req[%0d]: addr=0x%0h, tag=0x%0h (#%0d)\n", $time, INSTANCE_ID, i, `TO_FULL_ADDR(core_bus_if[i].req_data.addr), core_bus_if[i].req_data.tag.value, core_bus_if[i].req_data.tag.uuid))
                end
            end
            if (core_bus_if[i].rsp_valid && core_bus_if[i].rsp_ready) begin
                `TRACE(2, ("%t: %s core-rd-rsp[%0d]: tag=0x%0h, data=0x%h (#%0d)\n", $time, INSTANCE_ID, i, core_bus_if[i].rsp_data.tag.value, core_bus_if[i].rsp_data.data, core_bus_if[i].rsp_data.tag.uuid))
            end
        end
    end

    for (genvar i = 0; i < MEM_PORTS; ++i) begin : g_trace_mem
        always @(posedge clk) begin
            if (mem_bus_if[i].req_valid && mem_bus_if[i].req_ready) begin
                if (mem_bus_if[i].req_data.rw) begin
                    `TRACE(2, ("%t: %s mem-wr-req[%0d]: addr=0x%0h, tag=0x%0h, byteen=0x%h, data=0x%h (#%0d)\n",
                        $time, INSTANCE_ID, i, `TO_FULL_ADDR(mem_bus_if[i].req_data.addr), mem_bus_if[i].req_data.tag.value, mem_bus_if[i].req_data.byteen, mem_bus_if[i].req_data.data, mem_bus_if[i].req_data.tag.uuid))
                end else begin
                    `TRACE(2, ("%t: %s mem-rd-req[%0d]: addr=0x%0h, tag=0x%0h (#%0d)\n",
                        $time, INSTANCE_ID, i, `TO_FULL_ADDR(mem_bus_if[i].req_data.addr), mem_bus_if[i].req_data.tag.value, mem_bus_if[i].req_data.tag.uuid))
                end
            end
            if (mem_bus_if[i].rsp_valid && mem_bus_if[i].rsp_ready) begin
                `TRACE(2, ("%t: %s mem-rd-rsp[%0d]: data=0x%h, tag=0x%0h (#%0d)\n",
                    $time, INSTANCE_ID, i, mem_bus_if[i].rsp_data.data, mem_bus_if[i].rsp_data.tag.value, mem_bus_if[i].rsp_data.tag.uuid))
            end
        end
    end
`endif

endmodule
