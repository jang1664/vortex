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

// VX_tmem_subsystem
//  Top-level tensor memory subsystem integrating:
//  - VX_dma_engine:        8-channel HBM(AXI) <-> TMEM(membus) DMA
//  - VX_tensor_mem_bank:   8 TMEM banks with 5-port arbitration each
//  - VX_tmem_switch:       Address-based 1:N bank routing (x4)
//  - VX_lmem_dma_misal:    Local DMA for TMEM <-> GEMM data movement (x4)
//
//  Data flow:
//    HBM <-> DMA engine <-> TMEM banks <-> switches <-> local DMAs <-> GEMM unit

module VX_tmem_subsystem import VX_gpu_pkg::*; #(
    parameter `STRING INSTANCE_ID = "",
    parameter NUM_BANKS         = 8,
    parameter BANK_SIZE         = 32*1024,      // 32KB per bank
    parameter DATA_SIZE         = 64,           // 512-bit = 64 bytes
    parameter GEMM_DATA_SIZE    = 64,           // GEMM unit port width (64B)
    parameter GEMM_WEIGHT_DATA_SIZE = GEMM_DATA_SIZE,
    parameter TAG_WIDTH         = 8,
    parameter AXI_ADDR_WIDTH    = `PLATFORM_MEMORY_ADDR_WIDTH,
    parameter AXI_DATA_WIDTH    = `PLATFORM_MEMORY_DATA_SIZE * 8,
    parameter AXI_ID_WIDTH      = 8,
    parameter AXI_USER_WIDTH    = 1,
    parameter int I_RD_PREFETCH_DEPTH = `I_LMEM_DMA_RD_PREFETCH_DEPTH,
    parameter int W_RD_PREFETCH_DEPTH = `W_LMEM_DMA_RD_PREFETCH_DEPTH,
    parameter int SZ_RD_PREFETCH_DEPTH = `SZ_LMEM_DMA_RD_PREFETCH_DEPTH,
    parameter int O_RD_PREFETCH_DEPTH = `O_LMEM_DMA_RD_PREFETCH_DEPTH,
    parameter int DMA_RD_OUTSTANDING = `TMEM_DMA_RD_OUTSTANDING_SLOT
) (
    input wire clk,
    input wire reset,

    // DMA config (from gemm_dma_ctrl, 8 channels for DMA engine)
    VX_config_reg_if.slave  dma_cfg_if [NUM_BANKS],
    VX_node_done_if.master  dma_done_if [NUM_BANKS],

    // Local DMA control (from gemm_ctrl, 4 channels: input/weight/sz/output)
    VX_lmem_dma_ctrl_if.slave ldma_ctrl_if [4],

    // HBM side: AXI master ports (pass through to DMA engine)
    AXI_BUS.Master axi_m [NUM_BANKS],

    // GEMM unit side: 4 memory bus interfaces
    VX_mem_bus_if.master gemm_input_if,
    VX_mem_bus_if.master gemm_weight_if,
    VX_mem_bus_if.master gemm_sz_if,
    VX_mem_bus_if.master gemm_output_if
`ifdef PERF_ENABLE
    ,output hbm_dma_perf_t hbm_dma_perf
    ,output dma_perf_t     lmem_dma_input_perf
    ,output dma_perf_t     lmem_dma_weight_perf
    ,output dma_perf_t     lmem_dma_sz_perf
    ,output dma_perf_t     lmem_dma_output_perf
`endif
);

    localparam DATA_WIDTH       = DATA_SIZE * 8;
    localparam NUM_TMEM_PORTS   = 5;    // DMA + input + weight + sz + output
    localparam NUM_LDMA         = 4;    // input, weight, scale_zp, output
    localparam BANK_SEL_BITS    = `CLOG2(NUM_BANKS);
    // Switch appends BANK_SEL_BITS to tag, and TMEM bank arbiter appends
    // its own selector bits. The TMEM bank sees:
    //   TAG_WIDTH (original) + BANK_SEL_BITS (from switch)
    localparam SWITCH_TAG_WIDTH = TAG_WIDTH + BANK_SEL_BITS;

    `UNUSED_SPARAM (INSTANCE_ID)
    `UNUSED_PARAM (AXI_USER_WIDTH)

    // ================================================================
    // 1. DMA Engine: 8-channel HBM(AXI) <-> TMEM(membus)
    // ================================================================

    VX_mem_bus_if #(
        .DATA_SIZE  (DATA_SIZE),
        .TAG_WIDTH  (TAG_WIDTH)
    ) dma_to_tmem [NUM_BANKS] ();

    VX_dma_engine #(
        .INSTANCE_ID    ({INSTANCE_ID, ":dma"}),
        .NUM_CHANNELS   (NUM_BANKS),
        .DATA_WIDTH     (DATA_WIDTH),
        .AXI_ADDR_WIDTH (AXI_ADDR_WIDTH),
        .AXI_DATA_WIDTH (AXI_DATA_WIDTH),
        .AXI_ID_WIDTH   (AXI_ID_WIDTH),
        .TAG_WIDTH      (TAG_WIDTH),
        .RD_OUTSTANDING (DMA_RD_OUTSTANDING)
    ) u_dma_engine (
        .clk            (clk),
        .reset          (reset),
        .cfg_reg_if     (dma_cfg_if),
        .done_if        (dma_done_if),
        .axi_m          (axi_m),
        .tmem_bus_if    (dma_to_tmem)
    `ifdef PERF_ENABLE
        ,.perf          (hbm_dma_perf)
    `endif
    );

    // ================================================================
    // 2. Local DMA -> Switch -> TMEM bank wiring
    // ================================================================
    // Each switch connects 1 local DMA to NUM_BANKS TMEM bank ports.
    // We use separate 1D interface arrays per switch to avoid 2D arrays.

    // Switch outputs: per-switch, per-bank connections
    VX_mem_bus_if #(
        .DATA_SIZE  (DATA_SIZE),
        .TAG_WIDTH  (SWITCH_TAG_WIDTH)
    ) in_switch_to_tmem [NUM_BANKS] ();

    VX_mem_bus_if #(
        .DATA_SIZE  (DATA_SIZE),
        .TAG_WIDTH  (SWITCH_TAG_WIDTH)
    ) wt_switch_to_tmem [NUM_BANKS] ();

    VX_mem_bus_if #(
        .DATA_SIZE  (DATA_SIZE),
        .TAG_WIDTH  (SWITCH_TAG_WIDTH)
    ) sz_switch_to_tmem [NUM_BANKS] ();

    VX_mem_bus_if #(
        .DATA_SIZE  (DATA_SIZE),
        .TAG_WIDTH  (SWITCH_TAG_WIDTH)
    ) out_switch_to_tmem [NUM_BANKS] ();

    // Internal buses: local DMA tmem port -> switch input
    VX_mem_bus_if #(
        .DATA_SIZE  (DATA_SIZE),
        .TAG_WIDTH  (TAG_WIDTH)
    ) ldma_to_switch [NUM_LDMA] ();

    // Internal buses: local DMA gemm port -> GEMM unit
    VX_mem_bus_if #(
        .DATA_SIZE  (GEMM_DATA_SIZE),
        .TAG_WIDTH  (TAG_WIDTH)
    ) ldma_gemm [NUM_LDMA] ();

`ifdef WLOAD_AT_ONCE
    VX_mem_bus_if #(
        .DATA_SIZE  (GEMM_WEIGHT_DATA_SIZE),
        .TAG_WIDTH  (TAG_WIDTH)
    ) ldma_weight_to_tmem ();

    VX_mem_bus_if #(
        .DATA_SIZE  (GEMM_WEIGHT_DATA_SIZE),
        .TAG_WIDTH  (TAG_WIDTH)
    ) ldma_gemm_weight ();
