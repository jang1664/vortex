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
    localparam int BURST_GROUP_SHIFT  = `CLOG2(NUM_BURST_GROUPS);
    localparam int BEAT_STRIDE_HBM_SHIFT = `CLOG2(BEAT_STRIDE_HBM_B);
    localparam int BEAT_STRIDE_TMEM_SHIFT = `CLOG2(BEAT_STRIDE_TMEM_B);
    localparam int PENDING_COUNT_W    = `CLOG2(PENDING_DEPTH + 1);
    localparam int PENDING_INDEX_W    = (PENDING_DEPTH > 1)
                                      ? `CLOG2(PENDING_DEPTH) : 1;
    localparam logic PREP_HIGH_ID     = 1'b0;
    localparam logic PREP_FALLBACK_ID = 1'b1;
    localparam logic DECODE_PROGRAM   = 1'b0;
    localparam logic DECODE_SHADOW    = 1'b1;
    localparam int FOREGROUND_PREPARE = 0;
    localparam int FOREGROUND_CANDIDATE = 1;
    localparam int FOREGROUND_PENDING = 2;
    localparam int FOREGROUND_STORE = 3;
    localparam int FOREGROUND_SOURCES = 4;

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
        S_DECODE,
        S_BUILD,
        S_PROG,
        S_WAIT_DONE
    } state_t;

    function automatic logic [2:0] pow2_div_log2(
        input logic [6:0] v,
        input logic [2:0] cap_log2
    );
        logic [2:0] result;
        logic found;
        begin
            result = cap_log2;
            found = 1'b0;
            for (int b = 0; b <= 6; ++b) begin
                if (!found && v[b]) begin
                    result = 3'(b);
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
    logic foreground_pending_dequeue;
    logic [PENDING_INDEX_W-1:0] foreground_pending_idx;
    logic background_pending_dequeue;
    logic [PENDING_INDEX_W-1:0] background_pending_idx;
    logic pending_dequeue;
    logic [PENDING_INDEX_W-1:0] pending_select_idx;

    // Controller-owned compact candidate table.  Slot 0 is reserved for the
    // oldest high-priority load; slot 1 owns either the next paused store
    // chunk or the oldest low-priority command.  Exactly one candidate is
    // decoded into shadow_desc_q for background PREPARE and chaining.
    logic [1:0] candidate_valid_q;
    logic [1:0] candidate_gen_q;
    pending_cmd_t candidate_owner_q[2];
    logic candidate_is_store_q[2];
    logic candidate_store_new_q[2];
    logic candidate_store_chunkable_q[2];
    logic [31:0] candidate_store_cursor_q[2];
    logic [31:0] candidate_store_remaining_q[2];

    logic shadow_valid_q;
    logic shadow_owner_id_q;
    logic shadow_owner_gen_q;
    logic shadow_prepared_q;
    logic [31:0] shadow_chunk_beats_q;
    channel_desc_t shadow_desc_q[NUM_CHANNELS];
    logic [NUM_CHANNELS-1:0] shadow_prepare_accept_q;
    logic [1:0] shadow_result_ready_q[NUM_CHANNELS];
    logic shadow_decode_needed;
    logic shadow_decode_id;
    logic shadow_owner_live;
    logic shadow_invalidate;

    logic candidate_capture;
    logic candidate_capture_from_pending;
    logic candidate_capture_store_cont;
    logic candidate_capture_id;
    logic [PENDING_INDEX_W-1:0] candidate_capture_idx;
    logic issue_candidate_q;
    logic issue_candidate_id_q;
    logic candidate_select;
    logic candidate_select_id;
    logic store_context_select;
    logic shadow_prepared_now;
    logic chain_candidate_select;
    logic chain_candidate_id;
    logic chain_candidate_offer;
    logic chain_candidate_fire;

    logic prepare_active_q;

    gemm_unified_cmd_t work_cmd_q;
    logic [GEMM_DMA_TAG_WIDTH-1:0] work_tag_q;
    logic [FOREGROUND_SOURCES-1:0] foreground_owner_q;
    logic [GEMM_DMA_TAG_WIDTH-1:0] foreground_prepare_tag_q;
    logic [GEMM_DMA_TAG_WIDTH-1:0] foreground_candidate_tag_q;
    logic [GEMM_DMA_TAG_WIDTH-1:0] foreground_pending_tag_q;
    logic [GEMM_DMA_TAG_WIDTH-1:0] foreground_store_tag_q;
    logic [GEMM_DMA_TAG_WIDTH-1:0] foreground_tag;
    logic work_is_store_q;
    logic work_store_new_q;
    logic work_data_prefetched_q;
    logic work_data_released_q;

    logic decode_valid_q;
    gemm_unified_cmd_t decode_cmd_q;
    logic decode_target_q;
    logic decode_candidate_valid_q;
    logic decode_candidate_id_q;
    logic decode_candidate_gen_q;
    logic decode_is_store_q;
    logic decode_store_new_q;
    logic decode_store_chunkable_q;
    logic [31:0] decode_store_cursor_q;
    logic [31:0] decode_store_remaining_q;
    logic decode_request;
    gemm_unified_cmd_t decode_request_cmd;
    logic decode_request_target;
    logic decode_request_candidate_valid;
    logic decode_request_candidate_id;
    logic decode_request_candidate_gen;
    logic decode_request_is_store;
    logic decode_request_store_new;
    logic decode_request_store_chunkable;
    logic [31:0] decode_request_store_cursor;
    logic [31:0] decode_request_store_remaining;
    logic decode_shadow_inflight;
    logic decode_shadow_result_commit;

    channel_desc_t decoded_desc[NUM_CHANNELS];
    logic [2:0] decoded_bnd0_log2[NUM_CHANNELS];
    logic decoded_bound_overflow[NUM_CHANNELS];
    logic decoded_chunkable;
    logic [31:0] decoded_beats_per_bank;

    channel_desc_t load_desc_q[NUM_CHANNELS];
    channel_desc_t program_desc_q[NUM_CHANNELS];
    logic [NUM_CHANNELS-1:0] active_channel_mask_q;

    logic store_context_valid_q;
    logic store_chunkable_q;
    gemm_unified_cmd_t store_cmd_q;
    logic [GEMM_DMA_TAG_WIDTH-1:0] store_tag_q;
    logic [31:0] store_bank_beat_cursor_q;
    logic [31:0] store_remaining_beats_per_bank_q;
    logic [31:0] issued_chunk_beats_per_bank_q;

    channel_desc_t built_desc[NUM_CHANNELS];
    logic [31:0] built_chunk_beats_per_bank;
    logic built_bound_overflow;
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
    logic shadow_cfg_all_ready;
    logic [NUM_CHANNELS-1:0] cfg_channel_ready_s;
    logic [NUM_CHANNELS-1:0] cfg_valid_s;
    logic [NUM_CHANNELS-1:0] cfg_fire_s;
    logic [PENDING_COUNT_W:0] pending_capacity_used;

    // A prepared command remains the ordered DMA-child queue head until its
    // release handshake.  Use that ownership contract for synthesis instead
    // of rebuilding a full-width command comparator in the ready path.  The
    // command identity is still checked at the handshake in simulation.
    wire prepared_release_match = work_data_prefetched_q
                                && !work_data_released_q;
    wire cmd_accept = gemm_dma_ctrl_if.cmd_valid
                   && gemm_dma_ctrl_if.cmd_ready;
    wire prepared_release_accept = cmd_accept
                                 && work_data_prefetched_q
                                 && !work_data_released_q;
    wire cmd_enqueue = cmd_accept && !prepared_release_accept;
    wire data_prepare_accept = gemm_dma_ctrl_if.prepare_valid
                             && gemm_dma_ctrl_if.prepare_ready;
    // Release is registered before destination commit is enabled.  This keeps
    // a prepared completion strictly after the tag scoreboard insertion edge.
    wire work_release_visible = !work_data_prefetched_q
                              || work_data_released_q;
    wire accepted_high_now = cmd_enqueue
                           && gemm_dma_ctrl_if.cmd.dma_priority;
    wire cfg_all_ready = &cfg_ready_or_inactive;
    wire done_all_valid = &(done_sticky_q | done_or_inactive);
    wire completion_event = (state_q == S_WAIT_DONE)
                          && done_all_valid
                          && work_release_visible;
    wire store_chunk_last = !store_chunkable_q
                         || (issued_chunk_beats_per_bank_q
                             >= store_remaining_beats_per_bank_q);
    wire logical_complete = completion_event
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

    assign gemm_dma_ctrl_if.cmd_ready = work_data_prefetched_q
                                     && !work_data_released_q
        ? prepared_release_match
        : (pending_capacity_used < (PENDING_COUNT_W+1)'(PENDING_DEPTH));
    assign gemm_dma_ctrl_if.prepare_ready = (state_q == S_SELECT)
                                         && (pending_count_q == 0)
                                         && !store_context_valid_q
                                         && !(|candidate_valid_q)
                                         && !prepare_active_q
                                         && !work_data_prefetched_q
                                         && !gemm_dma_ctrl_if.cmd_valid;
    assign gemm_dma_ctrl_if.done = logical_complete;
    assign gemm_dma_ctrl_if.done_tag = work_is_store_q
                                     ? store_tag_q : work_tag_q;
    assign gemm_dma_ctrl_if.idle = (state_q == S_SELECT)
                                && (pending_count_q == 0)
                                && !store_context_valid_q
                                && !(|candidate_valid_q)
                                && !prepare_active_q
                                && !work_data_prefetched_q;
    assign store_done = logical_complete && work_is_store_q;

    assign gemm_sync_if.valid   = 1'b0;
    assign gemm_sync_if.reg_idx = 32'd0;
    assign gemm_sync_if.value   = 32'd0;

    always_comb begin
        shadow_owner_live = shadow_valid_q
                         && candidate_valid_q[shadow_owner_id_q]
                         && (candidate_gen_q[shadow_owner_id_q]
                             == shadow_owner_gen_q);
        decode_shadow_inflight = decode_valid_q
                              && (decode_target_q == DECODE_SHADOW)
                              && decode_candidate_valid_q
                              && candidate_valid_q[decode_candidate_id_q]
                              && (candidate_gen_q[decode_candidate_id_q]
                                  == decode_candidate_gen_q);
        decode_shadow_result_commit = decode_shadow_inflight;
    end


    always_comb begin
        shadow_decode_needed = 1'b0;
        shadow_decode_id = PREP_HIGH_ID;
        if (!prepare_active_q) begin
            if (candidate_valid_q[PREP_HIGH_ID]
             && (!shadow_owner_live
              || (shadow_owner_id_q != PREP_HIGH_ID))
             && (!decode_shadow_inflight
              || (decode_candidate_id_q != PREP_HIGH_ID))) begin
                shadow_decode_needed = 1'b1;
                shadow_decode_id = PREP_HIGH_ID;
            end else if (!candidate_valid_q[PREP_HIGH_ID]
                      && candidate_valid_q[PREP_FALLBACK_ID]
                      && (!shadow_owner_live
                       || (shadow_owner_id_q != PREP_FALLBACK_ID))
                      && (!decode_shadow_inflight
                       || (decode_candidate_id_q
                           != PREP_FALLBACK_ID))) begin
                shadow_decode_needed = 1'b1;
                shadow_decode_id = PREP_FALLBACK_ID;
            end
        end
    end

    always_comb begin
        prepare_all_accepted = prepare_active_q;
        prepare_all_results_ready = prepare_active_q;
        for (int ch = 0; ch < NUM_CHANNELS; ++ch) begin
            if (shadow_desc_q[ch].active) begin
                prepare_all_accepted &=
                    shadow_prepare_accept_q[ch]
                    || (lookahead_prepare_valid_s[ch]
                     && lookahead_prepare_ready_s[ch]);
                prepare_all_results_ready &=
                    &(shadow_result_ready_q[ch]
                    | lookahead_result_ready_s[ch]);
            end
        end
    end

    always_comb begin
        shadow_prepared_now = shadow_prepared_q;
        if (prepare_active_q
         && prepare_all_accepted
         && prepare_all_results_ready)
            shadow_prepared_now = 1'b1;
    end

    always_comb begin
        shadow_cfg_all_ready = 1'b1;
        for (int ch = 0; ch < NUM_CHANNELS; ++ch) begin
            if (shadow_desc_q[ch].active)
                shadow_cfg_all_ready &= cfg_channel_ready_s[ch];
        end
    end

    // A completion edge may directly activate only a fully prepared
    // candidate.  Any visible high-priority load, including one accepted on
    // this edge, suppresses fallback chaining.  An unprepared high candidate
    // is retained for the ordinary S_SELECT -> S_PROG slow path.
    always_comb begin
        chain_candidate_select = 1'b0;
        chain_candidate_id = PREP_HIGH_ID;
        if (completion_event) begin
            if (candidate_valid_q[PREP_HIGH_ID]) begin
                if (shadow_owner_live
                 && (shadow_owner_id_q == PREP_HIGH_ID)
                 && shadow_prepared_now) begin
                    chain_candidate_select = 1'b1;
                    chain_candidate_id = PREP_HIGH_ID;
                end
            end else if (!pending_high_found && !accepted_high_now
                      && candidate_valid_q[PREP_FALLBACK_ID]
                      && shadow_owner_live
                      && (shadow_owner_id_q == PREP_FALLBACK_ID)
                      && shadow_prepared_now) begin
                chain_candidate_select = 1'b1;
                chain_candidate_id = PREP_FALLBACK_ID;
            end
        end
    end

    // Scheduling selection and its source-owned offer are independent of
    // channel readiness.  Only the fire qualifier consumes ownership and
    // updates state.  Keeping readiness out of valid/ACTIVATE generation
    // avoids a ready -> valid/ACTIVATE -> ready feedback loop.
    always_comb begin
        chain_candidate_offer = chain_candidate_select;
        chain_candidate_fire = chain_candidate_offer
                            && shadow_cfg_all_ready;
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
        foreground_pending_dequeue = 1'b0;
        foreground_pending_idx = '0;
        candidate_select = 1'b0;
        candidate_select_id = 1'b0;
        store_context_select = 1'b0;

        unique case (state_q)
            S_SELECT: begin
                if (data_prepare_accept) begin
                    state_d = S_CAPTURE;
                end else if (candidate_valid_q[PREP_HIGH_ID]) begin
                    candidate_select = 1'b1;
                    candidate_select_id = 1'b0;
                    state_d = S_CAPTURE;
                end else if (pending_high_found) begin
                    foreground_pending_dequeue = 1'b1;
                    foreground_pending_idx = pending_high_idx;
                    state_d = S_CAPTURE;
                end else if (accepted_high_now) begin
                    // The accepted load becomes visible in pending_q after
                    // this edge.  Do not start fallback work in parallel.
                    state_d = S_SELECT;
                end else if (candidate_valid_q[PREP_FALLBACK_ID]) begin
                    candidate_select = 1'b1;
                    candidate_select_id = 1'b1;
                    state_d = S_CAPTURE;
                end else if (store_context_valid_q) begin
                    store_context_select = 1'b1;
                    state_d = S_CAPTURE;
                end else if (pending_low_found) begin
                    foreground_pending_dequeue = 1'b1;
                    foreground_pending_idx = pending_low_idx;
                    state_d = S_CAPTURE;
                end
            end

            S_CAPTURE: begin
                state_d = S_DECODE;
            end

            S_DECODE: begin
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
                if (completion_event) begin
                    state_d = chain_candidate_offer ? S_WAIT_DONE : S_SELECT;
                end
            end

            default: begin
                state_d = S_SELECT;
            end
        endcase
    end

    // Foreground tag ownership is captured at selection into a narrow token
    // and source-local snapshots.  The wide command context is still accepted
    // on the same edge, while work_tag_q is materialized one registered phase
    // later in S_CAPTURE.  This removes the source-priority cone from the
    // canonical tag register enable without adding an FSM state.
    always_comb begin
        foreground_tag = '0;
        unique case (1'b1)
            foreground_owner_q[FOREGROUND_PREPARE]:
                foreground_tag = foreground_prepare_tag_q;
            foreground_owner_q[FOREGROUND_CANDIDATE]:
                foreground_tag = foreground_candidate_tag_q;
            foreground_owner_q[FOREGROUND_PENDING]:
                foreground_tag = foreground_pending_tag_q;
            foreground_owner_q[FOREGROUND_STORE]:
                foreground_tag = foreground_store_tag_q;
            default: begin
            end
        endcase
    end

    // Completion and candidate capture are independent transactions.  Slot
    // availability is evaluated from pre-edge ownership, so a candidate
    // consumed by chaining cannot be rewritten on the same edge.  A distinct
    // empty slot may capture pending work concurrently with completion.
    always_comb begin
        candidate_capture = 1'b0;
        candidate_capture_from_pending = 1'b0;
        candidate_capture_store_cont = 1'b0;
        candidate_capture_id = PREP_HIGH_ID;
        candidate_capture_idx = '0;
        background_pending_dequeue = 1'b0;
        background_pending_idx = '0;

        if (state_q == S_WAIT_DONE) begin
            if (!candidate_valid_q[PREP_HIGH_ID]
             && pending_high_found) begin
                candidate_capture = 1'b1;
                candidate_capture_from_pending = 1'b1;
                candidate_capture_id = PREP_HIGH_ID;
                candidate_capture_idx = pending_high_idx;
                background_pending_dequeue = 1'b1;
                background_pending_idx = pending_high_idx;
            end else if (!candidate_valid_q[PREP_FALLBACK_ID]) begin
                if (store_context_valid_q
                 && (!work_is_store_q || !store_chunk_last)) begin
                    candidate_capture = 1'b1;
                    candidate_capture_store_cont = 1'b1;
                    candidate_capture_id = PREP_FALLBACK_ID;
                end else if (pending_low_found) begin
                    candidate_capture = 1'b1;
                    candidate_capture_from_pending = 1'b1;
                    candidate_capture_id = PREP_FALLBACK_ID;
                    candidate_capture_idx = pending_low_idx;
                    background_pending_dequeue = 1'b1;
                    background_pending_idx = pending_low_idx;
                end
            end
        end
    end

    // The pending queue has one physical removal port.  Foreground selection
    // and background capture are mutually exclusive by registered FSM phase;
    // combine them explicitly so every dequeue has a committed owner.
    always_comb begin
        pending_dequeue = foreground_pending_dequeue
                       || background_pending_dequeue;
        pending_select_idx = foreground_pending_dequeue
                           ? foreground_pending_idx : background_pending_idx;
    end

    always_comb begin
        shadow_invalidate = shadow_owner_live
                         && (shadow_owner_id_q == PREP_FALLBACK_ID)
                         && candidate_valid_q[PREP_HIGH_ID]
                         && !prepare_active_q
                         && !decode_shadow_result_commit;
    end

    // Register the complete decoder input and provenance.  Descriptor decode
    // and chunk arithmetic below consume only decode_*_q, never pending queue
    // selection or DMA completion control.
    always_comb begin
        decode_request = 1'b0;
        decode_request_cmd = '0;
        decode_request_target = DECODE_PROGRAM;
        decode_request_candidate_valid = 1'b0;
        decode_request_candidate_id = PREP_HIGH_ID;
        decode_request_candidate_gen = 1'b0;
        decode_request_is_store = 1'b0;
        decode_request_store_new = 1'b0;
        decode_request_store_chunkable = 1'b0;
        decode_request_store_cursor = 32'd0;
        decode_request_store_remaining = 32'd0;

        if (!decode_valid_q && (state_q == S_CAPTURE)) begin
            decode_request = 1'b1;
            decode_request_cmd = work_cmd_q;
            decode_request_target = DECODE_PROGRAM;
            decode_request_candidate_valid = issue_candidate_q;
            decode_request_candidate_id = issue_candidate_id_q;
            decode_request_candidate_gen =
                candidate_gen_q[issue_candidate_id_q];
            decode_request_is_store = work_is_store_q;
            decode_request_store_new = work_store_new_q;
            decode_request_store_chunkable = store_chunkable_q;
            decode_request_store_cursor = store_bank_beat_cursor_q;
            decode_request_store_remaining =
                store_remaining_beats_per_bank_q;
        end else if (!decode_valid_q && (state_q == S_WAIT_DONE)
                  && shadow_decode_needed) begin
            decode_request = 1'b1;
            decode_request_cmd = candidate_owner_q[shadow_decode_id].cmd;
            decode_request_target = DECODE_SHADOW;
            decode_request_candidate_valid = 1'b1;
            decode_request_candidate_id = shadow_decode_id;
            decode_request_candidate_gen = candidate_gen_q[shadow_decode_id];
            decode_request_is_store = candidate_is_store_q[shadow_decode_id];
            decode_request_store_new =
                candidate_store_new_q[shadow_decode_id];
            decode_request_store_chunkable =
                candidate_store_chunkable_q[shadow_decode_id];
            decode_request_store_cursor =
                candidate_store_cursor_q[shadow_decode_id];
            decode_request_store_remaining =
                candidate_store_remaining_q[shadow_decode_id];
        end
    end

    // Decode the selected logical command into complete channel descriptors.
    wire [3:0] decode_op = decode_cmd_q.instr[3:0];
    wire decode_is_store = (decode_op == OP_DMA_ST);
    wire [63:0] decode_src_base = 64'(decode_cmd_q.rs2_data);
    wire [63:0] decode_dst_base = 64'(decode_cmd_q.rs1_data);
    wire [31:0] decode_seg_size = {4'd0, decode_cmd_q.instr[31:4]};
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
        wire [31:0] total_bpb = ch_words >> BURST_GROUP_SHIFT;
        wire [2:0] s_bob_log2 =
            pow2_div_log2({1'b0, bank_off_beats}, 3'd6);
        wire [2:0] s_tbpb_log2 =
            pow2_div_log2(total_bpb[6:0], 3'd0);
        wire [2:0] sub_burst_log2 =
            (s_bob_log2 <= s_tbpb_log2) ? s_bob_log2 : s_tbpb_log2;
        wire [6:0] sub_burst_size = 7'd1 << sub_burst_log2;
        wire burst_mode = (ch_words >= 32'(NUM_BURST_GROUPS))
                       && ((ch_words
                            & 32'(NUM_BURST_GROUPS - 1)) == 0);
        assign decoded_bound_overflow[ch] = burst_mode
            ? ((total_bpb >> sub_burst_log2 >> `DMA_BOUND_WIDTH) != 0)
            : ((ch_words >> `DMA_BOUND_WIDTH) != 0);

        always_comb begin
            decoded_bnd0_log2[ch] = burst_mode ? sub_burst_log2 : 3'd0;
            decoded_desc[ch] = '0;
            decoded_desc[ch].active = ch_active;
            decoded_desc[ch].burst_mode = burst_mode;
            decoded_desc[ch].regs[DMA_R_CONTROL] = ch_active ? 32'd1 : 32'd0;
            decoded_desc[ch].regs[DMA_R_DST_BASE_LO] = ch_dst_base[31:0];
            decoded_desc[ch].regs[DMA_R_DST_BASE_HI] = ch_dst_base[63:32];
            decoded_desc[ch].regs[DMA_R_SRC_BASE_LO] = ch_src_base[31:0];
            decoded_desc[ch].regs[DMA_R_SRC_BASE_HI] = ch_src_base[63:32];

            if (burst_mode) begin
                decoded_desc[ch].regs[DMA_R_BND0]
                    = 32'(`DMA_BOUND_WIDTH'(sub_burst_size));
                decoded_desc[ch].regs[DMA_R_BND1] =
                    32'(`DMA_BOUND_WIDTH'(total_bpb >> sub_burst_log2));
                decoded_desc[ch].regs[DMA_R_BND2]
                    = 32'(`DMA_BOUND_WIDTH'(NUM_BURST_GROUPS));
                decoded_desc[ch].regs[DMA_R_SRC_ST0] = decode_is_store
                    ? 32'(BEAT_STRIDE_TMEM_B) : 32'(BEAT_STRIDE_HBM_B);
                decoded_desc[ch].regs[DMA_R_DST_ST0] = decode_is_store
                    ? 32'(BEAT_STRIDE_HBM_B) : 32'(BEAT_STRIDE_TMEM_B);
                decoded_desc[ch].regs[DMA_R_SRC_ST1] =
                    (decode_is_store
                     ? 32'(BEAT_STRIDE_TMEM_B) : 32'(BEAT_STRIDE_HBM_B))
                    << sub_burst_log2;
                decoded_desc[ch].regs[DMA_R_DST_ST1] =
                    (decode_is_store
                     ? 32'(BEAT_STRIDE_HBM_B) : 32'(BEAT_STRIDE_TMEM_B))
                    << sub_burst_log2;
                decoded_desc[ch].regs[DMA_R_SRC_ST2] = decode_is_store
                    ? 32'(BANK_STRIDE_TMEM_B) : 32'(BANK_STRIDE_HBM_B);
                decoded_desc[ch].regs[DMA_R_DST_ST2] = decode_is_store
                    ? 32'(BANK_STRIDE_HBM_B) : 32'(BANK_STRIDE_TMEM_B);
            end else begin
                decoded_desc[ch].regs[DMA_R_BND0]
                    = 32'(`DMA_BOUND_WIDTH'(1));
                decoded_desc[ch].regs[DMA_R_BND1]
                    = 32'(`DMA_BOUND_WIDTH'(ch_words));
                decoded_desc[ch].regs[DMA_R_BND2]
                    = 32'(`DMA_BOUND_WIDTH'(1));
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
        decoded_beats_per_bank =
            decoded_desc[0].regs[DMA_R_BND1]
            << decoded_bnd0_log2[0];
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

    // Chunk construction is shared by the foreground slow path and the one
    // decoded candidate shadow.  Original store descriptors are regenerated
    // from the compact command, so no candidate-indexed store descriptor copy
    // is required.
    always_comb begin
        logic [31:0] orig_bnd0;
        logic [31:0] max_chunk_beats;
        logic [31:0] bank_budget;
        logic [31:0] chunk_bnd0;
        logic [31:0] chunk_bnd1;
        logic [31:0] rows_by_remaining;
        logic [31:0] rows_by_budget;
        logic [5:0] orig_bnd0_log2;
        logic [5:0] max_chunk_log2;
        logic [5:0] bank_budget_log2;
        logic [5:0] chunk_bnd0_log2;

        builder_is_store = work_is_store_q;
        builder_store_chunkable = store_chunkable_q;
        builder_store_cmd = store_cmd_q;
        builder_store_cursor = store_bank_beat_cursor_q;
        builder_store_remaining = store_remaining_beats_per_bank_q;
        for (int ch = 0; ch < NUM_CHANNELS; ++ch) begin
            builder_store_desc[ch] = decoded_desc[ch];
            builder_default_desc[ch] = work_is_store_q
                                     ? decoded_desc[ch] : load_desc_q[ch];
        end

        if (decode_shadow_result_commit) begin
            builder_is_store = decode_is_store_q;
            builder_store_chunkable = decode_store_new_q
                ? decoded_chunkable : decode_store_chunkable_q;
            builder_store_cmd = decode_cmd_q;
            builder_store_cursor = decode_store_cursor_q;
            builder_store_remaining = decode_store_new_q
                ? decoded_beats_per_bank
                : decode_store_remaining_q;
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
                << BEAT_STRIDE_TMEM_SHIFT;
            chunk_dst_offset[ch] = 64'(builder_store_cursor)
                << BEAT_STRIDE_HBM_SHIFT;
        end

        built_chunk_beats_per_bank = 32'd0;
        built_bound_overflow = 1'b0;
        orig_bnd0 = builder_store_desc[0].regs[DMA_R_BND0];
        max_chunk_beats = 32'd0;
        bank_budget = 32'd0;
        chunk_bnd0 = orig_bnd0;
        chunk_bnd1 = builder_store_desc[0].regs[DMA_R_BND1];
        rows_by_remaining = 32'd0;
        rows_by_budget = 32'd0;
        orig_bnd0_log2 = 6'(decoded_bnd0_log2[0]);
        max_chunk_log2 = 6'd0;
        bank_budget_log2 = 6'd0;
        chunk_bnd0_log2 = orig_bnd0_log2;

        if (builder_is_store && builder_store_chunkable) begin
            if (builder_store_cmd.dma_max_chunk_log2p1 == 0) begin
                max_chunk_beats =
                    builder_store_desc[0].regs[DMA_R_BND1]
                    << (orig_bnd0_log2 + BURST_GROUP_SHIFT);
            end else begin
                max_chunk_log2 =
                    6'(builder_store_cmd.dma_max_chunk_log2p1 - 1'b1);
                max_chunk_beats = 32'd1
                    << max_chunk_log2;
            end

            bank_budget = max_chunk_beats >> BURST_GROUP_SHIFT;
            if (bank_budget >= orig_bnd0) begin
                rows_by_remaining =
                    builder_store_remaining >> orig_bnd0_log2;
                rows_by_budget = bank_budget >> orig_bnd0_log2;
                chunk_bnd0 = orig_bnd0;
                chunk_bnd1 = (rows_by_remaining <= rows_by_budget)
                           ? rows_by_remaining : rows_by_budget;
            end else begin
                chunk_bnd0 = bank_budget;
                chunk_bnd1 = 32'd1;
                if (bank_budget != 0) begin
                    bank_budget_log2 =
                        max_chunk_log2 - BURST_GROUP_SHIFT;
                    chunk_bnd0_log2 = bank_budget_log2;
                end
            end

            built_chunk_beats_per_bank = (chunk_bnd0 == 0)
                ? 32'd0 : (chunk_bnd1 << chunk_bnd0_log2);
            built_bound_overflow = ((chunk_bnd0 >> `DMA_BOUND_WIDTH) != 0)
                                || ((chunk_bnd1 >> `DMA_BOUND_WIDTH) != 0);
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
                built_desc[ch].regs[DMA_R_BND0]
                    = 32'(`DMA_BOUND_WIDTH'(chunk_bnd0));
                built_desc[ch].regs[DMA_R_BND1]
                    = 32'(`DMA_BOUND_WIDTH'(chunk_bnd1));
                built_desc[ch].regs[DMA_R_SRC_ST1] = (chunk_bnd0 == 0)
                    ? 32'd0
                    : (32'(BEAT_STRIDE_TMEM_B) << chunk_bnd0_log2);
                built_desc[ch].regs[DMA_R_DST_ST1] = (chunk_bnd0 == 0)
                    ? 32'd0
                    : (32'(BEAT_STRIDE_HBM_B) << chunk_bnd0_log2);
            end
        end else if (builder_is_store) begin
            built_chunk_beats_per_bank =
                builder_store_remaining;
        end
    end

    for (genvar ch = 0; ch < NUM_CHANNELS; ++ch) begin : g_issue_channels
        assign cfg_channel_ready_s[ch] = cfg_reg_if[ch].ready;
        wire chain_channel_active = shadow_desc_q[ch].active;
        wire program_channel_active = (state_q == S_WAIT_DONE)
                                    ? chain_channel_active
                                    : program_desc_q[ch].active;

        // The registered FSM phase selects the wide descriptor bus before
        // completion.  done_all_valid controls only the narrow valid/ACTIVATE
        // transaction and cannot enter this configuration-data mux.
        assign cfg_reg_if[ch].regs = (state_q == S_WAIT_DONE)
                                  ? shadow_desc_q[ch].regs
                                  : program_desc_q[ch].regs;
        assign cfg_reg_if[ch].entry_id = 32'd0;
        assign cfg_reg_if[ch].valid = ((state_q == S_PROG)
                                    && cfg_all_ready
                                    && program_desc_q[ch].active)
                                    || (chain_candidate_offer
                                     && chain_channel_active);
        assign cfg_valid_s[ch] = cfg_reg_if[ch].valid;
        assign cfg_fire_s[ch] = cfg_reg_if[ch].valid
                              && cfg_reg_if[ch].ready;
        assign lookahead_if[ch].prepare_valid = prepare_active_q
            && shadow_owner_live
            && shadow_desc_q[ch].active
            && !shadow_prepare_accept_q[ch]
            && !((state_q == S_PROG) && issue_candidate_q
              && (issue_candidate_id_q == shadow_owner_id_q));
        assign lookahead_prepare_valid_s[ch] = lookahead_if[ch].prepare_valid;
        assign lookahead_prepare_ready_s[ch] = lookahead_if[ch].prepare_ready;
        assign lookahead_result_ready_s[ch] = lookahead_if[ch].result_ready;
        assign lookahead_if[ch].prepare_id = shadow_owner_id_q;
        assign lookahead_if[ch].src_stride[0] =
            shadow_desc_q[ch].regs[DMA_R_SRC_ST0];
        assign lookahead_if[ch].src_stride[1] =
            shadow_desc_q[ch].regs[DMA_R_SRC_ST1];
        assign lookahead_if[ch].dst_stride[0] =
            shadow_desc_q[ch].regs[DMA_R_DST_ST0];
        assign lookahead_if[ch].dst_stride[1] =
            shadow_desc_q[ch].regs[DMA_R_DST_ST1];
        assign lookahead_if[ch].bound[0] =
            shadow_desc_q[ch].regs[DMA_R_BND0][`DMA_BOUND_WIDTH-1:0];
        assign lookahead_if[ch].bound[1] =
            shadow_desc_q[ch].regs[DMA_R_BND1][`DMA_BOUND_WIDTH-1:0];
        assign lookahead_if[ch].activate = ((state_q == S_PROG)
                                         && cfg_all_ready
                                         && issue_candidate_q
                                         && program_desc_q[ch].active)
                                         || (chain_candidate_offer
                                          && chain_channel_active);
        assign lookahead_if[ch].activate_id = (state_q == S_WAIT_DONE)
                                            ? shadow_owner_id_q
                                            : issue_candidate_id_q;
        assign lookahead_if[ch].data_release = work_release_visible;
        assign lookahead_if[ch].data_max_beats = work_data_prefetched_q
            ? work_cmd_q.prepare.max_beats : '0;
        assign lookahead_activate_s[ch] = lookahead_if[ch].activate;
        assign lookahead_activate_id_s[ch] = lookahead_if[ch].activate_id;
        assign cfg_ready_or_inactive[ch] = program_channel_active
            ? cfg_reg_if[ch].ready : 1'b1;
        assign done_or_inactive[ch] = active_channel_mask_q[ch]
            ? done_if[ch].valid : 1'b1;
        assign done_if[ch].ready = (state_q == S_WAIT_DONE);
    end

    always_ff @(posedge clk) begin
        if (reset) begin
            state_q <= S_SELECT;
            pending_count_q <= '0;
            work_cmd_q <= '0;
            work_tag_q <= '0;
            foreground_owner_q <= '0;
            foreground_prepare_tag_q <= '0;
            foreground_candidate_tag_q <= '0;
            foreground_pending_tag_q <= '0;
            foreground_store_tag_q <= '0;
            work_is_store_q <= 1'b0;
            work_store_new_q <= 1'b0;
            work_data_prefetched_q <= 1'b0;
            work_data_released_q <= 1'b0;
            decode_valid_q <= 1'b0;
            decode_cmd_q <= '0;
            decode_target_q <= DECODE_PROGRAM;
            decode_candidate_valid_q <= 1'b0;
            decode_candidate_id_q <= PREP_HIGH_ID;
            decode_candidate_gen_q <= 1'b0;
            decode_is_store_q <= 1'b0;
            decode_store_new_q <= 1'b0;
            decode_store_chunkable_q <= 1'b0;
            decode_store_cursor_q <= '0;
            decode_store_remaining_q <= '0;
            store_context_valid_q <= 1'b0;
            store_chunkable_q <= 1'b0;
            store_cmd_q <= '0;
            store_tag_q <= '0;
            store_bank_beat_cursor_q <= '0;
            store_remaining_beats_per_bank_q <= '0;
            issued_chunk_beats_per_bank_q <= '0;
            active_channel_mask_q <= '0;
            done_sticky_q <= '0;
            candidate_valid_q <= '0;
            candidate_gen_q <= '0;
            shadow_valid_q <= 1'b0;
            shadow_owner_id_q <= 1'b0;
            shadow_owner_gen_q <= 1'b0;
            shadow_prepared_q <= 1'b0;
            shadow_chunk_beats_q <= '0;
            shadow_prepare_accept_q <= '0;
            issue_candidate_q <= 1'b0;
            issue_candidate_id_q <= 1'b0;
            prepare_active_q <= 1'b0;
            for (int idx = 0; idx < PENDING_DEPTH; ++idx)
                pending_q[idx] <= '0;
            for (int id = 0; id < 2; ++id) begin
                candidate_owner_q[id] <= '0;
                candidate_is_store_q[id] <= 1'b0;
                candidate_store_new_q[id] <= 1'b0;
                candidate_store_chunkable_q[id] <= 1'b0;
                candidate_store_cursor_q[id] <= '0;
                candidate_store_remaining_q[id] <= '0;
            end
            for (int ch = 0; ch < NUM_CHANNELS; ++ch) begin
                load_desc_q[ch] <= '0;
                program_desc_q[ch] <= '0;
                shadow_desc_q[ch] <= '0;
                shadow_result_ready_q[ch] <= '0;
            end
        end else begin
            state_q <= state_d;

            // All source tags are sampled in parallel.  Only the registered
            // one-hot token chooses the canonical tag in S_CAPTURE, so source
            // priority does not feed work_tag_q on the selection edge.
            if (state_q == S_SELECT) begin
                foreground_owner_q <= {
                    store_context_select,
                    foreground_pending_dequeue,
                    candidate_select,
                    data_prepare_accept
                };
                foreground_prepare_tag_q <= '0;
                foreground_candidate_tag_q
                    <= candidate_owner_q[candidate_select_id].tag;
                foreground_pending_tag_q
                    <= pending_q[foreground_pending_idx].tag;
                foreground_store_tag_q <= store_tag_q;
            end else if (state_q == S_CAPTURE) begin
                foreground_owner_q <= '0;
            end

            if (state_q == S_CAPTURE) begin
                work_tag_q <= foreground_tag;
            end

            // Decoder requests are captured independently of completion.
            // decode_valid_q represents exactly one result cycle; a new
            // request may replace a result only on its consuming edge.
            decode_valid_q <= decode_request;
            if (decode_request) begin
                decode_cmd_q <= decode_request_cmd;
                decode_target_q <= decode_request_target;
                decode_candidate_valid_q
                    <= decode_request_candidate_valid;
                decode_candidate_id_q <= decode_request_candidate_id;
                decode_candidate_gen_q <= decode_request_candidate_gen;
                decode_is_store_q <= decode_request_is_store;
                decode_store_new_q <= decode_request_store_new;
                decode_store_chunkable_q
                    <= decode_request_store_chunkable;
                decode_store_cursor_q <= decode_request_store_cursor;
                decode_store_remaining_q <=
                    decode_request_store_remaining;
            end

            unique case ({cmd_enqueue, pending_dequeue})
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

            if (data_prepare_accept) begin
                work_cmd_q <= gemm_dma_ctrl_if.prepare_cmd;
                work_is_store_q <= 1'b0;
                work_store_new_q <= 1'b0;
                work_data_prefetched_q <= 1'b1;
                work_data_released_q <= 1'b0;
                issue_candidate_q <= 1'b0;
            end else if ((state_q == S_SELECT) && candidate_select) begin
                work_cmd_q <= candidate_owner_q[candidate_select_id].cmd;
                work_is_store_q <= candidate_is_store_q[candidate_select_id];
                work_store_new_q <=
                    candidate_store_new_q[candidate_select_id];
                work_data_prefetched_q <= 1'b0;
                work_data_released_q <= 1'b1;
                issue_candidate_q <= 1'b1;
                issue_candidate_id_q <= candidate_select_id;
                done_sticky_q <= '0;

                if (candidate_store_new_q[candidate_select_id]) begin
                    store_context_valid_q <= 1'b1;
                    store_chunkable_q <=
                        candidate_store_chunkable_q[candidate_select_id];
                    store_cmd_q <= candidate_owner_q[candidate_select_id].cmd;
                    store_tag_q <= candidate_owner_q[candidate_select_id].tag;
                    store_bank_beat_cursor_q <=
                        candidate_store_cursor_q[candidate_select_id];
                    store_remaining_beats_per_bank_q <=
                        candidate_store_remaining_q[candidate_select_id];
                end
            end else if ((state_q == S_SELECT) && pending_dequeue) begin
                work_cmd_q <= pending_q[pending_select_idx].cmd;
                work_is_store_q <=
                    (pending_q[pending_select_idx].cmd.instr[3:0]
                     == OP_DMA_ST);
                work_store_new_q <=
                    (pending_q[pending_select_idx].cmd.instr[3:0]
                     == OP_DMA_ST);
                work_data_prefetched_q <= 1'b0;
                work_data_released_q <= 1'b1;
                issue_candidate_q <= 1'b0;
            end else if ((state_q == S_SELECT)
                      && store_context_select) begin
                work_cmd_q <= store_cmd_q;
                work_is_store_q <= 1'b1;
                work_store_new_q <= 1'b0;
                work_data_prefetched_q <= 1'b0;
                work_data_released_q <= 1'b1;
                issue_candidate_q <= 1'b0;
            end

            if (prepared_release_accept) begin
                work_tag_q <= gemm_dma_ctrl_if.cmd_tag;
                work_data_released_q <= 1'b1;
            end

            if (decode_valid_q
             && (decode_target_q == DECODE_PROGRAM)) begin
                if (decode_is_store_q && decode_store_new_q) begin
                    store_context_valid_q <= 1'b1;
                    store_chunkable_q <= decoded_chunkable;
                    store_cmd_q <= decode_cmd_q;
                    store_tag_q <= work_tag_q;
                    store_bank_beat_cursor_q <= 32'd0;
                    store_remaining_beats_per_bank_q <=
                        decoded_beats_per_bank;
                end else begin
                    if (!decode_is_store_q) begin
                        for (int ch = 0; ch < NUM_CHANNELS; ++ch)
                            load_desc_q[ch] <= decoded_desc[ch];
                    end
                end
            end

            if (state_q == S_BUILD) begin
                for (int ch = 0; ch < NUM_CHANNELS; ++ch)
                    program_desc_q[ch] <= built_desc[ch];
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
                candidate_gen_q[candidate_capture_id]
                    <= ~candidate_gen_q[candidate_capture_id];

                if (candidate_capture_from_pending) begin
                    candidate_owner_q[candidate_capture_id]
                        <= pending_q[candidate_capture_idx];
                    candidate_is_store_q[candidate_capture_id]
                        <= (pending_q[candidate_capture_idx].cmd.instr[3:0]
                            == OP_DMA_ST);
                    candidate_store_new_q[candidate_capture_id]
                        <= (pending_q[candidate_capture_idx].cmd.instr[3:0]
                            == OP_DMA_ST);
                    candidate_store_chunkable_q[candidate_capture_id] <= 1'b0;
                    candidate_store_cursor_q[candidate_capture_id] <= 32'd0;
                    candidate_store_remaining_q[candidate_capture_id] <= 32'd0;
                end else begin
                    candidate_owner_q[candidate_capture_id].cmd <= store_cmd_q;
                    candidate_owner_q[candidate_capture_id].tag <= store_tag_q;
                    candidate_is_store_q[candidate_capture_id] <= 1'b1;
                    candidate_store_new_q[candidate_capture_id] <= 1'b0;
                    candidate_store_chunkable_q[candidate_capture_id]
                        <= store_chunkable_q;
                    candidate_store_cursor_q[candidate_capture_id]
                        <= work_is_store_q
                         ? (store_bank_beat_cursor_q
                          + issued_chunk_beats_per_bank_q)
                         : store_bank_beat_cursor_q;
                    candidate_store_remaining_q[candidate_capture_id]
                        <= work_is_store_q
                         ? (store_remaining_beats_per_bank_q
                          - issued_chunk_beats_per_bank_q)
                         : store_remaining_beats_per_bank_q;
                end
            end

            // Commit a background decode only if its registered provenance
            // still names the live candidate generation.  The decoder result
            // cannot be redirected by completion or a new queue selection.
            if (decode_shadow_result_commit) begin
                shadow_valid_q <= 1'b1;
                shadow_owner_id_q <= decode_candidate_id_q;
                shadow_owner_gen_q <= decode_candidate_gen_q;
                shadow_prepared_q <= 1'b0;
                shadow_chunk_beats_q <= built_chunk_beats_per_bank;
                shadow_prepare_accept_q <= '0;
                candidate_store_chunkable_q[decode_candidate_id_q]
                    <= decode_store_new_q
                     ? decoded_chunkable : decode_store_chunkable_q;
                candidate_store_cursor_q[decode_candidate_id_q]
                    <= decode_store_cursor_q;
                candidate_store_remaining_q[decode_candidate_id_q]
                    <= decode_store_new_q
                     ? decoded_beats_per_bank
                     : decode_store_remaining_q;
                for (int ch = 0; ch < NUM_CHANNELS; ++ch) begin
                    shadow_desc_q[ch] <= decode_is_store_q
                                       ? built_desc[ch] : decoded_desc[ch];
                    shadow_prepare_accept_q[ch]
                        <= decode_is_store_q
                         ? !built_desc[ch].active : !decoded_desc[ch].active;
                    shadow_result_ready_q[ch]
                        <= (decode_is_store_q
                            ? built_desc[ch].active : decoded_desc[ch].active)
                         ? 2'b00 : 2'b11;
                end
            end


            if (shadow_invalidate) begin
                shadow_valid_q <= 1'b0;
                shadow_prepared_q <= 1'b0;
            end

            // Serialize PREPARE transactions globally so prepare_id and all
            // operands stay stable through arbitrary per-channel skew.
            if (!prepare_active_q) begin
                if (shadow_owner_live && !shadow_prepared_q
                 && !decode_shadow_result_commit && !shadow_invalidate) begin
                    prepare_active_q <= 1'b1;
                end
            end else begin
                for (int ch = 0; ch < NUM_CHANNELS; ++ch) begin
                    if (lookahead_prepare_valid_s[ch]
                     && lookahead_prepare_ready_s[ch])
                        shadow_prepare_accept_q[ch] <= 1'b1;
                    if (shadow_desc_q[ch].active
                     && (shadow_prepare_accept_q[ch]
                      || (lookahead_prepare_valid_s[ch]
                       && lookahead_prepare_ready_s[ch])))
                        shadow_result_ready_q[ch]
                            <= shadow_result_ready_q[ch]
                             | lookahead_result_ready_s[ch];
                end
                if (prepare_all_accepted && prepare_all_results_ready) begin
                    shadow_prepared_q <= 1'b1;
                    prepare_active_q <= 1'b0;
                end
            end

            // ACTIVATE/retirement has priority over background PREPARE state.
            // Since capture is allowed only in S_WAIT_DONE, the released ID
            // cannot be reused on this edge.
            if ((state_q == S_PROG) && cfg_all_ready
             && issue_candidate_q) begin
                candidate_valid_q[issue_candidate_id_q] <= 1'b0;
                if (shadow_owner_live
                 && (shadow_owner_id_q == issue_candidate_id_q)) begin
                    shadow_valid_q <= 1'b0;
                    shadow_prepared_q <= 1'b0;
                    prepare_active_q <= 1'b0;
                end
                issue_candidate_q <= 1'b0;
            end

            if (chain_candidate_fire) begin
                candidate_valid_q[chain_candidate_id] <= 1'b0;
                shadow_valid_q <= 1'b0;
                shadow_prepared_q <= 1'b0;
                prepare_active_q <= 1'b0;
            end

            if (completion_event && work_is_store_q) begin
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

            if (logical_complete) begin
                work_data_prefetched_q <= 1'b0;
                work_data_released_q <= 1'b0;
            end

            if ((state_q == S_PROG) && cfg_all_ready) begin
                for (int ch = 0; ch < NUM_CHANNELS; ++ch)
                    active_channel_mask_q[ch] <= program_desc_q[ch].active;
            end else if (completion_event) begin
                active_channel_mask_q <= '0;
            end

            // Same-edge completion/ACTIVATE: old completion and any old-store
            // cursor commit above use the pre-edge context.  The selected
            // controller-owned descriptor then becomes the new foreground
            // command without visiting S_IDLE/S_PROG.
            if (chain_candidate_fire) begin
                work_cmd_q <= candidate_owner_q[chain_candidate_id].cmd;
                work_tag_q <= candidate_owner_q[chain_candidate_id].tag;
                work_is_store_q <= candidate_is_store_q[chain_candidate_id];
                work_store_new_q <=
                    candidate_store_new_q[chain_candidate_id];
                work_data_prefetched_q <= 1'b0;
                work_data_released_q <= 1'b1;
                issued_chunk_beats_per_bank_q <=
                    shadow_chunk_beats_q;
                issue_candidate_q <= 1'b0;
                issue_candidate_id_q <= chain_candidate_id;
                done_sticky_q <= '0;
                for (int ch = 0; ch < NUM_CHANNELS; ++ch)
                    active_channel_mask_q[ch] <= shadow_desc_q[ch].active;

                if (candidate_store_new_q[chain_candidate_id]) begin
                    store_context_valid_q <= 1'b1;
                    store_chunkable_q <=
                        candidate_store_chunkable_q[chain_candidate_id];
                    store_cmd_q <= candidate_owner_q[chain_candidate_id].cmd;
                    store_tag_q <= candidate_owner_q[chain_candidate_id].tag;
                    store_bank_beat_cursor_q <=
                        candidate_store_cursor_q[chain_candidate_id];
                    store_remaining_beats_per_bank_q <=
                        candidate_store_remaining_q[chain_candidate_id];
                end
            end
        end
    end

`ifndef SYNTHESIS
    logic chain_offer_stalled_prev_r;
    logic chain_offer_id_hold_r;
    channel_desc_t chain_offer_desc_hold_r[NUM_CHANNELS];
    logic chain_fire_prev_r;
    logic chain_fire_id_hold_r;
    logic [NUM_CHANNELS-1:0] chain_fire_active_hold_r;
    logic [31:0] chain_fire_chunk_hold_r;
    logic program_fire_prev_r;
    logic [NUM_CHANNELS-1:0] program_fire_active_hold_r;
    logic [31:0] program_fire_chunk_hold_r;
    logic foreground_materialize_prev_r;
    logic [GEMM_DMA_TAG_WIDTH-1:0] foreground_tag_hold_r;
    logic prepared_release_prev_r;
    logic [GEMM_DMA_TAG_WIDTH-1:0] prepared_release_tag_hold_r;
    logic chain_tag_update_prev_r;
    logic [GEMM_DMA_TAG_WIDTH-1:0] chain_tag_hold_r;

    initial begin
        if (`PLATFORM_MEMORY_INTERLEAVE == 0)
            $fatal(1, "%s: interleaved memory is required", INSTANCE_ID);
        if (RAW_BURST_GROUPS == 0)
            $fatal(1, "%s: memory banks must cover all DMA channels",
                   INSTANCE_ID);
    end

    always_ff @(posedge clk) begin
        if (reset) begin
            chain_offer_stalled_prev_r <= 1'b0;
            chain_fire_prev_r <= 1'b0;
            program_fire_prev_r <= 1'b0;
            foreground_materialize_prev_r <= 1'b0;
            prepared_release_prev_r <= 1'b0;
            chain_tag_update_prev_r <= 1'b0;
        end else begin
            if (state_q == S_CAPTURE) begin
                assert ($onehot(foreground_owner_q))
                    else $fatal(1,
                        "%s: foreground capture did not have exactly one owner",
                        INSTANCE_ID);
            end

            if (foreground_materialize_prev_r) begin
                assert (work_tag_q == foreground_tag_hold_r)
                    else $fatal(1,
                        "%s: foreground owner materialized stale tag %0d, expected %0d",
                        INSTANCE_ID, work_tag_q, foreground_tag_hold_r);
            end
            foreground_materialize_prev_r <= (state_q == S_CAPTURE)
                                           && !prepared_release_accept;
            if ((state_q == S_CAPTURE) && !prepared_release_accept)
                foreground_tag_hold_r <= foreground_tag;

            if (prepared_release_prev_r) begin
                assert (work_tag_q == prepared_release_tag_hold_r)
                    else $fatal(1,
                        "%s: prepared release exposed stale tag %0d, expected %0d",
                        INSTANCE_ID, work_tag_q,
                        prepared_release_tag_hold_r);
            end
            prepared_release_prev_r <= prepared_release_accept;
            if (prepared_release_accept)
                prepared_release_tag_hold_r <= gemm_dma_ctrl_if.cmd_tag;

            if (chain_tag_update_prev_r) begin
                assert (work_tag_q == chain_tag_hold_r)
                    else $fatal(1,
                        "%s: chained activation exposed stale tag %0d, expected %0d",
                        INSTANCE_ID, work_tag_q, chain_tag_hold_r);
            end
            chain_tag_update_prev_r <= chain_candidate_fire;
            if (chain_candidate_fire)
                chain_tag_hold_r
                    <= candidate_owner_q[chain_candidate_id].tag;

            if (chain_offer_stalled_prev_r) begin
                assert (chain_candidate_offer
                     && (chain_candidate_id == chain_offer_id_hold_r))
                    else $fatal(1,
                        "%s: chained candidate ownership changed while held",
                        INSTANCE_ID);
                for (int ch = 0; ch < NUM_CHANNELS; ++ch) begin
                    assert (shadow_desc_q[ch] == chain_offer_desc_hold_r[ch])
                        else $fatal(1,
                            "%s: chained channel %0d descriptor changed while held",
                            INSTANCE_ID, ch);
                end
            end
            chain_offer_stalled_prev_r <= chain_candidate_offer
                                       && !chain_candidate_fire;
            if (chain_candidate_offer && !chain_candidate_fire) begin
                chain_offer_id_hold_r <= chain_candidate_id;
                for (int ch = 0; ch < NUM_CHANNELS; ++ch)
                    chain_offer_desc_hold_r[ch] <= shadow_desc_q[ch];
            end

            if (chain_fire_prev_r) begin
                assert ((state_q == S_WAIT_DONE)
                     && (issue_candidate_id_q == chain_fire_id_hold_r))
                    else $fatal(1,
                        "%s: chained command did not directly enter WAIT_DONE",
                        INSTANCE_ID);
                assert ((active_channel_mask_q == chain_fire_active_hold_r)
                     && (issued_chunk_beats_per_bank_q
                         == chain_fire_chunk_hold_r))
                    else $fatal(1,
                        "%s: chained activation lost scalar descriptor metadata",
                        INSTANCE_ID);
            end
            chain_fire_prev_r <= chain_candidate_fire;
            if (chain_candidate_fire) begin
                chain_fire_id_hold_r <= chain_candidate_id;
                for (int ch = 0; ch < NUM_CHANNELS; ++ch)
                    chain_fire_active_hold_r[ch]
                        <= shadow_desc_q[ch].active;
                chain_fire_chunk_hold_r <= shadow_chunk_beats_q;
            end

            if (program_fire_prev_r) begin
                assert ((state_q == S_WAIT_DONE)
                     && (active_channel_mask_q
                         == program_fire_active_hold_r)
                     && (issued_chunk_beats_per_bank_q
                         == program_fire_chunk_hold_r))
                    else $fatal(1,
                        "%s: slow activation lost scalar descriptor metadata",
                        INSTANCE_ID);
            end
            program_fire_prev_r <= (state_q == S_PROG) && cfg_all_ready;
            if ((state_q == S_PROG) && cfg_all_ready) begin
                for (int ch = 0; ch < NUM_CHANNELS; ++ch)
                    program_fire_active_hold_r[ch]
                        <= program_desc_q[ch].active;
                program_fire_chunk_hold_r <=
                    issued_chunk_beats_per_bank_q;
            end
        end
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
            assert (!(foreground_pending_dequeue
                   && background_pending_dequeue))
                else $fatal(1,
                    "%s: foreground/background queue owners collided",
                    INSTANCE_ID);
            if (background_pending_dequeue) begin
                assert (candidate_capture
                     && candidate_capture_from_pending
                     && (candidate_capture_idx == background_pending_idx))
                    else $fatal(1,
                        "%s: background dequeue had no committed candidate owner",
                        INSTANCE_ID);
            end
            if (foreground_pending_dequeue) begin
                assert ((state_q == S_SELECT)
                     && (pending_select_idx == foreground_pending_idx))
                    else $fatal(1,
                        "%s: foreground dequeue escaped selection ownership",
                        INSTANCE_ID);
            end
            assert (pending_capacity_used
                 <= (PENDING_COUNT_W+1)'(PENDING_DEPTH))
                else $fatal(1, "%s: pending/candidate capacity overflow",
                            INSTANCE_ID);
            if (cmd_enqueue)
                assert (pending_capacity_used
                      < (PENDING_COUNT_W+1)'(PENDING_DEPTH))
                    else $fatal(1, "%s: command accepted beyond capacity",
                                INSTANCE_ID);

            if (data_prepare_accept) begin
                assert (gemm_dma_ctrl_if.prepare_cmd.prepare.valid
                     && (gemm_dma_ctrl_if.prepare_cmd.prepare.mode
                         == GEMM_PREPARE_SOURCE_READ)
                     && (gemm_dma_ctrl_if.prepare_cmd.prepare.max_beats != 0))
                    else $fatal(1, "%s: invalid DMA data-prepare metadata",
                                INSTANCE_ID);
                assert ((gemm_dma_ctrl_if.prepare_cmd.instr[3:0]
                         == OP_DMA_LD)
                     && (gemm_dma_ctrl_if.prepare_cmd.rd <= 3))
                    else $fatal(1,
                        "%s: only input/weight/scale/ZP DMA loads may prepare",
                        INSTANCE_ID);
            end

            if (prepared_release_accept) begin
                assert (gemm_dma_ctrl_if.cmd == work_cmd_q)
                    else $fatal(1,
                        "%s: released DMA command does not match prepared owner",
                        INSTANCE_ID);
            end

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

            if (chain_candidate_fire && candidate_capture) begin
                assert (chain_candidate_id != candidate_capture_id)
                    else $fatal(1,
                        "%s: simultaneous chain/capture reused candidate ID %0d",
                        INSTANCE_ID, chain_candidate_id);
            end

            assert (!(decode_valid_q && decode_request))
                else $fatal(1,
                    "%s: decoder input overwrote an unconsumed result",
                    INSTANCE_ID);
            if (decode_valid_q) begin
                assert (decode_is_store_q
                     == (decode_cmd_q.instr[3:0] == OP_DMA_ST))
                    else $fatal(1,
                        "%s: decoder command/store provenance mismatch",
                        INSTANCE_ID);
                for (int ch = 0; ch < NUM_CHANNELS; ++ch) begin
                    assert (is_pow2_u32(
                                decoded_desc[ch].regs[DMA_R_BND0])
                         && (decoded_desc[ch].regs[DMA_R_BND0]
                             == (32'd1 << decoded_bnd0_log2[ch])))
                        else $fatal(1,
                            "%s: channel %0d BND0 lost shift encoding",
                            INSTANCE_ID, ch);
                    assert (is_pow2_u32(
                                decoded_desc[ch].regs[DMA_R_BND2])
                         && (decoded_desc[ch].regs[DMA_R_BND2]
                             == (decoded_desc[ch].burst_mode
                                 ? 32'(NUM_BURST_GROUPS) : 32'd1)))
                        else $fatal(1,
                            "%s: channel %0d BND2 lost shift encoding",
                            INSTANCE_ID, ch);
                end
                if (decode_target_q == DECODE_SHADOW) begin
                    assert (decode_candidate_valid_q
                         && candidate_valid_q[decode_candidate_id_q]
                         && (candidate_gen_q[decode_candidate_id_q]
                             == decode_candidate_gen_q)
                         && (candidate_owner_q[decode_candidate_id_q].cmd
                             == decode_cmd_q)
                         && (candidate_is_store_q[decode_candidate_id_q]
                             == decode_is_store_q)
                         && (candidate_store_new_q[decode_candidate_id_q]
                             == decode_store_new_q)
                         && (candidate_store_chunkable_q[
                                 decode_candidate_id_q]
                             == decode_store_chunkable_q)
                         && (candidate_store_cursor_q[decode_candidate_id_q]
                             == decode_store_cursor_q)
                         && (candidate_store_remaining_q[
                                 decode_candidate_id_q]
                             == decode_store_remaining_q))
                        else $fatal(1,
                            "%s: shadow decoder result lost registered provenance",
                            INSTANCE_ID);
                end else begin
                    assert ((state_q == S_DECODE)
                         && (decode_cmd_q == work_cmd_q)
                         && (decode_is_store_q == work_is_store_q)
                         && (decode_store_new_q == work_store_new_q))
                        else $fatal(1,
                            "%s: program decoder result lost foreground provenance",
                            INSTANCE_ID);
                    if (decode_candidate_valid_q) begin
                        assert (candidate_valid_q[decode_candidate_id_q]
                             && (candidate_gen_q[decode_candidate_id_q]
                                 == decode_candidate_gen_q))
                            else $fatal(1,
                                "%s: program decoder result lost candidate generation",
                                INSTANCE_ID);
                    end
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
                    if (program_desc_q[ch].active)
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

            if (state_q == S_WAIT_DONE) begin
                assert (active_channel_mask_q != '0)
                    else $fatal(1,
                        "%s: WAIT_DONE has no active foreground channels",
                        INSTANCE_ID);
            end

            // Only uniform chunkable stores require a positive scalar
            // per-array progress delta.  A legal nonchunkable descriptor can
            // have channel 0 inactive while another channel performs the
            // transfer, leaving the scalar values at zero.
            if (completion_event && work_is_store_q
             && store_chunkable_q) begin
                assert ((issued_chunk_beats_per_bank_q != 0)
                     && (issued_chunk_beats_per_bank_q
                         <= store_remaining_beats_per_bank_q))
                    else $fatal(1,
                        "%s: store completion has invalid cursor delta",
                        INSTANCE_ID);
                if (!store_chunk_last) begin
                    assert ((store_bank_beat_cursor_q
                             + issued_chunk_beats_per_bank_q)
                            > store_bank_beat_cursor_q)
                        else $fatal(1,
                            "%s: store cursor did not advance monotonically",
                            INSTANCE_ID);
                end
            end


            if (chain_candidate_offer) begin
                assert (done_all_valid
                     && candidate_valid_q[chain_candidate_id]
                     && shadow_owner_live
                     && (shadow_owner_id_q == chain_candidate_id)
                     && shadow_prepared_now)
                    else $fatal(1,
                        "%s: unsafe or unprepared same-edge ACTIVATE",
                        INSTANCE_ID);
                assert (shadow_cfg_all_ready)
                    else $fatal(1,
                        "%s: chained descriptor did not have all-channel ready",
                        INSTANCE_ID);
                if (chain_candidate_id == PREP_FALLBACK_ID)
                    assert (!candidate_valid_q[PREP_HIGH_ID]
                         && !pending_high_found
                         && !accepted_high_now)
                        else $fatal(1,
                            "%s: fallback chained while high load was visible",
                            INSTANCE_ID);
                for (int ch = 0; ch < NUM_CHANNELS; ++ch) begin
                    assert (done_sticky_q[ch] || done_or_inactive[ch])
                        else $fatal(1,
                            "%s: old channel %0d was not done before chaining",
                            INSTANCE_ID, ch);
                    assert (cfg_channel_ready_s[ch]
                         || !shadow_desc_q[ch].active)
                        else $fatal(1,
                            "%s: channel %0d offered without cfg ready",
                            INSTANCE_ID, ch);
                    assert (cfg_valid_s[ch]
                         == shadow_desc_q[ch].active)
                        else $fatal(1,
                            "%s: channel %0d chained cfg active-mask mismatch",
                            INSTANCE_ID, ch);
                    assert (lookahead_activate_s[ch]
                         == shadow_desc_q[ch].active)
                        else $fatal(1,
                            "%s: channel %0d chained ACTIVATE active-mask mismatch",
                            INSTANCE_ID, ch);
                    assert (cfg_fire_s[ch]
                         == shadow_desc_q[ch].active)
                        else $fatal(1,
                            "%s: channel %0d partial chained cfg acceptance",
                            INSTANCE_ID, ch);
                    if (shadow_desc_q[ch].active) begin
                        assert (lookahead_activate_id_s[ch]
                             == chain_candidate_id)
                            else $fatal(1,
                                "%s: channel %0d chained ACTIVATE ID mismatch",
                                INSTANCE_ID, ch);
                    end
                end
                assert (chain_candidate_fire)
                    else $fatal(1,
                        "%s: chained all-ready offer did not fire atomically",
                        INSTANCE_ID);
            end

            if (prepare_active_q) begin
                assert (shadow_owner_live && !shadow_prepared_q)
                    else $fatal(1, "%s: PREPARE lost candidate ownership",
                                INSTANCE_ID);
            end

            if (shadow_valid_q) begin
                assert (shadow_owner_live)
                    else $fatal(1, "%s: shadow lost compact owner generation",
                                INSTANCE_ID);
                if (shadow_owner_id_q == PREP_FALLBACK_ID)
                    assert (!candidate_valid_q[PREP_HIGH_ID]
                         || prepare_active_q
                         || shadow_invalidate
                         || (decode_shadow_result_commit
                          && (decode_candidate_id_q == PREP_HIGH_ID)))
                        else $fatal(1,
                            "%s: prepared fallback shadow survived visible high owner",
                            INSTANCE_ID);
            end

            if (decode_shadow_result_commit && shadow_owner_live
             && (shadow_owner_id_q != decode_candidate_id_q)) begin
                assert (candidate_valid_q[shadow_owner_id_q])
                    else $fatal(1,
                        "%s: shadow replacement retired compact owner",
                        INSTANCE_ID);
                if (decode_candidate_id_q == PREP_HIGH_ID)
                    assert (shadow_owner_id_q == PREP_FALLBACK_ID)
                        else $fatal(1,
                            "%s: high shadow replacement had invalid prior owner",
                            INSTANCE_ID);
            end

            if (decode_valid_q && decode_is_store_q && decoded_chunkable) begin
                logic [31:0] orig_bnd0;
                logic [31:0] orig_bnd2;
                logic [31:0] max_chunk_beats;
                orig_bnd0 = decoded_desc[0].regs[DMA_R_BND0];
                orig_bnd2 = decoded_desc[0].regs[DMA_R_BND2];
                max_chunk_beats = (decode_cmd_q.dma_max_chunk_log2p1 == 0)
                    ? (decoded_beats_per_bank << BURST_GROUP_SHIFT)
                    : (32'd1
                       << (decode_cmd_q.dma_max_chunk_log2p1 - 1'b1));
                assert (is_pow2_u32(orig_bnd0)
                     && (orig_bnd0
                         == (32'd1 << decoded_bnd0_log2[0])))
                    else $fatal(1,
                        "%s: chunkable store BND0 lost shift encoding",
                        INSTANCE_ID);
                assert (is_pow2_u32(orig_bnd2))
                    else $fatal(1, "%s: chunkable store BND2 is not power-of-two",
                                INSTANCE_ID);
                assert (orig_bnd2 == 32'(NUM_BURST_GROUPS))
                    else $fatal(1,
                        "%s: chunkable store BND2 lost static shift encoding",
                        INSTANCE_ID);
                assert (max_chunk_beats >= orig_bnd2)
                    else $fatal(1, "%s: store chunk limit is smaller than BND2",
                                INSTANCE_ID);
                for (int ch = 0; ch < NUM_CHANNELS; ++ch) begin
                    assert ((decoded_desc[ch].regs[DMA_R_SRC_ST0]
                             == 32'(BEAT_STRIDE_TMEM_B))
                         && (decoded_desc[ch].regs[DMA_R_DST_ST0]
                             == 32'(BEAT_STRIDE_HBM_B))
                         && (decoded_desc[ch].regs[DMA_R_SEG_SIZE]
                             == 32'(`MEM_BLOCK_SIZE)))
                        else $fatal(1,
                            "%s: chunkable store stride/segment is not shift encodable on channel %0d",
                            INSTANCE_ID, ch);
                end
            end

            if (decode_valid_q) begin
                for (int ch = 0; ch < NUM_CHANNELS; ++ch) begin
                    if (decoded_desc[ch].active) begin
                        assert (!decoded_bound_overflow[ch]
                             && ((decoded_desc[ch].regs[DMA_R_BND0]
                                  >> `DMA_BOUND_WIDTH) == 0)
                             && ((decoded_desc[ch].regs[DMA_R_BND1]
                                  >> `DMA_BOUND_WIDTH) == 0)
                             && ((decoded_desc[ch].regs[DMA_R_BND2]
                                  >> `DMA_BOUND_WIDTH) == 0))
                            else $fatal(1,
                                "%s: decoded channel %0d bound exceeds %0d bits",
                                INSTANCE_ID, ch, `DMA_BOUND_WIDTH);
                    end
                end
            end

            if ((state_q == S_PROG) && cfg_all_ready) begin
                assert (!built_bound_overflow)
                    else $fatal(1, "%s: store chunk bound exceeds %0d bits",
                                INSTANCE_ID, `DMA_BOUND_WIDTH);
                for (int ch = 0; ch < NUM_CHANNELS; ++ch) begin
                    if (program_desc_q[ch].active) begin
                        assert (((program_desc_q[ch].regs[DMA_R_BND0]
                                  >> `DMA_BOUND_WIDTH) == 0)
                             && ((program_desc_q[ch].regs[DMA_R_BND1]
                                  >> `DMA_BOUND_WIDTH) == 0)
                             && ((program_desc_q[ch].regs[DMA_R_BND2]
                                  >> `DMA_BOUND_WIDTH) == 0))
                            else $fatal(1,
                                "%s: programmed channel %0d bound exceeds %0d bits",
                                INSTANCE_ID, ch, `DMA_BOUND_WIDTH);
                    end
                end
            end

            if ((state_q == S_PROG) && work_is_store_q
             && !store_chunkable_q) begin
                for (int ch = 0; ch < NUM_CHANNELS; ++ch) begin
                    assert (program_desc_q[ch] == decoded_desc[ch])
                        else $fatal(1,
                            "%s: non-chunkable store descriptor changed on channel %0d",
                            INSTANCE_ID, ch);
                end
            end

            if ((state_q == S_PROG) && work_is_store_q
             && store_chunkable_q) begin
                assert (program_desc_q[0].regs[DMA_R_BND0]
                     <= decoded_desc[0].regs[DMA_R_BND0])
                    else $fatal(1, "%s: chunk increased original BND0",
                                INSTANCE_ID);
            end

            if (gemm_dma_ctrl_if.done) begin
                assert (done_all_valid)
                    else $fatal(1, "%s: logical done preceded channel drain",
                                INSTANCE_ID);
                assert (!work_data_prefetched_q || work_data_released_q)
                    else $fatal(1,
                        "%s: prepared DMA completed before architectural release",
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
        unique case ({cmd_enqueue, dbg_capacity_release})
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

            if (data_prepare_accept) begin
                dbg_activity_seen_q <= 1'b1;
                `TRACE(2, ("%m : [%0t] | TMEM_DMA_DATA_PREPARE | {inst=%s, op=0x%0h, rd=%0d, max_beats=%0d}\n",
                          $time, INSTANCE_ID,
                          gemm_dma_ctrl_if.prepare_cmd.instr[3:0],
                          gemm_dma_ctrl_if.prepare_cmd.rd,
                          gemm_dma_ctrl_if.prepare_cmd.prepare.max_beats))
            end

            if (prepared_release_accept) begin
                `TRACE(2, ("%m : [%0t] | TMEM_DMA_DATA_RELEASE | {inst=%s, tag=%0d, op=0x%0h, rd=%0d}\n",
                          $time, INSTANCE_ID, gemm_dma_ctrl_if.cmd_tag,
                          gemm_dma_ctrl_if.cmd.instr[3:0],
                          gemm_dma_ctrl_if.cmd.rd))
            end

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

            if (decode_valid_q && (decode_target_q == DECODE_PROGRAM)
             && decode_is_store_q && decode_store_new_q) begin
                `TRACE(2, ("%m : [%0t] | TMEM_DMA_STORE_CAPTURE | {inst=%s, tag=%0d, chunkable=%0d, bypass=%0d, cursor=0, remaining=%0d, orig_bnd0=%0d, orig_bnd1=%0d, orig_bnd2=%0d, max_chunk_log2p1=%0d}\n",
                          $time, INSTANCE_ID, work_tag_q,
                          decoded_chunkable, !decoded_chunkable,
                          decoded_beats_per_bank,
                          decoded_desc[0].regs[DMA_R_BND0],
                          decoded_desc[0].regs[DMA_R_BND1],
                          decoded_desc[0].regs[DMA_R_BND2],
                          decode_cmd_q.dma_max_chunk_log2p1))
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
                          chain_candidate_fire
                            ? shadow_desc_q[0].regs[DMA_R_BND0]
                            : program_desc_q[0].regs[DMA_R_BND0],
                          chain_candidate_fire
                            ? shadow_desc_q[0].regs[DMA_R_BND1]
                            : program_desc_q[0].regs[DMA_R_BND1],
                          chain_candidate_fire
                            ? shadow_desc_q[0].regs[DMA_R_BND2]
                            : program_desc_q[0].regs[DMA_R_BND2],
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

        if (decode_valid_q && (decode_target_q == DECODE_PROGRAM)
         && decode_is_store_q && decode_store_new_q)
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

    `VX_STATIC_ASSERT((NUM_CHANNELS > 0)
                   && ((NUM_CHANNELS & (NUM_CHANNELS - 1)) == 0),
      ("NUM_CHANNELS must be a positive power of two"));
    `VX_STATIC_ASSERT((`PLATFORM_MEMORY_NUM_BANKS % NUM_CHANNELS) == 0,
      ("physical memory banks must be divisible by NUM_CHANNELS"));
    `VX_STATIC_ASSERT((NUM_BURST_GROUPS > 0)
                   && ((NUM_BURST_GROUPS & (NUM_BURST_GROUPS - 1)) == 0),
      ("NUM_BURST_GROUPS must be a positive power of two"));
    `VX_STATIC_ASSERT((`MEM_BLOCK_SIZE > 0)
                   && ((`MEM_BLOCK_SIZE & (`MEM_BLOCK_SIZE - 1)) == 0),
      ("MEM_BLOCK_SIZE must be a positive power of two"));
    `VX_STATIC_ASSERT((BEAT_STRIDE_HBM_B > 0)
                   && ((BEAT_STRIDE_HBM_B & (BEAT_STRIDE_HBM_B - 1)) == 0),
      ("HBM beat stride must be a positive power of two"));
    `VX_STATIC_ASSERT((BEAT_STRIDE_TMEM_B > 0)
                   && ((BEAT_STRIDE_TMEM_B & (BEAT_STRIDE_TMEM_B - 1)) == 0),
      ("TMEM beat stride must be a positive power of two"));
    `VX_STATIC_ASSERT(PENDING_DEPTH > 0,
      ("DMA pending depth must be positive"));

    `UNUSED_PARAM (ENTRYID_W)

endmodule
