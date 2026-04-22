// VX_gemm_tmem_dma_ctrl
//
// DMA controller for TMEM subsystem. Translates GEMM DMA commands
// into VX_config_reg_if writes for the 8-channel DMA engine.
// Decomposes at bus-word (64B) granularity: channels with fewer words
// get smaller seg_size; channels with no words are inactive.

`include "VX_define.vh"

module VX_gemm_tmem_dma_ctrl import VX_gpu_pkg::*; #(
    parameter `STRING INSTANCE_ID = "",
    parameter NUM_CHANNELS = 8,
    parameter ENTRYID_W    = `JOB_MMIO_ENTRYID_W
) (
    input wire clk,
    input wire reset,

    // From gemm_ctrl (commands)
    VX_gemm_dma_ctrl_if.slave  gemm_dma_ctrl_if,

    // To gemm_sync (notify completion)
    VX_gemm_sync_if.master     gemm_sync_if,

    // To DMA engine config registers (all channels active)
    VX_config_reg_if.master    cfg_reg_if [NUM_CHANNELS],

    // From DMA engine done signals
    VX_node_done_if.slave      done_if [NUM_CHANNELS]
);

    // =========================================================
    // Register indices (same layout as VX_gemm_dma_ctrl / VX_dma_unit_misal)
    // =========================================================
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
    localparam int DMA_R_RSVD        = 17;

    localparam int NUM_REGS = `DMA_CFG_REG_NUM;

    // =========================================================
    // Burst geometry (interleave mode only)
    // See agent-tasks/dma-burst-reorder/plan.md §Design for derivation.
    // 3D descriptor: i0=beat within sub-burst (inner, one AXI INCR burst),
    //                i1=sub-burst within bank (mid),
    //                i2=bank within channel (outer).
    // Sub-burst size S is computed per-channel as the largest power-of-2
    // that divides both bank_off_beats and total_beats_per_bank, capped at
    // MAX_BEATS_PER_BURST (= 64). This guarantees every AXI burst stays
    // within a 4KB boundary even when the HBM base offset is non-aligned
    // modulo 4KB.
    //
    // NUM_BURST_GROUPS uses a `MAX(1, ...)` guard so that degenerate
    // configs (PLATFORM_MEMORY_NUM_BANKS < NUM_CHANNELS) do not trigger
    // a div-by-zero at elaboration. Such configs are explicitly guarded
    // by the initial block below and are invalid for this form.
    // =========================================================
    localparam int RAW_BURST_GROUPS    = `PLATFORM_MEMORY_NUM_BANKS / NUM_CHANNELS;
    localparam int NUM_BURST_GROUPS    = (RAW_BURST_GROUPS > 0) ? RAW_BURST_GROUPS : 1;
    localparam int BEAT_STRIDE_HBM_B   = `PLATFORM_MEMORY_INTERLEAVE
                                         ? (`PLATFORM_MEMORY_NUM_BANKS * `MEM_BLOCK_SIZE)
                                         : `MEM_BLOCK_SIZE;
    localparam int BANK_STRIDE_HBM_B   = `HBM_BUS_STRIDE;
    localparam int BEAT_STRIDE_TMEM_B  = NUM_BURST_GROUPS * `MEM_BLOCK_SIZE;
    localparam int BANK_STRIDE_TMEM_B  = `MEM_BLOCK_SIZE;
    localparam int MAX_BEATS_PER_BURST = 4096 / `MEM_BLOCK_SIZE;

    // Largest power-of-2 divisor of `v`, returning `cap` if `v` is zero or
    // has no set bits within [0,6]. Range is 7 bits because the cap is 64
    // (MAX_BEATS_PER_BURST), which fits in a power-of-two ≤ 64.
    function automatic logic [6:0] pow2_div(input logic [6:0] v,
                                            input logic [6:0] cap);
        logic [6:0] result;
        logic       found;
        begin
            result = cap;
            found  = 1'b0;
            for (int b = 0; b <= 6; b++) begin
                if (!found && v[b]) begin
                    result = 7'd1 << b;
                    found  = 1'b1;
                end
            end
            return result;
        end
    endfunction

`ifndef SYNTHESIS
    initial begin
        if (`PLATFORM_MEMORY_INTERLEAVE == 0) begin
            $fatal(1, "VX_gemm_tmem_dma_ctrl: PLATFORM_MEMORY_INTERLEAVE=0 not supported (burst-reorder form requires interleave)");
        end
        if (RAW_BURST_GROUPS == 0) begin
            $fatal(1, "VX_gemm_tmem_dma_ctrl: PLATFORM_MEMORY_NUM_BANKS (%0d) must be >= NUM_CHANNELS (%0d) for burst-reorder form",
                   `PLATFORM_MEMORY_NUM_BANKS, NUM_CHANNELS);
        end
    end
