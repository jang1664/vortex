`include "VX_define.vh"
module tb_control import VX_gpu_pkg::*; ();
    logic clk = 0;
    always #5 clk = ~clk;
    logic reset = 1;
    VX_config_reg_if #(.NUM(42), .DW(64)) cfg();
    VX_gemm_ctrl_naive_meta_if child();
    wire done_valid, idle;
    logic done_ready=0;
    wire [`JOB_MMIO_ENTRYID_W-1:0] entry;
    logic [4:0] busy='0;
    int remaining[5]='{default:0};
    gemm_unified_cmd_t owned[5];
    logic [5:0] consume_valid;
    wire [3:0] source_read_done_valid;
    wire [31:0] source_read_done_work_seq[4];
    int cycle=0,m=4,k=512,n=512,qrow=0,wtrans=0;
    int delivery_delay=5, store_delay=0;
    int cfg_edge=-1, last_store_edge=-1, valid_edge=-1, handshake_edge=-1;
    int actual_stores=0;
    wire store_retired=child.done_valid[4] && child.done_ready[4]
        && owned[4].instr[3:0]==2;
    VX_gemm_latency_observer #(.INSTANCE_ID("meta_control"),.BACKEND("naive")) observer (
        .clk(clk),.reset(reset),.cfg_start_fire(cfg.valid && cfg.ready),
        .cfg_entry_id(cfg.entry_id),.store_done(store_retired),
        .done_valid(done_valid),.done_ready(done_ready),.done_entry_id(entry)
    );
    // Independent pre-edge oracle; no observer internal timestamps reused.
    always @(posedge clk) if(!reset) begin
        if(cfg.valid && cfg.ready) cfg_edge=cycle;
        if(store_retired) begin last_store_edge=cycle;actual_stores++;end
        if(done_valid && valid_edge<0) valid_edge=cycle;
        if(done_valid && done_ready) handshake_edge=cycle;
        if(done_valid) assert(!( |busy)) else $fatal(1,"Done with owned executor work");
    end
    int input_count=0,load_count=0,store_count=0,close_count=0;
    VX_naive_gemm_control dut (
        .clk(clk),.reset(reset),.cfg_reg_if(cfg),.child_if(child),
        .executor_quiescent(!( |busy)),.consume_valid(consume_valid),
        .source_read_done_valid(source_read_done_valid),.source_read_done_work_seq(source_read_done_work_seq),
        .done_valid(done_valid),.done_ready(done_ready),.done_entry_id(entry),.quiescent(idle)
    );
    wire cmd_valid=dut.command_valid;
    wire cmd_ready=dut.command_ready;
    wire producer_done=dut.producer_done;
    wire closed_valid=dut.closed_valid;
    wire closed_buffer=dut.closed_buffer;
    wire [31:0] closed_generation=dut.closed_generation,closed_count=dut.closed_count;
    wire gemm_unified_cmd_t cmd=dut.command;
    for(genvar c=0;c<5;++c)begin:g_executor
        logic eligible;
        always_comb begin
            eligible=1;
            if(child.cmd[c].writer_wait.valid)
                eligible &= child.sync_value[child.cmd[c].writer_wait.reg_id]>=child.cmd[c].writer_wait.target;
            if(c==0)
                for(int dep=0;dep<4;++dep)
                    if(child.cmd[c].input_admit_waits[dep].valid)
                        eligible &= child.sync_value[child.cmd[c].input_admit_waits[dep].reg_id]
                            >=child.cmd[c].input_admit_waits[dep].target;
        end
        assign child.cmd_ready[c]=!busy[c] && eligible;
        assign child.prepare_ready[c]=0;
        assign child.done_valid[c]=busy[c] && remaining[c]==0;
        assign child.done_work_seq[c]=owned[c].work_seq;
        if(c<4)begin
            assign source_read_done_valid[c]=child.cmd_valid[c]&&child.cmd_ready[c];
            assign source_read_done_work_seq[c]=child.cmd[c].work_seq;
        end
        always @(posedge clk)begin
            if(reset)begin busy[c]<=0;remaining[c]<=0;owned[c]<='0;end
            else begin
                if(busy[c] && remaining[c]!=0)remaining[c]<=remaining[c]-1;
                if(child.done_valid[c] && child.done_ready[c])busy[c]<=0;
                if(child.cmd_valid[c] && child.cmd_ready[c])begin
                    busy[c]<=1;
                    remaining[c]<=3+c+((c==4 && child.cmd[c].instr[3:0]==2)?store_delay:0);
                    owned[c]<=child.cmd[c];
                end
            end
        end
    end
    always_comb begin
        consume_valid='0;
        if(child.done_valid[0] && child.done_ready[0])begin
            consume_valid[int'(owned[0].flags[2])]=1;
            consume_valid[2+int'(owned[0].flags[1])]=1;
            consume_valid[4+int'(owned[0].flags[0])]=1;
        end
    end
    gemm_unified_cmd_t held;
    logic stalled = 0;
    always @(posedge clk) begin
        cycle <= cycle + 1;
        if (!reset) begin
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
        void'($value$plusargs("DELIVERY_DELAY=%d",delivery_delay));
        void'($value$plusargs("STORE_DELAY=%d",store_delay));
        assert(delivery_delay>=0 && store_delay>=0)else $fatal(1,"Negative test delay");
        done_ready=(delivery_delay==0);
        cfg.regs = '0; cfg.valid = 0; cfg.entry_id = 7;
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
        wait(cfg.ready); @(negedge clk); cfg.valid=0;
        wait (producer_done); @(negedge clk);
        expected_inputs=((m+127)/128)*(k/`MXU_ROW)*((n+`MXU_COL-1)/`MXU_COL);
        expected_tiles=((m+127)/128)*((n+127)/128)*((k+127)/128);
        expected_stores=((m+127)/128)*((n+127)/128);
        assert (input_count==expected_inputs && load_count==4*expected_tiles
            && close_count==expected_tiles && store_count==expected_stores)
            else $fatal(1,"FSM command count mismatch I%0d L%0d C%0d O%0d",input_count,load_count,close_count,store_count);
        wait(done_valid);
        repeat(delivery_delay)begin
            @(posedge clk); #1;
            assert(done_valid && entry==7 && !idle)else $fatal(1,"Lost invocation completion");
        end
        if(delivery_delay!=0)begin @(negedge clk);done_ready=1;end
        @(posedge clk); #1;
        assert(handshake_edge-valid_edge==delivery_delay
            && observer.completed_count==1
            && observer.last_store==last_store_edge-cfg_edge
            && observer.last_gemm==valid_edge-cfg_edge
            && observer.last_finalize==valid_edge-last_store_edge
            && observer.last_delivery==delivery_delay
            && observer.last_handshake==handshake_edge-cfg_edge
            && observer.last_store_count==expected_stores && actual_stores==expected_stores)
            else $fatal(1,"Metadata controller endpoint mismatch D%0d store_delay%0d",delivery_delay,store_delay);
        @(negedge clk);done_ready=0;
        assert(idle)else $fatal(1,"Control plane did not drain");
        $display("ENDPOINT_CHECK cfg=%0d store=%0d valid=%0d handshake=%0d D=%0d store_delay=%0d",
            cfg_edge,last_store_edge,valid_edge,handshake_edge,delivery_delay,store_delay);
        $display("TEST PASSED integrated metadata control m%0d k%0d n%0d qrow%0d wt%0d",m,k,n,qrow,wtrans);
        $finish;
    end
    initial begin #2000000; $fatal(1,"FSM timeout"); end
endmodule