`endif

    VX_gemm_sync_if ldma_sync_if [NUM_LDMA] ();

    for (genvar i = 0; i < NUM_LDMA; ++i) begin : g_ldma_sync
        assign ldma_sync_if[i].ready = 1'b1;
    end

    // ================================================================
    // 3. Switches: 1:N address-based bank routing (x4)
    // ================================================================

    VX_tmem_switch #(
        .INSTANCE_ID    ({INSTANCE_ID, ":sw_in"}),
        .NUM_BANKS      (NUM_BANKS),
        .DATA_SIZE      (DATA_SIZE),
        .TAG_WIDTH      (TAG_WIDTH)
    ) u_switch_input (
        .clk        (clk),
        .reset      (reset),
        .bus_in_if  (ldma_to_switch[0]),
        .bus_out_if (in_switch_to_tmem)
    );

`ifdef WLOAD_AT_ONCE
    VX_tmem_wide_read_switch #(
        .INSTANCE_ID    ({INSTANCE_ID, ":sw_wt_wide"}),
        .NUM_BANKS      (NUM_BANKS),
        .DATA_SIZE      (DATA_SIZE),
        .WIDE_DATA_SIZE (GEMM_WEIGHT_DATA_SIZE),
        .TAG_WIDTH      (TAG_WIDTH)
    ) u_switch_weight (
        .clk        (clk),
        .reset      (reset),
        .bus_in_if  (ldma_weight_to_tmem),
        .bus_out_if (wt_switch_to_tmem)
    );

