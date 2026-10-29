// Stall writes behind a real bank read whose response consumer is blocked.
// No bank signals or storage are forced: writes themselves always see ready.
    wire bank0_read_stalled = dut.local_mem.per_bank_req_valid[0]
        && !dut.local_mem.per_bank_req_rw[0] && !dut.local_mem.per_bank_req_ready[0];
    bit dma_blocker_active = 0;
    int dma_blocker_reads = 0, dma_blocker_seen = 0;
    always @(posedge clk) if (!reset && dma_blocker_active
                             && dma_lmem[0].rsp_valid && dma_lmem[0].rsp_ready) begin
        if (dma_blocker_seen >= dma_blocker_reads
            || dma_lmem[0].rsp_data.tag !== LMEM_TAG_WIDTH'(dma_blocker_seen + 1))
            $fatal(1, "DMA blocker response missing, duplicated or reordered");
        dma_blocker_seen++;
    end
    task automatic block_bank_with_dma_reads;
        int waited;
        @(negedge clk);
        dma_blocker_active = 1;
        dma_blocker_reads = 0;
        dma_blocker_seen = 0;
        dma_lmem[0].rsp_ready = 0;
        while (!bank0_read_stalled) begin
            if (dma_blocker_reads == 32) $fatal(1, "DMA reads did not block bank 0");
            dma_lmem[0].req_data = '0;
            dma_lmem[0].req_data.addr = (`MEM_ADDR_WIDTH-$clog2(LSU_WORD_SIZE))'(`LMEM_BASE_ADDR >> $clog2(LSU_WORD_SIZE));
            dma_lmem[0].req_data.byteen = '1;
            dma_lmem[0].req_data.tag = LMEM_TAG_WIDTH'(dma_blocker_reads + 1);
            dma_lmem[0].req_valid = 1;
            waited = 0;
            do begin
                @(posedge clk);
                if (++waited == 1000) $fatal(1, "DMA blocker request timeout");
            end while (!dma_lmem[0].req_ready);
            @(negedge clk);
            dma_lmem[0].req_valid = 0;
            dma_blocker_reads++;
            // Let each request reach the bank before adding another. This
            // leaves upstream capacity for the producer store being tested.
            repeat (12) @(negedge clk);
        end
        if (!dma_lmem[0].rsp_valid || dma_blocker_seen != 0)
            $fatal(1, "Missing held DMA response witness");
        $display("DMA READ BLOCKER HELD reads=%0d", dma_blocker_reads);
    endtask
    task automatic drain_dma_blocker;
        int waited = 0;
        dma_lmem[0].rsp_ready = 1;
        while (dma_blocker_seen != dma_blocker_reads) begin
            @(negedge clk);
            if (++waited == 1000) $fatal(1, "DMA blocker response drain timeout");
        end
        dma_blocker_active = 0;
        if (dma_lmem[0].rsp_valid) $fatal(1, "Extra DMA blocker response");
        $display("DMA READ BLOCKER DRAINED responses=%0d", dma_blocker_seen);
    endtask

`ifndef SRAM_PUBLISH_UPSTREAM_TEST
    bit cpu_blocker_active = 0;
    int cpu_blocker_reads = 0, cpu_blocker_seen = 0;
    logic [`LSUQ_IN_SIZE-1:0][`NUM_LSU_LANES-1:0] cpu_blocker_pending, cpu_blocker_ingress;
    logic [`LSUQ_IN_SIZE-1:0][`NUM_LSU_LANES-1:0][LSU_WORD_SIZE*8-1:0] cpu_blocker_data;
    always @(posedge clk) if (!reset && cpu_blocker_active) begin
        int slot;
        // Record the actual memory-side payload for every lane. The queued
        // DMA write may arbitrate between remaining lane reads, so assuming
        // that every vector lane observes the old word would be incorrect.
        if (dut.lmem_vector_if.rsp_valid && dut.lmem_vector_if.rsp_ready) begin
            slot = -1;
            for (int i = 0; i < cpu_blocker_reads; ++i)
                if (dut.lmem_vector_if.rsp_data.tag === LSU_TAG_WIDTH'(i + 1)) slot = i;
            if (slot < 0 || $isunknown(dut.lmem_vector_if.rsp_data.mask)
             || !(|dut.lmem_vector_if.rsp_data.mask)) $fatal(1, "Unknown CPU blocker ingress");
            if ((dut.lmem_vector_if.rsp_data.mask & ~cpu_blocker_ingress[slot]) != 0)
                $fatal(1, "Duplicate CPU blocker ingress lane");
            for (int lane = 0; lane < `NUM_LSU_LANES; ++lane)
                if (dut.lmem_vector_if.rsp_data.mask[lane]) begin
                    if (dut.lmem_vector_if.rsp_data.data[lane] !== 64'h0123456789abcdef
                     && dut.lmem_vector_if.rsp_data.data[lane] !== 64'hfedcba9876543210)
                        $fatal(1, "CPU blocker memory payload mismatch");
                    cpu_blocker_data[slot][lane] = dut.lmem_vector_if.rsp_data.data[lane];
                end
            cpu_blocker_ingress[slot] &= ~dut.lmem_vector_if.rsp_data.mask;
        end
        if (lsu[0].rsp_valid && lsu[0].rsp_ready) begin
            slot = -1;
            for (int i = 0; i < cpu_blocker_reads; ++i)
                if (lsu[0].rsp_data.tag === LSU_TAG_WIDTH'(i + 1)) slot = i;
            if (slot < 0 || $isunknown(lsu[0].rsp_data.mask) || !(|lsu[0].rsp_data.mask))
                $fatal(1, "Unknown CPU blocker response");
            if ((lsu[0].rsp_data.mask & ~cpu_blocker_pending[slot]) != 0
             || (lsu[0].rsp_data.mask & cpu_blocker_ingress[slot]) != 0)
                $fatal(1, "CPU blocker response duplicated or before ingress");
            for (int lane = 0; lane < `NUM_LSU_LANES; ++lane)
                if (lsu[0].rsp_data.mask[lane]
                 && lsu[0].rsp_data.data[lane] !== cpu_blocker_data[slot][lane])
                    $fatal(1, "CPU blocker transport payload mismatch");
            cpu_blocker_pending[slot] &= ~lsu[0].rsp_data.mask;
            cpu_blocker_seen += $countones(lsu[0].rsp_data.mask);
        end
    end
    task automatic hold_cpu_read_responses;
        int waited = 0;
        if (`LSUQ_IN_SIZE != 2 || `NUM_LSU_LANES != 16 || `NUM_LSU_BLOCKS != 1)
            $fatal(1, "CPU blocker requires the actual C4 two-tag/16-lane contract");
        @(negedge clk);
        cpu_blocker_active = 1;
        cpu_blocker_reads = 0;
        cpu_blocker_seen = 0;
        cpu_blocker_pending = '0;
        cpu_blocker_ingress = '0;
        cpu_blocker_data = '0;
        lsu[0].rsp_ready = 0;
        // One scheduler record owns a complete vector, not one record per
        // lane. Fill bank0 with at most two legal outstanding read tags.
        while (cpu_blocker_reads < `LSUQ_IN_SIZE) begin
            cpu_blocker_pending[cpu_blocker_reads] = '1;
            cpu_blocker_ingress[cpu_blocker_reads] = '1;
            cpu_blocker_reads++;
            issue_cpu(0, `LMEM_BASE_ADDR, '0, 1, 8'hff, cpu_blocker_reads, '1);
            repeat (12) @(negedge clk);
        end
        // Legal vectors can fit in the response transport without blocking
        // the bank. Require held responses, not an impossible bank stall.
        while (!lsu[0].rsp_valid) begin
            @(negedge clk);
            if (++waited == 1000) $fatal(1, "CPU held-response timeout");
        end
        if (!lsu[0].rsp_valid || cpu_blocker_seen != 0)
            $fatal(1, "Missing held CPU response witness");
        $display("CPU READ RESPONSES HELD vectors=%0d lanes=%0d", cpu_blocker_reads,
            cpu_blocker_reads * `NUM_LSU_LANES);
    endtask
    task automatic drain_cpu_blocker;
        int waited = 0;
        lsu[0].rsp_ready = 1;
        while (cpu_blocker_seen != cpu_blocker_reads * `NUM_LSU_LANES) begin
            @(negedge clk);
            if (++waited == 1000) $fatal(1, "CPU blocker response drain timeout");
        end
        lsu[0].rsp_ready = 0;
        cpu_blocker_active = 0;
        if (cpu_blocker_pending != '0 || cpu_blocker_ingress != '0)
            $fatal(1, "CPU blocker lane ownership did not drain");
        if (lsu[0].rsp_valid) $fatal(1, "Extra CPU blocker response");
        $display("CPU READ BLOCKER DRAINED lanes=%0d", cpu_blocker_seen);
    endtask
`endif
