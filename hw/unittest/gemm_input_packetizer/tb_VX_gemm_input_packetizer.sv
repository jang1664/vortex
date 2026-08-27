`timescale 1ns / 1ps
`include "VX_define.vh"

module tb_VX_gemm_input_packetizer;
    import VX_gpu_pkg::*;

    localparam int PERIOD = 10;
    localparam int CONTEXT_DEPTH = 4;
    localparam int PACKET_COUNT_W = `GEMM_ACC_MAX_CNT;
    localparam logic [PACKET_COUNT_W-1:0] MAX_PACKET_COUNT = '1;

    logic clk, reset;
    logic cmd_valid, cmd_ready;
    logic [PACKET_COUNT_W-1:0] cmd_packet_count;
    logic [`MEM_ADDR_WIDTH-1:0] rd_base, rd_stride;
    logic [`MEM_ADDR_WIDTH-1:0] wr_base, wr_stride;
    logic [`MEM_ADDR_WIDTH-1:0] final_base, final_stride;
    logic cmd_acc_rd_en, cmd_acc_wr_en, cmd_final_output;
    logic cmd_quant_dir;
    gemm_wreg_idx_t cmd_wreg_use_idx;
    gemm_qreg_idx_t cmd_sreg_use_idx, cmd_zreg_use_idx;
    logic [31:0] cmd_w_load_target, cmd_s_load_target;
    logic [31:0] cmd_z_load_target, cmd_work_seq;
    logic input_valid, input_ready, input_ready_out;
    gemm_input_ctrl_t packet_ctrl;
    logic ingress_complete, completion_valid, command_done;
    logic command_active;
    logic [31:0] active_work_seq;

    typedef struct packed {
        logic [PACKET_COUNT_W-1:0] packet_count;
        logic [`MEM_ADDR_WIDTH-1:0] rd_base;
        logic [`MEM_ADDR_WIDTH-1:0] rd_stride;
        logic [`MEM_ADDR_WIDTH-1:0] wr_base;
        logic [`MEM_ADDR_WIDTH-1:0] wr_stride;
        logic [`MEM_ADDR_WIDTH-1:0] final_base;
        logic [`MEM_ADDR_WIDTH-1:0] final_stride;
        logic rd_en;
        logic wr_en;
        logic final_output;
        logic quant_dir;
        gemm_wreg_idx_t wreg_idx;
        gemm_qreg_idx_t sreg_idx;
        gemm_qreg_idx_t zreg_idx;
        logic [31:0] w_target;
        logic [31:0] s_target;
        logic [31:0] z_target;
        logic [31:0] work_seq;
    } command_t;

    typedef struct packed {
        command_t cmd;
        logic [PACKET_COUNT_W-1:0] accepted;
        logic ingress_done;
    } expected_context_t;

    expected_context_t expected_q[$];
    gemm_input_ctrl_t held_ctrl;
    logic held_ctrl_valid;
    integer commands_accepted;
    integer packets_accepted;
    integer ingress_completions;
    integer destination_completions;
    integer stalled_valid_cycles;
    integer max_contexts;
    integer reset_flush_contexts;
    integer random_seed;

    VX_gemm_input_packetizer #(
        .INSTANCE_ID("packetizer_tb"),
        .CONTEXT_DEPTH(CONTEXT_DEPTH)
    ) dut (
        .clk, .reset, .cmd_valid, .cmd_ready, .cmd_packet_count,
        .cmd_acc_rd_base(rd_base), .cmd_acc_rd_stride(rd_stride),
        .cmd_acc_wr_base(wr_base), .cmd_acc_wr_stride(wr_stride),
        .cmd_final_wr_base(final_base),
        .cmd_final_wr_stride(final_stride),
        .cmd_acc_rd_en, .cmd_acc_wr_en, .cmd_final_output,
        .cmd_quant_dir, .cmd_wreg_use_idx, .cmd_sreg_use_idx,
        .cmd_zreg_use_idx, .cmd_w_load_target, .cmd_s_load_target,
        .cmd_z_load_target, .cmd_work_seq, .input_valid, .input_ready,
        .input_ready_out, .packet_ctrl, .ingress_complete,
        .completion_valid, .command_done, .command_active,
        .active_work_seq
    );

    initial clk = 1'b0;
    always #(PERIOD / 2) clk = ~clk;

    function automatic command_t make_command(
        input logic [PACKET_COUNT_W-1:0] packet_count,
        input logic [31:0] work_seq,
        input logic final_output,
        input logic quant_dir
    );
        command_t value;
        begin
            value = '0;
            value.packet_count = packet_count;
            value.rd_base = `MEM_ADDR_WIDTH'(34'h10000 + work_seq * 64);
            value.rd_stride = `MEM_ADDR_WIDTH'(128 + work_seq[2:0] * 16);
            value.wr_base = `MEM_ADDR_WIDTH'(34'h40000 + work_seq * 128);
            value.wr_stride = `MEM_ADDR_WIDTH'(256 + work_seq[1:0] * 32);
            value.final_base = `MEM_ADDR_WIDTH'(34'h180000 + work_seq * 512);
            value.final_stride = `MEM_ADDR_WIDTH'(512 + work_seq[2:0] * 64);
            value.rd_en = work_seq[0];
            value.wr_en = 1'b1;
            value.final_output = final_output;
            value.quant_dir = quant_dir;
            value.wreg_idx = gemm_wreg_idx_t'(work_seq[0]);
            value.sreg_idx = gemm_qreg_idx_t'(work_seq[1]);
            value.zreg_idx = gemm_qreg_idx_t'(work_seq[2]);
            value.w_target = 32'h1000_0000 + work_seq;
            value.s_target = 32'h2000_0000 + work_seq;
            value.z_target = 32'h3000_0000 + work_seq;
            value.work_seq = work_seq;
            return value;
        end
    endfunction

    task automatic drive_command(input command_t value);
        expected_context_t expected;
        integer wait_cycles;
        begin
            @(negedge clk);
            cmd_packet_count = value.packet_count;
            rd_base = value.rd_base;
            rd_stride = value.rd_stride;
            wr_base = value.wr_base;
            wr_stride = value.wr_stride;
            final_base = value.final_base;
            final_stride = value.final_stride;
            cmd_acc_rd_en = value.rd_en;
            cmd_acc_wr_en = value.wr_en;
            cmd_final_output = value.final_output;
            cmd_quant_dir = value.quant_dir;
            cmd_wreg_use_idx = value.wreg_idx;
            cmd_sreg_use_idx = value.sreg_idx;
            cmd_zreg_use_idx = value.zreg_idx;
            cmd_w_load_target = value.w_target;
            cmd_s_load_target = value.s_target;
            cmd_z_load_target = value.z_target;
            cmd_work_seq = value.work_seq;
            cmd_valid = 1'b1;

            wait_cycles = 0;
            while (!cmd_ready) begin
                @(posedge clk);
                assert (!cmd_ready)
                    else $fatal(1, "command ready changed before observed edge");
                @(negedge clk);
                assert (cmd_packet_count == value.packet_count
                     && rd_base == value.rd_base
                     && final_base == value.final_base
                     && cmd_work_seq == value.work_seq)
                    else $fatal(1, "command payload changed while FIFO full");
                wait_cycles = wait_cycles + 1;
                assert (wait_cycles < 10000)
                    else $fatal(1, "timed out waiting for packetizer FIFO space");
            end

            @(posedge clk);
            assert (cmd_valid && cmd_ready)
                else $fatal(1, "command did not fire when ready");
            @(negedge clk);
            expected = '0;
            expected.cmd = value;
            expected_q.push_back(expected);
            if (expected_q.size() > max_contexts)
                max_contexts = expected_q.size();
            cmd_valid = 1'b0;
        end
    endtask

    task automatic drive_head_packets(input bit randomized);
        integer local_fires;
        integer cycles;
        integer required;
        begin
            assert (expected_q.size() != 0)
                else $fatal(1, "packet drive requested with empty scoreboard");
            required = expected_q[0].cmd.packet_count;
            local_fires = 0;
            cycles = 0;
            @(negedge clk);
            input_valid = 1'b1;
            while (local_fires < required) begin
                if (randomized) begin
                    input_ready = ($urandom_range(0, 3) != 0);
                    // Once the source presents valid, it must retain valid
                    // and payload until the packet handshakes.  Randomize the
                    // downstream admission stall, not protocol ownership.
                    input_valid = 1'b1;
                end else begin
                    input_valid = 1'b1;
                    input_ready = (cycles[1:0] != 2'b01);
                end
                @(posedge clk);
                if (input_valid && input_ready_out)
                    local_fires = local_fires + 1;
                @(negedge clk);
                cycles = cycles + 1;
                assert (cycles < (required * 16 + 128))
                    else $fatal(1, "timed out draining command packets");
            end
            input_valid = 1'b0;
            input_ready = 1'b0;
            assert (expected_q[0].ingress_done)
                else $fatal(1, "last Input fire did not complete ingress");
        end
    endtask

    task automatic complete_head(input integer delay_cycles);
        logic [31:0] expected_work_seq;
        begin
            assert (expected_q.size() != 0 && expected_q[0].ingress_done)
                else $fatal(1, "completion requested before ingress completed");
            expected_work_seq = expected_q[0].cmd.work_seq;
            repeat (delay_cycles) begin
                @(posedge clk);
                assert (command_active && !command_done
                     && active_work_seq == expected_work_seq)
                    else $fatal(1, "early completion during destination delay");
            end
            @(negedge clk);
            completion_valid = 1'b1;
            @(posedge clk);
            assert (command_done && active_work_seq == expected_work_seq)
                else $fatal(1, "destination completion did not retire head");
            @(negedge clk);
            completion_valid = 1'b0;
        end
    endtask

    task automatic check_empty;
        begin
            repeat (2) @(posedge clk);
            assert (!command_active && !packet_ctrl.valid
                 && !ingress_complete && !command_done && cmd_ready)
                else $fatal(1, "packetizer not empty after final retirement");
        end
    endtask

    always @(posedge clk) begin : scoreboard
        expected_context_t head;
        logic [`MEM_ADDR_WIDTH-1:0] expected_rd_addr;
        logic [`MEM_ADDR_WIDTH-1:0] expected_wr_addr;
        logic expected_last_packet;
        if (!reset) begin
            if (held_ctrl_valid) begin
                assert (packet_ctrl.valid && packet_ctrl == held_ctrl)
                    else $fatal(1, "TB observed packet metadata change while stalled");
            end
            held_ctrl_valid = packet_ctrl.valid && !input_ready;
            if (held_ctrl_valid) begin
                held_ctrl = packet_ctrl;
                stalled_valid_cycles = stalled_valid_cycles + 1;
            end

            if (expected_q.size() == 0) begin
                assert (!command_active && !packet_ctrl.valid
                     && !input_ready_out && !ingress_complete && !command_done)
                    else $fatal(1, "packetizer asserted output without a context");
            end else begin
                head = expected_q[0];
                assert (command_active && active_work_seq == head.cmd.work_seq)
                    else $fatal(1, "FIFO head ownership/order mismatch");
                assert (packet_ctrl.valid
                        == (!head.ingress_done && input_valid))
                    else $fatal(1, "packet valid did not follow active Input source");
                assert (input_ready_out
                        == (!head.ingress_done && input_ready))
                    else $fatal(1, "Input ready escaped command/ingress gating");

                if (packet_ctrl.valid) begin
                    expected_rd_addr = head.cmd.rd_base
                        + `MEM_ADDR_WIDTH'(head.accepted) * head.cmd.rd_stride;
                    expected_wr_addr = (head.cmd.final_output
                            ? head.cmd.final_base : head.cmd.wr_base)
                        + `MEM_ADDR_WIDTH'(head.accepted)
                        * (head.cmd.final_output
                            ? head.cmd.final_stride : head.cmd.wr_stride);
                    expected_last_packet = (head.accepted + 1'b1
                                           == head.cmd.packet_count);
                    assert (packet_ctrl.acc_rd_en == head.cmd.rd_en
                         && packet_ctrl.acc_wr_en == head.cmd.wr_en
                         && packet_ctrl.acc_rd_addr == expected_rd_addr
                         && packet_ctrl.acc_wr_addr == expected_wr_addr)
                        else $fatal(1, "opaque ACC address/control mismatch");
                    assert (packet_ctrl.quant_dir == head.cmd.quant_dir
                         && packet_ctrl.wreg_use_idx == head.cmd.wreg_idx
                         && packet_ctrl.sreg_use_idx == head.cmd.sreg_idx
                         && packet_ctrl.zreg_use_idx == head.cmd.zreg_idx)
                        else $fatal(1, "QDIR or W/S/Z bank metadata mismatch");
                    assert (packet_ctrl.w_load_target == head.cmd.w_target
                         && packet_ctrl.s_load_target == head.cmd.s_target
                         && packet_ctrl.z_load_target == head.cmd.z_target
                         && packet_ctrl.work_seq == head.cmd.work_seq)
                        else $fatal(1, "generation/work sequence metadata mismatch");
                    assert (packet_ctrl.acc_txn_tag == 0
                         && packet_ctrl.is_load == !head.cmd.rd_en
                         && packet_ctrl.last == head.cmd.final_output
                         && packet_ctrl.notify_on_writeback
                            == expected_last_packet)
                        else $fatal(1, "last/notify/load metadata mismatch");
                end

                assert (command_done == completion_valid)
                    else $fatal(1, "command done did not match destination fire");
                if (completion_valid) begin
                    assert (head.ingress_done)
                        else $fatal(1, "command completed before final Input fire");
                    expected_q.pop_front();
                    destination_completions = destination_completions + 1;
                end

                if (input_valid && input_ready_out) begin
                    expected_last_packet = (head.accepted + 1'b1
                                           == head.cmd.packet_count);
                    assert (ingress_complete == expected_last_packet)
                        else $fatal(1, "ingress completion not aligned to last fire");
                    packets_accepted = packets_accepted + 1;
                    expected_q[0].accepted = head.accepted + 1'b1;
                    if (expected_last_packet) begin
                        expected_q[0].ingress_done = 1'b1;
                        ingress_completions = ingress_completions + 1;
                    end
                end else begin
                    assert (!ingress_complete)
                        else $fatal(1, "ingress completion without Input fire");
                end
            end
        end else begin
            held_ctrl_valid = 1'b0;
        end
    end

    initial begin : stimulus
        command_t c1, c3, cmax, cfill1, cfill2, cfill3, cturn;
        integer flushed;

        random_seed = 32'h51a7_c0de;
        void'($urandom(random_seed));
        commands_accepted = 0;
        packets_accepted = 0;
        ingress_completions = 0;
        destination_completions = 0;
        stalled_valid_cycles = 0;
        max_contexts = 0;
        reset_flush_contexts = 0;
        held_ctrl_valid = 1'b0;
        reset = 1'b1;
        cmd_valid = 1'b0;
        cmd_packet_count = '0;
        rd_base = '0;
        rd_stride = '0;
        wr_base = '0;
        wr_stride = '0;
        final_base = '0;
        final_stride = '0;
        cmd_acc_rd_en = 1'b0;
        cmd_acc_wr_en = 1'b0;
        cmd_final_output = 1'b0;
        cmd_quant_dir = `QDIR_COL;
        cmd_wreg_use_idx = '0;
        cmd_sreg_use_idx = '0;
        cmd_zreg_use_idx = '0;
        cmd_w_load_target = '0;
        cmd_s_load_target = '0;
        cmd_z_load_target = '0;
        cmd_work_seq = '0;
        input_valid = 1'b0;
        input_ready = 1'b0;
        completion_valid = 1'b0;
        expected_q.delete();
        repeat (4) @(posedge clk);
        @(negedge clk);
        reset = 1'b0;
        repeat (2) @(posedge clk);
        assert (cmd_ready && !command_active && !command_done)
            else $fatal(1, "reset did not leave packetizer empty and ready");

        c1 = make_command(PACKET_COUNT_W'(1), 32'h101, 1'b0, `QDIR_COL);
        drive_command(c1);
        commands_accepted = commands_accepted + 1;
        drive_head_packets(1'b0);
        complete_head(4);
        check_empty();

        c3 = make_command(PACKET_COUNT_W'(3), 32'h202, 1'b1, `QDIR_ROW);
        drive_command(c3);
        commands_accepted = commands_accepted + 1;
        drive_head_packets(1'b1);
        complete_head($urandom_range(2, 8));
        check_empty();

        cmax = make_command(MAX_PACKET_COUNT, 32'h301, 1'b0, `QDIR_COL);
        cfill1 = make_command(PACKET_COUNT_W'(1), 32'h302, 1'b1, `QDIR_ROW);
        cfill2 = make_command(PACKET_COUNT_W'(3), 32'h303, 1'b0, `QDIR_COL);
        cfill3 = make_command(PACKET_COUNT_W'(5), 32'h304, 1'b1, `QDIR_ROW);
        cturn = make_command(PACKET_COUNT_W'(2), 32'h305, 1'b0, `QDIR_COL);
        drive_command(cmax);
        commands_accepted = commands_accepted + 1;
        drive_command(cfill1);
        commands_accepted = commands_accepted + 1;
        drive_command(cfill2);
        commands_accepted = commands_accepted + 1;
        drive_command(cfill3);
        commands_accepted = commands_accepted + 1;
        @(posedge clk);
        assert (!cmd_ready && expected_q.size() == CONTEXT_DEPTH)
            else $fatal(1, "context FIFO did not report full");

        fork
            begin
                drive_command(cturn);
                commands_accepted = commands_accepted + 1;
            end
            begin
                drive_head_packets(1'b1);
                complete_head($urandom_range(1, 7));
            end
        join

        drive_head_packets(1'b1);
        complete_head($urandom_range(1, 7));
        drive_head_packets(1'b1);
        complete_head($urandom_range(1, 7));
        drive_head_packets(1'b1);
        complete_head($urandom_range(1, 7));
        drive_head_packets(1'b1);
        complete_head($urandom_range(1, 7));
        check_empty();

        c3 = make_command(PACKET_COUNT_W'(3), 32'h401, 1'b1, `QDIR_ROW);
        cfill1 = make_command(PACKET_COUNT_W'(1), 32'h402, 1'b0, `QDIR_COL);
        drive_command(c3);
        commands_accepted = commands_accepted + 1;
        drive_command(cfill1);
        commands_accepted = commands_accepted + 1;
        @(negedge clk);
        input_valid = 1'b1;
        input_ready = 1'b1;
        @(posedge clk);
        @(negedge clk);
        input_ready = 1'b0;
        flushed = expected_q.size();
        reset_flush_contexts = reset_flush_contexts + flushed;
        reset = 1'b1;
        expected_q.delete();
        #1;
        assert (!command_active && !packet_ctrl.valid && !command_done
             && !ingress_complete && cmd_ready)
            else $fatal(1, "occupied reset did not flush packetizer state");
        repeat (2) @(posedge clk);
        @(negedge clk);
        reset = 1'b0;
        input_valid = 1'b0;
        input_ready = 1'b0;
        repeat (3) @(posedge clk);
        check_empty();

        assert (max_contexts == CONTEXT_DEPTH)
            else $fatal(1, "full context occupancy was not covered");
        assert (stalled_valid_cycles != 0)
            else $fatal(1, "valid-not-ready stability was not covered");
        $display("PACKETIZER_CONFIG context_depth=%0d packet_count_width=%0d max_packet_count=%0d",
                 CONTEXT_DEPTH, PACKET_COUNT_W, MAX_PACKET_COUNT);
        $display("PACKETIZER_COUNTS commands=%0d packets=%0d ingress=%0d completions=%0d max_contexts=%0d stalled_valid=%0d reset_flush=%0d",
                 commands_accepted, packets_accepted, ingress_completions,
                 destination_completions, max_contexts,
                 stalled_valid_cycles, reset_flush_contexts);
        $display("TEST PASSED: packetizer count1/count3/max, FIFO full/turnover, stalls, metadata, delayed completion and occupied reset");
        $finish;
    end
endmodule
