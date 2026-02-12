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
    localparam CACHE_SIZE       = 4096;   // 4KB - small for easier testing
    localparam LINE_SIZE        = 64;     // 64B cache line
    localparam NUM_BANKS        = 4;
    localparam NUM_WAYS         = 4;
    localparam WORD_SIZE        = 4;      // 4B word
    localparam CRSQ_SIZE        = 4;
    localparam MSHR_SIZE        = 16;
    localparam MRSQ_SIZE        = 4;
    localparam MREQ_SIZE        = 4;
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
    localparam MEM_LATENCY      = 10;      // memory response latency in cycles

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
        .mem_bus_if     (mem_bus_if)
    );

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

    mem_rsp_entry_t mem_rsp_queue[$];

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
                    entry.delay = MEM_LATENCY;
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

    // Memory request ready - always accept
    generate
        for (genvar p = 0; p < MEM_PORTS; p++) begin : g_mem_req_ready
            assign mem_bus_if[p].req_ready = 1'b1;
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

        // ---- Test Cases ----
        test_single_read_miss();
        test_single_write();
        test_read_hit_after_write();
        test_multiple_reads_same_line();
        test_multiple_reads_diff_lines();
        test_write_read_back();
        test_concurrent_requests();

        // Wait for all pending transactions to complete
        repeat(50) @(posedge clk);

        // ---- Summary ----
        $display("\n=====================================================================");
        $display("  TEST SUMMARY: %0d total, %0d passed, %0d failed", 
                 total_tests, passed_tests, failed_tests);
        $display("=====================================================================");
        $fdisplay(rpt_fd, "TOTAL=%0d PASS=%0d FAIL=%0d", total_tests, passed_tests, failed_tests);
        $fdisplay(log_fd, "[%0t] Simulation complete", $time);

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
    core_bus_if[P].req_data.flags <= '0

`define CORE_REQ_READY(P) core_bus_if[P].req_ready

`define CORE_REQ_DEASSERT(P) core_bus_if[P].req_valid <= 1'b0

    task automatic send_core_req(
        input int port_id,
        input logic rw,
        input logic [WORD_ADDR_WIDTH-1:0] addr,
        input logic [WORD_SIZE-1:0] byteen,
        input logic [WORD_WIDTH-1:0] data,
        input logic [TAG_WIDTH-1:0] tag
    );
        @(posedge clk);
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
            while (!ready) begin
                @(posedge clk);
                case (port_id)
                    0: ready = `CORE_REQ_READY(0);
                    1: ready = `CORE_REQ_READY(1);
                    2: ready = `CORE_REQ_READY(2);
                    3: ready = `CORE_REQ_READY(3);
                endcase
            end
        end

        case (port_id)
            0: begin `CORE_REQ_DEASSERT(0); end
            1: begin `CORE_REQ_DEASSERT(1); end
            2: begin `CORE_REQ_DEASSERT(2); end
            3: begin `CORE_REQ_DEASSERT(3); end
        endcase
        $fdisplay(log_fd, "[%0t] REQ port=%0d rw=%0b addr=0x%08h data=0x%08h tag=0x%04h", 
                  $time, port_id, rw, addr, data, tag);
    endtask

    // =========================================================================
    // Core Response Collector Task
    // =========================================================================

`define CORE_RSP_CHECK(P) (core_bus_if[P].rsp_valid && core_bus_if[P].rsp_ready)
`define CORE_RSP_DATA(P)  core_bus_if[P].rsp_data.data
`define CORE_RSP_TAG(P)   core_bus_if[P].rsp_data.tag

    task automatic wait_core_rsp(
        input  int port_id,
        output logic [WORD_WIDTH-1:0] data,
        output logic [TAG_WIDTH-1:0]  tag,
        input  int timeout = 500
    );
        int cnt = 0;
        logic got_rsp;
        forever begin
            @(posedge clk);
            got_rsp = 0;
            case (port_id)
                0: got_rsp = `CORE_RSP_CHECK(0);
                1: got_rsp = `CORE_RSP_CHECK(1);
                2: got_rsp = `CORE_RSP_CHECK(2);
                3: got_rsp = `CORE_RSP_CHECK(3);
            endcase
            if (got_rsp) begin
                case (port_id)
                    0: begin data = `CORE_RSP_DATA(0); tag = `CORE_RSP_TAG(0); end
                    1: begin data = `CORE_RSP_DATA(1); tag = `CORE_RSP_TAG(1); end
                    2: begin data = `CORE_RSP_DATA(2); tag = `CORE_RSP_TAG(2); end
                    3: begin data = `CORE_RSP_DATA(3); tag = `CORE_RSP_TAG(3); end
                endcase
                $fdisplay(log_fd, "[%0t] RSP port=%0d data=0x%08h tag=0x%04h", 
                          $time, port_id, data, tag);
                return;
            end
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

    // =========================================================================
    // Utility: build word address from byte address
    // =========================================================================
    function automatic logic [WORD_ADDR_WIDTH-1:0] byte_to_word_addr(
        input logic [`MEM_ADDR_WIDTH-1:0] byte_addr
    );
        return byte_addr[$clog2(WORD_SIZE) +: WORD_ADDR_WIDTH];
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

endmodule
