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
    // =========================================================
    logic [63:0] src_base, dst_base;
    logic        dir_is_st;
    logic [31:0] src_s0, dst_s0;
    logic [31:0] bnd0;
    logic [31:0] seg_size;

    always_comb begin
        dir_is_st = 1'b0;
        src_base  = 64'd0;
        dst_base  = 64'd0;
        src_s0    = 32'd0;
        dst_s0    = 32'd0;
        bnd0      = 32'd1;
        seg_size  = 32'd0;

        if (cmd_op == OP_DMA_LD || cmd_op == OP_DMA_ST) begin
            dir_is_st = (cmd_op == OP_DMA_ST);
            src_base  = cmd_q.rs2_data;
            dst_base  = cmd_q.rs1_data;
            bnd0      = {16'd0, cmd_q.bound};
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
    localparam int BUS_WORD_SHIFT = 6;  // log2(64)
    localparam int NUM_CH_SHIFT   = 3;  // log2(8)

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

        // Build per-channel config registers
        logic [NUM_REGS-1:0][31:0] ch_prog_regs;
        always_comb begin
            ch_prog_regs = '0;
            ch_prog_regs[DMA_R_CONTROL]     = ch_active ? 32'd1 : 32'd0;
            ch_prog_regs[DMA_R_DST_BASE_LO] = ch_dst_base[31:0];
            ch_prog_regs[DMA_R_DST_BASE_HI] = ch_dst_base[63:32];
            ch_prog_regs[DMA_R_SRC_BASE_LO] = ch_src_base[31:0];
            ch_prog_regs[DMA_R_SRC_BASE_HI] = ch_src_base[63:32];
            ch_prog_regs[DMA_R_SRC_ST0]     = dir_is_st ? 32'd64  : 32'd512;  // TMEM:64, HBM:512
            ch_prog_regs[DMA_R_DST_ST0]     = dir_is_st ? 32'd512 : 32'd64;   // HBM:512, TMEM:64
            ch_prog_regs[DMA_R_SRC_ST1]     = dir_is_st ? tmem_bank_local_stride(src_s0) : src_s0;  // bank-local or full
            ch_prog_regs[DMA_R_DST_ST1]     = dir_is_st ? dst_s0 : tmem_bank_local_stride(dst_s0);  // full or bank-local
            ch_prog_regs[DMA_R_SRC_ST2]     = 32'd0;
            ch_prog_regs[DMA_R_DST_ST2]     = 32'd0;
            ch_prog_regs[DMA_R_BND0]        = ch_words;          // number of bus-word blocks for this channel
            ch_prog_regs[DMA_R_BND1]        = bnd0;              // original bnd0 from command (multi-segment)
            ch_prog_regs[DMA_R_BND2]        = 32'd1;
            ch_prog_regs[DMA_R_SEG_SIZE]    = 32'd64;            // one 64B bus word per DMA segment
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
    end

    wire cfg_all_ready  = &cfg_ready_or_inactive;
    wire done_all_valid = &done_sticky;

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
                `TRACE(2, ("%m : [%0t] | TMEM_DMA_CTRL_STATE | {inst=%s, from=%s, to=%s, op=0x%0h, seg_size=%0d, bnd0=%0d, src_base=0x%0h, dst_base=0x%0h, dir_is_st=%0d, start_ch=%0d, num_words=%0d}\n",
                          $time, INSTANCE_ID, state_to_str(state_q), state_to_str(state_d),
                          cmd_op, seg_size, bnd0, src_base, dst_base, dir_is_st, start_ch, num_words))
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

    `UNUSED_PARAM (ENTRYID_W)
    `UNUSED_SPARAM (INSTANCE_ID)

endmodule
