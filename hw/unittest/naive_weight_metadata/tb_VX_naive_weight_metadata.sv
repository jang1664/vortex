`timescale 1ns/1ps
`include "VX_define.vh"
module tb_VX_naive_weight_metadata;
    import VX_gpu_pkg::*;
    localparam int BYTES = `GEMM_WEIGHT_DATA_SIZE;
    localparam int LANES = BYTES / 8;
    localparam int ROW_BYTES = `MXU_COL / 2;
    localparam int ROWS = BYTES / ROW_BYTES;
    localparam int DEPTH = `MXU_ROW / ROWS;
    localparam int TW = GEMM_BASE_TAG_WIDTH;
    localparam int SB = $clog2(DEPTH);
    logic clk = 0, reset = 1;
    always #5 clk = ~clk;
    int cycle, accepted, installed, captured;
    int permit;
    bit allow_responses, reordered;
    bit [7:0] seen;
    gemm_wait_meta_t writer_wait, head_wait;
    wire head_valid, source_done, install_done;
    wire [31:0] head_id, source_id, install_id;
    wire release_writer = head_valid && permit >= head_wait.target;
    VX_lmem_dma_ctrl_if ctrl();
    VX_mem_bus_if #(.DATA_SIZE(8), .TAG_WIDTH(TW)) lanes[LANES]();
    VX_mem_bus_if #(.DATA_SIZE(BYTES), .TAG_WIDTH(TW)) gemm();
    VX_lmem_weight_gather_dma #(.INSTANCE_ID("metadata_test"),
        .NUM_LANES(LANES), .TAG_WIDTH(TW), .RD_PREFETCH_DEPTH(DEPTH),
        .CMD_FIFO_DEPTH(4), .NAIVE_METADATA(1)) dut (
        .clk(clk), .reset(reset), .ctrl_if(ctrl), .lmem_bus_if(lanes),
        .gemm_bus_if(gemm), .writer_wait_i(writer_wait),
        .writer_release_i(release_writer), .writer_head_valid_o(head_valid),
        .writer_wait_o(head_wait), .writer_work_seq_o(head_id),
        .source_done_valid_o(source_done), .source_done_work_seq_o(source_id),
        .install_done_valid_o(install_done), .install_done_work_seq_o(install_id));
    function automatic logic [63:0] base(input int cmd);
        return 64'h100000000 + 64'(cmd)*65536;
    endfunction
    function automatic logic [31:0] stride(input int cmd);
        return 64 + cmd*24;
    endfunction
    function automatic logic [63:0] address(input int cmd, input int lane);
        return base(cmd) + (lane/(ROW_BYTES/8))*stride(cmd)
             + (lane%(ROW_BYTES/8))*8;
    endfunction
    function automatic logic [63:0] payload(input logic [63:0] addr);
        return (addr*64'h9e3779b1) ^ 64'h913abca500ff0042;
    endfunction
    for (genvar l=0; l<LANES; ++l) begin : g_mem
        bit [DEPTH-1:0] pending;
        logic [63:0] data[DEPTH];
        logic [TW-1:0] tags[DEPTH];
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
                    if (64'(lanes[l].req_data.addr)*8 != address(requests,l))
                        $fatal(1,"wrong owned stride/address lane=%0d cmd=%0d got=%h expected=%h slot=%0d",l,requests,64'(lanes[l].req_data.addr)*8,address(requests,l),slot);
                    if (pending[slot]) $fatal(1,"duplicate pending slot");
                    pending[slot]=1;
                    data[slot]=payload(address(requests,l));
                    tags[slot]=lanes[l].req_data.tag;
                    requests++;
                end
                // Highest slot first plus lane skew deliberately reorders replies.
                if (!lanes[l].rsp_valid && allow_responses && cycle%3 != l%3) begin
                    automatic bit found=0;
                    for (int slot=DEPTH-1; slot>=0; --slot) begin
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
            cycle<=0; accepted=0; installed=0; captured=0; seen=0; reordered=0;
        end else begin
            cycle <= cycle+1;
            if (ctrl.start && ctrl.idle) accepted++;
            if (head_valid && (head_id != 100+installed || !head_wait.valid
                || head_wait.reg_id != 15 || head_wait.target != installed+1))
                $fatal(1,"writer metadata detached from destination owner");
            if (source_done) begin
                if (source_id < 100 || source_id >= 108 || seen[source_id-100])
                    $fatal(1,"invalid/duplicate source completion");
                if (source_id != 100+captured) reordered=1;
                seen[source_id-100]=1; captured++;
            end
            if (gemm.req_valid && gemm.req_ready) begin
                if (!release_writer || !install_done || install_id != 100+installed)
                    $fatal(1,"unreleased or wrong install owner");
                if (gemm.req_data.addr != installed%4 || gemm.req_data.byteen != {BYTES{1'b1}})
                    $fatal(1,"wrong destination metadata");
                for (int l=0;l<LANES;++l)
                    if (gemm.req_data.data[l*64+:64] != payload(address(installed,l)))
                        $fatal(1,"wrong install payload cmd=%0d lane=%0d",installed,l);
                installed++;
            end
            if (cycle>3000) $fatal(1,"finite fairness watchdog");
        end
    end
    task automatic submit(input int cmd);
        @(negedge clk);
        ctrl.src_base_addr=base(cmd); ctrl.src_strides[0]=stride(cmd);
        ctrl.dst_base_addr=(cmd%4)*BYTES; ctrl.reg_idx=100+cmd;
        writer_wait.valid=1; writer_wait.reg_id=15; writer_wait.target=cmd+1;
        ctrl.start=1;
        do @(posedge clk); while (!ctrl.idle);
        @(negedge clk); ctrl.start=0;
    endtask
    initial begin
        ctrl.start=0; ctrl.prepare=0; ctrl.prepare_max_beats=0;
        ctrl.src_base_addr=0; ctrl.dst_base_addr=0; ctrl.reg_idx=0;
        ctrl.reg_value=0; ctrl.scheduler_work_seq=0; ctrl.seg_size=ROW_BYTES;
        for(int d=0;d<3;++d) begin
            ctrl.src_strides[d]=0; ctrl.dst_strides[d]=0; ctrl.bounds[d]=1;
        end
        ctrl.bounds[0]=ROWS; writer_wait='0; permit=0; allow_responses=0;
        repeat(4) @(negedge clk); reset=0;
        for(int wave=0;wave<2;++wave) begin
            allow_responses=0;
            for(int c=0;c<4;++c) submit(wave*4+c);
            repeat(20) @(negedge clk);
            if (dut.queue_cmd_occupancy != 4 || installed != wave*4)
                $fatal(1,"four owners must coexist behind writer fence");
            allow_responses=1;
            wait(captured==(wave+1)*4);
            repeat(17) @(negedge clk);
            if(installed != wave*4) $fatal(1,"source capture bypassed writer fence");
            for(int c=0;c<4;++c) begin
                permit=wave*4+c+1;
                wait(installed==permit);
                repeat(7) @(negedge clk);
            end
        end
        repeat(5) @(negedge clk);
        if (!reordered) $fatal(1,"out-of-order source completion not exercised");
        if(accepted!=8 || captured!=8 || installed!=8 || dut.queue_cmd_occupancy!=0
            || dut.queue_slot_occupancy!=0 || dut.slot_busy_r!=0)
            $fatal(1,"nonquiescent or lost command");
        $display("TEST PASSED: Weight metadata MXU=%0d commands=8 distinct strides reordered responses writer fences",`MXU_ROW);
        $finish;
    end
endmodule