`else
    VX_tmem_switch #(
        .INSTANCE_ID    ({INSTANCE_ID, ":sw_wt"}),
        .NUM_BANKS      (NUM_BANKS),
        .DATA_SIZE      (DATA_SIZE),
        .TAG_WIDTH      (TAG_WIDTH)
    ) u_switch_weight (
        .clk        (clk),
        .reset      (reset),
        .bus_in_if  (ldma_to_switch[1]),
        .bus_out_if (wt_switch_to_tmem)
    );
`endif

    VX_tmem_switch #(
        .INSTANCE_ID    ({INSTANCE_ID, ":sw_sz"}),
        .NUM_BANKS      (NUM_BANKS),
        .DATA_SIZE      (DATA_SIZE),
        .TAG_WIDTH      (TAG_WIDTH)
    ) u_switch_sz (
        .clk        (clk),
        .reset      (reset),
        .bus_in_if  (ldma_to_switch[2]),
        .bus_out_if (sz_switch_to_tmem)
    );

    VX_tmem_switch #(
        .INSTANCE_ID    ({INSTANCE_ID, ":sw_out"}),
        .NUM_BANKS      (NUM_BANKS),
        .DATA_SIZE      (DATA_SIZE),
        .TAG_WIDTH      (TAG_WIDTH)
    ) u_switch_output (
        .clk        (clk),
        .reset      (reset),
        .bus_in_if  (ldma_to_switch[3]),
        .bus_out_if (out_switch_to_tmem)
    );

    // ================================================================
    // 4. TMEM Banks x NUM_BANKS
    // ================================================================
    // Each bank has 5 ports:
    //   port[0] = DMA direct (1:1)     (SWITCH_TAG_WIDTH)
    //   port[1] = input switch        (SWITCH_TAG_WIDTH)
    //   port[2] = weight switch       (SWITCH_TAG_WIDTH)
    //   port[3] = scale_zp switch     (SWITCH_TAG_WIDTH)
    //   port[4] = output switch       (SWITCH_TAG_WIDTH)
    //
    // All ports use SWITCH_TAG_WIDTH (the switch appends bank-select bits).

    for (genvar b = 0; b < NUM_BANKS; ++b) begin : g_bank

        // Create per-bank port array with uniform SWITCH_TAG_WIDTH
        VX_mem_bus_if #(
            .DATA_SIZE  (DATA_SIZE),
            .TAG_WIDTH  (SWITCH_TAG_WIDTH)
        ) bank_port_if [NUM_TMEM_PORTS] ();

        // Port 0: DMA direct (ch b -> bank b, 1:1 mapping)
        assign bank_port_if[0].req_valid       = dma_to_tmem[b].req_valid;
        assign bank_port_if[0].req_data.rw     = dma_to_tmem[b].req_data.rw;
        assign bank_port_if[0].req_data.addr   = dma_to_tmem[b].req_data.addr;
        assign bank_port_if[0].req_data.data   = dma_to_tmem[b].req_data.data;
        assign bank_port_if[0].req_data.byteen = dma_to_tmem[b].req_data.byteen;
        assign bank_port_if[0].req_data.flags  = dma_to_tmem[b].req_data.flags;
        assign bank_port_if[0].req_data.tag    = {{BANK_SEL_BITS{1'b0}}, dma_to_tmem[b].req_data.tag};
        assign dma_to_tmem[b].req_ready        = bank_port_if[0].req_ready;

        assign dma_to_tmem[b].rsp_valid     = bank_port_if[0].rsp_valid;
        assign dma_to_tmem[b].rsp_data.data = bank_port_if[0].rsp_data.data;
        assign dma_to_tmem[b].rsp_data.tag  = bank_port_if[0].rsp_data.tag[TAG_WIDTH-1:0];
        assign bank_port_if[0].rsp_ready    = dma_to_tmem[b].rsp_ready;

        // Port 1: input switch
        assign bank_port_if[1].req_valid       = in_switch_to_tmem[b].req_valid;
        assign bank_port_if[1].req_data.rw     = in_switch_to_tmem[b].req_data.rw;
        assign bank_port_if[1].req_data.addr   = in_switch_to_tmem[b].req_data.addr;
        assign bank_port_if[1].req_data.data   = in_switch_to_tmem[b].req_data.data;
        assign bank_port_if[1].req_data.byteen = in_switch_to_tmem[b].req_data.byteen;
        assign bank_port_if[1].req_data.flags  = in_switch_to_tmem[b].req_data.flags;
        assign bank_port_if[1].req_data.tag    = in_switch_to_tmem[b].req_data.tag;
        assign in_switch_to_tmem[b].req_ready  = bank_port_if[1].req_ready;

        assign in_switch_to_tmem[b].rsp_valid     = bank_port_if[1].rsp_valid;
        assign in_switch_to_tmem[b].rsp_data.data = bank_port_if[1].rsp_data.data;
        assign in_switch_to_tmem[b].rsp_data.tag  = bank_port_if[1].rsp_data.tag;
        assign bank_port_if[1].rsp_ready          = in_switch_to_tmem[b].rsp_ready;

        // Port 2: weight switch
        assign bank_port_if[2].req_valid       = wt_switch_to_tmem[b].req_valid;
        assign bank_port_if[2].req_data.rw     = wt_switch_to_tmem[b].req_data.rw;
        assign bank_port_if[2].req_data.addr   = wt_switch_to_tmem[b].req_data.addr;
        assign bank_port_if[2].req_data.data   = wt_switch_to_tmem[b].req_data.data;
        assign bank_port_if[2].req_data.byteen = wt_switch_to_tmem[b].req_data.byteen;
        assign bank_port_if[2].req_data.flags  = wt_switch_to_tmem[b].req_data.flags;
        assign bank_port_if[2].req_data.tag    = wt_switch_to_tmem[b].req_data.tag;
        assign wt_switch_to_tmem[b].req_ready  = bank_port_if[2].req_ready;

        assign wt_switch_to_tmem[b].rsp_valid     = bank_port_if[2].rsp_valid;
        assign wt_switch_to_tmem[b].rsp_data.data = bank_port_if[2].rsp_data.data;
        assign wt_switch_to_tmem[b].rsp_data.tag  = bank_port_if[2].rsp_data.tag;
        assign bank_port_if[2].rsp_ready          = wt_switch_to_tmem[b].rsp_ready;

        // Port 3: scale_zp switch
        assign bank_port_if[3].req_valid       = sz_switch_to_tmem[b].req_valid;
        assign bank_port_if[3].req_data.rw     = sz_switch_to_tmem[b].req_data.rw;
        assign bank_port_if[3].req_data.addr   = sz_switch_to_tmem[b].req_data.addr;
        assign bank_port_if[3].req_data.data   = sz_switch_to_tmem[b].req_data.data;
        assign bank_port_if[3].req_data.byteen = sz_switch_to_tmem[b].req_data.byteen;
        assign bank_port_if[3].req_data.flags  = sz_switch_to_tmem[b].req_data.flags;
        assign bank_port_if[3].req_data.tag    = sz_switch_to_tmem[b].req_data.tag;
        assign sz_switch_to_tmem[b].req_ready  = bank_port_if[3].req_ready;

        assign sz_switch_to_tmem[b].rsp_valid     = bank_port_if[3].rsp_valid;
        assign sz_switch_to_tmem[b].rsp_data.data = bank_port_if[3].rsp_data.data;
        assign sz_switch_to_tmem[b].rsp_data.tag  = bank_port_if[3].rsp_data.tag;
        assign bank_port_if[3].rsp_ready          = sz_switch_to_tmem[b].rsp_ready;

        // Port 4: output switch
        assign bank_port_if[4].req_valid        = out_switch_to_tmem[b].req_valid;
        assign bank_port_if[4].req_data.rw      = out_switch_to_tmem[b].req_data.rw;
        assign bank_port_if[4].req_data.addr    = out_switch_to_tmem[b].req_data.addr;
        assign bank_port_if[4].req_data.data    = out_switch_to_tmem[b].req_data.data;
        assign bank_port_if[4].req_data.byteen  = out_switch_to_tmem[b].req_data.byteen;
        assign bank_port_if[4].req_data.flags   = out_switch_to_tmem[b].req_data.flags;
        assign bank_port_if[4].req_data.tag     = out_switch_to_tmem[b].req_data.tag;
        assign out_switch_to_tmem[b].req_ready  = bank_port_if[4].req_ready;

        assign out_switch_to_tmem[b].rsp_valid     = bank_port_if[4].rsp_valid;
        assign out_switch_to_tmem[b].rsp_data.data = bank_port_if[4].rsp_data.data;
        assign out_switch_to_tmem[b].rsp_data.tag  = bank_port_if[4].rsp_data.tag;
        assign bank_port_if[4].rsp_ready           = out_switch_to_tmem[b].rsp_ready;

        VX_tensor_mem_bank #(
            .INSTANCE_ID ({INSTANCE_ID, ":bank"}),
            .SIZE        (BANK_SIZE),
            .DATA_SIZE   (DATA_SIZE),
            .NUM_PORTS   (NUM_TMEM_PORTS),
            .TAG_WIDTH   (SWITCH_TAG_WIDTH)
        ) u_bank (
            .clk        (clk),
            .reset      (reset),
            .mem_bus_if (bank_port_if)
        );

    end // g_bank

    // ================================================================
    // 5. Local DMAs x4
    // ================================================================
    // [0] input:   LMEM->GEMM (DIR=0)
    // [1] weight:  LMEM->GEMM (DIR=0)
    // [2] sz:      LMEM->GEMM (DIR=0)
    // [3] output:  GEMM->LMEM (DIR=1)

`ifdef PERF_ENABLE
    dma_perf_t ldma_perf [4];
`endif

    // Input local DMA
    VX_lmem_dma_misal #(
        .INSTANCE_ID ({INSTANCE_ID, ":ldma_in"}),
        .DIR         (0),
        .TAG_WIDTH   (TAG_WIDTH),
        .LMEM_ADDR_WIDTH_P(`MEM_ADDR_WIDTH - `CLOG2(DATA_SIZE)),
        .GEMM_ADDR_WIDTH_P(`MEM_ADDR_WIDTH - `CLOG2(GEMM_DATA_SIZE)),
        .LMEM_TAG_WIDTH_P(TAG_WIDTH),
        .GEMM_TAG_WIDTH_P(TAG_WIDTH),
        .RD_PREFETCH_DEPTH(I_RD_PREFETCH_DEPTH)
    ) u_ldma_input (
        .clk         (clk),
        .reset       (reset),
        .ctrl_if     (ldma_ctrl_if[0]),
        .gemm_sync_if(ldma_sync_if[0]),
        .lmem_bus_if (ldma_to_switch[0]),
        .gemm_bus_if (ldma_gemm[0])
    `ifdef PERF_ENABLE
        ,.perf       (ldma_perf[0])
    `endif
    );

    // Weight local DMA
`ifdef WLOAD_AT_ONCE
    VX_lmem_dma_misal #(
        .INSTANCE_ID ({INSTANCE_ID, ":ldma_wt"}),
        .DIR         (0),
        .TAG_WIDTH   (TAG_WIDTH),
        .LMEM_ADDR_WIDTH_P(`MEM_ADDR_WIDTH - `CLOG2(GEMM_WEIGHT_DATA_SIZE)),
        .GEMM_ADDR_WIDTH_P(`MEM_ADDR_WIDTH - `CLOG2(GEMM_WEIGHT_DATA_SIZE)),
        .LMEM_TAG_WIDTH_P(TAG_WIDTH),
        .GEMM_TAG_WIDTH_P(TAG_WIDTH),
        .RD_PREFETCH_DEPTH(W_RD_PREFETCH_DEPTH)
    ) u_ldma_weight (
        .clk         (clk),
        .reset       (reset),
        .ctrl_if     (ldma_ctrl_if[1]),
        .gemm_sync_if(ldma_sync_if[1]),
        .lmem_bus_if (ldma_weight_to_tmem),
        .gemm_bus_if (ldma_gemm_weight)
    `ifdef PERF_ENABLE
        ,.perf       (ldma_perf[1])
    `endif
    );

    `INIT_VX_MEM_BUS_IF (ldma_to_switch[1])
`else
    VX_lmem_dma_misal #(
        .INSTANCE_ID ({INSTANCE_ID, ":ldma_wt"}),
        .DIR         (0),
        .TAG_WIDTH   (TAG_WIDTH),
        .LMEM_ADDR_WIDTH_P(`MEM_ADDR_WIDTH - `CLOG2(DATA_SIZE)),
        .GEMM_ADDR_WIDTH_P(`MEM_ADDR_WIDTH - `CLOG2(GEMM_DATA_SIZE)),
        .LMEM_TAG_WIDTH_P(TAG_WIDTH),
        .GEMM_TAG_WIDTH_P(TAG_WIDTH),
        .RD_PREFETCH_DEPTH(W_RD_PREFETCH_DEPTH)
    ) u_ldma_weight (
        .clk         (clk),
        .reset       (reset),
        .ctrl_if     (ldma_ctrl_if[1]),
        .gemm_sync_if(ldma_sync_if[1]),
        .lmem_bus_if (ldma_to_switch[1]),
        .gemm_bus_if (ldma_gemm[1])
    `ifdef PERF_ENABLE
        ,.perf       (ldma_perf[1])
    `endif
    );
`endif

    // Scale/zero-point local DMA
    VX_lmem_dma_misal #(
        .INSTANCE_ID ({INSTANCE_ID, ":ldma_sz"}),
        .DIR         (0),
        .TAG_WIDTH   (TAG_WIDTH),
        .LMEM_ADDR_WIDTH_P(`MEM_ADDR_WIDTH - `CLOG2(DATA_SIZE)),
        .GEMM_ADDR_WIDTH_P(`MEM_ADDR_WIDTH - `CLOG2(GEMM_DATA_SIZE)),
        .LMEM_TAG_WIDTH_P(TAG_WIDTH),
        .GEMM_TAG_WIDTH_P(TAG_WIDTH),
        .RD_PREFETCH_DEPTH(SZ_RD_PREFETCH_DEPTH)
    ) u_ldma_sz (
        .clk         (clk),
        .reset       (reset),
        .ctrl_if     (ldma_ctrl_if[2]),
        .gemm_sync_if(ldma_sync_if[2]),
        .lmem_bus_if (ldma_to_switch[2]),
        .gemm_bus_if (ldma_gemm[2])
    `ifdef PERF_ENABLE
        ,.perf       (ldma_perf[2])
    `endif
    );

    // Output local DMA (GEMM -> LMEM)
    VX_lmem_dma_misal #(
        .INSTANCE_ID ({INSTANCE_ID, ":ldma_out"}),
        .DIR         (1),
        .TAG_WIDTH   (TAG_WIDTH),
        .LMEM_ADDR_WIDTH_P(`MEM_ADDR_WIDTH - `CLOG2(DATA_SIZE)),
        .GEMM_ADDR_WIDTH_P(`MEM_ADDR_WIDTH - `CLOG2(GEMM_DATA_SIZE)),
        .LMEM_TAG_WIDTH_P(TAG_WIDTH),
        .GEMM_TAG_WIDTH_P(TAG_WIDTH),
        .RD_PREFETCH_DEPTH(O_RD_PREFETCH_DEPTH)
    ) u_ldma_output (
        .clk         (clk),
        .reset       (reset),
        .ctrl_if     (ldma_ctrl_if[3]),
        .gemm_sync_if(ldma_sync_if[3]),
        .lmem_bus_if (ldma_to_switch[3]),
        .gemm_bus_if (ldma_gemm[3])
    `ifdef PERF_ENABLE
        ,.perf       (ldma_perf[3])
    `endif
    );

    // ================================================================
    // 6. Connect local DMA GEMM ports to top-level GEMM interfaces
    // ================================================================

    // Input: ldma_gemm[0] is master -> gemm_input_if is master
    // The local DMA (DIR=0) reads from LMEM and writes to GEMM.
    // ldma_gemm[0] acts as master on both ports.
    // gemm_input_if is master (output from subsystem to GEMM unit).
    // We need to forward ldma's gemm_bus_if requests/responses to the top-level port.

    // For DIR=0 (LMEM->GEMM): the local DMA issues read requests on lmem_bus_if
    // and write requests on gemm_bus_if (both as master).
    // gemm_input_if is a master port of this subsystem, meaning the GEMM unit
    // is on the slave side. The local DMA drives gemm_bus_if as master.
    // We directly connect.

    assign gemm_input_if.req_valid       = ldma_gemm[0].req_valid;
    assign gemm_input_if.req_data        = ldma_gemm[0].req_data;
    assign ldma_gemm[0].req_ready        = gemm_input_if.req_ready;
    assign ldma_gemm[0].rsp_valid        = gemm_input_if.rsp_valid;
    assign ldma_gemm[0].rsp_data         = gemm_input_if.rsp_data;
    assign gemm_input_if.rsp_ready       = ldma_gemm[0].rsp_ready;

