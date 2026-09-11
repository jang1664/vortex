`include "VX_define.vh"

`ifdef GEMM_NAIVE
// Staged metadata controller. Uses improve's command-stage / child-queue /
// owned-notification architecture, with five real LMEM children and no TMEM
// scheduler. The naive node routes real child commands through this controller.
module VX_gemm_ctrl_naive_meta import VX_gpu_pkg::*; #(
    parameter `STRING INSTANCE_ID = ""
) (
    input wire clk,
    input wire reset,
    input wire invocation_valid_i,
    output wire invocation_ready_o,
    input wire [`JOB_MMIO_ENTRYID_W-1:0] invocation_entry_id_i,
    input wire cmd_valid_i,
    output wire cmd_ready_o,
    input gemm_unified_cmd_t cmd_i,
    input wire producer_done_i,
    // Includes real transport, conversion and bank-commit work, even after an
    // ordinary Input's ingress notification has retired.
    input wire executor_quiescent_i,
    output wire quiescent_o,
    output wire done_valid_o,
    input wire done_ready_i,
    output wire [`JOB_MMIO_ENTRYID_W-1:0] done_entry_id_o,
    // One actual consume event per W0/W1/SC0/SC1/ZP0/ZP1 resource per edge.
    input wire [5:0] consume_valid_i,
    // The node joins all four source engines, closed generation and owned
    // responses before asserting this generation-qualified release.
    input wire [1:0] source_free_valid_i,
    input wire [31:0] source_free_generation_i [2],
    VX_gemm_ctrl_naive_meta_if.controller child_if
);
    localparam int CHILDREN = GEMM_NAIVE_NUM_CHILDREN;
    localparam int DMA = GEMM_NAIVE_DMA_CHILD;
    localparam int CMDW = $bits(gemm_unified_cmd_t);
    localparam logic [3:0] OP_LOAD = 4'd1;
    localparam logic [3:0] OP_STORE = 4'd2;
    localparam logic [3:0] OP_WEIGHT = 4'd5;
    localparam logic [3:0] OP_SCALE = 4'd6;
    localparam logic [3:0] OP_INPUT = 4'd7;
    localparam logic [3:0] OP_ZERO = 4'd10;

    typedef struct packed {
        gemm_notify_meta_t notify;
        logic [31:0] work_seq;
    } inflight_t;
    typedef struct packed {
        logic valid;
        logic buffer_id;
        logic [31:0] generation;
        logic [1:0] member;
    } load_receipt_t;
    typedef struct packed {
        logic [31:0] generation;
        logic [3:0] completed;
        logic published;
    } tile_join_t;

    logic invocation_active_q;
    logic [`JOB_MMIO_ENTRYID_W-1:0] invocation_entry_q;
    logic done_valid_q;
    logic [`JOB_MMIO_ENTRYID_W-1:0] done_entry_q;
    logic stage_valid_q;
    gemm_unified_cmd_t stage_cmd_q;
    logic [2:0] stage_child_q;
    gemm_unified_cmd_t queue_cmd [CHILDREN];
    wire [CHILDREN-1:0] queue_empty, queue_full;
    wire [CHILDREN-1:0] issue_fire, completion_fire;
    wire [CHILDREN-1:0] inflight_empty, inflight_full;
    inflight_t inflight_head [CHILDREN];
    logic [CHILDREN-1:0] prepare_offered_q, prepare_sent_q;
    wire [CHILDREN-1:0] prepare_eligible, prepare_fire;
    logic [31:0] sync_q [GEMM_NUM_SYNC_REGS];
    logic [31:0] sync_next [GEMM_NUM_SYNC_REGS];
    load_receipt_t load_receipt_q;
    tile_join_t tile_join_q [2];
    tile_join_t tile_join_next [2];

    function automatic logic [2:0] command_child(input gemm_unified_cmd_t cmd);
        unique case (cmd.instr[3:0])
            OP_INPUT: return 3'(GEMM_NAIVE_INPUT_CHILD);
            OP_WEIGHT: return 3'(GEMM_NAIVE_WEIGHT_CHILD);
            OP_SCALE: return 3'(GEMM_NAIVE_SCALE_CHILD);
            OP_ZERO: return 3'(GEMM_NAIVE_ZERO_CHILD);
            OP_LOAD, OP_STORE: return 3'(DMA);
            default: return 3'd7;
        endcase
    endfunction

    function automatic int consume_rid(input int resource);
        unique case (resource)
            0: return GEMM_RID_W_CONSUME0;
            1: return GEMM_RID_W_CONSUME1;
            2: return GEMM_RID_SC_CONSUME0;
            3: return GEMM_RID_SC_CONSUME1;
            4: return GEMM_RID_ZP_CONSUME0;
            5: return GEMM_RID_ZP_CONSUME1;
            default: return GEMM_RID_W_CONSUME0;
        endcase
    endfunction

    function automatic logic notification_legal(
        input int child, input gemm_notify_meta_t meta);
        if (!meta.valid)
            return 1'b1;
        unique case (child)
            GEMM_NAIVE_INPUT_CHILD:
                return !meta.set_mode && (meta.value == 32'd1)
                    && ((meta.reg_id == GEMM_RID_G0)
                     || (meta.reg_id == GEMM_RID_G1));
            GEMM_NAIVE_WEIGHT_CHILD:
                return meta.set_mode && (meta.value != 0)
                    && ((meta.reg_id == GEMM_RID_W0)
                     || (meta.reg_id == GEMM_RID_W1));
            GEMM_NAIVE_SCALE_CHILD:
                return meta.set_mode && (meta.value != 0)
                    && ((meta.reg_id == GEMM_RID_SC0)
                     || (meta.reg_id == GEMM_RID_SC1));
            GEMM_NAIVE_ZERO_CHILD:
                return meta.set_mode && (meta.value != 0)
                    && ((meta.reg_id == GEMM_RID_ZP0)
                     || (meta.reg_id == GEMM_RID_ZP1));
            DMA:
                return !meta.set_mode && (meta.value == 32'd1)
                    && (meta.reg_id == GEMM_RID_O);
            default: return 1'b0;
        endcase
    endfunction

    wire command_supported = command_child(cmd_i) < CHILDREN;
    wire stage_drain = stage_valid_q && !queue_full[stage_child_q];
    wire invocation_fire = invocation_valid_i && invocation_ready_o;
    wire command_fire = cmd_valid_i && cmd_ready_o;
    wire done_fire = done_valid_q && done_ready_i;
    wire joins_quiescent = ((tile_join_q[0].completed == 0)
                          || tile_join_q[0].published)
                        && ((tile_join_q[1].completed == 0)
                          || tile_join_q[1].published);
    assign quiescent_o = !stage_valid_q && (&queue_empty)
                     && (&inflight_empty) && !(|prepare_offered_q)
                     && !load_receipt_q.valid && joins_quiescent
                     && executor_quiescent_i;
    assign invocation_ready_o = !reset && !invocation_active_q && quiescent_o
                              && (!done_valid_q || done_ready_i);
    assign cmd_ready_o = !reset && invocation_active_q && !producer_done_i
                       && command_supported && (!stage_valid_q || stage_drain);
    wire invocation_complete = invocation_active_q && producer_done_i
                              && !cmd_valid_i && quiescent_o;
    assign done_valid_o = done_valid_q;
    assign done_entry_id_o = done_entry_q;

    always_ff @(posedge clk) begin
        if (reset) begin
            invocation_active_q <= 1'b0;
            invocation_entry_q <= '0;
            done_valid_q <= 1'b0;
            done_entry_q <= '0;
            stage_valid_q <= 1'b0;
            stage_child_q <= '0;
        end else begin
            if (done_fire)
                done_valid_q <= 1'b0;
            if (invocation_complete) begin
                invocation_active_q <= 1'b0;
                done_valid_q <= 1'b1;
                done_entry_q <= invocation_entry_q;
            end
            if (invocation_fire) begin
                invocation_active_q <= 1'b1;
                invocation_entry_q <= invocation_entry_id_i;
            end
            if (stage_drain)
                stage_valid_q <= 1'b0;
            if (command_fire) begin
                stage_valid_q <= 1'b1;
                stage_cmd_q <= cmd_i;
                stage_child_q <= command_child(cmd_i);
            end
        end
    end

    for (genvar child = 0; child < CHILDREN; ++child) begin : g_child
        localparam int DEPTH = (child == DMA) ? 8 : 4;
        wire [CMDW-1:0] queue_bits;
        logic deps_ready, prepare_deps_ready;
        assign queue_cmd[child] = queue_bits;
        VX_fifo_queue #(.DATAW(CMDW), .DEPTH(DEPTH)) cmd_queue (
            .clk(clk), .reset(reset),
            .push(stage_drain && (stage_child_q == child)),
            .pop(issue_fire[child]), .data_in(stage_cmd_q),
            .data_out(queue_bits), .empty(queue_empty[child]),
            .full(queue_full[child]), .alm_empty(), .alm_full(), .size()
        );

        // All slots, all 23 valid RIDs, for external DMA as well as operands.
        // Unsupported RIDs fail closed; never index outside the counter array.
        always_comb begin
            deps_ready = 1'b1;
            for (int dep = 0; dep < GEMM_MAX_WAIT_DEPS; ++dep) begin
                if (queue_cmd[child].waits[dep].valid) begin
                    if (queue_cmd[child].waits[dep].reg_id < GEMM_NUM_SYNC_REGS)
                        deps_ready &= sync_q[queue_cmd[child].waits[dep].reg_id]
                                   >= queue_cmd[child].waits[dep].target;
                    else
                        deps_ready = 1'b0;
                end
            end
            prepare_deps_ready = 1'b1;
            for (int dep = 0; dep < GEMM_MAX_PREPARE_WAIT_DEPS; ++dep) begin
                if (queue_cmd[child].prepare.waits[dep].valid) begin
                    if (queue_cmd[child].prepare.waits[dep].reg_id < GEMM_NUM_SYNC_REGS)
                        prepare_deps_ready &= sync_q[queue_cmd[child].prepare.waits[dep].reg_id]
                                           >= queue_cmd[child].prepare.waits[dep].target;
                    else
                        prepare_deps_ready = 1'b0;
                end
            end
        end
        assign child_if.cmd[child] = queue_cmd[child];
        assign child_if.cmd_valid[child] = !reset && !queue_empty[child]
                  && deps_ready && !inflight_full[child]
                  && !prepare_offered_q[child];
        assign issue_fire[child] = child_if.cmd_valid[child]
                                && child_if.cmd_ready[child];
        assign prepare_eligible[child] = !queue_empty[child]
                  && !inflight_full[child] && !deps_ready
                  && queue_cmd[child].prepare.valid
                  && (queue_cmd[child].prepare.mode == GEMM_PREPARE_SOURCE_READ)
                  && prepare_deps_ready && !prepare_sent_q[child]
                  && !prepare_offered_q[child];
        assign child_if.prepare_valid[child] = !reset && prepare_offered_q[child];
        assign prepare_fire[child] = child_if.prepare_valid[child]
                                  && child_if.prepare_ready[child];
        always_ff @(posedge clk) begin
            if (reset || invocation_fire) begin
                prepare_offered_q[child] <= 1'b0;
                prepare_sent_q[child] <= 1'b0;
            end else begin
                if (prepare_eligible[child])
                    prepare_offered_q[child] <= 1'b1;
                if (prepare_fire[child]) begin
                    prepare_offered_q[child] <= 1'b0;
                    prepare_sent_q[child] <= 1'b1;
                end
                if (issue_fire[child])
                    prepare_sent_q[child] <= 1'b0;
            end
        end

        if (child == DMA) begin : g_single_dma
            inflight_t record_q;
            logic valid_q;
            assign inflight_head[child] = record_q;
            assign inflight_empty[child] = !valid_q;
            assign inflight_full[child] = valid_q;
            always_ff @(posedge clk) begin
                if (reset)
                    valid_q <= 1'b0;
                else begin
                    if (completion_fire[child])
                        valid_q <= 1'b0;
                    if (issue_fire[child]) begin
                        valid_q <= 1'b1;
                        record_q <= {queue_cmd[child].notify, queue_cmd[child].work_seq};
                    end
                end
            end
        end else begin : g_ordered_local
            wire [$bits(inflight_t)-1:0] record_bits;
            assign inflight_head[child] = record_bits;
            VX_fifo_queue #(.DATAW($bits(inflight_t)), .DEPTH(4)) inflight_queue (
                .clk(clk), .reset(reset), .push(issue_fire[child]),
                .pop(completion_fire[child]),
                .data_in({queue_cmd[child].notify, queue_cmd[child].work_seq}),
                .data_out(record_bits), .empty(inflight_empty[child]),
                .full(inflight_full[child]), .alm_empty(), .alm_full(), .size()
            );
        end
        assign child_if.done_ready[child] = !reset && !inflight_empty[child]
                   && (child_if.done_work_seq[child] == inflight_head[child].work_seq);
        assign completion_fire[child] = child_if.done_valid[child]
                                     && child_if.done_ready[child];
    end

    // One physical external descriptor is active. LOAD readiness joins four
    // distinct *fenced* DMA completions; a changed token alone is not a receipt.
    always_ff @(posedge clk) begin
        if (reset || invocation_fire)
            load_receipt_q <= '0;
        else begin
            if (completion_fire[DMA])
                load_receipt_q.valid <= 1'b0;
            if (issue_fire[DMA]) begin
                load_receipt_q.valid <= queue_cmd[DMA].instr[3:0] == OP_LOAD;
                load_receipt_q.buffer_id <= queue_cmd[DMA].naive_source_buffer;
                load_receipt_q.generation <= queue_cmd[DMA].naive_source_generation;
                load_receipt_q.member <= queue_cmd[DMA].rd[1:0];
            end
        end
    end

    always_comb begin
        for (int bank = 0; bank < 2; ++bank) begin
            tile_join_next[bank] = tile_join_q[bank];
            if (issue_fire[DMA] && (queue_cmd[DMA].instr[3:0] == OP_LOAD)
             && (queue_cmd[DMA].naive_source_buffer == bank)
             && (queue_cmd[DMA].naive_source_generation != tile_join_q[bank].generation)) begin
                tile_join_next[bank].generation = queue_cmd[DMA].naive_source_generation;
                tile_join_next[bank].completed = '0;
                tile_join_next[bank].published = 1'b0;
            end
            if (completion_fire[DMA] && load_receipt_q.valid
             && (load_receipt_q.buffer_id == bank)) begin
                tile_join_next[bank].completed[load_receipt_q.member] = 1'b1;
                if (&tile_join_next[bank].completed)
                    tile_join_next[bank].published = 1'b1;
            end
        end
    end

    // Fixed producer ownership makes updates to different RIDs independent.
    // Architectural levels are registered, preserving the ingress-completion
    // timing cut and preventing compute -> completion -> admission loops.
    always_comb begin
        for (int rid = 0; rid < GEMM_NUM_SYNC_REGS; ++rid)
            sync_next[rid] = sync_q[rid];
        for (int child = 0; child < CHILDREN; ++child) begin
            if (completion_fire[child] && inflight_head[child].notify.valid
             && notification_legal(child, inflight_head[child].notify)) begin
                if (inflight_head[child].notify.set_mode) begin
                    if (inflight_head[child].notify.value > sync_q[inflight_head[child].notify.reg_id])
                        sync_next[inflight_head[child].notify.reg_id] = inflight_head[child].notify.value;
                end else begin
                    sync_next[inflight_head[child].notify.reg_id]
                        = sync_q[inflight_head[child].notify.reg_id] + 32'd1;
                end
            end
        end
        for (int resource = 0; resource < 6; ++resource) begin
            if (consume_valid_i[resource])
                sync_next[consume_rid(resource)] = sync_q[consume_rid(resource)] + 32'd1;
        end
        for (int bank = 0; bank < 2; ++bank) begin
            if (source_free_valid_i[bank])
                sync_next[bank ? GEMM_RID_SRC_FREE1 : GEMM_RID_SRC_FREE0]
                    = source_free_generation_i[bank];
            if (tile_join_next[bank].published && !tile_join_q[bank].published)
                sync_next[bank ? GEMM_RID_T1 : GEMM_RID_T0] = tile_join_next[bank].generation;
        end
        sync_next[GEMM_RID_SZ0] = (sync_next[GEMM_RID_SC0] < sync_next[GEMM_RID_ZP0])
                              ? sync_next[GEMM_RID_SC0] : sync_next[GEMM_RID_ZP0];
        sync_next[GEMM_RID_SZ1] = (sync_next[GEMM_RID_SC1] < sync_next[GEMM_RID_ZP1])
                              ? sync_next[GEMM_RID_SC1] : sync_next[GEMM_RID_ZP1];
    end
    for (genvar rid = 0; rid < GEMM_NUM_SYNC_REGS; ++rid) begin : g_sync
        assign child_if.sync_value[rid] = sync_q[rid];
        always_ff @(posedge clk) begin
            if (reset || invocation_fire)
                sync_q[rid] <= '0;
            else
                sync_q[rid] <= sync_next[rid];
        end
    end
    for (genvar bank = 0; bank < 2; ++bank) begin : g_tile_join
        always_ff @(posedge clk) begin
            if (reset || invocation_fire)
                tile_join_q[bank] <= '0;
            else
                tile_join_q[bank] <= tile_join_next[bank];
        end
    end

`ifndef SYNTHESIS
    initial begin
        assert ($bits(inflight_t) == 71 && $bits(load_receipt_t) == 36
             && $bits(tile_join_t) == 37 && GEMM_NUM_SYNC_REGS == 23)
            else $fatal(1, "%s: metadata allocation changed", INSTANCE_ID);
    end
    always_ff @(posedge clk) begin
        if (!reset) begin
            if (cmd_valid_i && invocation_active_q)
                assert (command_supported)
                    else $fatal(1, "%s: non-real command opcode", INSTANCE_ID);
            assert (!(invocation_complete && done_valid_q && !done_fire))
                else $fatal(1, "%s: pending invocation completion overwritten", INSTANCE_ID);
            for (int child = 0; child < CHILDREN; ++child) begin
                if (child_if.done_valid[child])
                    assert (!inflight_empty[child]
                         && child_if.done_work_seq[child] == inflight_head[child].work_seq)
                        else $fatal(1, "%s: unowned/out-of-order child completion child=%0d", INSTANCE_ID, child);
                if (issue_fire[child]) begin
                    assert (notification_legal(child, queue_cmd[child].notify))
                        else $fatal(1, "%s: illegal notification owner child=%0d", INSTANCE_ID, child);
                    if (child == GEMM_NAIVE_INPUT_CHILD && queue_cmd[child].notify.valid)
                        assert (queue_cmd[child].naive_terminal
                             == (queue_cmd[child].notify.reg_id == GEMM_RID_G1))
                            else $fatal(1, "%s: Input terminal/notification mismatch", INSTANCE_ID);
                end
            end
            for (int bank = 0; bank < 2; ++bank) begin
                if (source_free_valid_i[bank])
                    assert (source_free_generation_i[bank]
                              == sync_q[bank ? GEMM_RID_SRC_FREE1 : GEMM_RID_SRC_FREE0] + 32'd1
                         && source_free_generation_i[bank]
                              <= sync_q[bank ? GEMM_RID_T1 : GEMM_RID_T0])
                        else $fatal(1, "%s: stale/unready source release bank=%0d", INSTANCE_ID, bank);
            end
            if (issue_fire[DMA] && (queue_cmd[DMA].instr[3:0] == OP_LOAD)) begin
                assert (queue_cmd[DMA].rd < 4 && !queue_cmd[DMA].notify.valid
                     && queue_cmd[DMA].naive_source_generation != 0)
                    else $fatal(1, "%s: invalid LOAD receipt metadata", INSTANCE_ID);
                if (queue_cmd[DMA].naive_source_generation
                 != tile_join_q[queue_cmd[DMA].naive_source_buffer].generation)
                    assert ((queue_cmd[DMA].naive_source_generation
                              == tile_join_q[queue_cmd[DMA].naive_source_buffer].generation + 32'd1)
                         && ((tile_join_q[queue_cmd[DMA].naive_source_buffer].generation == 0)
                          || (tile_join_q[queue_cmd[DMA].naive_source_buffer].published
                           && sync_q[queue_cmd[DMA].naive_source_buffer ? GEMM_RID_SRC_FREE1 : GEMM_RID_SRC_FREE0]
                             >= tile_join_q[queue_cmd[DMA].naive_source_buffer].generation)))
                        else $fatal(1, "%s: LOAD reused unreleased/stale source generation", INSTANCE_ID);
            end
            if (completion_fire[DMA] && load_receipt_q.valid)
                assert (load_receipt_q.generation == tile_join_q[load_receipt_q.buffer_id].generation
                     && !tile_join_q[load_receipt_q.buffer_id].completed[load_receipt_q.member]
                     && !tile_join_q[load_receipt_q.buffer_id].published)
                    else $fatal(1, "%s: duplicate/stale fenced LOAD receipt", INSTANCE_ID);
`ifdef DBG_TRACE_GEMM
            for (int child = 0; child < CHILDREN; ++child) begin
                if (issue_fire[child])
                    $display("%s: META_ISSUE child=%0d work=%0d", INSTANCE_ID, child, queue_cmd[child].work_seq);
                if (completion_fire[child])
                    $display("%s: META_DONE child=%0d work=%0d", INSTANCE_ID, child, inflight_head[child].work_seq);
            end
`endif
        end
    end
`endif
endmodule
`endif
