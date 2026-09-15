`timescale 1ns/1ps
`include "VX_define.vh"
`ifndef TB_RESPONSE_SLOTS
`define TB_RESPONSE_SLOTS `W_LMEM_DMA_CMD_BEATS
`endif
module tb_VX_naive_weight_executor;
    import VX_gpu_pkg::*;
    localparam int BYTES = `GEMM_WEIGHT_DATA_SIZE;
    localparam int LANES = BYTES / 8;
    localparam int ROW_BYTES = `MXU_COL / 2;
    localparam int ROWS = BYTES / ROW_BYTES;
    localparam int DEPTH = `MXU_ROW / ROWS;
    localparam int TW = GEMM_BASE_TAG_WIDTH;
    localparam int RESPONSE_SLOTS = `TB_RESPONSE_SLOTS;
    logic clk = 0, reset = 1;
    always #5 clk = ~clk;
    int cycle, accepted, installed, captured;
    int permit, completions;
    localparam int GROUPS = DEPTH;
    gemm_unified_cmd_t cmd;
    logic cmd_valid, prepare_valid, done_ready;
    wire cmd_ready, prepare_ready, done_valid, quiescent;
    wire [31:0] done_id;
    wire [31:0] sync_value [GEMM_NUM_SYNC_REGS];
    for(genvar r=0;r<GEMM_NUM_SYNC_REGS;++r) assign sync_value[r]=permit;
    bit allow_responses, reordered;
    bit [7:0] seen;
    wire source_done;
    wire [31:0] source_id;
    VX_mem_bus_if #(.DATA_SIZE(8), .TAG_WIDTH(TW)) lanes[LANES]();
    VX_mem_bus_if #(.DATA_SIZE(BYTES), .TAG_WIDTH(TW)) gemm();
    VX_naive_weight_executor #(.INSTANCE_ID("weight_executor_test"),
        .RESPONSE_SLOTS(RESPONSE_SLOTS)) dut (
        .clk(clk), .reset(reset), .cmd(cmd), .cmd_valid(cmd_valid), .cmd_ready(cmd_ready),
        .prepare_valid(prepare_valid), .prepare_ready(prepare_ready),
        .done_valid(done_valid), .done_ready(done_ready), .done_work_seq(done_id),
        .sync_value(sync_value), .lane_bus_if(lanes), .install_bus_if(gemm),
        .source_done_valid(source_done), .source_done_work_seq(source_id), .quiescent(quiescent));
    function automatic logic [63:0] base(input int cmd);
        return 64'h100000000 + 64'(cmd)*65536;
    endfunction
    function automatic logic [31:0] stride(input int cmd);
        return 64 + cmd*24;
    endfunction
    function automatic logic [63:0] address(input int cmd, input int group_idx, input int lane);
        return base(cmd) + (group_idx*ROWS+lane/(ROW_BYTES/8))*stride(cmd)
             + (lane%(ROW_BYTES/8))*8;
    endfunction
    function automatic logic [63:0] payload(input logic [63:0] addr);
        return (addr*64'h9e3779b1) ^ 64'h913abca500ff0042;
    endfunction
    for (genvar l=0; l<LANES; ++l) begin : g_mem
        bit [RESPONSE_SLOTS-1:0] pending;
        logic [63:0] data[RESPONSE_SLOTS];
        logic [TW-1:0] tags[RESPONSE_SLOTS];
        int requests;
        assign lanes[l].req_ready = (cycle%5 != l%5);
        always @(posedge clk) begin
            if (reset) begin
                pending = '0; requests = 0;
                lanes[l].rsp_valid <= 0;
                lanes[l].rsp_data <= '0;
            end else begin
                if (lanes[l].rsp_valid && lanes[l].rsp_ready)
                    lanes[l].rsp_valid <= 0;
                if (lanes[l].req_valid && lanes[l].req_ready) begin
                    automatic int slot = lanes[l].req_data.tag.value;
                    if (64'(lanes[l].req_data.addr)*8 != address(requests/GROUPS,requests%GROUPS,l))
                        $fatal(1,"wrong owned stride/address lane=%0d cmd=%0d got=%h expected=%h slot=%0d",l,requests,64'(lanes[l].req_data.addr)*8,address(requests/GROUPS,requests%GROUPS,l),slot);
                    if (pending[slot]) $fatal(1,"duplicate pending slot");
                    pending[slot]=1;
                    data[slot]=payload(address(requests/GROUPS,requests%GROUPS,l));
                    tags[slot]=lanes[l].req_data.tag;
                    requests++;
                end
                // Highest slot first plus lane skew deliberately reorders replies.
                if (!lanes[l].rsp_valid && allow_responses && cycle%3 != l%3) begin
                    automatic bit found=0;
                    for (int slot=RESPONSE_SLOTS-1; slot>=0; --slot) begin
                        if (!found && pending[slot]) begin
                            found=1; pending[slot]=0;
                            lanes[l].rsp_valid <= 1;
                            lanes[l].rsp_data.data <= data[slot];
                            lanes[l].rsp_data.tag <= tags[slot];
                        end
                    end
                end
            end
        end
    end
    assign gemm.req_ready = cycle%7 != 0 && cycle%7 != 1;
    assign gemm.rsp_valid = 0;
    assign gemm.rsp_data = '0;
    always @(posedge clk) begin
        if (reset) begin
            cycle<=0; accepted=0; installed=0; captured=0; seen=0; reordered=0; completions=0;
        end else begin
            cycle <= cycle+1;
            if (cmd_valid && cmd_ready) accepted++;
            if (done_valid && done_ready) begin
                if (done_id != 100+completions) $fatal(1,"wrong completion owner");
                completions++;
            end
            if (source_done) begin
                if (source_id < 100 || source_id >= 108 || seen[source_id-100])
                    $fatal(1,"invalid/duplicate source completion");
                if (source_id != 100+captured) reordered=1;
                seen[source_id-100]=1; captured++;
            end
            if (gemm.req_valid && gemm.req_ready) begin
                if (installed/GROUPS >= permit)
                    $fatal(1,"unreleased writer");
                if (gemm.req_data.addr != (installed/GROUPS)%4 || gemm.req_data.byteen != {BYTES{1'b1}})
                    $fatal(1,"wrong destination metadata");
                for (int l=0;l<LANES;++l)
                    if (gemm.req_data.data[l*64+:64] != payload(address(installed/GROUPS,installed%GROUPS,l)))
                        $fatal(1,"wrong install payload beat=%0d lane=%0d",installed,l);
                installed++;
            end
            if (cycle>3000) $fatal(1,"finite fairness watchdog");
        end
    end
    task automatic setup_cmd(input int c);
        cmd='0; cmd.instr=5; cmd.work_seq=100+c;
        cmd.rs2_data=base(c); cmd.stride=stride(c); cmd.flags=c%4;
        cmd.bound=(c%2) ? 3 : `MXU_ROW; cmd.groups_eff=3;
        cmd.writer_wait.valid=1; cmd.writer_wait.reg_id=GEMM_RID_W_CONSUME0;
        cmd.writer_wait.target=c+1; cmd.notify.value=100+c;
    endtask
    task automatic issue(input int c);
        @(negedge clk); setup_cmd(c); cmd_valid=1;
        do @(posedge clk); while (!cmd_ready);
        @(negedge clk); cmd_valid=0;
    endtask
    initial begin
        cmd='0; cmd_valid=0; prepare_valid=0; done_ready=0;
        permit=0; allow_responses=1;
        repeat(4) @(negedge clk); reset=0;
        for(int wave=0;wave<2;++wave) begin
            @(negedge clk); setup_cmd(wave*4); prepare_valid=1;
            do @(posedge clk); while(!prepare_ready);
            @(negedge clk); prepare_valid=0;
            // Make the writer available while activation is deliberately absent.
            permit=wave*4+1;
            wait(captured==wave*4+1);
            repeat(17) @(negedge clk);
            if(installed != wave*4*GROUPS || accepted != wave*4)
                $fatal(1,"prepare installed before activation");
            permit=wave*4;
            issue(wave*4);
            for(int c=1;c<4;++c) issue(wave*4+c);
            if(dut.outstanding_q != 4) $fatal(1,"missing four executor owners");
            for(int c=0;c<4;++c) begin
                @(negedge clk); permit=wave*4+c+1; done_ready=0;
                wait(done_valid);
                repeat(19) begin
                    @(negedge clk);
                    if(!done_valid || done_id!=100+wave*4+c || installed!=(wave*4+c+1)*GROUPS)
                        $fatal(1,"completion owner/payload advanced under backpressure");
                end
                done_ready=1;
                wait(completions==wave*4+c+1);
                @(negedge clk); done_ready=0;
            end
        end
        repeat(5) @(negedge clk);
        if(accepted!=8 || captured!=8 || installed!=8*GROUPS || completions!=8 || !quiescent)
            $fatal(1,"nonquiescent or lost command");
        $display("TEST PASSED: Weight executor MXU=%0d prepared activation full microtiles held completion repeated jobs response_slots=%0d",`MXU_ROW,RESPONSE_SLOTS);
        $finish;
    end
endmodule