`ifdef WLOAD_AT_ONCE
    assign gemm_weight_if.req_valid      = ldma_gemm_weight.req_valid;
    assign gemm_weight_if.req_data       = ldma_gemm_weight.req_data;
    assign ldma_gemm_weight.req_ready    = gemm_weight_if.req_ready;
    assign ldma_gemm_weight.rsp_valid    = gemm_weight_if.rsp_valid;
    assign ldma_gemm_weight.rsp_data     = gemm_weight_if.rsp_data;
    assign gemm_weight_if.rsp_ready      = ldma_gemm_weight.rsp_ready;
`else
    assign gemm_weight_if.req_valid      = ldma_gemm[1].req_valid;
    assign gemm_weight_if.req_data       = ldma_gemm[1].req_data;
    assign ldma_gemm[1].req_ready        = gemm_weight_if.req_ready;
    assign ldma_gemm[1].rsp_valid        = gemm_weight_if.rsp_valid;
    assign ldma_gemm[1].rsp_data         = gemm_weight_if.rsp_data;
    assign gemm_weight_if.rsp_ready      = ldma_gemm[1].rsp_ready;
`endif

    assign gemm_sz_if.req_valid          = ldma_gemm[2].req_valid;
    assign gemm_sz_if.req_data           = ldma_gemm[2].req_data;
    assign ldma_gemm[2].req_ready        = gemm_sz_if.req_ready;
    assign ldma_gemm[2].rsp_valid        = gemm_sz_if.rsp_valid;
    assign ldma_gemm[2].rsp_data         = gemm_sz_if.rsp_data;
    assign gemm_sz_if.rsp_ready          = ldma_gemm[2].rsp_ready;

    // Output: DIR=1 (GEMM->LMEM) - local DMA reads from GEMM unit output buffer
    // gemm_output_if is master (subsystem issues read requests to GEMM unit)
    assign gemm_output_if.req_valid      = ldma_gemm[3].req_valid;
    assign gemm_output_if.req_data       = ldma_gemm[3].req_data;
    assign ldma_gemm[3].req_ready        = gemm_output_if.req_ready;
    assign ldma_gemm[3].rsp_valid        = gemm_output_if.rsp_valid;
    assign ldma_gemm[3].rsp_data         = gemm_output_if.rsp_data;
    assign gemm_output_if.rsp_ready      = ldma_gemm[3].rsp_ready;

    // ================================================================
    // 7. Local DMA performance — expose each instance directly
    //    (aggregation moved to runtime/stub/utils.cpp).
    // ================================================================
`ifdef PERF_ENABLE
    assign lmem_dma_input_perf  = ldma_perf[0];
    assign lmem_dma_weight_perf = ldma_perf[1];
    assign lmem_dma_sz_perf     = ldma_perf[2];
    assign lmem_dma_output_perf = ldma_perf[3];
