`include "VX_define.vh"

module tb_VX_sram_lmem_publish;
    import VX_gpu_pkg::*;
    logic clk = 0;
    always #5 clk = ~clk;
    logic reset = 1;
    VX_lsu_mem_if #(.NUM_LANES(`NUM_LSU_LANES), .DATA_SIZE(LSU_WORD_SIZE), .TAG_WIDTH(LSU_TAG_WIDTH)) lsu[`NUM_LSU_BLOCKS]();
    VX_lsu_mem_if #(.NUM_LANES(`NUM_LSU_LANES), .DATA_SIZE(LSU_WORD_SIZE), .TAG_WIDTH(LSU_TAG_WIDTH)) dma_mmio[`NUM_LSU_BLOCKS]();
    VX_lsu_mem_if #(.NUM_LANES(`NUM_LSU_LANES), .DATA_SIZE(LSU_WORD_SIZE), .TAG_WIDTH(LSU_TAG_WIDTH)) gemm_mmio[`NUM_LSU_BLOCKS]();
    VX_mem_bus_if #(.DATA_SIZE(DCACHE_WORD_SIZE), .TAG_WIDTH(DCACHE_CORE_TAG_WIDTH)) dcache[DCACHE_CORE_NUM_REQS]();
    VX_mem_bus_if #(.DATA_SIZE(LSU_WORD_SIZE), .TAG_WIDTH(LMEM_TAG_WIDTH)) dma_lmem[`LMEM_NUM_PORTS]();
    VX_mem_bus_if #(.DATA_SIZE(`DMA_DCACHE_PORTS*DCACHE_WORD_SIZE), .TAG_WIDTH(DMA_DCACHE_TAG_WIDTH)) dma_global();
    wire commit, published;
    int unsigned commits = 0;
    always @(posedge clk)
        if (!reset && commit)
            commits <= commits + 1;

    VX_mem_unit #(.INSTANCE_ID("publish_mem")) dut (
        .clk(clk), .reset(reset), .lsu_mem_if(lsu), .dcache_bus_if(dcache),
        .dma_ctrl_if(dma_mmio), .gemm_ctrl_if(gemm_mmio),
        .dma_local_data_if(dma_lmem), .dma_global_data_if(dma_global),
        .fusion_lmem_write_commit_o(commit), .fusion_lmem_published_o(published)
