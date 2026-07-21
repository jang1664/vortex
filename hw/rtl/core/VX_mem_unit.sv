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

module VX_mem_unit import VX_gpu_pkg::*; #(
    parameter `STRING INSTANCE_ID = ""
) (
    input wire              clk,
    input wire              reset,

`ifdef PERF_ENABLE
    output lmem_perf_t      lmem_perf,
    output coalescer_perf_t coalescer_perf,
`endif

    VX_lsu_mem_if.slave     lsu_mem_if [`NUM_LSU_BLOCKS],
    VX_mem_bus_if.master    dcache_bus_if [DCACHE_CORE_NUM_REQS],
    VX_lsu_mem_if.master    dma_ctrl_if [`NUM_LSU_BLOCKS],
    VX_lsu_mem_if.master    gemm_ctrl_if [`NUM_LSU_BLOCKS],
    VX_mem_bus_if.slave     dma_local_data_if [`LMEM_NUM_PORTS],
    VX_mem_bus_if.slave     dma_global_data_if
`ifdef GEMM_NAIVE
   ,VX_mem_bus_if.slave     gemm_data_if [`LMEM_NUM_PORTS]
`endif
);
    VX_lsu_mem_if #(
        .NUM_LANES (`NUM_LSU_LANES),
        .DATA_SIZE (LSU_WORD_SIZE),
        .TAG_WIDTH (LSU_TAG_WIDTH)
    ) lsu_dcache_if[`NUM_LSU_BLOCKS]();

`ifdef LMEM_ENABLE

    `VX_STATIC_ASSERT(`IS_DIVISBLE((1 << `LMEM_LOG_SIZE), `MEM_BLOCK_SIZE), ("invalid parameter"))
    `VX_STATIC_ASSERT(0 == (`LMEM_BASE_ADDR % (1 << `LMEM_LOG_SIZE)), ("invalid parameter"))

    localparam LMEM_ADDR_WIDTH = `LMEM_LOG_SIZE - `CLOG2(LSU_WORD_SIZE);
    localparam CPU_LMEM_ARB_SEL_BITS = `ARB_SEL_BITS(`NUM_LSU_BLOCKS, 1);
    localparam CPU_LMEM_TAG_WIDTH = LSU_TAG_WIDTH + CPU_LMEM_ARB_SEL_BITS;
    localparam logic [63:0] GEMM_MMIO_SIZE_B = 64'd1024;
    localparam logic [63:0] DMA_MMIO_SIZE_B  = 64'd1024;

    `VX_STATIC_ASSERT(CPU_LMEM_TAG_WIDTH <= GEMM_LMEM_TAG_WIDTH,
        ("invalid CPU LMEM tag width: CPU=%0d, shared=%0d", CPU_LMEM_TAG_WIDTH, GEMM_LMEM_TAG_WIDTH))

    VX_lsu_mem_if #(
        .NUM_LANES (`NUM_LSU_LANES),
        .DATA_SIZE (LSU_WORD_SIZE),
        .TAG_WIDTH (LSU_TAG_WIDTH)
    ) lsu_lmem_if[`NUM_LSU_BLOCKS]();

    for (genvar i = 0; i < `NUM_LSU_BLOCKS; ++i) begin : g_lmem_switches
        VX_lmem_switch #(
            .GLOBAL_OUT_BUF(0),
            .LOCAL_OUT_BUF(1),
            .GEMM_OUT_BUF (1),
            .DMA_OUT_BUF  (1),
            .RSP_OUT_BUF  (1),
            .GEMM_MMIO_BASE_ADDR(`GEMM_REG_BASE_ADDR),
            .DMA_MMIO_BASE_ADDR (`DMA_REG_BASE_ADDR),
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
        .NUM_LANES (`NUM_LSU_LANES),
        .DATA_SIZE (LSU_WORD_SIZE),
        .TAG_WIDTH (CPU_LMEM_TAG_WIDTH)
    ) lmem_arb_if[1]();

    VX_lsu_mem_arb #(
        .NUM_INPUTS (`NUM_LSU_BLOCKS),
        .NUM_OUTPUTS(1),
        .NUM_LANES  (`NUM_LSU_LANES),
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
    ) lmem_adapt_if[`NUM_LSU_LANES]();

    VX_lsu_adapter #(
        .NUM_LANES    (`NUM_LSU_LANES),
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
    ) lmem_membus_arb_out_if[`LMEM_NUM_PORTS]();

    // Per-lane local-memory arbitration. The naive backend adds the GEMM
    // shared-LMEM client; the improve backend retains the current 2:1 path.
    for (genvar i = 0; i < `LMEM_NUM_PORTS; ++i) begin : g_lmem_lane_dma_arb
        VX_mem_bus_if #(
            .DATA_SIZE (LSU_WORD_SIZE),
            .TAG_WIDTH (GEMM_LMEM_TAG_WIDTH)
`ifdef GEMM_NAIVE
        ) lane_arb_in_if[3]();
