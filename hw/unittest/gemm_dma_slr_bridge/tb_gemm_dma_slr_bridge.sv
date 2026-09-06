`timescale 1ns/1ps
`include "VX_define.vh"

module gemm_dma_transport_case #(
    parameter bit SLR_ENABLE = 1'b1,
    parameter int LAUNCH_DEPTH = 2
) (
    output logic finished = 0
);
    import VX_gpu_pkg::*;
    localparam int TAG_COUNT = 1 << GEMM_DMA_TAG_WIDTH;
    logic clk = 0;
    logic reset = 1;
    always #5 clk = ~clk;
    VX_gemm_dma_ctrl_if source_if ();
    VX_gemm_dma_ctrl_if backend_if ();
    VX_gemm_sync_if backend_sync_if ();
    VX_gemm_sync_if source_sync_if ();
    logic backend_store_done;
    wire source_store_done;
    VX_gemm_dma_transport #(
        .INSTANCE_ID("tb"), .SLR_ENABLE(SLR_ENABLE),
        .LAUNCH_DEPTH(LAUNCH_DEPTH)
    ) dut (
        .clk (clk), .reset (reset),
        .source_if (source_if), .backend_if (backend_if),
        .backend_store_done (backend_store_done),
        .source_store_done (source_store_done),
        .backend_sync_if (backend_sync_if),
        .source_sync_if (source_sync_if)
    );

    typedef struct packed {
        logic prepare_op;
        logic [GEMM_DMA_TAG_WIDTH-1:0] tag;
        gemm_unified_cmd_t cmd;
        int accepted_cycle;
    } offer_t;
    offer_t expected_ops[$];
    logic [GEMM_DMA_TAG_WIDTH:0] expected_done[$];
    logic [63:0] expected_sync[$];
    int cycle = 0;
    int accepted_commands = 0;
    int accepted_prepares = 0;
    int observed_done = 0;
    int observed_sync = 0;
    int last_done_cycle = -1;
    logic backend_prepared = 0;
    gemm_unified_cmd_t backend_prepared_cmd;
    bit burst_check = 1;
    bit measure_latency = 0;
    bit force_ready = 0;
    bit force_block = 0;

    always @(posedge clk) begin : monitor
        offer_t expected;
        logic [GEMM_DMA_TAG_WIDTH:0] done_record;
        logic [63:0] sync_record;
        if (!reset) begin
            cycle++;
            if (source_if.cmd_valid && source_if.cmd_ready)
                expected_ops.push_back('{1'b0, source_if.cmd_tag, source_if.cmd, cycle});
            if (source_if.prepare_valid && source_if.prepare_ready)
                expected_ops.push_back('{1'b1, source_if.cmd_tag, source_if.prepare_cmd, cycle});
            if ((backend_if.cmd_valid && backend_if.cmd_ready)
             || (backend_if.prepare_valid && backend_if.prepare_ready)) begin
                assert (expected_ops.size() != 0) else $fatal(1, "unexpected backend offer");
                expected = expected_ops.pop_front();
                if (measure_latency)
                    assert (cycle - expected.accepted_cycle == (SLR_ENABLE ? 3 : 1))
                        else $fatal(1, "SLR=%0d depth=%0d forward latency=%0d",
                                    SLR_ENABLE, LAUNCH_DEPTH, cycle - expected.accepted_cycle);
                assert (expected.prepare_op == backend_if.prepare_valid)
                    else $fatal(1, "prepare/release overtaken");
                if (expected.prepare_op) begin
                    assert (backend_if.prepare_cmd === expected.cmd)
                        else $fatal(1, "prepare payload changed");
                    backend_prepared = 1;
                    backend_prepared_cmd = expected.cmd;
                    accepted_prepares++;
                end else begin
                    assert ({backend_if.cmd_tag, backend_if.cmd}
                         === {expected.tag, expected.cmd})
                        else $fatal(1, "command payload/tag changed");
                    if (backend_prepared) begin
                        assert (backend_if.cmd == backend_prepared_cmd)
                            else $fatal(1, "prepared command was not next release");
                        backend_prepared = 0;
                    end
                    accepted_commands++;
                end
            end
            if (backend_if.done)
                expected_done.push_back({backend_store_done, backend_if.done_tag});
            if (source_if.done) begin
                assert (expected_done.size() != 0) else $fatal(1, "stray completion");
                done_record = expected_done.pop_front();
                assert ({source_store_done, source_if.done_tag} === done_record)
                    else $fatal(1, "completion tag/store flag changed");
                if (burst_check && observed_done > 0)
                    assert (cycle == last_done_cycle + 1)
                        else $fatal(1, "completion burst lost one-per-cycle throughput");
                last_done_cycle = cycle;
                observed_done++;
            end
            if (backend_sync_if.valid && backend_sync_if.ready)
                expected_sync.push_back({backend_sync_if.reg_idx, backend_sync_if.value});
            if (source_sync_if.valid && source_sync_if.ready) begin
                assert (expected_sync.size() != 0) else $fatal(1, "unexpected sync");
                sync_record = expected_sync.pop_front();
                assert ({source_sync_if.reg_idx, source_sync_if.value} === sync_record)
                    else $fatal(1, "sync payload changed");
                observed_sync++;
            end
            if (source_if.idle)
                assert (expected_ops.size() == 0 && expected_done.size() == 0
                     && expected_sync.size() == 0 && !backend_prepared
                     && observed_done == accepted_commands)
                    else $fatal(1, "premature drain");
            if (cycle > 1000)
                $fatal(1, "timeout");
        end else begin
            cycle = 0;
            expected_ops.delete();
            expected_done.delete();
            expected_sync.delete();
            accepted_commands = 0;
            accepted_prepares = 0;
            observed_done = 0;
            observed_sync = 0;
            last_done_cycle = -1;
            backend_prepared = 0;
        end
    end

    // Backend admission independently stalls commands and prepares. This
    // fills the forward credits and tests stability at the destination mux.
    always @(negedge clk) begin
        backend_if.cmd_ready = !reset && !force_block
                           && (force_ready || (cycle > 18 && cycle % 5 != 0));
        backend_if.prepare_ready = !reset && !force_block
                               && (force_ready || (cycle > 25 && cycle % 3 != 0));
        source_sync_if.ready = !reset && cycle > 20 && cycle % 4 == 0;
    end

    task automatic offer(input int tag, input bit is_prepare);
        gemm_unified_cmd_t cmd;
        cmd = '0;
        cmd.instr = 32'h00001001;
        cmd.rs1_data = 64'(tag * 64);
        cmd.rs2_data = 64'hfedcba9800000000 + 64'(tag * 256);
        cmd.dma_priority = tag[0];
        @(negedge clk);
        source_if.cmd = cmd;
        source_if.prepare_cmd = cmd;
        source_if.cmd_tag = GEMM_DMA_TAG_WIDTH'(tag);
        source_if.cmd_valid = !is_prepare;
        source_if.start = !is_prepare;
        source_if.prepare_valid = is_prepare;
        do @(posedge clk); while (!(is_prepare ? source_if.prepare_ready
                                               : source_if.cmd_ready));
        @(negedge clk);
        source_if.cmd_valid = 0;
        source_if.start = 0;
        source_if.prepare_valid = 0;
    endtask

    task automatic complete(input int tag);
        int completion_cycle;
        @(negedge clk);
        backend_if.done = 1;
        backend_if.done_tag = GEMM_DMA_TAG_WIDTH'(tag);
        backend_store_done = 1;
        completion_cycle = cycle;
        #1;
        if (!SLR_ENABLE)
            assert (source_if.done && source_store_done
                 && source_if.done_tag == GEMM_DMA_TAG_WIDTH'(tag))
                else $fatal(1, "local completion acquired latency");
        @(negedge clk);
        backend_if.done = 0;
        backend_store_done = 0;
        if (SLR_ENABLE) begin
            wait (source_if.done);
            assert (cycle - completion_cycle == 2)
                else $fatal(1, "SLR completion latency changed");
        end
    endtask

    initial begin
        source_if.start = 0;
        source_if.cmd_valid = 0;
        source_if.prepare_valid = 0;
        source_if.cmd = '0;
        source_if.prepare_cmd = '0;
        source_if.cmd_tag = '0;
        backend_if.idle = 1;
        backend_if.done = 0;
        backend_if.done_tag = '0;
        backend_store_done = 0;
        backend_sync_if.valid = 0;
        backend_sync_if.reg_idx = 0;
        backend_sync_if.value = 0;
        repeat (5) @(negedge clk);
        reset = 0;
        fork
            begin
                for (int tag = 0; tag < TAG_COUNT; ++tag) begin
                    if (tag == 3)
                        offer(tag, 1);
                    offer(tag, 0);
                end
            end
            begin
                for (int item = 0; item < 16; ++item) begin
                    @(negedge clk);
                    backend_sync_if.valid = 1;
                    backend_sync_if.reg_idx = 32'(item);
                    backend_sync_if.value = 32'habc00000 + 32'(item);
                    do @(posedge clk); while (!backend_sync_if.ready);
                    @(negedge clk);
                    backend_sync_if.valid = 0;
                end
            end
        join
        wait (accepted_commands == TAG_COUNT);
        // Reverse completion order is legal because the scheduler returns tags.
        for (int tag = TAG_COUNT-1; tag >= 0; --tag) begin
            @(negedge clk);
            backend_if.done = 1;
            backend_if.done_tag = GEMM_DMA_TAG_WIDTH'(tag);
            backend_store_done = tag[0];
        end
        @(negedge clk);
        backend_if.done = 0;
        backend_store_done = 0;
        wait (observed_done == TAG_COUNT && observed_sync == 16);
        wait (source_if.idle);
        @(negedge clk);
        assert (accepted_prepares == 1) else $fatal(1, "prepare not exercised");
        // Reuse a completed tag in a quiescent invocation. Both PREPARE and
        // RELEASE must incur the same common-launch latency, with no change
        // to direct local completion observation.
        burst_check = 0;
        force_ready = 1;
        measure_latency = 1;
        offer(0, 1);
        offer(0, 0);
        wait (accepted_commands == TAG_COUNT + 1);
        complete(0);
        wait (observed_done == TAG_COUNT + 1 && source_if.idle);

        // Reset with commands in the launch/crossing receiver and an owned,
        // unreleased PREPARE. No aborted operation may leak into a new run.
        @(negedge clk);
        force_block = 1;
        measure_latency = 0;
        offer(1, 0);
        if (SLR_ENABLE || LAUNCH_DEPTH > 1)
            offer(2, 1);
        repeat (8) @(negedge clk);
        assert (!source_if.idle) else $fatal(1, "pending reset setup is empty");
        reset = 1;
        repeat (4) @(negedge clk);
        reset = 0;
        force_block = 0;
        repeat (8) @(negedge clk);
        assert (source_if.idle && !backend_if.cmd_valid && !backend_if.prepare_valid
             && accepted_commands == 0 && accepted_prepares == 0 && observed_done == 0)
            else $fatal(1, "reset leaked an aborted operation/completion");
        // Also reset PREPARE ownership in the depth-one configuration, where
        // a blocked older command occupies the only launch entry.
        force_block = 1;
        offer(1, 1);
        repeat (8) @(negedge clk);
        reset = 1;
        repeat (4) @(negedge clk);
        reset = 0;
        force_block = 0;
        repeat (8) @(negedge clk);
        assert (source_if.idle && accepted_prepares == 0)
            else $fatal(1, "reset retained PREPARE ownership");
        measure_latency = 1;
        offer(1, 0);
        wait (accepted_commands == 1);
        complete(1);
        wait (observed_done == 1 && source_if.idle);
        $display("PASSED: DMA transport SLR=%0d launch=%0d ordering, stalls, tag reuse, latency, reset and drain",
                 SLR_ENABLE, LAUNCH_DEPTH);
        finished = 1;
    end
endmodule

module tb_gemm_dma_slr_bridge;
    wire [2:0] finished;
    gemm_dma_transport_case #(.SLR_ENABLE(0), .LAUNCH_DEPTH(1)) local1 (finished[0]);
    gemm_dma_transport_case #(.SLR_ENABLE(0), .LAUNCH_DEPTH(2)) local2 (finished[1]);
    gemm_dma_transport_case #(.SLR_ENABLE(1), .LAUNCH_DEPTH(2)) slr2 (finished[2]);
    initial begin
        wait (&finished);
        $display("TEST PASSED: common DMA transport local1/local2/SLR2");
        $finish;
    end
endmodule
