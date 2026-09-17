`include "VX_define.vh"
module tb_fsm import VX_gpu_pkg::*; ();
    logic clk = 0;
    always #5 clk = ~clk;
    logic reset = 1;
    VX_config_reg_if #(.NUM(42), .DW(64)) cfg();
    wire invocation_valid, cmd_valid, producer_done, idle;
    wire [`JOB_MMIO_ENTRYID_W-1:0] entry;
    logic invocation_ready = 0, controller_done = 0;
    wire closed_valid, closed_buffer;
    wire [31:0] closed_generation, closed_count;
    gemm_unified_cmd_t cmd;
    wire [31:0] geometry [9];
    int cycle = 0, m = 4, k = 512, n = 512, qrow = 0, wtrans = 0;
    int input_count = 0, load_count = 0, store_count = 0, close_count = 0;
    wire cmd_ready = cycle % 13 < 6;
    VX_gemm_fsm_naive_meta dut (
        .clk(clk), .reset(reset), .cfg_reg_if(cfg),
        .invocation_valid_o(invocation_valid), .invocation_ready_i(invocation_ready),
        .invocation_entry_id_o(entry), .cmd_valid_o(cmd_valid), .cmd_ready_i(cmd_ready),
        .cmd_o(cmd), .producer_done_o(producer_done), .controller_done_i(controller_done),
        .job_geometry_o(geometry), .idle_o(idle), .source_closed_valid_o(closed_valid), .source_closed_buffer_o(closed_buffer),
        .source_closed_generation_o(closed_generation), .source_closed_count_o(closed_count)
    );
    gemm_unified_cmd_t held;
    logic stalled = 0;
    always @(posedge clk) begin
        cycle <= cycle + 1;
        if (!reset) begin
            if (cmd_valid)
                assert (geometry[3] == 5)
                    else $fatal(1, "DMA QBLK geometry must retain log2 encoding, got %0d", geometry[3]);
            if (stalled)
                assert (cmd_valid && cmd == held) else $fatal(1, "FSM changed held command");
            stalled <= cmd_valid && !cmd_ready;
            held <= cmd;
            if (closed_valid) begin
                assert (cmd_valid && cmd_ready && cmd.instr[3:0] == 7)
                    else $fatal(1, "Closure without accepted Input");
                close_count++;
                $display("CLOSE %0d %0d %0d", closed_buffer, closed_generation, closed_count);
            end
            if (cmd_valid && cmd_ready) begin
                assert (cmd.instr[3:0] inside {1,2,5,6,7,10})
                    else $fatal(1, "Non-real command emitted");
                case (cmd.instr[3:0])
                    1: load_count++;
                    2: store_count++;
                    7: input_count++;
                    default:;
                endcase
                $display("CMD %0d %0d %0d %0d %0d %0h %0h %0h %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d",
                    cmd.instr[3:0], cmd.work_seq, cmd.naive_source_buffer, cmd.naive_source_generation,
                    cmd.instr[31:4], cmd.rs1_data, cmd.rs2_data, cmd.naive_final_base,
                    cmd.naive_final_stride, cmd.stride, cmd.bound, cmd.eff_mt, cmd.groups_eff,
                    cmd.flags, cmd.notify.reg_id, cmd.notify.value, cmd.notify.set_mode,
                    cmd.waits[0].valid, cmd.waits[0].reg_id, cmd.waits[0].target,
                    cmd.input_admit_waits[3].target, cmd.writer_wait.valid, cmd.writer_wait.reg_id,
                    cmd.writer_wait.target, cmd.naive_terminal, cmd.rd);
            end
        end
    end
    task automatic set64(input int index, input logic [63:0] value);
        cfg.regs[index] = {32'd0,value[31:0]};
        cfg.regs[index+1] = {32'd0,value[63:32]};
    endtask
    initial begin : main
        logic [63:0] cursor;
        int expected_inputs, expected_tiles, expected_stores;
        void'($value$plusargs("M=%d",m)); void'($value$plusargs("K=%d",k));
        void'($value$plusargs("N=%d",n)); void'($value$plusargs("QROW=%d",qrow));
        void'($value$plusargs("WTRANS=%d",wtrans));
        assert($bits(dut.knum)==$clog2(`GEMM_FSM_KT/`GEMM_FSM_MXU_KT+1)
            && $bits(dut.nnum)==$clog2(`GEMM_FSM_NT/`GEMM_FSM_MXU_NT+1)
            && $bits(dut.kb_q)==$clog2(`GEMM_FSM_KT/`GEMM_FSM_MXU_KT)
            && $bits(dut.nb_q)==$clog2(`GEMM_FSM_NT/`GEMM_FSM_MXU_NT)
            && $bits(dut.micro_count)==$clog2(
                (`GEMM_FSM_KT/`GEMM_FSM_MXU_KT)*(`GEMM_FSM_NT/`GEMM_FSM_MXU_NT)+1))
            else $fatal(1,"Geometry-derived count/index widths mismatch");
        $display("WIDTH_CHECK knum=%0d nnum=%0d product=%0d kb=%0d nb=%0d",
            $bits(dut.knum),$bits(dut.nnum),$bits(dut.micro_count),$bits(dut.kb_q),$bits(dut.nb_q));
        cfg.regs = '0; cfg.valid = 0; cfg.entry_id = 17;
        repeat (3) @(negedge clk);
        reset = 0;
        for (int resource=0;resource<5;++resource)
            set64(1+2*resource,64'h1_1000_0000+64'(resource)*64'h1000000);
        cursor = 64'h1_0000_0000;
        for (int resource=0;resource<4;++resource)
            for (int bank=0;bank<2;++bank) begin
                set64(11+4*resource+2*bank,cursor);
                cursor += resource==0 ? 32768 : resource==1 ? 8192 : 1024;
            end
        set64(27,cursor); cursor += 32768; set64(40,cursor);
        cfg.regs[29]=64'(m);cfg.regs[30]=64'(n);cfg.regs[31]=64'(k);cfg.regs[32]=5;
        cfg.regs[33]=64'(m);cfg.regs[34]=64'(n);cfg.regs[35]=64'(k);
        cfg.regs[38]=64'(wtrans);cfg.regs[39]=64'(qrow);cfg.regs[0]=1;
        cfg.valid=1;
        repeat (4) begin
            @(negedge clk);
            assert (invocation_valid && !cfg.ready && !cmd_valid)
                else $fatal(1,"Invocation ready backpressure failed");
        end
        invocation_ready=1;
        @(negedge clk); cfg.valid=0;
        wait (producer_done); @(negedge clk);
        expected_inputs=((m+127)/128)*(k/`MXU_ROW)*((n+`MXU_COL-1)/`MXU_COL);
        expected_tiles=((m+127)/128)*((n+127)/128)*((k+127)/128);
        expected_stores=((m+127)/128)*((n+127)/128);
        assert (input_count==expected_inputs && load_count==4*expected_tiles
            && close_count==expected_tiles && store_count==expected_stores)
            else $fatal(1,"FSM command count mismatch I%0d L%0d C%0d O%0d",input_count,load_count,close_count,store_count);
        repeat (5) begin
            @(negedge clk);
            assert (!idle && producer_done && !cmd_valid) else $fatal(1,"Premature invocation release");
        end
        controller_done=1; @(negedge clk); controller_done=0;
        assert (idle) else $fatal(1,"Invocation did not release");
        $display("TEST PASSED metadata FSM m%0d k%0d n%0d qrow%0d wt%0d",m,k,n,qrow,wtrans);
        $finish;
    end
    initial begin #2000000; $fatal(1,"FSM timeout"); end
endmodule
