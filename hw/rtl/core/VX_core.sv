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

`ifdef EXT_F_ENABLE
`include "VX_fpu_define.vh"
`endif

module VX_core import VX_gpu_pkg::*; #(
    parameter CORE_ID = 0,
    parameter `STRING INSTANCE_ID = "",
    parameter NUM_TMEM_BANKS = `NUM_DMA_CHANNELS
) (
    `SCOPE_IO_DECL

    // Clock
    input wire              clk,
    input wire              reset,

`ifdef PERF_ENABLE
    input sysmem_perf_t     sysmem_perf,
`endif

    VX_dcr_bus_if.slave     dcr_bus_if,

    VX_mem_bus_if.master    dcache_bus_if [DCACHE_NUM_REQS],

    VX_mem_bus_if.master    icache_bus_if,

    // DMA AXI ports (from GEMM node's TMEM subsystem)
    AXI_BUS.Master          dma_axi_m [NUM_TMEM_BANKS],

`ifdef GBAR_ENABLE
    VX_gbar_bus_if.master   gbar_bus_if,
`endif

`ifdef ENABLE_HW_DEBUG_MODULE
    output wire                         hw_debug_pc_valid,
    output wire [HW_DEBUG_CORE_ID_WIDTH-1:0] hw_debug_pc_core_id,
    output wire [NW_WIDTH-1:0]          hw_debug_pc_wid,
    output wire [`XLEN-1:0]             hw_debug_pc,
`endif

    // Status
    output wire             busy
);
    VX_schedule_if      schedule_if();
    VX_fetch_if         fetch_if();
    VX_decode_if        decode_if();
    VX_sched_csr_if     sched_csr_if();
    VX_decode_sched_if  decode_sched_if();
    VX_issue_sched_if   issue_sched_if[`ISSUE_WIDTH]();
    VX_commit_sched_if  commit_sched_if();
    VX_commit_csr_if    commit_csr_if();
    VX_branch_ctl_if    branch_ctl_if[`NUM_ALU_BLOCKS]();
    VX_warp_ctl_if      warp_ctl_if();

    VX_dispatch_if      dispatch_if[NUM_EX_UNITS * `ISSUE_WIDTH]();
    VX_commit_if        commit_if[NUM_EX_UNITS * `ISSUE_WIDTH]();
    VX_writeback_if     writeback_if[`ISSUE_WIDTH]();

    VX_lsu_mem_if #(
        .NUM_LANES (`NUM_LSU_LANES),
        .DATA_SIZE (LSU_WORD_SIZE),
        .TAG_WIDTH (LSU_TAG_WIDTH)
    ) lsu_mem_if[`NUM_LSU_BLOCKS]();

    // DMA control interfaces from mem_unit
    VX_lsu_mem_if #(
        .NUM_LANES (`NUM_LSU_LANES),
        .DATA_SIZE (LSU_WORD_SIZE),
        .TAG_WIDTH (LSU_TAG_WIDTH)
    ) dma_ctrl_if[`NUM_LSU_BLOCKS]();

    // GEMM control interfaces from mem_unit
    VX_lsu_mem_if #(
        .NUM_LANES (`NUM_LSU_LANES),
        .DATA_SIZE (LSU_WORD_SIZE),
        .TAG_WIDTH (LSU_TAG_WIDTH)
    ) gemm_ctrl_if[`NUM_LSU_BLOCKS]();

    // DMA data interfaces to mem_unit
    VX_mem_bus_if #(
        .DATA_SIZE (LSU_WORD_SIZE),
        .TAG_WIDTH (LMEM_TAG_WIDTH)
    ) dma_local_data_if();

    VX_mem_bus_if #(
        .DATA_SIZE (DCACHE_WORD_SIZE),
        .TAG_WIDTH (DCACHE_TAG_WIDTH)
    ) dma_global_data_if();


