module VX_mem_unit import VX_gpu_pkg::*; #(
    parameter  INSTANCE_ID = ""
) (
    input wire              clk,
    input wire              reset,
    VX_lsu_mem_if.slave     lsu_mem_if [1],
    VX_mem_bus_if.master    dcache_bus_if [DCACHE_CORE_NUM_REQS],
    VX_lsu_mem_if.master    dma_ctrl_if [1],
    VX_lsu_mem_if.master    gemm_ctrl_if [1],
    VX_mem_bus_if.slave     dma_local_data_if [16],
    VX_mem_bus_if.slave     dma_global_data_if
);
    VX_lsu_mem_if #(
        .NUM_LANES (16),
        .DATA_SIZE (LSU_WORD_SIZE),
        .TAG_WIDTH (LSU_TAG_WIDTH)
    ) lsu_dcache_if[1]();
    localparam LMEM_ADDR_WIDTH = 20 - $clog2(LSU_WORD_SIZE);
    localparam CPU_LMEM_ARB_SEL_BITS = ((1 > 1) ? $clog2(((1 + 1 - 1) / (1))) : 0);
    localparam CPU_LMEM_TAG_WIDTH = LSU_TAG_WIDTH + CPU_LMEM_ARB_SEL_BITS;
    localparam logic [63:0] GEMM_MMIO_SIZE_B = 64'd1024;
    localparam logic [63:0] DMA_MMIO_SIZE_B  = 64'd1024;
    VX_lsu_mem_if #(
        .NUM_LANES (16),
        .DATA_SIZE (LSU_WORD_SIZE),
        .TAG_WIDTH (LSU_TAG_WIDTH)
    ) lsu_lmem_if[1]();
    for (genvar i = 0; i < 1; ++i) begin : g_lmem_switches
        VX_lmem_switch #(
            .GLOBAL_OUT_BUF(0),
            .LOCAL_OUT_BUF(1),
            .GEMM_OUT_BUF (1),
            .DMA_OUT_BUF  (1),
            .RSP_OUT_BUF  (1),
            .GEMM_MMIO_BASE_ADDR(64'h0000_0000_0000_1080),
            .DMA_MMIO_BASE_ADDR (64'h0000_0000_0000_1480),
            .GEMM_MMIO_SIZE     (GEMM_MMIO_SIZE_B),
            .DMA_MMIO_SIZE      (DMA_MMIO_SIZE_B),
            .ARBITER      ("P")
        ) lmem_switch (
            .clk          (clk),
            .reset        (reset),
            .lsu_in_if    (lsu_mem_if[i]),
            .global_out_if(lsu_dcache_if[i]),
            .local_out_if (lsu_lmem_if[i]),
            .gemm_ctrl_if  (gemm_ctrl_if[i]),
            .dma_ctrl_if   (dma_ctrl_if[i])
        );
    end
    VX_lsu_mem_if #(
        .NUM_LANES (16),
        .DATA_SIZE (LSU_WORD_SIZE),
        .TAG_WIDTH (CPU_LMEM_TAG_WIDTH)
    ) lmem_arb_if[1]();
    VX_lsu_mem_arb #(
        .NUM_INPUTS (1),
        .NUM_OUTPUTS(1),
        .NUM_LANES  (16),
        .DATA_SIZE  (LSU_WORD_SIZE),
        .TAG_WIDTH  (LSU_TAG_WIDTH),
        .TAG_SEL_IDX(0),
        .ARBITER    ("R"),
        .REQ_OUT_BUF(0),
        .RSP_OUT_BUF(2)
    ) lmem_arb (
        .clk        (clk),
        .reset      (reset),
        .bus_in_if  (lsu_lmem_if),
        .bus_out_if (lmem_arb_if)
    );
    VX_mem_bus_if #(
        .DATA_SIZE (LSU_WORD_SIZE),
        .TAG_WIDTH (CPU_LMEM_TAG_WIDTH)
    ) lmem_adapt_if[16]();
    VX_lsu_adapter #(
        .NUM_LANES    (16),
        .DATA_SIZE    (LSU_WORD_SIZE),
        .TAG_WIDTH    (CPU_LMEM_TAG_WIDTH),
        .TAG_SEL_BITS (CPU_LMEM_TAG_WIDTH - UUID_WIDTH),
        .ARBITER      ("P"),
        .REQ_OUT_BUF  (3),
        .RSP_OUT_BUF  (0)
    ) lmem_adapter (
        .clk        (clk),
        .reset      (reset),
        .lsu_mem_if (lmem_arb_if[0]),
        .mem_bus_if (lmem_adapt_if)
    );
    VX_mem_bus_if #(
        .DATA_SIZE (LSU_WORD_SIZE),
        .TAG_WIDTH (LMEM_LOCAL_TAG_WIDTH)
    ) lmem_membus_arb_out_if[16]();
    for (genvar i = 0; i < 16; ++i) begin : g_lmem_lane_dma_arb
        VX_mem_bus_if #(
            .DATA_SIZE (LSU_WORD_SIZE),
            .TAG_WIDTH (GEMM_LMEM_TAG_WIDTH)
        ) lane_arb_in_if[2]();
        VX_mem_bus_if #(
            .DATA_SIZE (LSU_WORD_SIZE),
            .TAG_WIDTH (LMEM_LOCAL_TAG_WIDTH)
        ) lane_arb_out_if[1]();
        if (i < 16) begin : g_cpu_lmem_port
    /*verilator lint_off GENUNNAMED*/  
    assign lane_arb_in_if[0].req_valid = lmem_adapt_if[i].req_valid; 
    assign lane_arb_in_if[0].req_data.rw = lmem_adapt_if[i].req_data.rw; 
    assign lane_arb_in_if[0].req_data.addr = lmem_adapt_if[i].req_data.addr; 
    assign lane_arb_in_if[0].req_data.data = lmem_adapt_if[i].req_data.data; 
    assign lane_arb_in_if[0].req_data.byteen = lmem_adapt_if[i].req_data.byteen; 
    assign lane_arb_in_if[0].req_data.flags = lmem_adapt_if[i].req_data.flags; 
    if (GEMM_LMEM_TAG_WIDTH != CPU_LMEM_TAG_WIDTH) begin 
        if (UUID_WIDTH != 0) begin 
            if (GEMM_LMEM_TAG_WIDTH > CPU_LMEM_TAG_WIDTH) begin 
                assign lane_arb_in_if[0].req_data.tag = {lmem_adapt_if[i].req_data.tag.uuid, {(GEMM_LMEM_TAG_WIDTH-CPU_LMEM_TAG_WIDTH){1'b0}}, lmem_adapt_if[i].req_data.tag.value}; 
            end else begin 
                assign lane_arb_in_if[0].req_data.tag = {lmem_adapt_if[i].req_data.tag.uuid, lmem_adapt_if[i].req_data.tag.value[GEMM_LMEM_TAG_WIDTH-UUID_WIDTH-1:0]}; 
            end 
        end else begin 
            if (GEMM_LMEM_TAG_WIDTH > CPU_LMEM_TAG_WIDTH) begin 
                assign lane_arb_in_if[0].req_data.tag = {{(GEMM_LMEM_TAG_WIDTH-CPU_LMEM_TAG_WIDTH){1'b0}}, lmem_adapt_if[i].req_data.tag}; 
            end else begin 
                assign lane_arb_in_if[0].req_data.tag = lmem_adapt_if[i].req_data.tag[GEMM_LMEM_TAG_WIDTH-1:0]; 
            end 
        end 
    end else begin 
        assign lane_arb_in_if[0].req_data.tag = lmem_adapt_if[i].req_data.tag; 
    end 
    assign lmem_adapt_if[i].req_ready = lane_arb_in_if[0].req_ready; 
    assign lmem_adapt_if[i].rsp_valid = lane_arb_in_if[0].rsp_valid; 
    assign lmem_adapt_if[i].rsp_data.data = lane_arb_in_if[0].rsp_data.data; 
    if (GEMM_LMEM_TAG_WIDTH != CPU_LMEM_TAG_WIDTH) begin 
        if (UUID_WIDTH != 0) begin 
            if (GEMM_LMEM_TAG_WIDTH > CPU_LMEM_TAG_WIDTH) begin 
                assign lmem_adapt_if[i].rsp_data.tag = {lane_arb_in_if[0].rsp_data.tag.uuid, lane_arb_in_if[0].rsp_data.tag.value[CPU_LMEM_TAG_WIDTH-UUID_WIDTH-1:0]}; 
            end else begin 
                assign lmem_adapt_if[i].rsp_data.tag = {lane_arb_in_if[0].rsp_data.tag.uuid, {(CPU_LMEM_TAG_WIDTH-GEMM_LMEM_TAG_WIDTH){1'b0}}, lane_arb_in_if[0].rsp_data.tag.value}; 
            end 
        end else begin 
            if (GEMM_LMEM_TAG_WIDTH > CPU_LMEM_TAG_WIDTH) begin 
                assign lmem_adapt_if[i].rsp_data.tag = lane_arb_in_if[0].rsp_data.tag[CPU_LMEM_TAG_WIDTH-1:0]; 
            end else begin 
                assign lmem_adapt_if[i].rsp_data.tag = {{(CPU_LMEM_TAG_WIDTH-GEMM_LMEM_TAG_WIDTH){1'b0}}, lane_arb_in_if[0].rsp_data.tag}; 
            end 
        end 
    end else begin 
        assign lmem_adapt_if[i].rsp_data.tag = lane_arb_in_if[0].rsp_data.tag; 
    end 
    assign lane_arb_in_if[0].rsp_ready = lmem_adapt_if[i].rsp_ready 
    /*verilator lint_off GENUNNAMED*/ ;
        end else begin : g_no_cpu_lmem_port
            assign lane_arb_in_if[0].req_valid = 1'b0;
            assign lane_arb_in_if[0].req_data  = '0;
            assign lane_arb_in_if[0].rsp_ready = 1'b1;
        end
    /*verilator lint_off GENUNNAMED*/  
    assign lane_arb_in_if[1].req_valid = dma_local_data_if[i].req_valid; 
    assign lane_arb_in_if[1].req_data.rw = dma_local_data_if[i].req_data.rw; 
    assign lane_arb_in_if[1].req_data.addr = dma_local_data_if[i].req_data.addr; 
    assign lane_arb_in_if[1].req_data.data = dma_local_data_if[i].req_data.data; 
    assign lane_arb_in_if[1].req_data.byteen = dma_local_data_if[i].req_data.byteen; 
    assign lane_arb_in_if[1].req_data.flags = dma_local_data_if[i].req_data.flags; 
    if (GEMM_LMEM_TAG_WIDTH != LMEM_TAG_WIDTH) begin 
        if (UUID_WIDTH != 0) begin 
            if (GEMM_LMEM_TAG_WIDTH > LMEM_TAG_WIDTH) begin 
                assign lane_arb_in_if[1].req_data.tag = {dma_local_data_if[i].req_data.tag.uuid, {(GEMM_LMEM_TAG_WIDTH-LMEM_TAG_WIDTH){1'b0}}, dma_local_data_if[i].req_data.tag.value}; 
            end else begin 
                assign lane_arb_in_if[1].req_data.tag = {dma_local_data_if[i].req_data.tag.uuid, dma_local_data_if[i].req_data.tag.value[GEMM_LMEM_TAG_WIDTH-UUID_WIDTH-1:0]}; 
            end 
        end else begin 
            if (GEMM_LMEM_TAG_WIDTH > LMEM_TAG_WIDTH) begin 
                assign lane_arb_in_if[1].req_data.tag = {{(GEMM_LMEM_TAG_WIDTH-LMEM_TAG_WIDTH){1'b0}}, dma_local_data_if[i].req_data.tag}; 
            end else begin 
                assign lane_arb_in_if[1].req_data.tag = dma_local_data_if[i].req_data.tag[GEMM_LMEM_TAG_WIDTH-1:0]; 
            end 
        end 
    end else begin 
        assign lane_arb_in_if[1].req_data.tag = dma_local_data_if[i].req_data.tag; 
    end 
    assign dma_local_data_if[i].req_ready = lane_arb_in_if[1].req_ready; 
    assign dma_local_data_if[i].rsp_valid = lane_arb_in_if[1].rsp_valid; 
    assign dma_local_data_if[i].rsp_data.data = lane_arb_in_if[1].rsp_data.data; 
    if (GEMM_LMEM_TAG_WIDTH != LMEM_TAG_WIDTH) begin 
        if (UUID_WIDTH != 0) begin 
            if (GEMM_LMEM_TAG_WIDTH > LMEM_TAG_WIDTH) begin 
                assign dma_local_data_if[i].rsp_data.tag = {lane_arb_in_if[1].rsp_data.tag.uuid, lane_arb_in_if[1].rsp_data.tag.value[LMEM_TAG_WIDTH-UUID_WIDTH-1:0]}; 
            end else begin 
                assign dma_local_data_if[i].rsp_data.tag = {lane_arb_in_if[1].rsp_data.tag.uuid, {(LMEM_TAG_WIDTH-GEMM_LMEM_TAG_WIDTH){1'b0}}, lane_arb_in_if[1].rsp_data.tag.value}; 
            end 
        end else begin 
            if (GEMM_LMEM_TAG_WIDTH > LMEM_TAG_WIDTH) begin 
                assign dma_local_data_if[i].rsp_data.tag = lane_arb_in_if[1].rsp_data.tag[LMEM_TAG_WIDTH-1:0]; 
            end else begin 
                assign dma_local_data_if[i].rsp_data.tag = {{(LMEM_TAG_WIDTH-GEMM_LMEM_TAG_WIDTH){1'b0}}, lane_arb_in_if[1].rsp_data.tag}; 
            end 
        end 
    end else begin 
        assign dma_local_data_if[i].rsp_data.tag = lane_arb_in_if[1].rsp_data.tag; 
    end 
    assign lane_arb_in_if[1].rsp_ready = dma_local_data_if[i].rsp_ready 
    /*verilator lint_off GENUNNAMED*/ ;
        VX_mem_arb #(
            .NUM_INPUTS  (2),
            .NUM_OUTPUTS (1),
            .DATA_SIZE   (LSU_WORD_SIZE),
            .TAG_WIDTH   (GEMM_LMEM_TAG_WIDTH),
            .TAG_SEL_IDX (GEMM_LMEM_TAG_WIDTH - UUID_WIDTH),
            .REQ_OUT_BUF (3),
            .RSP_OUT_BUF (3),
            .ARBITER     ("P")
        ) lmem_membus_dma_arbiter (
            .clk        (clk),
            .reset      (reset),
            .bus_in_if  (lane_arb_in_if),
            .bus_out_if (lane_arb_out_if)
        );
    assign lmem_membus_arb_out_if[i].req_valid  = lane_arb_out_if[0].req_valid; 
    assign lmem_membus_arb_out_if[i].req_data   = lane_arb_out_if[0].req_data; 
    assign lane_arb_out_if[0].req_ready  = lmem_membus_arb_out_if[i].req_ready; 
    assign lane_arb_out_if[0].rsp_valid  = lmem_membus_arb_out_if[i].rsp_valid; 
    assign lane_arb_out_if[0].rsp_data   = lmem_membus_arb_out_if[i].rsp_data; 
    assign lmem_membus_arb_out_if[i].rsp_ready  = lane_arb_out_if[0].rsp_ready;
    end
    VX_local_mem #(
        .INSTANCE_ID(""),
        .SIZE       ((1 << 20)),
        .NUM_REQS   (16),
        .NUM_BANKS  (16),
        .WORD_SIZE  (LSU_WORD_SIZE),
        .ADDR_WIDTH (LMEM_ADDR_WIDTH),
        .TAG_WIDTH  (LMEM_LOCAL_TAG_WIDTH),
        .OUT_BUF    (3)
    ) local_mem (
        .clk        (clk),
        .reset      (reset),
        .mem_bus_if (lmem_membus_arb_out_if)
    );
    VX_lsu_mem_if #(
        .NUM_LANES (DCACHE_CHANNELS),
        .DATA_SIZE (DCACHE_WORD_SIZE),
        .TAG_WIDTH (DCACHE_TAG_WIDTH)
    ) dcache_coalesced_if[1]();
    if ((16 > 1) && (LSU_WORD_SIZE != DCACHE_WORD_SIZE)) begin : g_enabled
        for (genvar i = 0; i < 1; ++i) begin : g_coalescers
            VX_mem_coalescer #(
                .INSTANCE_ID    (""),
                .NUM_REQS       (16),
                .DATA_IN_SIZE   (LSU_WORD_SIZE),
                .DATA_OUT_SIZE  (DCACHE_WORD_SIZE),
                .ADDR_WIDTH     (LSU_ADDR_WIDTH),
                .FLAGS_WIDTH    (MEM_FLAGS_WIDTH),
                .TAG_WIDTH      (LSU_TAG_WIDTH),
                .UUID_WIDTH     (UUID_WIDTH),
                .QUEUE_SIZE     (((((2 * (16 / 16))) > ((((16 * (64 / 8)) < (64)) ? (16 * (64 / 8)) : (64)) / (64 / 8))) ? ((2 * (16 / 16))) : ((((16 * (64 / 8)) < (64)) ? (16 * (64 / 8)) : (64)) / (64 / 8)))),
                .PERF_CTR_BITS  (PERF_CTR_BITS)
            ) mem_coalescer (
                .clk            (clk),
                .reset          (reset),
                . misses (),
                .in_req_valid   (lsu_dcache_if[i].req_valid),
                .in_req_mask    (lsu_dcache_if[i].req_data.mask),
                .in_req_rw      (lsu_dcache_if[i].req_data.rw),
                .in_req_byteen  (lsu_dcache_if[i].req_data.byteen),
                .in_req_addr    (lsu_dcache_if[i].req_data.addr),
                .in_req_flags   (lsu_dcache_if[i].req_data.flags),
                .in_req_data    (lsu_dcache_if[i].req_data.data),
                .in_req_tag     (lsu_dcache_if[i].req_data.tag),
                .in_req_ready   (lsu_dcache_if[i].req_ready),
                .in_rsp_valid   (lsu_dcache_if[i].rsp_valid),
                .in_rsp_mask    (lsu_dcache_if[i].rsp_data.mask),
                .in_rsp_data    (lsu_dcache_if[i].rsp_data.data),
                .in_rsp_tag     (lsu_dcache_if[i].rsp_data.tag),
                .in_rsp_ready   (lsu_dcache_if[i].rsp_ready),
                .out_req_valid  (dcache_coalesced_if[i].req_valid),
                .out_req_mask   (dcache_coalesced_if[i].req_data.mask),
                .out_req_rw     (dcache_coalesced_if[i].req_data.rw),
                .out_req_byteen (dcache_coalesced_if[i].req_data.byteen),
                .out_req_addr   (dcache_coalesced_if[i].req_data.addr),
                .out_req_flags  (dcache_coalesced_if[i].req_data.flags),
                .out_req_data   (dcache_coalesced_if[i].req_data.data),
                .out_req_tag    (dcache_coalesced_if[i].req_data.tag),
                .out_req_ready  (dcache_coalesced_if[i].req_ready),
                .out_rsp_valid  (dcache_coalesced_if[i].rsp_valid),
                .out_rsp_mask   (dcache_coalesced_if[i].rsp_data.mask),
                .out_rsp_data   (dcache_coalesced_if[i].rsp_data.data),
                .out_rsp_tag    (dcache_coalesced_if[i].rsp_data.tag),
                .out_rsp_ready  (dcache_coalesced_if[i].rsp_ready)
            );
        end
    end else begin : g_passthru
        for (genvar i = 0; i < 1; ++i) begin : g_dcache_coalesced_if
    assign dcache_coalesced_if[i].req_valid  = lsu_dcache_if[i].req_valid; 
    assign dcache_coalesced_if[i].req_data   = lsu_dcache_if[i].req_data; 
    assign lsu_dcache_if[i].req_ready  = dcache_coalesced_if[i].req_ready; 
    assign lsu_dcache_if[i].rsp_valid  = dcache_coalesced_if[i].rsp_valid; 
    assign lsu_dcache_if[i].rsp_data   = dcache_coalesced_if[i].rsp_data; 
    assign dcache_coalesced_if[i].rsp_ready  = lsu_dcache_if[i].rsp_ready;
        end
    end
    VX_mem_bus_if #(
        .DATA_SIZE (DCACHE_WORD_SIZE),
        .TAG_WIDTH (DCACHE_TAG_WIDTH)
    ) dcache_cpu_bus_if[DCACHE_NUM_REQS]();
    for (genvar i = 0; i < 1; ++i) begin : g_dcache_adapters
        VX_mem_bus_if #(
            .DATA_SIZE (DCACHE_WORD_SIZE),
            .TAG_WIDTH (DCACHE_TAG_WIDTH)
        ) dcache_bus_tmp_if[DCACHE_CHANNELS]();
        VX_lsu_adapter #(
            .NUM_LANES    (DCACHE_CHANNELS),
            .DATA_SIZE    (DCACHE_WORD_SIZE),
            .TAG_WIDTH    (DCACHE_TAG_WIDTH),
            .TAG_SEL_BITS (DCACHE_TAG_WIDTH - UUID_WIDTH),
            .ARBITER      ("P"),
            .REQ_OUT_BUF  (0),
            .RSP_OUT_BUF  (0)
        ) dcache_adapter (
            .clk        (clk),
            .reset      (reset),
            .lsu_mem_if (dcache_coalesced_if[i]),
            .mem_bus_if (dcache_bus_tmp_if)
        );
        for (genvar j = 0; j < DCACHE_CHANNELS; ++j) begin : g_dcache_cpu_bus
    assign dcache_cpu_bus_if[i * DCACHE_CHANNELS + j].req_valid  = dcache_bus_tmp_if[j].req_valid; 
    assign dcache_cpu_bus_if[i * DCACHE_CHANNELS + j].req_data   = dcache_bus_tmp_if[j].req_data; 
    assign dcache_bus_tmp_if[j].req_ready  = dcache_cpu_bus_if[i * DCACHE_CHANNELS + j].req_ready; 
    assign dcache_bus_tmp_if[j].rsp_valid  = dcache_cpu_bus_if[i * DCACHE_CHANNELS + j].rsp_valid; 
    assign dcache_bus_tmp_if[j].rsp_data   = dcache_cpu_bus_if[i * DCACHE_CHANNELS + j].rsp_data; 
    assign dcache_cpu_bus_if[i * DCACHE_CHANNELS + j].rsp_ready  = dcache_bus_tmp_if[j].rsp_ready;
        end
    end
    VX_mem_bus_if #(
        .DATA_SIZE (DCACHE_WORD_SIZE),
        .TAG_WIDTH (DMA_DCACHE_TAG_WIDTH)
    ) dcache_dma_lane_if[1]();
    if (1 == 1) begin : g_single_dma_dcache_port
    assign dcache_dma_lane_if[0].req_valid  = dma_global_data_if.req_valid; 
    assign dcache_dma_lane_if[0].req_data   = dma_global_data_if.req_data; 
    assign dma_global_data_if.req_ready  = dcache_dma_lane_if[0].req_ready; 
    assign dma_global_data_if.rsp_valid  = dcache_dma_lane_if[0].rsp_valid; 
    assign dma_global_data_if.rsp_data   = dcache_dma_lane_if[0].rsp_data; 
    assign dcache_dma_lane_if[0].rsp_ready  = dma_global_data_if.rsp_ready;
    end else begin : g_split_dma_dcache_ports
        VX_mem_bus_split #(
            .NUM_LANES      (1),
            .LANE_DATA_SIZE (DCACHE_WORD_SIZE),
            .TAG_WIDTH      (DMA_DCACHE_TAG_WIDTH),
            .ENABLE_LANE_MASK(1)
        ) dma_dcache_split (
            .clk         (clk),
            .reset       (reset),
            .wide_bus_if (dma_global_data_if),
            .lane_bus_if (dcache_dma_lane_if)
        );
    end
    for (genvar i = 0; i < DCACHE_CORE_NUM_REQS; ++i) begin : g_dcache_core_ports
        if ((i < DCACHE_NUM_REQS) && (i < 1)) begin : g_cpu_dma_arb
            VX_mem_bus_if #(
                .DATA_SIZE (DCACHE_WORD_SIZE),
                .TAG_WIDTH (DCACHE_ARB_TAG_WIDTH)
            ) dcache_arb_in_if[2]();
            VX_mem_bus_if #(
                .DATA_SIZE (DCACHE_WORD_SIZE),
                .TAG_WIDTH (DCACHE_CORE_TAG_WIDTH)
            ) dcache_arb_out_if[1]();
    /*verilator lint_off GENUNNAMED*/  
    assign dcache_arb_in_if[0].req_valid = dcache_cpu_bus_if[i].req_valid; 
    assign dcache_arb_in_if[0].req_data.rw = dcache_cpu_bus_if[i].req_data.rw; 
    assign dcache_arb_in_if[0].req_data.addr = dcache_cpu_bus_if[i].req_data.addr; 
    assign dcache_arb_in_if[0].req_data.data = dcache_cpu_bus_if[i].req_data.data; 
    assign dcache_arb_in_if[0].req_data.byteen = dcache_cpu_bus_if[i].req_data.byteen; 
    assign dcache_arb_in_if[0].req_data.flags = dcache_cpu_bus_if[i].req_data.flags; 
    if (DCACHE_ARB_TAG_WIDTH != DCACHE_TAG_WIDTH) begin 
        if (UUID_WIDTH != 0) begin 
            if (DCACHE_ARB_TAG_WIDTH > DCACHE_TAG_WIDTH) begin 
                assign dcache_arb_in_if[0].req_data.tag = {dcache_cpu_bus_if[i].req_data.tag.uuid, {(DCACHE_ARB_TAG_WIDTH-DCACHE_TAG_WIDTH){1'b0}}, dcache_cpu_bus_if[i].req_data.tag.value}; 
            end else begin 
                assign dcache_arb_in_if[0].req_data.tag = {dcache_cpu_bus_if[i].req_data.tag.uuid, dcache_cpu_bus_if[i].req_data.tag.value[DCACHE_ARB_TAG_WIDTH-UUID_WIDTH-1:0]}; 
            end 
        end else begin 
            if (DCACHE_ARB_TAG_WIDTH > DCACHE_TAG_WIDTH) begin 
                assign dcache_arb_in_if[0].req_data.tag = {{(DCACHE_ARB_TAG_WIDTH-DCACHE_TAG_WIDTH){1'b0}}, dcache_cpu_bus_if[i].req_data.tag}; 
            end else begin 
                assign dcache_arb_in_if[0].req_data.tag = dcache_cpu_bus_if[i].req_data.tag[DCACHE_ARB_TAG_WIDTH-1:0]; 
            end 
        end 
    end else begin 
        assign dcache_arb_in_if[0].req_data.tag = dcache_cpu_bus_if[i].req_data.tag; 
    end 
    assign dcache_cpu_bus_if[i].req_ready = dcache_arb_in_if[0].req_ready; 
    assign dcache_cpu_bus_if[i].rsp_valid = dcache_arb_in_if[0].rsp_valid; 
    assign dcache_cpu_bus_if[i].rsp_data.data = dcache_arb_in_if[0].rsp_data.data; 
    if (DCACHE_ARB_TAG_WIDTH != DCACHE_TAG_WIDTH) begin 
        if (UUID_WIDTH != 0) begin 
            if (DCACHE_ARB_TAG_WIDTH > DCACHE_TAG_WIDTH) begin 
                assign dcache_cpu_bus_if[i].rsp_data.tag = {dcache_arb_in_if[0].rsp_data.tag.uuid, dcache_arb_in_if[0].rsp_data.tag.value[DCACHE_TAG_WIDTH-UUID_WIDTH-1:0]}; 
            end else begin 
                assign dcache_cpu_bus_if[i].rsp_data.tag = {dcache_arb_in_if[0].rsp_data.tag.uuid, {(DCACHE_TAG_WIDTH-DCACHE_ARB_TAG_WIDTH){1'b0}}, dcache_arb_in_if[0].rsp_data.tag.value}; 
            end 
        end else begin 
            if (DCACHE_ARB_TAG_WIDTH > DCACHE_TAG_WIDTH) begin 
                assign dcache_cpu_bus_if[i].rsp_data.tag = dcache_arb_in_if[0].rsp_data.tag[DCACHE_TAG_WIDTH-1:0]; 
            end else begin 
                assign dcache_cpu_bus_if[i].rsp_data.tag = {{(DCACHE_TAG_WIDTH-DCACHE_ARB_TAG_WIDTH){1'b0}}, dcache_arb_in_if[0].rsp_data.tag}; 
            end 
        end 
    end else begin 
        assign dcache_cpu_bus_if[i].rsp_data.tag = dcache_arb_in_if[0].rsp_data.tag; 
    end 
    assign dcache_arb_in_if[0].rsp_ready = dcache_cpu_bus_if[i].rsp_ready 
    /*verilator lint_off GENUNNAMED*/ ;
    /*verilator lint_off GENUNNAMED*/  
    assign dcache_arb_in_if[1].req_valid = dcache_dma_lane_if[i].req_valid; 
    assign dcache_arb_in_if[1].req_data.rw = dcache_dma_lane_if[i].req_data.rw; 
    assign dcache_arb_in_if[1].req_data.addr = dcache_dma_lane_if[i].req_data.addr; 
    assign dcache_arb_in_if[1].req_data.data = dcache_dma_lane_if[i].req_data.data; 
    assign dcache_arb_in_if[1].req_data.byteen = dcache_dma_lane_if[i].req_data.byteen; 
    assign dcache_arb_in_if[1].req_data.flags = dcache_dma_lane_if[i].req_data.flags; 
    if (DCACHE_ARB_TAG_WIDTH != DMA_DCACHE_TAG_WIDTH) begin 
        if (UUID_WIDTH != 0) begin 
            if (DCACHE_ARB_TAG_WIDTH > DMA_DCACHE_TAG_WIDTH) begin 
                assign dcache_arb_in_if[1].req_data.tag = {dcache_dma_lane_if[i].req_data.tag.uuid, {(DCACHE_ARB_TAG_WIDTH-DMA_DCACHE_TAG_WIDTH){1'b0}}, dcache_dma_lane_if[i].req_data.tag.value}; 
            end else begin 
                assign dcache_arb_in_if[1].req_data.tag = {dcache_dma_lane_if[i].req_data.tag.uuid, dcache_dma_lane_if[i].req_data.tag.value[DCACHE_ARB_TAG_WIDTH-UUID_WIDTH-1:0]}; 
            end 
        end else begin 
            if (DCACHE_ARB_TAG_WIDTH > DMA_DCACHE_TAG_WIDTH) begin 
                assign dcache_arb_in_if[1].req_data.tag = {{(DCACHE_ARB_TAG_WIDTH-DMA_DCACHE_TAG_WIDTH){1'b0}}, dcache_dma_lane_if[i].req_data.tag}; 
            end else begin 
                assign dcache_arb_in_if[1].req_data.tag = dcache_dma_lane_if[i].req_data.tag[DCACHE_ARB_TAG_WIDTH-1:0]; 
            end 
        end 
    end else begin 
        assign dcache_arb_in_if[1].req_data.tag = dcache_dma_lane_if[i].req_data.tag; 
    end 
    assign dcache_dma_lane_if[i].req_ready = dcache_arb_in_if[1].req_ready; 
    assign dcache_dma_lane_if[i].rsp_valid = dcache_arb_in_if[1].rsp_valid; 
    assign dcache_dma_lane_if[i].rsp_data.data = dcache_arb_in_if[1].rsp_data.data; 
    if (DCACHE_ARB_TAG_WIDTH != DMA_DCACHE_TAG_WIDTH) begin 
        if (UUID_WIDTH != 0) begin 
            if (DCACHE_ARB_TAG_WIDTH > DMA_DCACHE_TAG_WIDTH) begin 
                assign dcache_dma_lane_if[i].rsp_data.tag = {dcache_arb_in_if[1].rsp_data.tag.uuid, dcache_arb_in_if[1].rsp_data.tag.value[DMA_DCACHE_TAG_WIDTH-UUID_WIDTH-1:0]}; 
            end else begin 
                assign dcache_dma_lane_if[i].rsp_data.tag = {dcache_arb_in_if[1].rsp_data.tag.uuid, {(DMA_DCACHE_TAG_WIDTH-DCACHE_ARB_TAG_WIDTH){1'b0}}, dcache_arb_in_if[1].rsp_data.tag.value}; 
            end 
        end else begin 
            if (DCACHE_ARB_TAG_WIDTH > DMA_DCACHE_TAG_WIDTH) begin 
                assign dcache_dma_lane_if[i].rsp_data.tag = dcache_arb_in_if[1].rsp_data.tag[DMA_DCACHE_TAG_WIDTH-1:0]; 
            end else begin 
                assign dcache_dma_lane_if[i].rsp_data.tag = {{(DMA_DCACHE_TAG_WIDTH-DCACHE_ARB_TAG_WIDTH){1'b0}}, dcache_arb_in_if[1].rsp_data.tag}; 
            end 
        end 
    end else begin 
        assign dcache_dma_lane_if[i].rsp_data.tag = dcache_arb_in_if[1].rsp_data.tag; 
    end 
    assign dcache_arb_in_if[1].rsp_ready = dcache_dma_lane_if[i].rsp_ready 
    /*verilator lint_off GENUNNAMED*/ ;
            VX_mem_arb #(
                .NUM_INPUTS  (2),
                .NUM_OUTPUTS (1),
                .DATA_SIZE   (DCACHE_WORD_SIZE),
                .TAG_WIDTH   (DCACHE_ARB_TAG_WIDTH),
                .TAG_SEL_IDX (DCACHE_ARB_TAG_WIDTH - UUID_WIDTH),
                .REQ_OUT_BUF (3),
                .RSP_OUT_BUF (3),
                .ARBITER     ("P")
            ) dcache_dma_arbiter (
                .clk        (clk),
                .reset      (reset),
                .bus_in_if  (dcache_arb_in_if),
                .bus_out_if (dcache_arb_out_if)
            );
    assign dcache_bus_if[i].req_valid  = dcache_arb_out_if[0].req_valid; 
    assign dcache_bus_if[i].req_data   = dcache_arb_out_if[0].req_data; 
    assign dcache_arb_out_if[0].req_ready  = dcache_bus_if[i].req_ready; 
    assign dcache_arb_out_if[0].rsp_valid  = dcache_bus_if[i].rsp_valid; 
    assign dcache_arb_out_if[0].rsp_data   = dcache_bus_if[i].rsp_data; 
    assign dcache_bus_if[i].rsp_ready  = dcache_arb_out_if[0].rsp_ready;
        end else if (i < DCACHE_NUM_REQS) begin : g_cpu_only
    /*verilator lint_off GENUNNAMED*/  
    assign dcache_bus_if[i].req_valid = dcache_cpu_bus_if[i].req_valid; 
    assign dcache_bus_if[i].req_data.rw = dcache_cpu_bus_if[i].req_data.rw; 
    assign dcache_bus_if[i].req_data.addr = dcache_cpu_bus_if[i].req_data.addr; 
    assign dcache_bus_if[i].req_data.data = dcache_cpu_bus_if[i].req_data.data; 
    assign dcache_bus_if[i].req_data.byteen = dcache_cpu_bus_if[i].req_data.byteen; 
    assign dcache_bus_if[i].req_data.flags = dcache_cpu_bus_if[i].req_data.flags; 
    if (DCACHE_CORE_TAG_WIDTH != DCACHE_TAG_WIDTH) begin 
        if (UUID_WIDTH != 0) begin 
            if (DCACHE_CORE_TAG_WIDTH > DCACHE_TAG_WIDTH) begin 
                assign dcache_bus_if[i].req_data.tag = {dcache_cpu_bus_if[i].req_data.tag.uuid, {(DCACHE_CORE_TAG_WIDTH-DCACHE_TAG_WIDTH){1'b0}}, dcache_cpu_bus_if[i].req_data.tag.value}; 
            end else begin 
                assign dcache_bus_if[i].req_data.tag = {dcache_cpu_bus_if[i].req_data.tag.uuid, dcache_cpu_bus_if[i].req_data.tag.value[DCACHE_CORE_TAG_WIDTH-UUID_WIDTH-1:0]}; 
            end 
        end else begin 
            if (DCACHE_CORE_TAG_WIDTH > DCACHE_TAG_WIDTH) begin 
                assign dcache_bus_if[i].req_data.tag = {{(DCACHE_CORE_TAG_WIDTH-DCACHE_TAG_WIDTH){1'b0}}, dcache_cpu_bus_if[i].req_data.tag}; 
            end else begin 
                assign dcache_bus_if[i].req_data.tag = dcache_cpu_bus_if[i].req_data.tag[DCACHE_CORE_TAG_WIDTH-1:0]; 
            end 
        end 
    end else begin 
        assign dcache_bus_if[i].req_data.tag = dcache_cpu_bus_if[i].req_data.tag; 
    end 
    assign dcache_cpu_bus_if[i].req_ready = dcache_bus_if[i].req_ready; 
    assign dcache_cpu_bus_if[i].rsp_valid = dcache_bus_if[i].rsp_valid; 
    assign dcache_cpu_bus_if[i].rsp_data.data = dcache_bus_if[i].rsp_data.data; 
    if (DCACHE_CORE_TAG_WIDTH != DCACHE_TAG_WIDTH) begin 
        if (UUID_WIDTH != 0) begin 
            if (DCACHE_CORE_TAG_WIDTH > DCACHE_TAG_WIDTH) begin 
                assign dcache_cpu_bus_if[i].rsp_data.tag = {dcache_bus_if[i].rsp_data.tag.uuid, dcache_bus_if[i].rsp_data.tag.value[DCACHE_TAG_WIDTH-UUID_WIDTH-1:0]}; 
            end else begin 
                assign dcache_cpu_bus_if[i].rsp_data.tag = {dcache_bus_if[i].rsp_data.tag.uuid, {(DCACHE_TAG_WIDTH-DCACHE_CORE_TAG_WIDTH){1'b0}}, dcache_bus_if[i].rsp_data.tag.value}; 
            end 
        end else begin 
            if (DCACHE_CORE_TAG_WIDTH > DCACHE_TAG_WIDTH) begin 
                assign dcache_cpu_bus_if[i].rsp_data.tag = dcache_bus_if[i].rsp_data.tag[DCACHE_TAG_WIDTH-1:0]; 
            end else begin 
                assign dcache_cpu_bus_if[i].rsp_data.tag = {{(DCACHE_TAG_WIDTH-DCACHE_CORE_TAG_WIDTH){1'b0}}, dcache_bus_if[i].rsp_data.tag}; 
            end 
        end 
    end else begin 
        assign dcache_cpu_bus_if[i].rsp_data.tag = dcache_bus_if[i].rsp_data.tag; 
    end 
    assign dcache_bus_if[i].rsp_ready = dcache_cpu_bus_if[i].rsp_ready 
    /*verilator lint_off GENUNNAMED*/ ;
        end else begin : g_dma_only
    /*verilator lint_off GENUNNAMED*/  
    assign dcache_bus_if[i].req_valid = dcache_dma_lane_if[i].req_valid; 
    assign dcache_bus_if[i].req_data.rw = dcache_dma_lane_if[i].req_data.rw; 
    assign dcache_bus_if[i].req_data.addr = dcache_dma_lane_if[i].req_data.addr; 
    assign dcache_bus_if[i].req_data.data = dcache_dma_lane_if[i].req_data.data; 
    assign dcache_bus_if[i].req_data.byteen = dcache_dma_lane_if[i].req_data.byteen; 
    assign dcache_bus_if[i].req_data.flags = dcache_dma_lane_if[i].req_data.flags; 
    if (DCACHE_CORE_TAG_WIDTH != DMA_DCACHE_TAG_WIDTH) begin 
        if (UUID_WIDTH != 0) begin 
            if (DCACHE_CORE_TAG_WIDTH > DMA_DCACHE_TAG_WIDTH) begin 
                assign dcache_bus_if[i].req_data.tag = {dcache_dma_lane_if[i].req_data.tag.uuid, {(DCACHE_CORE_TAG_WIDTH-DMA_DCACHE_TAG_WIDTH){1'b0}}, dcache_dma_lane_if[i].req_data.tag.value}; 
            end else begin 
                assign dcache_bus_if[i].req_data.tag = {dcache_dma_lane_if[i].req_data.tag.uuid, dcache_dma_lane_if[i].req_data.tag.value[DCACHE_CORE_TAG_WIDTH-UUID_WIDTH-1:0]}; 
            end 
        end else begin 
            if (DCACHE_CORE_TAG_WIDTH > DMA_DCACHE_TAG_WIDTH) begin 
                assign dcache_bus_if[i].req_data.tag = {{(DCACHE_CORE_TAG_WIDTH-DMA_DCACHE_TAG_WIDTH){1'b0}}, dcache_dma_lane_if[i].req_data.tag}; 
            end else begin 
                assign dcache_bus_if[i].req_data.tag = dcache_dma_lane_if[i].req_data.tag[DCACHE_CORE_TAG_WIDTH-1:0]; 
            end 
        end 
    end else begin 
        assign dcache_bus_if[i].req_data.tag = dcache_dma_lane_if[i].req_data.tag; 
    end 
    assign dcache_dma_lane_if[i].req_ready = dcache_bus_if[i].req_ready; 
    assign dcache_dma_lane_if[i].rsp_valid = dcache_bus_if[i].rsp_valid; 
    assign dcache_dma_lane_if[i].rsp_data.data = dcache_bus_if[i].rsp_data.data; 
    if (DCACHE_CORE_TAG_WIDTH != DMA_DCACHE_TAG_WIDTH) begin 
        if (UUID_WIDTH != 0) begin 
            if (DCACHE_CORE_TAG_WIDTH > DMA_DCACHE_TAG_WIDTH) begin 
                assign dcache_dma_lane_if[i].rsp_data.tag = {dcache_bus_if[i].rsp_data.tag.uuid, dcache_bus_if[i].rsp_data.tag.value[DMA_DCACHE_TAG_WIDTH-UUID_WIDTH-1:0]}; 
            end else begin 
                assign dcache_dma_lane_if[i].rsp_data.tag = {dcache_bus_if[i].rsp_data.tag.uuid, {(DMA_DCACHE_TAG_WIDTH-DCACHE_CORE_TAG_WIDTH){1'b0}}, dcache_bus_if[i].rsp_data.tag.value}; 
            end 
        end else begin 
            if (DCACHE_CORE_TAG_WIDTH > DMA_DCACHE_TAG_WIDTH) begin 
                assign dcache_dma_lane_if[i].rsp_data.tag = dcache_bus_if[i].rsp_data.tag[DMA_DCACHE_TAG_WIDTH-1:0]; 
            end else begin 
                assign dcache_dma_lane_if[i].rsp_data.tag = {{(DMA_DCACHE_TAG_WIDTH-DCACHE_CORE_TAG_WIDTH){1'b0}}, dcache_bus_if[i].rsp_data.tag}; 
            end 
        end 
    end else begin 
        assign dcache_dma_lane_if[i].rsp_data.tag = dcache_bus_if[i].rsp_data.tag; 
    end 
    assign dcache_bus_if[i].rsp_ready = dcache_dma_lane_if[i].rsp_ready 
    /*verilator lint_off GENUNNAMED*/ ;
        end
    end
endmodule