`ifdef PERF_ENABLE
        ,.lmem_perf(), .coalescer_perf()
`endif
    );
    VX_sram_fusion_ctrl #(.INSTANCE_ID("publish_ctrl"), .NUM_MASTERS(`NUM_LSU_BLOCKS)) ctrl (
        .clk(clk), .reset(reset), .mmio_if(dma_mmio),
        .gemm_quiescent_i(1'b1), .lmem_published_i(published), .job_control_i('0),
        .job_accept_i(1'b0), .job_entry_i('0), .job_issue_control_i('0),
        .resident_flags_o(), .resident_reject_o(), .resident_done_i(1'b0),
        .resident_done_entry_i('0), .resident_error_i('0),
        .bridge_busy_o(), .bridge_owner_o(), .cmd_valid_o(), .cmd_ready_i(1'b1),
        .cmd_direction_o(), .cmd_tmem_addr_o(), .cmd_lmem_addr_o(),
        .cmd_length_o(), .cmd_sequence_o(), .dma_busy_i(1'b0),
        .dma_done_i(1'b0), .dma_done_sequence_i('0), .dma_error_i('0)
    );
    for (genvar i = 0; i < `NUM_LSU_BLOCKS; ++i) begin : g_idle_mmio
        assign gemm_mmio[i].req_ready = 1'b1;
        assign gemm_mmio[i].rsp_valid = 1'b0;
        assign gemm_mmio[i].rsp_data = '0;
        if (i != 0) begin : g_idle_lsu
            initial begin
                lsu[i].req_valid = 0;
                lsu[i].req_data = '0;
                lsu[i].rsp_ready = 1;
            end
        end
    end
    for (genvar i = 0; i < DCACHE_CORE_NUM_REQS; ++i) begin : g_idle_dcache
        assign dcache[i].req_ready = 1'b1;
        assign dcache[i].rsp_valid = 1'b0;
        assign dcache[i].rsp_data = '0;
    end
    for (genvar i = 1; i < `LMEM_NUM_PORTS; ++i) begin : g_idle_dma
        initial begin
            dma_lmem[i].req_valid = 0;
            dma_lmem[i].req_data = '0;
            dma_lmem[i].rsp_ready = 1;
        end
    end
    initial begin
        dma_global.req_valid = 0;
        dma_global.req_data = '0;
        dma_global.rsp_ready = 1;
    end

    `include "sram_publish_read_blocker.svh"

`ifdef SRAM_PUBLISH_UPSTREAM_TEST
    `include "sram_publish_upstream_tests.svh"
`else
    bit dma_order_active = 0;
    int dma_order_cycle = 0;
    int dma_accept_cycle = -1, dma_physical_cycle = -1, dma_commit_cycle = -1;
    int dma_accept_count = 0, dma_physical_count = 0, dma_commit_count = 0;
    wire [`LMEM_NUM_BANKS-1:0] physical_dma_writes = dut.local_mem.per_bank_req_valid
        & dut.local_mem.per_bank_req_ready & dut.local_mem.per_bank_req_rw
        & dut.local_mem.fusion_dma_source;
    always @(posedge clk) if (!reset && dma_order_active) begin
        dma_order_cycle++;
        if (!published) $fatal(1, "DMA store incorrectly counted as a CPU store");
        if (dma_lmem[0].req_valid && dma_lmem[0].req_ready && dma_lmem[0].req_data.rw) begin
            if (dma_accept_count != 0) $fatal(1, "Duplicate DMA requester acceptance");
            dma_accept_count++;
            dma_accept_cycle = dma_order_cycle;
        end
        if (|physical_dma_writes) begin
            if (physical_dma_writes !== {{(`LMEM_NUM_BANKS-1){1'b0}}, 1'b1}
             || dma_physical_count != 0 || dma_accept_count != 1
             || dma_accept_cycle >= dma_order_cycle)
                $fatal(1, "DMA physical write missing prior acceptance, duplicated or wrong bank");
            if (dut.local_mem.per_bank_req_addr[0] !== '0
             || dut.local_mem.per_bank_req_byteen[0] !== '1
             || dut.local_mem.per_bank_req_data[0] !== 64'hfedcba9876543210)
                $fatal(1, "DMA physical write address/byteen/data mismatch");
            dma_physical_count++;
            dma_physical_cycle = dma_order_cycle;
        end
        if (commit) begin
            if (dma_commit_count != 0 || dma_physical_count != 1
             || dma_physical_cycle > dma_order_cycle)
                $fatal(1, "DMA commit preceded physical write or repeated");
            dma_commit_count++;
            dma_commit_cycle = dma_order_cycle;
        end
    end

    task automatic issue_cpu(input bit write_req, input logic [63:0] address,
                             input logic [63:0] data, input bit local_req,
                             input logic [7:0] byteen, input int unsigned tag = 0,
                             input logic [`NUM_LSU_LANES-1:0] lanes = 'd1);
        int waited = 0;
        @(negedge clk);
        lsu[0].req_valid = 1;
        lsu[0].req_data = '0;
        lsu[0].req_data.rw = write_req;
        lsu[0].req_data.mask = lanes;
        for (int lane = 0; lane < `NUM_LSU_LANES; ++lane) if (lanes[lane]) begin
            lsu[0].req_data.addr[lane] = LSU_ADDR_WIDTH'(address >> $clog2(LSU_WORD_SIZE));
            lsu[0].req_data.data[lane] = data;
            lsu[0].req_data.byteen[lane] = byteen;
            lsu[0].req_data.flags[lane][MEM_REQ_FLAG_LOCAL] = local_req;
        end
        lsu[0].req_data.tag = LSU_TAG_WIDTH'(tag);
        do begin
            @(posedge clk);
            if (++waited == 1000) $fatal(1, "CPU request acceptance timeout");
        end while (!lsu[0].req_ready);
        @(negedge clk);
        lsu[0].req_valid = 0;
    endtask

    task automatic take_response(input logic [63:0] expected_data);
        while (!lsu[0].rsp_valid) @(negedge clk);
        if (lsu[0].rsp_data.mask != 1 || lsu[0].rsp_data.data[0] != expected_data)
            $fatal(1, "Unexpected LSU response: mask=%h data=%h expected=%h",
                lsu[0].rsp_data.mask, lsu[0].rsp_data.data[0], expected_data);
        lsu[0].rsp_ready = 1;
        @(posedge clk);
        @(negedge clk);
        lsu[0].rsp_ready = 0;
    endtask

    initial begin
        if (LSU_WORD_SIZE != 8)
            $fatal(1, "Publication test requires XLEN=64");
        lsu[0].req_valid = 0;
        lsu[0].req_data = '0;
        lsu[0].rsp_ready = 0;
        dma_lmem[0].req_valid = 0;
        dma_lmem[0].req_data = '0;
        dma_lmem[0].rsp_ready = 1;
        repeat (8) @(negedge clk);
        reset = 0;
        repeat (3) @(negedge clk);
        if (!published) $fatal(1, "Empty LMEM path is not published");

        // Backpressure real DMA read responses to hold a read at bank 0.
        // The CPU store must remain queued behind that read until release.
        block_bank_with_dma_reads();
        issue_cpu(1, `LMEM_BASE_ADDR, 64'h0123456789abcdef, 1, 8'hff);
        if (!bank0_read_stalled) $fatal(1, "CPU store was not admitted behind blocked bank read");
        repeat (12) begin
            @(negedge clk);
            if (published) $fatal(1, "Publication preceded physical CPU store");
            if (commit) $fatal(1, "CPU write was misclassified as DMA commit");
        end
        // The PUBLISH word is the upper half of the 0x28 MMIO beat.
        issue_cpu(0, `DMA_REG_BASE_ADDR + 64'h2c, '0, 0, 8'hf0);
        repeat (12) begin
            @(negedge clk);
            if (lsu[0].rsp_valid) $fatal(1, "PUBLISH returned with a posted CPU store");
        end
        drain_dma_blocker();
        take_response(64'h0000000100000000);
        if (!published || commits != 0)
            $fatal(1, "CPU publication did not drain or source decoding failed");
        issue_cpu(0, `LMEM_BASE_ADDR, '0, 1, 8'hff);
        take_response(64'h0123456789abcdef);

        // DMA stores use the existing requester, but completion must still
        // wait for physical SRAM acceptance rather than requester acceptance.
        hold_cpu_read_responses();
        @(negedge clk);
        dma_order_active = 1;
        dma_lmem[0].req_valid = 1;
        dma_lmem[0].req_data = '0;
        dma_lmem[0].req_data.rw = 1;
        dma_lmem[0].req_data.addr = (`MEM_ADDR_WIDTH-$clog2(LSU_WORD_SIZE))'(`LMEM_BASE_ADDR >> $clog2(LSU_WORD_SIZE));
        dma_lmem[0].req_data.byteen = '1;
        dma_lmem[0].req_data.data = 64'hfedcba9876543210;
        do @(posedge clk); while (!dma_lmem[0].req_ready);
        @(negedge clk);
        dma_lmem[0].req_valid = 0;
        if (dma_accept_count != 1 || dma_physical_count != 0 || dma_commit_count != 0)
            $fatal(1, "Missing requester-to-physical-write pipeline separation");
        drain_cpu_blocker();
        while (commits == 0) @(negedge clk);
        repeat (6) @(negedge clk);
        if (commits != 1) $fatal(1, "DMA physical commit repeated");
        issue_cpu(0, `LMEM_BASE_ADDR, '0, 1, 8'hff);
        take_response(64'hfedcba9876543210);
        if (dma_accept_count != 1 || dma_physical_count != 1 || dma_commit_count != 1
         || !(dma_accept_cycle < dma_physical_cycle && dma_physical_cycle <= dma_commit_cycle))
            $fatal(1, "DMA acceptance/physical write/commit ordering or count mismatch");
        dma_order_active = 0;
        $display("DMA WRITE ORDER PASSED accept=%0d physical=%0d commit=%0d counts=1/1/1",
            dma_accept_cycle, dma_physical_cycle, dma_commit_cycle);
        $display("SRAM LMEM PUBLICATION PASSED");
        $display("OUTPUT CHECK PASSED");
        $finish;
    end
`endif
    initial begin
        #200000;
        $fatal(1, "LMEM publication test timeout");
    end
endmodule
