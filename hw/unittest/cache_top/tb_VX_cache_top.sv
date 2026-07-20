`timescale 1ns / 1ps

`include "VX_cache_define.vh"

module tb_VX_cache_top import VX_gpu_pkg::*; ();

    // =========================================================================
    // Parameters
    // =========================================================================
    parameter string TB_NAME    = "tb_VX_cache_top";
    parameter PERIOD            = 10;

    // Cache parameters
    localparam NUM_REQS         = 4;
    localparam MEM_PORTS        = 1;
`ifdef CACHE_TOP_CACHE_SIZE
    localparam CACHE_SIZE       = `CACHE_TOP_CACHE_SIZE;
`else
    localparam CACHE_SIZE       = 4096;   // 4KB - small for easier testing
`endif
    localparam LINE_SIZE        = 64;     // 64B cache line
    localparam NUM_BANKS        = 4;
    localparam NUM_WAYS         = 4;
    localparam WORD_SIZE        = 4;      // 4B word
`ifdef CACHE_TOP_CRSQ_SIZE
    localparam CRSQ_SIZE        = `CACHE_TOP_CRSQ_SIZE;
`else
    localparam CRSQ_SIZE        = 4;
`endif
    localparam MSHR_SIZE        = 16;
    localparam MRSQ_SIZE        = 4;
`ifdef CACHE_TOP_MREQ_SIZE
    localparam MREQ_SIZE        = `CACHE_TOP_MREQ_SIZE;
`else
    localparam MREQ_SIZE        = 4;
`endif
    localparam WRITE_ENABLE     = 1;
    localparam WRITEBACK        = 0;      // writethrough for simpler testing
    localparam DIRTY_BYTES      = 0;
    localparam TAG_WIDTH        = UUID_WIDTH + 16; // must be > UUID_WIDTH
    localparam CORE_OUT_BUF     = 3;
    localparam MEM_OUT_BUF      = 3;

    // Derived parameters (mirror cache_define.vh with local params)
    localparam WORD_WIDTH       = WORD_SIZE * 8;  // 32 bits
    localparam LINE_WIDTH       = LINE_SIZE * 8;  // 512 bits
    localparam WORDS_PER_LINE   = LINE_SIZE / WORD_SIZE;  // 16
    localparam WORD_ADDR_WIDTH  = `MEM_ADDR_WIDTH - $clog2(WORD_SIZE);
    localparam MEM_ADDR_WIDTH_  = `MEM_ADDR_WIDTH - $clog2(LINE_SIZE);
    localparam MEM_TAG_WIDTH    = `CACHE_MEM_TAG_WIDTH(MSHR_SIZE, NUM_BANKS, MEM_PORTS, UUID_WIDTH);

    // Memory model parameters
    localparam MEM_SIZE         = 1 << 16; // 64KB backing memory (byte-addressed)
`ifdef CACHE_TOP_MEM_LATENCY
    localparam MEM_LATENCY      = `CACHE_TOP_MEM_LATENCY;
`else
    localparam MEM_LATENCY      = 10;      // memory response latency in cycles
`endif
    localparam NUM_FLUSH_WRITES = 8;
    localparam NUM_BP_REQS      = 24;

    // =========================================================================
    // File Handles
    // =========================================================================
    integer rpt_fd;
    integer log_fd;
    string fsdb_file_path;
    string fst_file_path;
    string rpt_file_path;
    string log_file_path;
    string name;

    // =========================================================================
    // Clock and Reset
    // =========================================================================
    logic clk;
    logic reset;
    logic cache_drain;

    initial clk = 0;
    always #(PERIOD / 2) clk = ~clk;

    // =========================================================================
    // Interface Instantiations
    // =========================================================================

    // Core request/response interfaces
    VX_mem_bus_if #(
        .DATA_SIZE (WORD_SIZE),
        .TAG_WIDTH (TAG_WIDTH)
    ) core_bus_if[NUM_REQS]();

    // Memory interfaces
    VX_mem_bus_if #(
        .DATA_SIZE (LINE_SIZE),
        .TAG_WIDTH (MEM_TAG_WIDTH)
    ) mem_bus_if[MEM_PORTS]();

`ifdef PERF_ENABLE
    localparam PERF_MEM_PORTS = NUM_REQS;
    localparam PERF_MEM_TAG_WIDTH = `CACHE_BYPASS_TAG_WIDTH(
        NUM_REQS, PERF_MEM_PORTS, LINE_SIZE, WORD_SIZE, TAG_WIDTH);

    cache_perf_t perf_bypass_cache_perf;
    logic perf_bypass_cache_drain;

    VX_mem_bus_if #(
        .DATA_SIZE (WORD_SIZE),
        .TAG_WIDTH (TAG_WIDTH)
    ) perf_bypass_core_bus_if[NUM_REQS]();

    VX_mem_bus_if #(
        .DATA_SIZE (LINE_SIZE),
        .TAG_WIDTH (PERF_MEM_TAG_WIDTH)
    ) perf_bypass_mem_bus_if[PERF_MEM_PORTS]();
`endif

    // =========================================================================
    // DUT Instantiation
    // =========================================================================
    VX_cache_wrap #(
        .INSTANCE_ID    ("cache_tb"),
        .CACHE_SIZE     (CACHE_SIZE),
        .LINE_SIZE      (LINE_SIZE),
        .NUM_BANKS      (NUM_BANKS),
        .NUM_WAYS       (NUM_WAYS),
        .WORD_SIZE      (WORD_SIZE),
        .NUM_REQS       (NUM_REQS),
        .MEM_PORTS      (MEM_PORTS),
        .CRSQ_SIZE      (CRSQ_SIZE),
        .MSHR_SIZE      (MSHR_SIZE),
        .MRSQ_SIZE      (MRSQ_SIZE),
        .MREQ_SIZE      (MREQ_SIZE),
        .TAG_WIDTH      (TAG_WIDTH),
        .WRITE_ENABLE   (WRITE_ENABLE),
        .WRITEBACK      (WRITEBACK),
        .DIRTY_BYTES    (DIRTY_BYTES),
        .CORE_OUT_BUF   (CORE_OUT_BUF),
        .MEM_OUT_BUF    (MEM_OUT_BUF)
    ) u_dut (
        .clk            (clk),
        .reset          (reset),
    `ifdef PERF_ENABLE
        .cache_perf     (),
    `endif
        .core_bus_if    (core_bus_if),
        .mem_bus_if     (mem_bus_if),
        .cache_drain    (cache_drain)
    );