`ifdef PERF_ENABLE
    lmem_perf_t lmem_perf;
    coalescer_perf_t coalescer_perf;
    pipeline_perf_t pipeline_perf;
    sysmem_perf_t sysmem_perf_tmp;
    accel_perf_t accel_perf;
    always @(*) begin
        sysmem_perf_tmp = sysmem_perf;
        sysmem_perf_tmp.lmem = lmem_perf;
        sysmem_perf_tmp.coalescer = coalescer_perf;
    end
`endif

    base_dcrs_t base_dcrs;

    VX_dcr_data dcr_data (
        .clk        (clk),
        .reset      (reset),
        .dcr_bus_if (dcr_bus_if),
        .base_dcrs  (base_dcrs)
    );

    `SCOPE_IO_SWITCH (3);

    VX_schedule #(
        .INSTANCE_ID (`SFORMATF(("%s-schedule", INSTANCE_ID))),
        .CORE_ID (CORE_ID)
    ) schedule (
        .clk            (clk),
        .reset          (reset),

    `ifdef PERF_ENABLE
        .sched_perf     (pipeline_perf.sched),
    `endif

        .base_dcrs      (base_dcrs),

        .warp_ctl_if    (warp_ctl_if),
        .branch_ctl_if  (branch_ctl_if),

        .decode_sched_if(decode_sched_if),
        .issue_sched_if (issue_sched_if),
        .commit_sched_if(commit_sched_if),

        .schedule_if    (schedule_if),
    `ifdef GBAR_ENABLE
        .gbar_bus_if    (gbar_bus_if),
    `endif
        .sched_csr_if   (sched_csr_if),

        .busy           (busy)
    );

    VX_fetch #(
        .INSTANCE_ID (`SFORMATF(("%s-fetch", INSTANCE_ID)))
    ) fetch (
        `SCOPE_IO_BIND  (0)
        .clk            (clk),
        .reset          (reset),
        .icache_bus_if  (icache_bus_if),
        .schedule_if    (schedule_if),
        .fetch_if       (fetch_if)
    );

    VX_decode #(
        .INSTANCE_ID (`SFORMATF(("%s-decode", INSTANCE_ID)))
    ) decode (
        .clk            (clk),
        .reset          (reset),
        .fetch_if       (fetch_if),
        .decode_if      (decode_if),
        .decode_sched_if(decode_sched_if)
    );

    VX_issue #(
        .INSTANCE_ID (`SFORMATF(("%s-issue", INSTANCE_ID)))
    ) issue (
        `SCOPE_IO_BIND  (1)

        .clk            (clk),
        .reset          (reset),

    `ifdef PERF_ENABLE
        .issue_perf     (pipeline_perf.issue),
    `endif

        .decode_if      (decode_if),
        .writeback_if   (writeback_if),
        .dispatch_if    (dispatch_if),
        .issue_sched_if (issue_sched_if)
    );

    VX_execute #(
        .INSTANCE_ID (`SFORMATF(("%s-execute", INSTANCE_ID))),
        .CORE_ID (CORE_ID)
    ) execute (
        `SCOPE_IO_BIND  (2)

        .clk            (clk),
        .reset          (reset),

    `ifdef PERF_ENABLE
        .sysmem_perf    (sysmem_perf_tmp),
        .pipeline_perf  (pipeline_perf),
        .accel_perf     (accel_perf),
    `endif

        .base_dcrs      (base_dcrs),

        .lsu_mem_if     (lsu_mem_if),

        .dispatch_if    (dispatch_if),
        .commit_if      (commit_if),

        .commit_csr_if  (commit_csr_if),
        .sched_csr_if   (sched_csr_if),

        .warp_ctl_if    (warp_ctl_if),
        .branch_ctl_if  (branch_ctl_if)
    );

    VX_commit #(
        .INSTANCE_ID (`SFORMATF(("%s-commit", INSTANCE_ID)))
    ) commit (
        .clk            (clk),
        .reset          (reset),

        .commit_if      (commit_if),

        .writeback_if   (writeback_if),

        .commit_csr_if  (commit_csr_if),
        .commit_sched_if(commit_sched_if)
    `ifdef ENABLE_HW_DEBUG_MODULE
        ,
        .hw_debug_pc_valid (hw_debug_pc_valid),
        .hw_debug_pc_wid   (hw_debug_pc_wid),
        .hw_debug_pc       (hw_debug_pc)
    `endif
    );

