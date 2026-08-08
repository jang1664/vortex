// VX_gemm_tmem_dma_ctrl
//
// Multi-command HBM/TMEM DMA scheduler.  Commands are accepted into a
// priority-aware pending queue, decoded into complete per-channel descriptors,
// and issued to the existing single-context DMA engines.  Uniform all-channel
// output stores may be split at descriptor boundaries.  Loads and non-uniform
// stores always execute their captured full descriptor without preemption.

`include "VX_define.vh"

module VX_gemm_tmem_dma_ctrl import VX_gpu_pkg::*; #(
    parameter `STRING INSTANCE_ID = "",
    parameter int NUM_CHANNELS  = 8,
    parameter int ENTRYID_W     = `JOB_MMIO_ENTRYID_W,
    parameter int PENDING_DEPTH = 4
) (
    input wire clk,
    input wire reset,
`ifndef SYNTHESIS
`ifdef DBG_TRACE_GEMM
    // Exact VX_gemm_unit_v2 pipeline-active predicate, sampled only by
    // simulation observability below.  This input has no scheduling effect.
    input wire compute_active_i,
`endif
`endif

    VX_gemm_dma_ctrl_if.slave gemm_dma_ctrl_if,
    output wire               store_done,

    VX_gemm_sync_if.master    gemm_sync_if,
    VX_config_reg_if.master   cfg_reg_if [NUM_CHANNELS],
    VX_dma_lookahead_if.master lookahead_if [NUM_CHANNELS],
    VX_node_done_if.slave     done_if [NUM_CHANNELS]
);

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
    localparam int DMA_NUM_REGS      = `DMA_CFG_REG_NUM;

    localparam logic [3:0] OP_DMA_LD = 4'd1;
    localparam logic [3:0] OP_DMA_ST = 4'd2;

    localparam int RAW_BURST_GROUPS =
        `PLATFORM_MEMORY_NUM_BANKS / NUM_CHANNELS;
    localparam int NUM_BURST_GROUPS =
        (RAW_BURST_GROUPS > 0) ? RAW_BURST_GROUPS : 1;
    localparam int BEAT_STRIDE_HBM_B = `PLATFORM_MEMORY_INTERLEAVE
        ? (`PLATFORM_MEMORY_NUM_BANKS * `MEM_BLOCK_SIZE)
        : `MEM_BLOCK_SIZE;
    localparam int BANK_STRIDE_HBM_B  = `HBM_BUS_STRIDE;
    localparam int BEAT_STRIDE_TMEM_B =
        NUM_BURST_GROUPS * `MEM_BLOCK_SIZE;
    localparam int BANK_STRIDE_TMEM_B = `MEM_BLOCK_SIZE;
    localparam int BUS_WORD_SHIFT     = `CLOG2(`MEM_BLOCK_SIZE);
    localparam int NUM_CH_SHIFT       = `CLOG2(NUM_CHANNELS);
    localparam int PENDING_COUNT_W    = `CLOG2(PENDING_DEPTH + 1);
    localparam int PENDING_INDEX_W    = (PENDING_DEPTH > 1)
                                      ? `CLOG2(PENDING_DEPTH) : 1;
    localparam int PREP_HIGH_ID       = 0;
    localparam int PREP_FALLBACK_ID   = 1;

    typedef struct packed {
        gemm_unified_cmd_t cmd;
        logic [GEMM_DMA_TAG_WIDTH-1:0] tag;
    } pending_cmd_t;

    typedef struct packed {
        logic active;
        logic burst_mode;
        logic [DMA_NUM_REGS-1:0][31:0] regs;
    } channel_desc_t;

    typedef enum logic [2:0] {
        S_SELECT,
        S_CAPTURE,
        S_BUILD,
        S_PROG,
        S_WAIT_DONE
    } state_t;

    function automatic logic [6:0] pow2_div(
        input logic [6:0] v,
        input logic [6:0] cap
    );
        logic [6:0] result;
        logic found;
        begin
            result = cap;
            found = 1'b0;
            for (int b = 0; b <= 6; ++b) begin
                if (!found && v[b]) begin
                    result = 7'd1 << b;
                    found = 1'b1;
                end
            end
            return result;
        end
    endfunction

    function automatic [63:0] tmem_bank_local_addr(
        input [63:0] byte_addr
    );
        begin
            tmem_bank_local_addr =
                (byte_addr & ((64'd1 << BUS_WORD_SHIFT) - 1))
              | ((byte_addr >> NUM_CH_SHIFT)
                 & ~((64'd1 << BUS_WORD_SHIFT) - 1));
        end
    endfunction

    function automatic logic is_pow2_u32(input logic [31:0] value);
        begin
            return (value != 0) && ((value & (value - 1)) == 0);
        end
    endfunction

    state_t state_q, state_d;

    pending_cmd_t pending_q[PENDING_DEPTH];
    logic [PENDING_COUNT_W-1:0] pending_count_q;
    logic pending_high_found;
    logic pending_low_found;
    logic [PENDING_INDEX_W-1:0] pending_high_idx;
    logic [PENDING_INDEX_W-1:0] pending_low_idx;
    logic pending_dequeue;
    logic [PENDING_INDEX_W-1:0] pending_select_idx;

    // Controller-owned random-access candidate table.  Slot 0 is reserved
    // for the oldest high-priority load; slot 1 owns either the next paused
    // store chunk or the oldest low-priority command.  Full descriptors live
    // only here; DMA channels receive only D0/D1 PREPARE operands.
    logic [1:0] candidate_valid_q;
    logic [1:0] candidate_prepared_q;
    pending_cmd_t candidate_owner_q[2];
    logic candidate_is_store_q[2];
    logic candidate_store_new_q[2];
    logic candidate_store_chunkable_q[2];
    logic [31:0] candidate_chunk_beats_q[2];
    logic [31:0] candidate_store_remaining_q[2];
    channel_desc_t candidate_desc_q[2][NUM_CHANNELS];
    channel_desc_t candidate_store_desc_q[2][NUM_CHANNELS];
    logic [NUM_CHANNELS-1:0] candidate_prepare_accept_q[2];
    logic [1:0] candidate_result_ready_q[2][NUM_CHANNELS];

    logic candidate_capture;
    logic candidate_capture_from_pending;
    logic candidate_capture_store_cont;
    logic candidate_capture_id;
    logic [PENDING_INDEX_W-1:0] candidate_capture_idx;
    logic issue_candidate_q;
    logic issue_candidate_id_q;
    logic candidate_select;
    logic candidate_select_id;
    logic [1:0] candidate_prepared_now;
    logic chain_candidate_select;
    logic chain_candidate_id;
    logic chain_candidate_fire;

    logic prepare_active_q;
    logic prepare_active_id_q;

    gemm_unified_cmd_t work_cmd_q;
    logic [GEMM_DMA_TAG_WIDTH-1:0] work_tag_q;
    logic work_is_store_q;

    channel_desc_t decoded_desc[NUM_CHANNELS];
    logic decoded_chunkable;

    channel_desc_t load_desc_q[NUM_CHANNELS];
    channel_desc_t store_desc_q[NUM_CHANNELS];
    channel_desc_t issue_desc_q[NUM_CHANNELS];

    logic store_context_valid_q;
    logic store_chunkable_q;
    gemm_unified_cmd_t store_cmd_q;
    logic [GEMM_DMA_TAG_WIDTH-1:0] store_tag_q;
    logic [31:0] store_bank_beat_cursor_q;
    logic [31:0] store_remaining_beats_per_bank_q;
    logic [31:0] issued_chunk_beats_per_bank_q;

    channel_desc_t built_desc[NUM_CHANNELS];
    logic [31:0] built_chunk_beats_per_bank;
    logic [63:0] chunk_src_base[NUM_CHANNELS];
    logic [63:0] chunk_dst_base[NUM_CHANNELS];
    logic [63:0] chunk_src_offset[NUM_CHANNELS];
    logic [63:0] chunk_dst_offset[NUM_CHANNELS];
    channel_desc_t builder_store_desc[NUM_CHANNELS];
    channel_desc_t builder_default_desc[NUM_CHANNELS];
    gemm_unified_cmd_t builder_store_cmd;
    logic builder_is_store;
    logic builder_store_chunkable;
    logic [31:0] builder_store_cursor;
    logic [31:0] builder_store_remaining;

    logic [NUM_CHANNELS-1:0] cfg_ready_or_inactive;
    logic [NUM_CHANNELS-1:0] done_or_inactive;
    logic [NUM_CHANNELS-1:0] done_sticky_q;
    logic prepare_all_accepted;
    logic prepare_all_results_ready;
    logic [NUM_CHANNELS-1:0] lookahead_prepare_valid_s;
    logic [NUM_CHANNELS-1:0] lookahead_prepare_ready_s;
    logic [NUM_CHANNELS-1:0][1:0] lookahead_result_ready_s;
    logic [NUM_CHANNELS-1:0] lookahead_activate_s;
    logic [NUM_CHANNELS-1:0] lookahead_activate_id_s;
    logic [1:0] candidate_reserved_logical_count;
    logic [1:0] candidate_cfg_all_ready;
    logic [NUM_CHANNELS-1:0] cfg_channel_ready_s;
    logic [NUM_CHANNELS-1:0] cfg_valid_s;
    logic [PENDING_COUNT_W:0] pending_capacity_used;

    wire cmd_accept = gemm_dma_ctrl_if.cmd_valid
                   && gemm_dma_ctrl_if.cmd_ready;
    wire accepted_high_now = cmd_accept
                           && gemm_dma_ctrl_if.cmd.dma_priority;
    wire cfg_all_ready = &cfg_ready_or_inactive;
    wire done_all_valid = &(done_sticky_q | done_or_inactive);
    wire store_chunk_last = !store_chunkable_q
                         || (issued_chunk_beats_per_bank_q
                             >= store_remaining_beats_per_bank_q);
    wire logical_complete = (state_q == S_WAIT_DONE)
                         && done_all_valid
                         && (!work_is_store_q || store_chunk_last);

    // Candidate reservation transfers a logical command out of pending_q; it
    // does not create additional queue capacity.  A speculative continuation
    // descriptor for the already-owned paused store is not a new logical
    // command.  Once a candidate is selected into the foreground issue path,
    // it has the same capacity status as the legacy work_cmd_q owner.
    always_comb begin
        candidate_reserved_logical_count = 2'd0;
        if (candidate_valid_q[PREP_HIGH_ID]
         && !(issue_candidate_q
           && (issue_candidate_id_q == PREP_HIGH_ID)))
            candidate_reserved_logical_count += 2'd1;
        if (candidate_valid_q[PREP_FALLBACK_ID]
         && candidate_store_new_q[PREP_FALLBACK_ID]
         && !(issue_candidate_q
           && (issue_candidate_id_q == PREP_FALLBACK_ID)))
            candidate_reserved_logical_count += 2'd1;
        pending_capacity_used = (PENDING_COUNT_W+1)'(pending_count_q)
                              + (PENDING_COUNT_W+1)'(
                                  candidate_reserved_logical_count);
    end

    assign gemm_dma_ctrl_if.cmd_ready =
        (pending_capacity_used < (PENDING_COUNT_W+1)'(PENDING_DEPTH));
    assign gemm_dma_ctrl_if.done = logical_complete;
    assign gemm_dma_ctrl_if.done_tag = work_is_store_q
                                     ? store_tag_q : work_tag_q;
    assign gemm_dma_ctrl_if.idle = (state_q == S_SELECT)
                                && (pending_count_q == 0)
                                && !store_context_valid_q
                                && !(|candidate_valid_q)
                                && !prepare_active_q;
    assign store_done = logical_complete && work_is_store_q;

    assign gemm_sync_if.valid   = 1'b0;
    assign gemm_sync_if.reg_idx = 32'd0;
    assign gemm_sync_if.value   = 32'd0;

    always_comb begin
        prepare_all_accepted = prepare_active_q;
        prepare_all_results_ready = prepare_active_q;
        for (int ch = 0; ch < NUM_CHANNELS; ++ch) begin
            if (candidate_desc_q[prepare_active_id_q][ch].active) begin
                prepare_all_accepted &=
                    candidate_prepare_accept_q[prepare_active_id_q][ch]
                    || (lookahead_prepare_valid_s[ch]
                     && lookahead_prepare_ready_s[ch]);
                prepare_all_results_ready &=
                    &(candidate_result_ready_q[prepare_active_id_q][ch]
                    | lookahead_result_ready_s[ch]);
            end
        end
    end

    always_comb begin
        candidate_prepared_now = candidate_prepared_q;
        if (prepare_active_q
         && prepare_all_accepted
         && prepare_all_results_ready)
            candidate_prepared_now[prepare_active_id_q] = 1'b1;
    end

    always_comb begin
        candidate_cfg_all_ready = '1;
        for (int id = 0; id < 2; ++id) begin
            for (int ch = 0; ch < NUM_CHANNELS; ++ch) begin
                if (candidate_desc_q[id][ch].active)
                    candidate_cfg_all_ready[id] &= cfg_channel_ready_s[ch];
            end
        end
    end

    // A completion edge may directly activate only a fully prepared
    // candidate.  Any visible high-priority load, including one accepted on
    // this edge, suppresses fallback chaining.  An unprepared high candidate
    // is retained for the ordinary S_SELECT -> S_PROG slow path.
    always_comb begin
        chain_candidate_select = 1'b0;
        chain_candidate_id = PREP_HIGH_ID;
        if ((state_q == S_WAIT_DONE) && done_all_valid) begin
            if (candidate_valid_q[PREP_HIGH_ID]) begin
                if (candidate_prepared_now[PREP_HIGH_ID]) begin
                    chain_candidate_select = 1'b1;
                    chain_candidate_id = PREP_HIGH_ID;
                end
            end else if (!pending_high_found && !accepted_high_now
                      && candidate_valid_q[PREP_FALLBACK_ID]
             && candidate_prepared_now[PREP_FALLBACK_ID]) begin
                chain_candidate_select = 1'b1;
                chain_candidate_id = PREP_FALLBACK_ID;
            end
        end
    end

    // Scheduling selection is independent of channel readiness.  Only the
    // fire qualifier consumes the old completion and presents the selected
    // descriptor as one atomic cfg/ACTIVATE transaction.  Keeping readiness
    // out of selection avoids a select -> active mask -> ready -> select loop.
    always_comb begin
        chain_candidate_fire = chain_candidate_select
                            && candidate_cfg_all_ready[chain_candidate_id];
    end

    always_comb begin
        pending_high_found = 1'b0;
        pending_low_found = 1'b0;
        pending_high_idx = '0;
        pending_low_idx = '0;

        for (int idx = 0; idx < PENDING_DEPTH; ++idx) begin
            if (idx < pending_count_q) begin
                if (pending_q[idx].cmd.dma_priority
                 && !pending_high_found) begin
                    pending_high_found = 1'b1;
                    pending_high_idx = PENDING_INDEX_W'(idx);
                end
                if (!pending_q[idx].cmd.dma_priority
                 && !pending_low_found) begin
                    pending_low_found = 1'b1;
                    pending_low_idx = PENDING_INDEX_W'(idx);
                end
            end
        end
    end

    always_comb begin
        state_d = state_q;
        pending_dequeue = 1'b0;
        pending_select_idx = '0;
        candidate_capture = 1'b0;
        candidate_capture_from_pending = 1'b0;
        candidate_capture_store_cont = 1'b0;
        candidate_capture_id = 1'b0;
        candidate_capture_idx = '0;
        candidate_select = 1'b0;
        candidate_select_id = 1'b0;

        unique case (state_q)
            S_SELECT: begin
                if (candidate_valid_q[PREP_HIGH_ID]) begin
                    candidate_select = 1'b1;
                    candidate_select_id = 1'b0;
                    state_d = S_PROG;
                end else if (pending_high_found) begin
                    pending_dequeue = 1'b1;
                    pending_select_idx = pending_high_idx;
                    state_d = S_CAPTURE;
                end else if (accepted_high_now) begin
                    // The accepted load becomes visible in pending_q after
                    // this edge.  Do not start fallback work in parallel.
                    state_d = S_SELECT;
                end else if (candidate_valid_q[PREP_FALLBACK_ID]) begin
                    candidate_select = 1'b1;
                    candidate_select_id = 1'b1;
                    state_d = S_PROG;
                end else if (store_context_valid_q) begin
                    state_d = S_BUILD;
                end else if (pending_low_found) begin
                    pending_dequeue = 1'b1;
                    pending_select_idx = pending_low_idx;
                    state_d = S_CAPTURE;
                end
            end

            S_CAPTURE: begin
                state_d = S_BUILD;
            end

            S_BUILD: begin
                state_d = S_PROG;
            end

            S_PROG: begin
                if (cfg_all_ready)
                    state_d = S_WAIT_DONE;
            end

            S_WAIT_DONE: begin
                if (done_all_valid) begin
                    state_d = chain_candidate_fire ? S_WAIT_DONE : S_SELECT;
                end else if (!candidate_valid_q[PREP_HIGH_ID]
                          && pending_high_found) begin
                    candidate_capture = 1'b1;
                    candidate_capture_from_pending = 1'b1;
                    candidate_capture_id = 1'b0;
                    candidate_capture_idx = pending_high_idx;
                    pending_dequeue = 1'b1;
                    pending_select_idx = pending_high_idx;
                end else if (!candidate_valid_q[PREP_FALLBACK_ID]) begin
                    if (store_context_valid_q
                     && (!work_is_store_q || !store_chunk_last)) begin
                        candidate_capture = 1'b1;
                        candidate_capture_store_cont = 1'b1;
                        candidate_capture_id = 1'b1;
                    end else if (pending_low_found) begin
                        candidate_capture = 1'b1;
                        candidate_capture_from_pending = 1'b1;
                        candidate_capture_id = 1'b1;
                        candidate_capture_idx = pending_low_idx;
                        pending_dequeue = 1'b1;
                        pending_select_idx = pending_low_idx;
                    end
                end
            end

            default: begin
                state_d = S_SELECT;
            end
        endcase
    end

    // The existing decoder is shared by the foreground slow path and the
    // background candidate capture.  Capture is restricted to S_WAIT_DONE,
    // so it never steals the decoder from S_CAPTURE.
    gemm_unified_cmd_t decode_cmd;
    always_comb begin
        decode_cmd = work_cmd_q;
        if (candidate_capture_from_pending)
            decode_cmd = pending_q[candidate_capture_idx].cmd;
    end

    // Decode the selected logical command into complete channel descriptors.
    wire [3:0] decode_op = decode_cmd.instr[3:0];
    wire decode_is_store = (decode_op == OP_DMA_ST);
    wire [63:0] decode_src_base = 64'(decode_cmd.rs2_data);
    wire [63:0] decode_dst_base = 64'(decode_cmd.rs1_data);
    wire [31:0] decode_seg_size = {4'd0, decode_cmd.instr[31:4]};
    wire [NUM_CH_SHIFT-1:0] decode_start_ch = decode_is_store
        ? decode_src_base[BUS_WORD_SHIFT +: NUM_CH_SHIFT]
        : decode_dst_base[BUS_WORD_SHIFT +: NUM_CH_SHIFT];
    wire [31:0] decode_num_words = decode_seg_size >> BUS_WORD_SHIFT;
    wire [31:0] decode_words_quot = decode_num_words >> NUM_CH_SHIFT;
    wire [NUM_CH_SHIFT-1:0] decode_words_rem =
        decode_num_words[NUM_CH_SHIFT-1:0];

    for (genvar ch = 0; ch < NUM_CHANNELS; ++ch) begin : g_decode_channels
        wire [NUM_CH_SHIFT-1:0] logical_ch = ch - decode_start_ch;
        wire [31:0] ch_words = decode_words_quot
            + ((logical_ch < decode_words_rem) ? 32'd1 : 32'd0);
        wire ch_active = (ch_words != 0);
        wire [63:0] ch_src_base = decode_is_store
            ? tmem_bank_local_addr(decode_src_base)
            : (decode_src_base + (64'(logical_ch) << BUS_WORD_SHIFT));
        wire [63:0] ch_dst_base = decode_is_store
            ? (decode_dst_base + (64'(logical_ch) << BUS_WORD_SHIFT))
            : tmem_bank_local_addr(decode_dst_base);
        wire [63:0] ch_hbm_base = decode_is_store
            ? ch_dst_base : ch_src_base;
        `UNUSED_VAR ({ch_hbm_base[63:17], ch_hbm_base[10:0]})
        wire [5:0] bank_off_beats = ch_hbm_base[16:11];
        wire [31:0] total_bpb = ch_words / 32'(NUM_BURST_GROUPS);
        wire [6:0] s_bob = pow2_div({1'b0, bank_off_beats}, 7'd64);
        wire [6:0] s_tbpb = pow2_div(total_bpb[6:0], 7'd1);
        wire [6:0] sub_burst_size = (s_bob <= s_tbpb) ? s_bob : s_tbpb;
        wire burst_mode = (ch_words >= 32'(NUM_BURST_GROUPS))
                       && ((ch_words % 32'(NUM_BURST_GROUPS)) == 0);

        always_comb begin
            decoded_desc[ch] = '0;
            decoded_desc[ch].active = ch_active;
            decoded_desc[ch].burst_mode = burst_mode;
            decoded_desc[ch].regs[DMA_R_CONTROL] = ch_active ? 32'd1 : 32'd0;
            decoded_desc[ch].regs[DMA_R_DST_BASE_LO] = ch_dst_base[31:0];
            decoded_desc[ch].regs[DMA_R_DST_BASE_HI] = ch_dst_base[63:32];
            decoded_desc[ch].regs[DMA_R_SRC_BASE_LO] = ch_src_base[31:0];
            decoded_desc[ch].regs[DMA_R_SRC_BASE_HI] = ch_src_base[63:32];

            if (burst_mode) begin
                decoded_desc[ch].regs[DMA_R_BND0] = 32'(sub_burst_size);
                decoded_desc[ch].regs[DMA_R_BND1] =
                    total_bpb / 32'(sub_burst_size);
                decoded_desc[ch].regs[DMA_R_BND2] = 32'(NUM_BURST_GROUPS);
                decoded_desc[ch].regs[DMA_R_SRC_ST0] = decode_is_store
                    ? 32'(BEAT_STRIDE_TMEM_B) : 32'(BEAT_STRIDE_HBM_B);
                decoded_desc[ch].regs[DMA_R_DST_ST0] = decode_is_store
                    ? 32'(BEAT_STRIDE_HBM_B) : 32'(BEAT_STRIDE_TMEM_B);
                decoded_desc[ch].regs[DMA_R_SRC_ST1] = 32'(sub_burst_size)
                    * (decode_is_store
                       ? 32'(BEAT_STRIDE_TMEM_B) : 32'(BEAT_STRIDE_HBM_B));
                decoded_desc[ch].regs[DMA_R_DST_ST1] = 32'(sub_burst_size)
                    * (decode_is_store
                       ? 32'(BEAT_STRIDE_HBM_B) : 32'(BEAT_STRIDE_TMEM_B));
                decoded_desc[ch].regs[DMA_R_SRC_ST2] = decode_is_store
                    ? 32'(BANK_STRIDE_TMEM_B) : 32'(BANK_STRIDE_HBM_B);
                decoded_desc[ch].regs[DMA_R_DST_ST2] = decode_is_store
                    ? 32'(BANK_STRIDE_HBM_B) : 32'(BANK_STRIDE_TMEM_B);
            end else begin
                decoded_desc[ch].regs[DMA_R_BND0] = 32'd1;
                decoded_desc[ch].regs[DMA_R_BND1] = ch_words;
                decoded_desc[ch].regs[DMA_R_BND2] = 32'd1;
                decoded_desc[ch].regs[DMA_R_SRC_ST0] = 32'd0;
                decoded_desc[ch].regs[DMA_R_DST_ST0] = 32'd0;
                decoded_desc[ch].regs[DMA_R_SRC_ST1] = decode_is_store
                    ? 32'(`MEM_BLOCK_SIZE) : 32'(`HBM_BUS_STRIDE);
                decoded_desc[ch].regs[DMA_R_DST_ST1] = decode_is_store
                    ? 32'(`HBM_BUS_STRIDE) : 32'(`MEM_BLOCK_SIZE);
                decoded_desc[ch].regs[DMA_R_SRC_ST2] = 32'd0;
                decoded_desc[ch].regs[DMA_R_DST_ST2] = 32'd0;
            end

            decoded_desc[ch].regs[DMA_R_SEG_SIZE] = 32'(`MEM_BLOCK_SIZE);
            decoded_desc[ch].regs[DMA_R_PAD] = 32'd0;
            decoded_desc[ch].regs[DMA_R_DIR] = {31'd0, decode_is_store};
            decoded_desc[ch].regs[DMA_R_RSVD] = 32'd0;
        end
    end

    always_comb begin
        decoded_chunkable = decode_is_store;
        for (int ch = 0; ch < NUM_CHANNELS; ++ch) begin
            decoded_chunkable &= decoded_desc[ch].active;
            decoded_chunkable &= decoded_desc[ch].burst_mode;
            decoded_chunkable &=
                (decoded_desc[ch].regs[DMA_R_BND0]
                 == decoded_desc[0].regs[DMA_R_BND0]);
            decoded_chunkable &=
                (decoded_desc[ch].regs[DMA_R_BND1]
                 == decoded_desc[0].regs[DMA_R_BND1]);
            decoded_chunkable &=
                (decoded_desc[ch].regs[DMA_R_BND2]
                 == decoded_desc[0].regs[DMA_R_BND2]);
        end
    end

    // Registered chunk builder input.  The store descriptor/context remains
    // untouched while high-priority loads execute.
    always_comb begin
        logic [31:0] orig_bnd0;
        logic [31:0] orig_bnd2;
        logic [31:0] max_chunk_beats;
        logic [31:0] bank_budget;
        logic [31:0] chunk_bnd0;
        logic [31:0] chunk_bnd1;
        logic [31:0] rows_by_remaining;
        logic [31:0] rows_by_budget;

        builder_is_store = work_is_store_q;
        builder_store_chunkable = store_chunkable_q;
        builder_store_cmd = store_cmd_q;
        builder_store_cursor = store_bank_beat_cursor_q;
        builder_store_remaining = store_remaining_beats_per_bank_q;
        for (int ch = 0; ch < NUM_CHANNELS; ++ch) begin
            builder_store_desc[ch] = store_desc_q[ch];
            builder_default_desc[ch] = work_is_store_q
                                     ? store_desc_q[ch] : load_desc_q[ch];
        end

        if (candidate_capture_store_cont) begin
            builder_is_store = 1'b1;
            builder_store_chunkable = store_chunkable_q;
            builder_store_cmd = store_cmd_q;
            builder_store_cursor = store_bank_beat_cursor_q;
            builder_store_remaining = store_remaining_beats_per_bank_q;
            if (work_is_store_q) begin
                builder_store_cursor = store_bank_beat_cursor_q
                                     + issued_chunk_beats_per_bank_q;
                builder_store_remaining = store_remaining_beats_per_bank_q
                                        - issued_chunk_beats_per_bank_q;
            end
            for (int ch = 0; ch < NUM_CHANNELS; ++ch)
                builder_default_desc[ch] = store_desc_q[ch];
        end else if (candidate_capture_from_pending && decode_is_store) begin
            builder_is_store = 1'b1;
            builder_store_chunkable = decoded_chunkable;
            builder_store_cmd = decode_cmd;
            builder_store_cursor = 32'd0;
            builder_store_remaining = decoded_desc[0].regs[DMA_R_BND0]
                                    * decoded_desc[0].regs[DMA_R_BND1];
            for (int ch = 0; ch < NUM_CHANNELS; ++ch) begin
                builder_store_desc[ch] = decoded_desc[ch];
                builder_default_desc[ch] = decoded_desc[ch];
            end
        end

        for (int ch = 0; ch < NUM_CHANNELS; ++ch) begin
            built_desc[ch] = builder_default_desc[ch];
            chunk_src_base[ch] = {
                builder_store_desc[ch].regs[DMA_R_SRC_BASE_HI],
                builder_store_desc[ch].regs[DMA_R_SRC_BASE_LO]
            };
            chunk_dst_base[ch] = {
                builder_store_desc[ch].regs[DMA_R_DST_BASE_HI],
                builder_store_desc[ch].regs[DMA_R_DST_BASE_LO]
            };
            chunk_src_offset[ch] = 64'(builder_store_cursor)
                * 64'(builder_store_desc[ch].regs[DMA_R_SRC_ST0]);
            chunk_dst_offset[ch] = 64'(builder_store_cursor)
                * 64'(builder_store_desc[ch].regs[DMA_R_DST_ST0]);
        end

        built_chunk_beats_per_bank = 32'd0;
        orig_bnd0 = builder_store_desc[0].regs[DMA_R_BND0];
        orig_bnd2 = builder_store_desc[0].regs[DMA_R_BND2];
        max_chunk_beats = 32'd0;
        bank_budget = 32'd0;
        chunk_bnd0 = orig_bnd0;
        chunk_bnd1 = builder_store_desc[0].regs[DMA_R_BND1];
        rows_by_remaining = 32'd0;
        rows_by_budget = 32'd0;

        if (builder_is_store && builder_store_chunkable) begin
            if (builder_store_cmd.dma_max_chunk_log2p1 == 0) begin
                max_chunk_beats = builder_store_desc[0].regs[DMA_R_BND0]
                    * builder_store_desc[0].regs[DMA_R_BND1]
                    * orig_bnd2;
            end else begin
                max_chunk_beats = 32'd1
                    << (builder_store_cmd.dma_max_chunk_log2p1 - 1'b1);
            end

            bank_budget = max_chunk_beats / orig_bnd2;
            if (bank_budget >= orig_bnd0) begin
                rows_by_remaining =
                    builder_store_remaining / orig_bnd0;
                rows_by_budget = bank_budget / orig_bnd0;
                chunk_bnd0 = orig_bnd0;
                chunk_bnd1 = (rows_by_remaining <= rows_by_budget)
                           ? rows_by_remaining : rows_by_budget;
            end else begin
                chunk_bnd0 = bank_budget;
                chunk_bnd1 = 32'd1;
            end

            built_chunk_beats_per_bank = chunk_bnd0 * chunk_bnd1;
            for (int ch = 0; ch < NUM_CHANNELS; ++ch) begin
                chunk_src_base[ch] = chunk_src_base[ch]
                                   + chunk_src_offset[ch];
                chunk_dst_base[ch] = chunk_dst_base[ch]
                                   + chunk_dst_offset[ch];

                built_desc[ch].regs[DMA_R_SRC_BASE_LO]
                    = chunk_src_base[ch][31:0];
                built_desc[ch].regs[DMA_R_SRC_BASE_HI]
                    = chunk_src_base[ch][63:32];
                built_desc[ch].regs[DMA_R_DST_BASE_LO]
                    = chunk_dst_base[ch][31:0];
                built_desc[ch].regs[DMA_R_DST_BASE_HI]
                    = chunk_dst_base[ch][63:32];
                built_desc[ch].regs[DMA_R_BND0] = chunk_bnd0;
                built_desc[ch].regs[DMA_R_BND1] = chunk_bnd1;
                built_desc[ch].regs[DMA_R_SRC_ST1] = chunk_bnd0
                    * builder_store_desc[ch].regs[DMA_R_SRC_ST0];
                built_desc[ch].regs[DMA_R_DST_ST1] = chunk_bnd0
                    * builder_store_desc[ch].regs[DMA_R_DST_ST0];
            end
        end else if (builder_is_store) begin
            built_chunk_beats_per_bank =
                builder_store_remaining;
        end
    end

    for (genvar ch = 0; ch < NUM_CHANNELS; ++ch) begin : g_issue_channels
        assign cfg_channel_ready_s[ch] = cfg_reg_if[ch].ready;
        wire chain_channel_active =
            candidate_desc_q[chain_candidate_id][ch].active;
        wire program_channel_active = chain_candidate_select
                                    ? chain_channel_active
                                    : issue_desc_q[ch].active;

        assign cfg_reg_if[ch].regs = chain_candidate_select
                                  ? candidate_desc_q[chain_candidate_id][ch].regs
                                  : issue_desc_q[ch].regs;
        assign cfg_reg_if[ch].entry_id = 32'd0;
        assign cfg_reg_if[ch].valid = ((state_q == S_PROG)
                                    && cfg_all_ready
                                    && issue_desc_q[ch].active)
                                    || (chain_candidate_fire
                                     && chain_channel_active);
        assign cfg_valid_s[ch] = cfg_reg_if[ch].valid;
        assign lookahead_if[ch].prepare_valid = prepare_active_q
            && candidate_valid_q[prepare_active_id_q]
            && candidate_desc_q[prepare_active_id_q][ch].active
            && !candidate_prepare_accept_q[prepare_active_id_q][ch]
            && !((state_q == S_PROG) && issue_candidate_q
              && (issue_candidate_id_q == prepare_active_id_q));
        assign lookahead_prepare_valid_s[ch] = lookahead_if[ch].prepare_valid;
        assign lookahead_prepare_ready_s[ch] = lookahead_if[ch].prepare_ready;
        assign lookahead_result_ready_s[ch] = lookahead_if[ch].result_ready;
        assign lookahead_if[ch].prepare_id = prepare_active_id_q;
        assign lookahead_if[ch].src_stride[0] =
            candidate_desc_q[prepare_active_id_q][ch].regs[DMA_R_SRC_ST0];
        assign lookahead_if[ch].src_stride[1] =
            candidate_desc_q[prepare_active_id_q][ch].regs[DMA_R_SRC_ST1];
        assign lookahead_if[ch].dst_stride[0] =
            candidate_desc_q[prepare_active_id_q][ch].regs[DMA_R_DST_ST0];
        assign lookahead_if[ch].dst_stride[1] =
            candidate_desc_q[prepare_active_id_q][ch].regs[DMA_R_DST_ST1];
        assign lookahead_if[ch].bound[0] =
            candidate_desc_q[prepare_active_id_q][ch].regs[DMA_R_BND0];
        assign lookahead_if[ch].bound[1] =
            candidate_desc_q[prepare_active_id_q][ch].regs[DMA_R_BND1];
        assign lookahead_if[ch].activate = ((state_q == S_PROG)
                                         && cfg_all_ready
                                         && issue_candidate_q
                                         && issue_desc_q[ch].active)
                                         || (chain_candidate_fire
                                          && chain_channel_active);
        assign lookahead_if[ch].activate_id = chain_candidate_select
                                            ? chain_candidate_id
                                            : issue_candidate_id_q;
        assign lookahead_activate_s[ch] = lookahead_if[ch].activate;
        assign lookahead_activate_id_s[ch] = lookahead_if[ch].activate_id;
        assign cfg_ready_or_inactive[ch] = program_channel_active
            ? cfg_reg_if[ch].ready : 1'b1;
        assign done_or_inactive[ch] = issue_desc_q[ch].active
            ? done_if[ch].valid : 1'b1;
        assign done_if[ch].ready = (state_q == S_WAIT_DONE);
    end

    always_ff @(posedge clk) begin
        if (reset) begin
            state_q <= S_SELECT;
            pending_count_q <= '0;
            work_cmd_q <= '0;
            work_tag_q <= '0;
            work_is_store_q <= 1'b0;
            store_context_valid_q <= 1'b0;
            store_chunkable_q <= 1'b0;
            store_cmd_q <= '0;
            store_tag_q <= '0;
            store_bank_beat_cursor_q <= '0;
            store_remaining_beats_per_bank_q <= '0;
            issued_chunk_beats_per_bank_q <= '0;
            done_sticky_q <= '0;
            candidate_valid_q <= '0;
            candidate_prepared_q <= '0;
            issue_candidate_q <= 1'b0;
            issue_candidate_id_q <= 1'b0;
            prepare_active_q <= 1'b0;
            prepare_active_id_q <= 1'b0;
            for (int idx = 0; idx < PENDING_DEPTH; ++idx)
                pending_q[idx] <= '0;
            for (int id = 0; id < 2; ++id) begin
                candidate_owner_q[id] <= '0;
                candidate_is_store_q[id] <= 1'b0;
                candidate_store_new_q[id] <= 1'b0;
                candidate_store_chunkable_q[id] <= 1'b0;
                candidate_chunk_beats_q[id] <= '0;
                candidate_store_remaining_q[id] <= '0;
                candidate_prepare_accept_q[id] <= '0;
                for (int ch = 0; ch < NUM_CHANNELS; ++ch) begin
                    candidate_desc_q[id][ch] <= '0;
                    candidate_store_desc_q[id][ch] <= '0;
                    candidate_result_ready_q[id][ch] <= '0;
                end
            end
            for (int ch = 0; ch < NUM_CHANNELS; ++ch) begin
                load_desc_q[ch] <= '0;
                store_desc_q[ch] <= '0;
                issue_desc_q[ch] <= '0;
            end
        end else begin
            state_q <= state_d;

            unique case ({cmd_accept, pending_dequeue})
                2'b10: begin
                    pending_q[PENDING_INDEX_W'(pending_count_q)].cmd
                        <= gemm_dma_ctrl_if.cmd;
                    pending_q[PENDING_INDEX_W'(pending_count_q)].tag
                        <= gemm_dma_ctrl_if.cmd_tag;
                    pending_count_q <= pending_count_q + 1'b1;
                end

                2'b01: begin
                    for (int idx = 0; idx < PENDING_DEPTH - 1; ++idx) begin
                        if ((idx >= pending_select_idx)
                         && (idx < (int'(pending_count_q) - 1))) begin
                            pending_q[idx] <= pending_q[idx + 1];
                        end
                    end
                    pending_q[PENDING_INDEX_W'(pending_count_q - 1'b1)]
                        <= '0;
                    pending_count_q <= pending_count_q - 1'b1;
                end

                2'b11: begin
                    for (int idx = 0; idx < PENDING_DEPTH - 1; ++idx) begin
                        if ((idx >= pending_select_idx)
                         && (idx < (int'(pending_count_q) - 1))) begin
                            pending_q[idx] <= pending_q[idx + 1];
                        end
                    end
                    pending_q[PENDING_INDEX_W'(pending_count_q - 1'b1)].cmd
                        <= gemm_dma_ctrl_if.cmd;
                    pending_q[PENDING_INDEX_W'(pending_count_q - 1'b1)].tag
                        <= gemm_dma_ctrl_if.cmd_tag;
                end

                default: begin
                end
            endcase

            if ((state_q == S_SELECT) && candidate_select) begin
                work_cmd_q <= candidate_owner_q[candidate_select_id].cmd;
                work_tag_q <= candidate_owner_q[candidate_select_id].tag;
                work_is_store_q <= candidate_is_store_q[candidate_select_id];
                issued_chunk_beats_per_bank_q <=
                    candidate_chunk_beats_q[candidate_select_id];
                issue_candidate_q <= 1'b1;
                issue_candidate_id_q <= candidate_select_id;
                done_sticky_q <= '0;
                for (int ch = 0; ch < NUM_CHANNELS; ++ch)
                    issue_desc_q[ch] <=
                        candidate_desc_q[candidate_select_id][ch];

                if (candidate_store_new_q[candidate_select_id]) begin
                    store_context_valid_q <= 1'b1;
                    store_chunkable_q <=
                        candidate_store_chunkable_q[candidate_select_id];
                    store_cmd_q <= candidate_owner_q[candidate_select_id].cmd;
                    store_tag_q <= candidate_owner_q[candidate_select_id].tag;
                    store_bank_beat_cursor_q <= 32'd0;
                    store_remaining_beats_per_bank_q <=
                        candidate_store_remaining_q[candidate_select_id];
                    for (int ch = 0; ch < NUM_CHANNELS; ++ch)
                        store_desc_q[ch] <=
                            candidate_store_desc_q[candidate_select_id][ch];
                end
            end else if ((state_q == S_SELECT) && pending_dequeue) begin
                work_cmd_q <= pending_q[pending_select_idx].cmd;
                work_tag_q <= pending_q[pending_select_idx].tag;
                work_is_store_q <=
                    (pending_q[pending_select_idx].cmd.instr[3:0]
                     == OP_DMA_ST);
                issue_candidate_q <= 1'b0;
            end else if ((state_q == S_SELECT)
                      && !pending_high_found
                      && !candidate_valid_q[PREP_HIGH_ID]
                      && !candidate_valid_q[PREP_FALLBACK_ID]
                      && store_context_valid_q) begin
                work_is_store_q <= 1'b1;
                issue_candidate_q <= 1'b0;
            end

            if (state_q == S_CAPTURE) begin
                if (work_is_store_q) begin
                    store_context_valid_q <= 1'b1;
                    store_chunkable_q <= decoded_chunkable;
                    store_cmd_q <= work_cmd_q;
                    store_tag_q <= work_tag_q;
                    store_bank_beat_cursor_q <= 32'd0;
                    store_remaining_beats_per_bank_q <=
                        decoded_desc[0].regs[DMA_R_BND0]
                        * decoded_desc[0].regs[DMA_R_BND1];
                    for (int ch = 0; ch < NUM_CHANNELS; ++ch)
                        store_desc_q[ch] <= decoded_desc[ch];
                end else begin
                    for (int ch = 0; ch < NUM_CHANNELS; ++ch)
                        load_desc_q[ch] <= decoded_desc[ch];
                end
            end

            if (state_q == S_BUILD) begin
                for (int ch = 0; ch < NUM_CHANNELS; ++ch)
                    issue_desc_q[ch] <= built_desc[ch];
                issued_chunk_beats_per_bank_q <=
                    built_chunk_beats_per_bank;
                done_sticky_q <= '0;
            end else if (state_q == S_WAIT_DONE) begin
                done_sticky_q <= done_sticky_q | done_or_inactive;
            end

            // Background reservation transfers ownership out of pending_q
            // (or snapshots the next paused-store cursor) into exactly one
            // random-access candidate slot.  The committed store cursor is
            // never changed here.
            if (candidate_capture) begin
                candidate_valid_q[candidate_capture_id] <= 1'b1;
                candidate_prepared_q[candidate_capture_id] <= 1'b0;
                candidate_prepare_accept_q[candidate_capture_id] <= '0;

                if (candidate_capture_from_pending) begin
                    candidate_owner_q[candidate_capture_id]
                        <= pending_q[candidate_capture_idx];
                    candidate_is_store_q[candidate_capture_id]
                        <= decode_is_store;
                    candidate_store_new_q[candidate_capture_id]
                        <= decode_is_store;
                    candidate_store_chunkable_q[candidate_capture_id]
                        <= decoded_chunkable;
                    candidate_chunk_beats_q[candidate_capture_id]
                        <= decode_is_store
                         ? built_chunk_beats_per_bank : 32'd0;
                    candidate_store_remaining_q[candidate_capture_id]
                        <= decode_is_store
                         ? (decoded_desc[0].regs[DMA_R_BND0]
                          * decoded_desc[0].regs[DMA_R_BND1]) : 32'd0;
                    for (int ch = 0; ch < NUM_CHANNELS; ++ch) begin
                        candidate_desc_q[candidate_capture_id][ch]
                            <= decode_is_store ? built_desc[ch]
                                               : decoded_desc[ch];
                        candidate_store_desc_q[candidate_capture_id][ch]
                            <= decoded_desc[ch];
                        candidate_prepare_accept_q[candidate_capture_id][ch]
                            <= decode_is_store ? !built_desc[ch].active
                                               : !decoded_desc[ch].active;
                        candidate_result_ready_q[candidate_capture_id][ch]
                            <= (decode_is_store ? built_desc[ch].active
                                                : decoded_desc[ch].active)
                             ? 2'b00 : 2'b11;
                    end
                end else begin
                    candidate_owner_q[candidate_capture_id].cmd <= store_cmd_q;
                    candidate_owner_q[candidate_capture_id].tag <= store_tag_q;
                    candidate_is_store_q[candidate_capture_id] <= 1'b1;
                    candidate_store_new_q[candidate_capture_id] <= 1'b0;
                    candidate_store_chunkable_q[candidate_capture_id]
                        <= store_chunkable_q;
                    candidate_chunk_beats_q[candidate_capture_id]
                        <= built_chunk_beats_per_bank;
                    candidate_store_remaining_q[candidate_capture_id]
                        <= builder_store_remaining;
                    for (int ch = 0; ch < NUM_CHANNELS; ++ch) begin
                        candidate_desc_q[candidate_capture_id][ch]
                            <= built_desc[ch];
                        candidate_store_desc_q[candidate_capture_id][ch]
                            <= store_desc_q[ch];
                        candidate_prepare_accept_q[candidate_capture_id][ch]
                            <= !built_desc[ch].active;
                        candidate_result_ready_q[candidate_capture_id][ch]
                            <= built_desc[ch].active ? 2'b00 : 2'b11;
                    end
                end
            end

            // Serialize PREPARE transactions globally so prepare_id and all
            // operands stay stable through arbitrary per-channel skew.
            if (!prepare_active_q) begin
                if (candidate_valid_q[PREP_HIGH_ID]
                 && !candidate_prepared_q[PREP_HIGH_ID]) begin
                    prepare_active_q <= 1'b1;
                    prepare_active_id_q <= 1'b0;
                end else if (candidate_valid_q[PREP_FALLBACK_ID]
                          && !candidate_prepared_q[PREP_FALLBACK_ID]) begin
                    prepare_active_q <= 1'b1;
                    prepare_active_id_q <= 1'b1;
                end
            end else begin
                for (int ch = 0; ch < NUM_CHANNELS; ++ch) begin
                    if (lookahead_prepare_valid_s[ch]
                     && lookahead_prepare_ready_s[ch])
                        candidate_prepare_accept_q[prepare_active_id_q][ch]
                            <= 1'b1;
                    if (candidate_desc_q[prepare_active_id_q][ch].active
                     && (candidate_prepare_accept_q[prepare_active_id_q][ch]
                      || (lookahead_prepare_valid_s[ch]
                       && lookahead_prepare_ready_s[ch])))
                        candidate_result_ready_q[prepare_active_id_q][ch]
                            <= candidate_result_ready_q[prepare_active_id_q][ch]
                             | lookahead_result_ready_s[ch];
                end
                if (prepare_all_accepted && prepare_all_results_ready) begin
                    candidate_prepared_q[prepare_active_id_q] <= 1'b1;
                    prepare_active_q <= 1'b0;
                end
            end

            // ACTIVATE/retirement has priority over background PREPARE state.
            // Since capture is allowed only in S_WAIT_DONE, the released ID
            // cannot be reused on this edge.
            if ((state_q == S_PROG) && cfg_all_ready
             && issue_candidate_q) begin
                candidate_valid_q[issue_candidate_id_q] <= 1'b0;
                candidate_prepared_q[issue_candidate_id_q] <= 1'b0;
                if (prepare_active_q
                 && (prepare_active_id_q == issue_candidate_id_q))
                    prepare_active_q <= 1'b0;
                issue_candidate_q <= 1'b0;
            end

            if (chain_candidate_fire) begin
                candidate_valid_q[chain_candidate_id] <= 1'b0;
                candidate_prepared_q[chain_candidate_id] <= 1'b0;
                if (prepare_active_q
                 && (prepare_active_id_q == chain_candidate_id))
                    prepare_active_q <= 1'b0;
            end

            if ((state_q == S_WAIT_DONE) && done_all_valid
             && work_is_store_q) begin
                if (store_chunk_last) begin
                    store_context_valid_q <= 1'b0;
                    store_bank_beat_cursor_q <= '0;
                    store_remaining_beats_per_bank_q <= '0;
                end else begin
                    store_bank_beat_cursor_q <=
                        store_bank_beat_cursor_q
                        + issued_chunk_beats_per_bank_q;
                    store_remaining_beats_per_bank_q <=
                        store_remaining_beats_per_bank_q
                        - issued_chunk_beats_per_bank_q;
                end
            end

            // Same-edge completion/ACTIVATE: old completion and any old-store
            // cursor commit above use the pre-edge context.  The selected
            // controller-owned descriptor then becomes the new foreground
            // command without visiting S_IDLE/S_PROG.
            if (chain_candidate_fire) begin
                work_cmd_q <= candidate_owner_q[chain_candidate_id].cmd;
                work_tag_q <= candidate_owner_q[chain_candidate_id].tag;
                work_is_store_q <= candidate_is_store_q[chain_candidate_id];
                issued_chunk_beats_per_bank_q <=
                    candidate_chunk_beats_q[chain_candidate_id];
                issue_candidate_q <= 1'b0;
                issue_candidate_id_q <= chain_candidate_id;
                done_sticky_q <= '0;
                for (int ch = 0; ch < NUM_CHANNELS; ++ch)
                    issue_desc_q[ch] <= candidate_desc_q[chain_candidate_id][ch];

                if (candidate_store_new_q[chain_candidate_id]) begin
                    store_context_valid_q <= 1'b1;
                    store_chunkable_q <=
                        candidate_store_chunkable_q[chain_candidate_id];
                    store_cmd_q <= candidate_owner_q[chain_candidate_id].cmd;
                    store_tag_q <= candidate_owner_q[chain_candidate_id].tag;
                    store_bank_beat_cursor_q <= 32'd0;
                    store_remaining_beats_per_bank_q <=
                        candidate_store_remaining_q[chain_candidate_id];
                    for (int ch = 0; ch < NUM_CHANNELS; ++ch)
                        store_desc_q[ch] <=
                            candidate_store_desc_q[chain_candidate_id][ch];
                end
            end
        end
    end

`ifndef SYNTHESIS
    initial begin
        if (`PLATFORM_MEMORY_INTERLEAVE == 0)
            $fatal(1, "%s: interleaved memory is required", INSTANCE_ID);
        if (RAW_BURST_GROUPS == 0)
            $fatal(1, "%s: memory banks must cover all DMA channels",
                   INSTANCE_ID);
    end

    always_ff @(posedge clk) begin
        if (!reset) begin
            if (cmd_accept) begin
                assert ((gemm_dma_ctrl_if.cmd.instr[3:0] == OP_DMA_LD)
                     || (gemm_dma_ctrl_if.cmd.instr[3:0] == OP_DMA_ST))
                    else $fatal(1, "%s: invalid DMA opcode 0x%0h",
                                INSTANCE_ID,
                                gemm_dma_ctrl_if.cmd.instr[3:0]);
                assert (gemm_dma_ctrl_if.cmd.bound == 16'd1)
                    else $fatal(1, "%s: DMA bound must remain one",
                                INSTANCE_ID);
                assert (gemm_dma_ctrl_if.cmd.rs1_data[
                            BUS_WORD_SHIFT +: NUM_CH_SHIFT]
                     == gemm_dma_ctrl_if.cmd.rs2_data[
                            BUS_WORD_SHIFT +: NUM_CH_SHIFT])
                    else $fatal(1, "%s: DMA channel-slot misalignment",
                                INSTANCE_ID);
                assert (gemm_dma_ctrl_if.cmd.dma_priority
                        == (gemm_dma_ctrl_if.cmd.instr[3:0] == OP_DMA_LD))
                    else $fatal(1, "%s: DMA priority/opcode mismatch",
                                INSTANCE_ID);
            end

            assert (!(pending_dequeue && (pending_count_q == 0)))
                else $fatal(1, "%s: pending queue underflow", INSTANCE_ID);
            assert (pending_capacity_used
                 <= (PENDING_COUNT_W+1)'(PENDING_DEPTH))
                else $fatal(1, "%s: pending/candidate capacity overflow",
                            INSTANCE_ID);
            if (cmd_accept)
                assert (pending_capacity_used
                      < (PENDING_COUNT_W+1)'(PENDING_DEPTH))
                    else $fatal(1, "%s: command accepted beyond capacity",
                                INSTANCE_ID);

            if (candidate_capture) begin
                assert (!candidate_valid_q[candidate_capture_id])
                    else $fatal(1, "%s: candidate ID reused before retirement",
                                INSTANCE_ID);
                if (candidate_capture_id == PREP_HIGH_ID) begin
                    assert (candidate_capture_from_pending
                         && pending_q[candidate_capture_idx].cmd.dma_priority)
                        else $fatal(1, "%s: ID0 did not reserve a high load",
                                    INSTANCE_ID);
                end else if (candidate_capture_from_pending) begin
                    assert (!pending_q[candidate_capture_idx].cmd.dma_priority)
                        else $fatal(1, "%s: ID1 reserved a high load",
                                    INSTANCE_ID);
                end else begin
                    assert (candidate_capture_store_cont)
                        else $fatal(1, "%s: ID1 has no fallback owner",
                                    INSTANCE_ID);
                end
            end

            if (candidate_select
             && (candidate_select_id == PREP_FALLBACK_ID)) begin
                assert (!candidate_valid_q[PREP_HIGH_ID]
                     && !pending_high_found
                     && !accepted_high_now)
                    else $fatal(1,
                        "%s: fallback selected while a high load was visible",
                        INSTANCE_ID);
            end

            if ((state_q == S_PROG) && cfg_all_ready
             && issue_candidate_q) begin
                assert (candidate_valid_q[issue_candidate_id_q])
                    else $fatal(1, "%s: candidate retired before ACTIVATE",
                                INSTANCE_ID);
                for (int ch = 0; ch < NUM_CHANNELS; ++ch) begin
                    if (issue_desc_q[ch].active)
                        assert (lookahead_activate_s[ch]
                             && (lookahead_activate_id_s[ch]
                              == issue_candidate_id_q))
                            else $fatal(1,
                                "%s: channel %0d ACTIVATE ID mismatch",
                                INSTANCE_ID, ch);
                end
            end

            if ((state_q == S_PROG) && !cfg_all_ready) begin
                for (int ch = 0; ch < NUM_CHANNELS; ++ch) begin
                    assert (!cfg_valid_s[ch]
                         && !lookahead_activate_s[ch])
                        else $fatal(1,
                            "%s: channel %0d partially accepted ACTIVATE",
                            INSTANCE_ID, ch);
                end
            end


            if (chain_candidate_fire) begin
                assert (done_all_valid
                     && candidate_valid_q[chain_candidate_id]
                     && candidate_prepared_now[chain_candidate_id])
                    else $fatal(1,
                        "%s: unsafe or unprepared same-edge ACTIVATE",
                        INSTANCE_ID);
                assert (cfg_all_ready)
                    else $fatal(1,
                        "%s: chained descriptor was not atomically accepted",
                        INSTANCE_ID);
                if (chain_candidate_id == PREP_FALLBACK_ID)
                    assert (!candidate_valid_q[PREP_HIGH_ID]
                         && !pending_high_found
                         && !accepted_high_now)
                        else $fatal(1,
                            "%s: fallback chained while high load was visible",
                            INSTANCE_ID);
                for (int ch = 0; ch < NUM_CHANNELS; ++ch) begin
                    if (candidate_desc_q[chain_candidate_id][ch].active)
                        assert (lookahead_activate_s[ch]
                             && (lookahead_activate_id_s[ch]
                              == chain_candidate_id))
                            else $fatal(1,
                                "%s: channel %0d missed chained ACTIVATE",
                                INSTANCE_ID, ch);
                end
            end

            if (prepare_active_q) begin
                assert (candidate_valid_q[prepare_active_id_q])
                    else $fatal(1, "%s: PREPARE lost candidate ownership",
                                INSTANCE_ID);
            end

            if ((state_q == S_CAPTURE) && work_is_store_q
             && decoded_chunkable) begin
                logic [31:0] orig_bnd2;
                logic [31:0] max_chunk_beats;
                orig_bnd2 = decoded_desc[0].regs[DMA_R_BND2];
                max_chunk_beats = (work_cmd_q.dma_max_chunk_log2p1 == 0)
                    ? (decoded_desc[0].regs[DMA_R_BND0]
                       * decoded_desc[0].regs[DMA_R_BND1]
                       * orig_bnd2)
                    : (32'd1
                       << (work_cmd_q.dma_max_chunk_log2p1 - 1'b1));
                assert (is_pow2_u32(orig_bnd2))
                    else $fatal(1, "%s: chunkable store BND2 is not power-of-two",
                                INSTANCE_ID);
                assert (max_chunk_beats >= orig_bnd2)
                    else $fatal(1, "%s: store chunk limit is smaller than BND2",
                                INSTANCE_ID);
            end

            if ((state_q == S_PROG) && work_is_store_q
             && !store_chunkable_q) begin
                for (int ch = 0; ch < NUM_CHANNELS; ++ch) begin
                    assert (issue_desc_q[ch] == store_desc_q[ch])
                        else $fatal(1,
                            "%s: non-chunkable store descriptor changed on channel %0d",
                            INSTANCE_ID, ch);
                end
            end

            if ((state_q == S_PROG) && work_is_store_q
             && store_chunkable_q) begin
                assert (issue_desc_q[0].regs[DMA_R_BND0]
                     <= store_desc_q[0].regs[DMA_R_BND0])
                    else $fatal(1, "%s: chunk increased original BND0",
                                INSTANCE_ID);
            end

            if (gemm_dma_ctrl_if.done) begin
                assert (done_all_valid)
                    else $fatal(1, "%s: logical done preceded channel drain",
                                INSTANCE_ID);
            end
        end
    end
`endif

`ifndef SYNTHESIS
`ifdef DBG_TRACE_GEMM
    logic [63:0] dbg_sched_cycle_q;
    logic [63:0] dbg_cmd_accept_count_q;
    logic [63:0] dbg_pending_occupancy_samples_q;
    logic [63:0] dbg_pending_occupancy_sum_q;
    logic [31:0] dbg_pending_occupancy_max_q;
    logic [63:0] dbg_descriptor_issue_count_q;
    logic [63:0] dbg_descriptor_complete_count_q;
    logic [63:0] dbg_store_chunk_issue_count_q;
    logic [63:0] dbg_store_chunk_complete_count_q;
    logic [63:0] dbg_logical_complete_count_q;
    logic [63:0] dbg_store_to_load_switch_count_q;
    logic [63:0] dbg_switch_latency_count_q;
    logic [63:0] dbg_switch_latency_sum_q;
    logic [63:0] dbg_switch_latency_max_q;
    logic [63:0] dbg_input_load_active_cycles_q;
    logic [63:0] dbg_compute_active_cycles_q;
    logic [63:0] dbg_input_load_compute_overlap_cycles_q;
    logic dbg_activity_seen_q;
    logic dbg_idle_q;
    logic dbg_switch_candidate_q;
    logic dbg_switch_latency_active_q;
    logic [63:0] dbg_switch_start_cycle_q;
    logic [GEMM_DMA_TAG_WIDTH-1:0] dbg_switch_store_tag_q;
    logic [GEMM_DMA_TAG_WIDTH-1:0] dbg_switch_load_tag_q;
    logic [PENDING_COUNT_W-1:0] dbg_pending_count_after;

    wire dbg_descriptor_issue = ((state_q == S_PROG) && cfg_all_ready)
                              || chain_candidate_fire;
    wire dbg_descriptor_issue_is_store = chain_candidate_fire
        ? candidate_is_store_q[chain_candidate_id] : work_is_store_q;
    wire dbg_descriptor_complete = (state_q == S_WAIT_DONE)
                                 && done_all_valid;
    wire dbg_intermediate_store_chunk_complete = dbg_descriptor_complete
                                               && work_is_store_q
                                               && !store_chunk_last;
    // A load is active after all channel descriptors have been accepted and
    // until every active channel has completed.  Sample the compute predicate
    // in this same clock domain so the intersection is cycle-exact.
    wire dbg_input_load_active = (state_q == S_WAIT_DONE)
                              && !work_is_store_q;
    wire dbg_compute_active = (compute_active_i === 1'b1);
    wire dbg_store_to_load_select = (state_q == S_SELECT)
                                  && pending_high_found
                                  && store_context_valid_q;
    wire dbg_capacity_release = (state_q == S_SELECT)
        && ((pending_dequeue && !candidate_capture_from_pending)
         || (candidate_select
          && ((candidate_select_id == PREP_HIGH_ID)
           || candidate_store_new_q[candidate_select_id])));
    wire [GEMM_DMA_TAG_WIDTH-1:0] dbg_active_tag = work_is_store_q
        ? store_tag_q : work_tag_q;

    always_comb begin
        dbg_pending_count_after =
            pending_capacity_used[PENDING_COUNT_W-1:0];
        unique case ({cmd_accept, dbg_capacity_release})
            2'b10: dbg_pending_count_after =
                pending_capacity_used[PENDING_COUNT_W-1:0] + 1'b1;
            2'b01: dbg_pending_count_after =
                pending_capacity_used[PENDING_COUNT_W-1:0] - 1'b1;
            default: begin
            end
        endcase
    end

    task automatic trace_sched_perf(input logic include_current_completion);
        logic [63:0] descriptor_complete_total;
        logic [63:0] store_chunk_complete_total;
        logic [63:0] logical_complete_total;
        logic [63:0] input_load_active_total;
        logic [63:0] compute_active_total;
        logic [63:0] input_load_compute_overlap_total;
        begin
            descriptor_complete_total = dbg_descriptor_complete_count_q
                + (include_current_completion ? 64'd1 : 64'd0);
            store_chunk_complete_total = dbg_store_chunk_complete_count_q
                + ((include_current_completion && work_is_store_q)
                   ? 64'd1 : 64'd0);
            logical_complete_total = dbg_logical_complete_count_q
                + (include_current_completion ? 64'd1 : 64'd0);
            input_load_active_total = dbg_input_load_active_cycles_q
                + (dbg_input_load_active ? 64'd1 : 64'd0);
            compute_active_total = dbg_compute_active_cycles_q
                + (dbg_compute_active ? 64'd1 : 64'd0);
            input_load_compute_overlap_total
                = dbg_input_load_compute_overlap_cycles_q
                + ((dbg_input_load_active && dbg_compute_active)
                   ? 64'd1 : 64'd0);
            `TRACE(1, ("%m : [%0t] | TMEM_DMA_SCHED_PERF | {inst=%s, cycles=%0d, accepted=%0d, pending_samples=%0d, pending_sum=%0d, pending_max=%0d, desc_issue=%0d, desc_complete=%0d, store_chunk_issue=%0d, store_chunk_complete=%0d, logical_complete=%0d, store_to_load_switch=%0d, switch_latency_count=%0d, switch_latency_sum=%0d, switch_latency_max=%0d, input_load_active_cycles=%0d, compute_active_cycles=%0d, input_load_compute_overlap_cycles=%0d}\n",
                      $time, INSTANCE_ID, dbg_sched_cycle_q,
                      dbg_cmd_accept_count_q,
                      dbg_pending_occupancy_samples_q,
                      dbg_pending_occupancy_sum_q,
                      dbg_pending_occupancy_max_q,
                      dbg_descriptor_issue_count_q,
                      descriptor_complete_total,
                      dbg_store_chunk_issue_count_q,
                      store_chunk_complete_total,
                      logical_complete_total,
                      dbg_store_to_load_switch_count_q,
                      dbg_switch_latency_count_q,
                      dbg_switch_latency_sum_q,
                      dbg_switch_latency_max_q,
                      input_load_active_total,
                      compute_active_total,
                      input_load_compute_overlap_total))
        end
    endtask

    always_ff @(posedge clk) begin
        if (reset) begin
            dbg_sched_cycle_q <= '0;
            dbg_cmd_accept_count_q <= '0;
            dbg_pending_occupancy_samples_q <= '0;
            dbg_pending_occupancy_sum_q <= '0;
            dbg_pending_occupancy_max_q <= '0;
            dbg_descriptor_issue_count_q <= '0;
            dbg_descriptor_complete_count_q <= '0;
            dbg_store_chunk_issue_count_q <= '0;
            dbg_store_chunk_complete_count_q <= '0;
            dbg_logical_complete_count_q <= '0;
            dbg_store_to_load_switch_count_q <= '0;
            dbg_switch_latency_count_q <= '0;
            dbg_switch_latency_sum_q <= '0;
            dbg_switch_latency_max_q <= '0;
            dbg_input_load_active_cycles_q <= '0;
            dbg_compute_active_cycles_q <= '0;
            dbg_input_load_compute_overlap_cycles_q <= '0;
            dbg_activity_seen_q <= 1'b0;
            dbg_idle_q <= 1'b1;
            dbg_switch_candidate_q <= 1'b0;
            dbg_switch_latency_active_q <= 1'b0;
            dbg_switch_start_cycle_q <= '0;
            dbg_switch_store_tag_q <= '0;
            dbg_switch_load_tag_q <= '0;
        end else begin
            logic [63:0] switch_latency;

            dbg_sched_cycle_q <= dbg_sched_cycle_q + 64'd1;
            dbg_idle_q <= gemm_dma_ctrl_if.idle;

            if (dbg_input_load_active)
                dbg_input_load_active_cycles_q
                    <= dbg_input_load_active_cycles_q + 64'd1;
            if (dbg_compute_active)
                dbg_compute_active_cycles_q
                    <= dbg_compute_active_cycles_q + 64'd1;
            if (dbg_input_load_active && dbg_compute_active)
                dbg_input_load_compute_overlap_cycles_q
                    <= dbg_input_load_compute_overlap_cycles_q + 64'd1;

            if (cmd_accept) begin
                dbg_activity_seen_q <= 1'b1;
                dbg_cmd_accept_count_q <= dbg_cmd_accept_count_q + 64'd1;
                `TRACE(2, ("%m : [%0t] | TMEM_DMA_CMD_ACCEPT | {inst=%s, tag=%0d, op=0x%0h, priority=%0d, max_chunk_log2p1=%0d, pending_before=%0d, pending_after=%0d, dequeue_same_cycle=%0d}\n",
                          $time, INSTANCE_ID, gemm_dma_ctrl_if.cmd_tag,
                          gemm_dma_ctrl_if.cmd.instr[3:0],
                          gemm_dma_ctrl_if.cmd.dma_priority,
                          gemm_dma_ctrl_if.cmd.dma_max_chunk_log2p1,
                          pending_count_q, dbg_pending_count_after,
                          pending_dequeue))
            end

            if (dbg_activity_seen_q || cmd_accept) begin
                dbg_pending_occupancy_samples_q
                    <= dbg_pending_occupancy_samples_q + 64'd1;
                dbg_pending_occupancy_sum_q
                    <= dbg_pending_occupancy_sum_q
                     + 64'(dbg_pending_count_after);
                if (32'(dbg_pending_count_after)
                    > dbg_pending_occupancy_max_q) begin
                    dbg_pending_occupancy_max_q
                        <= 32'(dbg_pending_count_after);
                end
            end

            if ((state_q == S_SELECT) && pending_dequeue) begin
                `TRACE(2, ("%m : [%0t] | TMEM_DMA_SELECT | {inst=%s, source=pending, tag=%0d, op=0x%0h, priority=%0d, pending_before=%0d, paused_store=%0d}\n",
                          $time, INSTANCE_ID,
                          pending_q[pending_select_idx].tag,
                          pending_q[pending_select_idx].cmd.instr[3:0],
                          pending_q[pending_select_idx].cmd.dma_priority,
                          pending_count_q, store_context_valid_q))
            end else if ((state_q == S_SELECT)
                      && !pending_high_found
                      && store_context_valid_q) begin
                `TRACE(2, ("%m : [%0t] | TMEM_DMA_SELECT | {inst=%s, source=paused_store, tag=%0d, op=0x%0h, priority=0, pending_before=%0d, chunkable=%0d, bypass=%0d, cursor=%0d, remaining=%0d}\n",
                          $time, INSTANCE_ID, store_tag_q, OP_DMA_ST,
                          pending_count_q, store_chunkable_q,
                          !store_chunkable_q, store_bank_beat_cursor_q,
                          store_remaining_beats_per_bank_q))
            end

            if ((state_q == S_CAPTURE) && work_is_store_q) begin
                `TRACE(2, ("%m : [%0t] | TMEM_DMA_STORE_CAPTURE | {inst=%s, tag=%0d, chunkable=%0d, bypass=%0d, cursor=0, remaining=%0d, orig_bnd0=%0d, orig_bnd1=%0d, orig_bnd2=%0d, max_chunk_log2p1=%0d}\n",
                          $time, INSTANCE_ID, work_tag_q,
                          decoded_chunkable, !decoded_chunkable,
                          decoded_desc[0].regs[DMA_R_BND0]
                            * decoded_desc[0].regs[DMA_R_BND1],
                          decoded_desc[0].regs[DMA_R_BND0],
                          decoded_desc[0].regs[DMA_R_BND1],
                          decoded_desc[0].regs[DMA_R_BND2],
                          work_cmd_q.dma_max_chunk_log2p1))
            end

            if (dbg_descriptor_issue) begin
                dbg_descriptor_issue_count_q
                    <= dbg_descriptor_issue_count_q + 64'd1;
                if (dbg_descriptor_issue_is_store) begin
                    dbg_store_chunk_issue_count_q
                        <= dbg_store_chunk_issue_count_q + 64'd1;
                end
                `TRACE(2, ("%m : [%0t] | TMEM_DMA_CHUNK_ISSUE | {inst=%s, tag=%0d, op=0x%0h, is_store=%0d, chunkable=%0d, bypass=%0d, cursor=%0d, remaining=%0d, chunk_beats_per_bank=%0d, bnd0=%0d, bnd1=%0d, bnd2=%0d, pending=%0d}\n",
                          $time, INSTANCE_ID, dbg_active_tag,
                          work_is_store_q ? OP_DMA_ST : OP_DMA_LD,
                          work_is_store_q,
                          work_is_store_q && store_chunkable_q,
                          work_is_store_q && !store_chunkable_q,
                          work_is_store_q ? store_bank_beat_cursor_q : 32'd0,
                          work_is_store_q
                            ? store_remaining_beats_per_bank_q : 32'd0,
                          issued_chunk_beats_per_bank_q,
                          issue_desc_q[0].regs[DMA_R_BND0],
                          issue_desc_q[0].regs[DMA_R_BND1],
                          issue_desc_q[0].regs[DMA_R_BND2],
                          pending_count_q))
            end

            if (dbg_descriptor_complete) begin
                dbg_descriptor_complete_count_q
                    <= dbg_descriptor_complete_count_q + 64'd1;
                if (work_is_store_q) begin
                    dbg_store_chunk_complete_count_q
                        <= dbg_store_chunk_complete_count_q + 64'd1;
                end
                `TRACE(2, ("%m : [%0t] | TMEM_DMA_CHUNK_COMPLETE | {inst=%s, tag=%0d, op=0x%0h, is_store=%0d, chunkable=%0d, bypass=%0d, cursor=%0d, remaining_before=%0d, chunk_beats_per_bank=%0d, logical_final=%0d, pending=%0d}\n",
                          $time, INSTANCE_ID, dbg_active_tag,
                          work_is_store_q ? OP_DMA_ST : OP_DMA_LD,
                          work_is_store_q,
                          work_is_store_q && store_chunkable_q,
                          work_is_store_q && !store_chunkable_q,
                          work_is_store_q ? store_bank_beat_cursor_q : 32'd0,
                          work_is_store_q
                            ? store_remaining_beats_per_bank_q : 32'd0,
                          issued_chunk_beats_per_bank_q,
                          !work_is_store_q || store_chunk_last,
                          pending_count_q))
            end

            if (logical_complete) begin
                dbg_logical_complete_count_q
                    <= dbg_logical_complete_count_q + 64'd1;
                `TRACE(2, ("%m : [%0t] | TMEM_DMA_LOGICAL_COMPLETE | {inst=%s, tag=%0d, op=0x%0h, is_store=%0d, chunkable=%0d, bypass=%0d, cursor=%0d, remaining_before=%0d, pending=%0d}\n",
                          $time, INSTANCE_ID, dbg_active_tag,
                          work_is_store_q ? OP_DMA_ST : OP_DMA_LD,
                          work_is_store_q,
                          work_is_store_q && store_chunkable_q,
                          work_is_store_q && !store_chunkable_q,
                          work_is_store_q ? store_bank_beat_cursor_q : 32'd0,
                          work_is_store_q
                            ? store_remaining_beats_per_bank_q : 32'd0,
                          pending_count_q))
                trace_sched_perf(1'b1);
            end

            if (dbg_intermediate_store_chunk_complete) begin
                dbg_switch_candidate_q <= 1'b1;
                dbg_switch_start_cycle_q <= dbg_sched_cycle_q;
                dbg_switch_store_tag_q <= store_tag_q;
            end

            if (dbg_switch_candidate_q && (state_q == S_SELECT)) begin
                dbg_switch_candidate_q <= 1'b0;
                if (dbg_store_to_load_select) begin
                    dbg_store_to_load_switch_count_q
                        <= dbg_store_to_load_switch_count_q + 64'd1;
                    dbg_switch_latency_active_q <= 1'b1;
                    dbg_switch_load_tag_q <= pending_q[pending_high_idx].tag;
                    `TRACE(2, ("%m : [%0t] | TMEM_DMA_STORE_TO_LOAD_SWITCH | {inst=%s, store_tag=%0d, load_tag=%0d, cursor=%0d, remaining=%0d, pending=%0d}\n",
                              $time, INSTANCE_ID, dbg_switch_store_tag_q,
                              pending_q[pending_high_idx].tag,
                              store_bank_beat_cursor_q,
                              store_remaining_beats_per_bank_q,
                              pending_count_q))
                end
            end

            if (dbg_switch_latency_active_q && dbg_descriptor_issue
             && !work_is_store_q) begin
                switch_latency = dbg_sched_cycle_q
                               - dbg_switch_start_cycle_q;
                dbg_switch_latency_active_q <= 1'b0;
                dbg_switch_latency_count_q
                    <= dbg_switch_latency_count_q + 64'd1;
                dbg_switch_latency_sum_q
                    <= dbg_switch_latency_sum_q + switch_latency;
                if (switch_latency > dbg_switch_latency_max_q)
                    dbg_switch_latency_max_q <= switch_latency;
                `TRACE(2, ("%m : [%0t] | TMEM_DMA_SWITCH_LATENCY | {inst=%s, store_tag=%0d, load_tag=%0d, cycles=%0d}\n",
                          $time, INSTANCE_ID, dbg_switch_store_tag_q,
                          dbg_switch_load_tag_q, switch_latency))
            end

            if (dbg_activity_seen_q && gemm_dma_ctrl_if.idle
             && !dbg_idle_q) begin
                trace_sched_perf(1'b0);
            end

            assert (dbg_input_load_compute_overlap_cycles_q
                 <= dbg_input_load_active_cycles_q)
                else $fatal(1, "%s: input-load/compute overlap exceeds input-load activity",
                            INSTANCE_ID);
            assert (dbg_input_load_compute_overlap_cycles_q
                 <= dbg_compute_active_cycles_q)
                else $fatal(1, "%s: input-load/compute overlap exceeds compute activity",
                            INSTANCE_ID);
        end
    end
`endif
`endif

`ifndef SYNTHESIS
`ifdef DBG_TRACE_GEMM_CMD_PERF
    localparam int DBG_DMA_RECORDS = 1 << GEMM_DMA_TAG_WIDTH;
    bit dbg_dma_cmd_valid_q[DBG_DMA_RECORDS];
    bit dbg_dma_cmd_is_store_q[DBG_DMA_RECORDS];
    bit dbg_dma_cmd_first_select_valid_q[DBG_DMA_RECORDS];
    bit dbg_dma_cmd_first_desc_valid_q[DBG_DMA_RECORDS];
    bit dbg_dma_cmd_chunkable_q[DBG_DMA_RECORDS];
    longint unsigned dbg_dma_cmd_serial_q[DBG_DMA_RECORDS];
    longint unsigned dbg_dma_cmd_accept_cycle_q[DBG_DMA_RECORDS];
    longint unsigned dbg_dma_cmd_first_select_cycle_q[DBG_DMA_RECORDS];
    longint unsigned dbg_dma_cmd_first_desc_cycle_q[DBG_DMA_RECORDS];
    longint unsigned dbg_dma_cmd_pending_cycles_q[DBG_DMA_RECORDS];
    longint unsigned dbg_dma_cmd_descriptor_cycles_q[DBG_DMA_RECORDS];
    longint unsigned dbg_dma_cmd_paused_cycles_q[DBG_DMA_RECORDS];
    longint unsigned dbg_dma_cmd_chunk_count_q[DBG_DMA_RECORDS];
    longint unsigned dbg_dma_perf_cycle_q;
    longint unsigned dbg_dma_accept_serial_q;

    wire dbg_dma_descriptor_issue = (state_q == S_PROG) && cfg_all_ready;
    wire dbg_dma_descriptor_active = (state_q == S_WAIT_DONE);
    wire dbg_dma_load_descriptor_active = dbg_dma_descriptor_active
                                        && !work_is_store_q;
    wire dbg_dma_store_descriptor_active = dbg_dma_descriptor_active
                                         && work_is_store_q;
    wire [GEMM_DMA_TAG_WIDTH-1:0] dbg_dma_active_tag = work_is_store_q
        ? store_tag_q : work_tag_q;

    always @(posedge clk) begin : dbg_dma_command_accounting
      if (reset) begin
        dbg_dma_perf_cycle_q = 0;
        dbg_dma_accept_serial_q = 0;
        for (int tag = 0; tag < DBG_DMA_RECORDS; ++tag) begin
          dbg_dma_cmd_valid_q[tag] = 0;
          dbg_dma_cmd_is_store_q[tag] = 0;
          dbg_dma_cmd_first_select_valid_q[tag] = 0;
          dbg_dma_cmd_first_desc_valid_q[tag] = 0;
          dbg_dma_cmd_chunkable_q[tag] = 0;
          dbg_dma_cmd_pending_cycles_q[tag] = 0;
          dbg_dma_cmd_descriptor_cycles_q[tag] = 0;
          dbg_dma_cmd_paused_cycles_q[tag] = 0;
          dbg_dma_cmd_chunk_count_q[tag] = 0;
        end
      end else begin
        dbg_dma_perf_cycle_q++;

        for (int tag = 0; tag < DBG_DMA_RECORDS; ++tag) begin
          bit tag_pending;
          tag_pending = 0;
          for (int idx = 0; idx < PENDING_DEPTH; ++idx) begin
            if ((idx < pending_count_q) && (pending_q[idx].tag == tag))
              tag_pending = 1;
          end
          if (dbg_dma_cmd_valid_q[tag] && tag_pending)
            dbg_dma_cmd_pending_cycles_q[tag]++;
          if (dbg_dma_cmd_valid_q[tag]
           && dbg_dma_descriptor_active
           && (dbg_dma_active_tag == tag))
            dbg_dma_cmd_descriptor_cycles_q[tag]++;
          if (dbg_dma_cmd_valid_q[tag]
           && dbg_dma_cmd_is_store_q[tag]
           && store_context_valid_q
           && (store_tag_q == tag)
           && !work_is_store_q
           && (state_q != S_SELECT))
            dbg_dma_cmd_paused_cycles_q[tag]++;
        end

        if (cmd_accept) begin
          int tag;
          tag = gemm_dma_ctrl_if.cmd_tag;
          assert (!dbg_dma_cmd_valid_q[tag])
            else $fatal(1, "%s: DMA perf tag %0d reused before completion",
                        INSTANCE_ID, tag);
          dbg_dma_cmd_valid_q[tag] = 1;
          dbg_dma_cmd_is_store_q[tag]
              = (gemm_dma_ctrl_if.cmd.instr[3:0] == OP_DMA_ST);
          dbg_dma_cmd_first_select_valid_q[tag] = 0;
          dbg_dma_cmd_first_desc_valid_q[tag] = 0;
          dbg_dma_cmd_chunkable_q[tag] = 0;
          dbg_dma_cmd_serial_q[tag] = dbg_dma_accept_serial_q;
          dbg_dma_cmd_accept_cycle_q[tag] = dbg_dma_perf_cycle_q;
          dbg_dma_cmd_first_select_cycle_q[tag] = 0;
          dbg_dma_cmd_first_desc_cycle_q[tag] = 0;
          dbg_dma_cmd_pending_cycles_q[tag] = 0;
          dbg_dma_cmd_descriptor_cycles_q[tag] = 0;
          dbg_dma_cmd_paused_cycles_q[tag] = 0;
          dbg_dma_cmd_chunk_count_q[tag] = 0;
          dbg_dma_accept_serial_q++;
        end

        if ((state_q == S_SELECT) && pending_dequeue) begin
          int tag;
          tag = pending_q[pending_select_idx].tag;
          if (!dbg_dma_cmd_first_select_valid_q[tag]) begin
            dbg_dma_cmd_first_select_valid_q[tag] = 1;
            dbg_dma_cmd_first_select_cycle_q[tag] = dbg_dma_perf_cycle_q;
          end
        end

        if ((state_q == S_CAPTURE) && work_is_store_q)
          dbg_dma_cmd_chunkable_q[work_tag_q] = decoded_chunkable;

        if (dbg_dma_descriptor_issue) begin
          int tag;
          tag = dbg_dma_active_tag;
          assert (dbg_dma_cmd_valid_q[tag])
            else $fatal(1, "%s: descriptor issued without DMA perf record tag %0d",
                        INSTANCE_ID, tag);
          if (!dbg_dma_cmd_first_desc_valid_q[tag]) begin
            dbg_dma_cmd_first_desc_valid_q[tag] = 1;
            dbg_dma_cmd_first_desc_cycle_q[tag] = dbg_dma_perf_cycle_q;
          end
          dbg_dma_cmd_chunk_count_q[tag]++;
        end

        if (logical_complete) begin
          int tag;
          longint unsigned descriptor_cycles;
          tag = dbg_dma_active_tag;
          descriptor_cycles = dbg_dma_cmd_descriptor_cycles_q[tag];
          assert (dbg_dma_cmd_valid_q[tag])
            else $fatal(1, "%s: DMA completion without perf record tag %0d",
                        INSTANCE_ID, tag);
          $display("TMEM_DMA_CMD_PERF | {inst=%s, serial=%0d, tag=%0d, op=%s, accept=%0d, first_select=%0d, first_descriptor=%0d, complete=%0d, total=%0d, pending_cycles=%0d, descriptor_active_cycles=%0d, paused_cycles=%0d, chunks=%0d, chunkable=%0d, bypass=%0d}",
                   INSTANCE_ID, dbg_dma_cmd_serial_q[tag], tag,
                   dbg_dma_cmd_is_store_q[tag] ? "STORE" : "LOAD",
                   dbg_dma_cmd_accept_cycle_q[tag],
                   dbg_dma_cmd_first_select_cycle_q[tag],
                   dbg_dma_cmd_first_desc_cycle_q[tag],
                   dbg_dma_perf_cycle_q,
                   dbg_dma_perf_cycle_q - dbg_dma_cmd_accept_cycle_q[tag],
                   dbg_dma_cmd_pending_cycles_q[tag], descriptor_cycles,
                   dbg_dma_cmd_paused_cycles_q[tag],
                   dbg_dma_cmd_chunk_count_q[tag],
                   dbg_dma_cmd_chunkable_q[tag],
                   dbg_dma_cmd_is_store_q[tag]
                     && !dbg_dma_cmd_chunkable_q[tag]);
          dbg_dma_cmd_valid_q[tag] = 0;
        end

        assert (!(dbg_dma_load_descriptor_active
               && dbg_dma_store_descriptor_active))
          else $fatal(1, "%s: load/store descriptors active simultaneously",
                      INSTANCE_ID);
      end
    end
`endif
`endif

    `VX_STATIC_ASSERT(NUM_CHANNELS == 8,
      ("multi-command GEMM DMA requires eight channels"));
    `VX_STATIC_ASSERT(PENDING_DEPTH > 0,
      ("DMA pending depth must be positive"));

    `UNUSED_PARAM (ENTRYID_W)

endmodule
