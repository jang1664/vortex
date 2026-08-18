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
    parameter NUM_TMEM_BANKS = `NUM_TMEM_BANKS,
    parameter NUM_DMA_CHANNELS = `NUM_DMA_CHANNELS,
    parameter int DMA_STORE_MAX_CHUNK_BEATS =
        `GEMM_DMA_STORE_MAX_CHUNK_BEATS
) (
    `SCOPE_IO_DECL

    // Clock
    input wire              clk,
    input wire              reset,

`ifdef PERF_ENABLE
    input sysmem_perf_t     sysmem_perf,
`endif

    VX_dcr_bus_if.slave     dcr_bus_if,

    VX_mem_bus_if.master    dcache_bus_if [DCACHE_CORE_NUM_REQS],

    VX_mem_bus_if.master    icache_bus_if,

    // DMA AXI ports (from GEMM node's TMEM subsystem)
    AXI_BUS.Master          dma_axi_m [NUM_DMA_CHANNELS],

`ifdef GBAR_ENABLE
    VX_gbar_bus_if.master   gbar_bus_if,
`endif

`ifdef ENABLE_HW_DEBUG_PC
	    output wire                         hw_debug_pc_valid,
	    output wire [HW_DEBUG_CORE_ID_WIDTH-1:0] hw_debug_pc_core_id,
	    output wire [NW_WIDTH-1:0]          hw_debug_pc_wid,
	    output wire [`XLEN-1:0]             hw_debug_pc,
`endif
`ifdef ENABLE_HW_DEBUG_CORE
	    output core_pipeline_debug_t        core_pipeline_debug,
`endif
`ifdef ENABLE_HW_DEBUG_GEMM
        output gemm_unit_debug_t           gemm_unit_debug,
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
`ifdef GEMM_NAIVE
    ) dma_ctrl_if[`NUM_LSU_BLOCKS+1]();
`else
    ) dma_ctrl_if[`NUM_LSU_BLOCKS]();
`endif

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
    ) dma_local_data_if[`LMEM_NUM_PORTS]();

`ifdef GEMM_NAIVE
    // Shared-LMEM GEMM data path used by the naive backend.
    VX_mem_bus_if #(
        .DATA_SIZE (LSU_WORD_SIZE),
        .TAG_WIDTH (GEMM_LMEM_TAG_WIDTH)
    ) gemm_data_if[`LMEM_NUM_PORTS]();
    VX_mem_bus_if #(
        .DATA_SIZE (LSU_WORD_SIZE),
        .TAG_WIDTH (PSUM_LMEM_TAG_WIDTH)
    ) gemm_psum_rd_if[`LMEM_NUM_PORTS]();
    VX_mem_bus_if #(
        .DATA_SIZE (LSU_WORD_SIZE),
        .TAG_WIDTH (PSUM_ARB_TAG_WIDTH)
    ) gemm_psum_wr_if[`LMEM_NUM_PORTS]();
`endif

	    VX_mem_bus_if #(
	        .DATA_SIZE (`DMA_DCACHE_PORTS * DCACHE_WORD_SIZE),
	        .TAG_WIDTH (DMA_DCACHE_TAG_WIDTH)
	    ) dma_global_data_if();

	`ifdef ENABLE_HW_DEBUG_CORE
	    issue_pipeline_debug_t issue_pipeline_debug;
	`endif


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
	    `ifdef ENABLE_HW_DEBUG_CORE
	        ,
	        .issue_pipeline_debug(issue_pipeline_debug)
	    `endif
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
    `ifdef ENABLE_HW_DEBUG_PC
        ,
        .hw_debug_pc_valid (hw_debug_pc_valid),
        .hw_debug_pc_wid   (hw_debug_pc_wid),
        .hw_debug_pc       (hw_debug_pc)
    `endif
    );