`endif

    // =========================================================
    // Opcodes
    // =========================================================
    localparam logic [3:0] OP_DMA_LD = 4'd1;
    localparam logic [3:0] OP_DMA_ST = 4'd2;
    localparam logic [3:0] OP_NOTIFY = 4'd3;

    // =========================================================
    // FSM states
    // =========================================================
    typedef enum logic [2:0] {
        S_IDLE,
        S_PROG,
        S_WAIT_DONE,
        S_DONE,
        S_NOTIFY
    } state_t;

    state_t state_q, state_d;

    // =========================================================
    // Command capture register
    // =========================================================
    gemm_unified_cmd_t cmd_q;
    wire [3:0] cmd_op = cmd_q.instr[3:0];

    // =========================================================
    // Command decoding (combinational, from captured cmd_q)
    // Note: cmd_q.bound is asserted to be 1 in the new 2D burst-reorder
    // form. The legacy multi-segment path that routed it to DMA_R_BND1
    // has been removed (BND1 is now the bank dim).
    // =========================================================
    logic [63:0] src_base, dst_base;
    logic        dir_is_st;
    logic [31:0] src_s0, dst_s0;
    logic [31:0] seg_size;

    always_comb begin
        dir_is_st = 1'b0;
        src_base  = 64'd0;
        dst_base  = 64'd0;
        src_s0    = 32'd0;
        dst_s0    = 32'd0;
        seg_size  = 32'd0;

        if (cmd_op == OP_DMA_LD || cmd_op == OP_DMA_ST) begin
            dir_is_st = (cmd_op == OP_DMA_ST);
            src_base  = cmd_q.rs2_data;
            dst_base  = cmd_q.rs1_data;
            seg_size  = {4'd0, cmd_q.instr[31:4]};

            if (cmd_op == OP_DMA_LD) begin
                src_s0 = {16'd0, cmd_q.stride[31:16]};
                dst_s0 = {16'd0, cmd_q.stride[15:0]};
            end else begin
                src_s0 = {16'd0, cmd_q.stride[15:0]};
                dst_s0 = {16'd0, cmd_q.stride[31:16]};
            end
        end
    end

    // =========================================================
    // Bus-word-level decomposition
    // Distributes seg_size across channels at 64-byte bus-word
    // granularity. Channels with no words are marked inactive.
    // =========================================================
    localparam int BUS_WORD_SHIFT = `CLOG2(`MEM_BLOCK_SIZE);
    localparam int NUM_CH_SHIFT   = `CLOG2(NUM_CHANNELS);

    function automatic [63:0] tmem_bank_local_addr(input [63:0] byte_addr);
        begin
            // Remove the interleaved TMEM bank index bits while preserving the
            // byte offset within each 64B bank line.
            tmem_bank_local_addr = (byte_addr & ((64'd1 << BUS_WORD_SHIFT) - 1))
                                 | ((byte_addr >> NUM_CH_SHIFT) & ~((64'd1 << BUS_WORD_SHIFT) - 1));
        end
    endfunction

    function automatic [31:0] tmem_bank_local_stride(input [31:0] byte_stride);
        begin
            tmem_bank_local_stride = (byte_stride & ((32'd1 << BUS_WORD_SHIFT) - 1))
                                   | ((byte_stride >> NUM_CH_SHIFT) & ~((32'd1 << BUS_WORD_SHIFT) - 1));
        end
    endfunction

    // Per-channel base addresses are computed inside the genvar loop,
    // conditioned on direction (LD vs ST) to swap HBM/TMEM roles.
    wire [NUM_CH_SHIFT-1:0] start_ch = dir_is_st ? src_base[BUS_WORD_SHIFT +: NUM_CH_SHIFT]
                                                 : dst_base[BUS_WORD_SHIFT +: NUM_CH_SHIFT];

    // Seg size: decompose at 64-byte bus-word granularity
    wire [31:0] num_words  = seg_size >> BUS_WORD_SHIFT;        // total bus words
    wire [31:0] words_quot = num_words >> NUM_CH_SHIFT;          // words per channel (quotient)
    wire [2:0]  words_rem  = num_words[NUM_CH_SHIFT-1:0];       // remainder

    // =========================================================
    // Per-channel config registers and output wiring
    // =========================================================
    logic cfg_all_valid;

    logic [NUM_CHANNELS-1:0] cfg_ready_or_inactive;
    logic [NUM_CHANNELS-1:0] done_or_inactive;
    logic [NUM_CHANNELS-1:0] done_sticky;

    wire cfg_all_ready  = &cfg_ready_or_inactive;
    wire done_all_valid = &done_sticky;

    for (genvar ch = 0; ch < NUM_CHANNELS; ++ch) begin : g_channels
        wire [NUM_CH_SHIFT-1:0] logical_ch = ch - start_ch;

        // Per-channel word count: quotient + 1 if ch < remainder, else quotient
        wire [31:0] ch_words    = words_quot + ((logical_ch < words_rem) ? 32'd1 : 32'd0);
        wire        ch_active   = (ch_words != 32'd0);

        // Per-channel addresses: physical channel ch corresponds to the bank
        // selected by the starting interleaved block plus logical stripe index.
        wire [63:0] ch_src_base = dir_is_st ? tmem_bank_local_addr(src_base)
                                            : (src_base + (logical_ch << BUS_WORD_SHIFT));
        wire [63:0] ch_dst_base = dir_is_st ? (dst_base + (logical_ch << BUS_WORD_SHIFT))
                                            : tmem_bank_local_addr(dst_base);

        // HBM-side base for this channel (LD=src, ST=dst). Used for the
        // sub-burst size computation below (bank_off_beats = (hbm_base >> 11)
        // & 0x3F, i.e. bank_offset_within_4KB measured in MEM_BLOCK_SIZE beats).
        wire [63:0] ch_hbm_base = dir_is_st ? ch_dst_base : ch_src_base;
        wire [5:0]  bank_off_beats = ch_hbm_base[16:11];

        // Total beats per bank (only meaningful when burst_mode holds — i.e.,
        // ch_words is a multiple of NUM_BURST_GROUPS).
        wire [31:0] total_bpb = ch_words / 32'(NUM_BURST_GROUPS);

        // Largest power-of-2 divisor of bank_off_beats and total_bpb. cap=64
        // for bank_off_beats (when it's zero the bank is 4KB-aligned so any
        // burst size up to 64 is safe). For total_bpb the cap is 1 because
        // total_bpb can legitimately be 1 (single beat per bank) — the final
        // min() below clamps sub_burst_size to total_bpb.
        wire [6:0] s_bob  = pow2_div({1'b0, bank_off_beats}, 7'd64);
        wire [6:0] s_tbpb = pow2_div(total_bpb[6:0], 7'd1);

        // S = min(s_bob, s_tbpb); both are pow-of-2, S ≤ 64 = MAX_BEATS_PER_BURST.
        wire [6:0] sub_burst_size = (s_bob <= s_tbpb) ? s_bob : s_tbpb;

        // Burst-mode decision per channel. The 4KB safety / beat-count cap is
        // absorbed into the sub-burst size computation above, so burst_mode
        // only requires ch_words to be a multiple of NUM_BURST_GROUPS.
        wire burst_mode = (ch_words >= 32'(NUM_BURST_GROUPS))
                       && ((ch_words % 32'(NUM_BURST_GROUPS)) == 32'd0);

        // Build per-channel config registers
        logic [NUM_REGS-1:0][31:0] ch_prog_regs;
        always_comb begin
            ch_prog_regs = '0;
            ch_prog_regs[DMA_R_CONTROL]     = ch_active ? 32'd1 : 32'd0;
            ch_prog_regs[DMA_R_DST_BASE_LO] = ch_dst_base[31:0];
            ch_prog_regs[DMA_R_DST_BASE_HI] = ch_dst_base[63:32];
            ch_prog_regs[DMA_R_SRC_BASE_LO] = ch_src_base[31:0];
            ch_prog_regs[DMA_R_SRC_BASE_HI] = ch_src_base[63:32];

            // 3D: i0=beat within sub-burst (inner), i1=sub-burst within bank
            // (mid), i2=bank within channel (outer). LD: SRC=HBM, DST=TMEM.
            // ST: SRC=TMEM, DST=HBM.
            if (burst_mode) begin
                ch_prog_regs[DMA_R_BND0]    = 32'(sub_burst_size);                   // beats per AXI burst
                ch_prog_regs[DMA_R_BND1]    = total_bpb / 32'(sub_burst_size);       // sub-bursts per bank
                ch_prog_regs[DMA_R_BND2]    = 32'(NUM_BURST_GROUPS);                 // banks per channel

                // ST0: beat stride within sub-burst (same bank)
                ch_prog_regs[DMA_R_SRC_ST0] = dir_is_st ? 32'(BEAT_STRIDE_TMEM_B) : 32'(BEAT_STRIDE_HBM_B);
                ch_prog_regs[DMA_R_DST_ST0] = dir_is_st ? 32'(BEAT_STRIDE_HBM_B)  : 32'(BEAT_STRIDE_TMEM_B);

                // ST1: sub-burst stride within bank = S × beat stride
                ch_prog_regs[DMA_R_SRC_ST1] = 32'(sub_burst_size)
                                            * (dir_is_st ? 32'(BEAT_STRIDE_TMEM_B) : 32'(BEAT_STRIDE_HBM_B));
                ch_prog_regs[DMA_R_DST_ST1] = 32'(sub_burst_size)
                                            * (dir_is_st ? 32'(BEAT_STRIDE_HBM_B)  : 32'(BEAT_STRIDE_TMEM_B));

                // ST2: bank stride
                ch_prog_regs[DMA_R_SRC_ST2] = dir_is_st ? 32'(BANK_STRIDE_TMEM_B) : 32'(BANK_STRIDE_HBM_B);
                ch_prog_regs[DMA_R_DST_ST2] = dir_is_st ? 32'(BANK_STRIDE_HBM_B)  : 32'(BANK_STRIDE_TMEM_B);
            end else begin
                // Fallback: BND0 == 1, so ST0 is unused — zero it.
                // ST1 walks banks, one beat per bank. ST2 unused.
                ch_prog_regs[DMA_R_BND0]    = 32'd1;
                ch_prog_regs[DMA_R_BND1]    = ch_words;
                ch_prog_regs[DMA_R_BND2]    = 32'd1;
                ch_prog_regs[DMA_R_SRC_ST0] = 32'd0;
                ch_prog_regs[DMA_R_DST_ST0] = 32'd0;
                ch_prog_regs[DMA_R_SRC_ST1] = dir_is_st ? 32'(`MEM_BLOCK_SIZE) : 32'(`HBM_BUS_STRIDE);
                ch_prog_regs[DMA_R_DST_ST1] = dir_is_st ? 32'(`HBM_BUS_STRIDE) : 32'(`MEM_BLOCK_SIZE);
                ch_prog_regs[DMA_R_SRC_ST2] = 32'd0;
                ch_prog_regs[DMA_R_DST_ST2] = 32'd0;
            end

            ch_prog_regs[DMA_R_SEG_SIZE]    = 32'(`MEM_BLOCK_SIZE); // one bus word per beat
            ch_prog_regs[DMA_R_PAD]         = 32'd0;
            ch_prog_regs[DMA_R_DIR]         = {31'd0, dir_is_st};
            ch_prog_regs[DMA_R_RSVD]        = 32'd0;

        end

        // Config interface: only program active channels
        assign cfg_reg_if[ch].regs     = ch_prog_regs;
        assign cfg_reg_if[ch].entry_id = 32'd0;
        assign cfg_reg_if[ch].valid    = cfg_all_valid && ch_active;

        // Ready: inactive channels count as ready
        assign cfg_ready_or_inactive[ch] = ch_active ? cfg_reg_if[ch].ready : 1'b1;

        // Done: inactive channels count as done
        assign done_or_inactive[ch] = ch_active ? done_if[ch].valid : 1'b1;
        assign done_if[ch].ready = (state_q == S_WAIT_DONE || state_q == S_DONE) ? 1'b1 : 1'b0;

`ifdef DBG_TRACE_GEMM
        always_ff @(posedge clk) begin
            if (!reset && (state_q == S_PROG) && cfg_all_ready && ch_active) begin
                `TRACE(2, ("%m : [%0t] | TMEM_DMA_CTRL_PROG_CH | {inst=%s, ch=%0d, burst_mode=%0d, bob=%0d, S=%0d, bnd0=%0d, bnd1=%0d, bnd2=%0d, src_st0=%0d, src_st1=%0d, src_st2=%0d, dst_st0=%0d, dst_st1=%0d, dst_st2=%0d, ch_src_base=0x%0h, ch_dst_base=0x%0h}\n",
                          $time, INSTANCE_ID, ch, burst_mode,
                          bank_off_beats, sub_burst_size,
                          ch_prog_regs[DMA_R_BND0], ch_prog_regs[DMA_R_BND1], ch_prog_regs[DMA_R_BND2],
                          ch_prog_regs[DMA_R_SRC_ST0], ch_prog_regs[DMA_R_SRC_ST1], ch_prog_regs[DMA_R_SRC_ST2],
                          ch_prog_regs[DMA_R_DST_ST0], ch_prog_regs[DMA_R_DST_ST1], ch_prog_regs[DMA_R_DST_ST2],
                          ch_src_base, ch_dst_base))
            end
        end
`endif
    end

    // =========================================================
    // FSM outputs (active/idle/done to gemm_dma_ctrl_if)
    // =========================================================
    assign gemm_dma_ctrl_if.idle = (state_q == S_IDLE);
    assign gemm_dma_ctrl_if.done = (state_q == S_DONE);

    // =========================================================
    // FSM combinational logic
    // =========================================================
    always_comb begin
        state_d       = state_q;
        cfg_all_valid = 1'b0;

        // gemm_sync defaults
        gemm_sync_if.valid   = 1'b0;
        gemm_sync_if.reg_idx = 32'd0;
        gemm_sync_if.value   = 32'd0;

        unique case (state_q)
            S_IDLE: begin
                if (gemm_dma_ctrl_if.start) begin
                    if (gemm_dma_ctrl_if.cmd.instr[3:0] == OP_NOTIFY) begin
                        state_d = S_NOTIFY;
                    end else begin
                        state_d = S_PROG;
                    end
                end
            end

            S_PROG: begin
                cfg_all_valid = 1'b1;
                if (cfg_all_ready) begin
                    state_d = S_WAIT_DONE;
                end
            end

            S_WAIT_DONE: begin
                if (done_all_valid) begin
                    state_d = S_DONE;
                end
            end

            S_DONE: begin
                state_d = S_IDLE;
            end

            S_NOTIFY: begin
                gemm_sync_if.valid   = 1'b1;
                gemm_sync_if.reg_idx = cmd_q.rs1_data[31:0];
                gemm_sync_if.value   = cmd_q.rs2_data[31:0];
                if (gemm_sync_if.ready) begin
                    state_d = S_DONE;
                end
            end

            default: begin
                state_d = S_IDLE;
            end
        endcase
    end

`ifdef DBG_TRACE_GEMM
    function automatic string state_to_str(input state_t s);
        case (s)
            S_IDLE:      state_to_str = "S_IDLE";
            S_PROG:      state_to_str = "S_PROG";
            S_WAIT_DONE: state_to_str = "S_WAIT_DONE";
            S_DONE:      state_to_str = "S_DONE";
            S_NOTIFY:    state_to_str = "S_NOTIFY";
            default:     state_to_str = "S_UNKNOWN";
        endcase
    endfunction

    always_ff @(posedge clk) begin
        if (!reset) begin
            if (gemm_dma_ctrl_if.start) begin
                `TRACE(2, ("%m : [%0t] | TMEM_DMA_CTRL_CMD | {inst=%s, op=0x%0h, instr=0x%0h, rs1=0x%0h, rs2=0x%0h, stride=0x%0h, bound=%0d}\n",
                          $time, INSTANCE_ID, gemm_dma_ctrl_if.cmd.instr[3:0], gemm_dma_ctrl_if.cmd.instr,
                          gemm_dma_ctrl_if.cmd.rs1_data, gemm_dma_ctrl_if.cmd.rs2_data,
                          gemm_dma_ctrl_if.cmd.stride, gemm_dma_ctrl_if.cmd.bound))
            end

            if (state_q != state_d) begin
                `TRACE(2, ("%m : [%0t] | TMEM_DMA_CTRL_STATE | {inst=%s, from=%s, to=%s, op=0x%0h, seg_size=%0d, cmd_bound=%0d, src_base=0x%0h, dst_base=0x%0h, dir_is_st=%0d, start_ch=%0d, num_words=%0d}\n",
                          $time, INSTANCE_ID, state_to_str(state_q), state_to_str(state_d),
                          cmd_op, seg_size, cmd_q.bound, src_base, dst_base, dir_is_st, start_ch, num_words))
            end

            if (state_q == S_PROG && cfg_all_ready) begin
                `TRACE(2, ("%m : [%0t] | TMEM_DMA_CTRL_PROG | {inst=%s, op=0x%0h, dir_is_st=%0d, start_ch=%0d, num_words=%0d, words_quot=%0d, words_rem=%0d, cfg_ready=0x%0h}\n",
                          $time, INSTANCE_ID, cmd_op, dir_is_st, start_ch, num_words, words_quot, words_rem, cfg_ready_or_inactive))
            end

            if (state_q == S_WAIT_DONE && done_all_valid) begin
                `TRACE(2, ("%m : [%0t] | TMEM_DMA_CTRL_DONE | {inst=%s, done_mask=0x%0h}\n",
                          $time, INSTANCE_ID, done_or_inactive))
            end
        end
    end
`endif

    // =========================================================
    // Sequential logic
    // =========================================================
    always_ff @(posedge clk) begin
        if (reset) begin
            state_q     <= S_IDLE;
            cmd_q       <= '0;
            done_sticky <= '0;
        end else begin
            state_q <= state_d;
            if (state_q == S_IDLE) begin
                done_sticky <= '0;
            end else begin
                done_sticky <= done_sticky | done_or_inactive;
            end
            if (state_q == S_IDLE && gemm_dma_ctrl_if.start) begin
                cmd_q <= gemm_dma_ctrl_if.cmd;
            end
        end
    end

    // =========================================================
    // SIMULATION-only assertions
    // =========================================================
`ifndef SYNTHESIS
    always_ff @(posedge clk) begin
        if (!reset) begin
            if (gemm_dma_ctrl_if.start
                && ((gemm_dma_ctrl_if.cmd.instr[3:0] == OP_DMA_LD)
                 || (gemm_dma_ctrl_if.cmd.instr[3:0] == OP_DMA_ST))) begin
                assert (gemm_dma_ctrl_if.cmd.bound == 16'd1)
                    else $fatal(1, "%m: kernel cmd.bound=%0d > 1 is unsupported in 2D burst-reorder form",
                                gemm_dma_ctrl_if.cmd.bound);
            end
        end
    end
`endif

    // Legacy signals retained per plan (helpers stay, but s0 fields are no
    // longer routed to ST1 in the 2D burst-reorder form).
    `UNUSED_VAR (src_s0)
    `UNUSED_VAR (dst_s0)

    `UNUSED_PARAM (ENTRYID_W)
    `UNUSED_SPARAM (INSTANCE_ID)

endmodule
