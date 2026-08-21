`include "VX_define.vh"

// Four-entry, work-sequence ordered readiness scoreboard.  This block is a
// performance policy only: no output is used to decide GEMM architectural
// ready.  All state-changing inputs are registered events.
module VX_microtile_readiness_scheduler import VX_gpu_pkg::*; #(
    parameter `STRING INSTANCE_ID = "",
    parameter int DEPTH = 4,
    parameter int INPUT_SLOTS = 8,
    parameter int INPUT_MIN_READY = 1,
    parameter int WEIGHT_NEAR_WINDOW = 2,
    parameter int TMEM_ARB_MAX_CONSECUTIVE_URGENT =
        `TMEM_ARB_MAX_CONSECUTIVE_URGENT
) (
    input wire clk,
    input wire reset,

    input wire probe_valid_i,
    input wire [31:0] probe_work_seq_i,
    output logic probe_ready_o,

    input wire cmd_fire_i,
    input wire [1:0] cmd_resource_i,
    input wire [31:0] cmd_work_seq_i,
    input wire cmd_bank_i,
    input wire [31:0] cmd_target_i,
    input gemm_wait_meta_t cmd_writer_wait_i,
    input gemm_wait_meta_t input_waits_i [4],

    input wire retire_valid_i,
    input wire [31:0] retire_work_seq_i,

    input wire [3:0] fetch_complete_valid_i,
    input wire [31:0] fetch_complete_work_seq_i [4],

    input wire block_valid_i,
    input wire [1:0] block_resource_i,
    input wire [31:0] block_work_seq_i,
    input wire block_bank_i,
    input wire [31:0] block_target_i,

    input wire [3:0] source_valid_i,
    input wire [31:0] source_work_seq_i [4],
    input wire [31:0] source_total_beats_i [4],
    input wire [31:0] source_request_beats_i [4],
    input wire [31:0] source_response_beats_i [4],
    input wire [31:0] source_writer_beats_i [4],
    input wire [3:0] input_slot_occupancy_i,
    input wire input_ahead_credit_i,
    input wire input_admit_valid_i,
    input wire [31:0] input_admit_work_seq_i,

    input wire [31:0] w_load_value_i [2],
    input wire [31:0] s_load_value_i [2],
    input wire [31:0] z_load_value_i [2],
    input wire [31:0] acc_free_value_i [2],

    output logic [GEMM_SCHED_PRIORITY_WIDTH-1:0] source_priority_o [4],
    output logic input_source_enable_o,
    output logic [$clog2(DEPTH+1)-1:0] entry_count_o
);
    localparam int PTRW = $clog2(DEPTH);
    localparam int COUNTW = $clog2(DEPTH + 1);
    localparam int INPUT_SMALL_BUDGET = (INPUT_SLOTS > 1)
        ? (INPUT_SLOTS / 2) : INPUT_SLOTS;
    localparam int INPUT_MEDIUM_BUDGET = (INPUT_SLOTS > 3)
        ? ((INPUT_SLOTS * 3) / 4) : INPUT_SLOTS;
    // Fixed production pipeline contract measured from the authoritative
    // logical Weight response through registered generation visibility.
    localparam int WEIGHT_RSP_TO_WRITE_LATENCY = 2;
    localparam int WEIGHT_WRITE_TO_VISIBLE_LATENCY = 1;
    localparam int WEIGHT_INSTALL_VISIBLE_LATENCY
        = WEIGHT_RSP_TO_WRITE_LATENCY + WEIGHT_WRITE_TO_VISIBLE_LATENCY;
    // The physical TMEM bank has six fixed requesters: general DMA, Input,
    // Weight, Scale, Zero-point, and Output.  The bank's fair-RR escape can
    // visit a particular requester after at most one escape per requester,
    // with each escape separated by MAX_CONSECUTIVE_URGENT priority grants.
    // Express the issue horizon in that same accepted-grant contract.
    localparam int TMEM_ARB_NUM_REQUESTERS = 6;
    localparam int BANK_WAIT_BOUND = TMEM_ARB_NUM_REQUESTERS
                                   * (TMEM_ARB_MAX_CONSECUTIVE_URGENT + 1);

    typedef enum logic [1:0] {
        WEIGHT_DEADLINE_SAFE,
        WEIGHT_DEADLINE_NEAR,
        WEIGHT_DEADLINE_CRITICAL
    } weight_deadline_class_t;

    typedef enum logic [1:0] {
        INPUT_SERVICE_STARVATION,
        INPUT_SERVICE_MINIMUM,
        INPUT_SERVICE_AHEAD,
        INPUT_SERVICE_AHEAD_THROTTLED
    } input_service_class_t;

    typedef struct packed {
        logic valid;
        logic [31:0] work_seq;
        logic [3:0] seen;
        logic [3:0] buffered;
        logic [3:0][31:0] total_beats;
        logic [3:0][31:0] request_beats;
        logic [3:0][31:0] response_beats;
        logic [3:0][31:0] writer_beats;
        logic input_admitted;
        logic w_bank;
        logic s_bank;
        logic z_bank;
        logic [31:0] w_target;
        logic [31:0] s_target;
        logic [31:0] z_target;
        gemm_wait_meta_t w_writer_wait;
        gemm_wait_meta_t s_writer_wait;
        gemm_wait_meta_t z_writer_wait;
        gemm_wait_meta_t acc_wait;
    } entry_t;

    entry_t entries_r[DEPTH];
    logic [PTRW-1:0] head_r, tail_r;
    logic [COUNTW-1:0] count_r;
    logic probe_match;
    logic [PTRW-1:0] probe_idx;
    weight_deadline_class_t weight_deadline_class;
    input_service_class_t input_service_class;
    logic critical_weight_fetch_pending;
    logic weight_issue_deadline_guard;
    logic precritical_weight_fetch_pending;
    logic [33:0] weight_unrequested_beats;
    logic [33:0] weight_outstanding_beats;
    logic [33:0] weight_ready_eta;
    logic [33:0] weight_issue_ready_eta;

    function automatic logic wait_released(
        input gemm_wait_meta_t wait_meta,
        input logic [31:0] value0,
        input logic [31:0] value1,
        input logic [GEMM_SYNC_REG_ID_WIDTH-1:0] rid0,
        input logic [GEMM_SYNC_REG_ID_WIDTH-1:0] rid1
    );
        logic is0, is1;
        begin
            is0 = wait_meta.reg_id == GEMM_SYNC_REG_ID_WIDTH'(rid0);
            is1 = wait_meta.reg_id == GEMM_SYNC_REG_ID_WIDTH'(rid1);
            wait_released = !wait_meta.valid
                         || (is0 && (value0 >= wait_meta.target))
                         || (is1 && (value1 >= wait_meta.target));
        end
    endfunction

    always_comb begin
        probe_match = 1'b0;
        probe_idx = tail_r;
        for (int offset = 0; offset < DEPTH; ++offset) begin
            logic [PTRW-1:0] idx;
            idx = head_r + PTRW'(offset);
            if (!probe_match && entries_r[idx].valid
             && (entries_r[idx].work_seq == probe_work_seq_i)) begin
                probe_match = 1'b1;
                probe_idx = idx;
            end
        end
        // Ordered retirement may recycle the head on the same edge.  A new
        // work is accepted only on the exact enqueue handshake.
        probe_ready_o = !probe_valid_i || probe_match
                     || (count_r < COUNTW'(DEPTH))
                     || (retire_valid_i && entries_r[head_r].valid
                      && (entries_r[head_r].work_seq == retire_work_seq_i));
        entry_count_o = count_r;
    end

    always_comb begin
        logic earliest_w_ready, earliest_s_ready, earliest_z_ready;
        logic earliest_acc_ready;
        logic earliest_all_operands;
        logic earliest_all_buffered;
        logic [3:0] input_budget;
        logic weight_found;
        logic [PTRW-1:0] weight_idx;
        logic [COUNTW-1:0] weight_distance;
        logic weight_fetch_pending;
        logic weight_input_admitted;
        logic [33:0] weight_consumer_slack;
        logic weight_critical_now;

        earliest_w_ready = entries_r[head_r].valid
            && entries_r[head_r].seen[GEMM_SCHED_RESOURCE_WEIGHT]
            && (w_load_value_i[entries_r[head_r].w_bank]
             == entries_r[head_r].w_target);
        earliest_s_ready = entries_r[head_r].valid
            && entries_r[head_r].seen[GEMM_SCHED_RESOURCE_SCALE]
            && (s_load_value_i[entries_r[head_r].s_bank]
             == entries_r[head_r].s_target);
        earliest_z_ready = entries_r[head_r].valid
            && entries_r[head_r].seen[GEMM_SCHED_RESOURCE_ZP]
            && (z_load_value_i[entries_r[head_r].z_bank]
             == entries_r[head_r].z_target);
        earliest_acc_ready = entries_r[head_r].valid
            && wait_released(entries_r[head_r].acc_wait,
                             acc_free_value_i[0], acc_free_value_i[1],
                             GEMM_SYNC_REG_ID_WIDTH'(GEMM_RID_ACC_FREE0),
                             GEMM_SYNC_REG_ID_WIDTH'(GEMM_RID_ACC_FREE1));
        earliest_all_operands = earliest_w_ready
                             && earliest_s_ready
                             && earliest_z_ready
                             && earliest_acc_ready;
        earliest_all_buffered = entries_r[head_r].valid
            && (&entries_r[head_r].buffered[3:1]);

        // The operand-state bucket bounds data held in the eight response
        // slots.  Registered capacity beyond the DMA may extend that bucket
        // below, while actual admission remains governed by local GEMM ready.
        input_budget = earliest_all_operands ? 4'(INPUT_SLOTS)
                     : earliest_all_buffered ? 4'(INPUT_MEDIUM_BUDGET)
                     : 4'(INPUT_SMALL_BUDGET);
        // The response-slot occupancy alone misses capacity that is
        // available beyond the DMA.  Consume at most one registered credit
        // from the GEMM elastic/tree boundary, while retaining the operand
        // state bucket and the physical response-slot bound.
        if (input_ahead_credit_i && (input_budget < 4'(INPUT_SLOTS)))
            input_budget = input_budget + 4'd1;
        input_source_enable_o = !source_valid_i[GEMM_SCHED_RESOURCE_INPUT]
                             || (input_slot_occupancy_i < input_budget);

        // Predecode the currently requestable Weight from registered
        // scoreboard, descriptor-progress, occupancy, and admission state.
        // A wide logical response remains outstanding until every required
        // lane completes, so request-response includes an incomplete oldest
        // lane without adding a tile- or WLOAD-specific lane count here.
        weight_found = 1'b0;
        weight_idx = head_r;
        weight_distance = '0;
        for (int offset = 0; offset < DEPTH; ++offset) begin
            logic [PTRW-1:0] scan_idx;
            scan_idx = head_r + PTRW'(offset);
            if (!weight_found && entries_r[scan_idx].valid
             && source_valid_i[GEMM_SCHED_RESOURCE_WEIGHT]
             && (entries_r[scan_idx].work_seq
              == source_work_seq_i[GEMM_SCHED_RESOURCE_WEIGHT])) begin
                weight_found = 1'b1;
                weight_idx = scan_idx;
                weight_distance = COUNTW'(offset);
            end
        end

        weight_fetch_pending = weight_found
            && (source_total_beats_i[GEMM_SCHED_RESOURCE_WEIGHT] != 0)
            && (source_request_beats_i[GEMM_SCHED_RESOURCE_WEIGHT]
                < source_total_beats_i[GEMM_SCHED_RESOURCE_WEIGHT])
            && (source_response_beats_i[GEMM_SCHED_RESOURCE_WEIGHT]
                < source_total_beats_i[GEMM_SCHED_RESOURCE_WEIGHT]);
        weight_input_admitted = weight_found
            && (entries_r[weight_idx].input_admitted
             || (input_admit_valid_i
              && (input_admit_work_seq_i == entries_r[weight_idx].work_seq)));
        weight_unrequested_beats = '0;
        weight_outstanding_beats = '0;
        if (weight_fetch_pending) begin
            weight_unrequested_beats
                = {2'b0, source_total_beats_i[GEMM_SCHED_RESOURCE_WEIGHT]}
                - {2'b0, source_request_beats_i[GEMM_SCHED_RESOURCE_WEIGHT]};
            weight_outstanding_beats
                = {2'b0, source_request_beats_i[GEMM_SCHED_RESOURCE_WEIGHT]}
                - {2'b0, source_response_beats_i[GEMM_SCHED_RESOURCE_WEIGHT]};
        end
        weight_ready_eta = weight_unrequested_beats
                         + weight_outstanding_beats
                         + 34'(WEIGHT_INSTALL_VISIBLE_LATENCY);
        weight_issue_ready_eta = weight_ready_eta + 34'(BANK_WAIT_BOUND);
        weight_consumer_slack = 34'(input_slot_occupancy_i);

        weight_deadline_class = WEIGHT_DEADLINE_SAFE;
        weight_critical_now = 1'b0;
        if (weight_fetch_pending
         && (weight_distance <= COUNTW'(WEIGHT_NEAR_WINDOW))) begin
            weight_deadline_class = WEIGHT_DEADLINE_NEAR;
            if ((weight_distance == 0)
             || weight_input_admitted
             || ((input_slot_occupancy_i >= 4'(INPUT_MIN_READY))
              && (weight_ready_eta >= weight_consumer_slack))) begin
                weight_deadline_class = WEIGHT_DEADLINE_CRITICAL;
                weight_critical_now = 1'b1;
            end
        end
        critical_weight_fetch_pending = weight_fetch_pending
            && (weight_deadline_class == WEIGHT_DEADLINE_CRITICAL);
        // All terms feeding this guard are registered scheduler/descriptor
        // state.  The bank-wait horizon makes a near Weight request P2 before
        // its valid/priority can be sampled and held by the LDMA request path;
        // no already-presented request is live-reprioritized.
        weight_issue_deadline_guard = weight_fetch_pending
            && (weight_distance <= COUNTW'(WEIGHT_NEAR_WINDOW))
            && (weight_critical_now
             || (weight_issue_ready_eta >= weight_consumer_slack));
        precritical_weight_fetch_pending = weight_issue_deadline_guard
            && !critical_weight_fetch_pending;

        if (input_slot_occupancy_i == 0)
            input_service_class = INPUT_SERVICE_STARVATION;
        else if (input_slot_occupancy_i < 4'(INPUT_MIN_READY))
            input_service_class = INPUT_SERVICE_MINIMUM;
        else if (weight_issue_deadline_guard)
            input_service_class = INPUT_SERVICE_AHEAD_THROTTLED;
        else
            input_service_class = INPUT_SERVICE_AHEAD;

        for (int resource = 0; resource < 4; ++resource) begin
            logic found;
            logic [PTRW-1:0] idx;
            logic [COUNTW-1:0] distance;
            logic block_match;
            logic fetch_pending;
            logic final_request;
            logic resource_bank;
            logic [31:0] resource_target;

            found = 1'b0;
            idx = head_r;
            distance = '0;
            for (int offset = 0; offset < DEPTH; ++offset) begin
                logic [PTRW-1:0] scan_idx;
                scan_idx = head_r + PTRW'(offset);
                if (!found && entries_r[scan_idx].valid
                 && source_valid_i[resource]
                 && (entries_r[scan_idx].work_seq
                  == source_work_seq_i[resource])) begin
                    found = 1'b1;
                    idx = scan_idx;
                    distance = COUNTW'(offset);
                end
            end

            resource_bank = 1'b0;
            resource_target = '0;
            if (found) begin
                unique case (2'(resource))
                    GEMM_SCHED_RESOURCE_INPUT:;
                    GEMM_SCHED_RESOURCE_WEIGHT: begin
                        resource_bank = entries_r[idx].w_bank;
                        resource_target = entries_r[idx].w_target;
                    end
                    GEMM_SCHED_RESOURCE_SCALE: begin
                        resource_bank = entries_r[idx].s_bank;
                        resource_target = entries_r[idx].s_target;
                    end
                    default: begin
                        resource_bank = entries_r[idx].z_bank;
                        resource_target = entries_r[idx].z_target;
                    end
                endcase
            end

            block_match = block_valid_i && found
                       && (block_resource_i == 2'(resource))
                       && (block_work_seq_i == entries_r[idx].work_seq)
                       && (block_bank_i == resource_bank)
                       && (block_target_i == resource_target);

            // The LDMA descriptor is the only authority for command length
            // and progress.  In particular, register installation state does
            // not keep a source request elevated after all responses arrived.
            fetch_pending = found
                         && (source_total_beats_i[resource] != 0)
                         && (source_request_beats_i[resource]
                             < source_total_beats_i[resource])
                         && (source_response_beats_i[resource]
                             < source_total_beats_i[resource]);
            final_request = fetch_pending
                         && ((source_request_beats_i[resource] + 32'd1)
                             == source_total_beats_i[resource]);
            source_priority_o[resource] = GEMM_SCHED_PRIORITY_BACKGROUND;
            if (fetch_pending) begin
                if (2'(resource) == GEMM_SCHED_RESOURCE_WEIGHT) begin
                    if (weight_issue_deadline_guard)
                        source_priority_o[resource]
                            = GEMM_SCHED_PRIORITY_EARLIEST;
                    else if (weight_deadline_class == WEIGHT_DEADLINE_NEAR)
                        source_priority_o[resource]
                            = GEMM_SCHED_PRIORITY_NEAR;
                    // The final logical request, including all of its wide
                    // lanes, receives at most the CRITICAL P2 tier.
                    if (final_request
                     && weight_issue_deadline_guard)
                        source_priority_o[resource]
                            = GEMM_SCHED_PRIORITY_EARLIEST;
                end else begin
                    source_priority_o[resource]
                        = (distance == 0) ? GEMM_SCHED_PRIORITY_EARLIEST
                        : (distance == 1) ? GEMM_SCHED_PRIORITY_NEAR
                                          : GEMM_SCHED_PRIORITY_BACKGROUND;
                    if (final_request && (distance <= COUNTW'(1)))
                        source_priority_o[resource]
                            = GEMM_SCHED_PRIORITY_EARLIEST;
                end
                if (block_match)
                    source_priority_o[resource]
                        = GEMM_SCHED_PRIORITY_BLOCKED;
            end
            if ((2'(resource) == GEMM_SCHED_RESOURCE_INPUT) && fetch_pending
             && (distance <= COUNTW'(1))) begin
                unique case (input_service_class)
                    INPUT_SERVICE_STARVATION:
                        source_priority_o[resource]
                            = GEMM_SCHED_PRIORITY_BLOCKED;
                    INPUT_SERVICE_AHEAD_THROTTLED:
                        source_priority_o[resource]
                            = GEMM_SCHED_PRIORITY_NEAR;
                    default:
                        source_priority_o[resource]
                            = GEMM_SCHED_PRIORITY_EARLIEST;
                endcase
            end
        end
    end

    always_ff @(posedge clk) begin
        if (reset) begin
            head_r <= '0;
            tail_r <= '0;
            count_r <= '0;
            for (int entry = 0; entry < DEPTH; ++entry)
                entries_r[entry] <= '0;
        end else begin
            logic allocate;
            logic retire;
            logic [PTRW-1:0] update_idx;
            allocate = cmd_fire_i && !probe_match;
            retire = retire_valid_i;
            update_idx = probe_match ? probe_idx : tail_r;

            unique case ({allocate, retire})
                2'b10: count_r <= count_r + COUNTW'(1);
                2'b01: count_r <= count_r - COUNTW'(1);
                default:;
            endcase

            if (retire) begin
                entries_r[head_r] <= '0;
                head_r <= head_r + PTRW'(1);
            end

            for (int resource = 0; resource < 4; ++resource) begin
                if (source_valid_i[resource]) begin
                    for (int entry = 0; entry < DEPTH; ++entry) begin
                        if (entries_r[entry].valid
                         && (entries_r[entry].work_seq
                          == source_work_seq_i[resource])) begin
                            entries_r[entry].total_beats[resource]
                                <= source_total_beats_i[resource];
                            entries_r[entry].request_beats[resource]
                                <= source_request_beats_i[resource];
                            entries_r[entry].response_beats[resource]
                                <= source_response_beats_i[resource];
                            entries_r[entry].writer_beats[resource]
                                <= source_writer_beats_i[resource];
                        end
                    end
                end
                if (fetch_complete_valid_i[resource]) begin
                    for (int entry = 0; entry < DEPTH; ++entry) begin
                        if (entries_r[entry].valid
                         && (entries_r[entry].work_seq
                          == fetch_complete_work_seq_i[resource])) begin
                            entries_r[entry].buffered[resource] <= 1'b1;
                            entries_r[entry].response_beats[resource]
                                <= entries_r[entry].total_beats[resource];
                        end
                    end
                end
            end

            if (input_admit_valid_i) begin
                for (int entry = 0; entry < DEPTH; ++entry) begin
                    if (entries_r[entry].valid
                     && (entries_r[entry].work_seq
                      == input_admit_work_seq_i))
                        entries_r[entry].input_admitted <= 1'b1;
                end
            end

            // Enqueue/update last so a same-cycle ordered retirement can
            // recycle the head storage without erasing the new descriptor.
            if (cmd_fire_i) begin
                if (allocate) begin
                    entries_r[tail_r] <= '0;
                    entries_r[tail_r].valid <= 1'b1;
                    entries_r[tail_r].work_seq <= cmd_work_seq_i;
                    tail_r <= tail_r + PTRW'(1);
                end
                entries_r[update_idx].seen[cmd_resource_i] <= 1'b1;
                unique case (cmd_resource_i)
                    GEMM_SCHED_RESOURCE_INPUT: begin
                        entries_r[update_idx].w_bank
                            <= input_waits_i[0].reg_id
                            == GEMM_SYNC_REG_ID_WIDTH'(GEMM_RID_W1);
                        entries_r[update_idx].s_bank
                            <= input_waits_i[1].reg_id
                            == GEMM_SYNC_REG_ID_WIDTH'(GEMM_RID_SC1);
                        entries_r[update_idx].z_bank
                            <= input_waits_i[2].reg_id
                            == GEMM_SYNC_REG_ID_WIDTH'(GEMM_RID_ZP1);
                        entries_r[update_idx].w_target <= input_waits_i[0].target;
                        entries_r[update_idx].s_target <= input_waits_i[1].target;
                        entries_r[update_idx].z_target <= input_waits_i[2].target;
                        entries_r[update_idx].acc_wait <= input_waits_i[3];
                    end
                    GEMM_SCHED_RESOURCE_WEIGHT: begin
                        entries_r[update_idx].w_bank <= cmd_bank_i;
                        entries_r[update_idx].w_target <= cmd_target_i;
                        entries_r[update_idx].w_writer_wait <= cmd_writer_wait_i;
                    end
                    GEMM_SCHED_RESOURCE_SCALE: begin
                        entries_r[update_idx].s_bank <= cmd_bank_i;
                        entries_r[update_idx].s_target <= cmd_target_i;
                        entries_r[update_idx].s_writer_wait <= cmd_writer_wait_i;
                    end
                    default: begin
                        entries_r[update_idx].z_bank <= cmd_bank_i;
                        entries_r[update_idx].z_target <= cmd_target_i;
                        entries_r[update_idx].z_writer_wait <= cmd_writer_wait_i;
                    end
                endcase
            end
        end
    end

`ifndef SYNTHESIS
    logic [31:0] dbg_fetch_missing_block_count_r;
    logic [31:0] dbg_fetched_not_installed_block_count_r;

    always_ff @(posedge clk) begin
        if (reset) begin
            dbg_fetch_missing_block_count_r <= '0;
            dbg_fetched_not_installed_block_count_r <= '0;
        end else begin
            assert (count_r <= COUNTW'(DEPTH))
                else $fatal(1, "%s: readiness scoreboard overflow", INSTANCE_ID);
            assert ((INPUT_MIN_READY > 0)
                 && (INPUT_MIN_READY <= INPUT_SLOTS))
                else $fatal(1, "%s: invalid Input minimum-service threshold", INSTANCE_ID);
            assert ((WEIGHT_NEAR_WINDOW >= 0)
                 && (WEIGHT_NEAR_WINDOW < DEPTH))
                else $fatal(1, "%s: invalid Weight deadline window", INSTANCE_ID);
            assert ((TMEM_ARB_MAX_CONSECUTIVE_URGENT > 0)
                 && (BANK_WAIT_BOUND > TMEM_ARB_MAX_CONSECUTIVE_URGENT)
                 && (BANK_WAIT_BOUND >= INPUT_SLOTS))
                else $fatal(1,
                    "%s: invalid TMEM bank-wait contract requesters=%0d max_urgent=%0d bound=%0d input_slots=%0d",
                    INSTANCE_ID, TMEM_ARB_NUM_REQUESTERS,
                    TMEM_ARB_MAX_CONSECUTIVE_URGENT, BANK_WAIT_BOUND,
                    INPUT_SLOTS);
            if (cmd_fire_i) begin
                assert (probe_valid_i && (probe_work_seq_i == cmd_work_seq_i)
                     && probe_ready_o)
                    else $fatal(1, "%s: untracked/duplicate command enqueue", INSTANCE_ID);
            end
            if (retire_valid_i) begin
                assert ((count_r != 0) && entries_r[head_r].valid
                     && (entries_r[head_r].work_seq == retire_work_seq_i))
                    else $fatal(1, "%s: non-head or mismatched work retirement", INSTANCE_ID);
            end
            if (probe_valid_i && !probe_match && (count_r == COUNTW'(DEPTH))
             && !retire_valid_i)
                assert (!probe_ready_o)
                    else $fatal(1, "%s: fifth work bypassed full scoreboard", INSTANCE_ID);

            for (int resource = 0; resource < 4; ++resource) begin
                if (source_valid_i[resource]) begin
                    assert ((source_total_beats_i[resource] != 0)
                         && (source_request_beats_i[resource]
                             < source_total_beats_i[resource])
                         && (source_response_beats_i[resource]
                             <= source_request_beats_i[resource])
                         && (source_writer_beats_i[resource]
                             <= source_total_beats_i[resource]))
                        else $fatal(1,
                            "%s: invalid descriptor fetch progress resource=%0d total=%0d req=%0d rsp=%0d writer=%0d",
                            INSTANCE_ID, resource,
                            source_total_beats_i[resource],
                            source_request_beats_i[resource],
                            source_response_beats_i[resource],
                            source_writer_beats_i[resource]);
                end
                if (source_priority_o[resource]
                    == GEMM_SCHED_PRIORITY_BLOCKED) begin
                    assert ((source_total_beats_i[resource] != 0)
                         && (source_request_beats_i[resource]
                             < source_total_beats_i[resource])
                         && (source_response_beats_i[resource]
                             < source_total_beats_i[resource]))
                        else $fatal(1,
                            "%s: P3 selected without descriptor fetch work resource=%0d",
                            INSTANCE_ID, resource);
                end
                if ((2'(resource) == GEMM_SCHED_RESOURCE_WEIGHT)
                 && source_valid_i[resource]
                 && (source_response_beats_i[resource]
                     == source_total_beats_i[resource])) begin
                    assert (source_priority_o[resource]
                         == GEMM_SCHED_PRIORITY_BACKGROUND)
                        else $fatal(1,
                            "%s: fetch-complete Weight retained elevated priority",
                            INSTANCE_ID);
                end
            end

            if (weight_issue_deadline_guard
             && (input_slot_occupancy_i >= 4'(INPUT_MIN_READY))
             && source_valid_i[GEMM_SCHED_RESOURCE_INPUT]) begin
                assert (source_priority_o[GEMM_SCHED_RESOURCE_INPUT]
                     <= GEMM_SCHED_PRIORITY_NEAR)
                    else $fatal(1,
                        "%s: Input ahead exceeded P1 over precritical/critical Weight",
                        INSTANCE_ID);
            end

            if (precritical_weight_fetch_pending
             && source_valid_i[GEMM_SCHED_RESOURCE_WEIGHT]) begin
                assert (source_priority_o[GEMM_SCHED_RESOURCE_WEIGHT]
                     >= GEMM_SCHED_PRIORITY_EARLIEST)
                    else $fatal(1,
                        "%s: precritical Weight request sampled below P2",
                        INSTANCE_ID);
            end

            if (block_valid_i) begin
                logic accounted;
                accounted = 1'b0;
                for (int entry = 0; entry < DEPTH; ++entry) begin
                    if (!accounted && entries_r[entry].valid
                     && (entries_r[entry].work_seq == block_work_seq_i)) begin
                        if (entries_r[entry].buffered[block_resource_i])
                            dbg_fetched_not_installed_block_count_r
                                <= dbg_fetched_not_installed_block_count_r + 32'd1;
                        else
                            dbg_fetch_missing_block_count_r
                                <= dbg_fetch_missing_block_count_r + 32'd1;
                        accounted = 1'b1;
                    end
                end
            end
        end
    end
`endif
endmodule