`endif

`ifdef DBG_TRACE_MEM
    always @(posedge clk) begin
        if (ldma_to_switch[0].req_valid && ldma_to_switch[0].req_ready) begin
            `TRACE(1, ("%t: %s ldma_in req: addr=0x%0h, rw=%0b\n",
                $time, INSTANCE_ID, ldma_to_switch[0].req_data.addr,
                ldma_to_switch[0].req_data.rw))
        end
    `ifdef WLOAD_AT_ONCE
        if (ldma_weight_to_tmem.req_valid && ldma_weight_to_tmem.req_ready) begin
            `TRACE(1, ("%t: %s ldma_wt_wide req: addr=0x%0h, rw=%0b\n",
                $time, INSTANCE_ID, ldma_weight_to_tmem.req_data.addr,
                ldma_weight_to_tmem.req_data.rw))
        end
        if (ldma_weight_to_tmem.rsp_valid && ldma_weight_to_tmem.rsp_ready) begin
            `TRACE(1, ("%t: %s ldma_wt_wide rsp: tag=0x%0h\n",
                $time, INSTANCE_ID, ldma_weight_to_tmem.rsp_data.tag))
        end
        if (ldma_gemm_weight.req_valid && ldma_gemm_weight.req_ready) begin
            `TRACE(1, ("%t: %s ldma_wt_gemm req: addr=0x%0h, rw=%0b\n",
                $time, INSTANCE_ID, ldma_gemm_weight.req_data.addr,
                ldma_gemm_weight.req_data.rw))
        end
    `else
        if (ldma_to_switch[1].req_valid && ldma_to_switch[1].req_ready) begin
            `TRACE(1, ("%t: %s ldma_wt req: addr=0x%0h, rw=%0b\n",
                $time, INSTANCE_ID, ldma_to_switch[1].req_data.addr,
                ldma_to_switch[1].req_data.rw))
        end
    `endif
        if (ldma_to_switch[2].req_valid && ldma_to_switch[2].req_ready) begin
            `TRACE(1, ("%t: %s ldma_sz req: addr=0x%0h, rw=%0b\n",
                $time, INSTANCE_ID, ldma_to_switch[2].req_data.addr,
                ldma_to_switch[2].req_data.rw))
        end
        if (ldma_to_switch[3].req_valid && ldma_to_switch[3].req_ready) begin
            `TRACE(1, ("%t: %s ldma_out req: addr=0x%0h, rw=%0b\n",
                $time, INSTANCE_ID, ldma_to_switch[3].req_data.addr,
                ldma_to_switch[3].req_data.rw))
        end
    end
