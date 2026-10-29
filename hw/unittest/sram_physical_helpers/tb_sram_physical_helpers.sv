`include "VX_define.vh"
module tb_sram_physical_helpers;
    import VX_gpu_pkg::*;
    logic clk=0, reset=1;
    always #5 clk=~clk;
    logic first_post_reset = 1;
    always @(posedge clk) first_post_reset <= reset;
    logic [15:0] bank_valid=0,bank_write=0,bank_dma=0;
    wire [15:0] cpu_commits,dma_commits;
    wire [4:0] count;
    VX_sram_commit_return #(.BANKS(16)) counter(
        .clk(clk),.reset(reset),.valid_i(bank_valid),.write_i(bank_write),.dma_source_i(bank_dma),
        .cpu_commits_o(cpu_commits),.dma_commits_o(dma_commits),.count_o(count));
    logic [`NUM_LSU_BLOCKS-1:0] av=0,ar=0,aw=0;
    logic [`NUM_LSU_BLOCKS-1:0][`NUM_LSU_LANES-1:0] am=0;
    logic [`NUM_LSU_BLOCKS-1:0][`NUM_LSU_LANES-1:0][`MEM_ADDR_WIDTH-$clog2(LSU_WORD_SIZE)-1:0] aa=0;
    logic [`NUM_LSU_BLOCKS-1:0][`NUM_LSU_LANES-1:0][MEM_FLAGS_WIDTH-1:0] af=0;
    wire published;
    wire [31:0] pending;
    VX_sram_publication_observer observer(
        .clk(clk),.reset(reset),.valid_i(av),.ready_i(ar),.write_i(aw),
        .mask_i(am),.addr_i(aa),.flags_i(af),.committed_count_i(count),
        .published_o(published),.pending_o(pending));
    logic qv=0,qwait=0,qtoken=0,rr=0;
    wire qr,rv,rpublished,rtoken;
    VX_sram_publish_link link(
        .clk(clk),.controller_reset(reset),.observer_reset(reset),
        .query_valid_i(qv),.query_ready_o(qr),.query_wait_i(qwait),.query_token_i(qtoken),
        .reply_valid_o(rv),.reply_ready_i(rr),.reply_published_o(rpublished),
        .reply_token_o(rtoken),.published_i(published));

    VX_mem_bus_if #(.DATA_SIZE(32),.TAG_WIDTH(GEMM_BASE_TAG_WIDTH)) upstream(),downstream();
    wire mem_idle;
    VX_sram_mem_transport memory_link(.clk(clk),.source_reset(reset),.destination_reset(reset),
        .upstream_if(upstream),.downstream_if(downstream),.request_idle(mem_idle));
    logic mem_enable=1,mem_rsp_valid=0;
    logic [$bits(downstream.rsp_data)-1:0] mem_rsp_data;
    logic [$bits(upstream.req_data)-1:0] expected_mem_request;
    assign downstream.req_ready=mem_enable && (!mem_rsp_valid || downstream.rsp_ready);
    assign downstream.rsp_valid=mem_rsp_valid;
    assign downstream.rsp_data=mem_rsp_data;
    always @(posedge clk) begin
        if(reset) mem_rsp_valid<=0;
        else if(downstream.req_valid && downstream.req_ready) begin
            if(downstream.req_data!==expected_mem_request) $fatal(1,"Memory request payload changed");
            mem_rsp_valid<=1;
            mem_rsp_data<={downstream.req_data.data ^ 256'h123456789abcdef,downstream.req_data.tag};
        end else if(downstream.rsp_ready) mem_rsp_valid<=0;
    end

    int delayed1=0,delayed2=0,physical_pending=0,expected_admits=0;
    int peak=0,consecutive=0,early_admit=0,same_edge=0,query_responses=0,mem_responses=0;
    logic last_nonzero=0;
    always @(posedge clk) begin
        if(reset) begin
            delayed1=0;delayed2=0;physical_pending=0;last_nonzero=0;
        end else begin
            if(count!==5'(delayed2)) $fatal(1,"Commit return lost/duplicated a cycle");
            if(published && (physical_pending!=0 || expected_admits!=0))
                $fatal(1,"Publication preceded physical commit or same-edge admission");
            if(expected_admits!=0) begin
                physical_pending+=expected_admits;
                if(first_post_reset) early_admit++;
                if(count!=0) same_edge++;
            end
            physical_pending-=$countones(cpu_commits);
            if(physical_pending<0) $fatal(1,"Test physical commit before admission");
            if(cpu_commits!==(bank_valid & bank_write & ~bank_dma)
             || dma_commits!==(bank_valid & bank_write & bank_dma)) $fatal(1,"Commit decode mismatch");
            delayed2=delayed1;delayed1=$countones(cpu_commits);
            if(delayed1==16) peak++;
            if(last_nonzero && delayed1!=0) consecutive++;
            last_nonzero=(delayed1!=0);
            if(rv && rr) query_responses++;
            if(upstream.rsp_valid && upstream.rsp_ready) mem_responses++;
        end
        if(reset && upstream.req_ready) $fatal(1,"Memory source accepted during core reset");
    end
    task automatic cycle(input int admits,input logic[15:0] cpu,input logic[15:0] dma=0);
        @(negedge clk);
        av='0;ar='1;aw='1;am='0;
        av[0]=(admits!=0); am[0]=`NUM_LSU_LANES'((32'h1<<admits)-1);
        expected_admits=admits;
        bank_valid=cpu|dma;bank_write=cpu|dma;bank_dma=dma;
    endtask
    task automatic idle(input int n=8);
        cycle(0,0);
        repeat(n) @(negedge clk);
    endtask
    task automatic query(input bit wait_for_commit,input bit token);
        @(negedge clk);qv=1;qwait=wait_for_commit;qtoken=token;
        do @(posedge clk); while(!qr);
        @(negedge clk);qv=0;
    endtask
    task automatic reply(input bit value,input bit token);
        int cycles=0;
        while(!rv) begin @(negedge clk);if(++cycles>150) $fatal(1,"Reply timeout");end
        repeat(7) begin
            @(negedge clk);
            if(!rv || rpublished!==value || rtoken!==token) $fatal(1,"Reply changed or wrong token/result");
        end
        rr=1;@(negedge clk);rr=0;
    endtask
    task automatic flush;
        @(negedge clk);reset=1;qv=0;rr=0;av=0;am=0;expected_admits=0;bank_valid=0;bank_write=0;bank_dma=0;
        upstream.req_valid=0;upstream.rsp_ready=0;
        repeat(6) @(negedge clk);reset=0;
        // Both transport endpoints accept immediately in the new core-reset epoch.
        av[0]=1;ar='1;aw='1;am[0]=1;expected_admits=1;
        #1; if(!upstream.req_ready || !qr) $fatal(1,"Extra reset-release holdoff");
        @(negedge clk);av=0;am=0;expected_admits=0;
        if(pending!=1) $fatal(1,"Early post-reset admission lost");
        cycle(0,16'h1);idle();
        if(pending!=0 || !published || rv || upstream.rsp_valid || !mem_idle)
            $fatal(1,"Old epoch survived reset or new count was lost");
    endtask
    task automatic memory_packet(input int id,input bit write);
        logic[$bits(upstream.rsp_data)-1:0] expected;
        @(negedge clk);upstream.req_data='0;upstream.req_data.rw=write;
        upstream.req_data.addr=id;upstream.req_data.data={8{32'(id*32+7)}};
        upstream.req_data.byteen=32'h5aa55aa5;upstream.req_data.flags=MEM_FLAGS_WIDTH'(id);
        upstream.req_data.tag=GEMM_BASE_TAG_WIDTH'(id);
        expected_mem_request=upstream.req_data;
        expected={upstream.req_data.data ^ 256'h123456789abcdef,upstream.req_data.tag};
        upstream.req_valid=1;
        do @(posedge clk);while(!upstream.req_ready);
        @(negedge clk);upstream.req_valid=0;
        while(!upstream.rsp_valid) @(negedge clk);
        repeat(9) begin
            @(negedge clk);
            if(!upstream.rsp_valid || upstream.rsp_data!==expected) $fatal(1,"Memory response changed/mismatched");
        end
        upstream.rsp_ready=1;@(negedge clk);upstream.rsp_ready=0;
        repeat(8) @(negedge clk);
        if(!mem_idle) $fatal(1,"Memory request credits did not drain");
    endtask
    initial begin
        if(`NUM_LSU_LANES<16 || `LMEM_NUM_BANKS!=16) $fatal(1,"Requires actual C4 geometry");
        for(int b=0;b<`NUM_LSU_BLOCKS;b++) for(int l=0;l<`NUM_LSU_LANES;l++) begin
            aa[b][l]=(64'(`LMEM_BASE_ADDR)>>$clog2(LSU_WORD_SIZE))+l;
            af[b][l][MEM_REQ_FLAG_LOCAL]=1;
        end
        upstream.req_valid=0;upstream.req_data=0;upstream.rsp_ready=0;
        flush();
        // These offered lanes are not local CPU stores and must not create
        // pending work: global-flag write, MMIO write, then local read.
        @(negedge clk);av[0]=1;ar='1;aw='1;am[0]=1;af[0][0]=0;
        @(negedge clk);af[0][0][MEM_REQ_FLAG_LOCAL]=1;
        aa[0][0]=64'(`DMA_REG_BASE_ADDR)>>$clog2(LSU_WORD_SIZE);
        @(negedge clk);aa[0][0]=64'(`LMEM_BASE_ADDR)>>$clog2(LSU_WORD_SIZE);aw=0;
        idle();if(pending!=0 || !published) $fatal(1,"Nonstore/MMIO lane counted as CPU store");
        cycle(16,0);cycle(16,0);cycle(0,16'hffff);cycle(0,16'h7);
        cycle(2,16'h1f);cycle(0,16'hff);cycle(0,16'h3);idle();
        if(pending!=0 || !published) $fatal(1,"Consecutive count sequence did not drain");
        cycle(0,0,16'h8000);idle(); // One DMA commit must not decrement CPU accounting.
        cycle(1,0);idle();
        query(0,0);reply(0,0); // fresh START sees unfinished work
        query(1,1);
        repeat(16) begin @(negedge clk);if(rv) $fatal(1,"PUBLISH returned early");end
        cycle(0,1);idle();reply(1,1);
        memory_packet(1,0);memory_packet(2,1);
        // Reset a genuine pending query and memory request together.
        cycle(1,0);idle();query(1,0);
        mem_enable=0;
        @(negedge clk);upstream.req_valid=1;
        do @(posedge clk);while(!upstream.req_ready);
        @(negedge clk);upstream.req_valid=0;
        flush();mem_enable=1;
        query(1,0);reply(1,0);memory_packet(3,0);
        // Reset with an actual backpressured response and its return credits.
        @(negedge clk);upstream.req_valid=1;
        do @(posedge clk);while(!upstream.req_ready);
        @(negedge clk);upstream.req_valid=0;
        while(!upstream.rsp_valid) @(negedge clk);
        flush();memory_packet(4,0);
        if(peak==0 || consecutive<3 || early_admit<2 || same_edge==0 || query_responses!=3 || mem_responses!=4)
            $fatal(1,"Missing helper witness");
        $display("TEST PASSED physical_helpers count16=%0d consecutive=%0d early_admit=%0d same_edge=%0d replies=%0d memory=%0d",
            peak,consecutive,early_admit,same_edge,query_responses,mem_responses);
        $finish;
    end
    initial begin #2000000;$fatal(1,"Helper watchdog");end
endmodule