`ifdef ENABLE_HW_DEBUG_MODULE
    assign hw_debug_pc_core_id = HW_DEBUG_CORE_ID_WIDTH'(CORE_ID);
`endif

    VX_mem_unit #(
        .INSTANCE_ID (INSTANCE_ID)
    ) mem_unit (
        .clk              (clk),
        .reset            (reset),
    `ifdef PERF_ENABLE
        .lmem_perf        (lmem_perf),
        .coalescer_perf   (coalescer_perf),
    `endif
        .lsu_mem_if        (lsu_mem_if),
        .dcache_bus_if     (dcache_bus_if),
        .dma_ctrl_if       (dma_ctrl_if),
        .gemm_ctrl_if      (gemm_ctrl_if),
        .dma_local_data_if (dma_local_data_if),
        .dma_global_data_if(dma_global_data_if)
    );

    VX_dma_node #(
      .INSTANCE_ID(INSTANCE_ID),
      .N_MASTER(`NUM_LSU_BLOCKS),
      .NUM_ENTRIES(`JOB_MMIO_NUM_ENTRIES)
    ) u_VX_dma_node (
      .clk(clk),
      .reset(reset),
    `ifdef PERF_ENABLE
      .perf(accel_perf.cpu_dma),
    `endif
      .mmio_if(dma_ctrl_if),
      .dcache_bus_if(dma_global_data_if),
      .lmem_bus_if(dma_local_data_if)
    );

`ifdef ENABLE_GEMM_ACCEL

    VX_gemm_node #(
        .INSTANCE_ID (`SFORMATF(("%s-gemm", INSTANCE_ID))),
        .N_MASTER (`NUM_LSU_BLOCKS),
        .NUM_TMEM_BANKS (NUM_TMEM_BANKS)
    ) gemm_node (
        .clk         (clk),
        .reset       (reset),
    `ifdef PERF_ENABLE
        .gemm_unit_perf       (accel_perf.gemm_unit),
        .gemm_node_perf       (accel_perf.gemm_node),
        .hbm_dma_perf         (accel_perf.hbm_dma),
        .lmem_dma_input_perf  (accel_perf.lmem_dma_input),
        .lmem_dma_weight_perf (accel_perf.lmem_dma_weight),
        .lmem_dma_sz_perf     (accel_perf.lmem_dma_sz),
        .lmem_dma_output_perf (accel_perf.lmem_dma_output),
    `endif
        .mmio_if     (gemm_ctrl_if),
        .dma_axi_m   (dma_axi_m)
    );

`else

    for (genvar i = 0; i < `NUM_LSU_BLOCKS; ++i) begin : g_disabled_gemm_ctrl
        VX_lsu_mem_zero_rsp #(
            .NUM_LANES (`NUM_LSU_LANES),
            .DATA_SIZE (LSU_WORD_SIZE),
            .TAG_WIDTH (LSU_TAG_WIDTH)
        ) gemm_ctrl_rsp (
            .clk    (clk),
            .reset  (reset),
            .mem_if (gemm_ctrl_if[i])
        );
    end

    for (genvar i = 0; i < NUM_TMEM_BANKS; ++i) begin : g_disabled_gemm_dma_axi
        assign dma_axi_m[i].aw_id     = '0;
        assign dma_axi_m[i].aw_addr   = '0;
        assign dma_axi_m[i].aw_len    = '0;
        assign dma_axi_m[i].aw_size   = '0;
        assign dma_axi_m[i].aw_burst  = '0;
        assign dma_axi_m[i].aw_lock   = 1'b0;
        assign dma_axi_m[i].aw_cache  = '0;
        assign dma_axi_m[i].aw_prot   = '0;
        assign dma_axi_m[i].aw_qos    = '0;
        assign dma_axi_m[i].aw_region = '0;
        assign dma_axi_m[i].aw_atop   = '0;
        assign dma_axi_m[i].aw_user   = '0;
        assign dma_axi_m[i].aw_valid  = 1'b0;

        assign dma_axi_m[i].w_data    = '0;
        assign dma_axi_m[i].w_strb    = '0;
        assign dma_axi_m[i].w_last    = 1'b0;
        assign dma_axi_m[i].w_user    = '0;
        assign dma_axi_m[i].w_valid   = 1'b0;

        assign dma_axi_m[i].b_ready   = 1'b0;

        assign dma_axi_m[i].ar_id     = '0;
        assign dma_axi_m[i].ar_addr   = '0;
        assign dma_axi_m[i].ar_len    = '0;
        assign dma_axi_m[i].ar_size   = '0;
        assign dma_axi_m[i].ar_burst  = '0;
        assign dma_axi_m[i].ar_lock   = 1'b0;
        assign dma_axi_m[i].ar_cache  = '0;
        assign dma_axi_m[i].ar_prot   = '0;
        assign dma_axi_m[i].ar_qos    = '0;
        assign dma_axi_m[i].ar_region = '0;
        assign dma_axi_m[i].ar_user   = '0;
        assign dma_axi_m[i].ar_valid  = 1'b0;

        assign dma_axi_m[i].r_ready   = 1'b0;

        `UNUSED_VAR (dma_axi_m[i].aw_ready)
        `UNUSED_VAR (dma_axi_m[i].w_ready)
        `UNUSED_VAR (dma_axi_m[i].b_id)
        `UNUSED_VAR (dma_axi_m[i].b_resp)
        `UNUSED_VAR (dma_axi_m[i].b_user)
        `UNUSED_VAR (dma_axi_m[i].b_valid)
        `UNUSED_VAR (dma_axi_m[i].ar_ready)
        `UNUSED_VAR (dma_axi_m[i].r_id)
        `UNUSED_VAR (dma_axi_m[i].r_data)
        `UNUSED_VAR (dma_axi_m[i].r_resp)
        `UNUSED_VAR (dma_axi_m[i].r_last)
        `UNUSED_VAR (dma_axi_m[i].r_user)
        `UNUSED_VAR (dma_axi_m[i].r_valid)
    end

`ifdef PERF_ENABLE
    assign accel_perf.gemm_unit       = '0;
    assign accel_perf.gemm_node       = '0;
    assign accel_perf.hbm_dma         = '0;
    assign accel_perf.lmem_dma_input  = '0;
    assign accel_perf.lmem_dma_weight = '0;
    assign accel_perf.lmem_dma_sz     = '0;
    assign accel_perf.lmem_dma_output = '0;
