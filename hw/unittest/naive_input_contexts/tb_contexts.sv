`include "VX_define.vh"
module tb_contexts import VX_gpu_pkg::*; ();
    logic clk = 0;
    always #5 clk = ~clk;
    logic reset = 1, cmd_valid = 0;
    wire cmd_ready;
    logic [31:0] cmd_work_seq = 0, cmd_output_target = 0;
    logic cmd_terminal = 0, cmd_final_output = 0;
    logic [31:0] output_release_value = 0;
    logic input_valid = 0, input_ready = 1;
    wire input_ready_out, ingress_complete;
    wire [31:0] ingress_work_seq;
    gemm_input_ctrl_t packet_ctrl;
    logic terminal_fence_valid = 0;
    logic [31:0] terminal_fence_work_seq = 0;
    wire terminal_wait_valid, done_valid, done_terminal, quiescent;
    wire [31:0] terminal_wait_work_seq, done_work_seq;
    logic done_ready = 0;
    wire [2:0] occupancy;
    wire [`MEM_ADDR_WIDTH-1:0] final_base = `MEM_ADDR_WIDTH'(64'h1_0000_1000)
        + `MEM_ADDR_WIDTH'(cmd_work_seq * 256);
    VX_naive_input_contexts dut (
        .clk(clk), .reset(reset), .cmd_valid(cmd_valid), .cmd_ready(cmd_ready),
        .cmd_packet_count(21'd2),
        .cmd_acc_rd_base(`MEM_ADDR_WIDTH'(64'h1_0000_2000)),
        .cmd_acc_rd_stride(`MEM_ADDR_WIDTH'(64)),
        .cmd_acc_wr_base(`MEM_ADDR_WIDTH'(64'h1_0000_3000)),
        .cmd_acc_wr_stride(`MEM_ADDR_WIDTH'(64)),
        .cmd_final_wr_base(final_base), .cmd_final_wr_stride(`MEM_ADDR_WIDTH'(64)),
        .cmd_acc_rd_en(1'b1), .cmd_acc_wr_en(1'b1),
        .cmd_final_output(cmd_final_output), .cmd_quant_dir(1'b1),
        .cmd_wreg_use_idx(cmd_work_seq[0]), .cmd_sreg_use_idx(cmd_work_seq[0]),
        .cmd_zreg_use_idx(cmd_work_seq[0]),
        .cmd_w_load_target(cmd_work_seq + 32'd1),
        .cmd_s_load_target(cmd_work_seq + 32'd1),
        .cmd_z_load_target(cmd_work_seq + 32'd1),
        .cmd_work_seq(cmd_work_seq), .cmd_output_target(cmd_output_target),
        .cmd_terminal(cmd_terminal), .cmd_source_buffer(cmd_work_seq[0]),
        .cmd_source_generation(32'd1), .output_release_value(output_release_value),
        .input_valid(input_valid), .input_ready(input_ready), .input_ready_out(input_ready_out),
        .packet_ctrl(packet_ctrl), .ingress_complete(ingress_complete),
        .ingress_work_seq(ingress_work_seq), .terminal_fence_valid(terminal_fence_valid),
        .terminal_fence_work_seq(terminal_fence_work_seq),
        .terminal_wait_valid(terminal_wait_valid), .terminal_wait_work_seq(terminal_wait_work_seq),
        .done_valid(done_valid), .done_ready(done_ready), .done_work_seq(done_work_seq),
        .done_terminal(done_terminal), .occupancy(occupancy), .quiescent(quiescent)
    );
    int completed = 0;
    int packets = 0;
    always @(posedge clk) begin
        if (!reset && done_valid && done_ready) begin
            assert (done_work_seq == 32'(completed)) else $fatal(1, "Completion owner/order mismatch");
            completed++;
        end
        if (!reset && input_valid && input_ready_out)
            packets++;
    end
    task automatic tick;
        @(posedge clk); #1;
    endtask
    task automatic push(input int id, input bit terminal_cmd, input int output_target);
        cmd_work_seq = 32'(id);
        cmd_terminal = terminal_cmd;
        cmd_final_output = terminal_cmd;
        cmd_output_target = 32'(output_target);
        cmd_valid = 1;
        do begin @(posedge clk); end while (!cmd_ready);
        #1; cmd_valid = 0;
    endtask
    task automatic feed(input int id);
        input_valid = 1;
        for (int row = 0; row < 2; ++row) begin
            #1;
            assert (input_ready_out && packet_ctrl.valid && packet_ctrl.work_seq == 32'(id))
                else $fatal(1, "Admission blocked or wrong context id=%0d row=%0d", id, row);
            assert (packet_ctrl.acc_rd_addr == `MEM_ADDR_WIDTH'(64'h1_0000_2000 + row*64))
                else $fatal(1, "Full-width PSUM address lost");
            assert (packet_ctrl.acc_wr_addr == (id == 1
                ? `MEM_ADDR_WIDTH'(64'h1_0000_1000 + id*256 + row*64)
                : `MEM_ADDR_WIDTH'(64'h1_0000_3000 + row*64)))
                else $fatal(1, "Full-width output address lost");
            assert (packet_ctrl.notify_on_writeback == (row == 1)
                && packet_ctrl.last == (id == 1)
                && packet_ctrl.w_load_target == 32'(id+1)
                && packet_ctrl.s_load_target == 32'(id+1)
                && packet_ctrl.z_load_target == 32'(id+1))
                else $fatal(1, "Packet metadata mismatch");
            if (row == 0) begin
                input_ready = 0;
                repeat (3) begin
                    tick();
                    assert (packet_ctrl.work_seq == 32'(id) && !input_ready_out)
                        else $fatal(1, "Backpressure moved admission");
                end
                input_ready = 1;
            end
            tick();
        end
        input_valid = 0;
    endtask
    initial begin
        assert ($bits(dut.contexts) + $bits(dut.admission_ptr) + $bits(dut.retirement_ptr)
            + $bits(dut.tail_ptr) + $bits(dut.count) == 1805)
            else $fatal(1, "Context control allocation mismatch");
        repeat (3) tick();
        reset = 0;
        push(0, 0, 0); push(1, 1, 0); push(2, 0, 1); push(3, 0, 1);
        assert (occupancy == 4 && !cmd_ready) else $fatal(1, "Full queue not bounded");
        feed(0);
        assert (done_valid && done_work_seq == 0) else $fatal(1, "Ordinary ingress not registered for completion");
        feed(1); // Next input flows despite previous completion backpressure.
        assert (occupancy == 4 && completed == 0) else $fatal(1, "Unexpected retirement");
        input_valid = 1;
        repeat (3) begin
            tick();
            assert (!packet_ctrl.valid && !input_ready_out) else $fatal(1, "O owner fence bypassed");
        end
        input_valid = 0;
        done_ready = 1;
        push(4, 0, 1); // Full queue retire/enqueue recycles the same slot.
        done_ready = 0;
        assert (occupancy == 4 && completed == 1 && terminal_wait_valid)
            else $fatal(1, "Full queue recycle or terminal owner failed");
        terminal_fence_valid = 1;
        terminal_fence_work_seq = 99;
        tick();
        assert (!done_valid) else $fatal(1, "Unrelated terminal fence accepted");
        terminal_fence_work_seq = 1;
        repeat (3) begin
            tick();
            assert (done_valid && done_work_seq == 1 && done_terminal)
                else $fatal(1, "Terminal completion not retained");
        end
        done_ready = 1;
        tick(); terminal_fence_valid = 0;
        output_release_value = 1;
        feed(2); feed(3); feed(4); tick();
        assert (quiescent && completed == 5) else $fatal(1, "First job did not drain");
        for (int job = 5; job < 8; ++job) begin
            push(job, 0, 1); feed(job); tick();
            assert (quiescent && completed == job+1) else $fatal(1, "No-reset context reuse failed");
        end
        assert (packets == 16) else $fatal(1, "Packet lost or duplicated");
        $display("TEST PASSED naive context overlap, full recycle, owned fence, O wait, full addresses, no-reset reuse");
        $finish;
    end
    initial begin
        #100000;
        $fatal(1, "Context test timeout");
    end
endmodule
