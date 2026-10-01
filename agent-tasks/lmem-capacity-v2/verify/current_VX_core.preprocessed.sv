module VX_core import VX_gpu_pkg::*; #(
    parameter CORE_ID = 0,
    parameter  INSTANCE_ID = "",
    parameter NUM_TMEM_BANKS = 8,
    parameter NUM_DMA_CHANNELS = 4,
    parameter int DMA_STORE_MAX_CHUNK_BEATS =
        8
) (
    input wire              clk,
    input wire              reset,
    VX_dcr_bus_if.slave     dcr_bus_if,
    VX_mem_bus_if.master    dcache_bus_if [DCACHE_CORE_NUM_REQS],
    VX_mem_bus_if.master    icache_bus_if,
    AXI_BUS.Master          dma_axi_m [NUM_DMA_CHANNELS],
    output wire             busy
);
    VX_schedule_if      schedule_if();
    VX_fetch_if         fetch_if();
    VX_decode_if        decode_if();
    VX_sched_csr_if     sched_csr_if();
    VX_decode_sched_if  decode_sched_if();
    VX_issue_sched_if   issue_sched_if[(((4 / 16) > 0) ? (4 / 16) : 1)]();
    VX_commit_sched_if  commit_sched_if();
    VX_commit_csr_if    commit_csr_if();
    VX_branch_ctl_if    branch_ctl_if[(((4 / 16) > 0) ? (4 / 16) : 1)]();
    VX_warp_ctl_if      warp_ctl_if();
    VX_dispatch_if      dispatch_if[NUM_EX_UNITS * (((4 / 16) > 0) ? (4 / 16) : 1)]();
    VX_commit_if        commit_if[NUM_EX_UNITS * (((4 / 16) > 0) ? (4 / 16) : 1)]();
    VX_writeback_if     writeback_if[(((4 / 16) > 0) ? (4 / 16) : 1)]();
    VX_lsu_mem_if #(
        .NUM_LANES (16),
        .DATA_SIZE (LSU_WORD_SIZE),
        .TAG_WIDTH (LSU_TAG_WIDTH)
    ) lsu_mem_if[1]();
    VX_lsu_mem_if #(
        .NUM_LANES (16),
        .DATA_SIZE (LSU_WORD_SIZE),
        .TAG_WIDTH (LSU_TAG_WIDTH)
    ) dma_ctrl_if[1]();
    VX_lsu_mem_if #(
        .NUM_LANES (16),
        .DATA_SIZE (LSU_WORD_SIZE),
        .TAG_WIDTH (LSU_TAG_WIDTH)
    ) gemm_ctrl_if[1]();
    VX_mem_bus_if #(
        .DATA_SIZE (LSU_WORD_SIZE),
        .TAG_WIDTH (LMEM_TAG_WIDTH)
    ) dma_local_data_if[16]();
	    VX_mem_bus_if #(
	        .DATA_SIZE (1 * DCACHE_WORD_SIZE),
	        .TAG_WIDTH (DMA_DCACHE_TAG_WIDTH)
	    ) dma_global_data_if();
    base_dcrs_t base_dcrs;
    VX_dcr_data dcr_data (
        .clk        (clk),
        .reset      (reset),
        .dcr_bus_if (dcr_bus_if),
        .base_dcrs  (base_dcrs)
    );
    ;
    VX_schedule #(
        .INSTANCE_ID (""),
        .CORE_ID (CORE_ID)
    ) schedule (
        .clk            (clk),
        .reset          (reset),
        .base_dcrs      (base_dcrs),
        .warp_ctl_if    (warp_ctl_if),
        .branch_ctl_if  (branch_ctl_if),
        .decode_sched_if(decode_sched_if),
        .issue_sched_if (issue_sched_if),
        .commit_sched_if(commit_sched_if),
        .schedule_if    (schedule_if),
        .sched_csr_if   (sched_csr_if),
        .busy           (busy)
    );
    VX_fetch #(
        .INSTANCE_ID ("")
    ) fetch (
        .clk            (clk),
        .reset          (reset),
        .icache_bus_if  (icache_bus_if),
        .schedule_if    (schedule_if),
        .fetch_if       (fetch_if)
    );
    VX_decode #(
        .INSTANCE_ID ("")
    ) decode (
        .clk            (clk),
        .reset          (reset),
        .fetch_if       (fetch_if),
        .decode_if      (decode_if),
        .decode_sched_if(decode_sched_if)
    );
    VX_issue #(
        .INSTANCE_ID ("")
    ) issue (
        .clk            (clk),
        .reset          (reset),
	        .decode_if      (decode_if),
	        .writeback_if   (writeback_if),
	        .dispatch_if    (dispatch_if),
	        .issue_sched_if (issue_sched_if)
	    );
    VX_execute #(
        .INSTANCE_ID (""),
        .CORE_ID (CORE_ID)
    ) execute (
        .clk            (clk),
        .reset          (reset),
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
        .INSTANCE_ID ("")
    ) commit (
        .clk            (clk),
        .reset          (reset),
        .commit_if      (commit_if),
        .writeback_if   (writeback_if),
        .commit_csr_if  (commit_csr_if),
        .commit_sched_if(commit_sched_if)
    );
    VX_mem_unit #(
        .INSTANCE_ID (INSTANCE_ID)
    ) mem_unit (
        .clk              (clk),
        .reset            (reset),
        .lsu_mem_if        (lsu_mem_if),
        .dcache_bus_if     (dcache_bus_if),
        .dma_ctrl_if       (dma_ctrl_if),
        .gemm_ctrl_if      (gemm_ctrl_if),
        .dma_local_data_if (dma_local_data_if),
        .dma_global_data_if(dma_global_data_if)
    );
    for (genvar i = 0; i < 1; ++i) begin : g_disabled_dma_ctrl
        VX_lsu_mem_zero_rsp #(
            .NUM_LANES (16),
            .DATA_SIZE (LSU_WORD_SIZE),
            .TAG_WIDTH (LSU_TAG_WIDTH)
        ) dma_ctrl_rsp (
            .clk    (clk),
            .reset  (reset),
            .mem_if (dma_ctrl_if[i])
        );
    end
    for (genvar i = 0; i < 16; ++i) begin : g_disabled_dma_lmem
    assign dma_local_data_if[i].req_valid = 0; 
    assign dma_local_data_if[i].req_data = '0; 
    assign dma_local_data_if[i].rsp_ready = 0;
    end
    assign dma_global_data_if.req_valid = 0; 
    assign dma_global_data_if.req_data = '0; 
    assign dma_global_data_if.rsp_ready = 0;
    VX_gemm_node #(
        .INSTANCE_ID (""),
        .N_MASTER (1),
        .NUM_TMEM_BANKS (NUM_TMEM_BANKS),
        .NUM_DMA_CHANNELS (NUM_DMA_CHANNELS),
        .DMA_STORE_MAX_CHUNK_BEATS (DMA_STORE_MAX_CHUNK_BEATS)
    ) gemm_node (
        .clk         (clk),
        .reset       (reset),
        .mmio_if     (gemm_ctrl_if),
        .dma_axi_m   (dma_axi_m)
    );
endmodule