`endif

`endif

`ifdef PERF_ENABLE

    wire [`CLOG2(LSU_NUM_REQS+1)-1:0] perf_dcache_rd_req_per_cycle;
    wire [`CLOG2(LSU_NUM_REQS+1)-1:0] perf_dcache_wr_req_per_cycle;
    wire [`CLOG2(LSU_NUM_REQS+1)-1:0] perf_dcache_rsp_per_cycle;

    wire [1:0] perf_icache_pending_read_cycle;
    wire [`CLOG2(LSU_NUM_REQS+1)+1-1:0] perf_dcache_pending_read_cycle;

    reg [PERF_CTR_BITS-1:0] perf_icache_pending_reads;
    reg [PERF_CTR_BITS-1:0] perf_dcache_pending_reads;

    reg [PERF_CTR_BITS-1:0] perf_ifetches;
    reg [PERF_CTR_BITS-1:0] perf_loads;
    reg [PERF_CTR_BITS-1:0] perf_stores;

    wire perf_icache_req_fire = icache_bus_if.req_valid && icache_bus_if.req_ready;
    wire perf_icache_rsp_fire = icache_bus_if.rsp_valid && icache_bus_if.rsp_ready;

    wire [LSU_NUM_REQS-1:0] perf_dcache_rd_req_fire, perf_dcache_rd_req_fire_r;
    wire [LSU_NUM_REQS-1:0] perf_dcache_wr_req_fire, perf_dcache_wr_req_fire_r;
    wire [LSU_NUM_REQS-1:0] perf_dcache_rsp_fire;

    for (genvar i = 0; i < `NUM_LSU_BLOCKS; ++i) begin : g_perf_dcache
        for (genvar j = 0; j < `NUM_LSU_LANES; ++j) begin : g_j
            assign perf_dcache_rd_req_fire[i * `NUM_LSU_LANES + j] = lsu_mem_if[i].req_valid && lsu_mem_if[i].req_data.mask[j] && lsu_mem_if[i].req_ready && ~lsu_mem_if[i].req_data.rw;
            assign perf_dcache_wr_req_fire[i * `NUM_LSU_LANES + j] = lsu_mem_if[i].req_valid && lsu_mem_if[i].req_data.mask[j] && lsu_mem_if[i].req_ready && lsu_mem_if[i].req_data.rw;
            assign perf_dcache_rsp_fire[i * `NUM_LSU_LANES + j] = lsu_mem_if[i].rsp_valid && lsu_mem_if[i].rsp_data.mask[j] && lsu_mem_if[i].rsp_ready;
        end
    end

    `BUFFER(perf_dcache_rd_req_fire_r, perf_dcache_rd_req_fire);
    `BUFFER(perf_dcache_wr_req_fire_r, perf_dcache_wr_req_fire);

    `POP_COUNT(perf_dcache_rd_req_per_cycle, perf_dcache_rd_req_fire_r);
    `POP_COUNT(perf_dcache_wr_req_per_cycle, perf_dcache_wr_req_fire_r);
    `POP_COUNT(perf_dcache_rsp_per_cycle, perf_dcache_rsp_fire);

    assign perf_icache_pending_read_cycle = perf_icache_req_fire - perf_icache_rsp_fire;
    assign perf_dcache_pending_read_cycle = perf_dcache_rd_req_per_cycle - perf_dcache_rsp_per_cycle;

    always @(posedge clk) begin
        if (reset) begin
            perf_icache_pending_reads <= '0;
            perf_dcache_pending_reads <= '0;
        end else begin
            perf_icache_pending_reads <= $signed(perf_icache_pending_reads) + PERF_CTR_BITS'($signed(perf_icache_pending_read_cycle));
            perf_dcache_pending_reads <= $signed(perf_dcache_pending_reads) + PERF_CTR_BITS'($signed(perf_dcache_pending_read_cycle));
        end
    end

    reg [PERF_CTR_BITS-1:0] perf_icache_lat;
    reg [PERF_CTR_BITS-1:0] perf_dcache_lat;

    always @(posedge clk) begin
        if (reset) begin
            perf_ifetches   <= '0;
            perf_loads      <= '0;
            perf_stores     <= '0;
            perf_icache_lat <= '0;
            perf_dcache_lat <= '0;
        end else begin
            perf_ifetches   <= perf_ifetches   + PERF_CTR_BITS'(perf_icache_req_fire);
            perf_loads      <= perf_loads      + PERF_CTR_BITS'(perf_dcache_rd_req_per_cycle);
            perf_stores     <= perf_stores     + PERF_CTR_BITS'(perf_dcache_wr_req_per_cycle);
            perf_icache_lat <= perf_icache_lat + perf_icache_pending_reads;
            perf_dcache_lat <= perf_dcache_lat + perf_dcache_pending_reads;
        end
    end

    assign pipeline_perf.ifetches = perf_ifetches;
    assign pipeline_perf.loads = perf_loads;
    assign pipeline_perf.stores = perf_stores;
    assign pipeline_perf.ifetch_latency = perf_icache_lat;
    assign pipeline_perf.load_latency = perf_dcache_lat;

    // Overlap counter: cycles where any DMA is busy AND the GEMM unit is computing.
    // OR across cpu_dma + hbm_dma aggregate + all 4 per-LDMA busy bits.
    wire any_dma_busy = accel_perf.cpu_dma.busy
                      | accel_perf.hbm_dma.aggregate.busy
                      | accel_perf.lmem_dma_input.busy
                      | accel_perf.lmem_dma_weight.busy
                      | accel_perf.lmem_dma_sz.busy
                      | accel_perf.lmem_dma_output.busy;
    reg [PERF_CTR_BITS-1:0] perf_overlap_r;
    always @(posedge clk) begin
        if (reset)
            perf_overlap_r <= '0;
        else if (any_dma_busy && accel_perf.gemm_unit.computing)
            perf_overlap_r <= perf_overlap_r + PERF_CTR_BITS'(1);
    end
    assign accel_perf.overlap_dma_mxu = perf_overlap_r;

    // Busy counter: cycles where this core has an active kernel
    // (active warps or pending instructions — VX_core.busy = VX_schedule.busy).
    // Per-core counter; sums across cores in the runtime represent total
    // core-busy work across the device.
    reg [PERF_CTR_BITS-1:0] perf_busy_r;
    always @(posedge clk) begin
        if (reset)
            perf_busy_r <= '0;
        else if (busy)
            perf_busy_r <= perf_busy_r + PERF_CTR_BITS'(1);
    end
    assign accel_perf.busy_cycles = perf_busy_r;

`endif

endmodule
