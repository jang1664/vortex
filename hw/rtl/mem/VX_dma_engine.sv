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

// VX_dma_engine (passthrough FSM, burst-reorder free)
//  Multi-channel DMA engine bridging HBM (AXI) and TMEM (VX_mem_bus_if).
//  Each channel instantiates VX_dma_unit_misal for the 3D strided FSM.
//
//  Phase 2 of the dma-burst-reorder refactor. Upstream (VX_gemm_tmem_dma_ctrl)
//  emits 2D descriptors whose inner dim (BND0) is the AXI burst length in
//  beats and whose outer dim (BND1) walks HBM banks. This engine therefore
//  streams requests directly onto the AXI channel with no reordering:
//   - First beat of a burst (beat_cnt == 0): launch AR/AW with
//       ar_len = aw_len = burst_len_r - 1 and the VX_mem_remap'd byte address.
//   - Subsequent beats: push req tag into rsp_tag_fifo (reads) or drive W
//       data (writes). w_last fires on beat_cnt == burst_len_r - 1.
//   - Done is gated until every issued AW has a matching B response.

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

    // Burst sizing. `BND0` carries the number of AXI beats per burst. A single
    // AXI INCR burst may not cross a 4KB boundary, so the absolute ceiling is
    // `MAX_BEATS_PER_BURST` = 4096 / BEAT_SIZE.
    localparam int BLOCK_SIZE_B         = `MEM_BLOCK_SIZE;
    localparam int BLOCK_SHIFT          = `CLOG2(BLOCK_SIZE_B);
    localparam int MAX_BEATS_PER_BURST  = 4096 / DATA_SIZE;
    localparam int BURST_LEN_W          = `CLOG2(MAX_BEATS_PER_BURST + 1);
    // Depth of the outstanding-request bookkeeping.
    //   RSP_TAG_FIFO_DEPTH — one tag per outstanding R beat. Sized to cover a
    //                        full burst so reads never stall waiting for tag
    //                        FIFO room.
    //   MAX_OUTSTANDING_WR — maximum number of write bursts whose B response
    //                        has not yet drained. Power of two for fifo-like
    //                        bookkeeping; 8 is plenty for current AXI masters.
    localparam int RSP_TAG_FIFO_DEPTH   = MAX_BEATS_PER_BURST;   // e.g. 64
    localparam int MAX_OUTSTANDING_WR   = 8;
    localparam int OUTSTANDING_W        = `CLOG2(MAX_OUTSTANDING_WR + 2);

    // Runtime guard — engine assumes interleaved HBM remap. Non-interleave
    // path is broken (VX_mem_remap has no identity bypass) and must fail fast.
`ifdef SIMULATION
    initial begin
        if (`PLATFORM_MEMORY_INTERLEAVE == 0)
            $fatal(1, "VX_dma_engine: PLATFORM_MEMORY_INTERLEAVE=0 not supported");
    end
