`include "VX_define.vh"
module tb_mmio_serializer;
    import VX_gpu_pkg::*;
    localparam int LANES = 16;
    localparam int ENTRIES = 4;
    localparam int WORDS = 46;
    localparam logic [63:0] BASE = `GEMM_REG_BASE_ADDR;
    logic clk = 0, reset = 1;
    always #5 clk = ~clk;
    VX_lsu_mem_if #(.NUM_LANES(LANES), .DATA_SIZE(LSU_WORD_SIZE),
        .TAG_WIDTH(LSU_TAG_WIDTH)) source_if();
    VX_lsu_mem_if #(.NUM_LANES(1), .DATA_SIZE(LSU_WORD_SIZE),
        .TAG_WIDTH(LSU_TAG_WIDTH)) scalar_if(), remote_if[1]();
    VX_config_reg_if #(.NUM(WORDS), .DW(32)) issue();
    VX_node_done_if done();
    wire owned, link_owned, frontend_pending, publish_valid;
    logic publish_ready = 0, status_valid = 0;
    logic [`JOB_MMIO_ENTRYID_W-1:0] status_entry = 0;
    logic [31:0] status_value = 0;
    logic [LANES-1:0][63:0] replies;
    int scalar_requests = 0, scalar_reads = 0, scalar_writes = 0;
    int partial_responses = 0, publish_wait_cycles = 0;
    VX_mmio_serializer #(.INSTANCE_ID("serializer"), .NUM_LANES(LANES)) serializer (
        .clk(clk), .reset(reset), .source_if(source_if),
        .scalar_if(scalar_if), .owned_o(owned)
    );
    VX_sram_lsu_transport #(.INSTANCE_ID("narrow_link"), .DESTINATION_READ_SLOTS(4)) transport (
        .clk(clk), .source_reset(reset), .destination_reset(reset),
        .source_if(scalar_if), .destination_if(remote_if[0]), .source_owned_o(link_owned)
    );
    VX_job_frontend #(.INSTANCE_ID("unified_frontend"), .NUM_MASTERS(1),
        .NUM_ENTRIES(ENTRIES), .NUM_REGS32(WORDS), .CFG_BASE_ADDR(BASE),
        .ONE_LANE_MMIO(1), .MMIO_NUM_LANES(1), .UNIFIED_MMIO(1),
        .HW_STATUS_REG_IDX(45), .HW_WRITE_REG_IDX(43)) frontend (
        .clk(clk), .reset(reset), .mmio_if(remote_if), .issue_if(issue), .done_if(done),
        .hw_write_valid_i(1'b0), .hw_write_entry_id_i('0), .hw_write_value_i('0),
        .publish_valid_o(publish_valid), .publish_ready_i(publish_ready),
        .hw_status_valid_i(status_valid), .hw_status_entry_id_i(status_entry),
        .hw_status_value_i(status_value), .fusion_control_o(),
        .fusion_frontend_pending_o(frontend_pending)
    );
    always @(posedge clk) if (!reset) begin
        if (scalar_if.req_valid && scalar_if.req_ready) begin
            scalar_requests++;
            if (scalar_if.req_data.mask != 1) $fatal(1, "Non-scalar MMIO request");
            if (scalar_if.req_data.rw) scalar_writes++; else scalar_reads++;
        end
        if (source_if.rsp_valid && source_if.rsp_ready) begin
            if (!$onehot(source_if.rsp_data.mask)) $fatal(1, "Non-one-hot partial response");
            partial_responses++;
        end
        if (publish_valid && !publish_ready) publish_wait_cycles++;
    end
    function automatic logic [63:0] reg_address(input int entry, input int word);
        return BASE + 8 + 64'(entry * WORDS * 4 + word * 4);
    endfunction
    task automatic prepare(input bit write, input logic [15:0] mask, input int tag = 1);
        @(negedge clk);
        source_if.req_data = '0;
        source_if.req_data.rw = write;
        source_if.req_data.mask = mask;
        source_if.req_data.tag = LSU_TAG_WIDTH'(tag);
        source_if.rsp_ready = 0;
    endtask
    task automatic lane(input int index, input logic [63:0] address,
                        input logic [63:0] data = 0, input logic [7:0] byteen = 8'hff);
        source_if.req_data.addr[index] = address >> 3;
        source_if.req_data.data[index] = data;
        source_if.req_data.byteen[index] = byteen;
    endtask
    task automatic send;
        int count = 0;
        source_if.req_valid = 1;
        do begin @(posedge clk); if (++count > 100) $fatal(1, "Source acceptance timeout"); end
        while (!source_if.req_ready);
        @(negedge clk);
        source_if.req_valid = 0;
        // Payload storage belongs to the serializer after capture.
        source_if.req_data = 'x;
    endtask
    task automatic collect(input logic [15:0] expected, input int tag = 1,
                           input int hold_cycles = 0);
        logic [15:0] seen, held_mask;
        logic [63:0] held_data;
        int count = 0, first_lane;
        seen = 0;
        replies = '0;
        if (hold_cycles != 0) begin
            while (!source_if.rsp_valid) begin
                @(negedge clk); if (++count > 200) $fatal(1, "Response hold timeout");
            end
            held_mask = source_if.rsp_data.mask;
            first_lane = 0;
            while (!held_mask[first_lane]) first_lane++;
            held_data = source_if.rsp_data.data[first_lane];
            repeat (hold_cycles) begin
                @(negedge clk);
                if (!source_if.rsp_valid || source_if.rsp_data.mask != held_mask
                 || source_if.rsp_data.data[first_lane] !== held_data)
                    $fatal(1, "Stalled scalar response changed");
            end
        end
        source_if.rsp_ready = 1;
        while (seen != expected) begin
            @(posedge clk);
            if (++count > 2000) $fatal(1, "Missing response lanes expected=%h seen=%h", expected, seen);
            if (source_if.rsp_valid) begin
                if (source_if.rsp_data.tag != LSU_TAG_WIDTH'(tag)
                 || (source_if.rsp_data.mask & ~expected) != 0
                 || (source_if.rsp_data.mask & seen) != 0)
                    $fatal(1, "Wrong tag, unexpected lane or duplicate response");
                seen |= source_if.rsp_data.mask;
                for (int l = 0; l < LANES; ++l)
                    if (source_if.rsp_data.mask[l]) replies[l] = source_if.rsp_data.data[l];
            end
            @(negedge clk);
        end
        source_if.rsp_ready = 0;
    endtask
    task automatic drain;
        int count = 0;
        while (owned || link_owned || frontend.u_job_desc_mmio_regs.fusion_mmio_pending_o) begin
            @(negedge clk); if (++count > 500) $fatal(1, "Posted MMIO did not drain");
        end
        repeat (3) @(negedge clk);
    endtask
    initial begin
        int before_requests;
        source_if.req_valid = 0; source_if.req_data = 0; source_if.rsp_ready = 0;
        issue.ready = 0; done.valid = 0; done.entry_id = 0;
        repeat (6) @(negedge clk); reset = 0;

        // Four active lanes must perform four independent allocation side effects.
        prepare(0, 16'h810a, 2);
        lane(1, BASE); lane(3, BASE); lane(8, BASE); lane(15, BASE);
        before_requests = scalar_requests;
        send(); collect(16'h810a, 2, 20); drain();
        if (scalar_requests - before_requests != 4) $fatal(1, "Allocation requests lost/duplicated");
        if (!replies[1][0] || !replies[3][0] || !replies[8][0] || !replies[15][0]
         || replies[1][`JOB_MMIO_ALLOC_ENTRY_LSB +: `JOB_MMIO_ALLOC_ENTRY_BITS] != 0
         || replies[3][`JOB_MMIO_ALLOC_ENTRY_LSB +: `JOB_MMIO_ALLOC_ENTRY_BITS] != 1
         || replies[8][`JOB_MMIO_ALLOC_ENTRY_LSB +: `JOB_MMIO_ALLOC_ENTRY_BITS] != 2
         || replies[15][`JOB_MMIO_ALLOC_ENTRY_LSB +: `JOB_MMIO_ALLOC_ENTRY_BITS] != 3)
            $fatal(1, "Serialized allocation did not return four distinct entries: lane1=%h lane3=%h lane8=%h lane15=%h occupy=%h",
                replies[1], replies[3], replies[8], replies[15], frontend.occupy);

        // Concurrent lanes access different descriptor locations, with byte enables.
        prepare(1, 16'hffff);
        for (int l = 0; l < LANES; ++l)
            lane(l, reg_address(l % 4, 2 + 2 * (l / 4)), 64'h12340000_00001000 + 64'(l));
        send(); drain();
        prepare(1, 16'h0001);
        lane(0, reg_address(0, 2), 64'h00000000_0000aa00, 8'h02);
        send(); drain();
        prepare(0, 16'hffff, 3);
        for (int l = 0; l < LANES; ++l) lane(l, reg_address(l % 4, 2 + 2 * (l / 4)));
        send(); collect(16'hffff, 3, 12); drain();
        for (int l = 0; l < LANES; ++l) begin
            if (replies[l] !== (l == 0 ? 64'h12340000_0000aa00 : 64'h12340000_00001000 + 64'(l)))
                $fatal(1, "Descriptor/byte-enable data mismatch lane=%0d data=%h", l, replies[l]);
        end

        // Same-register writes have deterministic ascending-lane order.
        prepare(1, 16'h8001);
        lane(0, reg_address(0, 10), 64'h1111); lane(15, reg_address(0, 10), 64'hffff);
        send(); drain();
        prepare(0, 16'h0040); lane(6, reg_address(0, 10)); send(); collect(16'h0040); drain();
        if (replies[6] != 64'hffff) $fatal(1, "Lane serialization order changed");

        prepare(0, 16'h0020); lane(5, BASE + 'h3f8); send(); collect(16'h0020); drain();
        if (replies[5] != 64'h53465203) $fatal(1, "Wrong unified MMIO capability");

        // Publication holds the read, including under downstream backpressure.
        prepare(0, 16'h0200); lane(9, BASE + 'h3f0); send();
        wait (publish_valid);
        // Start at a falling edge so twenty subsequent falling edges enclose
        // twenty complete sampled clock cycles with publication blocked.
        @(negedge clk);
        repeat (20) begin @(negedge clk); if (source_if.rsp_valid) $fatal(1, "Publish replied before commit"); end
        publish_ready = 1;
        @(negedge clk); publish_ready = 0;
        collect(16'h0200, 1, 8); drain();
        if (replies[9] != 1 || publish_wait_cycles < 20)
            $fatal(1, "Missing publish barrier witness reply=%h wait_cycles=%0d", replies[9], publish_wait_cycles);

        // HW status survives retirement, is software-read-only, clears at allocation.
        prepare(1, 16'h0001); lane(0, reg_address(0, 44), 64'hffffffff_00000052); send();
        wait (frontend.u_job_desc_mmio_regs.req_valid_q
           && frontend.u_job_desc_mmio_regs.req_rw_q);
        // Completion coincides with a software write to the same register beat.
        @(negedge clk); status_valid = 1; status_entry = 0; status_value = 7;
        @(negedge clk); status_valid = 0;
        drain();
        prepare(1, 16'h0001); lane(0, reg_address(0, 0), 64'h1, 8'h0f); send(); drain();
        wait (issue.valid); @(negedge clk); issue.ready = 1;
        @(negedge clk); issue.ready = 0;
        repeat (3) @(negedge clk);
        done.valid = 1;
        do @(posedge clk); while (!done.ready);
        @(negedge clk); done.valid = 0;
        prepare(0, 16'h0001); lane(0, reg_address(0, 44)); send(); collect(16'h0001); drain();
        if (replies[0] != 64'h00000007_00000052)
            $fatal(1, "Status lost at done or simultaneous software update");
        prepare(0, 16'h0001); lane(0, BASE); send(); collect(16'h0001); drain();
        if (!replies[0][0]) $fatal(1, "Retired entry not reusable");
        prepare(0, 16'h0001); lane(0, reg_address(0, 44)); send(); collect(16'h0001); drain();
        if (replies[0] != 0) $fatal(1, "IO_CONTROL/status not cleared on allocation");

        // Reset discards a vector with an outstanding stalled publication read.
        prepare(0, 16'h8001); lane(0, BASE + 'h3f0); lane(15, BASE + 'h3f8); send();
        wait (publish_valid); @(negedge clk); reset = 1;
        repeat (5) @(negedge clk); reset = 0;
        repeat (12) begin
            @(negedge clk);
            if (owned || link_owned || source_if.rsp_valid || publish_valid)
                $fatal(1, "Stale MMIO work survived core reset");
        end
        prepare(0, 16'h8000); lane(15, BASE + 'h3f8); send(); collect(16'h8000); drain();
        if (replies[15] != 64'h53465203) $fatal(1, "First post-reset scalar access failed");
        $display("TEST PASSED scalar MMIO requests=%0d reads=%0d writes=%0d partial_responses=%0d publication_wait=%0d",
            scalar_requests, scalar_reads, scalar_writes, partial_responses, publish_wait_cycles);
        $finish;
    end
    initial begin #2000000; $fatal(1, "Scalar MMIO watchdog"); end
endmodule