`else
        ) lane_arb_in_if[2]();
`endif

        VX_mem_bus_if #(
            .DATA_SIZE (LSU_WORD_SIZE),
            .TAG_WIDTH (LMEM_LOCAL_TAG_WIDTH)
        ) lane_arb_out_if[1]();

        if (i < `NUM_LSU_LANES) begin : g_cpu_lmem_port
            `ASSIGN_VX_MEM_BUS_IF_EX(lane_arb_in_if[0], lmem_adapt_if[i], GEMM_LMEM_TAG_WIDTH, CPU_LMEM_TAG_WIDTH, UUID_WIDTH);
        end else begin : g_no_cpu_lmem_port
            assign lane_arb_in_if[0].req_valid = 1'b0;
            assign lane_arb_in_if[0].req_data  = '0;
            assign lane_arb_in_if[0].rsp_ready = 1'b1;
        end
        `ASSIGN_VX_MEM_BUS_IF_EX(lane_arb_in_if[1], dma_local_data_if[i], GEMM_LMEM_TAG_WIDTH, LMEM_TAG_WIDTH, UUID_WIDTH);
`ifdef GEMM_NAIVE
        `ASSIGN_VX_MEM_BUS_IF(lane_arb_in_if[2], gemm_data_if[i]);
`endif

        VX_mem_arb #(
`ifdef GEMM_NAIVE
            .NUM_INPUTS  (3),
`else
            .NUM_INPUTS  (2),
`endif
            .NUM_OUTPUTS (1),
            .DATA_SIZE   (LSU_WORD_SIZE),
            .TAG_WIDTH   (GEMM_LMEM_TAG_WIDTH),
            .TAG_SEL_IDX (GEMM_LMEM_TAG_WIDTH - UUID_WIDTH),
            .REQ_OUT_BUF (3),
            .RSP_OUT_BUF (3),
`ifdef GEMM_NAIVE
            .ARBITER     ("R")
`else
            .ARBITER     ("P")
`endif
        ) lmem_membus_dma_arbiter (
            .clk        (clk),
            .reset      (reset),
            .bus_in_if  (lane_arb_in_if),
            .bus_out_if (lane_arb_out_if)
        );

        `ASSIGN_VX_MEM_BUS_IF(lmem_membus_arb_out_if[i], lane_arb_out_if[0]);
    end
    
    VX_local_mem #(
        .INSTANCE_ID(`SFORMATF(("%s-lmem", INSTANCE_ID))),
        .SIZE       (1 << `LMEM_LOG_SIZE),
        .NUM_REQS   (`LMEM_NUM_PORTS),
        .NUM_BANKS  (`LMEM_NUM_BANKS),
        .WORD_SIZE  (LSU_WORD_SIZE),
        .ADDR_WIDTH (LMEM_ADDR_WIDTH),
        .TAG_WIDTH  (LMEM_LOCAL_TAG_WIDTH),
        .OUT_BUF    (3)
    ) local_mem (
        .clk        (clk),
        .reset      (reset),
    `ifdef PERF_ENABLE
        .lmem_perf  (lmem_perf),
    `endif
        .mem_bus_if (lmem_membus_arb_out_if)
    );

`else

`ifdef PERF_ENABLE
    assign lmem_perf = '0;
`endif

    for (genvar i = 0; i < `NUM_LSU_BLOCKS; ++i) begin : g_lsu_dcache_if
        `ASSIGN_VX_MEM_BUS_IF (lsu_dcache_if[i], lsu_mem_if[i]);
    end

`ifdef GEMM_NAIVE
    for (genvar i = 0; i < `LMEM_NUM_PORTS; ++i) begin : g_unused_gemm_data_if
        `UNUSED_VX_MEM_BUS_IF (gemm_data_if[i])
    end
`endif

`endif

    VX_lsu_mem_if #(
        .NUM_LANES (DCACHE_CHANNELS),
        .DATA_SIZE (DCACHE_WORD_SIZE),
        .TAG_WIDTH (DCACHE_TAG_WIDTH)
    ) dcache_coalesced_if[`NUM_LSU_BLOCKS]();