`endif

    for (genvar ch = 0; ch < NUM_CHANNELS; ++ch) begin : g_channel

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
        //   done gated by write-B drain
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
        // Descriptor latch — BND0 carries the AXI burst length (in beats).
        // --------------------------------------------------------
        wire cfg_fire = cfg_reg_if[ch].valid && cfg_reg_if[ch].ready;

        logic [BURST_LEN_W-1:0] burst_len_r;

        // --------------------------------------------------------
        // Per-direction beat counters and write AW bookkeeping
        // --------------------------------------------------------
        logic [BURST_LEN_W-1:0]     rd_beat_cnt_r;
        logic [BURST_LEN_W-1:0]     wr_beat_cnt_r;

        // Write-side: AW and W are decoupled handshakes. AXI spec forbids
        // `valid` depending on `ready`, so we register a per-burst "AW done"
        // flag and only retire the req after both AW and W have handshook.
        //   wr_aw_done_r : set when AW fires, cleared on req accept of first
        //                  beat — i.e., once the first-beat W has also fired.
        logic                       wr_aw_done_r;
        logic [OUTSTANDING_W-1:0]   aw_outstanding_r;
        logic [OUTSTANDING_W-1:0]   b_drained_r;

        // --------------------------------------------------------
        // Response tag FIFO (reads only)
        //   Push: every read req_fire
        //   Pop : every axi.r_fire forwarded as rsp
        // --------------------------------------------------------
        wire                        rsp_tag_fifo_push;
        wire                        rsp_tag_fifo_pop;
        wire                        rsp_tag_fifo_full;
        wire                        rsp_tag_fifo_empty;
        wire [TAG_WIDTH-1:0]        rsp_tag_fifo_dout;

        VX_fifo_queue #(
            .DATAW    (TAG_WIDTH),
            .DEPTH    (RSP_TAG_FIFO_DEPTH),
            .ALM_FULL (RSP_TAG_FIFO_DEPTH - 1),
            .OUT_REG  (0)
        ) u_rsp_tag_fifo (
            .clk       (clk),
            .reset     (reset),
            .push      (rsp_tag_fifo_push),
            .pop       (rsp_tag_fifo_pop),
            .data_in   (hbm_req_tag),
            .data_out  (rsp_tag_fifo_dout),
            .empty     (rsp_tag_fifo_empty),
            .alm_empty (),
            .full      (rsp_tag_fifo_full),
            .alm_full  (),
            .size      ()
        );

        // --------------------------------------------------------
        // Request gating
        //   Split req_valid by direction then gate each on the cost we need
        //   to pay for that first beat.
        // --------------------------------------------------------
        wire rd_req_valid = hbm_req_valid && ~hbm_req_rw;
        wire wr_req_valid = hbm_req_valid &&  hbm_req_rw;

        // For reads: the first beat of a new burst must fire AR; downstream
        // beats just push into the tag FIFO. In all cases we need the tag
        // FIFO to have room.
        wire rd_first_beat = (rd_beat_cnt_r == '0);
        wire rd_req_ready  = (~rsp_tag_fifo_full)
                           && (rd_first_beat ? axi_m[ch].ar_ready : 1'b1);

        // For writes: issue AW strictly before the first W beat, to avoid
        // any AXI valid→ready cross-channel dependency. The flow per burst:
        //   1. First-beat req is blocked by wr_req_ready=0 until AW fires
        //      (wr_aw_done_r set next cycle).
        //   2. All W beats (including the first) stream once AW has handshook;
        //      req_ready follows w_ready only.
        wire wr_first_beat       = (wr_beat_cnt_r == '0);
        wire wr_outstanding_room = (aw_outstanding_r - b_drained_r)
                                  < OUTSTANDING_W'(MAX_OUTSTANDING_WR);
        wire wr_req_ready        = wr_first_beat
                                 ? (wr_aw_done_r && axi_m[ch].w_ready)
                                 : axi_m[ch].w_ready;

        assign hbm_req_ready = hbm_req_rw ? wr_req_ready : rd_req_ready;

        wire rd_req_fire = rd_req_valid && rd_req_ready;
        wire wr_req_fire = wr_req_valid && wr_req_ready;
        wire rd_last_beat_fire = rd_req_fire
                               && (rd_beat_cnt_r == (burst_len_r - BURST_LEN_W'(1)));
        wire wr_last_beat_fire = wr_req_fire
                               && (wr_beat_cnt_r == (burst_len_r - BURST_LEN_W'(1)));

        // --------------------------------------------------------
        // Response forwarding (reads)
        //   Upstream sees the R beat directly — tag paired from the FIFO.
        // --------------------------------------------------------
        wire axi_r_fire = axi_m[ch].r_valid && axi_m[ch].r_ready;
        assign hbm_rsp_valid      = axi_m[ch].r_valid && ~rsp_tag_fifo_empty;
        assign hbm_rsp_data       = axi_m[ch].r_data;
        assign hbm_rsp_tag        = rsp_tag_fifo_dout;
        assign axi_m[ch].r_ready  = hbm_rsp_ready && ~rsp_tag_fifo_empty;

        assign rsp_tag_fifo_push  = rd_req_fire;
        assign rsp_tag_fifo_pop   = axi_r_fire;

        // --------------------------------------------------------
        // Done gate — hold done until every outstanding B has drained.
        // --------------------------------------------------------
        wire wr_drain_complete = (aw_outstanding_r == b_drained_r);

        assign done_if[ch].valid      = internal_done_if.valid & wr_drain_complete;
        assign done_if[ch].entry_id   = internal_done_if.entry_id;
        assign internal_done_if.ready = done_if[ch].ready     & wr_drain_complete;

        // --------------------------------------------------------
        // Descriptor shape assertions (burst-mode invariant)
        // --------------------------------------------------------
    `ifdef SIMULATION
        wire cfg_is_read = ~cfg_reg_if[ch].regs[DMA_R_DIR][0];
        always_ff @(posedge clk) begin
            if (!reset && cfg_fire) begin
                if (cfg_is_read) begin
                    assert (cfg_reg_if[ch].regs[DMA_R_SEG_SIZE] == 32'(`MEM_BLOCK_SIZE)
                         && cfg_reg_if[ch].regs[DMA_R_PAD]      == 32'd0
                         && cfg_reg_if[ch].regs[DMA_R_BND2]     == 32'd1
                         && cfg_reg_if[ch].regs[DMA_R_SRC_ST2]  == 32'd0
                         && cfg_reg_if[ch].regs[DMA_R_DST_ST2]  == 32'd0
                         && cfg_reg_if[ch].regs[DMA_R_SRC_BASE_LO][BLOCK_SHIFT-1:0] == '0
                         && cfg_reg_if[ch].regs[DMA_R_BND0] != 32'd0
                         && cfg_reg_if[ch].regs[DMA_R_BND0] <= 32'(MAX_BEATS_PER_BURST))
                    else $fatal(1, "%m: bad read DMA descriptor (ch=%0d): BND0=%0d BND2=%0d SEG=%0d PAD=%0d",
                                ch, cfg_reg_if[ch].regs[DMA_R_BND0],
                                cfg_reg_if[ch].regs[DMA_R_BND2],
                                cfg_reg_if[ch].regs[DMA_R_SEG_SIZE],
                                cfg_reg_if[ch].regs[DMA_R_PAD]);
                end else begin
                    assert (cfg_reg_if[ch].regs[DMA_R_SEG_SIZE] == 32'(`MEM_BLOCK_SIZE)
                         && cfg_reg_if[ch].regs[DMA_R_PAD]      == 32'd0
                         && cfg_reg_if[ch].regs[DMA_R_BND2]     == 32'd1
                         && cfg_reg_if[ch].regs[DMA_R_SRC_ST2]  == 32'd0
                         && cfg_reg_if[ch].regs[DMA_R_DST_ST2]  == 32'd0
                         && cfg_reg_if[ch].regs[DMA_R_DST_BASE_LO][BLOCK_SHIFT-1:0] == '0
                         && cfg_reg_if[ch].regs[DMA_R_BND0] != 32'd0
                         && cfg_reg_if[ch].regs[DMA_R_BND0] <= 32'(MAX_BEATS_PER_BURST))
                    else $fatal(1, "%m: bad write DMA descriptor (ch=%0d): BND0=%0d BND2=%0d SEG=%0d PAD=%0d",
                                ch, cfg_reg_if[ch].regs[DMA_R_BND0],
                                cfg_reg_if[ch].regs[DMA_R_BND2],
                                cfg_reg_if[ch].regs[DMA_R_SEG_SIZE],
                                cfg_reg_if[ch].regs[DMA_R_PAD]);
                end
            end
        end
    `endif

        // --------------------------------------------------------
        // AXI 4KB boundary assertions (runtime)
        // --------------------------------------------------------
    `ifdef SIMULATION
        always_ff @(posedge clk) begin
            if (!reset && axi_m[ch].ar_valid && axi_m[ch].ar_ready) begin
                logic [AXI_ADDR_WIDTH-1:0] ar_last;
                ar_last = axi_m[ch].ar_addr
                        + (AXI_ADDR_WIDTH'(axi_m[ch].ar_len) << LOG2_DATA_SIZE);
                assert (axi_m[ch].ar_addr[AXI_ADDR_WIDTH-1:12]
                        == ar_last[AXI_ADDR_WIDTH-1:12])
                    else $fatal(1, "%m: ch=%0d AR crosses 4KB boundary: addr=0x%0h len=%0d",
                                ch, axi_m[ch].ar_addr, axi_m[ch].ar_len);
            end
            if (!reset && axi_m[ch].aw_valid && axi_m[ch].aw_ready) begin
                logic [AXI_ADDR_WIDTH-1:0] aw_last;
                aw_last = axi_m[ch].aw_addr
                        + (AXI_ADDR_WIDTH'(axi_m[ch].aw_len) << LOG2_DATA_SIZE);
                assert (axi_m[ch].aw_addr[AXI_ADDR_WIDTH-1:12]
                        == aw_last[AXI_ADDR_WIDTH-1:12])
                    else $fatal(1, "%m: ch=%0d AW crosses 4KB boundary: addr=0x%0h len=%0d",
                                ch, axi_m[ch].aw_addr, axi_m[ch].aw_len);
            end
        end
    `endif

        // --------------------------------------------------------
        // Sequential FSM
        // --------------------------------------------------------
        always_ff @(posedge clk) begin
            if (reset) begin
                burst_len_r      <= '0;
                rd_beat_cnt_r    <= '0;
                wr_beat_cnt_r    <= '0;
                wr_aw_done_r     <= 1'b0;
                aw_outstanding_r <= '0;
                b_drained_r      <= '0;
            end else begin
                if (cfg_fire) begin
                    // Treat BND0 as-is: ctrl always emits beats-per-burst.
                    burst_len_r      <= cfg_reg_if[ch].regs[DMA_R_BND0][BURST_LEN_W-1:0];
                    rd_beat_cnt_r    <= '0;
                    wr_beat_cnt_r    <= '0;
                    wr_aw_done_r     <= 1'b0;
                    aw_outstanding_r <= '0;
                    b_drained_r      <= '0;
                end else begin
                    // ------------------------------
                    // Read path (beat counter + AR done via req_fire)
                    // ------------------------------
                    if (rd_req_fire) begin
                        if (rd_last_beat_fire)
                            rd_beat_cnt_r <= '0;
                        else
                            rd_beat_cnt_r <= rd_beat_cnt_r + BURST_LEN_W'(1);
                    end

                    // ------------------------------
                    // Write path
                    //   wr_aw_done_r gates the first-beat W until AW handshakes.
                    //   Cleared on wr_last_beat_fire so the next burst starts
                    //   fresh (awaits its own AW handshake).
                    // ------------------------------
                    if (axi_m[ch].aw_valid && axi_m[ch].aw_ready) begin
                        wr_aw_done_r <= 1'b1;
                    end
                    if (wr_req_fire) begin
                        if (wr_last_beat_fire) begin
                            wr_beat_cnt_r    <= '0;
                            wr_aw_done_r     <= 1'b0;
                            aw_outstanding_r <= aw_outstanding_r + OUTSTANDING_W'(1);
                        end else begin
                            wr_beat_cnt_r <= wr_beat_cnt_r + BURST_LEN_W'(1);
                        end
                    end

                    // B drain (independent of W issue)
                    if (axi_m[ch].b_valid && axi_m[ch].b_ready) begin
                        b_drained_r <= b_drained_r + OUTSTANDING_W'(1);
                    end
                end
            end
        end

        // --------------------------------------------------------
        // AXI AR drive (reads)
        //   First beat of a burst: assert ar_valid (address supplied from the
        //   remap port). AXI spec forbids valid depending on ready, so we do
        //   NOT gate ar_valid on ar_ready — the first-beat req_ready instead
        //   gates on ar_ready so the req is retired on the same cycle as AR
        //   fires.
        // --------------------------------------------------------
        assign axi_m[ch].ar_valid  = rd_req_valid && rd_first_beat
                                   && ~rsp_tag_fifo_full;
        assign axi_m[ch].ar_addr   = hbm_req_remap_byte_addr;
        assign axi_m[ch].ar_id     = '0;
        assign axi_m[ch].ar_len    = 8'(burst_len_r - BURST_LEN_W'(1));
        assign axi_m[ch].ar_size   = 3'(LOG2_DATA_SIZE);
        assign axi_m[ch].ar_burst  = 2'b01;
        assign axi_m[ch].ar_lock   = 1'b0;
        assign axi_m[ch].ar_cache  = 4'b0000;
        assign axi_m[ch].ar_prot   = 3'b000;
        assign axi_m[ch].ar_qos    = 4'b0000;
        assign axi_m[ch].ar_region = 4'b0000;
        assign axi_m[ch].ar_user   = '0;

        // --------------------------------------------------------
        // AXI AW / W drive (writes)
        //   AW asserted only on the first beat, and only until it handshakes
        //   (wr_aw_done_r latches the handshake). W asserted on every beat.
        //   Neither valid depends on the opposite ready, so AW/W can complete
        //   in any order. wr_outstanding_room gates AW so we never overflow
        //   our B counter.
        // --------------------------------------------------------
        assign axi_m[ch].aw_valid  = wr_req_valid && wr_first_beat
                                   && ~wr_aw_done_r
                                   && wr_outstanding_room;
        assign axi_m[ch].aw_addr   = hbm_req_remap_byte_addr;
        assign axi_m[ch].aw_id     = '0;
        assign axi_m[ch].aw_len    = 8'(burst_len_r - BURST_LEN_W'(1));
        assign axi_m[ch].aw_size   = 3'(LOG2_DATA_SIZE);
        assign axi_m[ch].aw_burst  = 2'b01;
        assign axi_m[ch].aw_lock   = 1'b0;
        assign axi_m[ch].aw_cache  = 4'b0000;
        assign axi_m[ch].aw_prot   = 3'b000;
        assign axi_m[ch].aw_qos    = 4'b0000;
        assign axi_m[ch].aw_region = 4'b0000;
        assign axi_m[ch].aw_atop   = '0;
        assign axi_m[ch].aw_user   = '0;

        // W: gated by wr_aw_done_r on the first beat so AW is strictly issued
        // before the first W beat. wr_aw_done_r is a registered flag (no
        // combinational dependency on ready), satisfying AXI valid→ready
        // independence.
        assign axi_m[ch].w_valid   = wr_req_valid
                                   && (~wr_first_beat || wr_aw_done_r);
        assign axi_m[ch].w_data    = hbm_req_data;
        assign axi_m[ch].w_strb    = hbm_req_byteen;
        assign axi_m[ch].w_last    = (wr_beat_cnt_r == (burst_len_r - BURST_LEN_W'(1)));
        assign axi_m[ch].w_user    = '0;

        assign axi_m[ch].b_ready   = 1'b1;

`ifdef DBG_TRACE_GEMM
        // --------------------------------------------------------
        // Trace — new passthrough FSM. Logs burst_len latch, AR/AW fire,
        // each R/W beat, and B drain for post-mortem of any hang.
        // --------------------------------------------------------
        logic                       prev_done_valid;
        logic                       prev_internal_done_valid;

        always @(posedge clk) begin
            if (reset) begin
                prev_done_valid          <= 1'b0;
                prev_internal_done_valid <= 1'b0;
            end else begin
                prev_done_valid          <= done_if[ch].valid;
                prev_internal_done_valid <= internal_done_if.valid;

                if (cfg_fire) begin
                    `TRACE(1, ("%t: %s ch=%0d CFG_FIRE burst_len=%0d dir=%0d\n",
                        $time, INSTANCE_ID, ch,
                        cfg_reg_if[ch].regs[DMA_R_BND0],
                        cfg_reg_if[ch].regs[DMA_R_DIR][0]))
                end

                if (axi_m[ch].ar_valid && axi_m[ch].ar_ready) begin
                    `TRACE(1, ("%t: %s ch=%0d AR_FIRE addr=0x%0h len=%0d beat_cnt=%0d\n",
                        $time, INSTANCE_ID, ch,
                        axi_m[ch].ar_addr, axi_m[ch].ar_len, rd_beat_cnt_r))
                end

                if (axi_r_fire) begin
                    `TRACE(1, ("%t: %s ch=%0d R_FIRE beat_cnt=%0d r_last=%0b tag=0x%0h\n",
                        $time, INSTANCE_ID, ch,
                        rd_beat_cnt_r, axi_m[ch].r_last, rsp_tag_fifo_dout))
                end

                if (axi_m[ch].aw_valid && axi_m[ch].aw_ready) begin
                    `TRACE(1, ("%t: %s ch=%0d AW_FIRE addr=0x%0h len=%0d beat_cnt=%0d\n",
                        $time, INSTANCE_ID, ch,
                        axi_m[ch].aw_addr, axi_m[ch].aw_len, wr_beat_cnt_r))
                end

                if (axi_m[ch].w_valid && axi_m[ch].w_ready) begin
                    `TRACE(2, ("%t: %s ch=%0d W_FIRE beat_cnt=%0d w_last=%0b strb=0x%0h\n",
                        $time, INSTANCE_ID, ch,
                        wr_beat_cnt_r, axi_m[ch].w_last, axi_m[ch].w_strb))
                end

                if (axi_m[ch].b_valid && axi_m[ch].b_ready) begin
                    `TRACE(1, ("%t: %s ch=%0d B_FIRE b_drained=%0d aw_outstanding=%0d\n",
                        $time, INSTANCE_ID, ch,
                        b_drained_r + OUTSTANDING_W'(1), aw_outstanding_r))
                end

                if (internal_done_if.valid && !prev_internal_done_valid) begin
                    `TRACE(1, ("%t: %s ch=%0d internal_done ASSERT (entry_id=%0d, ready=%0b, aw_out=%0d, b_drain=%0d)\n",
                        $time, INSTANCE_ID, ch,
                        internal_done_if.entry_id, internal_done_if.ready,
                        aw_outstanding_r, b_drained_r))
                end

                if (done_if[ch].valid && !prev_done_valid) begin
                    `TRACE(1, ("%t: %s ch=%0d done_if ASSERT (entry_id=%0d, ready=%0b, internal_valid=%0b)\n",
                        $time, INSTANCE_ID, ch,
                        done_if[ch].entry_id, done_if[ch].ready,
                        internal_done_if.valid))
                end
            end
        end
`endif

    end // g_channel

    `UNUSED_PARAM (AXI_USER_WIDTH)

endmodule
