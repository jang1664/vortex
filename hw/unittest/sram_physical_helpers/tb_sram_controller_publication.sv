`include "VX_define.vh"
// Directed controller protocol with the REAL publication transport enabled.
// Physical commits are the separately verified observer input contract here.
module tb_sram_controller_publication;
    import VX_gpu_pkg::*;
    logic clk=0,reset=1,published=0,dma_busy=0,dma_done=0,cmd_ready=0;
    always #5 clk=~clk;
    VX_lsu_mem_if #(.NUM_LANES(`NUM_LSU_LANES),.DATA_SIZE(LSU_WORD_SIZE),
        .TAG_WIDTH(LSU_TAG_WIDTH)) bus[1]();
    wire qv,qr,qwait,qtoken,rv,rr,rpub,rtoken;
    wire busy,owner,cmd_valid;
    wire [31:0] cmd_sequence;
    logic bad_token=0;
    VX_sram_publish_link link(.clk(clk),.controller_reset(reset),.observer_reset(reset),
        .query_valid_i(qv),.query_ready_o(qr),.query_wait_i(qwait),.query_token_i(qtoken),
        .reply_valid_o(rv),.reply_ready_i(rr),.reply_published_o(rpub),.reply_token_o(rtoken),
        .published_i(published));
    VX_sram_fusion_ctrl #(.INSTANCE_ID("linked_ctrl"),.NUM_MASTERS(1),.PUBLICATION_LINK(1)) ctrl(
        .clk(clk),.reset(reset),.mmio_if(bus),.gemm_quiescent_i(1'b1),.lmem_published_i(1'b0),
        .publication_query_valid_o(qv),.publication_query_ready_i(qr),
        .publication_query_wait_o(qwait),.publication_query_token_o(qtoken),
        .publication_reply_valid_i(rv),.publication_reply_ready_o(rr),
        .publication_reply_published_i(rpub),.publication_reply_token_i(rtoken ^ bad_token),
        .job_control_i('0),.job_accept_i(1'b0),.job_entry_i('0),.job_issue_control_i('0),
        .resident_flags_o(),.resident_reject_o(),.resident_done_i(1'b0),
        .resident_done_entry_i('0),.resident_error_i('0),.bridge_busy_o(busy),.bridge_owner_o(owner),
        .cmd_valid_o(cmd_valid),.cmd_ready_i(cmd_ready),.cmd_direction_o(),.cmd_tmem_addr_o(),
        .cmd_lmem_addr_o(),.cmd_length_o(),.cmd_sequence_o(cmd_sequence),
        .dma_busy_i(dma_busy),.dma_done_i(dma_done),.dma_done_sequence_i(32'h55),.dma_error_i('0));
    int queries=0,replies=0,launches=0,guards=0,blocked=0;
    logic previous_token=0,token_seen=0;
    always @(posedge clk) if(!reset) begin
        if(qv && qr) begin
            if(token_seen && qtoken==previous_token) $fatal(1,"Query reused previous live epoch token");
            previous_token=qtoken;token_seen=1;queries++;
        end
        if(rv && rr) replies++;
        if(cmd_valid && cmd_ready) launches++;
        if(bus[0].req_valid && bus[0].req_ready && ctrl.start_request) begin
            if(!busy) $fatal(1,"Same-edge START did not block GEMM dispatch");
            guards++;
        end
        if(ctrl.start_pending_q) begin
            if(!owner || cmd_valid || bus[0].req_ready) $fatal(1,"START reservation overwritten");
            if(bus[0].req_valid) blocked++;
        end
    end
    task automatic prepare(input bit write,input int offset,input int value,input int tag=1);
        @(negedge clk);bus[0].req_data='0;bus[0].req_data.rw=write;
        bus[0].req_data.mask[0]=1;
        bus[0].req_data.addr[0]=(64'(`DMA_REG_BASE_ADDR)+64'(offset))>>$clog2(LSU_WORD_SIZE);
        bus[0].req_data.byteen[0][offset%LSU_WORD_SIZE +: 4]=4'hf;
        bus[0].req_data.data[0][(offset%LSU_WORD_SIZE)*8 +: 32]=32'(value);
        bus[0].req_data.tag=LSU_TAG_WIDTH'(tag);bus[0].req_valid=1;
    endtask
    task automatic accept;
        int cycles=0;
        do begin @(posedge clk);if(++cycles>200) $fatal(1,"Request acceptance timeout");end
        while(!bus[0].req_ready);
        @(negedge clk);bus[0].req_valid=0;
    endtask
    task automatic response;
        int cycles=0;
        while(!bus[0].rsp_valid) begin @(negedge clk);if(++cycles>200) $fatal(1,"Response timeout");end
    endtask
    task automatic consume;
        bus[0].rsp_ready=1;@(negedge clk);bus[0].rsp_ready=0;
    endtask
    task automatic read_word(input int off,input int expected);
        prepare(0,off,0);accept();response();
        if(bus[0].rsp_data.data[0][(off%LSU_WORD_SIZE)*8 +: 32]!==32'(expected))
            $fatal(1,"Read mismatch off=%h expected=%h",off,expected);
        consume();
    endtask
    initial begin
        logic[$bits(bus[0].rsp_data)-1:0] snapshot;
        bus[0].req_valid=0;bus[0].req_data=0;bus[0].rsp_ready=0;
        repeat(8) @(negedge clk);reset=0;
        if($test$plusargs("BAD_TOKEN")) begin
            bad_token=1;published=1;prepare(0,'h2c,0);accept();
            repeat(80) @(negedge clk);
            $fatal(1,"Missing stale-token assertion");
        end
        // Mixed PUBLISH+STATUS snapshots at acceptance, not at commit reply.
        dma_busy=1;prepare(0,'h2c,0,'h123);
        bus[0].req_data.mask[1]=1;
        bus[0].req_data.addr[1]=64'(`DMA_REG_BASE_ADDR)>>$clog2(LSU_WORD_SIZE);
        bus[0].req_data.byteen[1]=8'hf0;
        accept();
        repeat(12) begin @(negedge clk);if(bus[0].rsp_valid) $fatal(1,"PUBLISH returned before commit");end
        dma_busy=0;published=1;response();
        if(bus[0].rsp_data.mask!=3 || bus[0].rsp_data.tag!=LSU_TAG_WIDTH'('h123)
         || bus[0].rsp_data.data[0][63:32]!=1 || bus[0].rsp_data.data[1][63:32]!=1)
            $fatal(1,"Mixed acceptance snapshot changed");
        snapshot=bus[0].rsp_data;
        repeat(12) begin @(negedge clk);if(!bus[0].rsp_valid || bus[0].rsp_data!==snapshot) $fatal(1,"Held snapshot changed");end
        consume();read_word('h04,0);

        prepare(1,'h0c,'h44);accept();published=0;
        prepare(1,'h08,1);accept();
        // A legal held metadata request cannot overwrite the reserved command.
        prepare(1,'h0c,'h55);
        while(ctrl.start_pending_q) begin
            if(ctrl.sequence_q!='h44 || cmd_valid) $fatal(1,"Pending START state changed");
            @(negedge clk);
        end
        accept();read_word('h28,4);read_word('h0c,'h55);
        if(launches!=0) $fatal(1,"Unpublished START launched");

        published=1;prepare(1,'h08,1);accept();
        // A second doorbell held during pending must not create another query.
        prepare(1,'h08,1);accept();
        while(!cmd_valid) @(negedge clk);
        if(cmd_sequence!='h55 || !owner) $fatal(1,"Captured command/reservation lost");
        cmd_ready=1;dma_busy=1;@(negedge clk);cmd_ready=0;
        repeat(5) @(negedge clk);dma_busy=0;dma_done=1;
        @(negedge clk);dma_done=0;read_word('h24,'h55);
        if(launches!=1 || queries!=3 || replies!=3 || guards<3 || blocked==0)
            $fatal(1,"Missing linked controller witness");

        // Reset producers together with a real PUBLISH query in flight.
        published=0;prepare(0,'h2c,0);accept();
        repeat(4) @(negedge clk);reset=1;bus[0].req_valid=0;
        repeat(6) @(negedge clk);reset=0;token_seen=0;published=1;
        repeat(12) begin @(negedge clk);if(bus[0].rsp_valid || owner || cmd_valid) $fatal(1,"Old transaction after reset");end
        prepare(0,'h2c,0);accept();response();consume();
        $display("TEST PASSED controller_publication queries=%0d replies=%0d launch=%0d guards=%0d blocked=%0d",
            queries,replies,launches,guards,blocked);
        $finish;
    end
    initial begin #2000000;$fatal(1,"Controller publication watchdog");end
endmodule