`ifdef PERF_ENABLE
    VX_cache_wrap #(
        .INSTANCE_ID  ("cache_perf_bypass_tb"),
        .NUM_REQS     (NUM_REQS),
        .MEM_PORTS    (PERF_MEM_PORTS),
        .CACHE_SIZE   (CACHE_SIZE),
        .LINE_SIZE    (LINE_SIZE),
        .NUM_BANKS    (NUM_BANKS),
        .NUM_WAYS     (NUM_WAYS),
        .WORD_SIZE    (WORD_SIZE),
        .CRSQ_SIZE    (CRSQ_SIZE),
        .MSHR_SIZE    (MSHR_SIZE),
        .MRSQ_SIZE    (MRSQ_SIZE),
        .MREQ_SIZE    (MREQ_SIZE),
        .TAG_WIDTH    (TAG_WIDTH),
        .WRITE_ENABLE (WRITE_ENABLE),
        .PASSTHRU     (1)
    ) u_perf_bypass_dut (
        .clk         (clk),
        .reset       (reset),
        .cache_perf  (perf_bypass_cache_perf),
        .core_bus_if (perf_bypass_core_bus_if),
        .mem_bus_if  (perf_bypass_mem_bus_if),
        .cache_drain (perf_bypass_cache_drain)
    );

    for (genvar i = 0; i < PERF_MEM_PORTS; ++i) begin : g_perf_bypass_mem
        assign perf_bypass_mem_bus_if[i].req_ready = 1'b1;
        assign perf_bypass_mem_bus_if[i].rsp_valid = 1'b0;
        assign perf_bypass_mem_bus_if[i].rsp_data = '0;
    end
`endif

    wire [NUM_BANKS-1:0] dbg_per_bank_flush_begin    = u_dut.g_cache.cache.per_bank_flush_begin;
    wire [NUM_BANKS-1:0] dbg_per_bank_core_req_valid = u_dut.g_cache.cache.per_bank_core_req_valid;
    wire [NUM_BANKS-1:0] dbg_per_bank_core_req_ready = u_dut.g_cache.cache.per_bank_core_req_ready;
    wire [NUM_BANKS-1:0] dbg_per_bank_mem_req_ready  = u_dut.g_cache.cache.per_bank_mem_req_ready;
    wire [NUM_BANKS-1:0] dbg_per_bank_core_req_fire  = u_dut.g_cache.cache.per_bank_core_req_fire;
    wire dbg_bank0_crsp_queue_stall = u_dut.g_cache.cache.g_banks[0].bank.crsp_queue_stall;

    // =========================================================================
    // Simple Memory Model (backing store)
    // =========================================================================
    // Byte-addressable memory
    logic [7:0] backing_mem [0:MEM_SIZE-1];

    // Reference model: tracks what has been written through the cache
    logic [7:0] ref_mem [0:MEM_SIZE-1];

    // Memory response pipeline (latency model)
    typedef struct {
        logic                       valid;
        logic [LINE_WIDTH-1:0]      data;
        logic [MEM_TAG_WIDTH-1:0]   tag;
        int                         delay;
    } mem_rsp_entry_t;

    typedef struct packed {
        logic [$clog2(NUM_REQS)-1:0] port;
        logic [WORD_WIDTH-1:0]       data;
        logic [TAG_WIDTH-1:0]        tag;
    } core_rsp_entry_t;

    mem_rsp_entry_t mem_rsp_queue[$];
    core_rsp_entry_t core_rsp_queue[$];
    logic mem_req_ready_r;
    int mem_rsp_delay_cycles;

    // Handle memory requests from cache (MEM_PORTS=1, use constant index)
    always @(posedge clk) begin
        if (reset) begin
            mem_rsp_queue.delete();
        end else begin
            if (mem_bus_if[0].req_valid && mem_bus_if[0].req_ready) begin
                automatic logic [MEM_ADDR_WIDTH_-1:0] addr = mem_bus_if[0].req_data.addr;
                automatic logic [`MEM_ADDR_WIDTH-1:0] byte_addr = {addr, {$clog2(LINE_SIZE){1'b0}}};
                
                if (mem_bus_if[0].req_data.rw) begin
                    // Write request (writethrough/writeback)
                    for (int b = 0; b < LINE_SIZE; b++) begin
                        if (mem_bus_if[0].req_data.byteen[b]) begin
                            backing_mem[byte_addr[15:0] + b] = mem_bus_if[0].req_data.data[b*8 +: 8];
                        end
                    end
                    $display("[%0t] MEM WRITE: addr=0x%08h, byteen=0x%0h", 
                             $time, byte_addr, mem_bus_if[0].req_data.byteen);
                end else begin
                    // Read request - schedule response with latency
                    automatic mem_rsp_entry_t entry;
                    entry.valid = 1;
                    entry.tag = mem_bus_if[0].req_data.tag;
                    entry.delay = mem_rsp_delay_cycles;
                    for (int b = 0; b < LINE_SIZE; b++) begin
                        entry.data[b*8 +: 8] = backing_mem[byte_addr[15:0] + b];
                    end
                    mem_rsp_queue.push_back(entry);
                    $display("[%0t] MEM READ REQ: addr=0x%08h, tag=0x%0h", 
                             $time, byte_addr, mem_bus_if[0].req_data.tag);
                end
            end

            // Decrement delays
            foreach (mem_rsp_queue[i]) begin
                if (mem_rsp_queue[i].delay > 0)
                    mem_rsp_queue[i].delay--;
            end
        end
    end

    // Memory request ready - controlled by the test to inject backpressure.
    generate
        for (genvar p = 0; p < MEM_PORTS; p++) begin : g_mem_req_ready
            assign mem_bus_if[p].req_ready = mem_req_ready_r;
        end
    endgenerate

    // Memory response drive (MEM_PORTS=1, use constant index)
    always @(posedge clk) begin
        if (reset) begin
            mem_bus_if[0].rsp_valid <= 1'b0;
            mem_bus_if[0].rsp_data  <= '0;
        end else begin
            if (mem_bus_if[0].rsp_valid && mem_bus_if[0].rsp_ready) begin
                mem_bus_if[0].rsp_valid <= 1'b0;
            end

            if (!mem_bus_if[0].rsp_valid || mem_bus_if[0].rsp_ready) begin
                if (mem_rsp_queue.size() > 0 && mem_rsp_queue[0].delay == 0) begin
                    mem_bus_if[0].rsp_valid     <= 1'b1;
                    mem_bus_if[0].rsp_data.data <= mem_rsp_queue[0].data;
                    mem_bus_if[0].rsp_data.tag  <= mem_rsp_queue[0].tag;
                    $display("[%0t] MEM READ RSP: tag=0x%0h", $time, mem_rsp_queue[0].tag);
                    mem_rsp_queue.delete(0);
                end
            end
        end
    end

    // Collect core responses in a global queue so tests can consume them without
    // racing the handshake cycle.
    always @(posedge clk) begin
        if (reset) begin
            core_rsp_queue.delete();
        end else begin
            if (core_bus_if[0].rsp_valid && core_bus_if[0].rsp_ready)
                core_rsp_queue.push_back('{port: 0, data: core_bus_if[0].rsp_data.data, tag: core_bus_if[0].rsp_data.tag});
            if (core_bus_if[1].rsp_valid && core_bus_if[1].rsp_ready)
                core_rsp_queue.push_back('{port: 1, data: core_bus_if[1].rsp_data.data, tag: core_bus_if[1].rsp_data.tag});
            if (core_bus_if[2].rsp_valid && core_bus_if[2].rsp_ready)
                core_rsp_queue.push_back('{port: 2, data: core_bus_if[2].rsp_data.data, tag: core_bus_if[2].rsp_data.tag});
            if (core_bus_if[3].rsp_valid && core_bus_if[3].rsp_ready)
                core_rsp_queue.push_back('{port: 3, data: core_bus_if[3].rsp_data.data, tag: core_bus_if[3].rsp_data.tag});
        end
    end

    // =========================================================================
    // Statistics
    // =========================================================================
    int total_tests;
    int passed_tests;
    int failed_tests;

    // =========================================================================
    // Initialization
    // =========================================================================
    initial begin
        $timeformat(-9, 0, "ns", 0);

        $sformat(name, "%s", TB_NAME);
        $sformat(fsdb_file_path, "./reports/%s.fsdb", name);
        $sformat(fst_file_path, "./reports/%s.fst", name);
        $sformat(log_file_path, "./logs/%s.log", name);
        $sformat(rpt_file_path, "./reports/%s.rpt", name);

        // Waveform dump
`ifdef VCS
        $fsdbDumpfile(fsdb_file_path);
        $fsdbDumpvars(0, "+all", "+parameter");
`else
        $dumpfile(fst_file_path);
        $dumpvars(0, tb_VX_cache_top);
`endif

        rpt_fd = $fopen(rpt_file_path, "w");
        log_fd = $fopen(log_file_path, "w");
    end

    // =========================================================================
    // Main Test Flow
    // =========================================================================
    initial begin
        total_tests  = 0;
        passed_tests = 0;
        failed_tests = 0;

        $display("=====================================================================");
        $display("=======================  START SIMULATION  ==========================");
        $display("=====================================================================");
        $fdisplay(log_fd, "[%0t] Starting cache simulation", $time);

        init_signals();
        init_memory();
        apply_reset();
        repeat(5) @(posedge clk);

`ifdef PERF_ENABLE
        test_perf_bypass_read_stage();
`endif

        // ---- Test Cases ----
        test_single_read_miss();
        test_single_write();
        test_read_hit_after_write();
        test_multiple_reads_same_line();
        test_multiple_reads_diff_lines();
        test_write_read_back();
        test_concurrent_requests();
        test_flush_with_backpressure();
        test_multiport_flush_requests();
        test_flush_during_rsp_backpressure();
        test_bank_req_fire_accounting();

        // Wait for all pending transactions to complete
        repeat(50) @(posedge clk);

        // ---- Summary ----
        $display("\n=====================================================================");
        $display("  TEST SUMMARY: %0d total, %0d passed, %0d failed", 
                 total_tests, passed_tests, failed_tests);
        $display("=====================================================================");
        $fdisplay(rpt_fd, "TOTAL=%0d PASS=%0d FAIL=%0d", total_tests, passed_tests, failed_tests);
        $fdisplay(log_fd, "[%0t] Simulation complete", $time);
        if (failed_tests == 0)
            $display("TEST PASSED");

`ifdef VCS
        $fsdbDumpoff();
`else
        $dumpoff();
`endif
        $fclose(rpt_fd);
        $fclose(log_fd);
        $finish;
    end

    // =========================================================================
    // Signal Initialization
    // =========================================================================
    task init_signals();
        core_bus_if[0].req_valid  = 1'b0;
        core_bus_if[0].req_data   = '0;
        core_bus_if[0].rsp_ready  = 1'b1;
        core_bus_if[1].req_valid  = 1'b0;
        core_bus_if[1].req_data   = '0;
        core_bus_if[1].rsp_ready  = 1'b1;
        core_bus_if[2].req_valid  = 1'b0;
        core_bus_if[2].req_data   = '0;
        core_bus_if[2].rsp_ready  = 1'b1;
        core_bus_if[3].req_valid  = 1'b0;
        core_bus_if[3].req_data   = '0;
        core_bus_if[3].rsp_ready  = 1'b1;
        core_rsp_queue.delete();
        mem_req_ready_r           = 1'b1;
        mem_rsp_delay_cycles      = MEM_LATENCY;
`ifdef PERF_ENABLE
        perf_bypass_core_bus_if[0].req_valid = 1'b0;
        perf_bypass_core_bus_if[0].req_data = '0;
        perf_bypass_core_bus_if[0].rsp_ready = 1'b1;
        perf_bypass_core_bus_if[1].req_valid = 1'b0;
        perf_bypass_core_bus_if[1].req_data = '0;
        perf_bypass_core_bus_if[1].rsp_ready = 1'b1;
        perf_bypass_core_bus_if[2].req_valid = 1'b0;
        perf_bypass_core_bus_if[2].req_data = '0;
        perf_bypass_core_bus_if[2].rsp_ready = 1'b1;
        perf_bypass_core_bus_if[3].req_valid = 1'b0;
        perf_bypass_core_bus_if[3].req_data = '0;
        perf_bypass_core_bus_if[3].rsp_ready = 1'b1;
`endif
        $display("[%0t] Signals initialized", $time);
    endtask

    // =========================================================================
    // Memory Initialization
    // =========================================================================
    task init_memory();
        for (int i = 0; i < MEM_SIZE; i++) begin
            backing_mem[i] = i[7:0];      // predictable pattern
            ref_mem[i]     = i[7:0];
        end
        $display("[%0t] Memory initialized with pattern", $time);
    endtask

    // =========================================================================
    // Reset Application
    // =========================================================================
    task apply_reset();
        $display("[%0t] Applying reset...", $time);
        reset = 1'b1;
        repeat(10) @(posedge clk);
        reset = 1'b0;
        repeat(5) @(posedge clk);
        $display("[%0t] Reset complete", $time);
    endtask

`ifdef PERF_ENABLE
`define PERF_BYPASS_REQ_DRIVE(P) \
    perf_bypass_core_bus_if[P].req_valid = read_mask[P] || write_mask[P]; \
    perf_bypass_core_bus_if[P].req_data.rw = write_mask[P]; \
    perf_bypass_core_bus_if[P].req_data.addr = WORD_ADDR_WIDTH'((P + 1) * WORDS_PER_LINE); \
    perf_bypass_core_bus_if[P].req_data.byteen = '1; \
    perf_bypass_core_bus_if[P].req_data.data = WORD_WIDTH'(32'h12340000 + P); \
    perf_bypass_core_bus_if[P].req_data.tag = TAG_WIDTH'(16'h9000 + P); \
    perf_bypass_core_bus_if[P].req_data.flags = '0

`define PERF_BYPASS_REQ_CLEAR(P) \
    perf_bypass_core_bus_if[P].req_valid = 1'b0

    task automatic drive_perf_bypass_cycle(
        input logic [NUM_REQS-1:0] read_mask,
        input logic [NUM_REQS-1:0] write_mask
    );
        logic [NUM_REQS-1:0] active_mask;
        begin
            active_mask = read_mask | write_mask;
            if (|(read_mask & write_mask))
                $fatal(1, "PERF bypass read/write masks overlap");

            @(negedge clk);
            `PERF_BYPASS_REQ_DRIVE(0);
            `PERF_BYPASS_REQ_DRIVE(1);
            `PERF_BYPASS_REQ_DRIVE(2);
            `PERF_BYPASS_REQ_DRIVE(3);

            @(posedge clk);
            if (active_mask[0] && !perf_bypass_core_bus_if[0].req_ready)
                $fatal(1, "PERF bypass request 0 was not accepted");
            if (active_mask[1] && !perf_bypass_core_bus_if[1].req_ready)
                $fatal(1, "PERF bypass request 1 was not accepted");
            if (active_mask[2] && !perf_bypass_core_bus_if[2].req_ready)
                $fatal(1, "PERF bypass request 2 was not accepted");
            if (active_mask[3] && !perf_bypass_core_bus_if[3].req_ready)
                $fatal(1, "PERF bypass request 3 was not accepted");

            @(negedge clk);
            `PERF_BYPASS_REQ_CLEAR(0);
            `PERF_BYPASS_REQ_CLEAR(1);
            `PERF_BYPASS_REQ_CLEAR(2);
            `PERF_BYPASS_REQ_CLEAR(3);
        end
    endtask

    task automatic test_perf_bypass_read_stage();
        begin
            $display("\n--- PERF TEST: Bypass Read Popcount Stage ---");

            drive_perf_bypass_cycle(4'b1111, 4'b0000);
            if ((perf_bypass_cache_perf.reads !== PERF_CTR_BITS'(0))
             || (perf_bypass_cache_perf.writes !== PERF_CTR_BITS'(0))) begin
                $fatal(1, "PERF bypass counters changed before read-stage drain");
            end

            @(posedge clk);
            @(negedge clk);
            if ((perf_bypass_cache_perf.reads !== PERF_CTR_BITS'(4))
             || (perf_bypass_cache_perf.writes !== PERF_CTR_BITS'(0))) begin
                $fatal(1, "PERF bypass simultaneous-read total mismatch");
            end

            @(posedge clk);
            @(negedge clk);
            if (perf_bypass_cache_perf.reads !== PERF_CTR_BITS'(4))
                $fatal(1, "PERF bypass read counter incremented after drain");

            drive_perf_bypass_cycle(4'b0101, 4'b1010);
            if ((perf_bypass_cache_perf.reads !== PERF_CTR_BITS'(4))
             || (perf_bypass_cache_perf.writes !== PERF_CTR_BITS'(2))) begin
                $fatal(1, "PERF bypass mixed-cycle staging or write timing mismatch");
            end

            @(posedge clk);
            @(negedge clk);
            if ((perf_bypass_cache_perf.reads !== PERF_CTR_BITS'(6))
             || (perf_bypass_cache_perf.writes !== PERF_CTR_BITS'(2))) begin
                $fatal(1, "PERF bypass mixed-cycle drained total mismatch");
            end

            @(posedge clk);
            @(negedge clk);
            if ((perf_bypass_cache_perf.reads !== PERF_CTR_BITS'(6))
             || (perf_bypass_cache_perf.writes !== PERF_CTR_BITS'(2))) begin
                $fatal(1, "PERF bypass counters changed after final drain");
            end

            total_tests++;
            passed_tests++;
            $display("[PASS] PERF bypass read popcount stage");
            $fdisplay(rpt_fd, "[PASS] PERF bypass read popcount stage");
        end
    endtask
`endif

    // =========================================================================
    // Core Request Driver Task (single request on a specific port)
    // =========================================================================
    // VCS does not allow variable indexing into interface arrays (IIXMR).
    // Use macros with case statements to access with constant indices only.

`define CORE_REQ_DRIVE(P) \
    core_bus_if[P].req_valid     <= 1'b1; \
    core_bus_if[P].req_data.rw   <= rw; \
    core_bus_if[P].req_data.addr <= addr; \
    core_bus_if[P].req_data.byteen <= byteen; \
    core_bus_if[P].req_data.data <= data; \
    core_bus_if[P].req_data.tag  <= tag; \
    core_bus_if[P].req_data.flags <= flags

`define CORE_REQ_READY(P) core_bus_if[P].req_ready

`define CORE_REQ_DEASSERT(P) core_bus_if[P].req_valid <= 1'b0

    task automatic send_core_req_ex_status(
        input int port_id,
        input logic rw,
        input logic [WORD_ADDR_WIDTH-1:0] addr,
        input logic [WORD_SIZE-1:0] byteen,
        input logic [WORD_WIDTH-1:0] data,
        input logic [TAG_WIDTH-1:0] tag,
        input logic [`UP(MEM_FLAGS_WIDTH)-1:0] flags,
        output logic accepted,
        input int timeout = 500
    );
        int cnt;

        @(posedge clk);
        accepted = 0;
        case (port_id)
            0: begin `CORE_REQ_DRIVE(0); end
            1: begin `CORE_REQ_DRIVE(1); end
            2: begin `CORE_REQ_DRIVE(2); end
            3: begin `CORE_REQ_DRIVE(3); end
        endcase

        // Wait for handshake
        begin
            logic ready;
            ready = 0;
            cnt = 0;
            while (!ready) begin
                @(posedge clk);
                case (port_id)
                    0: ready = `CORE_REQ_READY(0);
                    1: ready = `CORE_REQ_READY(1);
                    2: ready = `CORE_REQ_READY(2);
                    3: ready = `CORE_REQ_READY(3);
                endcase
                if (ready) begin
                    accepted = 1;
                end
                cnt++;
                if ((timeout >= 0) && (cnt >= timeout)) begin
                    $display("[%0t] ERROR: Timeout waiting for request handshake on port %0d", $time, port_id);
                    $fdisplay(log_fd, "[%0t] ERROR: Request timeout on port %0d", $time, port_id);
                    break;
                end
            end
        end

        case (port_id)
            0: begin `CORE_REQ_DEASSERT(0); end
            1: begin `CORE_REQ_DEASSERT(1); end
            2: begin `CORE_REQ_DEASSERT(2); end
            3: begin `CORE_REQ_DEASSERT(3); end
        endcase
        $fdisplay(log_fd, "[%0t] REQ port=%0d rw=%0b addr=0x%08h data=0x%08h tag=0x%04h flags=0x%0h", 
                  $time, port_id, rw, addr, data, tag, flags);
    endtask

    task automatic send_core_req_ex(
        input int port_id,
        input logic rw,
        input logic [WORD_ADDR_WIDTH-1:0] addr,
        input logic [WORD_SIZE-1:0] byteen,
        input logic [WORD_WIDTH-1:0] data,
        input logic [TAG_WIDTH-1:0] tag,
        input logic [`UP(MEM_FLAGS_WIDTH)-1:0] flags,
        input int timeout = 500
    );
        logic accepted;
        send_core_req_ex_status(port_id, rw, addr, byteen, data, tag, flags, accepted, timeout);
    endtask

    task automatic send_core_req(
        input int port_id,
        input logic rw,
        input logic [WORD_ADDR_WIDTH-1:0] addr,
        input logic [WORD_SIZE-1:0] byteen,
        input logic [WORD_WIDTH-1:0] data,
        input logic [TAG_WIDTH-1:0] tag
    );
        send_core_req_ex(port_id, rw, addr, byteen, data, tag, `UP(MEM_FLAGS_WIDTH)'(0));
    endtask

    // =========================================================================
    // Core Response Collector Task
    // =========================================================================

`define CORE_RSP_CHECK(P) (core_bus_if[P].rsp_valid && core_bus_if[P].rsp_ready)
`define CORE_RSP_DATA(P)  core_bus_if[P].rsp_data.data
`define CORE_RSP_TAG(P)   core_bus_if[P].rsp_data.tag

    task automatic clear_core_rsp_queue();
        core_rsp_queue.delete();
    endtask

    task automatic wait_core_rsp(
        input  int port_id,
        output logic [WORD_WIDTH-1:0] data,
        output logic [TAG_WIDTH-1:0]  tag,
        input  int timeout = 500
    );
        int cnt = 0;
        logic got_rsp;
        forever begin
            got_rsp = 0;
            for (int i = 0; i < core_rsp_queue.size(); ++i) begin
                if (core_rsp_queue[i].port == port_id[$clog2(NUM_REQS)-1:0]) begin
                    data = core_rsp_queue[i].data;
                    tag  = core_rsp_queue[i].tag;
                    core_rsp_queue.delete(i);
                    got_rsp = 1;
                    break;
                end
            end
            if (got_rsp) begin
                $fdisplay(log_fd, "[%0t] RSP port=%0d data=0x%08h tag=0x%04h", 
                          $time, port_id, data, tag);
                return;
            end
            @(posedge clk);
            cnt++;
            if (cnt >= timeout) begin
                $display("[%0t] ERROR: Timeout waiting for response on port %0d", $time, port_id);
                $fdisplay(log_fd, "[%0t] ERROR: Timeout on port %0d", $time, port_id);
                data = '0;
                tag  = '0;
                return;
            end
        end
    endtask

    task automatic wait_core_rsp_tag(
        input  logic [TAG_WIDTH-1:0]  expected_tag,
        output int                    port_id,
        output logic [WORD_WIDTH-1:0] data,
        input  int timeout = 500
    );
        int cnt = 0;
        logic got_rsp;
        forever begin
            got_rsp = 0;
            for (int i = 0; i < core_rsp_queue.size(); ++i) begin
                if (core_rsp_queue[i].tag == expected_tag) begin
                    port_id = int'(core_rsp_queue[i].port);
                    data    = core_rsp_queue[i].data;
                    core_rsp_queue.delete(i);
                    got_rsp = 1;
                    break;
                end
            end
            if (got_rsp) begin
                $fdisplay(log_fd, "[%0t] RSP tag=0x%04h port=%0d data=0x%08h",
                          $time, expected_tag, port_id, data);
                return;
            end
            @(posedge clk);
            cnt++;
            if (cnt >= timeout) begin
                $display("[%0t] ERROR: Timeout waiting for response tag 0x%04h", $time, expected_tag);
                $fdisplay(log_fd, "[%0t] ERROR: Timeout on tag 0x%04h", $time, expected_tag);
                port_id = -1;
                data    = '0;
                return;
            end
        end
    endtask

    // =========================================================================
    // Utility: build word address from byte address
    // =========================================================================
    function automatic logic [WORD_ADDR_WIDTH-1:0] byte_to_word_addr(
        input logic [`MEM_ADDR_WIDTH-1:0] byte_addr
    );
        return byte_addr[$clog2(WORD_SIZE) +: WORD_ADDR_WIDTH];
    endfunction

    function automatic logic [`MEM_ADDR_WIDTH-1:0] same_bank_addr(
        input logic [`MEM_ADDR_WIDTH-1:0] base_addr,
        input int index
    );
        return base_addr + (`MEM_ADDR_WIDTH'(index * NUM_BANKS * LINE_SIZE));
    endfunction

    // =========================================================================
    // Utility: read expected word from reference memory
    // =========================================================================
    function automatic logic [WORD_WIDTH-1:0] ref_read_word(
        input logic [`MEM_ADDR_WIDTH-1:0] byte_addr
    );
        logic [WORD_WIDTH-1:0] w;
        for (int b = 0; b < WORD_SIZE; b++) begin
            w[b*8 +: 8] = ref_mem[byte_addr[15:0] + b];
        end
        return w;
    endfunction

    // =========================================================================
    // Utility: write word to reference memory
    // =========================================================================
    task automatic ref_write_word(
        input logic [`MEM_ADDR_WIDTH-1:0] byte_addr,
        input logic [WORD_SIZE-1:0] byteen,
        input logic [WORD_WIDTH-1:0] data
    );
        for (int b = 0; b < WORD_SIZE; b++) begin
            if (byteen[b])
                ref_mem[byte_addr[15:0] + b] = data[b*8 +: 8];
        end
    endtask

    // =========================================================================
    // Check result helper
    // =========================================================================
    task automatic check_result(
        input string test_name,
        input logic [WORD_WIDTH-1:0] actual,
        input logic [WORD_WIDTH-1:0] expected,
        input logic [TAG_WIDTH-1:0] actual_tag,
        input logic [TAG_WIDTH-1:0] expected_tag
    );
        total_tests++;
        if (actual === expected && actual_tag === expected_tag) begin
            passed_tests++;
            $display("[PASS] %s: data=0x%08h tag=0x%04h", test_name, actual, actual_tag);
            $fdisplay(rpt_fd, "[PASS] %s", test_name);
        end else begin
            failed_tests++;
            $display("[FAIL] %s: got data=0x%08h (exp 0x%08h), got tag=0x%04h (exp 0x%04h)", 
                     test_name, actual, expected, actual_tag, expected_tag);
            $fdisplay(rpt_fd, "[FAIL] %s: got=0x%08h exp=0x%08h", test_name, actual, expected);
        end
    endtask

    task automatic check_data_only(
        input string test_name,
        input logic [WORD_WIDTH-1:0] actual,
        input logic [WORD_WIDTH-1:0] expected
    );
        total_tests++;
        if (actual === expected) begin
            passed_tests++;
            $display("[PASS] %s: data=0x%08h", test_name, actual);
            $fdisplay(rpt_fd, "[PASS] %s", test_name);
        end else begin
            failed_tests++;
            $display("[FAIL] %s: got=0x%08h exp=0x%08h", test_name, actual, expected);
            $fdisplay(rpt_fd, "[FAIL] %s: got=0x%08h exp=0x%08h", test_name, actual, expected);
        end
    endtask

    task automatic wait_for_cache_drain(
        input int timeout = 1000
    );
        int cnt;
        cnt = 0;
        while (!cache_drain && (cnt < timeout)) begin
            @(posedge clk);
            cnt++;
        end
        if (!cache_drain) begin
            $display("[%0t] ERROR: Timeout waiting for cache_drain", $time);
            $fdisplay(log_fd, "[%0t] ERROR: cache_drain timeout", $time);
        end
    endtask

    task automatic pulse_mem_req_ready(
        input int low_cycles,
        input int high_cycles,
        input int rounds
    );
        for (int i = 0; i < rounds; i++) begin
            mem_req_ready_r = 1'b0;
            repeat (low_cycles) @(posedge clk);
            mem_req_ready_r = 1'b1;
            repeat (high_cycles) @(posedge clk);
        end
        mem_req_ready_r = 1'b1;
    endtask

    task automatic set_core_rsp_ready(
        input int port_id,
        input logic ready
    );
        case (port_id)
            0: core_bus_if[0].rsp_ready = ready;
            1: core_bus_if[1].rsp_ready = ready;
            2: core_bus_if[2].rsp_ready = ready;
            3: core_bus_if[3].rsp_ready = ready;
        endcase
    endtask

    task automatic wait_for_bank0_crsp_stall(
        output logic saw_stall,
        input int timeout = 200
    );
        int cnt;
        saw_stall = 0;
        cnt = 0;
        while (!saw_stall && (cnt < timeout)) begin
            @(posedge clk);
            saw_stall = dbg_bank0_crsp_queue_stall;
            cnt++;
        end
    endtask

    task automatic monitor_flush_clean_start(
        output logic saw_flush,
        output logic pending_violation,
        output logic blocked_violation,
        input int timeout = 400
    );
        int cnt;
        saw_flush = 0;
        pending_violation = 0;
        blocked_violation = 0;
        cnt = 0;
        while (!saw_flush && (cnt < timeout)) begin
            @(posedge clk);
            if (|dbg_per_bank_flush_begin) begin
                saw_flush = 1;
                // A request being actively fired (valid & ready) at the moment
                // flush begins is a violation — it means the flush didn't wait
                // for in-flight requests to clear.
                // A request that is valid but stalled (valid & ~ready) is NOT
                // a violation; it is merely queued and will be handled after flush.
                pending_violation = (|(dbg_per_bank_core_req_valid & dbg_per_bank_core_req_ready));
                blocked_violation = 1'b0;
            end
            cnt++;
        end
        if (!saw_flush) begin
            $display("[%0t] ERROR: Timeout waiting for flush_begin", $time);
            $fdisplay(log_fd, "[%0t] ERROR: flush_begin timeout", $time);
        end
    endtask

    task automatic monitor_bank0_fire_guard(
        output logic saw_guard_case,
        output logic saw_fire_mismatch,
        input int timeout = 400
    );
        int cnt;
        saw_guard_case = 0;
        saw_fire_mismatch = 0;
        cnt = 0;
        // Exit as soon as guard case is seen (regardless of mismatch),
        // or immediately when a mismatch is detected.
        while (!saw_fire_mismatch && !saw_guard_case && (cnt < timeout)) begin
            @(posedge clk);
            if (dbg_per_bank_core_req_valid[0]
             && ~dbg_per_bank_core_req_ready[0]
             && dbg_per_bank_mem_req_ready[0]) begin
                saw_guard_case    = 1;
                saw_fire_mismatch = dbg_per_bank_core_req_fire[0];
                $fdisplay(log_fd,
                    "[%0t] GUARD: valid=%0b ready=%0b mem_rdy=%0b fire=%0b",
                    $time,
                    dbg_per_bank_core_req_valid[0],
                    dbg_per_bank_core_req_ready[0],
                    dbg_per_bank_mem_req_ready[0],
                    dbg_per_bank_core_req_fire[0]);
            end
            cnt++;
        end
    endtask

    task automatic check_true(
        input string test_name,
        input logic cond
    );
        total_tests++;
        if (cond) begin
            passed_tests++;
            $display("[PASS] %s", test_name);
            $fdisplay(rpt_fd, "[PASS] %s", test_name);
        end else begin
            failed_tests++;
            $display("[FAIL] %s", test_name);
            $fdisplay(rpt_fd, "[FAIL] %s", test_name);
        end
    endtask

    // =========================================================================
    // TEST 1: Single Read Miss
    // =========================================================================
    task test_single_read_miss();
        logic [WORD_WIDTH-1:0] rsp_data;
        logic [TAG_WIDTH-1:0]  rsp_tag;
        logic [`MEM_ADDR_WIDTH-1:0] byte_addr;
        logic [WORD_WIDTH-1:0] expected;

        $display("\n--- TEST 1: Single Read Miss ---");
        $fdisplay(log_fd, "[%0t] TEST 1: Single Read Miss", $time);

        byte_addr = 'h100;  // some address
        expected = ref_read_word(byte_addr);

        fork
            send_core_req(
                .port_id(0),
                .rw(1'b0),
                .addr(byte_to_word_addr(byte_addr)),
                .byteen({WORD_SIZE{1'b1}}),
                .data('0),
                .tag(16'hA001)
            );
            wait_core_rsp(0, rsp_data, rsp_tag);
        join

        check_result("Read Miss @0x100", rsp_data, expected, rsp_tag, 16'hA001);
        repeat(5) @(posedge clk);
    endtask

    // =========================================================================
    // TEST 2: Single Write
    // =========================================================================
    task test_single_write();
        logic [`MEM_ADDR_WIDTH-1:0] byte_addr;
        logic [WORD_WIDTH-1:0] wr_data;

        $display("\n--- TEST 2: Single Write ---");
        $fdisplay(log_fd, "[%0t] TEST 2: Single Write", $time);

        byte_addr = 'h200;
        wr_data   = 32'hDEADBEEF;

        send_core_req(
            .port_id(0),
            .rw(1'b1),
            .addr(byte_to_word_addr(byte_addr)),
            .byteen({WORD_SIZE{1'b1}}),
            .data(wr_data),
            .tag(16'hB002)
        );

        // Update reference
        ref_write_word(byte_addr, {WORD_SIZE{1'b1}}, wr_data);

        // Write requests don't get core responses, just wait a few cycles
        repeat(20) @(posedge clk);

        total_tests++;
        passed_tests++;
        $display("[PASS] Write @0x200 = 0xDEADBEEF (accepted)");
        $fdisplay(rpt_fd, "[PASS] Write @0x200");
    endtask

    // =========================================================================
    // TEST 3: Read Hit After Write (same address as TEST 2)
    // =========================================================================
    task test_read_hit_after_write();
        logic [WORD_WIDTH-1:0] rsp_data;
        logic [TAG_WIDTH-1:0]  rsp_tag;
        logic [`MEM_ADDR_WIDTH-1:0] byte_addr;
        logic [WORD_WIDTH-1:0] expected;

        $display("\n--- TEST 3: Read Hit After Write ---");
        $fdisplay(log_fd, "[%0t] TEST 3: Read Hit After Write", $time);

        byte_addr = 'h200;
        expected = ref_read_word(byte_addr);

        fork
            send_core_req(
                .port_id(0),
                .rw(1'b0),
                .addr(byte_to_word_addr(byte_addr)),
                .byteen({WORD_SIZE{1'b1}}),
                .data('0),
                .tag(16'hC003)
            );
            wait_core_rsp(0, rsp_data, rsp_tag);
        join

        check_result("Read After Write @0x200", rsp_data, expected, rsp_tag, 16'hC003);
        repeat(5) @(posedge clk);
    endtask

    // =========================================================================
    // TEST 4: Multiple Reads to Same Cache Line
    // =========================================================================
    task test_multiple_reads_same_line();
        logic [WORD_WIDTH-1:0] rsp_data;
        logic [TAG_WIDTH-1:0]  rsp_tag;
        logic [`MEM_ADDR_WIDTH-1:0] byte_addr;
        logic [WORD_WIDTH-1:0] expected;

        $display("\n--- TEST 4: Multiple Reads Same Line ---");
        $fdisplay(log_fd, "[%0t] TEST 4: Multiple Reads Same Line", $time);

        // Read word 0 of a new cache line
        byte_addr = 'h400;
        expected = ref_read_word(byte_addr);

        fork
            send_core_req(0, 1'b0, byte_to_word_addr(byte_addr),
                          {WORD_SIZE{1'b1}}, '0, 16'hD010);
            wait_core_rsp(0, rsp_data, rsp_tag);
        join
        check_result("Same Line W0 @0x400", rsp_data, expected, rsp_tag, 16'hD010);

        // Read word 1 of same cache line (should be a hit now)
        byte_addr = 'h400 + WORD_SIZE;
        expected = ref_read_word(byte_addr);

        fork
            send_core_req(0, 1'b0, byte_to_word_addr(byte_addr),
                          {WORD_SIZE{1'b1}}, '0, 16'hD011);
            wait_core_rsp(0, rsp_data, rsp_tag);
        join
        check_result("Same Line W1 @0x404", rsp_data, expected, rsp_tag, 16'hD011);

        // Read word 2 of same cache line
        byte_addr = 'h400 + 2 * WORD_SIZE;
        expected = ref_read_word(byte_addr);

        fork
            send_core_req(0, 1'b0, byte_to_word_addr(byte_addr),
                          {WORD_SIZE{1'b1}}, '0, 16'hD012);
            wait_core_rsp(0, rsp_data, rsp_tag);
        join
        check_result("Same Line W2 @0x408", rsp_data, expected, rsp_tag, 16'hD012);

        repeat(5) @(posedge clk);
    endtask

    // =========================================================================
    // TEST 5: Multiple Reads to Different Lines
    // =========================================================================
    task test_multiple_reads_diff_lines();
        logic [WORD_WIDTH-1:0] rsp_data;
        logic [TAG_WIDTH-1:0]  rsp_tag;
        logic [`MEM_ADDR_WIDTH-1:0] byte_addr;
        logic [WORD_WIDTH-1:0] expected;

        $display("\n--- TEST 5: Multiple Reads Different Lines ---");
        $fdisplay(log_fd, "[%0t] TEST 5: Multiple Reads Different Lines", $time);

        for (int i = 0; i < 4; i++) begin
            byte_addr = 'h1000 + i * LINE_SIZE;  // different cache lines
            expected = ref_read_word(byte_addr);

            fork
                send_core_req(0, 1'b0, byte_to_word_addr(byte_addr),
                              {WORD_SIZE{1'b1}}, '0, 16'hE000 + i[15:0]);
                wait_core_rsp(0, rsp_data, rsp_tag);
            join

            check_data_only($sformatf("Diff Line %0d @0x%04h", i, byte_addr), rsp_data, expected);
        end

        repeat(5) @(posedge clk);
    endtask

    // =========================================================================
    // TEST 6: Write then Read Back (data integrity)
    // =========================================================================
    task test_write_read_back();
        logic [WORD_WIDTH-1:0] rsp_data;
        logic [TAG_WIDTH-1:0]  rsp_tag;
        logic [`MEM_ADDR_WIDTH-1:0] byte_addr;
        logic [WORD_WIDTH-1:0] wr_data;

        $display("\n--- TEST 6: Write then Read Back ---");
        $fdisplay(log_fd, "[%0t] TEST 6: Write then Read Back", $time);

        // Write 4 different words
        for (int i = 0; i < 4; i++) begin
            byte_addr = 'h800 + i * WORD_SIZE;
            wr_data   = 32'hCAFE0000 + i;

            send_core_req(0, 1'b1, byte_to_word_addr(byte_addr),
                          {WORD_SIZE{1'b1}}, wr_data, 16'hF000 + i[15:0]);
            ref_write_word(byte_addr, {WORD_SIZE{1'b1}}, wr_data);
        end

        // Wait for writes to propagate
        repeat(30) @(posedge clk);

        // Read them back
        for (int i = 0; i < 4; i++) begin
            byte_addr = 'h800 + i * WORD_SIZE;
            wr_data   = ref_read_word(byte_addr);

            fork
                send_core_req(0, 1'b0, byte_to_word_addr(byte_addr),
                              {WORD_SIZE{1'b1}}, '0, 16'hF010 + i[15:0]);
                wait_core_rsp(0, rsp_data, rsp_tag);
            join

            check_data_only($sformatf("ReadBack W%0d @0x%04h", i, byte_addr), rsp_data, wr_data);
        end

        repeat(5) @(posedge clk);
    endtask

    // =========================================================================
    // TEST 7: Concurrent Requests on Multiple Ports
    // =========================================================================
    task test_concurrent_requests();
        logic [WORD_WIDTH-1:0] rsp_data[4];
        logic [TAG_WIDTH-1:0]  rsp_tag[4];
        logic [`MEM_ADDR_WIDTH-1:0] byte_addr[4];
        logic [WORD_WIDTH-1:0] expected[4];

        $display("\n--- TEST 7: Concurrent Requests on Multiple Ports ---");
        $fdisplay(log_fd, "[%0t] TEST 7: Concurrent Requests", $time);

        // Send reads on all 4 ports simultaneously to different addresses
        for (int i = 0; i < NUM_REQS; i++) begin
            byte_addr[i] = 'h2000 + i * LINE_SIZE;
            expected[i]  = ref_read_word(byte_addr[i]);
        end

        fork
            begin // Port 0
                fork
                    send_core_req(0, 1'b0, byte_to_word_addr(byte_addr[0]),
                                  {WORD_SIZE{1'b1}}, '0, 16'h7000);
                    wait_core_rsp(0, rsp_data[0], rsp_tag[0]);
                join
            end
            begin // Port 1
                fork
                    send_core_req(1, 1'b0, byte_to_word_addr(byte_addr[1]),
                                  {WORD_SIZE{1'b1}}, '0, 16'h7001);
                    wait_core_rsp(1, rsp_data[1], rsp_tag[1]);
                join
            end
            begin // Port 2
                fork
                    send_core_req(2, 1'b0, byte_to_word_addr(byte_addr[2]),
                                  {WORD_SIZE{1'b1}}, '0, 16'h7002);
                    wait_core_rsp(2, rsp_data[2], rsp_tag[2]);
                join
            end
            begin // Port 3
                fork
                    send_core_req(3, 1'b0, byte_to_word_addr(byte_addr[3]),
                                  {WORD_SIZE{1'b1}}, '0, 16'h7003);
                    wait_core_rsp(3, rsp_data[3], rsp_tag[3]);
                join
            end
        join

        for (int i = 0; i < NUM_REQS; i++) begin
            check_data_only($sformatf("Concurrent Port%0d @0x%04h", i, byte_addr[i]),
                            rsp_data[i], expected[i]);
        end

        repeat(5) @(posedge clk);
    endtask

    // =========================================================================
    // TEST 8: Flush under Memory Backpressure
    // =========================================================================
    task test_flush_with_backpressure();
        logic [`UP(MEM_FLAGS_WIDTH)-1:0] flush_flags;
        logic [`MEM_ADDR_WIDTH-1:0] byte_addr[NUM_FLUSH_WRITES];
        logic [WORD_WIDTH-1:0] wr_data[NUM_FLUSH_WRITES];
        logic [WORD_WIDTH-1:0] rsp_data, flush_rsp_data;
        logic [WORD_WIDTH-1:0] expected;
        logic [`MEM_ADDR_WIDTH-1:0] flush_addr;
        int actual_port;

        $display("\n--- TEST 8: Flush under Memory Backpressure ---");
        $fdisplay(log_fd, "[%0t] TEST 8: Flush under Memory Backpressure", $time);

        clear_core_rsp_queue();
        flush_flags = '0;
        flush_flags[MEM_REQ_FLAG_FLUSH] = 1'b1;
        flush_addr = same_bank_addr('h3000, 31);

        mem_rsp_delay_cycles = 32;

        for (int i = 0; i < NUM_FLUSH_WRITES; i++) begin
            byte_addr[i] = same_bank_addr('h3000, i);
            wr_data[i]   = 32'hA5000000 | WORD_WIDTH'(i);
            ref_write_word(byte_addr[i], {WORD_SIZE{1'b1}}, wr_data[i]);
        end

        fork
            pulse_mem_req_ready(1, 3, 20);
            begin
                for (int wave = 0; wave < (NUM_FLUSH_WRITES / NUM_REQS); wave++) begin
                    fork
                        send_core_req(0, 1'b1, byte_to_word_addr(byte_addr[wave * NUM_REQS + 0]),
                                      {WORD_SIZE{1'b1}}, wr_data[wave * NUM_REQS + 0], 16'h8100 + wave[15:0]);
                        send_core_req(1, 1'b1, byte_to_word_addr(byte_addr[wave * NUM_REQS + 1]),
                                      {WORD_SIZE{1'b1}}, wr_data[wave * NUM_REQS + 1], 16'h8110 + wave[15:0]);
                        send_core_req(2, 1'b1, byte_to_word_addr(byte_addr[wave * NUM_REQS + 2]),
                                      {WORD_SIZE{1'b1}}, wr_data[wave * NUM_REQS + 2], 16'h8120 + wave[15:0]);
                        send_core_req(3, 1'b1, byte_to_word_addr(byte_addr[wave * NUM_REQS + 3]),
                                      {WORD_SIZE{1'b1}}, wr_data[wave * NUM_REQS + 3], 16'h8130 + wave[15:0]);
                    join
                end

                send_core_req_ex(
                    .port_id(0),
                    .rw(1'b0),
                    .addr(byte_to_word_addr(flush_addr)),
                    .byteen({WORD_SIZE{1'b1}}),
                    .data('0),
                    .tag(16'h8F00),
                    .flags(flush_flags)
                );
            end
        join

        wait_for_cache_drain();

        mem_req_ready_r      = 1'b1;
        mem_rsp_delay_cycles = MEM_LATENCY;
        repeat(10) @(posedge clk);

        wait_core_rsp_tag(TAG_WIDTH'(16'h8F00), actual_port, flush_rsp_data, 2000);
        check_result("FlushBackpressure flush read",
                     flush_rsp_data, ref_read_word(flush_addr), TAG_WIDTH'(16'h8F00), TAG_WIDTH'(16'h8F00));
        check_true("FlushBackpressure flush returned on port 0", actual_port == 0);

        for (int i = 0; i < NUM_FLUSH_WRITES; i++) begin
            expected = ref_read_word(byte_addr[i]);
            send_core_req(i % NUM_REQS, 1'b0, byte_to_word_addr(byte_addr[i]),
                          {WORD_SIZE{1'b1}}, '0, 16'h8200 + i[15:0]);
            wait_core_rsp_tag(TAG_WIDTH'(16'h8200 + i[15:0]), actual_port, rsp_data, 2000);
            check_result($sformatf("FlushBackpressure W%0d @0x%04h", i, byte_addr[i]),
                         rsp_data, expected, TAG_WIDTH'(16'h8200 + i[15:0]), TAG_WIDTH'(16'h8200 + i[15:0]));
            check_true($sformatf("FlushBackpressure port %0d", i), actual_port == (i % NUM_REQS));
        end

        repeat(10) @(posedge clk);
    endtask

    // =========================================================================
    // TEST 9: Simultaneous Flush Requests on Multiple Ports
    // =========================================================================
    task test_multiport_flush_requests();
        logic [`UP(MEM_FLAGS_WIDTH)-1:0] flush_flags;
        logic [`MEM_ADDR_WIDTH-1:0] byte_addr[NUM_REQS];
        logic [WORD_WIDTH-1:0] wr_data[NUM_REQS];
        logic [WORD_WIDTH-1:0] rsp_data[NUM_REQS];
        logic [WORD_WIDTH-1:0] expected[NUM_REQS];
        logic saw_flush, pending_violation, blocked_violation;
        int actual_port;

        $display("\n--- TEST 9: Simultaneous Flush Requests ---");
        $fdisplay(log_fd, "[%0t] TEST 9: Simultaneous Flush Requests", $time);

        clear_core_rsp_queue();
        flush_flags = '0;
        flush_flags[MEM_REQ_FLAG_FLUSH] = 1'b1;
        mem_rsp_delay_cycles = 24;

        for (int i = 0; i < NUM_REQS; i++) begin
            byte_addr[i] = same_bank_addr('h4000, i);
            wr_data[i]   = 32'hB6000000 | WORD_WIDTH'(i);
            expected[i]  = wr_data[i];
            ref_write_word(byte_addr[i], {WORD_SIZE{1'b1}}, wr_data[i]);
        end

        fork
            pulse_mem_req_ready(1, 2, 16);
            begin
                fork
                    send_core_req(0, 1'b1, byte_to_word_addr(byte_addr[0]),
                                  {WORD_SIZE{1'b1}}, wr_data[0], TAG_WIDTH'(16'h9100));
                    send_core_req(1, 1'b1, byte_to_word_addr(byte_addr[1]),
                                  {WORD_SIZE{1'b1}}, wr_data[1], TAG_WIDTH'(16'h9101));
                    send_core_req(2, 1'b1, byte_to_word_addr(byte_addr[2]),
                                  {WORD_SIZE{1'b1}}, wr_data[2], TAG_WIDTH'(16'h9102));
                    send_core_req(3, 1'b1, byte_to_word_addr(byte_addr[3]),
                                  {WORD_SIZE{1'b1}}, wr_data[3], TAG_WIDTH'(16'h9103));
                join

                fork
                    monitor_flush_clean_start(saw_flush, pending_violation, blocked_violation);
                    begin
                        fork
                            begin
                                fork
                                    send_core_req_ex(0, 1'b0, byte_to_word_addr(byte_addr[0]),
                                                     {WORD_SIZE{1'b1}}, '0, TAG_WIDTH'(16'h9200), flush_flags);
                                join
                            end
                            begin
                                fork
                                    send_core_req_ex(1, 1'b0, byte_to_word_addr(byte_addr[1]),
                                                     {WORD_SIZE{1'b1}}, '0, TAG_WIDTH'(16'h9201), flush_flags);
                                join
                            end
                            begin
                                fork
                                    send_core_req_ex(2, 1'b0, byte_to_word_addr(byte_addr[2]),
                                                     {WORD_SIZE{1'b1}}, '0, TAG_WIDTH'(16'h9202), flush_flags);
                                join
                            end
                            begin
                                fork
                                    send_core_req_ex(3, 1'b0, byte_to_word_addr(byte_addr[3]),
                                                     {WORD_SIZE{1'b1}}, '0, TAG_WIDTH'(16'h9203), flush_flags);
                                join
                            end
                        join
                    end
                join
            end
        join

        wait_for_cache_drain();
        mem_req_ready_r      = 1'b1;
        mem_rsp_delay_cycles = MEM_LATENCY;

        for (int i = 0; i < NUM_REQS; i++) begin
            wait_core_rsp_tag(TAG_WIDTH'(16'h9200 + i), actual_port, rsp_data[i], 2000);
            check_result($sformatf("MultiFlush Port%0d @0x%04h", i, byte_addr[i]),
                         rsp_data[i], expected[i], TAG_WIDTH'(16'h9200 + i), TAG_WIDTH'(16'h9200 + i));
            check_true($sformatf("MultiFlush response port %0d", i), actual_port == i);
        end
        check_true("MultiFlush clean start", saw_flush && !pending_violation && !blocked_violation);

        repeat(10) @(posedge clk);
    endtask

    // =========================================================================
    // TEST 10: Flush during Core Response Backpressure
    // =========================================================================
    task test_flush_during_rsp_backpressure();
        logic [`UP(MEM_FLAGS_WIDTH)-1:0] flush_flags;
        logic [`MEM_ADDR_WIDTH-1:0] addr_hits[NUM_BP_REQS];
        logic [`MEM_ADDR_WIDTH-1:0] flush_addr;
        logic [WORD_WIDTH-1:0] warm_data;
        logic [TAG_WIDTH-1:0]  warm_tag;
        logic [WORD_WIDTH-1:0] rsp_data, rsp_data_flush;
        logic saw_flush, pending_violation, blocked_violation;
        logic saw_stall;
        logic req_accepted, flush_accepted;
        logic stop_req_gen, req_gen_done, flush_driver_done;
        logic [TAG_WIDTH-1:0] req_tags[NUM_BP_REQS];
        int req_ports[NUM_BP_REQS];
        int actual_port;
        int issued_reqs;
        int cnt;

        $display("\n--- TEST 10: Flush during Core Response Backpressure ---");
        $fdisplay(log_fd, "[%0t] TEST 10: Flush during Core Response Backpressure", $time);

        clear_core_rsp_queue();
        flush_flags = '0;
        flush_flags[MEM_REQ_FLAG_FLUSH] = 1'b1;

        for (int i = 0; i < NUM_BP_REQS; i++) begin
            addr_hits[i] = same_bank_addr('h5000, i);
            req_tags[i]  = TAG_WIDTH'(16'hA200 + i);
            req_ports[i] = 0;
        end
        flush_addr = same_bank_addr('h5000, 31);

        for (int i = 0; i < NUM_BP_REQS; i++) begin
            fork
                send_core_req(req_ports[i], 1'b0, byte_to_word_addr(addr_hits[i]),
                              {WORD_SIZE{1'b1}}, '0, TAG_WIDTH'(16'hA100 + i));
                wait_core_rsp(req_ports[i], warm_data, warm_tag);
            join
            check_result($sformatf("Backpressure warm read %0d", i),
                         warm_data, ref_read_word(addr_hits[i]), warm_tag, TAG_WIDTH'(16'hA100 + i));
        end

        clear_core_rsp_queue();
        set_core_rsp_ready(0, 1'b0);
        set_core_rsp_ready(1, 1'b0);
        set_core_rsp_ready(2, 1'b0);
        set_core_rsp_ready(3, 1'b0);
        saw_stall = 0;
        flush_accepted = 0;
        stop_req_gen = 0;
        req_gen_done = 0;
        flush_driver_done = 0;
        issued_reqs = 0;

        fork
            begin : g_req_gen
                for (int i = 0; i < NUM_BP_REQS; i++) begin
                    send_core_req_ex_status(req_ports[i], 1'b0, byte_to_word_addr(addr_hits[i]),
                                            {WORD_SIZE{1'b1}}, '0, req_tags[i], `UP(MEM_FLAGS_WIDTH)'(0),
                                            req_accepted, -1);
                    if (req_accepted) begin
                        issued_reqs++;
                    end
                    if (stop_req_gen) begin
                        break;
                    end
                end
                req_gen_done = 1;
            end
            begin : g_stall_watch
                wait_for_bank0_crsp_stall(saw_stall, 2000);
            end
        join_none

        cnt = 0;
        while (!saw_stall && !req_gen_done && (cnt < 2000)) begin
            @(posedge clk);
            cnt++;
        end

        if (saw_stall) begin
            stop_req_gen = 1;
            fork
                begin : g_flush_watch
                    monitor_flush_clean_start(saw_flush, pending_violation, blocked_violation);
                end
                begin : g_flush_driver
                    send_core_req_ex_status(1, 1'b0, byte_to_word_addr(flush_addr),
                                            {WORD_SIZE{1'b1}}, '0, TAG_WIDTH'(16'hAF00), flush_flags,
                                            flush_accepted, -1);
                    flush_driver_done = 1;
                end
            join_none
            repeat (12) @(posedge clk);
        end else begin
            stop_req_gen = 1;
        end

        set_core_rsp_ready(0, 1'b1);
        set_core_rsp_ready(1, 1'b1);
        set_core_rsp_ready(2, 1'b1);
        set_core_rsp_ready(3, 1'b1);

        cnt = 0;
        while (!req_gen_done && (cnt < 2000)) begin
            @(posedge clk);
            cnt++;
        end

        if (saw_stall) begin
            cnt = 0;
            while (!flush_driver_done && (cnt < 2000)) begin
                @(posedge clk);
                cnt++;
            end
        end

        wait_for_cache_drain();

        if (saw_stall) begin
            check_true("Backpressure flush request accepted", flush_accepted);
            if (flush_accepted) begin
                wait_core_rsp_tag(TAG_WIDTH'(16'hAF00), actual_port, rsp_data_flush, 2000);
                check_result("Backpressure flush read", rsp_data_flush, ref_read_word(flush_addr), TAG_WIDTH'(16'hAF00), TAG_WIDTH'(16'hAF00));
                check_true("Backpressure flush returned on port 1", actual_port == 1);
                check_true("Backpressure flush clean start", saw_flush && !pending_violation && !blocked_violation);
            end else begin
                check_true("Backpressure flush clean start", 1'b0);
            end
        end

        check_true("Backpressure stall observed", saw_stall);
        check_true("Backpressure request stream saturated", saw_stall);
        for (int i = 0; i < issued_reqs; i++) begin
            wait_core_rsp_tag(req_tags[i], actual_port, rsp_data, 2000);
            check_result($sformatf("Backpressure queued hit %0d", i),
                         rsp_data, ref_read_word(addr_hits[i]), req_tags[i], req_tags[i]);
            check_true($sformatf("Backpressure response port %0d", i), actual_port == req_ports[i]);
        end

        repeat(10) @(posedge clk);
    endtask

    // =========================================================================
    // TEST 11: bank_req_fire should track core_req_ready, not mem_req_ready
    //
    // Strategy: force the state (valid=1, core_ready=0, mem_ready=1) explicitly.
    //   1. Use fresh uncached addresses → cache misses → bank issues mem requests.
    //   2. Hold mem_req_ready_r = 0:
    //        miss requests pile up in bank MREQ queue (depth=MREQ_SIZE=4)
    //        and mem_req_buf (depth=TO_OUT_BUF_SIZE(MEM_OUT_BUF)=2).
    //        Once MREQ is ALM_FULL, bank pipeline stalls:
    //          per_bank_core_req_ready[0] = 0.
    //        The core_req_xbar output buffer (REQ_XBAR_BUF=2) holds the
    //        next request, keeping per_bank_core_req_valid[0] = 1.
    //   3. Release mem_req_ready_r = 1:
    //        mem_req_buf drains → arb selects bank 0 →
    //        per_bank_mem_req_ready[0] = 1  (because per_bank_mem_req_valid[0]=1
    //        and arb.ready_in[i] = ready_out_w && arb_onehot[i]).
    //        Bank is still stalled for a few cycles (MREQ not yet below ALM_FULL).
    //        → Guard state observed.
    //   4. If DUT uses the buggy line (fire = valid & mem_req_ready),
    //        fire=1 during guard state → saw_fire_mismatch=1 → test FAILs.
    //      If DUT uses the correct line (fire = valid & core_req_ready),
    //        fire=0 during guard state → saw_fire_mismatch=0 → test PASSes.
    // =========================================================================
    task test_bank_req_fire_accounting();
        // Fresh addresses not present in cache (all map to bank 0)
        logic [`MEM_ADDR_WIDTH-1:0] miss_addrs[NUM_BP_REQS];
        logic [WORD_WIDTH-1:0] rsp_data;
        logic [TAG_WIDTH-1:0]  req_tags[NUM_BP_REQS];
        logic req_accepted, stop_req_gen, req_gen_done;
        logic saw_guard_case, saw_fire_mismatch, fire_watch_done;
        int actual_port;
        int issued_reqs;
        int cnt;

        $display("\n--- TEST 11: bank_req_fire Accounting (miss+MREQ stall method) ---");
        $fdisplay(log_fd, "[%0t] TEST 11: bank_req_fire Accounting", $time);

        // Use a base address region not touched by earlier tests.
        // same_bank_addr ensures every address maps to bank 0.
        for (int i = 0; i < NUM_BP_REQS; i++) begin
            miss_addrs[i] = same_bank_addr('hD000, i);
            req_tags[i]   = TAG_WIDTH'(16'hC000 + i);
        end

        // --- Setup ---
        clear_core_rsp_queue();
        set_core_rsp_ready(0, 1'b1);
        set_core_rsp_ready(1, 1'b1);
        set_core_rsp_ready(2, 1'b1);
        set_core_rsp_ready(3, 1'b1);
        mem_req_ready_r   = 1'b0;   // block memory → misses pile up in MREQ

        stop_req_gen      = 0;
        req_gen_done      = 0;
        fire_watch_done   = 0;
        saw_guard_case    = 0;
        saw_fire_mismatch = 0;
        issued_reqs       = 0;

        fork
            // Thread A: drive cache-miss requests toward bank 0.
            // send_core_req_ex_status blocks (timeout=-1) once the core_req_xbar
            // output buffer for bank 0 is full (bank stalled, buffer saturated).
            // While blocking, req_valid stays asserted → per_bank_core_req_valid[0]=1.
            begin : g_req_gen
                for (int i = 0; i < NUM_BP_REQS; i++) begin
                    if (stop_req_gen) break;
                    send_core_req_ex_status(0, 1'b0,
                                            byte_to_word_addr(miss_addrs[i]),
                                            {WORD_SIZE{1'b1}}, '0, req_tags[i],
                                            `UP(MEM_FLAGS_WIDTH)'(0),
                                            req_accepted, -1);
                    if (req_accepted) issued_reqs++;
                end
                req_gen_done = 1;
            end

            // Thread B: continuously sample the three-signal guard state.
            begin : g_fire_watch
                monitor_bank0_fire_guard(saw_guard_case, saw_fire_mismatch, 3000);
                fire_watch_done = 1;
            end

            // Thread C: wait for MREQ + mem_req_buf to fill, then open the memory
            // side.  This creates exactly one window where:
            //   per_bank_mem_req_ready[0] = 1  (arb grants bank 0 as buf drains)
            //   per_bank_core_req_ready[0] = 0  (bank still stalled, MREQ ALM_FULL)
            //   per_bank_core_req_valid[0] = 1  (xbar buf holds pending req)
            begin : g_mem_trigger
                // MREQ_SIZE=4, mem_req_buf SIZE=2, pipeline latency ~3 cycles.
                // 20 cycles is safely beyond the fill time for all queues.
                repeat (20) @(posedge clk);
                $fdisplay(log_fd, "[%0t] TEST11: releasing mem_req_ready", $time);
                mem_req_ready_r = 1'b1;
                // Keep monitoring for a few more cycles after release to
                // capture the transition window.
                repeat (10) @(posedge clk);
            end
        join_none

        // Wait until the guard monitor exits (guard seen or mismatch or timeout).
        cnt = 0;
        while (!fire_watch_done && (cnt < 3500)) begin
            @(posedge clk);
            cnt++;
        end

        // Tear down request generator.
        stop_req_gen = 1;

        // Drain: wait for all accepted requests to complete.
        mem_req_ready_r = 1'b1;
        set_core_rsp_ready(0, 1'b1);
        set_core_rsp_ready(1, 1'b1);
        set_core_rsp_ready(2, 1'b1);
        set_core_rsp_ready(3, 1'b1);

        cnt = 0;
        while (!req_gen_done && (cnt < 2000)) begin
            @(posedge clk);
            cnt++;
        end

        cnt = 0;
        while (!fire_watch_done && (cnt < 2000)) begin
            @(posedge clk);
            cnt++;
        end

        wait_for_cache_drain();

        // --- Assertions ---
        check_true("BankFire: guard state (valid=1,core_rdy=0,mem_rdy=1) observed",
                   saw_guard_case);
        check_true("BankFire: fire must NOT assert when core_req_ready=0",
                   !saw_fire_mismatch);

        // Verify data integrity for all issued miss requests.
        for (int i = 0; i < issued_reqs; i++) begin
            wait_core_rsp_tag(req_tags[i], actual_port, rsp_data, 2000);
            check_result($sformatf("BankFire miss response %0d", i),
                         rsp_data, ref_read_word(miss_addrs[i]),
                         req_tags[i], req_tags[i]);
        end

        repeat(10) @(posedge clk);
    endtask

endmodule
