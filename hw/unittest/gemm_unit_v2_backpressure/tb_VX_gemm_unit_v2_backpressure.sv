`timescale 1ns / 1ps

`include "VX_define.vh"

module tb_VX_gemm_unit_v2_backpressure import VX_gpu_pkg::*; ();

    localparam int PERIOD = 10;
    localparam int ACC_ROW_BYTES = `GEMM_PSUM_DATA_SIZE;

    typedef logic [`MXU_ROW-1:0][`IFP_WIDTH-1:0] input_vector_t;
    typedef struct packed {
        logic [`GEMM_ACC_MEM_ADDR_WIDTH-1:0] addr;
        logic quant_dir;
        logic last;
    } expected_t;

    logic clk;
    logic reset;
    logic post_ready;
    gemm_input_ctrl_t packet_ctrl_drive;
    bit test_failed;
    int accepted_count;
    int compute_count;
    int push_count;
    int pop_count;
    int write_count;
    int input_backpressure_count;
    int last_write_count;
    expected_t accepted_q[$];
    expected_t commit_q[$];
    logic held_head_valid;
    logic [`MXU_COL-1:0][`MERGE_OUT_BW-1:0] held_head_data;
    gemm_input_ctrl_t held_head_ctrl;
    logic [`IFP_EXP_WIDTH-1:0] held_head_max_exp;

    VX_mem_bus_if #(
        .DATA_SIZE (`GEMM_INPUT_DATA_SIZE),
        .TAG_WIDTH (1)
    ) i_lmem_bus_if ();
    VX_mem_bus_if #(
        .DATA_SIZE (`GEMM_WEIGHT_DATA_SIZE),
        .TAG_WIDTH (1)
    ) w_lmem_bus_if ();
    VX_mem_bus_if #(
        .DATA_SIZE (`GEMM_SCALE_ZERO_DATA_SIZE),
        .TAG_WIDTH (1)
    ) sc_lmem_bus_if ();
    VX_mem_bus_if #(
        .DATA_SIZE (`GEMM_SCALE_ZERO_DATA_SIZE),
        .TAG_WIDTH (1)
    ) zp_lmem_bus_if ();
    VX_mem_bus_if #(
        .DATA_SIZE (`GEMM_OUTPUT_DATA_SIZE),
        .TAG_WIDTH (1)
    ) o_lmem_bus_if ();

    VX_gemm_unit_v2_if gemm_unit_v2_if ();
    assign gemm_unit_v2_if.input_admission_ready = 1'b1;
    for (genvar bank = 0; bank < 2; ++bank) begin : g_ready_generations
        assign gemm_unit_v2_if.w_load_value[bank] = 32'd1;
        assign gemm_unit_v2_if.s_load_value[bank] = 32'd1;
        assign gemm_unit_v2_if.z_load_value[bank] = 32'd1;
    end

    always_comb begin
        gemm_unit_v2_if.packet_ctrl = packet_ctrl_drive;
        gemm_unit_v2_if.packet_ctrl.valid
            = i_lmem_bus_if.req_valid;
    end

    VX_gemm_unit_v2 #(
        .INSTANCE_ID ("gemm_unit_v2_backpressure_ut")
    ) u_dut (
        .clk             (clk),
        .reset           (reset),
        .i_lmem_bus_if   (i_lmem_bus_if),
        .w_lmem_bus_if   (w_lmem_bus_if),
        .sc_lmem_bus_if  (sc_lmem_bus_if),
        .zp_lmem_bus_if  (zp_lmem_bus_if),
        .o_lmem_bus_if   (o_lmem_bus_if),
        .gemm_unit_v2_if (gemm_unit_v2_if)
    );

    initial clk = 1'b0;
    always #(PERIOD / 2) clk = ~clk;

    task automatic init_signals();
        i_lmem_bus_if.req_valid = 1'b0;
        i_lmem_bus_if.req_data = '0;
        i_lmem_bus_if.rsp_ready = 1'b1;
        w_lmem_bus_if.req_valid = 1'b0;
        w_lmem_bus_if.req_data = '0;
        w_lmem_bus_if.rsp_ready = 1'b1;
        sc_lmem_bus_if.req_valid = 1'b0;
        sc_lmem_bus_if.req_data = '0;
        sc_lmem_bus_if.rsp_ready = 1'b1;
        zp_lmem_bus_if.req_valid = 1'b0;
        zp_lmem_bus_if.req_data = '0;
        zp_lmem_bus_if.rsp_ready = 1'b1;
        o_lmem_bus_if.req_valid = 1'b0;
        o_lmem_bus_if.req_data = '0;
        o_lmem_bus_if.rsp_ready = 1'b1;
        packet_ctrl_drive = '0;
        post_ready = 1'b1;
        u_dut.postprocess_ready_test = 1'b1;
    endtask

    task automatic apply_reset();
        reset = 1'b1;
        i_lmem_bus_if.req_valid = 1'b0;
        packet_ctrl_drive = '0;
        repeat (5) @(posedge clk);
        @(negedge clk);
        reset = 1'b0;
        repeat (2) @(posedge clk);
        if (!gemm_unit_v2_if.pipeline_empty
         || u_dut.u_compute_core.merged_fifo_count != 0
         || u_dut.u_compute_core.tree_credit_q
             != $bits(u_dut.u_compute_core.tree_credit_q)'(
                    u_dut.u_compute_core.MERGED_RESULT_FIFO_DEPTH)) begin
            $error("backpressure reset did not clear all ownership");
            test_failed = 1'b1;
        end
    endtask

    task automatic drive_packets(
        input int count,
        input int unsigned base_row
    );
        input_vector_t data;
        data = '0;
        for (int i = 0; i < count; ++i) begin
            @(negedge clk);
            i_lmem_bus_if.req_valid = 1'b1;
            i_lmem_bus_if.req_data = '0;
            i_lmem_bus_if.req_data.data = data;
            i_lmem_bus_if.req_data.byteen = '1;
            packet_ctrl_drive = '0;
            packet_ctrl_drive.acc_wr_en = 1'b1;
            packet_ctrl_drive.acc_rd_addr
                = `GEMM_ACC_MEM_ADDR_WIDTH'((base_row + i) * ACC_ROW_BYTES);
            packet_ctrl_drive.acc_wr_addr
                = packet_ctrl_drive.acc_rd_addr;
            packet_ctrl_drive.quant_dir
                = ((i % 2) != 0) ? `QDIR_ROW : `QDIR_COL;
            packet_ctrl_drive.wreg_use_idx = gemm_wreg_idx_t'(i & 1);
            packet_ctrl_drive.sreg_use_idx = ((i % 2) != 0);
            packet_ctrl_drive.zreg_use_idx = (((i / 2) % 2) != 0);
            packet_ctrl_drive.w_load_target = 32'd1;
            packet_ctrl_drive.s_load_target = 32'd1;
            packet_ctrl_drive.z_load_target = 32'd1;
            packet_ctrl_drive.is_load = 1'b1;
            packet_ctrl_drive.last = ((i & 3) == 3);
            packet_ctrl_drive.notify_on_writeback
                = packet_ctrl_drive.last;
            do @(posedge clk); while (!i_lmem_bus_if.req_ready);
        end
        @(negedge clk);
        i_lmem_bus_if.req_valid = 1'b0;
        packet_ctrl_drive = '0;
    endtask

    task automatic stall_cycles(input int count);
        @(negedge clk);
        post_ready = 1'b0;
        u_dut.postprocess_ready_test = 1'b0;
        repeat (count) @(posedge clk);
        @(negedge clk);
        post_ready = 1'b1;
        u_dut.postprocess_ready_test = 1'b1;
    endtask

    task automatic stall_pattern();
        // Close the post boundary before the first result arrives.  This
        // specifically covers FIFO fall-through on the first output cycle.
        @(negedge clk);
        post_ready = 1'b0;
        u_dut.postprocess_ready_test = 1'b0;
        wait (u_dut.u_compute_core.merged_fifo_push);
        // Keep ready low across the edge that captures the first result.
        @(posedge clk);
        @(negedge clk);
        post_ready = 1'b1;
        u_dut.postprocess_ready_test = 1'b1;
        wait (pop_count >= 2);
        stall_cycles(2);
        wait (pop_count >= 5);
        stall_cycles(6);
        wait (pop_count >= 9);
        stall_cycles(7);
        for (int i = 0; i < 48; ++i) begin
            @(negedge clk);
            post_ready = ((i * 13 + 5) % 7) >= 2;
            u_dut.postprocess_ready_test = post_ready;
        end
        post_ready = 1'b1;
        u_dut.postprocess_ready_test = 1'b1;
    endtask

    task automatic wait_for_drain(input int max_cycles);
        int timeout;
        timeout = 0;
        while (!gemm_unit_v2_if.pipeline_empty && timeout < max_cycles) begin
            @(posedge clk);
            timeout++;
        end
        if (timeout == max_cycles) begin
            $error("timeout draining backpressure pipeline");
            test_failed = 1'b1;
        end
        repeat (4) @(posedge clk);
    endtask

    always @(posedge clk) begin : scoreboard
        expected_t item;
        if (reset) begin
            accepted_count = 0;
            compute_count = 0;
            push_count = 0;
            pop_count = 0;
            write_count = 0;
            input_backpressure_count = 0;
            last_write_count = 0;
            accepted_q.delete();
            commit_q.delete();
            held_head_valid = 1'b0;
        end else begin
            if (i_lmem_bus_if.req_valid && !i_lmem_bus_if.req_ready)
                input_backpressure_count++;
            if (i_lmem_bus_if.req_valid && i_lmem_bus_if.req_ready) begin
                item.addr = packet_ctrl_drive.acc_wr_addr;
                item.quant_dir = packet_ctrl_drive.quant_dir;
                item.last = packet_ctrl_drive.last;
                accepted_q.push_back(item);
                accepted_count++;
            end
            if (u_dut.u_compute_core.compute_fire)
                compute_count++;
            if (u_dut.u_compute_core.merged_fifo_push)
                push_count++;
            if (u_dut.u_compute_core.merged_fifo_pop) begin
                if (accepted_q.size() == 0) begin
                    $error("merged FIFO pop without accepted transaction");
                    test_failed = 1'b1;
                end else begin
                    item = accepted_q.pop_front();
                    if (u_dut.u_compute_core.merged_fifo_data_out.ctrl.acc_wr_addr !== item.addr
                     || u_dut.u_compute_core.merged_fifo_data_out.ctrl.quant_dir !== item.quant_dir
                     || u_dut.u_compute_core.merged_fifo_data_out.ctrl.last !== item.last) begin
                        $error("merged FIFO transaction reordered");
                        test_failed = 1'b1;
                    end
                    commit_q.push_back(item);
                end
                pop_count++;
            end
            if (u_dut.acc_write_fire) begin
                if (commit_q.size() == 0) begin
                    $error("ACC commit without launched transaction");
                    test_failed = 1'b1;
                end else begin
                    item = commit_q.pop_front();
                    if (u_dut.u_compute_core.ctrl_pipe[u_dut.u_compute_core.WRITE_CTRL_IDX].acc_wr_addr
                        !== item.addr) begin
                        $error("ACC commit transaction reordered");
                        test_failed = 1'b1;
                    end
                end
                write_count++;
            end
            if (gemm_unit_v2_if.last_write)
                last_write_count++;

            if (!post_ready
             && (!u_dut.u_compute_core.merged_fifo_empty || u_dut.u_compute_core.merged_fifo_push)) begin
                if (held_head_valid
                 && (u_dut.u_compute_core.merged_fifo_data_out.data !== held_head_data
                  || u_dut.u_compute_core.merged_fifo_data_out.ctrl !== held_head_ctrl
                  || u_dut.u_compute_core.merged_fifo_data_out.max_exp !== held_head_max_exp)) begin
                    $error("merged FIFO head changed while valid and stalled");
                    test_failed = 1'b1;
                end
                held_head_valid = 1'b1;
                held_head_data = u_dut.u_compute_core.merged_fifo_data_out.data;
                held_head_ctrl = u_dut.u_compute_core.merged_fifo_data_out.ctrl;
                held_head_max_exp = u_dut.u_compute_core.merged_fifo_data_out.max_exp;
            end else begin
                held_head_valid = 1'b0;
            end
        end
    end

    initial begin
        test_failed = 1'b0;
        reset = 1'b0;
        init_signals();
        apply_reset();

        fork
            drive_packets(40, 0);
            stall_pattern();
        join
        wait_for_drain(1000);

        if (accepted_count != 40
         || compute_count != accepted_count
         || push_count != accepted_count
         || pop_count != accepted_count
         || write_count != accepted_count
         || accepted_q.size() != 0
         || commit_q.size() != 0) begin
            $error("backpressure count mismatch accepted=%0d compute=%0d push=%0d pop=%0d write=%0d aq=%0d cq=%0d",
                   accepted_count, compute_count, push_count, pop_count,
                   write_count, accepted_q.size(), commit_q.size());
            test_failed = 1'b1;
        end
        if (input_backpressure_count == 0) begin
            $error("depth-six capacity test never backpressured input");
            test_failed = 1'b1;
        end

        // Reset with reserved results and a non-empty FIFO.  No pre-reset
        // transaction may commit after reset is released.
        @(negedge clk);
        post_ready = 1'b0;
        u_dut.postprocess_ready_test = 1'b0;
        drive_packets(4, 64);
        wait (u_dut.u_compute_core.merged_fifo_count >= 2);
        apply_reset();
        post_ready = 1'b1;
        u_dut.postprocess_ready_test = 1'b1;
        repeat (20) @(posedge clk);
        if (!gemm_unit_v2_if.pipeline_empty || write_count != 0) begin
            $error("stale transaction survived occupied reset");
            test_failed = 1'b1;
        end

        drive_packets(4, 96);
        wait_for_drain(400);
        if (accepted_count != 4 || write_count != 4) begin
            $error("post-reset stream mismatch accepted=%0d write=%0d",
                   accepted_count, write_count);
            test_failed = 1'b1;
        end

        if (test_failed)
            $fatal(1, "VX_gemm_unit_v2 backpressure unittest FAILED");
        $display("VX_gemm_unit_v2 backpressure unittest PASSED stalls=1,2,6,7,random reset=occupied");
        $finish;
    end

endmodule