`ifdef PERF_ENABLE
    wire [`NUM_LSU_BLOCKS-1:0][PERF_CTR_BITS-1:0] per_block_coalescer_misses;
    wire [PERF_CTR_BITS-1:0] coalescer_misses;
    VX_reduce_tree #(
        .IN_W (PERF_CTR_BITS),
        .N    (`NUM_LSU_BLOCKS),
        .OP   ("+")
    ) coalescer_reduce (
        .data_in  (per_block_coalescer_misses),
        .data_out (coalescer_misses)
    );
    `BUFFER(coalescer_perf.misses, coalescer_misses);
`endif

    if ((`NUM_LSU_LANES > 1) && (LSU_WORD_SIZE != DCACHE_WORD_SIZE)) begin : g_enabled

        for (genvar i = 0; i < `NUM_LSU_BLOCKS; ++i) begin : g_coalescers
            VX_mem_coalescer #(
                .INSTANCE_ID    (`SFORMATF(("%s-coalescer%0d", INSTANCE_ID, i))),
                .NUM_REQS       (`NUM_LSU_LANES),
                .DATA_IN_SIZE   (LSU_WORD_SIZE),
                .DATA_OUT_SIZE  (DCACHE_WORD_SIZE),
                .ADDR_WIDTH     (LSU_ADDR_WIDTH),
                .FLAGS_WIDTH    (MEM_FLAGS_WIDTH),
                .TAG_WIDTH      (LSU_TAG_WIDTH),
                .UUID_WIDTH     (UUID_WIDTH),
                .QUEUE_SIZE     (`LSUQ_OUT_SIZE),
                .PERF_CTR_BITS  (PERF_CTR_BITS)
            ) mem_coalescer (
                .clk            (clk),
                .reset          (reset),

            `ifdef PERF_ENABLE
                .misses         (per_block_coalescer_misses[i]),
            `else
                `UNUSED_PIN (misses),
            `endif

                // Input request
                .in_req_valid   (lsu_dcache_if[i].req_valid),
                .in_req_mask    (lsu_dcache_if[i].req_data.mask),
                .in_req_rw      (lsu_dcache_if[i].req_data.rw),
                .in_req_byteen  (lsu_dcache_if[i].req_data.byteen),
                .in_req_addr    (lsu_dcache_if[i].req_data.addr),
                .in_req_flags   (lsu_dcache_if[i].req_data.flags),
                .in_req_data    (lsu_dcache_if[i].req_data.data),
                .in_req_tag     (lsu_dcache_if[i].req_data.tag),
                .in_req_ready   (lsu_dcache_if[i].req_ready),

                // Input response
                .in_rsp_valid   (lsu_dcache_if[i].rsp_valid),
                .in_rsp_mask    (lsu_dcache_if[i].rsp_data.mask),
                .in_rsp_data    (lsu_dcache_if[i].rsp_data.data),
                .in_rsp_tag     (lsu_dcache_if[i].rsp_data.tag),
                .in_rsp_ready   (lsu_dcache_if[i].rsp_ready),

                // Output request
                .out_req_valid  (dcache_coalesced_if[i].req_valid),
                .out_req_mask   (dcache_coalesced_if[i].req_data.mask),
                .out_req_rw     (dcache_coalesced_if[i].req_data.rw),
                .out_req_byteen (dcache_coalesced_if[i].req_data.byteen),
                .out_req_addr   (dcache_coalesced_if[i].req_data.addr),
                .out_req_flags  (dcache_coalesced_if[i].req_data.flags),
                .out_req_data   (dcache_coalesced_if[i].req_data.data),
                .out_req_tag    (dcache_coalesced_if[i].req_data.tag),
                .out_req_ready  (dcache_coalesced_if[i].req_ready),

                // Output response
                .out_rsp_valid  (dcache_coalesced_if[i].rsp_valid),
                .out_rsp_mask   (dcache_coalesced_if[i].rsp_data.mask),
                .out_rsp_data   (dcache_coalesced_if[i].rsp_data.data),
                .out_rsp_tag    (dcache_coalesced_if[i].rsp_data.tag),
                .out_rsp_ready  (dcache_coalesced_if[i].rsp_ready)
            );
        end

    end else begin : g_passthru

        for (genvar i = 0; i < `NUM_LSU_BLOCKS; ++i) begin : g_dcache_coalesced_if
            `ASSIGN_VX_MEM_BUS_IF (dcache_coalesced_if[i], lsu_dcache_if[i]);
        `ifdef PERF_ENABLE
            assign per_block_coalescer_misses[i] = '0;
        `endif
        end

    end

    VX_mem_bus_if #(
        .DATA_SIZE (DCACHE_WORD_SIZE),
        .TAG_WIDTH (DCACHE_TAG_WIDTH)
    ) dcache_cpu_bus_if[DCACHE_NUM_REQS]();

    for (genvar i = 0; i < `NUM_LSU_BLOCKS; ++i) begin : g_dcache_adapters

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
            `ASSIGN_VX_MEM_BUS_IF (dcache_cpu_bus_if[i * DCACHE_CHANNELS + j], dcache_bus_tmp_if[j]);
        end
    end

    // The common DMA operates on one aggregate cache beat. Scatter it into
    // independent cache-line requests without changing the CPU LSU width.
    VX_mem_bus_if #(
        .DATA_SIZE (DCACHE_WORD_SIZE),
        .TAG_WIDTH (DMA_DCACHE_TAG_WIDTH)
    ) dcache_dma_lane_if[`DMA_DCACHE_PORTS]();

    if (`DMA_DCACHE_PORTS == 1) begin : g_single_dma_dcache_port
        `ASSIGN_VX_MEM_BUS_IF(dcache_dma_lane_if[0], dma_global_data_if);
    end else begin : g_split_dma_dcache_ports
        VX_mem_bus_split #(
            .NUM_LANES      (`DMA_DCACHE_PORTS),
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
        if ((i < DCACHE_NUM_REQS) && (i < `DMA_DCACHE_PORTS)) begin : g_cpu_dma_arb
            VX_mem_bus_if #(
                .DATA_SIZE (DCACHE_WORD_SIZE),
                .TAG_WIDTH (DCACHE_ARB_TAG_WIDTH)
            ) dcache_arb_in_if[2]();

            VX_mem_bus_if #(
                .DATA_SIZE (DCACHE_WORD_SIZE),
                .TAG_WIDTH (DCACHE_CORE_TAG_WIDTH)
            ) dcache_arb_out_if[1]();

            `ASSIGN_VX_MEM_BUS_IF_EX(dcache_arb_in_if[0], dcache_cpu_bus_if[i], DCACHE_ARB_TAG_WIDTH, DCACHE_TAG_WIDTH, UUID_WIDTH);
            `ASSIGN_VX_MEM_BUS_IF_EX(dcache_arb_in_if[1], dcache_dma_lane_if[i], DCACHE_ARB_TAG_WIDTH, DMA_DCACHE_TAG_WIDTH, UUID_WIDTH);

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

            `ASSIGN_VX_MEM_BUS_IF(dcache_bus_if[i], dcache_arb_out_if[0]);
        end else if (i < DCACHE_NUM_REQS) begin : g_cpu_only
            `ASSIGN_VX_MEM_BUS_IF_EX(dcache_bus_if[i], dcache_cpu_bus_if[i], DCACHE_CORE_TAG_WIDTH, DCACHE_TAG_WIDTH, UUID_WIDTH);
        end else begin : g_dma_only
            `ASSIGN_VX_MEM_BUS_IF_EX(dcache_bus_if[i], dcache_dma_lane_if[i], DCACHE_CORE_TAG_WIDTH, DMA_DCACHE_TAG_WIDTH, UUID_WIDTH);
        end

    end

endmodule
