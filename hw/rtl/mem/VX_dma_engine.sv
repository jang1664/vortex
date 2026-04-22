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

// VX_dma_engine
//  Multi-channel DMA engine bridging HBM (AXI) and TMEM (VX_mem_bus_if).
//  Each channel instantiates VX_dma_unit_misal for the 3D strided FSM.
//  Burst-only: all DMA descriptors must satisfy
//     SEG_SIZE    == MEM_BLOCK_SIZE
//     SRC/DST_ST0 == HBM_BUS_STRIDE (= MEM_BLOCK_SIZE * NUM_DMA_CHANNELS)
//  so HBM addresses are remapped and coalesced into AXI bursts.
//
//  Burst window layout: READ_BURST_GROUPS (= NUM_HBM_BANKS / NUM_CHANNELS)
//  groups per window, each group covering READ_GROUP_CAP beats of an AXI INCR
//  burst. The invariant
//     READ_BURST_GROUPS * HBM_BUS_STRIDE == NUM_HBM_BANKS * MEM_BLOCK_SIZE
//  ensures that "beat+1 inside a group" (AXI INCR, +64 B physical) lands on
//  the next valid sw row in the 32-bank interleaved layout.

module VX_dma_engine import VX_gpu_pkg::*; #(
    parameter `STRING INSTANCE_ID   = "",
    parameter NUM_CHANNELS          = 8,
    parameter DATA_WIDTH            = 512,
    parameter AXI_ADDR_WIDTH        = `PLATFORM_MEMORY_ADDR_WIDTH,
    parameter AXI_DATA_WIDTH        = `PLATFORM_MEMORY_DATA_SIZE * 8,
    parameter AXI_ID_WIDTH          = `PLATFORM_MEMORY_ID_WIDTH,
    parameter AXI_USER_WIDTH        = 1,
    parameter MEM_ADDR_WIDTH        = `MEM_ADDR_WIDTH,
    parameter TAG_WIDTH             = 8,
    // Forwarded to each VX_dma_unit_misal channel — see that module for
    // semantics. Default 0 (aligned-only) to match the chip-level SW
    // convention; parents that still need byte-misalign must override.
    parameter bit ENABLE_MISALIGN   = 1'b0
) (
    input wire clk,
    input wire reset,

    // Config register interface per channel (from gemm_dma_ctrl)
    VX_config_reg_if.slave  cfg_reg_if [NUM_CHANNELS],

    // Done interface per channel
    VX_node_done_if.master  done_if [NUM_CHANNELS],

    // HBM side: AXI master per channel
    AXI_BUS.Master          axi_m [NUM_CHANNELS],

    // TMEM side: VX_mem_bus_if master per channel
    VX_mem_bus_if.master    tmem_bus_if [NUM_CHANNELS]
);

    localparam DATA_SIZE      = DATA_WIDTH / 8;
    localparam LOG2_DATA_SIZE = `CLOG2(DATA_SIZE);
    // VX_mem_bus_if uses word-addressable addresses
    localparam HBM_ADDR_WIDTH = MEM_ADDR_WIDTH - LOG2_DATA_SIZE;

    localparam int DMA_R_CONTROL     = 0;
    localparam int DMA_R_DST_BASE_LO = 1;
    localparam int DMA_R_DST_BASE_HI = 2;
    localparam int DMA_R_SRC_BASE_LO = 3;
    localparam int DMA_R_SRC_BASE_HI = 4;
    localparam int DMA_R_SRC_ST0     = 5;
    localparam int DMA_R_DST_ST0     = 6;
    localparam int DMA_R_SRC_ST1     = 7;
    localparam int DMA_R_DST_ST1     = 8;
    localparam int DMA_R_SRC_ST2     = 9;
    localparam int DMA_R_DST_ST2     = 10;
    localparam int DMA_R_BND0        = 11;
    localparam int DMA_R_BND1        = 12;
    localparam int DMA_R_BND2        = 13;
    localparam int DMA_R_SEG_SIZE    = 14;
    localparam int DMA_R_PAD         = 15;
    localparam int DMA_R_DIR         = 16;

    // Burst geometry. The invariant
    //    READ_BURST_GROUPS * HBM_BUS_STRIDE == PLATFORM_MEMORY_NUM_BANKS * MEM_BLOCK_SIZE
    // must hold so that a "beat+1 inside a group" in the AXI INCR burst lands on
    // the next valid sw row in the 32-bank interleaved layout. Equivalently,
    //    READ_BURST_GROUPS == PLATFORM_MEMORY_NUM_BANKS / NUM_CHANNELS.
    localparam int READ_GROUP_CAP    = 4;
    localparam int READ_BURST_GROUPS = `PLATFORM_MEMORY_NUM_BANKS / NUM_CHANNELS;
    localparam int READ_WINDOW_WORDS = READ_BURST_GROUPS * READ_GROUP_CAP;
    // Index widths. Counters are wide enough to hold the "all done" terminator
    // (== GROUPS / == CAP). Slice widths (LOG2_GROUPS, GSEL_W, WIDX_W) are for
    // array indexing and are guarded with `UP to avoid 0-bit slices when
    // GROUPS == 1 (i.e., NUM_CHANNELS == NUM_HBM_BANKS).
    localparam int GROUP_IDX_W       = `CLOG2(READ_BURST_GROUPS + 1);
    localparam int BEAT_IDX_W        = `CLOG2(READ_GROUP_CAP    + 1);
    localparam int WINDOW_CNT_W      = `CLOG2(READ_WINDOW_WORDS + 1);
    localparam int LOG2_GROUPS       = `CLOG2(READ_BURST_GROUPS);
    localparam int GSEL_W            = `UP(LOG2_GROUPS);
    localparam int WIDX_W            = `UP(`CLOG2(READ_WINDOW_WORDS));

    // Bus-word / HBM-bank geometry (all derived from VX_config.vh macros)
    localparam int BLOCK_SIZE_B         = `MEM_BLOCK_SIZE;
    localparam int BLOCK_SHIFT          = `CLOG2(BLOCK_SIZE_B);
    localparam int HBM_BANK_BITS        = `CLOG2(`PLATFORM_MEMORY_NUM_BANKS);
    localparam int HBM_BANK_SHIFT       = `PLATFORM_MEMORY_ADDR_WIDTH - HBM_BANK_BITS;
    localparam int HBM_BUS_STRIDE_B     = `HBM_BUS_STRIDE;
    localparam int HBM_BUS_STRIDE_SHIFT = `CLOG2(HBM_BUS_STRIDE_B);

    // ceil((window_words - group_idx) / READ_BURST_GROUPS) for group_idx < window_words,
    // else 0. Distributes `window_words` bus-words evenly across READ_BURST_GROUPS groups
    // (excess words land in lower-indexed groups).
    function automatic [BEAT_IDX_W-1:0] calc_group_words(
        input logic [WINDOW_CNT_W-1:0] window_words,
        input logic [GSEL_W-1:0]       group_idx
    );
        logic [WINDOW_CNT_W-1:0] words_left;
        begin
            if (window_words <= WINDOW_CNT_W'(group_idx)) begin
                calc_group_words = '0;
            end else begin
                words_left       = window_words - WINDOW_CNT_W'(group_idx) - WINDOW_CNT_W'(1);
                calc_group_words = BEAT_IDX_W'(
                    (words_left >> LOG2_GROUPS) + WINDOW_CNT_W'(1)
                );
            end
        end
    endfunction

    function automatic [AXI_ADDR_WIDTH-1:0] calc_remap_byte_addr(
        input logic [AXI_ADDR_WIDTH-1:0] byte_addr
    );
        logic [AXI_ADDR_WIDTH-1:0] block_idx;
        logic [AXI_ADDR_WIDTH-1:0] byte_offset;
        logic [HBM_BANK_BITS-1:0]  bank_idx;
        logic [AXI_ADDR_WIDTH-1:0] bank_offset;
        begin
            block_idx   = byte_addr >> BLOCK_SHIFT;
            byte_offset = byte_addr & ((AXI_ADDR_WIDTH'(1) << BLOCK_SHIFT) - 1);
            bank_idx    = block_idx[HBM_BANK_BITS-1:0];
            bank_offset = (block_idx >> HBM_BANK_BITS) << BLOCK_SHIFT;
            calc_remap_byte_addr =
                ({ {(AXI_ADDR_WIDTH-HBM_BANK_BITS){1'b0}}, bank_idx } << HBM_BANK_SHIFT)
              | bank_offset
              | byte_offset;
        end
    endfunction

    for (genvar ch = 0; ch < NUM_CHANNELS; ++ch) begin : g_channel

        typedef enum logic [0:0] {
            RD_BURST_CAPTURE,
            RD_BURST_ACTIVE
        } read_state_t;

        typedef enum logic [2:0] {
            WR_IDLE,
            WR_BURST_CAPTURE,
            WR_BURST_AW,
            WR_BURST_W,
            WR_BURST_DRAIN_B
        } write_state_t;

        // --------------------------------------------------------
        // Internal membus interface for HBM side (dcache port)
        // --------------------------------------------------------
        VX_mem_bus_if #(
            .DATA_SIZE      (DATA_SIZE),
            .TAG_WIDTH      (TAG_WIDTH),
            .MEM_ADDR_WIDTH (MEM_ADDR_WIDTH)
        ) hbm_bus_if ();

        // --------------------------------------------------------
        // VX_dma_unit_misal instance
        //   dcache_bus_if -> hbm_bus_if
        //   lmem_bus_if   -> tmem_bus_if[ch]
        //   done gated by burst write completion
        // --------------------------------------------------------
        VX_node_done_if internal_done_if();

        VX_dma_unit_misal #(
            .INSTANCE_ID     (INSTANCE_ID),
            .ENABLE_MISALIGN (ENABLE_MISALIGN)
        ) u_dma_unit (
            .clk            (clk),
            .reset          (reset),
            .cfg_reg_if     (cfg_reg_if[ch]),
            .dcache_bus_if  (hbm_bus_if),
            .lmem_bus_if    (tmem_bus_if[ch]),
            .done_if        (internal_done_if)
        );

        // --------------------------------------------------------
        // Extract flat signals from hbm_bus_if
        // --------------------------------------------------------
        wire                      hbm_req_valid;
        wire                      hbm_req_rw;
        wire [DATA_SIZE-1:0]      hbm_req_byteen;
        wire [HBM_ADDR_WIDTH-1:0] hbm_req_addr;
        wire [DATA_WIDTH-1:0]     hbm_req_data;
        wire [TAG_WIDTH-1:0]      hbm_req_tag;
        wire                      hbm_req_ready;

        wire                      hbm_rsp_valid;
        wire [DATA_WIDTH-1:0]     hbm_rsp_data;
        wire [TAG_WIDTH-1:0]      hbm_rsp_tag;
        wire                      hbm_rsp_ready;

        assign hbm_req_valid         = hbm_bus_if.req_valid;
        assign hbm_req_rw            = hbm_bus_if.req_data.rw;
        assign hbm_req_byteen        = hbm_bus_if.req_data.byteen;
        assign hbm_req_addr          = hbm_bus_if.req_data.addr;
        assign hbm_req_data          = hbm_bus_if.req_data.data;
        assign hbm_req_tag           = TAG_WIDTH'(hbm_bus_if.req_data.tag);
        assign hbm_bus_if.req_ready  = hbm_req_ready;

        assign hbm_bus_if.rsp_valid     = hbm_rsp_valid;
        assign hbm_bus_if.rsp_data.data = hbm_rsp_data;
        assign hbm_bus_if.rsp_data.tag  = hbm_rsp_tag;
        assign hbm_rsp_ready            = hbm_bus_if.rsp_ready;

        wire [AXI_ADDR_WIDTH-1:0] hbm_req_byte_addr;
        wire [AXI_ADDR_WIDTH-1:0] hbm_req_remap_byte_addr;

        assign hbm_req_byte_addr = AXI_ADDR_WIDTH'(hbm_req_addr) << LOG2_DATA_SIZE;

        VX_mem_remap #(
            .ADDR_W (AXI_ADDR_WIDTH)
        ) u_mem_remap (
            .m_address   (hbm_req_byte_addr),
            .hbm_address (hbm_req_remap_byte_addr)
        );

        // --------------------------------------------------------
        // Descriptor latch
        // --------------------------------------------------------
        wire cfg_fire = cfg_reg_if[ch].valid && cfg_reg_if[ch].ready;

        wire cfg_is_read = ~cfg_reg_if[ch].regs[DMA_R_DIR][0];

        logic [31:0] desc_words_r;

        // --------------------------------------------------------
        // Write path: burst only
        // --------------------------------------------------------
        wire wr_req_valid = hbm_req_valid && hbm_req_rw;
        wire wr_req_ready;

        // --------------------------------------------------------
        // Read path: burst only
        // --------------------------------------------------------
        logic [AXI_ADDR_WIDTH-1:0] burst_src_base_byte_r;
        logic [31:0]               burst_words_served_r;
        logic                      burst_prefetch_started_r;
        logic                      burst_req_pending_r;
        logic [TAG_WIDTH-1:0]      burst_req_tag_r;
        logic                      burst_rsp_valid_r;
        logic [DATA_WIDTH-1:0]     burst_rsp_data_r;
        logic [TAG_WIDTH-1:0]      burst_rsp_tag_r;
        logic [31:0]               burst_window_base_r;
        logic [WINDOW_CNT_W-1:0]   burst_accept_count_r;
        // AR issue pointer (0..READ_BURST_GROUPS, == READ_BURST_GROUPS means all AR issued)
        logic [GROUP_IDX_W-1:0]    burst_issue_group_r;
        // R recv pointers (independent of AR issue to allow pipelined AR/R)
        logic [GROUP_IDX_W-1:0]    burst_recv_group_r;
        logic [BEAT_IDX_W-1:0]     burst_recv_beat_r;
        logic [READ_BURST_GROUPS-1:0][BEAT_IDX_W-1:0]                   burst_group_count_r;
        logic [READ_BURST_GROUPS-1:0][AXI_ADDR_WIDTH-1:0]               burst_group_base_addr_r;
        logic [READ_BURST_GROUPS-1:0][READ_GROUP_CAP-1:0][TAG_WIDTH-1:0] burst_group_tag_r;
        (* ram_style = "block" *)
        logic [READ_WINDOW_WORDS-1:0][DATA_WIDTH-1:0]               burst_window_data_r;
        logic [READ_WINDOW_WORDS-1:0]                               burst_window_valid_r;

        read_state_t read_state_r;

        // --------------------------------------------------------
        // Write burst registers
        // --------------------------------------------------------
        write_state_t write_state_r;
        logic [AXI_ADDR_WIDTH-1:0] burst_wr_dst_base_byte_r;
        logic [31:0]               burst_wr_words_captured_r;
        logic [31:0]               burst_wr_window_base_r;
        logic                      burst_wr_prefetch_started_r;
        // AW issue pointer (0..READ_BURST_GROUPS)
        logic [GROUP_IDX_W-1:0]    burst_wr_issue_group_r;
        // W beat within current issue group
        logic [BEAT_IDX_W-1:0]     burst_wr_issue_beat_r;
        // B recv pointer (pipelines independently of AW/W issue)
        logic [GROUP_IDX_W-1:0]    burst_wr_recv_group_r;
        logic [READ_BURST_GROUPS-1:0][BEAT_IDX_W-1:0]     burst_wr_group_count_r;
        logic [READ_BURST_GROUPS-1:0][AXI_ADDR_WIDTH-1:0] burst_wr_group_base_addr_r;
        logic [READ_WINDOW_WORDS-1:0][DATA_WIDTH-1:0]     burst_wr_window_data_r;
        logic [READ_WINDOW_WORDS-1:0][DATA_SIZE-1:0]      burst_wr_window_byteen_r;

        // Hold done until burst writes drain to AXI
        assign done_if[ch].valid      = internal_done_if.valid & (write_state_r == WR_IDLE);
        assign done_if[ch].entry_id   = internal_done_if.entry_id;
        assign internal_done_if.ready = done_if[ch].ready & (write_state_r == WR_IDLE);

        wire                       rd_req_valid;
        wire [WINDOW_CNT_W-1:0]    burst_window_words;
        wire [31:0]                burst_words_remaining;
        wire [BEAT_IDX_W-1:0]      burst_group_words [READ_BURST_GROUPS];
        wire [WIDX_W-1:0]          burst_service_word;
        wire [AXI_ADDR_WIDTH-1:0]  burst_expected_byte_addr;
        wire                       burst_service_data_ready;
        wire                       rd_req_ready;
        wire                       axi_r_fire;

        assign rd_req_valid         = hbm_req_valid && ~hbm_req_rw;
        assign burst_words_remaining = (desc_words_r > burst_window_base_r)
                                     ? (desc_words_r - burst_window_base_r)
                                     : 32'd0;
        assign burst_window_words    = (burst_words_remaining > READ_WINDOW_WORDS)
                                     ? WINDOW_CNT_W'(READ_WINDOW_WORDS)
                                     : burst_words_remaining[WINDOW_CNT_W-1:0];
        assign burst_service_word   = burst_words_served_r[WIDX_W-1:0];
        assign burst_expected_byte_addr = burst_src_base_byte_r + (AXI_ADDR_WIDTH'(burst_words_served_r) << HBM_BUS_STRIDE_SHIFT);
        assign burst_service_data_ready = burst_window_valid_r[burst_service_word];

        for (genvar g = 0; g < READ_BURST_GROUPS; ++g) begin : g_burst_group_words
            assign burst_group_words[g] = calc_group_words(burst_window_words, GSEL_W'(g));
        end

        // Write burst combinational logic
        wire [WINDOW_CNT_W-1:0]    burst_wr_window_words;
        wire [BEAT_IDX_W-1:0]      burst_wr_group_words [READ_BURST_GROUPS];
        wire [AXI_ADDR_WIDTH-1:0]  burst_wr_expected_byte_addr;
        wire [WIDX_W-1:0]          burst_wr_word_idx;

        wire [31:0] burst_wr_words_remaining = (desc_words_r > burst_wr_window_base_r)
                                         ? (desc_words_r - burst_wr_window_base_r) : 32'd0;
        assign burst_wr_window_words = (burst_wr_words_remaining > READ_WINDOW_WORDS)
                                     ? WINDOW_CNT_W'(READ_WINDOW_WORDS)
                                     : burst_wr_words_remaining[WINDOW_CNT_W-1:0];

        assign burst_wr_expected_byte_addr = burst_wr_dst_base_byte_r
                                           + (AXI_ADDR_WIDTH'(burst_wr_words_captured_r) << HBM_BUS_STRIDE_SHIFT);

        assign wr_req_ready = (write_state_r == WR_BURST_CAPTURE)
                           && (burst_wr_words_captured_r < desc_words_r)
                           && ((burst_wr_words_captured_r == 32'd0)
                            || (hbm_req_byte_addr == burst_wr_expected_byte_addr));

        // Window layout: window[w] := group (w % GROUPS), beat (w / GROUPS).
        // Equivalently: word_idx = group + beat * GROUPS.
        assign burst_wr_word_idx = WIDX_W'(burst_wr_issue_group_r)
                                 + (WIDX_W'(burst_wr_issue_beat_r) << LOG2_GROUPS);

        for (genvar g = 0; g < READ_BURST_GROUPS; ++g) begin : g_wr_burst_group_words
            assign burst_wr_group_words[g] = calc_group_words(burst_wr_window_words, GSEL_W'(g));
        end

        assign rd_req_ready =
            ~burst_req_pending_r
            && (burst_words_served_r < desc_words_r)
            && ((~burst_prefetch_started_r && (read_state_r == RD_BURST_CAPTURE))
             || (burst_prefetch_started_r
                 && burst_service_data_ready
                 && (hbm_req_byte_addr == burst_expected_byte_addr)));

        assign axi_r_fire = axi_m[ch].r_valid && axi_m[ch].r_ready;

        // --------------------------------------------------------
        // Burst condition assertion (safety check)
        // --------------------------------------------------------
    `ifdef SIMULATION
        always_ff @(posedge clk) begin
            if (!reset && cfg_fire) begin
                if (cfg_is_read) begin
                    assert (cfg_reg_if[ch].regs[DMA_R_SEG_SIZE] == 32'(`MEM_BLOCK_SIZE)
                         && cfg_reg_if[ch].regs[DMA_R_PAD]      == 32'd0
                         && cfg_reg_if[ch].regs[DMA_R_BND2]     == 32'd1
                         && cfg_reg_if[ch].regs[DMA_R_SRC_ST0]  == 32'(`HBM_BUS_STRIDE)
                         && cfg_reg_if[ch].regs[DMA_R_SRC_ST2]  == 32'd0
                         && cfg_reg_if[ch].regs[DMA_R_DST_ST2]  == 32'd0
                         && cfg_reg_if[ch].regs[DMA_R_SRC_BASE_LO][BLOCK_SHIFT-1:0] == '0
                         && cfg_reg_if[ch].regs[DMA_R_BND0] != 32'd0)
                    else $fatal(1, "%m: non-burst read DMA descriptor detected (ch=%0d)", ch);
                end else begin
                    assert (cfg_reg_if[ch].regs[DMA_R_SEG_SIZE] == 32'(`MEM_BLOCK_SIZE)
                         && cfg_reg_if[ch].regs[DMA_R_PAD]      == 32'd0
                         && cfg_reg_if[ch].regs[DMA_R_BND2]     == 32'd1
                         && cfg_reg_if[ch].regs[DMA_R_DST_ST0]  == 32'(`HBM_BUS_STRIDE)
                         && cfg_reg_if[ch].regs[DMA_R_SRC_ST2]  == 32'd0
                         && cfg_reg_if[ch].regs[DMA_R_DST_ST2]  == 32'd0
                         && cfg_reg_if[ch].regs[DMA_R_DST_BASE_LO][BLOCK_SHIFT-1:0] == '0
                         && cfg_reg_if[ch].regs[DMA_R_BND0] != 32'd0)
                    else $fatal(1, "%m: non-burst write DMA descriptor detected (ch=%0d)", ch);
                end
            end
        end
    `endif

        // --------------------------------------------------------
        // Main FSM
        // --------------------------------------------------------
        always_ff @(posedge clk) begin
            if (reset) begin
                desc_words_r         <= '0;
                burst_window_base_r  <= '0;
                burst_accept_count_r <= '0;
                burst_issue_group_r  <= '0;
                burst_recv_group_r   <= '0;
                burst_recv_beat_r    <= '0;
                read_state_r         <= RD_BURST_CAPTURE;
                for (int i = 0; i < READ_BURST_GROUPS; ++i) begin
                    burst_group_count_r[i]     <= '0;
                    burst_group_base_addr_r[i] <= '0;
                    for (int j = 0; j < READ_GROUP_CAP; ++j) begin
                        burst_group_tag_r[i][j] <= '0;
                    end
                end
                write_state_r               <= WR_IDLE;
                burst_wr_dst_base_byte_r    <= '0;
                burst_wr_words_captured_r   <= '0;
                burst_wr_window_base_r      <= '0;
                burst_wr_prefetch_started_r <= 1'b0;
                burst_wr_issue_group_r      <= '0;
                burst_wr_issue_beat_r       <= '0;
                burst_wr_recv_group_r       <= '0;
                for (int i = 0; i < READ_BURST_GROUPS; ++i) begin
                    burst_wr_group_count_r[i]     <= '0;
                    burst_wr_group_base_addr_r[i] <= '0;
                end
            end else begin
                if (cfg_fire) begin
                    desc_words_r         <= cfg_reg_if[ch].regs[DMA_R_BND0];
                    burst_src_base_byte_r <= '0;
                    burst_words_served_r  <= '0;
                    burst_prefetch_started_r <= 1'b0;
                    burst_req_pending_r   <= 1'b0;
                    burst_req_tag_r       <= '0;
                    burst_rsp_valid_r     <= 1'b0;
                    burst_rsp_data_r      <= '0;
                    burst_rsp_tag_r       <= '0;
                    burst_window_base_r  <= '0;
                    burst_accept_count_r <= '0;
                    burst_issue_group_r  <= '0;
                    burst_recv_group_r   <= '0;
                    burst_recv_beat_r    <= '0;
                    read_state_r         <= RD_BURST_CAPTURE;
                    for (int i = 0; i < READ_BURST_GROUPS; ++i) begin
                        burst_group_count_r[i]     <= '0;
                        burst_group_base_addr_r[i] <= '0;
                        for (int j = 0; j < READ_GROUP_CAP; ++j) begin
                            burst_group_tag_r[i][j] <= '0;
                        end
                    end
                    // burst_window_data_r intentionally left unreset: the
                    // valid scoreboard gates reads, and array-wide reset
                    // prevents Vivado BRAM inference.
                    for (int i = 0; i < READ_WINDOW_WORDS; ++i) begin
                        burst_window_valid_r[i] <= 1'b0;
                    end
                    write_state_r               <= ~cfg_is_read ? WR_BURST_CAPTURE : WR_IDLE;
                    burst_wr_dst_base_byte_r    <= '0;
                    burst_wr_words_captured_r   <= '0;
                    burst_wr_window_base_r      <= '0;
                    burst_wr_prefetch_started_r <= 1'b0;
                    burst_wr_issue_group_r      <= '0;
                    burst_wr_issue_beat_r       <= '0;
                    burst_wr_recv_group_r       <= '0;
                    for (int i = 0; i < READ_BURST_GROUPS; ++i) begin
                        burst_wr_group_count_r[i]     <= '0;
                        burst_wr_group_base_addr_r[i] <= '0;
                    end
                    for (int i = 0; i < READ_WINDOW_WORDS; ++i) begin
                        burst_wr_window_data_r[i]   <= '0;
                        burst_wr_window_byteen_r[i] <= '0;
                    end
                end else begin
                    // ------------------------------------------------
                    // Read burst state machine (AR issue and R recv pipelined)
                    // ------------------------------------------------
                    if (burst_rsp_valid_r && hbm_rsp_ready) begin
                        burst_rsp_valid_r <= 1'b0;
                        burst_window_valid_r[burst_service_word] <= 1'b0;
                        burst_req_pending_r <= 1'b0;
                        burst_words_served_r <= burst_words_served_r + 32'd1;
                        if (burst_words_served_r + 32'd1 == burst_window_base_r + 32'(burst_window_words)
                            && burst_words_served_r + 32'd1 < desc_words_r) begin
                            burst_window_base_r      <= burst_window_base_r + 32'(burst_window_words);
                            burst_prefetch_started_r <= 1'b0;
                            for (int i = 0; i < READ_WINDOW_WORDS; ++i)
                                burst_window_valid_r[i] <= 1'b0;
                        end
                    end

                    if (burst_req_pending_r && !burst_rsp_valid_r && burst_service_data_ready) begin
                        burst_rsp_valid_r <= 1'b1;
                        burst_rsp_data_r  <= burst_window_data_r[burst_service_word];
                        burst_rsp_tag_r   <= burst_req_tag_r;
                    end

                    // Consumer request capture (both in CAPTURE and ACTIVE states)
                    if (rd_req_valid && rd_req_ready) begin
                        burst_req_pending_r <= 1'b1;
                        burst_req_tag_r     <= hbm_req_tag;

                        if (!burst_prefetch_started_r) begin
                            // First request of a new window: kick off AR pipeline
                            if (burst_words_served_r == 32'd0)
                                burst_src_base_byte_r <= hbm_req_byte_addr;
                            burst_prefetch_started_r <= 1'b1;
                            burst_accept_count_r     <= WINDOW_CNT_W'(1);
                            burst_issue_group_r      <= '0;
                            burst_recv_group_r       <= '0;
                            burst_recv_beat_r        <= '0;
                            read_state_r             <= RD_BURST_ACTIVE;
                            for (int i = 0; i < READ_BURST_GROUPS; ++i) begin
                                burst_group_count_r[i]     <= burst_group_words[i];
                                burst_group_base_addr_r[i] <= calc_remap_byte_addr(
                                    hbm_req_byte_addr + (AXI_ADDR_WIDTH'(i) << HBM_BUS_STRIDE_SHIFT)
                                );
                            end
                        end
                    end

                    if (read_state_r == RD_BURST_ACTIVE) begin
                        // AR side: issue AR for each non-empty group back-to-back
                        if (burst_issue_group_r < GROUP_IDX_W'(READ_BURST_GROUPS)) begin
                            if (burst_group_count_r[burst_issue_group_r[GSEL_W-1:0]] == 0) begin
                                // Skip empty group (no AR fired)
                                burst_issue_group_r <= burst_issue_group_r + GROUP_IDX_W'(1);
                            end else if (axi_m[ch].ar_ready) begin
                                burst_issue_group_r <= burst_issue_group_r + GROUP_IDX_W'(1);
                            end
                        end

                        // R side: accept beats in AR-issue order (same ar_id => in-order)
                        if (burst_recv_group_r < GROUP_IDX_W'(READ_BURST_GROUPS)) begin
                            if (burst_group_count_r[burst_recv_group_r[GSEL_W-1:0]] == 0) begin
                                // Skip empty group (no R expected)
                                burst_recv_group_r <= burst_recv_group_r + GROUP_IDX_W'(1);
                                burst_recv_beat_r  <= '0;
                                if (burst_recv_group_r + GROUP_IDX_W'(1) == GROUP_IDX_W'(READ_BURST_GROUPS))
                                    read_state_r <= RD_BURST_CAPTURE;
                            end else if (axi_r_fire) begin
                                logic [WIDX_W-1:0] rsp_word_idx;
                                rsp_word_idx = WIDX_W'(burst_recv_group_r)
                                             + (WIDX_W'(burst_recv_beat_r) << LOG2_GROUPS);
                                burst_window_data_r[rsp_word_idx]  <= axi_m[ch].r_data;
                                burst_window_valid_r[rsp_word_idx] <= 1'b1;

                                if (burst_recv_beat_r + BEAT_IDX_W'(1) < burst_group_count_r[burst_recv_group_r[GSEL_W-1:0]]) begin
                                    burst_recv_beat_r <= burst_recv_beat_r + BEAT_IDX_W'(1);
                                end else begin
                                    burst_recv_beat_r  <= '0;
                                    burst_recv_group_r <= burst_recv_group_r + GROUP_IDX_W'(1);
                                    if (burst_recv_group_r + GROUP_IDX_W'(1) == GROUP_IDX_W'(READ_BURST_GROUPS))
                                        read_state_r <= RD_BURST_CAPTURE;
                                end
                            end
                        end
                    end

                    // ------------------------------------------------
                    // Write burst state machine
                    //   AW+W is sequential per group (tb write model supports
                    //   one outstanding AW), but B is collected independently
                    //   so next group's AW is not blocked by B wait.
                    // ------------------------------------------------

                    // B response pipeline (runs once AW/W phase has begun)
                    if ((write_state_r == WR_BURST_AW
                         || write_state_r == WR_BURST_W
                         || write_state_r == WR_BURST_DRAIN_B)
                        && burst_wr_recv_group_r < GROUP_IDX_W'(READ_BURST_GROUPS)) begin
                        if (burst_wr_group_count_r[burst_wr_recv_group_r[GSEL_W-1:0]] == 0) begin
                            // Skip zero-count group (no AW fired for it)
                            burst_wr_recv_group_r <= burst_wr_recv_group_r + GROUP_IDX_W'(1);
                        end else if (axi_m[ch].b_valid) begin
                            burst_wr_recv_group_r <= burst_wr_recv_group_r + GROUP_IDX_W'(1);
                        end
                    end

                    case (write_state_r)
                        WR_BURST_CAPTURE: begin
                            if (burst_wr_prefetch_started_r
                                && (burst_wr_words_captured_r >= burst_wr_window_base_r + 32'(burst_wr_window_words))) begin
                                burst_wr_issue_group_r <= '0;
                                burst_wr_issue_beat_r  <= '0;
                                burst_wr_recv_group_r  <= '0;
                                write_state_r          <= WR_BURST_AW;
                            end else if (wr_req_valid && wr_req_ready) begin
                                burst_wr_window_data_r[burst_wr_words_captured_r[WIDX_W-1:0]]   <= hbm_req_data;
                                burst_wr_window_byteen_r[burst_wr_words_captured_r[WIDX_W-1:0]] <= hbm_req_byteen;
                                if (!burst_wr_prefetch_started_r) begin
                                    if (burst_wr_words_captured_r == 32'd0)
                                        burst_wr_dst_base_byte_r <= hbm_req_byte_addr;
                                    burst_wr_prefetch_started_r <= 1'b1;
                                    for (int i = 0; i < READ_BURST_GROUPS; ++i) begin
                                        burst_wr_group_count_r[i]     <= burst_wr_group_words[i];
                                        burst_wr_group_base_addr_r[i] <= calc_remap_byte_addr(
                                            hbm_req_byte_addr + (AXI_ADDR_WIDTH'(i) << HBM_BUS_STRIDE_SHIFT)
                                        );
                                    end
                                end
                                burst_wr_words_captured_r <= burst_wr_words_captured_r + 32'd1;
                            end
                        end
                        WR_BURST_AW: begin
                            if (burst_wr_group_count_r[burst_wr_issue_group_r[GSEL_W-1:0]] == 0) begin
                                if (burst_wr_issue_group_r == GROUP_IDX_W'(READ_BURST_GROUPS-1)) begin
                                    // All AW done — move to B drain (or skip if already drained)
                                    burst_wr_issue_group_r <= burst_wr_issue_group_r + GROUP_IDX_W'(1);
                                    write_state_r          <= WR_BURST_DRAIN_B;
                                end else begin
                                    burst_wr_issue_group_r <= burst_wr_issue_group_r + GROUP_IDX_W'(1);
                                end
                            end else if (axi_m[ch].aw_ready) begin
                                burst_wr_issue_beat_r <= '0;
                                write_state_r         <= WR_BURST_W;
                            end
                        end
                        WR_BURST_W: begin
                            if (axi_m[ch].w_ready) begin
                                if (burst_wr_issue_beat_r + BEAT_IDX_W'(1) >= burst_wr_group_count_r[burst_wr_issue_group_r[GSEL_W-1:0]]) begin
                                    // W burst for this group done — do NOT wait for B
                                    if (burst_wr_issue_group_r == GROUP_IDX_W'(READ_BURST_GROUPS-1)) begin
                                        burst_wr_issue_group_r <= burst_wr_issue_group_r + GROUP_IDX_W'(1);
                                        write_state_r          <= WR_BURST_DRAIN_B;
                                    end else begin
                                        burst_wr_issue_group_r <= burst_wr_issue_group_r + GROUP_IDX_W'(1);
                                        write_state_r          <= WR_BURST_AW;
                                    end
                                end else begin
                                    burst_wr_issue_beat_r <= burst_wr_issue_beat_r + BEAT_IDX_W'(1);
                                end
                            end
                        end
                        WR_BURST_DRAIN_B: begin
                            // Wait until parallel B pipeline has consumed all responses
                            if (burst_wr_recv_group_r >= GROUP_IDX_W'(READ_BURST_GROUPS)) begin
                                if (burst_wr_words_captured_r < desc_words_r) begin
                                    burst_wr_window_base_r      <= burst_wr_window_base_r + 32'(burst_wr_window_words);
                                    burst_wr_prefetch_started_r <= 1'b0;
                                    burst_wr_issue_group_r      <= '0;
                                    burst_wr_recv_group_r       <= '0;
                                    write_state_r               <= WR_BURST_CAPTURE;
                                end else begin
                                    write_state_r <= WR_IDLE;
                                end
                            end
                        end
                        WR_IDLE: begin
                            // All bursts done — stay idle until next cfg_fire
                        end
                        default: begin
                            write_state_r <= WR_BURST_CAPTURE;
                        end
                    endcase
                end
            end
        end

        // --------------------------------------------------------
        // HBM request/response mux
        // --------------------------------------------------------
        assign hbm_req_ready = hbm_req_rw ? wr_req_ready : rd_req_ready;

        assign hbm_rsp_valid = burst_rsp_valid_r;
        assign hbm_rsp_data  = burst_rsp_data_r;
        assign hbm_rsp_tag   = burst_rsp_tag_r;

        // --------------------------------------------------------
        // AXI write channel: burst logic only
        // --------------------------------------------------------
        wire burst_aw_valid_w = (write_state_r == WR_BURST_AW)
                             && (burst_wr_issue_group_r < GROUP_IDX_W'(READ_BURST_GROUPS))
                             && (burst_wr_group_count_r[burst_wr_issue_group_r[GSEL_W-1:0]] != 0);

        assign axi_m[ch].aw_valid   = burst_aw_valid_w;
        assign axi_m[ch].aw_addr    = burst_wr_group_base_addr_r[burst_wr_issue_group_r[GSEL_W-1:0]];
        assign axi_m[ch].aw_id      = '0;
        assign axi_m[ch].aw_len     = 8'(burst_wr_group_count_r[burst_wr_issue_group_r[GSEL_W-1:0]]) - 8'd1;
        assign axi_m[ch].aw_size    = 3'(LOG2_DATA_SIZE);
        assign axi_m[ch].aw_burst   = 2'b01;
        assign axi_m[ch].aw_lock    = 1'b0;
        assign axi_m[ch].aw_cache   = 4'b0000;
        assign axi_m[ch].aw_prot    = 3'b000;
        assign axi_m[ch].aw_qos     = 4'b0000;
        assign axi_m[ch].aw_region  = 4'b0000;
        assign axi_m[ch].aw_atop    = '0;
        assign axi_m[ch].aw_user    = '0;

        assign axi_m[ch].w_valid    = (write_state_r == WR_BURST_W);
        assign axi_m[ch].w_data     = burst_wr_window_data_r[burst_wr_word_idx];
        assign axi_m[ch].w_strb     = burst_wr_window_byteen_r[burst_wr_word_idx];
        assign axi_m[ch].w_last     = (burst_wr_issue_beat_r + BEAT_IDX_W'(1) >= burst_wr_group_count_r[burst_wr_issue_group_r[GSEL_W-1:0]]);
        assign axi_m[ch].w_user     = '0;

        // B can be accepted while AW/W are still issuing (pipeline B drain)
        assign axi_m[ch].b_ready    = (write_state_r != WR_IDLE)
                                    && (write_state_r != WR_BURST_CAPTURE)
                                    && (burst_wr_recv_group_r < GROUP_IDX_W'(READ_BURST_GROUPS));

        // --------------------------------------------------------
        // AXI read channel: burst logic only
        // --------------------------------------------------------
        assign axi_m[ch].ar_valid   = (read_state_r == RD_BURST_ACTIVE)
                                    && (burst_issue_group_r < GROUP_IDX_W'(READ_BURST_GROUPS))
                                    && (burst_group_count_r[burst_issue_group_r[GSEL_W-1:0]] != 0);
        assign axi_m[ch].ar_addr    = burst_group_base_addr_r[burst_issue_group_r[GSEL_W-1:0]];
        assign axi_m[ch].ar_id      = '0;
        assign axi_m[ch].ar_len     = 8'(burst_group_count_r[burst_issue_group_r[GSEL_W-1:0]]) - 8'd1;
        assign axi_m[ch].ar_size    = 3'(LOG2_DATA_SIZE);
        assign axi_m[ch].ar_burst   = 2'b01;
        assign axi_m[ch].ar_lock    = 1'b0;
        assign axi_m[ch].ar_cache   = 4'b0000;
        assign axi_m[ch].ar_prot    = 3'b000;
        assign axi_m[ch].ar_qos     = 4'b0000;
        assign axi_m[ch].ar_region  = 4'b0000;
        assign axi_m[ch].ar_user    = '0;

        assign axi_m[ch].r_ready    = (read_state_r == RD_BURST_ACTIVE)
                                    && (burst_recv_group_r < GROUP_IDX_W'(READ_BURST_GROUPS));

`ifdef DBG_TRACE_GEMM
        // --------------------------------------------------------
        // Per-channel state / handshake trace for hang diagnosis.
        // Logs each read/write FSM transition, burst group pointer
        // movement, and done_if rising edge. Use to locate which
        // channel or phase fails to drain when TMEM_DMA_CTRL is
        // stuck in S_WAIT_DONE.
        // --------------------------------------------------------
        read_state_t         prev_read_state_r;
        write_state_t        prev_write_state_r;
        logic [GROUP_IDX_W-1:0] prev_burst_issue_group_r;
        logic [GROUP_IDX_W-1:0] prev_burst_recv_group_r;
        logic [GROUP_IDX_W-1:0] prev_burst_wr_issue_group_r;
        logic [GROUP_IDX_W-1:0] prev_burst_wr_recv_group_r;
        logic                prev_done_valid;
        logic                prev_internal_done_valid;

        always @(posedge clk) begin
            if (reset) begin
                prev_read_state_r           <= RD_BURST_CAPTURE;
                prev_write_state_r          <= WR_IDLE;
                prev_burst_issue_group_r    <= '0;
                prev_burst_recv_group_r     <= '0;
                prev_burst_wr_issue_group_r <= '0;
                prev_burst_wr_recv_group_r  <= '0;
                prev_done_valid             <= 1'b0;
                prev_internal_done_valid    <= 1'b0;
            end else begin
                prev_read_state_r           <= read_state_r;
                prev_write_state_r          <= write_state_r;
                prev_burst_issue_group_r    <= burst_issue_group_r;
                prev_burst_recv_group_r     <= burst_recv_group_r;
                prev_burst_wr_issue_group_r <= burst_wr_issue_group_r;
                prev_burst_wr_recv_group_r  <= burst_wr_recv_group_r;
                prev_done_valid             <= done_if[ch].valid;
                prev_internal_done_valid    <= internal_done_if.valid;

                if (read_state_r != prev_read_state_r) begin
                    `TRACE(1, ("%t: %s ch=%0d read_state: %0d -> %0d (iss_grp=%0d recv_grp=%0d recv_beat=%0d served=%0d)\n",
                        $time, INSTANCE_ID, ch,
                        prev_read_state_r, read_state_r,
                        burst_issue_group_r, burst_recv_group_r,
                        burst_recv_beat_r, burst_words_served_r))
                end

                if (write_state_r != prev_write_state_r) begin
                    `TRACE(1, ("%t: %s ch=%0d write_state: %0d -> %0d (iss_grp=%0d iss_beat=%0d recv_grp=%0d captured=%0d)\n",
                        $time, INSTANCE_ID, ch,
                        prev_write_state_r, write_state_r,
                        burst_wr_issue_group_r, burst_wr_issue_beat_r,
                        burst_wr_recv_group_r, burst_wr_words_captured_r))
                end

                if (burst_issue_group_r != prev_burst_issue_group_r) begin
                    `TRACE(2, ("%t: %s ch=%0d rd.issue_group: %0d -> %0d (state=%0d ar_ready=%0b)\n",
                        $time, INSTANCE_ID, ch,
                        prev_burst_issue_group_r, burst_issue_group_r,
                        read_state_r, axi_m[ch].ar_ready))
                end

                if (burst_recv_group_r != prev_burst_recv_group_r) begin
                    `TRACE(2, ("%t: %s ch=%0d rd.recv_group: %0d -> %0d (state=%0d r_valid=%0b r_last=%0b)\n",
                        $time, INSTANCE_ID, ch,
                        prev_burst_recv_group_r, burst_recv_group_r,
                        read_state_r, axi_m[ch].r_valid, axi_m[ch].r_last))
                end

                if (burst_wr_issue_group_r != prev_burst_wr_issue_group_r) begin
                    `TRACE(2, ("%t: %s ch=%0d wr.issue_group: %0d -> %0d (state=%0d aw_ready=%0b)\n",
                        $time, INSTANCE_ID, ch,
                        prev_burst_wr_issue_group_r, burst_wr_issue_group_r,
                        write_state_r, axi_m[ch].aw_ready))
                end

                if (burst_wr_recv_group_r != prev_burst_wr_recv_group_r) begin
                    `TRACE(2, ("%t: %s ch=%0d wr.recv_group: %0d -> %0d (state=%0d b_valid=%0b b_ready=%0b)\n",
                        $time, INSTANCE_ID, ch,
                        prev_burst_wr_recv_group_r, burst_wr_recv_group_r,
                        write_state_r, axi_m[ch].b_valid, axi_m[ch].b_ready))
                end

                if (internal_done_if.valid && !prev_internal_done_valid) begin
                    `TRACE(1, ("%t: %s ch=%0d internal_done ASSERT (entry_id=%0d, ready=%0b, write_state=%0d)\n",
                        $time, INSTANCE_ID, ch,
                        internal_done_if.entry_id, internal_done_if.ready,
                        write_state_r))
                end

                if (done_if[ch].valid && !prev_done_valid) begin
                    `TRACE(1, ("%t: %s ch=%0d done_if ASSERT (entry_id=%0d, ready=%0b, internal_valid=%0b)\n",
                        $time, INSTANCE_ID, ch,
                        done_if[ch].entry_id, done_if[ch].ready,
                        internal_done_if.valid))
                end

                // Burst window setup: counts/addresses decided when a new
                // read burst kicks off. Verifies `calc_group_words` result
                // and first base address.
                if (rd_req_valid && rd_req_ready && !burst_prefetch_started_r) begin
                    `TRACE(1, ("%t: %s ch=%0d BURST_START window_words=%0d GROUPS=%0d base=0x%0h remaining=%0d\n",
                        $time, INSTANCE_ID, ch, burst_window_words,
                        READ_BURST_GROUPS,
                        hbm_req_byte_addr, burst_words_remaining))
                    for (int gi = 0; gi < READ_BURST_GROUPS; ++gi) begin
                        `TRACE(2, ("%t: %s ch=%0d   group[%0d] words=%0d\n",
                            $time, INSTANCE_ID, ch, gi, burst_group_words[gi]))
                    end
                end

                // Every AR fired to HBM with its programmed ar_len.
                // Use with BURST_START to confirm ar_len == group_count-1.
                if (axi_m[ch].ar_valid && axi_m[ch].ar_ready) begin
                    `TRACE(1, ("%t: %s ch=%0d AR_FIRE addr=0x%0h len=%0d group=%0d count=%0d\n",
                        $time, INSTANCE_ID, ch, axi_m[ch].ar_addr, axi_m[ch].ar_len,
                        burst_issue_group_r,
                        burst_group_count_r[burst_issue_group_r[GSEL_W-1:0]]))
                end

                // Every AXI R-channel handshake the channel actually
                // accepts. If the number of R_FIRE events does not match
                // (sum of counts for this burst), beats are being lost or
                // gated by r_ready upstream.
                if (axi_r_fire) begin
                    `TRACE(1, ("%t: %s ch=%0d R_FIRE recv_grp=%0d recv_beat=%0d count[grp]=%0d r_last=%0b\n",
                        $time, INSTANCE_ID, ch,
                        burst_recv_group_r, burst_recv_beat_r,
                        burst_group_count_r[burst_recv_group_r[GSEL_W-1:0]],
                        axi_m[ch].r_last))
                end
            end
        end
`endif

    end // g_channel

    `UNUSED_PARAM (AXI_USER_WIDTH)

endmodule
