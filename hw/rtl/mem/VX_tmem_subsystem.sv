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
//  - VX_tensor_mem_bank:   8 TMEM banks with 6-port arbitration each
//  - VX_tmem_switch:       Address-based 1:N bank routing (x5)
//  - Local DMA executors:  resource-specific TMEM <-> GEMM movement
//
//  Data flow:
//    HBM <-> DMA engine <-> TMEM banks <-> switches <-> local DMAs <-> GEMM unit

module VX_tmem_subsystem import VX_gpu_pkg::*; #(
    parameter `STRING INSTANCE_ID = "",
    parameter NUM_BANKS         = 8,
    parameter NUM_DMA_CHANNELS  = NUM_BANKS,
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
    parameter int LDMA_CMD_FIFO_DEPTH = `LMEM_DMA_CMD_FIFO_DEPTH,
    parameter int I_RD_OUTSTANDING = `I_LMEM_DMA_RD_OUTSTANDING_SLOTS,
    parameter int W_CMD_BEATS = `W_LMEM_DMA_CMD_BEATS,
    parameter int W_RD_OUTSTANDING = `W_LMEM_DMA_RESPONSE_SLOTS,
    parameter int SZ_RD_OUTSTANDING = `SZ_LMEM_DMA_RD_OUTSTANDING_SLOTS,
    parameter int O_RD_OUTSTANDING = `O_LMEM_DMA_RD_OUTSTANDING_SLOTS,
    parameter int DMA_RD_OUTSTANDING = `TMEM_DMA_RD_OUTSTANDING_SLOT,
    parameter bit TMEM_ARB_URGENCY_ENABLE = `TMEM_ARB_URGENCY_ENABLE,
    parameter int INPUT_READY_AHEAD_LOW_WATERMARK =
        `I_LMEM_DMA_READY_AHEAD_LOW_WATERMARK,
    parameter int WEIGHT_READY_AHEAD_LOW_WATERMARK =
        `W_LMEM_DMA_READY_AHEAD_LOW_WATERMARK,
    parameter int TMEM_ARB_MAX_CONSECUTIVE_URGENT =
        `TMEM_ARB_MAX_CONSECUTIVE_URGENT
) (
    input wire clk,
    input wire reset,

    // DMA config (from gemm_dma_ctrl, 8 channels for DMA engine)
    VX_config_reg_if.slave  dma_cfg_if [NUM_DMA_CHANNELS],
    VX_dma_lookahead_if.slave dma_lookahead_if [NUM_DMA_CHANNELS],
    VX_node_done_if.master  dma_done_if [NUM_DMA_CHANNELS],

    // Local DMA control (input/weight/scale/zero-point/output)
    VX_lmem_dma_ctrl_if.slave ldma_ctrl_if [5],

    // Weight destination-commit fence.  The descriptor-associated wait is
    // sampled when ldma_ctrl_if[1].start is accepted; the two consume levels
    // are the controller's same-cycle authoritative dependency view.
    input gemm_wait_meta_t weight_writer_wait_i,
    input wire [31:0] weight_consume_value0_i,
    input wire [31:0] weight_consume_value1_i,
    input gemm_wait_meta_t scale_writer_wait_i,
    input wire [31:0] scale_consume_value0_i,
    input wire [31:0] scale_consume_value1_i,
    input gemm_wait_meta_t zero_point_writer_wait_i,
    input wire [31:0] zero_point_consume_value0_i,
    input wire [31:0] zero_point_consume_value1_i,

    input wire [GEMM_SCHED_PRIORITY_WIDTH-1:0]
        sched_source_priority_i [4],
    input wire sched_input_source_enable_i,
    output wire [3:0] sched_source_valid_o,
    output wire [31:0] sched_source_work_seq_o [4],
    output wire [31:0] sched_source_total_beats_o [4],
    output wire [31:0] sched_source_request_beats_o [4],
    output wire [31:0] sched_source_response_beats_o [4],
    output wire [31:0] sched_source_writer_beats_o [4],
    output wire [3:0] sched_input_slot_occupancy_o,
    output wire [3:0] sched_fetch_complete_o,
    output wire [31:0] sched_fetch_complete_work_seq_o [4],

    // HBM side: AXI master ports (pass through to DMA engine)
    AXI_BUS.Master axi_m [NUM_DMA_CHANNELS],

    // GEMM unit side memory bus interfaces
    VX_mem_bus_if.master gemm_input_if,
    VX_mem_bus_if.master gemm_weight_if,
    VX_mem_bus_if.master gemm_scale_if,
    VX_mem_bus_if.master gemm_zp_if,
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
    localparam NUM_TMEM_PORTS   = 6;
    localparam NUM_LDMA         = 5;
    localparam BANK_SEL_BITS    = `CLOG2(NUM_BANKS);
    localparam DMA_BANKS_PER_CHANNEL = NUM_BANKS / NUM_DMA_CHANNELS;
    localparam DMA_BANK_SEL_BITS = `CLOG2(DMA_BANKS_PER_CHANNEL);
    localparam DMA_SWITCH_TAG_WIDTH = TAG_WIDTH + DMA_BANK_SEL_BITS;
    localparam WEIGHT_BANKS_PER_BEAT = GEMM_WEIGHT_DATA_SIZE / DATA_SIZE;
    // Switch appends BANK_SEL_BITS to tag, and TMEM bank arbiter appends
    // its own selector bits. The TMEM bank sees:
    //   TAG_WIDTH (original) + BANK_SEL_BITS (from switch)
    localparam SWITCH_TAG_WIDTH = TAG_WIDTH + BANK_SEL_BITS;

    `UNUSED_SPARAM (INSTANCE_ID)
    `UNUSED_PARAM (AXI_USER_WIDTH)
    `UNUSED_PARAM (I_RD_PREFETCH_DEPTH)
    `UNUSED_PARAM (W_RD_PREFETCH_DEPTH)
    `UNUSED_PARAM (SZ_RD_PREFETCH_DEPTH)

    initial begin
        if ((NUM_BANKS < 1) || ((NUM_BANKS & (NUM_BANKS - 1)) != 0))
            $fatal(1, "%s: NUM_BANKS(%0d) must be a positive power of two",
                   INSTANCE_ID, NUM_BANKS);
        if ((NUM_DMA_CHANNELS < 1)
         || ((NUM_DMA_CHANNELS & (NUM_DMA_CHANNELS - 1)) != 0))
            $fatal(1, "%s: NUM_DMA_CHANNELS(%0d) must be a positive power of two",
                   INSTANCE_ID, NUM_DMA_CHANNELS);
        if (NUM_DMA_CHANNELS > NUM_BANKS)
            $fatal(1, "%s: NUM_DMA_CHANNELS(%0d) must not exceed NUM_BANKS(%0d)",
                   INSTANCE_ID, NUM_DMA_CHANNELS, NUM_BANKS);
        if ((`MXU_WLOAD_NUM < 1) || ((`MXU_ROW % `MXU_WLOAD_NUM) != 0))
            $fatal(1, "%s: MXU_WLOAD_NUM(%0d) must be positive and divide MXU_ROW(%0d)",
                   INSTANCE_ID, `MXU_WLOAD_NUM, `MXU_ROW);
        if ((W_CMD_BEATS < 1)
         || ((`MXU_WLOAD_NUM * W_CMD_BEATS) != `MXU_ROW))
            $fatal(1, "%s: MXU_WLOAD_NUM(%0d) * W_CMD_BEATS(%0d) must equal MXU_ROW(%0d)",
                   INSTANCE_ID, `MXU_WLOAD_NUM, W_CMD_BEATS, `MXU_ROW);
        if ((WEIGHT_BANKS_PER_BEAT < 1)
         || ((NUM_BANKS % WEIGHT_BANKS_PER_BEAT) != 0))
            $fatal(1, "%s: invalid Weight bank grouping NUM_BANKS(%0d), WEIGHT_BANKS_PER_BEAT(%0d)",
                   INSTANCE_ID, NUM_BANKS, WEIGHT_BANKS_PER_BEAT);
        if ((LDMA_CMD_FIFO_DEPTH != 2) && (LDMA_CMD_FIFO_DEPTH != 4))
            $fatal(1, "%s: LDMA command FIFO depth(%0d) must be 2 or 4",
                   INSTANCE_ID, LDMA_CMD_FIFO_DEPTH);
        if ((W_RD_OUTSTANDING < 1)
         || ((W_RD_OUTSTANDING & (W_RD_OUTSTANDING - 1)) != 0))
            $fatal(1, "%s: Weight shared response slots(%0d) must be a positive power of two",
                   INSTANCE_ID, W_RD_OUTSTANDING);
        if ((INPUT_READY_AHEAD_LOW_WATERMARK < 1)
         || (INPUT_READY_AHEAD_LOW_WATERMARK > I_RD_OUTSTANDING))
            $fatal(1, "%s: invalid Input ready-ahead watermark %0d",
                   INSTANCE_ID, INPUT_READY_AHEAD_LOW_WATERMARK);
        if ((WEIGHT_READY_AHEAD_LOW_WATERMARK < 1)
         || (WEIGHT_READY_AHEAD_LOW_WATERMARK > W_RD_OUTSTANDING))
            $fatal(1, "%s: invalid Weight ready-ahead watermark %0d",
                   INSTANCE_ID, WEIGHT_READY_AHEAD_LOW_WATERMARK);
    end

    // ================================================================
    // 1. DMA Engine: 8-channel HBM(AXI) <-> TMEM(membus)
    // ================================================================

    VX_mem_bus_if #(
        .DATA_SIZE  (DATA_SIZE),
        .TAG_WIDTH  (TAG_WIDTH)
    ) dma_to_tmem [NUM_DMA_CHANNELS] ();

    // Restricted DMA-to-TMEM fabric.  The flat array is indexed by physical
    // TMEM bank; each element has exactly one static owner, bank%D.  The
    // per-channel demux below only creates wires to banks c+kD.
    VX_mem_bus_if #(
        .DATA_SIZE  (DATA_SIZE),
        .TAG_WIDTH  (SWITCH_TAG_WIDTH)
    ) dma_switch_to_tmem [NUM_BANKS] ();

    VX_dma_engine #(
        .INSTANCE_ID    ({INSTANCE_ID, ":dma"}),
        .NUM_CHANNELS   (NUM_DMA_CHANNELS),
        .NUM_HBM_PORTS  (`NUM_HBM_PORTS),
        .DATA_WIDTH     (DATA_WIDTH),
        .AXI_ADDR_WIDTH (AXI_ADDR_WIDTH),
        .AXI_DATA_WIDTH (AXI_DATA_WIDTH),
        .AXI_ID_WIDTH   (AXI_ID_WIDTH),
        .TAG_WIDTH      (TAG_WIDTH),
        .MAX_DIMS       (3),
        .ENABLE_PADDING (1'b0),
        .RD_OUTSTANDING (DMA_RD_OUTSTANDING)
    ) u_dma_engine (
        .clk            (clk),
        .reset          (reset),
        .cfg_reg_if     (dma_cfg_if),
        .lookahead_if   (dma_lookahead_if),
        .done_if        (dma_done_if),
        .axi_m          (axi_m),
        .tmem_bus_if    (dma_to_tmem)
    `ifdef PERF_ENABLE
        ,.perf          (hbm_dma_perf)
    `endif
    );

    // A DMA descriptor carries a D-channel-local word address.  When T>D,
    // its low log2(T/D) bits select an owned bank slot and the remaining bits
    // are the physical bank-local address.  T==D keeps the legacy direct wire.
    for (genvar c = 0; c < NUM_DMA_CHANNELS; ++c) begin : g_dma_tmem_route
        if (NUM_BANKS == NUM_DMA_CHANNELS) begin : g_direct
            localparam int BANK = c;

            assign dma_switch_to_tmem[BANK].req_valid = dma_to_tmem[c].req_valid;
            assign dma_switch_to_tmem[BANK].req_data.rw = dma_to_tmem[c].req_data.rw;
            assign dma_switch_to_tmem[BANK].req_data.addr = dma_to_tmem[c].req_data.addr;
            assign dma_switch_to_tmem[BANK].req_data.data = dma_to_tmem[c].req_data.data;
            assign dma_switch_to_tmem[BANK].req_data.byteen = dma_to_tmem[c].req_data.byteen;
            assign dma_switch_to_tmem[BANK].req_data.flags = dma_to_tmem[c].req_data.flags;
            assign dma_switch_to_tmem[BANK].req_data.tag =
                {{BANK_SEL_BITS{1'b0}}, dma_to_tmem[c].req_data.tag};
            assign dma_to_tmem[c].req_ready = dma_switch_to_tmem[BANK].req_ready;

            assign dma_to_tmem[c].rsp_valid = dma_switch_to_tmem[BANK].rsp_valid;
            assign dma_to_tmem[c].rsp_data.data = dma_switch_to_tmem[BANK].rsp_data.data;
            assign dma_to_tmem[c].rsp_data.tag =
                dma_switch_to_tmem[BANK].rsp_data.tag[TAG_WIDTH-1:0];
            assign dma_switch_to_tmem[BANK].rsp_ready = dma_to_tmem[c].rsp_ready;
        end else begin : g_interleaved
            VX_mem_bus_if #(
                .DATA_SIZE  (DATA_SIZE),
                .TAG_WIDTH  (DMA_SWITCH_TAG_WIDTH)
            ) owned_bank_if [DMA_BANKS_PER_CHANNEL] ();

            VX_tmem_switch #(
                .INSTANCE_ID ({INSTANCE_ID, ":dma_sw"}),
                .NUM_BANKS   (DMA_BANKS_PER_CHANNEL),
                .DATA_SIZE   (DATA_SIZE),
                .TAG_WIDTH   (TAG_WIDTH)
            ) u_dma_switch (
                .clk               (clk),
                .reset             (reset),
                .req_urgent_i      (1'b0),
                .req_priority_i    (GEMM_SCHED_PRIORITY_BACKGROUND),
                .bank_req_urgent_o (),
                .bank_req_priority_o(),
                .bus_in_if         (dma_to_tmem[c]),
                .bus_out_if        (owned_bank_if)
            );

            for (genvar k = 0; k < DMA_BANKS_PER_CHANNEL; ++k) begin : g_owned_bank
                localparam int BANK = c + k * NUM_DMA_CHANNELS;
                localparam int TAG_PAD = SWITCH_TAG_WIDTH - DMA_SWITCH_TAG_WIDTH;

                assign dma_switch_to_tmem[BANK].req_valid = owned_bank_if[k].req_valid;
                assign dma_switch_to_tmem[BANK].req_data.rw = owned_bank_if[k].req_data.rw;
                assign dma_switch_to_tmem[BANK].req_data.addr = owned_bank_if[k].req_data.addr;
                assign dma_switch_to_tmem[BANK].req_data.data = owned_bank_if[k].req_data.data;
                assign dma_switch_to_tmem[BANK].req_data.byteen = owned_bank_if[k].req_data.byteen;
                assign dma_switch_to_tmem[BANK].req_data.flags = owned_bank_if[k].req_data.flags;
                assign dma_switch_to_tmem[BANK].req_data.tag =
                    {{TAG_PAD{1'b0}}, owned_bank_if[k].req_data.tag};
                assign owned_bank_if[k].req_ready = dma_switch_to_tmem[BANK].req_ready;

                assign owned_bank_if[k].rsp_valid = dma_switch_to_tmem[BANK].rsp_valid;
                assign owned_bank_if[k].rsp_data.data = dma_switch_to_tmem[BANK].rsp_data.data;
                assign owned_bank_if[k].rsp_data.tag =
                    dma_switch_to_tmem[BANK].rsp_data.tag[DMA_SWITCH_TAG_WIDTH-1:0];
                assign dma_switch_to_tmem[BANK].rsp_ready = owned_bank_if[k].rsp_ready;
            end
        end
    end

    // ================================================================
    // 2. Local DMA -> Switch -> TMEM bank wiring
    // ================================================================
    // Each switch connects one local DMA to NUM_BANKS TMEM bank ports.
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
    ) sc_switch_to_tmem [NUM_BANKS] ();

    VX_mem_bus_if #(
        .DATA_SIZE  (DATA_SIZE),
        .TAG_WIDTH  (SWITCH_TAG_WIDTH)
    ) zp_switch_to_tmem [NUM_BANKS] ();

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

    VX_mem_bus_if #(
        .DATA_SIZE  (GEMM_WEIGHT_DATA_SIZE),
        .TAG_WIDTH  (TAG_WIDTH)
    ) ldma_weight_to_tmem ();

    // Read request reservations cut selected-TMEM-memory-array ready from
    // local-DMA response-slot allocation.  Responses remain a direct return
    // path through each reservation because their slots were allocated when
    // the corresponding request entered the reservation.
    VX_mem_bus_if #(
        .DATA_SIZE  (DATA_SIZE),
        .TAG_WIDTH  (TAG_WIDTH)
    ) input_reserved_to_switch ();

    VX_mem_bus_if #(
        .DATA_SIZE  (GEMM_WEIGHT_DATA_SIZE),
        .TAG_WIDTH  (TAG_WIDTH)
    ) weight_reserved_to_switch ();

    VX_mem_bus_if #(
        .DATA_SIZE  (DATA_SIZE),
        .TAG_WIDTH  (TAG_WIDTH)
    ) scale_reserved_to_switch ();

    VX_mem_bus_if #(
        .DATA_SIZE  (DATA_SIZE),
        .TAG_WIDTH  (TAG_WIDTH)
    ) zero_point_reserved_to_switch ();

    // Weight transfers use their native GEMM beat width on both sides. The
    // wide TMEM switch fans each source read out to the required bank group.
    VX_mem_bus_if #(
        .DATA_SIZE  (GEMM_WEIGHT_DATA_SIZE),
        .TAG_WIDTH  (TAG_WIDTH)
    ) ldma_gemm_weight ();

    VX_gemm_sync_if ldma_sync_if [NUM_LDMA] ();

    wire input_req_urgent;
    wire weight_req_urgent;
    wire [GEMM_SCHED_PRIORITY_WIDTH-1:0] input_req_priority;
    wire [GEMM_SCHED_PRIORITY_WIDTH-1:0] weight_req_priority;
    wire [GEMM_SCHED_PRIORITY_WIDTH-1:0] scale_req_priority;
    wire [GEMM_SCHED_PRIORITY_WIDTH-1:0] zero_point_req_priority;
    wire input_reserved_req_urgent;
    wire weight_reserved_req_urgent;
    wire scale_reserved_req_urgent;
    wire zero_point_reserved_req_urgent;
    wire [GEMM_SCHED_PRIORITY_WIDTH-1:0] input_reserved_req_priority;
    wire [GEMM_SCHED_PRIORITY_WIDTH-1:0] weight_reserved_req_priority;
    wire [GEMM_SCHED_PRIORITY_WIDTH-1:0] scale_reserved_req_priority;
    wire [GEMM_SCHED_PRIORITY_WIDTH-1:0] zero_point_reserved_req_priority;
    wire [31:0] input_reserved_req_work_seq;
    wire [31:0] weight_reserved_req_work_seq;
    wire [31:0] scale_reserved_req_work_seq;
    wire [31:0] zero_point_reserved_req_work_seq;
    wire [NUM_BANKS-1:0] input_bank_req_urgent;
    wire [NUM_BANKS-1:0] weight_bank_req_urgent;
    wire [NUM_BANKS-1:0][GEMM_SCHED_PRIORITY_WIDTH-1:0]
        input_bank_req_priority;
    wire [NUM_BANKS-1:0][GEMM_SCHED_PRIORITY_WIDTH-1:0]
        weight_bank_req_priority;
    wire [NUM_BANKS-1:0][GEMM_SCHED_PRIORITY_WIDTH-1:0]
        scale_bank_req_priority;
    wire [NUM_BANKS-1:0][GEMM_SCHED_PRIORITY_WIDTH-1:0]
        zero_point_bank_req_priority;

    for (genvar i = 0; i < NUM_LDMA; ++i) begin : g_ldma_sync
        assign ldma_sync_if[i].ready = 1'b1;
    end

    VX_tmem_read_req_reservation #(
        .INSTANCE_ID ({INSTANCE_ID, ":input_req_reservation"}),
        .DATA_SIZE   (DATA_SIZE),
        .TAG_WIDTH   (TAG_WIDTH)
    ) u_input_req_reservation (
        .clk              (clk),
        .reset            (reset),
        .req_priority_i   (input_req_priority),
        .req_urgent_i     (input_req_urgent),
        .req_work_seq_i   (sched_source_work_seq_o[0]),
        .req_priority_o   (input_reserved_req_priority),
        .req_urgent_o     (input_reserved_req_urgent),
        .req_work_seq_o   (input_reserved_req_work_seq),
        .upstream_if      (ldma_to_switch[0]),
        .downstream_if    (input_reserved_to_switch)
    );

    VX_tmem_read_req_reservation #(
        .INSTANCE_ID ({INSTANCE_ID, ":weight_req_reservation"}),
        .DATA_SIZE   (GEMM_WEIGHT_DATA_SIZE),
        .TAG_WIDTH   (TAG_WIDTH)
    ) u_weight_req_reservation (
        .clk              (clk),
        .reset            (reset),
        .req_priority_i   (weight_req_priority),
        .req_urgent_i     (weight_req_urgent),
        .req_work_seq_i   (sched_source_work_seq_o[1]),
        .req_priority_o   (weight_reserved_req_priority),
        .req_urgent_o     (weight_reserved_req_urgent),
        .req_work_seq_o   (weight_reserved_req_work_seq),
        .upstream_if      (ldma_weight_to_tmem),
        .downstream_if    (weight_reserved_to_switch)
    );

    VX_tmem_read_req_reservation #(
        .INSTANCE_ID ({INSTANCE_ID, ":scale_req_reservation"}),
        .DATA_SIZE   (DATA_SIZE),
        .TAG_WIDTH   (TAG_WIDTH)
    ) u_scale_req_reservation (
        .clk              (clk),
        .reset            (reset),
        .req_priority_i   (scale_req_priority),
        .req_urgent_i     (1'b0),
        .req_work_seq_i   (sched_source_work_seq_o[2]),
        .req_priority_o   (scale_reserved_req_priority),
        .req_urgent_o     (scale_reserved_req_urgent),
        .req_work_seq_o   (scale_reserved_req_work_seq),
        .upstream_if      (ldma_to_switch[2]),
        .downstream_if    (scale_reserved_to_switch)
    );

    VX_tmem_read_req_reservation #(
        .INSTANCE_ID ({INSTANCE_ID, ":zero_point_req_reservation"}),
        .DATA_SIZE   (DATA_SIZE),
        .TAG_WIDTH   (TAG_WIDTH)
    ) u_zero_point_req_reservation (
        .clk              (clk),
        .reset            (reset),
        .req_priority_i   (zero_point_req_priority),
        .req_urgent_i     (1'b0),
        .req_work_seq_i   (sched_source_work_seq_o[3]),
        .req_priority_o   (zero_point_reserved_req_priority),
        .req_urgent_o     (zero_point_reserved_req_urgent),
        .req_work_seq_o   (zero_point_reserved_req_work_seq),
        .upstream_if      (ldma_to_switch[3]),
        .downstream_if    (zero_point_reserved_to_switch)
    );

    `UNUSED_VAR ({input_reserved_req_work_seq,
                  weight_reserved_req_work_seq,
                  scale_reserved_req_work_seq,
                  zero_point_reserved_req_work_seq})

    // ================================================================
    // 3. Switches: 1:N address-based bank routing (x5)
    // ================================================================

    VX_tmem_switch #(
        .INSTANCE_ID    ({INSTANCE_ID, ":sw_in"}),
        .NUM_BANKS      (NUM_BANKS),
        .DATA_SIZE      (DATA_SIZE),
        .TAG_WIDTH      (TAG_WIDTH)
    ) u_switch_input (
        .clk        (clk),
        .reset      (reset),
        .req_urgent_i(input_reserved_req_urgent),
        .req_priority_i(input_reserved_req_priority),
        .bank_req_urgent_o(input_bank_req_urgent),
        .bank_req_priority_o(input_bank_req_priority),
        .bus_in_if  (input_reserved_to_switch),
        .bus_out_if (in_switch_to_tmem)
    );

    VX_tmem_wide_read_switch #(
        .INSTANCE_ID    ({INSTANCE_ID, ":sw_wt_wide"}),
        .NUM_BANKS      (NUM_BANKS),
        .DATA_SIZE      (DATA_SIZE),
        .WIDE_DATA_SIZE (GEMM_WEIGHT_DATA_SIZE),
        .TAG_WIDTH      (TAG_WIDTH),
        .OUTSTANDING    (W_RD_OUTSTANDING)
    ) u_switch_weight (
        .clk        (clk),
        .reset      (reset),
        .req_urgent_i(weight_reserved_req_urgent),
        .req_priority_i(weight_reserved_req_priority),
        .bank_req_urgent_o(weight_bank_req_urgent),
        .bank_req_priority_o(weight_bank_req_priority),
        .bus_in_if  (weight_reserved_to_switch),
        .bus_out_if (wt_switch_to_tmem)
    );

    VX_tmem_switch #(
        .INSTANCE_ID    ({INSTANCE_ID, ":sw_sc"}),
        .NUM_BANKS      (NUM_BANKS),
        .DATA_SIZE      (DATA_SIZE),
        .TAG_WIDTH      (TAG_WIDTH)
    ) u_switch_scale (
        .clk        (clk),
        .reset      (reset),
        .req_urgent_i(scale_reserved_req_urgent),
        .req_priority_i(scale_reserved_req_priority),
        .bank_req_urgent_o(),
        .bank_req_priority_o(scale_bank_req_priority),
        .bus_in_if  (scale_reserved_to_switch),
        .bus_out_if (sc_switch_to_tmem)
    );

    VX_tmem_switch #(
        .INSTANCE_ID    ({INSTANCE_ID, ":sw_zp"}),
        .NUM_BANKS      (NUM_BANKS),
        .DATA_SIZE      (DATA_SIZE),
        .TAG_WIDTH      (TAG_WIDTH)
    ) u_switch_zero_point (
        .clk        (clk),
        .reset      (reset),
        .req_urgent_i(zero_point_reserved_req_urgent),
        .req_priority_i(zero_point_reserved_req_priority),
        .bank_req_urgent_o(),
        .bank_req_priority_o(zero_point_bank_req_priority),
        .bus_in_if  (zero_point_reserved_to_switch),
        .bus_out_if (zp_switch_to_tmem)
    );

    VX_tmem_switch #(
        .INSTANCE_ID    ({INSTANCE_ID, ":sw_out"}),
        .NUM_BANKS      (NUM_BANKS),
        .DATA_SIZE      (DATA_SIZE),
        .TAG_WIDTH      (TAG_WIDTH)
    ) u_switch_output (
        .clk        (clk),
        .reset      (reset),
        .req_urgent_i(1'b0),
        .req_priority_i(GEMM_SCHED_PRIORITY_BACKGROUND),
        .bank_req_urgent_o(),
        .bank_req_priority_o(),
        .bus_in_if  (ldma_to_switch[4]),
        .bus_out_if (out_switch_to_tmem)
    );

    // ================================================================
    // 4. TMEM Banks x NUM_BANKS
    // ================================================================
    // Each bank has 6 ports:
    //   port[0] = DMA direct (1:1)     (SWITCH_TAG_WIDTH)
    //   port[1] = input switch        (SWITCH_TAG_WIDTH)
    //   port[2] = weight switch       (SWITCH_TAG_WIDTH)
    //   port[3] = scale switch        (SWITCH_TAG_WIDTH)
    //   port[4] = zero-point switch   (SWITCH_TAG_WIDTH)
    //   port[5] = output switch       (SWITCH_TAG_WIDTH)
    //
    // All ports use SWITCH_TAG_WIDTH (the switch appends bank-select bits).

    for (genvar b = 0; b < NUM_BANKS; ++b) begin : g_bank

        // Create per-bank port array with uniform SWITCH_TAG_WIDTH
        VX_mem_bus_if #(
            .DATA_SIZE  (DATA_SIZE),
            .TAG_WIDTH  (SWITCH_TAG_WIDTH)
        ) bank_port_if [NUM_TMEM_PORTS] ();

        wire [NUM_TMEM_PORTS-1:0] bank_req_urgent;
        wire [NUM_TMEM_PORTS-1:0][GEMM_SCHED_PRIORITY_WIDTH-1:0]
            bank_req_priority;
        assign bank_req_urgent[0] = 1'b0;
        assign bank_req_urgent[1] = input_bank_req_urgent[b];
        assign bank_req_urgent[2] = weight_bank_req_urgent[b];
        assign bank_req_urgent[3] = 1'b0;
        assign bank_req_urgent[4] = 1'b0;
        assign bank_req_urgent[5] = 1'b0;
        assign bank_req_priority[0] = GEMM_SCHED_PRIORITY_BACKGROUND;
        assign bank_req_priority[1] = input_bank_req_priority[b];
        assign bank_req_priority[2] = weight_bank_req_priority[b];
        assign bank_req_priority[3] = scale_bank_req_priority[b];
        assign bank_req_priority[4] = zero_point_bank_req_priority[b];
        assign bank_req_priority[5] = GEMM_SCHED_PRIORITY_BACKGROUND;

        // Port 0: restricted DMA direct path.  Physical bank b is owned by
        // DMA channel b%NUM_DMA_CHANNELS; no cross-class path is elaborated.
        assign bank_port_if[0].req_valid       = dma_switch_to_tmem[b].req_valid;
        assign bank_port_if[0].req_data.rw     = dma_switch_to_tmem[b].req_data.rw;
        assign bank_port_if[0].req_data.addr   = dma_switch_to_tmem[b].req_data.addr;
        assign bank_port_if[0].req_data.data   = dma_switch_to_tmem[b].req_data.data;
        assign bank_port_if[0].req_data.byteen = dma_switch_to_tmem[b].req_data.byteen;
        assign bank_port_if[0].req_data.flags  = dma_switch_to_tmem[b].req_data.flags;
        assign bank_port_if[0].req_data.tag    = dma_switch_to_tmem[b].req_data.tag;
        assign dma_switch_to_tmem[b].req_ready = bank_port_if[0].req_ready;

        assign dma_switch_to_tmem[b].rsp_valid     = bank_port_if[0].rsp_valid;
        assign dma_switch_to_tmem[b].rsp_data.data = bank_port_if[0].rsp_data.data;
        assign dma_switch_to_tmem[b].rsp_data.tag  = bank_port_if[0].rsp_data.tag;
        assign bank_port_if[0].rsp_ready            = dma_switch_to_tmem[b].rsp_ready;

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

        // Port 3: scale switch
        assign bank_port_if[3].req_valid       = sc_switch_to_tmem[b].req_valid;
        assign bank_port_if[3].req_data.rw     = sc_switch_to_tmem[b].req_data.rw;
        assign bank_port_if[3].req_data.addr   = sc_switch_to_tmem[b].req_data.addr;
        assign bank_port_if[3].req_data.data   = sc_switch_to_tmem[b].req_data.data;
        assign bank_port_if[3].req_data.byteen = sc_switch_to_tmem[b].req_data.byteen;
        assign bank_port_if[3].req_data.flags  = sc_switch_to_tmem[b].req_data.flags;
        assign bank_port_if[3].req_data.tag    = sc_switch_to_tmem[b].req_data.tag;
        assign sc_switch_to_tmem[b].req_ready  = bank_port_if[3].req_ready;

        assign sc_switch_to_tmem[b].rsp_valid     = bank_port_if[3].rsp_valid;
        assign sc_switch_to_tmem[b].rsp_data.data = bank_port_if[3].rsp_data.data;
        assign sc_switch_to_tmem[b].rsp_data.tag  = bank_port_if[3].rsp_data.tag;
        assign bank_port_if[3].rsp_ready          = sc_switch_to_tmem[b].rsp_ready;

        // Port 4: zero-point switch
        assign bank_port_if[4].req_valid       = zp_switch_to_tmem[b].req_valid;
        assign bank_port_if[4].req_data.rw     = zp_switch_to_tmem[b].req_data.rw;
        assign bank_port_if[4].req_data.addr   = zp_switch_to_tmem[b].req_data.addr;
        assign bank_port_if[4].req_data.data   = zp_switch_to_tmem[b].req_data.data;
        assign bank_port_if[4].req_data.byteen = zp_switch_to_tmem[b].req_data.byteen;
        assign bank_port_if[4].req_data.flags  = zp_switch_to_tmem[b].req_data.flags;
        assign bank_port_if[4].req_data.tag    = zp_switch_to_tmem[b].req_data.tag;
        assign zp_switch_to_tmem[b].req_ready  = bank_port_if[4].req_ready;

        assign zp_switch_to_tmem[b].rsp_valid     = bank_port_if[4].rsp_valid;
        assign zp_switch_to_tmem[b].rsp_data.data = bank_port_if[4].rsp_data.data;
        assign zp_switch_to_tmem[b].rsp_data.tag  = bank_port_if[4].rsp_data.tag;
        assign bank_port_if[4].rsp_ready          = zp_switch_to_tmem[b].rsp_ready;

        // Port 5: output switch
        assign bank_port_if[5].req_valid        = out_switch_to_tmem[b].req_valid;
        assign bank_port_if[5].req_data.rw      = out_switch_to_tmem[b].req_data.rw;
        assign bank_port_if[5].req_data.addr    = out_switch_to_tmem[b].req_data.addr;
        assign bank_port_if[5].req_data.data    = out_switch_to_tmem[b].req_data.data;
        assign bank_port_if[5].req_data.byteen  = out_switch_to_tmem[b].req_data.byteen;
        assign bank_port_if[5].req_data.flags   = out_switch_to_tmem[b].req_data.flags;
        assign bank_port_if[5].req_data.tag     = out_switch_to_tmem[b].req_data.tag;
        assign out_switch_to_tmem[b].req_ready  = bank_port_if[5].req_ready;

        assign out_switch_to_tmem[b].rsp_valid     = bank_port_if[5].rsp_valid;
        assign out_switch_to_tmem[b].rsp_data.data = bank_port_if[5].rsp_data.data;
        assign out_switch_to_tmem[b].rsp_data.tag  = bank_port_if[5].rsp_data.tag;
        assign bank_port_if[5].rsp_ready           = out_switch_to_tmem[b].rsp_ready;

        VX_tensor_mem_bank #(
            .INSTANCE_ID ({INSTANCE_ID, ":bank"}),
            .SIZE        (BANK_SIZE),
            .DATA_SIZE   (DATA_SIZE),
            .NUM_PORTS   (NUM_TMEM_PORTS),
            .TAG_WIDTH   (SWITCH_TAG_WIDTH),
            .ENABLE_URGENCY(TMEM_ARB_URGENCY_ENABLE),
            .MAX_CONSECUTIVE_URGENT(TMEM_ARB_MAX_CONSECUTIVE_URGENT)
        ) u_bank (
            .clk        (clk),
            .reset      (reset),
            .req_urgent_i(bank_req_urgent),
            .req_priority_i(bank_req_priority),
            .mem_bus_if (bank_port_if)
        );

    end // g_bank

    // ================================================================
    // 5. Local DMAs x5
    // ================================================================
    // [0] input:   LMEM->GEMM (DIR=0)
    // [1] weight:  LMEM->GEMM (DIR=0)
    // [2] scale:   LMEM->GEMM (DIR=0)
    // [3] zp:      LMEM->GEMM (DIR=0)
    // [4] output:  GEMM->LMEM (DIR=1)

