`timescale 1ns/1ps
`include "VX_define.vh"

// Improve lifecycle boundary test of the real controller. The command generator and
// scheduler quiescence are modeled; done generation and activity registers are
// never forced. This is not an end-to-end compute/memory or HBM visibility test.
module tb_controller;
    import VX_gpu_pkg::*;
    localparam int N_NODE = 6;
    localparam int EXPECT_FINALIZE = 1;
    VX_gemm_ctrl_if gemm_ctrl_if();
    bit clk = 0;
    always #5 clk = !clk;
    bit reset = 1;
    bit quiescent = 1;
    bit store_done = 0;
    VX_config_reg_if #(.NUM(`GEMM_CFG_REG_NUM), .DW(32)) cfg_reg_if();
    VX_node_done_if done_if();
    VX_gemm_sync_if sync_if[N_NODE]();
    wire [31:0] zeros[4];
    for (genvar i = 0; i < 4; ++i) begin : g_zero
        assign zeros[i] = 0;
    end
    for (genvar i = 0; i < N_NODE; ++i) begin : g_sync
        assign sync_if[i].valid = 0;
        assign sync_if[i].reg_idx = 0;
        assign sync_if[i].value = 0;
    end
    VX_gemm_ctrl #(.INSTANCE_ID("lifecycle_improve")) dut (
        .sched_source_valid_i('0),
        .sched_source_work_seq_i(zeros), .sched_source_total_beats_i(zeros),
        .sched_source_request_beats_i(zeros), .sched_source_response_beats_i(zeros),
        .sched_source_writer_beats_i(zeros), .sched_input_slot_occupancy_i('0),
        .sched_input_ahead_credit_i(1'b1), .sched_input_admit_valid_i(1'b0),
        .sched_input_admit_work_seq_i('0), .sched_fetch_complete_i('0),
        .sched_fetch_complete_work_seq_i(zeros), .consumer_block_valid_i(1'b0),
        .consumer_block_resource_i('0), .consumer_block_work_seq_i('0),
        .consumer_block_bank_i(1'b0), .consumer_block_target_i('0),
`ifdef PERF_ENABLE
        .gemm_unit_computing(1'b0),
`endif
`ifndef SYNTHESIS
`ifdef DBG_TRACE_GEMM_CMD_PERF
        .dbg_compute_active_i(1'b0),
`endif
`endif
        .clk(clk), .reset(reset), .cfg_reg_if(cfg_reg_if),
        .gemm_ctrl_if(gemm_ctrl_if), .done_if(done_if),
        .gemm_sync_slv_if(sync_if), .output_store_done_i(store_done),
        .progress_update_valid_o(), .progress_update_entry_id_o(),
        .progress_update_value_o()
    );

    task automatic step(input bit cfg, input bit store, input bit idle, input bit ready);
        @(negedge clk);
        cfg_reg_if.valid = cfg;
        store_done = store;
        quiescent = idle;
        done_if.ready = ready;
        @(posedge clk);
        #1;
    endtask

    task automatic run_job(input int entry, input int delay_cycles,
                           input int store_delay);
        int expected_store;
        int timeout_count;
        longint unsigned completed_before;
        cfg_reg_if.entry_id = entry;
        completed_before = dut.latency_observer.completed_count;
        step(1, 0, 1, delay_cycles == 0);
        step(0, 0, 0, delay_cycles == 0);
        step(0, 1, 0, delay_cycles == 0); // An earlier output tile store.
        repeat (3 + store_delay) step(0, 0, 0, delay_cycles == 0);
        step(0, 1, 1, delay_cycles == 0); // Last store and quiescence coincide.
        expected_store = 6 + store_delay;
        timeout_count = 0;
        while (!done_if.valid) begin
            step(0, 0, 1, delay_cycles == 0);
            timeout_count++;
            if (timeout_count > 8)
                $fatal(1, "Controller did not produce notification");
        end
        // done is now visible between edges; next edge is e_valid. Delayed
        // tests had ready low before completion, and retain it for D edges.
        repeat (delay_cycles) begin
            step(0, 0, 1, 0);
            if (!done_if.valid || done_if.entry_id != entry)
                $fatal(1, "Notification did not remain stable under backpressure");
        end
        step(0, 0, 1, 1);
        if (dut.latency_observer.completed_count != completed_before + 1
            || dut.latency_observer.last_store != expected_store
            || dut.latency_observer.last_gemm != expected_store + EXPECT_FINALIZE
            || dut.latency_observer.last_finalize != EXPECT_FINALIZE
            || dut.latency_observer.last_delivery != delay_cycles
            || dut.latency_observer.last_handshake != expected_store + EXPECT_FINALIZE + delay_cycles
            || dut.latency_observer.last_store_count != 2)
            $fatal(1, "Controller latency contract mismatch entry=%0d D=%0d store_delay=%0d", entry, delay_cycles, store_delay);
        step(0, 0, 1, 1);
    endtask

    initial begin
        cfg_reg_if.valid = 0;
        cfg_reg_if.regs = '0;
        cfg_reg_if.regs[0][0] = 1;
        cfg_reg_if.regs[29] = 4;
        cfg_reg_if.regs[30] = 16;
        cfg_reg_if.regs[31] = 32;
        cfg_reg_if.regs[32] = 5;
        cfg_reg_if.regs[33] = 4;
        cfg_reg_if.regs[34] = 16;
        cfg_reg_if.regs[35] = 32;
        cfg_reg_if.regs[40] = 7;
        cfg_reg_if.regs[41] = 7;
        cfg_reg_if.regs[42] = 7;
        cfg_reg_if.entry_id = 0;
        done_if.ready = 0;
        gemm_ctrl_if.input_read_flag = '0;
        gemm_ctrl_if.weight_read_flag = '0;
        gemm_ctrl_if.output_write_flag = '0;
        gemm_ctrl_if.quant_param_read_flag = '0;
        gemm_ctrl_if.dma_flag = '0;
        gemm_ctrl_if.scale_read_flag = '0;
        gemm_ctrl_if.zero_point_read_flag = '0;
        // Isolate lifecycle logic at its existing command/control boundaries.
        force cfg_reg_if.ready = quiescent;
        force dut.gemm_fsm_if.ctrl.start = 1'b0;
        force dut.fsm_idle = quiescent;
        force dut.scheduler_quiescent = 1'b1;
        repeat (3) @(negedge clk);
        reset = 0;
        run_job(11, 0, 0);
        run_job(12, 1, 0);
        run_job(13, 17, 0);
        run_job(14, 0, 7);
        run_job(15, 1, 7);
        run_job(16, 17, 7);
        $display("TEST PASSED: real controller lifecycle boundaries D=0,1,17; two stores; final store delay=0,7; six jobs without reset; modeled quiescence only");
        $finish;
    end
    initial begin
        #100000;
        $fatal(1, "Controller latency test timeout");
    end
endmodule
