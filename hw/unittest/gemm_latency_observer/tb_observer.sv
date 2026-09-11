`timescale 1ns/1ps

// Pure observation selftest. Controller tests are in tb_controller.sv.
module tb_observer;
    bit clk = 0;
    always #5 clk = !clk;
    bit reset = 1;
    bit cfg_start_fire = 0, store_done = 0, done_valid = 0, done_ready = 0;
    logic [31:0] cfg_entry_id = 0, done_entry_id = 0;
    VX_gemm_latency_observer #(.INSTANCE_ID("selftest"), .BACKEND("synthetic")) dut (.*);

    task automatic step(input bit cfg, input bit store, input bit valid,
                        input bit ready, input int cfg_id, input int done_id);
        @(negedge clk);
        cfg_start_fire = cfg;
        store_done = store;
        done_valid = valid;
        done_ready = ready;
        cfg_entry_id = cfg_id;
        done_entry_id = done_id;
        @(posedge clk);
        #1;
    endtask

    task automatic check(input int gemm, input int store, input int delivery,
                         input int count);
        if (dut.last_gemm != gemm || dut.last_store != store
            || dut.last_finalize != gemm - store || dut.last_delivery != delivery
            || dut.last_handshake != gemm + delivery || dut.last_store_count != count)
            $fatal(1, "Observer endpoint mismatch gemm=%0d store=%0d delivery=%0d count=%0d",
                dut.last_gemm, dut.last_store, dut.last_delivery, dut.last_store_count);
    endtask

    initial begin
        repeat (2) @(negedge clk);
        reset = 0;
        // All endpoints on one edge, including notification acceptance.
        step(1, 1, 1, 1, 7, 7);
        check(0, 0, 0, 1);
        step(0, 0, 0, 0, 0, 0);
        // Last of two stores wins; delayed notification must not affect gemm.
        step(1, 0, 0, 0, 8, 8);
        step(0, 1, 0, 0, 8, 8);
        step(0, 1, 1, 0, 8, 8);
        repeat (16) step(0, 0, 1, 0, 8, 8);
        step(0, 0, 1, 1, 8, 8);
        check(2, 2, 17, 2);
        // Start a new invocation while the prior notification is pending.
        step(1, 1, 0, 0, 9, 9);
        step(0, 0, 1, 0, 9, 9);
        step(1, 0, 1, 1, 10, 9);
        check(1, 0, 1, 1);
        step(0, 1, 0, 0, 10, 10);
        step(0, 0, 1, 1, 10, 10);
        check(2, 1, 0, 1);
        if (dut.completed_count != 4)
            $fatal(1, "Repeated-invocation count mismatch");
        $display("TEST PASSED: observation edge arithmetic, same-edge events, latest store, pending notification and repeated jobs");
        $finish;
    end
endmodule