`endif

endmodule

module VX_tmem_wide_read_switch import VX_gpu_pkg::*; #(
    parameter `STRING INSTANCE_ID = "",
    parameter NUM_BANKS      = 8,
    parameter DATA_SIZE      = 64,
    parameter WIDE_DATA_SIZE = NUM_BANKS * DATA_SIZE,
    parameter TAG_WIDTH      = 8,
    parameter MEM_ADDR_WIDTH = `MEM_ADDR_WIDTH
) (
    input wire clk,
    input wire reset,

    // Wide input from weight local DMA.
    VX_mem_bus_if.slave     bus_in_if,

    // Narrow per-bank outputs to TMEM banks.
    VX_mem_bus_if.master    bus_out_if [NUM_BANKS]
);

    localparam BANK_SEL_BITS    = `CLOG2(NUM_BANKS);
    localparam DATA_WIDTH       = DATA_SIZE * 8;
    localparam WIDE_DATA_WIDTH  = WIDE_DATA_SIZE * 8;
    localparam IN_ADDR_WIDTH    = MEM_ADDR_WIDTH - `CLOG2(WIDE_DATA_SIZE);
    localparam OUT_ADDR_WIDTH   = MEM_ADDR_WIDTH - `CLOG2(DATA_SIZE);
    localparam OUT_TAG_WIDTH    = TAG_WIDTH + BANK_SEL_BITS;

    `UNUSED_SPARAM (INSTANCE_ID)
    `UNUSED_PARAM (MEM_ADDR_WIDTH)

    initial begin
        if (WIDE_DATA_SIZE != (NUM_BANKS * DATA_SIZE)) begin
            $fatal(1, "VX_tmem_wide_read_switch requires WIDE_DATA_SIZE (%0d) == NUM_BANKS*DATA_SIZE (%0d)",
                   WIDE_DATA_SIZE, NUM_BANKS * DATA_SIZE);
        end
    end

    typedef struct packed {
        logic [`UP(UUID_WIDTH)-1:0]             uuid;
        logic [TAG_WIDTH-`UP(UUID_WIDTH)-1:0]   value;
    } in_tag_t;

    typedef struct packed {
        logic                         rw;
        logic [IN_ADDR_WIDTH-1:0]     addr;
        logic [WIDE_DATA_WIDTH-1:0]   data;
        logic [WIDE_DATA_SIZE-1:0]    byteen;
        logic [MEM_FLAGS_WIDTH-1:0]   flags;
        in_tag_t                      tag;
    } wide_req_data_t;

    logic [NUM_BANKS-1:0]                  req_issued_r;
    logic                                  req_pending_r;
    logic                                  req_is_read_r;
    wide_req_data_t                        req_data_r;

    logic [NUM_BANKS-1:0]                  rsp_seen_r;
    logic [NUM_BANKS-1:0][DATA_WIDTH-1:0]  rsp_data_r;
    logic [TAG_WIDTH-1:0]                  rsp_tag_r;
    logic                                  rsp_active_r;
    logic                                  rsp_valid_r;

    wire [NUM_BANKS-1:0] req_ready_bank;
    wire [NUM_BANKS-1:0] req_fire_bank;
    wire [NUM_BANKS-1:0] rsp_fire_bank;
    wire [NUM_BANKS-1:0][DATA_WIDTH-1:0] rsp_data_bank;
    wire                 can_accept = !req_pending_r && !rsp_active_r && !rsp_valid_r;
    wire                 req_accept = bus_in_if.req_valid && bus_in_if.req_ready;
    wire [NUM_BANKS-1:0] req_issued_next = req_issued_r | req_fire_bank;
    wire                 req_issue_done = req_pending_r && (&req_issued_next);
    wire [NUM_BANKS-1:0] rsp_seen_next = rsp_seen_r | rsp_fire_bank;
    wire                 rsp_complete = rsp_active_r && (&rsp_seen_next);

    assign bus_in_if.req_ready = can_accept;

    for (genvar b = 0; b < NUM_BANKS; ++b) begin : g_bank_req
        assign req_ready_bank[b] = bus_out_if[b].req_ready;
        assign req_fire_bank[b] = bus_out_if[b].req_valid && bus_out_if[b].req_ready;
        assign rsp_fire_bank[b] = bus_out_if[b].rsp_valid && bus_out_if[b].rsp_ready;
        assign rsp_data_bank[b] = bus_out_if[b].rsp_data.data;

        assign bus_out_if[b].req_valid       = req_pending_r && !req_issued_r[b];
        assign bus_out_if[b].req_data.rw     = req_data_r.rw;
        // A 512B-aligned wide address is the same value as each bank-local
        // 64B address after the normal interleaved bank-select bits are stripped.
        assign bus_out_if[b].req_data.addr   = OUT_ADDR_WIDTH'(req_data_r.addr);
        assign bus_out_if[b].req_data.data   = req_data_r.data[b*DATA_WIDTH +: DATA_WIDTH];
        assign bus_out_if[b].req_data.byteen = req_data_r.byteen[b*DATA_SIZE +: DATA_SIZE];
        assign bus_out_if[b].req_data.flags  = req_data_r.flags;
        assign bus_out_if[b].req_data.tag    = OUT_TAG_WIDTH'({BANK_SEL_BITS'(b), req_data_r.tag});

        assign bus_out_if[b].rsp_ready = rsp_active_r && !rsp_seen_r[b] && !rsp_valid_r;
    end

    assign bus_in_if.rsp_valid     = rsp_valid_r;
    assign bus_in_if.rsp_data.tag  = rsp_tag_r;

    for (genvar b = 0; b < NUM_BANKS; ++b) begin : g_rsp_pack
        assign bus_in_if.rsp_data.data[b*DATA_WIDTH +: DATA_WIDTH] = rsp_data_r[b];
    end

    always_ff @(posedge clk) begin
        if (reset) begin
            req_issued_r <= '0;
            req_pending_r <= 1'b0;
            req_is_read_r <= 1'b0;
            req_data_r    <= '0;
            rsp_seen_r   <= '0;
            rsp_data_r   <= '0;
            rsp_tag_r    <= '0;
            rsp_active_r <= 1'b0;
            rsp_valid_r  <= 1'b0;
        end else begin
            if (req_accept) begin
                req_issued_r  <= '0;
                req_pending_r <= 1'b1;
                req_is_read_r <= !bus_in_if.req_data.rw;
                req_data_r    <= bus_in_if.req_data;
            end else begin
                req_issued_r <= req_issued_next;
            end

            if (req_issue_done) begin
                req_issued_r  <= '0;
                req_pending_r <= 1'b0;
                rsp_seen_r   <= '0;
                rsp_tag_r    <= {req_data_r.tag.uuid, req_data_r.tag.value};
                rsp_active_r <= req_is_read_r;
            end

            for (int b = 0; b < NUM_BANKS; ++b) begin
                if (rsp_fire_bank[b]) begin
                    rsp_seen_r[b] <= 1'b1;
                    rsp_data_r[b] <= rsp_data_bank[b];
                end
            end

            if (rsp_complete) begin
                rsp_seen_r   <= '0;
                rsp_active_r <= 1'b0;
                rsp_valid_r  <= 1'b1;
            end else if (bus_in_if.rsp_valid && bus_in_if.rsp_ready) begin
                rsp_valid_r <= 1'b0;
            end
        end
    end

