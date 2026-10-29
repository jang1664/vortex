`include "VX_define.vh"
// Real GEMM frontend + credit link + safe export. The compute consumer is
// modeled only at its existing issue/done interface; no DUT state is forced.
module tb_sram_frontend_busy;
    import VX_gpu_pkg::*;
    logic clk=0,reset=1,kernel_busy=0,require_busy=0;
    always #5 clk=~clk;
    logic first_post_reset = 1;
    always @(posedge clk) first_post_reset <= reset;
    VX_lsu_mem_if #(.NUM_LANES(`NUM_LSU_LANES),.DATA_SIZE(LSU_WORD_SIZE),
        .TAG_WIDTH(LSU_TAG_WIDTH)) source_if(),remote_if[1]();
    wire owned,frontend_pending,exported;
    wire device_busy=kernel_busy || exported;
    VX_sram_lsu_transport #(.DESTINATION_READ_SLOTS(4)) transport(
        .clk(clk),.source_reset(reset),.destination_reset(reset),
        .source_if(source_if),.destination_if(remote_if[0]),.source_owned_o(owned));
    VX_sram_busy_export #(.SOURCES(1)) busy_export(
        .clk(clk),.source_reset(reset),.destination_reset(reset),
        .operational_busy_i(frontend_pending),.source_owned_i(owned),
        .source_offer_i(source_if.req_valid),.busy_o(exported));
    VX_config_reg_if #(.NUM(44),.DW(32)) issue();
    VX_node_done_if done();
    VX_job_frontend #(.INSTANCE_ID("busy_frontend"),.NUM_MASTERS(1),.NUM_ENTRIES(1),
        .NUM_REGS32(44),.CFG_BASE_ADDR(`GEMM_REG_BASE_ADDR),.ONE_LANE_MMIO(1)) frontend(
        .clk(clk),.reset(reset),.mmio_if(remote_if),.issue_if(issue),.done_if(done),
        .hw_write_valid_i(1'b0),.hw_write_entry_id_i('0),.hw_write_value_i('0),
        .fusion_control_o(),.fusion_frontend_pending_o(frontend_pending));
    int captures=0,staged_after_retire=0,queued_cycles=0,working_cycles=0,offer_during_release=0;
    always @(posedge clk) if(!reset) begin
        if(frontend.u_job_desc_mmio_regs.req_capture) captures++;
        if(!kernel_busy && frontend.u_job_desc_mmio_regs.req_valid_q) staged_after_retire++;
        if(frontend.valid[0] && !frontend.working[0]) queued_cycles++;
        if(frontend.working[0]) working_cycles++;
        if(first_post_reset && source_if.req_valid && source_if.req_ready) offer_during_release++;
    end
    always @(negedge clk) begin
        #1;
        if(!reset && require_busy && !device_busy)
            $fatal(1,"AFU completion gap before posted work drained");
    end
    task automatic prepare(input bit write,input int off,input int value);
        @(negedge clk);source_if.req_data='0;source_if.req_valid=1;
        source_if.req_data.mask[0]=1;source_if.req_data.rw=write;
        source_if.req_data.addr[0]=(64'(`GEMM_REG_BASE_ADDR)+64'(off))>>$clog2(LSU_WORD_SIZE);
        source_if.req_data.byteen[0]=8'h0f;source_if.req_data.data[0]=64'(value);
        source_if.req_data.tag=LSU_TAG_WIDTH'(1);
    endtask
    task automatic accept_and_retire;
        int cycles=0;
        do begin @(posedge clk);if(++cycles>100) $fatal(1,"MMIO accept timeout");end while(!source_if.req_ready);
        // Same-edge source handshake and modeled worker/kernel retirement.
        kernel_busy<=0;
        @(negedge clk);source_if.req_valid=0;
    endtask
    task automatic quiet;
        int cycles=0;
        require_busy=0;
        while(device_busy) begin @(negedge clk);if(++cycles>150) $fatal(1,"Busy did not drain");end
        repeat(10) begin @(negedge clk);if(device_busy) $fatal(1,"Late busy pulse");end
    endtask
    initial begin
        source_if.req_valid=0;source_if.req_data=0;source_if.rsp_ready=0;
        issue.ready=0;done.valid=0;done.entry_id=0;
        repeat(8) @(negedge clk);reset=0;
        repeat(12) begin @(negedge clk);if(device_busy) $fatal(1,"Reset release fabricated work");end
        kernel_busy=1;prepare(0,0,0);accept_and_retire();
        while(!source_if.rsp_valid) @(negedge clk);
        if(!source_if.rsp_data.data[0][0]) $fatal(1,"Allocation failed");
        source_if.rsp_ready=1;@(negedge clk);source_if.rsp_ready=0;quiet();
        if(!frontend.occupy[0] || frontend_pending) $fatal(1,"Allocated inactive entry kept busy");

        kernel_busy=1;prepare(1,LSU_WORD_SIZE,1);require_busy=1;accept_and_retire();
        while(!issue.valid) @(negedge clk);
        repeat(15) @(negedge clk); // Queued, not yet accepted by compute.
        issue.ready=1;@(posedge clk);@(negedge clk);issue.ready=0;
        repeat(20) @(negedge clk); // Working job, CPU/kernel already retired.
        done.valid=1;
        do @(posedge clk);while(!done.ready);
        @(negedge clk);done.valid=0;quiet();
        if(frontend.occupy[0] || frontend.working[0]) $fatal(1,"Done did not clear job");

        // A real offer at the first post-reset edge must be accepted.
        // This posted invalid-entry write creates
        // no job, but still traverses the real captured-request stage.
        @(negedge clk);reset=1;source_if.req_valid=0;
        repeat(6) @(negedge clk);
        prepare(1,LSU_WORD_SIZE,0);reset=0;require_busy=1;
        #1;if(!source_if.req_ready) $fatal(1,"MMIO reset-release holdoff");
        accept_and_retire();
        while(owned || frontend_pending) @(negedge clk);
        quiet();
        if(captures<3 || staged_after_retire==0 || queued_cycles<15 || working_cycles<20 || offer_during_release==0)
            $fatal(1,"Missing real frontend/retirement witness");
        $display("TEST PASSED frontend_busy captures=%0d staged_after_retire=%0d queued=%0d working=%0d early_offer=%0d",
            captures,staged_after_retire,queued_cycles,working_cycles,offer_during_release);
        $finish;
    end
    initial begin #2000000;$fatal(1,"Frontend busy watchdog");end
endmodule
