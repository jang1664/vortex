`include "VX_define.vh"
module tb_controller;
    import VX_gpu_pkg::*;
    logic clk = 0;
    always #5 clk = !clk;
    logic reset = 1;
    logic invocation_valid = 0;
    wire invocation_ready;
    logic [`JOB_MMIO_ENTRYID_W-1:0] entry_id = 0;
    logic cmd_valid = 0;
    wire cmd_ready;
    gemm_unified_cmd_t cmd;
    logic producer_done = 0;
    logic executor_quiescent = 1;
    wire quiescent, done_valid;
    logic done_ready = 0;
    wire [`JOB_MMIO_ENTRYID_W-1:0] done_entry;
    logic [5:0] consume = 0;
    logic [1:0] source_free = 0;
    logic [31:0] source_generation [2];
    VX_gemm_ctrl_naive_meta_if child ();
    VX_gemm_ctrl_naive_meta #(.INSTANCE_ID("tb_meta")) dut (
        .clk(clk), .reset(reset), .invocation_valid_i(invocation_valid),
        .invocation_ready_o(invocation_ready), .invocation_entry_id_i(entry_id),
        .cmd_valid_i(cmd_valid), .cmd_ready_o(cmd_ready), .cmd_i(cmd),
        .producer_done_i(producer_done), .executor_quiescent_i(executor_quiescent),
        .quiescent_o(quiescent), .done_valid_o(done_valid), .done_ready_i(done_ready),
        .done_entry_id_o(done_entry), .consume_valid_i(consume),
        .source_free_valid_i(source_free), .source_free_generation_i(source_generation),
        .child_if(child)
    );
    // These queues are an independent, simulation-only command/ownership
    // scoreboard. Executor completion timing is controlled explicitly below.
    gemm_unified_cmd_t expected [5][$];
    logic [31:0] active [5][$];
    gemm_unified_cmd_t last_issue [5];
    int issued [5], retired [5], prepared [5];
    logic [4:0] auto_complete = '1;
    int cycle = 0;
    int next_work = 1;
    int last_multi_completion = -1;
    string test_case = "positive";

    function automatic int route(input gemm_unified_cmd_t item);
        case (item.instr[3:0])
            7: return 0;
            5: return 1;
            6: return 2;
            10: return 3;
            1,2: return 4;
            default: return -1;
        endcase
    endfunction
    function automatic gemm_unified_cmd_t work(input int op);
        gemm_unified_cmd_t item;
        item = '0;
        item.instr = (32'd32 << 4) | op;
        item.work_seq = next_work++;
        item.rs1_data = 64'h1_ffc1d000;
        item.rs2_data = 64'h1_ffc15000;
        item.stride = 32'd64;
        item.naive_final_base = 64'h1_ffc15000;
        item.naive_final_stride = 32'd256;
        item.eff_mt = 21'd4;
        return item;
    endfunction
    function automatic gemm_notify_meta_t note(input int rid, input int value, input bit set_mode);
        gemm_notify_meta_t result;
        result = '0;
        result.valid = 1;
        result.reg_id = GEMM_SYNC_REG_ID_WIDTH'(rid);
        result.value = value;
        result.set_mode = set_mode;
        return result;
    endfunction
    function automatic gemm_wait_meta_t fence(input int rid, input int target);
        gemm_wait_meta_t result;
        result.valid = 1;
        result.reg_id = GEMM_SYNC_REG_ID_WIDTH'(rid);
        result.target = target;
        return result;
    endfunction
    always @(posedge clk) begin : scoreboard
        gemm_unified_cmd_t item;
        logic [31:0] sequence_id;
        int completions;
        cycle = cycle + 1;
        completions = 0;
        if (!reset) begin
            if (cmd_valid && cmd_ready)
                expected[route(cmd)].push_back(cmd);
            for (int c = 0; c < 5; ++c) begin
                if (child.prepare_valid[c] && child.prepare_ready[c]) begin
                    assert (expected[c].size() != 0 && child.cmd[c] === expected[c][0])
                        else $fatal(1, "prepare lost descriptor identity child=%0d", c);
                    prepared[c]++;
                end
                if (child.done_valid[c] && child.done_ready[c]) begin
                    assert (active[c].size() != 0)
                        else $fatal(1, "unowned test completion");
                    sequence_id = active[c].pop_front();
                    assert (child.done_work_seq[c] == sequence_id)
                        else $fatal(1, "completion crossed owners");
                    retired[c]++;
                    completions++;
                end
                if (child.cmd_valid[c] && child.cmd_ready[c]) begin
                    assert (expected[c].size() != 0)
                        else $fatal(1, "unexpected executor command");
                    item = expected[c].pop_front();
                    assert (child.cmd[c] === item)
                        else $fatal(1, "descriptor changed child=%0d work=%0d", c, item.work_seq);
                    assert (child.cmd[c].naive_final_base == 64'h1_ffc15000)
                        else $fatal(1, "full-width final address lost");
                    active[c].push_back(item.work_seq);
                    last_issue[c] = item;
                    issued[c]++;
                end
            end
            if (completions >= 4)
                last_multi_completion = cycle;
        end
    end
    always @(negedge clk) begin
        for (int c = 0; c < 5; ++c) begin
            child.done_valid[c] = !reset && auto_complete[c] && (active[c].size() != 0);
            child.done_work_seq[c] = active[c].size() ? active[c][0] : '0;
        end
    end
    task automatic ticks(input int count);
        repeat (count) begin @(posedge clk); #1; end
    endtask
    task automatic start_job(input int id);
        @(negedge clk);
        producer_done = 0;
        entry_id = `JOB_MMIO_ENTRYID_W'(id);
        invocation_valid = 1;
        do begin @(posedge clk); end while (!invocation_ready);
        @(negedge clk);
        invocation_valid = 0;
    endtask
    task automatic send(input gemm_unified_cmd_t item);
        @(negedge clk);
        cmd = item;
        cmd_valid = 1;
        do begin @(posedge clk); end while (!cmd_ready);
        @(negedge clk);
        cmd_valid = 0;
    endtask
    task automatic drain;
        int timeout;
        timeout = 0;
        while (!quiescent) begin
            ticks(1);
            if (++timeout > 4000)
                $fatal(1, "controller failed to drain");
        end
    endtask
    task automatic wait_retired(input int c, input int count);
        int timeout;
        timeout = 0;
        while (retired[c] < count) begin
            ticks(1);
            if (++timeout > 1000)
                $fatal(1, "retirement timeout child=%0d", c);
        end
    endtask
    task automatic load_tile(input bit bank, input int generation);
        gemm_unified_cmd_t item;
        int before_count;
        for (int member = 0; member < 4; ++member) begin
            before_count = retired[4];
            item = work(1);
            item.rd = NUM_REGS_BITS'(member);
            item.naive_source_buffer = bank;
            item.naive_source_generation = generation;
            send(item);
            wait_retired(4, before_count+1);
            if (member != 3)
                assert (child.sync_value[bank ? GEMM_RID_T1 : GEMM_RID_T0] == generation-1)
                    else $fatal(1, "T published before four fenced receipts");
        end
        assert (child.sync_value[bank ? GEMM_RID_T1 : GEMM_RID_T0] == generation)
            else $fatal(1, "complete LOAD join not published");
    endtask
    task automatic release_source(input bit bank, input int generation);
        @(negedge clk);
        source_generation[bank] = generation;
        source_free[bank] = 1;
        @(negedge clk);
        source_free[bank] = 0;
    endtask
    task automatic consume_weight;
        @(negedge clk); consume[0] = 1;
        @(negedge clk); consume[0] = 0;
    endtask
    task automatic finish_job(input int delay_cycles);
        int timeout;
        int valid_cycle;
        @(negedge clk); producer_done = 1;
        timeout = 0;
        while (!done_valid) begin
            ticks(1);
            if (++timeout > 4000) $fatal(1, "invocation done timeout");
        end
        // done_valid was produced after the preceding edge; observers
        // sample its first visible value at the next rising edge.
        valid_cycle = cycle + 1;
        repeat (delay_cycles) begin
            ticks(1);
            assert (done_valid && done_entry == entry_id && !invocation_ready)
                else $fatal(1, "pending completion unstable");
        end
        @(negedge clk); done_ready = 1;
        @(posedge clk);
        assert (done_valid && done_entry == entry_id)
            else $fatal(1, "done handshake owner lost");
        // Sample after the scoreboard advances its edge counter.
        #1;
        assert (cycle - valid_cycle == delay_cycles)
            else $fatal(1, "delivery delay differs from requested cycles");
        $display("DONE_BACKPRESSURE requested=%0d first_valid=%0d handshake=%0d", delay_cycles, valid_cycle, cycle);
        @(negedge clk); done_ready = 0;
    endtask

    initial begin : stimulus
        gemm_unified_cmd_t item;
        int old_issued, old_retired, old_prepared;
        int previous_w, previous_s, previous_z;
        cmd = '0;
        child.cmd_ready = '1;
        child.prepare_ready = '1;
        child.done_valid = '0;
        for (int c = 0; c < 5; ++c) begin
            child.done_work_seq[c] = '0;
            issued[c] = 0; retired[c] = 0; prepared[c] = 0;
        end
        source_generation[0] = 0; source_generation[1] = 0;
        if ($value$plusargs("CASE=%s", test_case)) begin end
        ticks(3);
        @(negedge clk); reset = 0;
        start_job(11);

        if (test_case == "bad_opcode") begin
            item = work(3); send(item);
            $fatal(1, "bad opcode was accepted");
        end
        if (test_case == "bad_source") begin
            release_source(0, 1); ticks(5);
            $fatal(1, "premature source release escaped");
        end
        if (test_case == "bad_owner") begin
            auto_complete[0] = 0;
            item = work(7); send(item);
            ticks(8);
            // Override at a non-driver edge; the next posedge must reject it.
            @(negedge clk); #1; child.done_work_seq[0] = item.work_seq + 1;
            child.done_valid[0] = 1;
            @(posedge clk); #1;
            $fatal(1, "wrong owner escaped");
        end

        load_tile(0, 1);
        if (test_case == "duplicate_load") begin
            item = work(1); item.rd = 0;
            item.naive_source_generation = 1;
            send(item); ticks(20);
            $fatal(1, "duplicate LOAD escaped");
        end
        if (test_case == "unreleased_load") begin
            item = work(1); item.rd = 0;
            item.naive_source_generation = 2;
            send(item); ticks(20);
            $fatal(1, "unreleased generation escaped");
        end
        // A queued refill is a real LOAD, but slot4 SRC_FREE blocks it even
        // after T-ready. Independent local work still makes progress.
        old_issued = issued[4];
        old_retired = retired[4];
        item = work(1); item.rd = 0;
        item.naive_source_generation = 2;
        item.waits[4] = fence(GEMM_RID_SRC_FREE0, 1);
        send(item); ticks(8);
        assert (issued[4] == old_issued) else $fatal(1, "DMA ignored SRC_FREE slot4");
        item = work(10); send(item); ticks(8);
        assert (issued[4] == old_issued && retired[3] != 0)
            else $fatal(1, "blocked DMA stopped independent local work");
        release_source(0, 1);
        wait_retired(4, old_retired+1);
        for (int member = 1; member < 4; ++member) begin
            old_retired = retired[4];
            item = work(1); item.rd = NUM_REGS_BITS'(member);
            item.naive_source_generation = 2;
            send(item); wait_retired(4, old_retired+1);
            assert (child.sync_value[GEMM_RID_T0] == ((member == 3) ? 2 : 1))
                else $fatal(1, "refill T join published wrong generation");
        end
        release_source(0, 2);
        load_tile(1, 1);
        release_source(1, 1);

        // Exhaust every architectural RID in every wait slot. IDs 9/10 stay
        // zero in naive; accepting their target0 checks does not invent an
        // ACC_FREE producer. Nonzero blocked checks follow independently.
        for (int rid = 0; rid < GEMM_NUM_SYNC_REGS; ++rid) begin
            for (int slot = 0; slot < GEMM_MAX_WAIT_DEPS; ++slot) begin
                item = work(7);
                item.waits[slot] = fence(rid, 0);
                item.notify = note(GEMM_RID_G0, 1, 0);
                send(item);
            end
        end
        drain();
        assert (child.sync_value[GEMM_RID_G0] == GEMM_NUM_SYNC_REGS*GEMM_MAX_WAIT_DEPS)
            else $fatal(1, "wait/RID census lost commands");

        // Every slot independently blocks; a different eligible child runs.
        for (int slot = 0; slot < GEMM_MAX_WAIT_DEPS; ++slot) begin
            old_issued = issued[1];
            item = work(5);
            item.waits[slot] = fence(GEMM_RID_W_CONSUME0, slot+1);
            item.notify = note(GEMM_RID_W0, slot+1, 1);
            send(item);
            item = work(10); item.notify = note(GEMM_RID_ZP0, slot+1, 1);
            old_retired = retired[3]; send(item);
            wait_retired(3, old_retired+1);
            assert (issued[1] == old_issued)
                else $fatal(1, "ignored wait slot=%0d", slot);
            consume_weight();
            wait_retired(1, old_issued+1);
        end

        // Prepare waits for the exact source version, then remains a stable
        // offer while ordinary dependencies become ready under backpressure.
        old_issued = issued[2]; old_prepared = prepared[2];
        child.prepare_ready[2] = 0;
        item = work(6);
        item.waits[0] = fence(GEMM_RID_W_CONSUME0, 6);
        item.prepare.valid = 1;
        item.prepare.mode = GEMM_PREPARE_SOURCE_READ;
        item.prepare.max_beats = 8;
        item.prepare.waits[0] = fence(GEMM_RID_T1, 2);
        item.notify = note(GEMM_RID_SC0, 7, 1);
        send(item); ticks(8);
        assert (!child.prepare_valid[2] && issued[2] == old_issued)
            else $fatal(1, "prepare ignored source generation");
        load_tile(1, 2); ticks(3);
        assert (child.prepare_valid[2]) else $fatal(1, "prepare not offered");
        consume_weight(); ticks(4);
        assert (child.prepare_valid[2] && child.cmd[2] === item && issued[2] == old_issued)
            else $fatal(1, "prepare changed/issued before accepted");
        @(negedge clk); child.prepare_ready[2] = 1;
        wait_retired(2, old_issued+1);
        assert (prepared[2] == old_prepared+1)
            else $fatal(1, "duplicate source preparation");
        release_source(1, 2);

        // Four real completions and all consume resources update together.
        drain();
        auto_complete[3:0] = 0;
        previous_w = child.sync_value[GEMM_RID_W0];
        previous_s = child.sync_value[GEMM_RID_SC0];
        previous_z = child.sync_value[GEMM_RID_ZP0];
        item = work(7); item.naive_terminal = 1;
        item.notify = note(GEMM_RID_G1, 1, 0); send(item);
        item = work(5); item.notify = note(GEMM_RID_W0, previous_w+1, 1); send(item);
        item = work(6); item.notify = note(GEMM_RID_SC0, previous_s+1, 1); send(item);
        item = work(10); item.notify = note(GEMM_RID_ZP0, previous_z+1, 1); send(item);
        ticks(10);
        @(posedge clk); #1; auto_complete[3:0] = '1; consume = '1;
        ticks(1);
        @(negedge clk); consume = '0;
        drain();
        assert (last_multi_completion >= 0 && child.sync_value[GEMM_RID_G1] == 1
             && child.sync_value[GEMM_RID_W0] == previous_w+1
             && child.sync_value[GEMM_RID_SC0] == previous_s+1
             && child.sync_value[GEMM_RID_ZP0] == previous_z+1)
            else $fatal(1, "simultaneous producer updates lost");
        item = work(2); item.rd = 4;
        item.waits[4] = fence(GEMM_RID_G1, 1);
        item.notify = note(GEMM_RID_O, 1, 0); send(item); drain();
        assert (child.sync_value[GEMM_RID_O] == 1)
            else $fatal(1, "STORE actual completion not counted");

        // The DMA wait evaluator must inspect every slot, not just slot0.
        for (int slot = 0; slot < GEMM_MAX_WAIT_DEPS; ++slot) begin
            old_issued = issued[4]; old_retired = retired[4];
            item = work(2); item.rd = 4;
            item.waits[slot] = fence(GEMM_RID_SC_CONSUME1,
                                    child.sync_value[GEMM_RID_SC_CONSUME1]+1);
            item.notify = note(GEMM_RID_O, 1, 0);
            send(item); ticks(6);
            assert (issued[4] == old_issued) else $fatal(1, "DMA ignored wait slot=%0d", slot);
            @(negedge clk); consume[3] = 1;
            @(negedge clk); consume[3] = 0;
            wait_retired(4, old_retired+1);
        end

        // Four queued commands plus the command stage fill while the executor
        // is blocked; the sixth offer must wait without losing its identity.
        child.cmd_ready[0] = 0;
        repeat (5) begin item = work(7); send(item); end
        item = work(7);
        @(negedge clk); cmd = item; cmd_valid = 1;
        ticks(5);
        assert (!cmd_ready && !quiescent) else $fatal(1, "queue capacity escaped");
        @(negedge clk); child.cmd_ready[0] = 1;
        do begin @(posedge clk); end while (!cmd_ready);
        @(negedge clk); cmd_valid = 0;
        drain();

        if (test_case == "unsupported_wait") begin
            item = work(7); item.waits[4] = fence(31, 0);
            old_issued = issued[0]; send(item);
            item = work(10); old_retired = retired[3]; send(item);
            wait_retired(3, old_retired+1); ticks(8);
            assert (issued[0] == old_issued && !quiescent)
                else $fatal(1, "unsupported RID did not fail closed");
            $display("TEST PASSED unsupported wait blocks only owning child"); $finish;
        end
        // Logical ingress retirement alone is insufficient for invocation done.
        executor_quiescent = 0;
        @(negedge clk); producer_done = 1;
        ticks(8);
        assert (!done_valid) else $fatal(1, "physical executor work ignored");
        executor_quiescent = 1;
        finish_job(17);
        start_job(12);
        assert (child.sync_value[GEMM_RID_T0] == 0 && child.sync_value[GEMM_RID_G0] == 0)
            else $fatal(1, "new invocation retained old generations");
        item = work(7); send(item); drain(); finish_job(0);
        start_job(13);
        item = work(7); send(item); drain(); finish_job(1);
        for (int c = 0; c < 5; ++c)
            assert (expected[c].size() == 0 && active[c].size() == 0 && issued[c] == retired[c])
                else $fatal(1, "scoreboard residue child=%0d", c);
        $display("TEST PASSED staged naive metadata controller: waits/RIDs, preparation, ownership, queues, LOAD join, simultaneous completion, three no-reset jobs");
        $finish;
    end
    initial begin
        #1000000;
        $fatal(1, "global test timeout");
    end
endmodule
