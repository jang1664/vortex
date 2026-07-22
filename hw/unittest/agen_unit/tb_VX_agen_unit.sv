`timescale 1ns / 1ps

`include "VX_define.vh"

module tb_VX_agen_unit;
    import VX_gpu_pkg::*;

    localparam int NUM_STREAMS = 3;
    localparam int NUM_DIMS = 3;
    localparam int QUEUE_DEPTH = 4;
    localparam int TOTAL_THREADS = `NUM_WARPS * `NUM_THREADS;
    localparam int NUM_SLICES = `NUM_THREADS / `SIMD_WIDTH;
    localparam int TOTAL_SLICES = `NUM_WARPS * NUM_SLICES;
    localparam int TB_POP_STALL_TIMEOUT = 64;

    localparam logic [1:0] STREAM_LD0 = 2'd0;
    localparam logic [1:0] STREAM_LD1 = 2'd1;
    localparam logic [1:0] STREAM_ST  = 2'd2;

    localparam logic [2:0] OP_CFG_BASE = 3'd0;
    localparam logic [2:0] OP_CFG_DIM0 = 3'd1;
    localparam logic [2:0] OP_CFG_DIM1 = 3'd2;
    localparam logic [2:0] OP_CFG_DIM2 = 3'd3;
    localparam logic [2:0] OP_START    = 3'd4;
    localparam logic [2:0] OP_RESET    = 3'd5;
    localparam logic [2:0] OP_POP      = 3'd6;

    typedef logic [`SIMD_WIDTH-1:0] lane_mask_t;
    typedef logic [`SIMD_WIDTH-1:0][63:0] lane_values_t;

    logic clk;
    logic reset;
    integer errors;
    integer commit_handshakes;

    logic [63:0] shadow_base [NUM_STREAMS][TOTAL_THREADS];
    logic [63:0] shadow_stride [NUM_STREAMS][TOTAL_THREADS][NUM_DIMS];
    logic [31:0] shadow_bound [NUM_STREAMS][TOTAL_THREADS][NUM_DIMS];
    logic [63:0] expected_q [NUM_STREAMS][TOTAL_THREADS][$];

    VX_dispatch_if dispatch_if[`ISSUE_WIDTH]();
    VX_commit_if commit_if[`ISSUE_WIDTH]();

    VX_agen_unit #(
        .INSTANCE_ID       ("agen-test"),
        .POP_STALL_TIMEOUT (TB_POP_STALL_TIMEOUT)
    ) dut (
        .clk         (clk),
        .reset       (reset),
        .dispatch_if (dispatch_if),
        .commit_if   (commit_if)
    );

    always #5 clk = ~clk;

    always @(posedge clk) begin
        if (!reset && commit_if[0].valid && commit_if[0].ready)
            ++commit_handshakes;
    end

    function automatic int thread_index(
        input int wid,
        input int sid,
        input int lane
    );
        return wid * `NUM_THREADS + sid * `SIMD_WIDTH + lane;
    endfunction

    function automatic logic [63:0] random_stride(input int selector);
        unique case (selector)
            0: return 64'd0;
            1: return 64'd1;
            2: return -64'sd1;
            3: return 64'h7fff_ffff_ffff_ffff;
            4: return 64'h8000_0000_0000_0000;
            5: return 64'd64;
            6: return -64'sd128;
            default: return {$urandom, $urandom};
        endcase
    endfunction

    task automatic check(input logic condition, input string message);
        if (condition !== 1'b1) begin
            $display("ERROR: %s", message);
            ++errors;
        end
    endtask

    task automatic ref_start_lane(input int stream, input int thread_id);
        logic [63:0] offset0;
        logic [63:0] offset1;
        logic [63:0] offset2;
        begin
            expected_q[stream][thread_id].delete();
            if ((shadow_bound[stream][thread_id][0] == 0)
             || (shadow_bound[stream][thread_id][1] == 0)
             || (shadow_bound[stream][thread_id][2] == 0)) begin
                return;
            end

            offset2 = '0;
            for (int unsigned i2 = 0;
                 i2 < shadow_bound[stream][thread_id][2]; ++i2) begin
                offset1 = '0;
                for (int unsigned i1 = 0;
                     i1 < shadow_bound[stream][thread_id][1]; ++i1) begin
                    offset0 = '0;
                    for (int unsigned i0 = 0;
                         i0 < shadow_bound[stream][thread_id][0]; ++i0) begin
                        expected_q[stream][thread_id].push_back(
                            shadow_base[stream][thread_id]
                          + offset0 + offset1 + offset2);
                        offset0 += shadow_stride[stream][thread_id][0];
                    end
                    offset1 += shadow_stride[stream][thread_id][1];
                end
                offset2 += shadow_stride[stream][thread_id][2];
            end
        end
    endtask

    task automatic apply_model_instruction(
        input int stream,
        input logic [2:0] op,
        input int wid,
        input int sid,
        input lane_mask_t tmask,
        input lane_values_t rs1,
        input lane_values_t rs2
    );
        int thread_id;
        int dim;
        begin
            for (int lane = 0; lane < `SIMD_WIDTH; ++lane) begin
                if (tmask[lane]) begin
                    thread_id = thread_index(wid, sid, lane);
                    unique case (op)
                        OP_CFG_BASE: begin
                            shadow_base[stream][thread_id] = rs1[lane];
                        end
                        OP_CFG_DIM0,
                        OP_CFG_DIM1,
                        OP_CFG_DIM2: begin
                            dim = op - OP_CFG_DIM0;
                            shadow_stride[stream][thread_id][dim] = rs1[lane];
                            shadow_bound[stream][thread_id][dim] = rs2[lane][31:0];
                        end
                        OP_START: begin
                            ref_start_lane(stream, thread_id);
                        end
                        OP_RESET: begin
                            // RESET flushes active/queued state but preserves shadow.
                            expected_q[stream][thread_id].delete();
                        end
                        default: begin
                        end
                    endcase
                end
            end
        end
    endtask

    task automatic drive_instruction_now(
        input int stream,
        input logic [2:0] op,
        input int wid,
        input int sid,
        input lane_mask_t tmask,
        input lane_values_t rs1,
        input lane_values_t rs2,
        input logic [NUM_REGS_BITS-1:0] rd,
        output integer stall_cycles
    );
        begin
            dispatch_if[0].data = '0;
            dispatch_if[0].data.wis = wid_to_wis(NW_WIDTH'(wid));
            dispatch_if[0].data.sid = sid;
            dispatch_if[0].data.tmask = tmask;
            dispatch_if[0].data.op_type = op;
            dispatch_if[0].data.op_args.agen.stream = stream;
            dispatch_if[0].data.wb = (op == OP_POP);
            dispatch_if[0].data.rd = rd;
            dispatch_if[0].data.rs1_data = rs1;
            dispatch_if[0].data.rs2_data = rs2;
            dispatch_if[0].data.sop = 1'b1;
            dispatch_if[0].data.eop = 1'b1;
            dispatch_if[0].valid = 1'b1;
            stall_cycles = 0;
            #1;
            while (dispatch_if[0].ready !== 1'b1) begin
                @(negedge clk);
                ++stall_cycles;
                #1;
            end
            @(posedge clk);
            @(negedge clk);
            dispatch_if[0].valid = 1'b0;
        end
    endtask

    task automatic drive_instruction(
        input int stream,
        input logic [2:0] op,
        input int wid,
        input int sid,
        input lane_mask_t tmask,
        input lane_values_t rs1,
        input lane_values_t rs2,
        input logic [NUM_REGS_BITS-1:0] rd,
        output integer stall_cycles
    );
        begin
            @(negedge clk);
            drive_instruction_now(stream, op, wid, sid, tmask, rs1, rs2,
                                  rd, stall_cycles);
        end
    endtask

    task automatic wait_commit(output commit_t result);
        int timeout;
        begin
            timeout = 0;
            while (!commit_if[0].valid && timeout < 200) begin
                @(negedge clk);
                ++timeout;
            end
            check(timeout < 200, "commit timeout");
            result = commit_if[0].data;
        end
    endtask

    task automatic send_nonpop(
        input int stream,
        input logic [2:0] op,
        input int wid,
        input int sid,
        input lane_mask_t tmask,
        input lane_values_t rs1,
        input lane_values_t rs2
    );
        integer stalls;
        commit_t result;
        begin
            drive_instruction(stream, op, wid, sid, tmask, rs1, rs2,
                              '0, stalls);
            wait_commit(result);
            check(stalls == 0, "configuration/reset instruction stalled");
            check(!result.wb, "configuration/reset committed with writeback");
            check(result.wid == NW_WIDTH'(wid), "non-POP commit changed wid");
            check(result.sid == sid, "non-POP commit changed sid");
            apply_model_instruction(stream, op, wid, sid, tmask, rs1, rs2);
        end
    endtask

    task automatic configure_descriptor(
        input int stream,
        input int wid,
        input int sid,
        input lane_mask_t tmask,
        input lane_values_t base,
        input lane_values_t stride0,
        input lane_values_t stride1,
        input lane_values_t stride2,
        input lane_values_t bound0,
        input lane_values_t bound1,
        input lane_values_t bound2
    );
        lane_values_t zeros;
        begin
            zeros = '0;
            send_nonpop(stream, OP_CFG_BASE, wid, sid, tmask, base, zeros);
            send_nonpop(stream, OP_CFG_DIM0, wid, sid, tmask, stride0, bound0);
            send_nonpop(stream, OP_CFG_DIM1, wid, sid, tmask, stride1, bound1);
            send_nonpop(stream, OP_CFG_DIM2, wid, sid, tmask, stride2, bound2);
        end
    endtask

    task automatic start_descriptor(
        input int stream,
        input int wid,
        input int sid,
        input lane_mask_t tmask
    );
        lane_values_t zeros;
        begin
            zeros = '0;
            send_nonpop(stream, OP_START, wid, sid, tmask, zeros, zeros);
        end
    endtask

    task automatic program_descriptor(
        input int stream,
        input int wid,
        input int sid,
        input lane_mask_t tmask,
        input lane_values_t base,
        input lane_values_t stride0,
        input lane_values_t stride1,
        input lane_values_t stride2,
        input lane_values_t bound0,
        input lane_values_t bound1,
        input lane_values_t bound2
    );
        begin
            configure_descriptor(stream, wid, sid, tmask, base,
                                 stride0, stride1, stride2,
                                 bound0, bound1, bound2);
            start_descriptor(stream, wid, sid, tmask);
        end
    endtask

    task automatic send_reset(
        input int stream,
        input int wid,
        input int sid,
        input lane_mask_t tmask
    );
        lane_values_t zeros;
        begin
            zeros = '0;
            send_nonpop(stream, OP_RESET, wid, sid, tmask, zeros, zeros);
        end
    endtask

    task automatic reset_all_streams;
        begin
            for (int stream = 0; stream < NUM_STREAMS; ++stream) begin
                for (int wid = 0; wid < `NUM_WARPS; ++wid) begin
                    for (int sid = 0; sid < NUM_SLICES; ++sid)
                        send_reset(stream, wid, sid, '1);
                end
            end
        end
    endtask

    task automatic pop_and_check(
        input int stream,
        input int wid,
        input int sid,
        input lane_mask_t tmask,
        input logic issue_now,
        input logic require_stall,
        output integer stalls
    );
        lane_values_t zeros;
        lane_values_t expected;
        commit_t result;
        int thread_id;
        begin
            zeros = '0;
            expected = '0;
            for (int lane = 0; lane < `SIMD_WIDTH; ++lane) begin
                if (tmask[lane]) begin
                    thread_id = thread_index(wid, sid, lane);
                    check(expected_q[stream][thread_id].size() != 0,
                          $sformatf("reference queue empty stream=%0d thread=%0d",
                                    stream, thread_id));
                    if (expected_q[stream][thread_id].size() != 0)
                        expected[lane] = expected_q[stream][thread_id][0];
                end
            end

            if (issue_now)
                drive_instruction_now(stream, OP_POP, wid, sid, tmask,
                                      zeros, zeros, 5'd7, stalls);
            else
                drive_instruction(stream, OP_POP, wid, sid, tmask,
                                  zeros, zeros, 5'd7, stalls);
            wait_commit(result);

            if (require_stall)
                check(stalls != 0, "blocked POP did not stall before waking");
            check(result.wb, "POP did not request integer writeback");
            check(result.rd == 5'd7, "POP changed destination register");
            check(result.wid == NW_WIDTH'(wid), "POP commit changed wid");
            check(result.sid == sid, "POP commit changed sid");
            check(result.tmask == tmask, "POP commit changed lane mask");
            for (int lane = 0; lane < `SIMD_WIDTH; ++lane) begin
                if (tmask[lane]) begin
                    thread_id = thread_index(wid, sid, lane);
                    check(result.data[lane] == expected[lane],
                          $sformatf("stream=%0d wid=%0d sid=%0d lane=%0d got=%h expected=%h",
                                    stream, wid, sid, lane,
                                    result.data[lane], expected[lane]));
                    if (expected_q[stream][thread_id].size() != 0)
                        void'(expected_q[stream][thread_id].pop_front());
                end
            end
        end
    endtask

    task automatic wait_queue_count(
        input int stream,
        input int thread_id,
        input int expected_count,
        input int timeout_cycles
    );
        int cycles;
        begin
            cycles = 0;
            while ((dut.queue_count[stream][thread_id] != expected_count)
                && (cycles < timeout_cycles)) begin
                @(negedge clk);
                ++cycles;
            end
            check(cycles < timeout_cycles,
                  $sformatf("queue count timeout stream=%0d thread=%0d got=%0d expected=%0d",
                            stream, thread_id,
                            dut.queue_count[stream][thread_id], expected_count));
        end
    endtask

    task automatic check_backpressured_pop(
        input int stream,
        input int wid,
        input int sid,
        input lane_mask_t tmask
    );
        lane_values_t zeros;
        lane_values_t expected;
        commit_t held_result;
        integer stalls;
        integer handshakes_before;
        int thread_id;
        begin
            zeros = '0;
            expected = '0;
            for (int lane = 0; lane < `SIMD_WIDTH; ++lane) begin
                if (tmask[lane]) begin
                    thread_id = thread_index(wid, sid, lane);
                    check(expected_q[stream][thread_id].size() != 0,
                          "backpressure reference queue empty");
                    if (expected_q[stream][thread_id].size() != 0)
                        expected[lane] = expected_q[stream][thread_id][0];
                end
            end

            @(negedge clk);
            commit_if[0].ready = 1'b0;
            handshakes_before = commit_handshakes;
            drive_instruction_now(stream, OP_POP, wid, sid, tmask,
                                  zeros, zeros, 5'd11, stalls);
            check(commit_if[0].valid, "POP response was not held under backpressure");
            held_result = commit_if[0].data;
            for (int cycle = 0; cycle < 4; ++cycle) begin
                @(negedge clk);
                #1;
                check(commit_if[0].valid, "pending POP response lost valid");
                check(commit_if[0].data === held_result,
                      "pending POP response changed under backpressure");
                check(commit_handshakes == handshakes_before,
                      "POP committed while commit ready was low");
            end

            for (int lane = 0; lane < `SIMD_WIDTH; ++lane) begin
                if (tmask[lane]) begin
                    thread_id = thread_index(wid, sid, lane);
                    check(held_result.data[lane] == expected[lane],
                          "backpressured POP address mismatch");
                    if (expected_q[stream][thread_id].size() != 0)
                        void'(expected_q[stream][thread_id].pop_front());
                end
            end
            check(held_result.wb && held_result.rd == 5'd11,
                  "backpressured POP lost writeback metadata");

            commit_if[0].ready = 1'b1;
            @(posedge clk);
            @(negedge clk);
            #1;
            check(commit_handshakes == handshakes_before + 1,
                  "backpressured POP did not commit exactly once");
            check(!commit_if[0].valid,
                  "backpressured POP response remained valid after commit");
        end
    endtask

    task automatic init_uniform_descriptor(
        output lane_values_t base,
        output lane_values_t stride0,
        output lane_values_t stride1,
        output lane_values_t stride2,
        output lane_values_t bound0,
        output lane_values_t bound1,
        output lane_values_t bound2,
        input logic [63:0] base_start,
        input logic [63:0] base_step,
        input logic [63:0] s0,
        input logic [63:0] s1,
        input logic [63:0] s2,
        input int b0,
        input int b1,
        input int b2
    );
        begin
            for (int lane = 0; lane < `SIMD_WIDTH; ++lane) begin
                base[lane] = base_start + lane * base_step;
                stride0[lane] = s0;
                stride1[lane] = s1;
                stride2[lane] = s2;
                bound0[lane] = b0;
                bound1[lane] = b1;
                bound2[lane] = b2;
            end
        end
    endtask

    task automatic test_traversals;
        lane_values_t base, s0, s1, s2, b0, b1, b2;
        integer stalls;
        begin
            $display("TEST: 1D/2D/3D traversal and exact carry order");
            reset_all_streams();

            init_uniform_descriptor(base, s0, s1, s2, b0, b1, b2,
                                    64'h1000, 64'h100, 64'd6, 64'd0, 64'd0,
                                    3, 1, 1);
            program_descriptor(STREAM_LD0, 0, 0, '1,
                               base, s0, s1, s2, b0, b1, b2);
            repeat (3)
                pop_and_check(STREAM_LD0, 0, 0, '1, 1'b0, 1'b0, stalls);

            init_uniform_descriptor(base, s0, s1, s2, b0, b1, b2,
                                    64'h4000, 64'h80, 64'd4, 64'h20, 64'd0,
                                    2, 3, 1);
            program_descriptor(STREAM_LD1, 0, 1, lane_mask_t'(4'b0011),
                               base, s0, s1, s2, b0, b1, b2);
            repeat (6)
                pop_and_check(STREAM_LD1, 0, 1, lane_mask_t'(4'b0011),
                              1'b0, 1'b0, stalls);

            init_uniform_descriptor(base, s0, s1, s2, b0, b1, b2,
                                    64'h8000, 64'h40, 64'd1, 64'h10, 64'h100,
                                    2, 2, 2);
            program_descriptor(STREAM_ST, 1, 0, lane_mask_t'(4'b0101),
                               base, s0, s1, s2, b0, b1, b2);
            repeat (8)
                pop_and_check(STREAM_ST, 1, 0, lane_mask_t'(4'b0101),
                              1'b0, 1'b0, stalls);
        end
    endtask

    task automatic test_bounds_and_reset_lifecycle;
        lane_values_t base, s0, s1, s2, b0, b1, b2;
        lane_values_t zeros;
        integer stalls;
        int thread_id;
        begin
            $display("TEST: zero/one bounds and RESET lifecycle/shadow semantics");
            reset_all_streams();
            zeros = '0;
            thread_id = thread_index(0, 0, 0);

            for (int zero_dim = 0; zero_dim < NUM_DIMS; ++zero_dim) begin
                init_uniform_descriptor(base, s0, s1, s2, b0, b1, b2,
                                        64'h2000 + zero_dim * 64'h100,
                                        64'd0, 64'd2, 64'd8, 64'd32, 1, 1, 1);
                unique case (zero_dim)
                    0: b0[0] = 0;
                    1: b1[0] = 0;
                    2: b2[0] = 0;
                endcase
                program_descriptor(STREAM_LD0, 0, 0, lane_mask_t'(1),
                                   base, s0, s1, s2, b0, b1, b2);
                repeat (8) @(posedge clk);
                check(dut.queue_count[STREAM_LD0][thread_id] == 0,
                      $sformatf("zero bound dim%0d generated an address", zero_dim));
                send_reset(STREAM_LD0, 0, 0, lane_mask_t'(1));
            end

            init_uniform_descriptor(base, s0, s1, s2, b0, b1, b2,
                                    64'h3000, 64'd0, 64'd7, 64'd11, 64'd13,
                                    1, 1, 1);
            program_descriptor(STREAM_LD0, 0, 0, lane_mask_t'(1),
                               base, s0, s1, s2, b0, b1, b2);
            pop_and_check(STREAM_LD0, 0, 0, lane_mask_t'(1),
                          1'b0, 1'b0, stalls);

            // CONFIGURED -> RESET -> START proves RESET preserves shadow.
            init_uniform_descriptor(base, s0, s1, s2, b0, b1, b2,
                                    64'h3400, 64'd0, 64'd9, 64'd0, 64'd0,
                                    2, 1, 1);
            configure_descriptor(STREAM_LD0, 0, 0, lane_mask_t'(1),
                                 base, s0, s1, s2, b0, b1, b2);
            send_reset(STREAM_LD0, 0, 0, lane_mask_t'(1));
            start_descriptor(STREAM_LD0, 0, 0, lane_mask_t'(1));
            repeat (2)
                pop_and_check(STREAM_LD0, 0, 0, lane_mask_t'(1),
                              1'b0, 1'b0, stalls);

            // RUNNING reset flushes work; restarting reuses the shadow descriptor.
            init_uniform_descriptor(base, s0, s1, s2, b0, b1, b2,
                                    64'h3800, 64'd0, 64'd4, 64'd0, 64'd0,
                                    8, 1, 1);
            program_descriptor(STREAM_LD0, 0, 0, lane_mask_t'(1),
                               base, s0, s1, s2, b0, b1, b2);
            wait_queue_count(STREAM_LD0, thread_id, QUEUE_DEPTH, 40);
            send_reset(STREAM_LD0, 0, 0, lane_mask_t'(1));
            check(dut.queue_count[STREAM_LD0][thread_id] == 0,
                  "RUNNING reset did not flush queue");
            start_descriptor(STREAM_LD0, 0, 0, lane_mask_t'(1));
            repeat (8)
                pop_and_check(STREAM_LD0, 0, 0, lane_mask_t'(1),
                              1'b0, 1'b0, stalls);

            // DRAINING reset: producer is exhausted while one entry remains queued.
            init_uniform_descriptor(base, s0, s1, s2, b0, b1, b2,
                                    64'h3c00, 64'd0, 64'd4, 64'd0, 64'd0,
                                    1, 1, 1);
            program_descriptor(STREAM_LD0, 0, 0, lane_mask_t'(1),
                               base, s0, s1, s2, b0, b1, b2);
            wait_queue_count(STREAM_LD0, thread_id, 1, 40);
            repeat (4) @(posedge clk);
            send_reset(STREAM_LD0, 0, 0, lane_mask_t'(1));
            check(dut.queue_count[STREAM_LD0][thread_id] == 0,
                  "DRAINING reset did not flush final entry");

            // IDLE reset remains harmless and also preserves the last shadow.
            send_reset(STREAM_LD0, 0, 0, lane_mask_t'(1));
            start_descriptor(STREAM_LD0, 0, 0, lane_mask_t'(1));
            pop_and_check(STREAM_LD0, 0, 0, lane_mask_t'(1),
                          1'b0, 1'b0, stalls);
        end
    endtask

    task automatic test_signed_strides_and_wrap;
        lane_values_t base, s0, s1, s2, b0, b1, b2;
        integer stalls;
        begin
            $display("TEST: zero/negative/large strides and modulo-2^64 wrap");
            reset_all_streams();

            init_uniform_descriptor(base, s0, s1, s2, b0, b1, b2,
                                    64'h10, 64'd0, -64'sd8, 64'd0, 64'd0,
                                    3, 1, 1);
            program_descriptor(STREAM_LD0, 0, 0, lane_mask_t'(1),
                               base, s0, s1, s2, b0, b1, b2);
            repeat (3)
                pop_and_check(STREAM_LD0, 0, 0, lane_mask_t'(1),
                              1'b0, 1'b0, stalls);

            init_uniform_descriptor(base, s0, s1, s2, b0, b1, b2,
                                    64'hffff_ffff_ffff_fff0, 64'd0,
                                    64'h20, 64'd0, 64'd0, 2, 1, 1);
            program_descriptor(STREAM_LD0, 0, 0, lane_mask_t'(1),
                               base, s0, s1, s2, b0, b1, b2);
            repeat (2)
                pop_and_check(STREAM_LD0, 0, 0, lane_mask_t'(1),
                              1'b0, 1'b0, stalls);

            init_uniform_descriptor(base, s0, s1, s2, b0, b1, b2,
                                    64'h5, 64'd0, 64'd0,
                                    64'h7fff_ffff_ffff_ffff,
                                    64'h8000_0000_0000_0000, 2, 2, 2);
            program_descriptor(STREAM_LD1, 1, 1, lane_mask_t'(1),
                               base, s0, s1, s2, b0, b1, b2);
            repeat (8)
                pop_and_check(STREAM_LD1, 1, 1, lane_mask_t'(1),
                              1'b0, 1'b0, stalls);
        end
    endtask

    task automatic test_stream_warp_slice_isolation;
        lane_values_t base, s0, s1, s2, b0, b1, b2;
        integer stalls;
        int fairness_cycles;
        int thread_w0;
        int thread_w1;
        begin
            $display("TEST: concurrent LD0/LD1/ST, two warps, two slices, fairness");
            reset_all_streams();

            init_uniform_descriptor(base, s0, s1, s2, b0, b1, b2,
                                    64'h10000, 64'h100, 64'd4, 64'd0, 64'd0,
                                    8, 1, 1);
            program_descriptor(STREAM_LD0, 0, 0, lane_mask_t'(4'b0011),
                               base, s0, s1, s2, b0, b1, b2);
            for (int lane = 0; lane < `SIMD_WIDTH; ++lane)
                base[lane] += 64'h4000;
            program_descriptor(STREAM_LD0, 1, 0, lane_mask_t'(4'b0011),
                               base, s0, s1, s2, b0, b1, b2);

            init_uniform_descriptor(base, s0, s1, s2, b0, b1, b2,
                                    64'h20000, 64'h100, 64'd8, 64'd0, 64'd0,
                                    6, 1, 1);
            program_descriptor(STREAM_LD1, 0, 1, lane_mask_t'(4'b0101),
                               base, s0, s1, s2, b0, b1, b2);

            init_uniform_descriptor(base, s0, s1, s2, b0, b1, b2,
                                    64'h30000, 64'h100, 64'd16, 64'd0, 64'd0,
                                    6, 1, 1);
            program_descriptor(STREAM_ST, 1, 1, lane_mask_t'(4'b1010),
                               base, s0, s1, s2, b0, b1, b2);

            thread_w0 = thread_index(0, 0, 0);
            thread_w1 = thread_index(1, 0, 0);
            fairness_cycles = 0;
            while (((dut.queue_count[STREAM_LD0][thread_w0] != QUEUE_DEPTH)
                 || (dut.queue_count[STREAM_LD0][thread_w1] != QUEUE_DEPTH))
                && (fairness_cycles < 20)) begin
                @(negedge clk);
                ++fairness_cycles;
            end
            check(fairness_cycles < 20,
                  "round-robin producer did not service both warps within bound");

            repeat (6) begin
                pop_and_check(STREAM_LD1, 0, 1, lane_mask_t'(4'b0101),
                              1'b0, 1'b0, stalls);
                pop_and_check(STREAM_ST, 1, 1, lane_mask_t'(4'b1010),
                              1'b0, 1'b0, stalls);
            end
            repeat (8) begin
                pop_and_check(STREAM_LD0, 0, 0, lane_mask_t'(4'b0011),
                              1'b0, 1'b0, stalls);
                pop_and_check(STREAM_LD0, 1, 0, lane_mask_t'(4'b0011),
                              1'b0, 1'b0, stalls);
            end
        end
    endtask

    task automatic test_queue_and_commit_handshakes;
        lane_values_t base, s0, s1, s2, b0, b1, b2;
        integer stalls;
        int thread_id;
        begin
            $display("TEST: blocked wakeup, enqueue+pop, full+pop, commit backpressure");
            reset_all_streams();
            thread_id = thread_index(0, 0, 0);

            // Chaining POP at the START response boundary observes an empty queue,
            // then wakes when the producer creates the first entry.
            init_uniform_descriptor(base, s0, s1, s2, b0, b1, b2,
                                    64'h40000, 64'd0, 64'd4, 64'd0, 64'd0,
                                    4, 1, 1);
            program_descriptor(STREAM_LD0, 0, 0, lane_mask_t'(1),
                               base, s0, s1, s2, b0, b1, b2);
            pop_and_check(STREAM_LD0, 0, 0, lane_mask_t'(1),
                          1'b1, 1'b1, stalls);
            check(dut.queue_count[STREAM_LD0][thread_id] == 0,
                  "blocked POP did not consume exactly one produced entry");

            // Align a pending POP with the next producer visit to this slice.
            wait_queue_count(STREAM_LD0, thread_id, 1, 40);
            repeat (TOTAL_SLICES - 1) @(posedge clk);
            @(negedge clk);
            pop_and_check(STREAM_LD0, 0, 0, lane_mask_t'(1),
                          1'b1, 1'b0, stalls);
            check(dut.queue_count[STREAM_LD0][thread_id] == 1,
                  "enqueue+pop did not preserve occupancy");
            repeat (2)
                pop_and_check(STREAM_LD0, 0, 0, lane_mask_t'(1),
                              1'b0, 1'b0, stalls);

            // A full queue plus POP must replace the consumed entry in one cycle.
            init_uniform_descriptor(base, s0, s1, s2, b0, b1, b2,
                                    64'h44000, 64'd0, 64'd8, 64'd0, 64'd0,
                                    8, 1, 1);
            program_descriptor(STREAM_LD1, 0, 0, lane_mask_t'(1),
                               base, s0, s1, s2, b0, b1, b2);
            wait_queue_count(STREAM_LD1, thread_id, QUEUE_DEPTH, 40);
            repeat (TOTAL_SLICES - 1) @(posedge clk);
            @(negedge clk);
            pop_and_check(STREAM_LD1, 0, 0, lane_mask_t'(1),
                          1'b1, 1'b0, stalls);
            check(dut.queue_count[STREAM_LD1][thread_id] == QUEUE_DEPTH,
                  "full-plus-pop did not preserve full occupancy");
            repeat (7)
                pop_and_check(STREAM_LD1, 0, 0, lane_mask_t'(1),
                              1'b0, 1'b0, stalls);

            init_uniform_descriptor(base, s0, s1, s2, b0, b1, b2,
                                    64'h48000, 64'd0, 64'd16, 64'd0, 64'd0,
                                    2, 1, 1);
            program_descriptor(STREAM_ST, 0, 0, lane_mask_t'(1),
                               base, s0, s1, s2, b0, b1, b2);
            wait_queue_count(STREAM_ST, thread_id, 2, 40);
            check_backpressured_pop(STREAM_ST, 0, 0, lane_mask_t'(1));
            pop_and_check(STREAM_ST, 0, 0, lane_mask_t'(1),
                          1'b0, 1'b0, stalls);
        end
    endtask

    task automatic test_random_descriptors(input int iterations);
        lane_values_t base, s0, s1, s2, b0, b1, b2;
        lane_mask_t tmask;
        integer stalls;
        int stream;
        int wid;
        int sid;
        int bound_v0;
        int bound_v1;
        int bound_v2;
        int pop_count;
        int thread_id;
        begin
            $display("TEST: randomized legal descriptors iterations=%0d", iterations);
            reset_all_streams();
            for (int iteration = 0; iteration < iterations; ++iteration) begin
                stream = $urandom_range(NUM_STREAMS - 1, 0);
                wid = $urandom_range(`NUM_WARPS - 1, 0);
                sid = $urandom_range(NUM_SLICES - 1, 0);
                tmask = $urandom;
                if (tmask == '0)
                    tmask[0] = 1'b1;

                bound_v0 = $urandom_range(3, 0);
                bound_v1 = $urandom_range(3, 0);
                bound_v2 = $urandom_range(3, 0);
                for (int lane = 0; lane < `SIMD_WIDTH; ++lane) begin
                    base[lane] = {$urandom, $urandom};
                    s0[lane] = random_stride($urandom_range(8, 0));
                    s1[lane] = random_stride($urandom_range(8, 0));
                    s2[lane] = random_stride($urandom_range(8, 0));
                    b0[lane] = bound_v0;
                    b1[lane] = bound_v1;
                    b2[lane] = bound_v2;
                end

                program_descriptor(stream, wid, sid, tmask,
                                   base, s0, s1, s2, b0, b1, b2);
                pop_count = bound_v0 * bound_v1 * bound_v2;
                if (pop_count == 0) begin
                    repeat (6) @(posedge clk);
                    for (int lane = 0; lane < `SIMD_WIDTH; ++lane) begin
                        if (tmask[lane]) begin
                            thread_id = thread_index(wid, sid, lane);
                            check(dut.queue_count[stream][thread_id] == 0,
                                  $sformatf("random zero-bound descriptor produced data iter=%0d",
                                            iteration));
                        end
                    end
                    send_reset(stream, wid, sid, tmask);
                end else begin
                    repeat (pop_count)
                        pop_and_check(stream, wid, sid, tmask,
                                      1'b0, 1'b0, stalls);
                end
            end
        end
    endtask

    task automatic test_target_shape_smoke;
        lane_values_t base, s0, s1, s2, b0, b1, b2;
        integer stalls;
        begin
            $display("TEST: single-slice target-shape smoke for LD0/LD1/ST");
            reset_all_streams();
            for (int stream = 0; stream < NUM_STREAMS; ++stream) begin
                init_uniform_descriptor(base, s0, s1, s2, b0, b1, b2,
                                        64'h60000 + stream * 64'h10000,
                                        64'h100, 64'd8 + stream * 64'd8,
                                        64'd0, 64'd0, 2, 1, 1);
                program_descriptor(stream, 0, 0, '1,
                                   base, s0, s1, s2, b0, b1, b2);
            end
            repeat (2) begin
                pop_and_check(STREAM_LD0, 0, 0, '1, 1'b0, 1'b0, stalls);
                pop_and_check(STREAM_LD1, 0, 0, '1, 1'b0, 1'b0, stalls);
                pop_and_check(STREAM_ST, 0, 0, '1, 1'b0, 1'b0, stalls);
            end
        end
    endtask

    task automatic test_overpop_diagnostic;
        lane_values_t base, s0, s1, s2, b0, b1, b2;
        lane_values_t zeros;
        integer stalls;
        begin
            $display("TEST: expecting prolonged empty-POP RTL diagnostic");
            reset_all_streams();
            init_uniform_descriptor(base, s0, s1, s2, b0, b1, b2,
                                    64'h50000, 64'd0, 64'd4, 64'd0, 64'd0,
                                    1, 1, 1);
            program_descriptor(STREAM_LD0, 0, 0, lane_mask_t'(1),
                               base, s0, s1, s2, b0, b1, b2);
            pop_and_check(STREAM_LD0, 0, 0, lane_mask_t'(1),
                          1'b0, 1'b0, stalls);
            zeros = '0;
            @(negedge clk);
            dispatch_if[0].data = '0;
            dispatch_if[0].data.wis = wid_to_wis(NW_WIDTH'(0));
            dispatch_if[0].data.sid = '0;
            dispatch_if[0].data.tmask = lane_mask_t'(1);
            dispatch_if[0].data.op_type = OP_POP;
            dispatch_if[0].data.op_args.agen.stream = STREAM_LD0;
            dispatch_if[0].data.wb = 1'b1;
            dispatch_if[0].data.rd = NUM_REGS_BITS'(7);
            dispatch_if[0].data.rs1_data = zeros;
            dispatch_if[0].data.rs2_data = zeros;
            dispatch_if[0].data.sop = 1'b1;
            dispatch_if[0].data.eop = 1'b1;
            dispatch_if[0].valid = 1'b1;
            repeat (TB_POP_STALL_TIMEOUT + 3) @(posedge clk);
            @(negedge clk);
            #1;
            check(!dispatch_if[0].ready,
                  "over-popped descriptor unexpectedly accepted POP");
            check(dut.pop_stall_cycles[0] >= TB_POP_STALL_TIMEOUT,
                  "empty-POP diagnostic threshold was not reached");
            dispatch_if[0].valid = 1'b0;
            $display("EXPECTED DIAGNOSTIC PASSED: empty POP timeout observed");
        end
    endtask

    initial begin : watchdog
        int max_cycles;
        max_cycles = 30000;
        void'($value$plusargs("MAX_CYCLES=%d", max_cycles));
        repeat (max_cycles) @(posedge clk);
        $fatal(1, "VX_agen_unit testbench watchdog expired after %0d cycles",
               max_cycles);
    end

    initial begin : main_test
        string test_name;
        int random_iterations;

        clk = 1'b0;
        reset = 1'b1;
        errors = 0;
        commit_handshakes = 0;
        test_name = "all";
        random_iterations = 12;
        void'($value$plusargs("TEST=%s", test_name));
        void'($value$plusargs("RANDOM_ITERS=%d", random_iterations));

        check(`NUM_WARPS >= 2, "test requires NUM_WARPS >= 2");
        if (test_name != "smoke") begin
            check(`NUM_THREADS >= (2 * `SIMD_WIDTH),
                  "test requires at least two SIMD slices per warp");
        end
        check((`NUM_THREADS % `SIMD_WIDTH) == 0,
              "NUM_THREADS must be divisible by SIMD_WIDTH");
        check(`ISSUE_WIDTH == 1,
              "focused address-generator test currently requires ISSUE_WIDTH=1");

        dispatch_if[0].valid = 1'b0;
        dispatch_if[0].data = '0;
        commit_if[0].ready = 1'b1;
        for (int stream = 0; stream < NUM_STREAMS; ++stream) begin
            for (int thread_id = 0; thread_id < TOTAL_THREADS; ++thread_id) begin
                shadow_base[stream][thread_id] = '0;
                for (int dim = 0; dim < NUM_DIMS; ++dim) begin
                    shadow_stride[stream][thread_id][dim] = '0;
                    shadow_bound[stream][thread_id][dim] = '0;
                end
                expected_q[stream][thread_id].delete();
            end
        end

        repeat (4) @(posedge clk);
        @(negedge clk);
        reset = 1'b0;

        if ((test_name == "all") || (test_name == "directed")) begin
            test_traversals();
            test_bounds_and_reset_lifecycle();
            test_signed_strides_and_wrap();
            test_stream_warp_slice_isolation();
            test_queue_and_commit_handshakes();
        end
        if ((test_name == "all") || (test_name == "random"))
            test_random_descriptors(random_iterations);
        if (test_name == "smoke")
            test_target_shape_smoke();
        if (test_name == "overpop")
            test_overpop_diagnostic();

        if (errors == 0) begin
            $display("OUTPUT CHECK PASSED: VX_agen_unit test=%s", test_name);
            $finish;
        end else begin
            $fatal(1, "VX_agen_unit test=%s errors=%0d", test_name, errors);
        end
    end

endmodule