`ifdef DBG_TRACE_MEM
    always @(posedge clk) begin
        if (bus_in_if.req_valid && bus_in_if.req_ready) begin
            `TRACE(1, ("%t: %s wide accept: addr=0x%0h, rw=%0b\n",
                $time, INSTANCE_ID, bus_in_if.req_data.addr,
                bus_in_if.req_data.rw))
        end
        if (|req_fire_bank) begin
            `TRACE(1, ("%t: %s wide bank_req: fired=0x%0h, ready=0x%0h, issued=0x%0h\n",
                $time, INSTANCE_ID, req_fire_bank, req_ready_bank, req_issued_next))
        end
        if (bus_in_if.rsp_valid && bus_in_if.rsp_ready) begin
            `TRACE(1, ("%t: %s wide rsp: tag=0x%0h\n",
                $time, INSTANCE_ID, bus_in_if.rsp_data.tag))
        end
    end

    for (genvar b = 0; b < NUM_BANKS; ++b) begin : g_bank_rsp_trace
        always @(posedge clk) begin
            if (bus_out_if[b].rsp_valid && bus_out_if[b].rsp_ready) begin
                `TRACE(1, ("%t: %s wide bank_rsp[%0d]: tag=0x%0h\n",
                    $time, INSTANCE_ID, b, bus_out_if[b].rsp_data.tag))
            end
        end
    end
`endif

endmodule
