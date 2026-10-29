// Optional real-LSU supplement to the existing physical-memory fixture.
// Enable with -DSRAM_PUBLISH_UPSTREAM_TEST; no production state is forced.
    VX_execute_if #(.data_t(lsu_exe_t)) upstream_execute();
    VX_result_if #(.data_t(lsu_res_t)) upstream_result();
    VX_lsu_slice #(.INSTANCE_ID("publish_upstream_lsu")) upstream_lsu (
        .clk(clk), .reset(reset), .execute_if(upstream_execute),
        .result_if(upstream_result), .lsu_mem_if(lsu[0])
    );

    bit upstream_input_held = 0;
    bit upstream_bank_held = 0;
    int unsigned upstream_active_warp = 0;
    logic [63:0] upstream_expected_data;
    int unsigned upstream_queued_publish = 0;
    int unsigned upstream_empty_hold_cycles = 0;
    int unsigned upstream_publish_bank_hold_cycles = 0;
    int unsigned upstream_pending_accepts = 0;
    int unsigned upstream_pending_cycles = 0;
    int unsigned upstream_cpu_commits = 0;
    int unsigned upstream_publish_results = 0;
    int unsigned upstream_read_results = 0;

    always @(posedge clk) begin
        if (!reset) begin
            upstream_cpu_commits <= upstream_cpu_commits
                + $countones(dut.local_mem.fusion_cpu_write_commit_o);
            if (commit)
                $fatal(1, "CPU-only upstream test observed a DMA commit");
            if (upstream_bank_held && (|dut.local_mem.fusion_cpu_write_commit_o))
                $fatal(1, "Physical CPU store committed while bank was held");
            if (upstream_input_held) begin
                if (lsu[0].req_valid !== 1'b0 || lsu[0].req_ready !== 1'b0)
                    $fatal(1, "Upstream boundary hold is inconsistent");
                if (dut.fusion_pending_stores_q !== 0 || published !== 1'b1)
                    $fatal(1, "Unadmitted store changed publication accounting");
                upstream_empty_hold_cycles <= upstream_empty_hold_cycles + 1;
                // This is a handshake into the production scheduler's request
                // FIFO, while its head is still the unadmitted producer store.
                if (upstream_lsu.mem_scheduler.core_req_fire
                    && !upstream_lsu.mem_scheduler.core_req_rw
                    && upstream_execute.data.op_type == INST_LSU_LWU
                    && upstream_execute.data.rs1_data[0] == `DMA_REG_BASE_ADDR + 64'h2c) begin
                    if (!upstream_lsu.mem_scheduler.reqq_valid
                        || !upstream_lsu.mem_scheduler.reqq_rw
                        || upstream_lsu.mem_scheduler.reqq_addr[0]
                            != LSU_ADDR_WIDTH'(`LMEM_BASE_ADDR >> $clog2(LSU_WORD_SIZE))
                        || upstream_lsu.mem_scheduler.reqq_data[0] !== upstream_expected_data
                        || upstream_execute.data.wid != NW_WIDTH'(upstream_active_warp))
                        $fatal(1, "PUBLISH did not enqueue behind the producer store");
                    upstream_queued_publish <= upstream_queued_publish + 1;
                end
            end
            if (upstream_bank_held && dma_mmio[0].req_valid
                && dma_mmio[0].req_ready && !dma_mmio[0].req_data.rw)
                upstream_pending_accepts <= upstream_pending_accepts + 1;
            if (upstream_bank_held && ctrl.publish_pending_q)
                upstream_pending_cycles <= upstream_pending_cycles + 1;
            if (upstream_bank_held && ((dma_mmio[0].req_valid
                && !dma_mmio[0].req_data.rw) || ctrl.publish_pending_q)) begin
                if (published || dma_mmio[0].rsp_valid || lsu[0].rsp_valid
                    || (ctrl.publish_pending_q && dma_mmio[0].req_ready))
                    $fatal(1, "PUBLISH passed a physically blocked store");
                upstream_publish_bank_hold_cycles <= upstream_publish_bank_hold_cycles + 1;
            end
            if (upstream_result.valid && upstream_result.ready && upstream_result.data.wb) begin
                if (upstream_result.data.wid != NW_WIDTH'(upstream_active_warp)
                    || upstream_result.data.tmask != 1)
                    $fatal(1, "Unexpected upstream result producer or mask");
                case (upstream_result.data.rd)
                    1: begin
                        if (upstream_input_held || upstream_bank_held
                            || upstream_cpu_commits != upstream_active_warp + 1
                            || upstream_result.data.data[0] !== 64'd1)
                            $fatal(1, "PUBLISH result preceded commit or was not one");
                        upstream_publish_results <= upstream_publish_results + 1;
                    end
                    2: begin
                        if (upstream_result.data.data[0] !== upstream_expected_data)
                            $fatal(1, "Upstream readback mismatch: got=%h expected=%h",
                                upstream_result.data.data[0], upstream_expected_data);
                        upstream_read_results <= upstream_read_results + 1;
                    end
                    default: $fatal(1, "Unexpected upstream writeback register");
                endcase
            end
        end
    end

    // The caller starts on a falling edge. Returning on the next falling edge
    // permits consecutive execute handshakes without an intervening bubble.
    task automatic upstream_issue(input logic [INST_LSU_BITS-1:0] op,
                                  input logic [63:0] address,
                                  input logic [63:0] data,
                                  input int unsigned rd);
        int unsigned waited;
        upstream_execute.data = '0;
        upstream_execute.data.wid = NW_WIDTH'(upstream_active_warp);
        upstream_execute.data.uuid = UUID_WIDTH'(upstream_active_warp * 4 + rd + 1);
        upstream_execute.data.PC = PC_BITS'(64'h1000 + upstream_active_warp * 16 + rd * 4);
        upstream_execute.data.tmask[0] = 1;
        upstream_execute.data.sop = 1;
        upstream_execute.data.eop = 1;
        upstream_execute.data.op_type = op;
        upstream_execute.data.op_args.lsu.is_store = (op == INST_LSU_SD);
        upstream_execute.data.wb = (op != INST_LSU_SD);
        upstream_execute.data.rd = NUM_REGS_BITS'(rd);
        upstream_execute.data.rs1_data[0] = address;
        upstream_execute.data.rs2_data[0] = data;
        upstream_execute.valid = 1;
        waited = 0;
        do begin
            @(posedge clk);
            waited++;
            if (waited == 1000)
                $fatal(1, "Upstream execute request timed out: op=%h", op);
        end while (!upstream_execute.ready);
        @(negedge clk);
        upstream_execute.valid = 0;
    endtask

    task automatic upstream_run_case(input int unsigned warp,
                                     input logic [63:0] pattern);
        int unsigned waited;
        int unsigned bank_hold_start;
        upstream_active_warp = warp;
        upstream_expected_data = pattern;
        block_bank_with_dma_reads();
        upstream_input_held = 1;
        upstream_bank_held = 1;
        // Hold both sides of the admission handshake. Forcing ready alone
        // would let the memory unit repeatedly accept the stalled request.
        force lsu[0].req_valid = 1'b0;
        force lsu[0].req_ready = 1'b0;
        upstream_issue(INST_LSU_SD, `LMEM_BASE_ADDR, pattern, 0);
        upstream_issue(INST_LSU_LWU, `DMA_REG_BASE_ADDR + 64'h2c, 0, 1);
        repeat (32) @(negedge clk);
        if (upstream_queued_publish != warp + 1
            || upstream_cpu_commits != warp
            || upstream_publish_results != warp)
            $fatal(1, "Missing queued-PUBLISH/unadmitted-store overlap witness");

        upstream_input_held = 0;
        release lsu[0].req_valid;
        release lsu[0].req_ready;
        waited = 0;
        bank_hold_start = upstream_pending_cycles;
        while (upstream_pending_cycles < bank_hold_start + 32) begin
            @(negedge clk);
            waited++;
            if (waited == 1000)
                $fatal(1, "Queued PUBLISH did not reach the held physical store");
        end
        if (!bank0_read_stalled || dut.fusion_pending_stores_q !== 32'd1
            || upstream_cpu_commits != warp || upstream_publish_results != warp)
            $fatal(1, "Expected exactly one physically blocked producer store");

        upstream_bank_held = 0;
        drain_dma_blocker();
        waited = 0;
        while (upstream_publish_results != warp + 1) begin
            @(negedge clk);
            waited++;
            if (waited == 1000)
                $fatal(1, "PUBLISH result timed out after physical store release");
        end
        upstream_issue(INST_LSU_LD, `LMEM_BASE_ADDR, 0, 2);
        waited = 0;
        while (upstream_read_results != warp + 1) begin
            @(negedge clk);
            waited++;
            if (waited == 1000)
                $fatal(1, "Exact physical-memory readback timed out");
        end
        repeat (8) @(negedge clk);
        if (upstream_cpu_commits != warp + 1
            || upstream_publish_results != warp + 1
            || upstream_read_results != warp + 1 || !published)
            $fatal(1, "Duplicate/missing store, publication, or readback");
        $display("UPSTREAM PUBLISH CASE PASSED warp=%0d bytes=8 data=%h", warp, pattern);
    endtask

    initial begin
        if (LSU_WORD_SIZE != 8 || `NUM_WARPS < 2)
            $fatal(1, "Upstream publication test requires XLEN=64 and at least two warps");
        upstream_execute.valid = 0;
        upstream_execute.data = '0;
        upstream_result.ready = 1;
        dma_lmem[0].req_valid = 0;
        dma_lmem[0].req_data = '0;
        dma_lmem[0].rsp_ready = 1;
        repeat (8) @(negedge clk);
        reset = 0;
        repeat (3) @(negedge clk);
        upstream_run_case(0, 64'h0123456789abcdef);
        upstream_run_case(1, 64'hfedcba9876543210);
        if (upstream_queued_publish != 2 || upstream_empty_hold_cycles < 64
            || upstream_publish_bank_hold_cycles < 64 || upstream_pending_cycles < 64
            || upstream_pending_accepts != 2 || commits != 0)
            $fatal(1, "Upstream publication coverage incomplete");
        $display("UPSTREAM PUBLISH COVERAGE queued_during_hold=%0d counter_empty_held_cycles=%0d bank_blocked_publish_cycles=%0d cpu_commits=%0d publish_results=%0d readbacks=%0d bytes=16",
            upstream_queued_publish, upstream_empty_hold_cycles,
            upstream_publish_bank_hold_cycles, upstream_cpu_commits,
            upstream_publish_results, upstream_read_results);
        $display("UPSTREAM PENDING COVERAGE accepted_while_blocked=%0d pending_cycles=%0d",
            upstream_pending_accepts, upstream_pending_cycles);
        $display("SRAM LMEM UPSTREAM PUBLICATION PASSED");
        $display("OUTPUT CHECK PASSED");
        $finish;
    end