`ifdef ENABLE_HW_DEBUG_PC
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
`ifdef GEMM_NAIVE
        .dma_ctrl_if       (dma_ctrl_if[0:`NUM_LSU_BLOCKS-1]),
`else
        .dma_ctrl_if       (dma_ctrl_if),
`endif
        .gemm_ctrl_if      (gemm_ctrl_if),
        .dma_local_data_if (dma_local_data_if),
        .dma_global_data_if(dma_global_data_if)
`ifdef GEMM_NAIVE
       ,.gemm_data_if      (gemm_data_if)
       ,.gemm_psum_rd_if   (gemm_psum_rd_if)
       ,.gemm_psum_wr_if   (gemm_psum_wr_if)
`endif
    );

`ifdef GEMM_NAIVE
    VX_dma_node #(
      .INSTANCE_ID(INSTANCE_ID),
      .N_MASTER(`NUM_LSU_BLOCKS+1),
      .NUM_ENTRIES(`JOB_MMIO_NUM_ENTRIES),
      .LMEM_NUM_LANES_P(`LMEM_NUM_PORTS),
      .DCACHE_NUM_LANES_P(`DMA_DCACHE_PORTS),
      .DCACHE_TAG_WIDTH_P(DMA_DCACHE_TAG_WIDTH),
      .ENABLE_MISALIGN(1'b1),
      .MISALIGN_PACK_BYTES(`MISALIGN_PACK_BYTES)
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
`else
    for (genvar i = 0; i < `NUM_LSU_BLOCKS; ++i) begin : g_disabled_dma_ctrl
        VX_lsu_mem_zero_rsp #(
            .NUM_LANES (`NUM_LSU_LANES),
            .DATA_SIZE (LSU_WORD_SIZE),
            .TAG_WIDTH (LSU_TAG_WIDTH)
        ) dma_ctrl_rsp (
            .clk    (clk),
            .reset  (reset),
            .mem_if (dma_ctrl_if[i])
        );
    end

    for (genvar i = 0; i < `LMEM_NUM_PORTS; ++i) begin : g_disabled_dma_lmem
        `INIT_VX_MEM_BUS_IF (dma_local_data_if[i])
    end

    `INIT_VX_MEM_BUS_IF (dma_global_data_if)

`ifdef PERF_ENABLE
    assign accel_perf.cpu_dma = '0;
`endif
`endif

`ifdef ENABLE_GEMM_ACCEL

`ifdef GEMM_NAIVE

    VX_gemm_node_naive #(
        .INSTANCE_ID (`SFORMATF(("%s-gemm-naive", INSTANCE_ID))),
        .N_MASTER    (`NUM_LSU_BLOCKS),
        .NUM_ENTRIES (`JOB_MMIO_NUM_ENTRIES)
    ) gemm_node_naive (
        .clk         (clk),
        .reset       (reset),
    `ifdef PERF_ENABLE
        .gemm_unit_perf (accel_perf.gemm_unit),
        .gemm_node_perf (accel_perf.gemm_node),
    `endif
        .mmio_if     (gemm_ctrl_if),
        .dma_if      (dma_ctrl_if[`NUM_LSU_BLOCKS]),
        .lmem_bus_if (gemm_data_if)
       ,.psum_rd_lmem_bus_if(gemm_psum_rd_if)
       ,.psum_wr_lmem_bus_if(gemm_psum_wr_if)
    );

    for (genvar i = 0; i < NUM_DMA_CHANNELS; ++i) begin : g_naive_gemm_dma_axi
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
    assign accel_perf.hbm_dma         = '0;
    assign accel_perf.lmem_dma_input  = '0;
    assign accel_perf.lmem_dma_weight = '0;
    assign accel_perf.lmem_dma_sz     = '0;
    assign accel_perf.lmem_dma_output = '0;
`endif
`ifdef ENABLE_HW_DEBUG_GEMM
    assign gemm_unit_debug = '0;
`endif

`else

    VX_gemm_node #(
        .INSTANCE_ID (`SFORMATF(("%s-gemm", INSTANCE_ID))),
        .N_MASTER (`NUM_LSU_BLOCKS),
        .NUM_TMEM_BANKS (NUM_TMEM_BANKS),
        .NUM_DMA_CHANNELS (NUM_DMA_CHANNELS),
        .DMA_STORE_MAX_CHUNK_BEATS (DMA_STORE_MAX_CHUNK_BEATS)
    ) gemm_node (
        .clk         (clk),
        .reset       (reset),
    `ifdef ENABLE_HW_DEBUG_GEMM
        .gemm_unit_debug      (gemm_unit_debug),
    `endif
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

`endif

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

`ifdef GEMM_NAIVE
    `INIT_VX_LSU_MEM_IF (dma_ctrl_if[`NUM_LSU_BLOCKS])
    for (genvar i = 0; i < `LMEM_NUM_PORTS; ++i) begin : g_disabled_gemm_data
        `INIT_VX_MEM_BUS_IF (gemm_data_if[i])
        `INIT_VX_MEM_BUS_IF (gemm_psum_rd_if[i])
        `INIT_VX_MEM_BUS_IF (gemm_psum_wr_if[i])
    end
`endif

    for (genvar i = 0; i < NUM_DMA_CHANNELS; ++i) begin : g_disabled_gemm_dma_axi
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
`ifdef ENABLE_HW_DEBUG_GEMM
    assign gemm_unit_debug = '0;
`endif

`endif

	`ifdef ENABLE_HW_DEBUG_CORE
	    reg hw_debug_core_busy_r;

	    always @(posedge clk) begin
	        if (reset) begin
	            hw_debug_core_busy_r <= 1'b0;
	        end else begin
	            hw_debug_core_busy_r <= busy;
	        end
	    end

	    assign core_pipeline_debug.busy = hw_debug_core_busy_r;

	    VX_hw_debug_vr_probe core_schedule_debug (
	        .clk          (clk),
	        .reset        (reset),
	        .valid        (schedule_if.valid),
	        .ready        (schedule_if.ready),
	        .wid          (schedule_if.data.wid),
	        .tag          (16'(schedule_if.data.uuid) ^ 16'(schedule_if.data.PC)),
	        .payload_hash (16'(schedule_if.data.uuid) ^ 16'(schedule_if.data.PC)),
	        .debug        (core_pipeline_debug.channels[HW_DBG_CH_SCHEDULE])
	    );

	    VX_hw_debug_vr_probe core_icache_req_debug (
	        .clk          (clk),
	        .reset        (reset),
	        .valid        (icache_bus_if.req_valid),
	        .ready        (icache_bus_if.req_ready),
	        .wid          (NW_WIDTH'(icache_bus_if.req_data.tag.value)),
	        .tag          (16'(icache_bus_if.req_data.tag.uuid) ^ 16'(icache_bus_if.req_data.tag.value)),
	        .payload_hash (16'(icache_bus_if.req_data.tag.uuid) ^ 16'(icache_bus_if.req_data.tag.value) ^ 16'(icache_bus_if.req_data.addr)),
	        .debug        (core_pipeline_debug.channels[HW_DBG_CH_ICACHE_REQ])
	    );

	    VX_hw_debug_vr_probe core_icache_rsp_debug (
	        .clk          (clk),
	        .reset        (reset),
	        .valid        (icache_bus_if.rsp_valid),
	        .ready        (icache_bus_if.rsp_ready),
	        .wid          (NW_WIDTH'(icache_bus_if.rsp_data.tag.value)),
	        .tag          (16'(icache_bus_if.rsp_data.tag.uuid) ^ 16'(icache_bus_if.rsp_data.tag.value)),
	        .payload_hash (16'(icache_bus_if.rsp_data.tag.uuid) ^ 16'(icache_bus_if.rsp_data.tag.value)),
	        .debug        (core_pipeline_debug.channels[HW_DBG_CH_ICACHE_RSP])
	    );

	    VX_hw_debug_vr_probe core_fetch_debug (
	        .clk          (clk),
	        .reset        (reset),
	        .valid        (fetch_if.valid),
	        .ready        (fetch_if.ready),
	        .wid          (fetch_if.data.wid),
	        .tag          (16'(fetch_if.data.uuid) ^ 16'(fetch_if.data.PC)),
	        .payload_hash (16'(fetch_if.data.uuid) ^ 16'(fetch_if.data.PC) ^ 16'(fetch_if.data.instr)),
	        .debug        (core_pipeline_debug.channels[HW_DBG_CH_FETCH])
	    );

	    VX_hw_debug_vr_probe core_decode_debug (
	        .clk          (clk),
	        .reset        (reset),
	        .valid        (decode_if.valid),
	        .ready        (decode_if.ready),
	        .wid          (decode_if.data.wid),
	        .tag          (16'(decode_if.data.uuid) ^ 16'(decode_if.data.PC)),
	        .payload_hash (16'(decode_if.data.uuid) ^ 16'(decode_if.data.PC) ^ 16'(decode_if.data.rd) ^ 16'(decode_if.data.op_type)),
	        .debug        (core_pipeline_debug.channels[HW_DBG_CH_DECODE])
	    );

	    for (genvar dbg_issue_ch = 0; dbg_issue_ch < HW_DEBUG_ISSUE_PIPE_CHANNELS; ++dbg_issue_ch) begin : g_hw_debug_issue
	        assign core_pipeline_debug.channels[HW_DBG_CH_ISSUE_BASE + dbg_issue_ch] =
	            issue_pipeline_debug.channels[dbg_issue_ch];
	    end

	    for (genvar dbg_ex = 0; dbg_ex < NUM_EX_UNITS; ++dbg_ex) begin : g_hw_debug_ex
	        for (genvar dbg_issue = 0; dbg_issue < `ISSUE_WIDTH; ++dbg_issue) begin : g_issue
	            localparam DBG_EX_CHANNEL = dbg_ex * `ISSUE_WIDTH + dbg_issue;
	            VX_hw_debug_vr_probe core_dispatch_debug (
	                .clk          (clk),
	                .reset        (reset),
	                .valid        (dispatch_if[DBG_EX_CHANNEL].valid),
	                .ready        (dispatch_if[DBG_EX_CHANNEL].ready),
	                .wid          (wis_to_wid(dispatch_if[DBG_EX_CHANNEL].data.wis, ISSUE_ISW_W'(dbg_issue))),
	                .tag          (16'(dispatch_if[DBG_EX_CHANNEL].data.uuid) ^ 16'(dispatch_if[DBG_EX_CHANNEL].data.PC)),
	                .payload_hash (16'(dispatch_if[DBG_EX_CHANNEL].data.uuid) ^ 16'(dispatch_if[DBG_EX_CHANNEL].data.PC) ^ 16'(dispatch_if[DBG_EX_CHANNEL].data.rd) ^ 16'(dispatch_if[DBG_EX_CHANNEL].data.op_type)),
	                .debug        (core_pipeline_debug.channels[HW_DBG_CH_DISPATCH_BASE + DBG_EX_CHANNEL])
	            );

	            VX_hw_debug_vr_probe core_commit_debug (
	                .clk          (clk),
	                .reset        (reset),
	                .valid        (commit_if[DBG_EX_CHANNEL].valid),
	                .ready        (commit_if[DBG_EX_CHANNEL].ready),
	                .wid          (commit_if[DBG_EX_CHANNEL].data.wid),
	                .tag          (16'(commit_if[DBG_EX_CHANNEL].data.uuid) ^ 16'(commit_if[DBG_EX_CHANNEL].data.PC)),
	                .payload_hash (16'(commit_if[DBG_EX_CHANNEL].data.uuid) ^ 16'(commit_if[DBG_EX_CHANNEL].data.PC) ^ 16'(commit_if[DBG_EX_CHANNEL].data.rd) ^ 16'(commit_if[DBG_EX_CHANNEL].data.sid)),
	                .debug        (core_pipeline_debug.channels[HW_DBG_CH_COMMIT_BASE + DBG_EX_CHANNEL])
	            );
	        end
	    end

	    for (genvar dbg_lsu = 0; dbg_lsu < `NUM_LSU_BLOCKS; ++dbg_lsu) begin : g_hw_debug_lsu
	        VX_hw_debug_vr_probe core_lsu_req_debug (
	            .clk          (clk),
	            .reset        (reset),
	            .valid        (lsu_mem_if[dbg_lsu].req_valid),
	            .ready        (lsu_mem_if[dbg_lsu].req_ready),
	            .wid          ('0),
	            .tag          (16'(lsu_mem_if[dbg_lsu].req_data.tag.uuid) ^ 16'(lsu_mem_if[dbg_lsu].req_data.tag.value)),
	            .payload_hash (16'(lsu_mem_if[dbg_lsu].req_data.tag.uuid) ^ 16'(lsu_mem_if[dbg_lsu].req_data.tag.value) ^ 16'(lsu_mem_if[dbg_lsu].req_data.addr[0])),
	            .debug        (core_pipeline_debug.channels[HW_DBG_CH_LSU_REQ_BASE + dbg_lsu])
	        );

	        VX_hw_debug_vr_probe core_lsu_rsp_debug (
	            .clk          (clk),
	            .reset        (reset),
	            .valid        (lsu_mem_if[dbg_lsu].rsp_valid),
	            .ready        (lsu_mem_if[dbg_lsu].rsp_ready),
	            .wid          ('0),
	            .tag          (16'(lsu_mem_if[dbg_lsu].rsp_data.tag.uuid) ^ 16'(lsu_mem_if[dbg_lsu].rsp_data.tag.value)),
	            .payload_hash (16'(lsu_mem_if[dbg_lsu].rsp_data.tag.uuid) ^ 16'(lsu_mem_if[dbg_lsu].rsp_data.tag.value)),
	            .debug        (core_pipeline_debug.channels[HW_DBG_CH_LSU_RSP_BASE + dbg_lsu])
	        );
	    end

	    for (genvar dbg_dcache = 0; dbg_dcache < DCACHE_CORE_NUM_REQS; ++dbg_dcache) begin : g_hw_debug_dcache
	        VX_hw_debug_vr_probe core_dcache_req_debug (
	            .clk          (clk),
	            .reset        (reset),
	            .valid        (dcache_bus_if[dbg_dcache].req_valid),
	            .ready        (dcache_bus_if[dbg_dcache].req_ready),
	            .wid          ('0),
	            .tag          (16'(dcache_bus_if[dbg_dcache].req_data.tag.uuid) ^ 16'(dcache_bus_if[dbg_dcache].req_data.tag.value)),
	            .payload_hash (16'(dcache_bus_if[dbg_dcache].req_data.tag.uuid) ^ 16'(dcache_bus_if[dbg_dcache].req_data.tag.value) ^ 16'(dcache_bus_if[dbg_dcache].req_data.addr)),
	            .debug        (core_pipeline_debug.channels[HW_DBG_CH_DCACHE_REQ_BASE + dbg_dcache])
	        );

	        VX_hw_debug_vr_probe core_dcache_rsp_debug (
	            .clk          (clk),
	            .reset        (reset),
	            .valid        (dcache_bus_if[dbg_dcache].rsp_valid),
	            .ready        (dcache_bus_if[dbg_dcache].rsp_ready),
	            .wid          ('0),
	            .tag          (16'(dcache_bus_if[dbg_dcache].rsp_data.tag.uuid) ^ 16'(dcache_bus_if[dbg_dcache].rsp_data.tag.value)),
	            .payload_hash (16'(dcache_bus_if[dbg_dcache].rsp_data.tag.uuid) ^ 16'(dcache_bus_if[dbg_dcache].rsp_data.tag.value)),
	            .debug        (core_pipeline_debug.channels[HW_DBG_CH_DCACHE_RSP_BASE + dbg_dcache])
	        );
	    end
		`endif

	`ifdef PERF_ENABLE

    localparam PERF_DCACHE_COUNT_W = `CLOG2(LSU_NUM_REQS+1);
    localparam PERF_DCACHE_DELTA_W = PERF_DCACHE_COUNT_W + 1;

    wire [PERF_DCACHE_COUNT_W-1:0] perf_dcache_rd_req_per_cycle;
    wire [PERF_DCACHE_COUNT_W-1:0] perf_dcache_wr_req_per_cycle;
    wire [PERF_DCACHE_COUNT_W-1:0] perf_dcache_rsp_per_cycle;

    wire [1:0] perf_icache_pending_read_cycle;
    wire signed [PERF_DCACHE_DELTA_W-1:0] perf_dcache_pending_read_cycle;
    reg  signed [PERF_DCACHE_DELTA_W-1:0] perf_dcache_pending_read_cycle_q;

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
    assign perf_dcache_pending_read_cycle
        = $signed({1'b0, perf_dcache_rd_req_per_cycle})
        - $signed({1'b0, perf_dcache_rsp_per_cycle});

    always @(posedge clk) begin
        if (reset) begin
            perf_dcache_pending_read_cycle_q <= '0;
            perf_icache_pending_reads <= '0;
            perf_dcache_pending_reads <= '0;
        end else begin
            perf_dcache_pending_read_cycle_q <= perf_dcache_pending_read_cycle;
            perf_icache_pending_reads <= $signed(perf_icache_pending_reads) + PERF_CTR_BITS'($signed(perf_icache_pending_read_cycle));
            perf_dcache_pending_reads <= $signed(perf_dcache_pending_reads) + PERF_CTR_BITS'($signed(perf_dcache_pending_read_cycle_q));
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

`ifndef SYNTHESIS
    reg [PERF_CTR_BITS-1:0] perf_dcache_pending_reads_ref_r;
    reg [PERF_CTR_BITS-1:0] perf_dcache_pending_reads_ref_q;
    reg [PERF_CTR_BITS-1:0] perf_dcache_lat_ref_r;
    reg [PERF_CTR_BITS-1:0] perf_dcache_lat_ref_q;

    always @(posedge clk) begin
        if (reset) begin
            perf_dcache_pending_reads_ref_r <= '0;
            perf_dcache_pending_reads_ref_q <= '0;
            perf_dcache_lat_ref_r <= '0;
            perf_dcache_lat_ref_q <= '0;
        end else begin
            assert (perf_dcache_pending_reads == perf_dcache_pending_reads_ref_q)
                else $fatal(1, "%s: staged D-cache pending-read recurrence mismatch", INSTANCE_ID);
            assert (perf_dcache_lat == perf_dcache_lat_ref_q)
                else $fatal(1, "%s: staged D-cache latency recurrence mismatch", INSTANCE_ID);

            perf_dcache_pending_reads_ref_r <= $signed(perf_dcache_pending_reads_ref_r)
                + PERF_CTR_BITS'($signed(perf_dcache_pending_read_cycle));
            perf_dcache_pending_reads_ref_q <= perf_dcache_pending_reads_ref_r;
            perf_dcache_lat_ref_r <= perf_dcache_lat_ref_r + perf_dcache_pending_reads_ref_r;
            perf_dcache_lat_ref_q <= perf_dcache_lat_ref_r;
        end
    end
`endif

    assign pipeline_perf.ifetches = perf_ifetches;
    assign pipeline_perf.loads = perf_loads;
    assign pipeline_perf.stores = perf_stores;
    assign pipeline_perf.ifetch_latency = perf_icache_lat;
    assign pipeline_perf.load_latency = perf_dcache_lat;

    // DMA union-active and overlap counters share the exact same union
    // predicate. Concurrent DMA engines therefore count once per cycle.
    wire any_dma_busy = accel_perf.cpu_dma.busy
                      | accel_perf.hbm_dma.aggregate.busy
                      | accel_perf.lmem_dma_input.busy
                      | accel_perf.lmem_dma_weight.busy
                      | accel_perf.lmem_dma_sz.busy
                      | accel_perf.lmem_dma_output.busy;
    reg [PERF_CTR_BITS-1:0] perf_overlap_r;
    reg [PERF_CTR_BITS-1:0] perf_dma_union_active_r;
    always @(posedge clk) begin
        if (reset) begin
            perf_overlap_r <= '0;
            perf_dma_union_active_r <= '0;
        end else begin
            if (any_dma_busy)
                perf_dma_union_active_r
                    <= perf_dma_union_active_r + PERF_CTR_BITS'(1);
            if (any_dma_busy && accel_perf.gemm_unit.computing)
                perf_overlap_r <= perf_overlap_r + PERF_CTR_BITS'(1);
        end
    end
    assign accel_perf.overlap_dma_mxu = perf_overlap_r;
    assign accel_perf.dma_union_active_cycles = perf_dma_union_active_r;

`ifndef SYNTHESIS
    always @(posedge clk) begin
        if (!reset) begin
            assert (perf_overlap_r <= perf_dma_union_active_r)
                else $fatal(1, "%s: DMA+MXU overlap exceeds DMA union-active cycles",
                            INSTANCE_ID);
        end
    end
`endif

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