`ifdef PERF_ENABLE
    dma_perf_t ldma_perf [5];
`endif

    wire [$clog2(I_RD_OUTSTANDING + 1)-1:0]
        input_slot_occupancy;
    assign sched_input_slot_occupancy_o
        = $bits(sched_input_slot_occupancy_o)'(input_slot_occupancy);

    // Input local DMA
    VX_lmem_dma_input_overlap #(
        .INSTANCE_ID ({INSTANCE_ID, ":ldma_in"}),
        .MAX_DIMS    (1),
        .TAG_WIDTH   (TAG_WIDTH),
        .LMEM_ADDR_WIDTH_P(`MEM_ADDR_WIDTH - `CLOG2(DATA_SIZE)),
        .GEMM_ADDR_WIDTH_P(`MEM_ADDR_WIDTH - `CLOG2(GEMM_DATA_SIZE)),
        .LMEM_TAG_WIDTH_P(TAG_WIDTH),
        .GEMM_TAG_WIDTH_P(TAG_WIDTH),
        .CMD_FIFO_DEPTH(LDMA_CMD_FIFO_DEPTH),
        .RESPONSE_SLOTS(I_RD_OUTSTANDING),
        .ENABLE_TMEM_URGENCY(TMEM_ARB_URGENCY_ENABLE),
        .ENABLE_SCHED_SOURCE_GATE(1'b1),
        .READY_AHEAD_LOW_WATERMARK(INPUT_READY_AHEAD_LOW_WATERMARK)
    ) u_ldma_input (
        .clk         (clk),
        .reset       (reset),
        .sched_source_enable_i(sched_input_source_enable_i),
        .sched_priority_i(sched_source_priority_i[0]),
        .ctrl_if     (ldma_ctrl_if[0]),
        .writer_wait_i ('0),
        .writer_consume_value0_i ('0),
        .writer_consume_value1_i ('0),
        .gemm_sync_if(ldma_sync_if[0]),
        .lmem_bus_if (ldma_to_switch[0]),
        .gemm_bus_if (ldma_gemm[0]),
        .lmem_req_urgent_o(input_req_urgent),
        .lmem_req_priority_o(input_req_priority),
        .ready_ahead_o(),
        .sched_source_valid_o(sched_source_valid_o[0]),
        .sched_source_work_seq_o(sched_source_work_seq_o[0]),
        .sched_source_total_beats_o(sched_source_total_beats_o[0]),
        .sched_source_request_beats_o(sched_source_request_beats_o[0]),
        .sched_source_response_beats_o(sched_source_response_beats_o[0]),
        .sched_source_writer_beats_o(sched_source_writer_beats_o[0]),
        .sched_slot_occupancy_o(input_slot_occupancy),
        .sched_fetch_complete_o(sched_fetch_complete_o[0]),
        .sched_fetch_complete_work_seq_o(
            sched_fetch_complete_work_seq_o[0])
    `ifdef PERF_ENABLE
        ,.perf       (ldma_perf[0])
    `endif
    );

    // Weight local DMA
    VX_lmem_dma_weight_overlap #(
        .INSTANCE_ID ({INSTANCE_ID, ":ldma_wt"}),
        .MAX_DIMS    (1),
        .TAG_WIDTH   (TAG_WIDTH),
        .LMEM_ADDR_WIDTH_P(`MEM_ADDR_WIDTH - `CLOG2(GEMM_WEIGHT_DATA_SIZE)),
        .GEMM_ADDR_WIDTH_P(`MEM_ADDR_WIDTH - `CLOG2(GEMM_WEIGHT_DATA_SIZE)),
        .LMEM_TAG_WIDTH_P(TAG_WIDTH),
        .GEMM_TAG_WIDTH_P(TAG_WIDTH),
        .CMD_FIFO_DEPTH(LDMA_CMD_FIFO_DEPTH),
        .CMD_BEATS   (W_CMD_BEATS),
        .RESPONSE_SLOTS(W_RD_OUTSTANDING),
        .ENABLE_TMEM_URGENCY(TMEM_ARB_URGENCY_ENABLE),
        .READY_AHEAD_LOW_WATERMARK(WEIGHT_READY_AHEAD_LOW_WATERMARK)
    ) u_ldma_weight (
        .clk         (clk),
        .reset       (reset),
        .sched_priority_i(sched_source_priority_i[1]),
        .ctrl_if     (ldma_ctrl_if[1]),
        .writer_wait_i(weight_writer_wait_i),
        .weight_consume_value0_i(weight_consume_value0_i),
        .weight_consume_value1_i(weight_consume_value1_i),
        .gemm_sync_if(ldma_sync_if[1]),
        .lmem_bus_if (ldma_weight_to_tmem),
        .gemm_bus_if (ldma_gemm_weight),
        .lmem_req_urgent_o(weight_req_urgent),
        .lmem_req_priority_o(weight_req_priority),
        .ready_ahead_o(),
        .sched_source_valid_o(sched_source_valid_o[1]),
        .sched_source_work_seq_o(sched_source_work_seq_o[1]),
        .sched_source_total_beats_o(sched_source_total_beats_o[1]),
        .sched_source_request_beats_o(sched_source_request_beats_o[1]),
        .sched_source_response_beats_o(sched_source_response_beats_o[1]),
        .sched_source_writer_beats_o(sched_source_writer_beats_o[1]),
        .sched_slot_occupancy_o(),
        .sched_fetch_complete_o(sched_fetch_complete_o[1]),
        .sched_fetch_complete_work_seq_o(
            sched_fetch_complete_work_seq_o[1])
    `ifdef PERF_ENABLE
        ,.perf       (ldma_perf[1])
    `endif
    );

    `INIT_VX_MEM_BUS_IF (ldma_to_switch[1])

    // Scale local DMA
    VX_lmem_dma_qparam_overlap #(
        .INSTANCE_ID ({INSTANCE_ID, ":ldma_sc"}),
        .MAX_DIMS    (1),
        .TAG_WIDTH   (TAG_WIDTH),
        .CMD_FIFO_DEPTH(LDMA_CMD_FIFO_DEPTH),
        .RESPONSE_SLOTS(SZ_RD_OUTSTANDING),
        .WRITER_RID0 (GEMM_RID_SC_CONSUME0),
        .WRITER_RID1 (GEMM_RID_SC_CONSUME1),
        .LMEM_ADDR_WIDTH_P(`MEM_ADDR_WIDTH - `CLOG2(DATA_SIZE)),
        .GEMM_ADDR_WIDTH_P(`MEM_ADDR_WIDTH - `CLOG2(GEMM_DATA_SIZE)),
        .LMEM_TAG_WIDTH_P(TAG_WIDTH),
        .GEMM_TAG_WIDTH_P(TAG_WIDTH)
    ) u_ldma_scale (
        .clk         (clk),
        .reset       (reset),
        .sched_priority_i(sched_source_priority_i[2]),
        .ctrl_if     (ldma_ctrl_if[2]),
        .writer_wait_i(scale_writer_wait_i),
        .writer_consume_value0_i(scale_consume_value0_i),
        .writer_consume_value1_i(scale_consume_value1_i),
        .gemm_sync_if(ldma_sync_if[2]),
        .lmem_bus_if (ldma_to_switch[2]),
        .gemm_bus_if (ldma_gemm[2])
        ,.sched_source_valid_o(sched_source_valid_o[2])
        ,.sched_source_work_seq_o(sched_source_work_seq_o[2])
        ,.sched_source_total_beats_o(sched_source_total_beats_o[2])
        ,.sched_source_request_beats_o(sched_source_request_beats_o[2])
        ,.sched_source_response_beats_o(sched_source_response_beats_o[2])
        ,.sched_source_writer_beats_o(sched_source_writer_beats_o[2])
        ,.sched_slot_occupancy_o()
        ,.sched_fetch_complete_o(sched_fetch_complete_o[2])
        ,.sched_fetch_complete_work_seq_o(
            sched_fetch_complete_work_seq_o[2])
        ,.lmem_req_priority_o(scale_req_priority)
    `ifdef PERF_ENABLE
        ,.perf       (ldma_perf[2])
    `endif
    );

    // Zero-point local DMA
    VX_lmem_dma_qparam_overlap #(
        .INSTANCE_ID ({INSTANCE_ID, ":ldma_zp"}),
        .MAX_DIMS    (1),
        .TAG_WIDTH   (TAG_WIDTH),
        .CMD_FIFO_DEPTH(LDMA_CMD_FIFO_DEPTH),
        .RESPONSE_SLOTS(SZ_RD_OUTSTANDING),
        .WRITER_RID0 (GEMM_RID_ZP_CONSUME0),
        .WRITER_RID1 (GEMM_RID_ZP_CONSUME1),
        .LMEM_ADDR_WIDTH_P(`MEM_ADDR_WIDTH - `CLOG2(DATA_SIZE)),
        .GEMM_ADDR_WIDTH_P(`MEM_ADDR_WIDTH - `CLOG2(GEMM_DATA_SIZE)),
        .LMEM_TAG_WIDTH_P(TAG_WIDTH),
        .GEMM_TAG_WIDTH_P(TAG_WIDTH)
    ) u_ldma_zero_point (
        .clk         (clk),
        .reset       (reset),
        .sched_priority_i(sched_source_priority_i[3]),
        .ctrl_if     (ldma_ctrl_if[3]),
        .writer_wait_i(zero_point_writer_wait_i),
        .writer_consume_value0_i(zero_point_consume_value0_i),
        .writer_consume_value1_i(zero_point_consume_value1_i),
        .gemm_sync_if(ldma_sync_if[3]),
        .lmem_bus_if (ldma_to_switch[3]),
        .gemm_bus_if (ldma_gemm[3])
        ,.sched_source_valid_o(sched_source_valid_o[3])
        ,.sched_source_work_seq_o(sched_source_work_seq_o[3])
        ,.sched_source_total_beats_o(sched_source_total_beats_o[3])
        ,.sched_source_request_beats_o(sched_source_request_beats_o[3])
        ,.sched_source_response_beats_o(sched_source_response_beats_o[3])
        ,.sched_source_writer_beats_o(sched_source_writer_beats_o[3])
        ,.sched_slot_occupancy_o()
        ,.sched_fetch_complete_o(sched_fetch_complete_o[3])
        ,.sched_fetch_complete_work_seq_o(
            sched_fetch_complete_work_seq_o[3])
        ,.lmem_req_priority_o(zero_point_req_priority)
    `ifdef PERF_ENABLE
        ,.perf       (ldma_perf[3])
    `endif
    );

    // Output local DMA (GEMM -> LMEM)
    VX_lmem_dma_misal #(
        .INSTANCE_ID ({INSTANCE_ID, ":ldma_out"}),
        .MAX_DIMS    (1),
        .DIR         (1),
        .TAG_WIDTH   (TAG_WIDTH),
        .LMEM_ADDR_WIDTH_P(`MEM_ADDR_WIDTH - `CLOG2(DATA_SIZE)),
        .GEMM_ADDR_WIDTH_P(`MEM_ADDR_WIDTH - `CLOG2(GEMM_DATA_SIZE)),
        .LMEM_TAG_WIDTH_P(TAG_WIDTH),
        .GEMM_TAG_WIDTH_P(TAG_WIDTH),
        .RD_PREFETCH_DEPTH(O_RD_PREFETCH_DEPTH),
        .RD_OUTSTANDING(O_RD_OUTSTANDING)
    ) u_ldma_output (
        .clk         (clk),
        .reset       (reset),
        .ctrl_if     (ldma_ctrl_if[4]),
        .gemm_sync_if(ldma_sync_if[4]),
        .lmem_bus_if (ldma_to_switch[4]),
        .gemm_bus_if (ldma_gemm[4])
    `ifdef PERF_ENABLE
        ,.perf       (ldma_perf[4])
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

    assign gemm_weight_if.req_valid      = ldma_gemm_weight.req_valid;
    assign gemm_weight_if.req_data       = ldma_gemm_weight.req_data;
    assign ldma_gemm_weight.req_ready    = gemm_weight_if.req_ready;
    assign ldma_gemm_weight.rsp_valid    = gemm_weight_if.rsp_valid;
    assign ldma_gemm_weight.rsp_data     = gemm_weight_if.rsp_data;
    assign gemm_weight_if.rsp_ready      = ldma_gemm_weight.rsp_ready;

    assign gemm_scale_if.req_valid       = ldma_gemm[2].req_valid;
    assign gemm_scale_if.req_data        = ldma_gemm[2].req_data;
    assign ldma_gemm[2].req_ready        = gemm_scale_if.req_ready;
    assign ldma_gemm[2].rsp_valid        = gemm_scale_if.rsp_valid;
    assign ldma_gemm[2].rsp_data         = gemm_scale_if.rsp_data;
    assign gemm_scale_if.rsp_ready       = ldma_gemm[2].rsp_ready;

    assign gemm_zp_if.req_valid          = ldma_gemm[3].req_valid;
    assign gemm_zp_if.req_data           = ldma_gemm[3].req_data;
    assign ldma_gemm[3].req_ready        = gemm_zp_if.req_ready;
    assign ldma_gemm[3].rsp_valid        = gemm_zp_if.rsp_valid;
    assign ldma_gemm[3].rsp_data         = gemm_zp_if.rsp_data;
    assign gemm_zp_if.rsp_ready          = ldma_gemm[3].rsp_ready;

    // Output: DIR=1 (GEMM->LMEM) - local DMA reads from GEMM unit output buffer
    // gemm_output_if is master (subsystem issues read requests to GEMM unit)
    assign gemm_output_if.req_valid      = ldma_gemm[4].req_valid;
    assign gemm_output_if.req_data       = ldma_gemm[4].req_data;
    assign ldma_gemm[4].req_ready        = gemm_output_if.req_ready;
    assign ldma_gemm[4].rsp_valid        = gemm_output_if.rsp_valid;
    assign ldma_gemm[4].rsp_data         = gemm_output_if.rsp_data;
    assign gemm_output_if.rsp_ready      = ldma_gemm[4].rsp_ready;

    // ================================================================
    // 7. Local DMA performance — expose each instance directly
    //    (aggregation moved to runtime/stub/utils.cpp).
    // ================================================================
`ifdef PERF_ENABLE
    assign lmem_dma_input_perf  = ldma_perf[0];
    assign lmem_dma_weight_perf = ldma_perf[1];
    always_comb begin
        lmem_dma_sz_perf = '0;
        lmem_dma_sz_perf.rd_bytes = ldma_perf[2].rd_bytes + ldma_perf[3].rd_bytes;
        lmem_dma_sz_perf.wr_bytes = ldma_perf[2].wr_bytes + ldma_perf[3].wr_bytes;
        lmem_dma_sz_perf.xfer_count = ldma_perf[2].xfer_count + ldma_perf[3].xfer_count;
        lmem_dma_sz_perf.active_cycles = ldma_perf[2].active_cycles + ldma_perf[3].active_cycles;
        lmem_dma_sz_perf.src_rd_req_fire = ldma_perf[2].src_rd_req_fire + ldma_perf[3].src_rd_req_fire;
        lmem_dma_sz_perf.src_rd_req_stall = ldma_perf[2].src_rd_req_stall + ldma_perf[3].src_rd_req_stall;
        lmem_dma_sz_perf.src_rd_data_fire = ldma_perf[2].src_rd_data_fire + ldma_perf[3].src_rd_data_fire;
        lmem_dma_sz_perf.src_rd_data_stall = ldma_perf[2].src_rd_data_stall + ldma_perf[3].src_rd_data_stall;
        lmem_dma_sz_perf.dst_wr_fire = ldma_perf[2].dst_wr_fire + ldma_perf[3].dst_wr_fire;
        lmem_dma_sz_perf.dst_wr_stall = ldma_perf[2].dst_wr_stall + ldma_perf[3].dst_wr_stall;
        lmem_dma_sz_perf.wait_dcache = ldma_perf[2].wait_dcache + ldma_perf[3].wait_dcache;
        lmem_dma_sz_perf.wait_lmem = ldma_perf[2].wait_lmem + ldma_perf[3].wait_lmem;
        lmem_dma_sz_perf.busy = ldma_perf[2].busy || ldma_perf[3].busy;
    end
    assign lmem_dma_output_perf = ldma_perf[4];
`endif

`ifdef DBG_TRACE_MEM
    always @(posedge clk) begin
        if (ldma_to_switch[0].req_valid && ldma_to_switch[0].req_ready) begin
            `TRACE(1, ("%t: %s ldma_in req: addr=0x%0h, rw=%0b\n",
                $time, INSTANCE_ID, ldma_to_switch[0].req_data.addr,
                ldma_to_switch[0].req_data.rw))
        end
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
        if (ldma_to_switch[2].req_valid && ldma_to_switch[2].req_ready) begin
            `TRACE(1, ("%t: %s ldma_sc req: addr=0x%0h, rw=%0b\n",
                $time, INSTANCE_ID, ldma_to_switch[2].req_data.addr,
                ldma_to_switch[2].req_data.rw))
        end
        if (ldma_to_switch[3].req_valid && ldma_to_switch[3].req_ready) begin
            `TRACE(1, ("%t: %s ldma_zp req: addr=0x%0h, rw=%0b\n",
                $time, INSTANCE_ID, ldma_to_switch[3].req_data.addr,
                ldma_to_switch[3].req_data.rw))
        end
        if (ldma_to_switch[4].req_valid && ldma_to_switch[4].req_ready) begin
            `TRACE(1, ("%t: %s ldma_out req: addr=0x%0h, rw=%0b\n",
                $time, INSTANCE_ID, ldma_to_switch[4].req_data.addr,
                ldma_to_switch[4].req_data.rw))
        end
    end
`endif

endmodule

// Two-entry, registered, non-fall-through reservation for read requests.
// The local DMA allocates its response slot on upstream enqueue.  The
// downstream handshake only releases this reservation and therefore must not
// feed upstream ready in the same cycle.
module VX_tmem_read_req_reservation import VX_gpu_pkg::*; #(
    parameter `STRING INSTANCE_ID = "",
    parameter DATA_SIZE      = 64,
    parameter TAG_WIDTH      = 8,
    parameter MEM_ADDR_WIDTH = `MEM_ADDR_WIDTH
) (
    input wire clk,
    input wire reset,

    input wire [GEMM_SCHED_PRIORITY_WIDTH-1:0] req_priority_i,
    input wire req_urgent_i,
    input wire [31:0] req_work_seq_i,
    output wire [GEMM_SCHED_PRIORITY_WIDTH-1:0] req_priority_o,
    output wire req_urgent_o,
    output wire [31:0] req_work_seq_o,

    VX_mem_bus_if.slave upstream_if,
    VX_mem_bus_if.master downstream_if
);
    localparam int DEPTH = 2;
    localparam int ADDR_WIDTH = MEM_ADDR_WIDTH - `CLOG2(DATA_SIZE);
    localparam int TAG_VALUE_WIDTH = TAG_WIDTH - `UP(UUID_WIDTH);

    logic [ADDR_WIDTH-1:0] addr_r[DEPTH];
    logic [TAG_VALUE_WIDTH-1:0] tag_value_r[DEPTH];
    logic [GEMM_SCHED_PRIORITY_WIDTH-1:0] priority_r[DEPTH];
    logic urgent_r[DEPTH];
    // Work sequence is reservation provenance for debug/assertion correlation
    // even though the current TMEM switch arbitration consumes only priority.
    (* keep = "true" *)
    logic [31:0] work_seq_r[DEPTH];
    logic read_ptr_r;
    logic write_ptr_r;
    logic [1:0] occupancy_r;

    wire enqueue = upstream_if.req_valid && upstream_if.req_ready;
    wire dequeue = downstream_if.req_valid && downstream_if.req_ready;
    wire head_valid = occupancy_r != 0;

    // Registered-credit rule: a full reservation cannot accept a replacement
    // on the same edge that begins draining.
    assign upstream_if.req_ready = occupancy_r < 2'd2;

    assign downstream_if.req_valid = head_valid;
    assign downstream_if.req_data.rw = 1'b0;
    assign downstream_if.req_data.addr = head_valid ? addr_r[read_ptr_r] : '0;
    assign downstream_if.req_data.data = '0;
    assign downstream_if.req_data.byteen = '1;
    assign downstream_if.req_data.flags = '0;
    assign downstream_if.req_data.tag.uuid = '0;
    assign downstream_if.req_data.tag.value
        = head_valid ? tag_value_r[read_ptr_r] : '0;
    assign req_priority_o = head_valid
        ? priority_r[read_ptr_r] : GEMM_SCHED_PRIORITY_BACKGROUND;
    assign req_urgent_o = head_valid && urgent_r[read_ptr_r];
    assign req_work_seq_o = head_valid ? work_seq_r[read_ptr_r] : '0;

    // Response tags return unchanged to the local DMA slot allocated on
    // enqueue.  No request state is allocated on downstream dequeue.
    assign upstream_if.rsp_valid = downstream_if.rsp_valid;
    assign upstream_if.rsp_data = downstream_if.rsp_data;
    assign downstream_if.rsp_ready = upstream_if.rsp_ready;

    always_ff @(posedge clk) begin
        if (reset) begin
            read_ptr_r <= 1'b0;
            write_ptr_r <= 1'b0;
            occupancy_r <= '0;
        end else begin
            if (enqueue) begin
                addr_r[write_ptr_r] <= upstream_if.req_data.addr;
                tag_value_r[write_ptr_r] <= upstream_if.req_data.tag.value;
                priority_r[write_ptr_r] <= req_priority_i;
                urgent_r[write_ptr_r] <= req_urgent_i;
                work_seq_r[write_ptr_r] <= req_work_seq_i;
                write_ptr_r <= ~write_ptr_r;
            end
            if (dequeue)
                read_ptr_r <= ~read_ptr_r;

            unique case ({enqueue, dequeue})
                2'b10: occupancy_r <= occupancy_r + 2'd1;
                2'b01: occupancy_r <= occupancy_r - 2'd1;
                default:;
            endcase
        end
    end

`ifndef SYNTHESIS
    logic stalled_head_r;
    logic [ADDR_WIDTH-1:0] stalled_addr_r;
    logic [TAG_VALUE_WIDTH-1:0] stalled_tag_value_r;
    logic [GEMM_SCHED_PRIORITY_WIDTH-1:0] stalled_priority_r;
    logic stalled_urgent_r;
    logic [31:0] stalled_work_seq_r;
    logic [31:0] enqueue_count_r;
    logic [31:0] dequeue_count_r;

    always_ff @(posedge clk) begin
        if (reset) begin
            stalled_head_r <= 1'b0;
            enqueue_count_r <= '0;
            dequeue_count_r <= '0;
        end else begin
            assert (occupancy_r <= 2'd2)
                else $fatal(1, "%s: read reservation occupancy overflow",
                            INSTANCE_ID);
            assert ((enqueue_count_r - dequeue_count_r) == occupancy_r)
                else $fatal(1, "%s: read reservation accounting mismatch",
                            INSTANCE_ID);
            if (enqueue) begin
                assert (!upstream_if.req_data.rw
                     && (upstream_if.req_data.data == '0)
                     && (&upstream_if.req_data.byteen)
                     && (upstream_if.req_data.flags == '0)
                     && (upstream_if.req_data.tag.uuid == '0))
                    else $fatal(1,
                        "%s: non-constant read payload entered reservation",
                        INSTANCE_ID);
                enqueue_count_r <= enqueue_count_r + 32'd1;
            end
            if (dequeue)
                dequeue_count_r <= dequeue_count_r + 32'd1;
            if (stalled_head_r) begin
                assert (downstream_if.req_valid
                     && (downstream_if.req_data.addr == stalled_addr_r)
                     && (downstream_if.req_data.tag.value
                         == stalled_tag_value_r)
                     && (req_priority_o == stalled_priority_r)
                     && (req_urgent_o == stalled_urgent_r)
                     && (req_work_seq_o == stalled_work_seq_r))
                    else $fatal(1,
                        "%s: read reservation head changed under backpressure",
                        INSTANCE_ID);
            end
            stalled_head_r <= downstream_if.req_valid
                           && !downstream_if.req_ready;
            if (downstream_if.req_valid && !downstream_if.req_ready) begin
                stalled_addr_r <= downstream_if.req_data.addr;
                stalled_tag_value_r <= downstream_if.req_data.tag.value;
                stalled_priority_r <= req_priority_o;
                stalled_urgent_r <= req_urgent_o;
                stalled_work_seq_r <= req_work_seq_o;
            end
        end
    end
`endif

endmodule
