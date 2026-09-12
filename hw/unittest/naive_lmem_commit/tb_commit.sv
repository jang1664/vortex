`include "VX_define.vh"
module tb_commit;
    import VX_gpu_pkg::*;
    localparam BANKS = `LMEM_NUM_BANKS;
    localparam TAGW = LMEM_LOCAL_TAG_WIDTH + 1;
    localparam ADDRW = 12;
    logic clk = 0;
    always #5 clk = ~clk;
    logic reset = 1;
    VX_mem_bus_if #(.DATA_SIZE(8), .TAG_WIDTH(TAGW)) bus[BANKS]();
    logic [BANKS-1:0] valid, write;
    logic [BANKS-1:0][ADDRW-1:0] address;
    logic [BANKS-1:0][63:0] data;
    logic [BANKS-1:0][7:0] mask;
    logic [BANKS-1:0][TAGW-1:0] tag;
    wire [BANKS-1:0] ready, response;
    wire [BANKS-1:0][63:0] response_data;
    wire [BANKS-1:0][2:0] commits;
    for (genvar i = 0; i < BANKS; ++i) begin : g_bus
        assign bus[i].req_valid = valid[i];
        assign bus[i].req_data.rw = write[i];
        assign bus[i].req_data.addr = address[i];
        assign bus[i].req_data.data = data[i];
        assign bus[i].req_data.byteen = mask[i];
        assign bus[i].req_data.flags = '0;
        assign bus[i].req_data.tag = tag[i];
        assign ready[i] = bus[i].req_ready;
        assign response[i] = bus[i].rsp_valid;
        assign response_data[i] = bus[i].rsp_data.data;
        assign bus[i].rsp_ready = 1'b1;
    end
    VX_local_mem #(.SIZE(8*(1<<ADDRW)), .NUM_REQS(BANKS), .NUM_BANKS(BANKS),
                   .ADDR_WIDTH(ADDRW), .WORD_SIZE(8), .TAG_WIDTH(TAGW), .OUT_BUF(3)) memory
        (.clk(clk), .reset(reset), .mem_bus_if(bus), .naive_write_commit(commits));

    integer seen_psum0 = 0, seen_psum1 = 0, seen_final = 0, seen_dma = 0;
    always @(posedge clk) if (!reset) begin
        for (int b = 0; b < BANKS; ++b) begin
            case (commits[b])
                3'b010: seen_psum0 = seen_psum0 + 1;
                3'b011: seen_psum1 = seen_psum1 + 1;
                3'b100: seen_final = seen_final + 1;
                3'b110: seen_dma = seen_dma + 1;
                3'b000: begin end
                default: $fatal(1, "Invalid bank event encoding");
            endcase
            if (commits[b] != 0)
                assert (memory.per_bank_req_valid[b] && memory.per_bank_req_ready[b]
                        && memory.per_bank_req_rw[b]) else $fatal(1, "Noncommit event");
        end
    end

    function automatic logic [TAGW-1:0] route(input bit normal, input int normal_origin, input int write_origin);
        return (TAGW'(normal) << (LMEM_LOCAL_TAG_WIDTH-UUID_WIDTH))
             | (TAGW'(normal_origin) << (GEMM_LMEM_TAG_WIDTH-UUID_WIDTH))
             | (TAGW'(write_origin) << (GEMM_BASE_TAG_WIDTH-UUID_WIDTH));
    endfunction
    task automatic send_write(input int port, input int addr, input logic [TAGW-1:0] routed_tag,
                              input logic [63:0] value, input logic [7:0] enables = 8'hff);
        @(negedge clk);
        valid[port] = 1; write[port] = 1; address[port] = ADDRW'(addr);
        data[port] = value; mask[port] = enables; tag[port] = routed_tag;
        do @(posedge clk); while (!ready[port]);
        @(negedge clk); valid[port] = 0;
        repeat (12) @(negedge clk);
    endtask
    task automatic check_read(input int port, input int addr, input logic [63:0] expected);
        @(negedge clk);
        valid[port] = 1; write[port] = 0; address[port] = ADDRW'(addr);
        mask[port] = '1; tag[port] = route(1, 0, 0);
        do @(posedge clk); while (!ready[port]);
        @(negedge clk); valid[port] = 0;
        do @(posedge clk); while (!response[port]);
        assert (response_data[port] == expected) else $fatal(1, "RAM contents mismatch");
        @(negedge clk);
    endtask

    logic f_valid = 0, f_write = 1, f_ready = 1;
    logic [BANKS*8-1:0] f_mask = 0;
    logic [BANKS-1:0] f_commit = 0;
    logic worker_done = 0, frontend_ready = 1;
    logic use_bank_commits = 0;
    wire [BANKS-1:0] actual_dma_commits;
    for (genvar i = 0; i < BANKS; ++i) begin : g_actual_dma_commit
        assign actual_dma_commits[i] = commits[i][2:1] == 2'b11;
    end
    wire allow, drained, frontend_done, worker_ready;
    VX_naive_dma_write_fence #(.NUM_LANES(BANKS), .NUM_BANKS(BANKS)) fence
        (.clk(clk), .reset(reset), .req_valid(f_valid), .req_write(f_write),
         .req_byteen(f_mask), .downstream_ready(use_bank_commits ? ready[0] : f_ready),
         .commit_valid(use_bank_commits ? actual_dma_commits : f_commit),
         .worker_done_valid(worker_done), .frontend_done_ready(frontend_ready),
         .allow_request(allow), .drained(drained), .frontend_done_valid(frontend_done),
         .worker_done_ready(worker_ready));
    task automatic step;
        @(posedge clk); #1; @(negedge clk);
    endtask
    initial begin
        assert (LSU_WORD_SIZE == 8)
            else $fatal(1, "This fixture requires configured XLEN=64 (8-byte LSU words), got %0d bytes", LSU_WORD_SIZE);
        valid = '0; write = '0; address = '0; data = '0; mask = '0; tag = '0;
        repeat (4) @(negedge clk);
        reset = 0;
        // Actual bank write events distinguish normal CPU, ordinary GEMM,
        // DMA, PSUM sets and final writes. Flags are deliberately all zero.
        send_write(0, 0, route(1, 0, 0), 64'h1122334455667788);
        send_write(0, 0, route(1, 2, 0), 64'h1122334455667788);
        assert (seen_dma+seen_final+seen_psum0+seen_psum1 == 0) else $fatal(1, "Foreign write counted");
        send_write(0, 0, route(1, 1, 0), 64'hffffffffaabbccdd, 8'h0f);
        check_read(1, 0, 64'h11223344aabbccdd);
        send_write(0, 0, route(0, 0, 0), 64'h10);
        send_write(0, (`GEMM_PSUM_DATA_SIZE/8), route(0, 0, 0), 64'h20);
        send_write(0, 0, route(0, 0, 2), 64'h30);
        assert (seen_dma == 1 && seen_final == 1 && seen_psum0 == 1 && seen_psum1 == 1)
            else $fatal(1, "Bank origin/set classification failed: dma=%0d final=%0d psum0=%0d psum1=%0d",
                        seen_dma, seen_final, seen_psum0, seen_psum1);
        check_read(1, 0, 64'h30);

        // Real memory integration: upstream acceptance precedes bank commit.
        // A dependent same-bank read is held until fenced descriptor release.
        use_bank_commits = 1;
        @(negedge clk);
        f_valid = 1; f_mask = 0; f_mask[7:0] = '1;
        valid[0] = 1; write[0] = 1; address[0] = 0;
        data[0] = 64'hdeadbeef76543210; mask[0] = '1; tag[0] = route(1, 1, 0);
        do @(posedge clk); while (!ready[0]);
        @(negedge clk);
        valid[0] = 0; f_valid = 0; worker_done = 1;
        #1;
        assert (!frontend_done && !worker_ready) else $fatal(1, "Real write released before RAM bank");
        do @(negedge clk); while (!frontend_done);
        assert (seen_dma == 2) else $fatal(1, "Real descriptor released without its commit");
        worker_done = 0;
        check_read(1, 0, 64'hdeadbeef76543210);
        use_bank_commits = 0;

        // A partial wide request reserves every active lane before any
        // scatter completion. Same-edge returning commit cannot erase reserve.
        f_valid = 1; f_ready = 0; f_mask = 0; f_mask[0] = 1; f_mask[8] = 1;
        f_commit[0] = 1;
        step();
        assert (fence.pending_r == 1 && fence.reserved_r) else $fatal(1, "Partial reserve/commit arithmetic");
        f_commit = 0;
        repeat (7) step();
        assert (fence.pending_r == 1) else $fatal(1, "Duplicate partial reservation");
        f_ready = 1; step(); f_valid = 0; worker_done = 1;
        #1; assert (!frontend_done && !worker_ready) else $fatal(1, "Descriptor released before commit");
        repeat (9) step();
        f_commit[0] = 1; step(); f_commit = 0;
        #1; assert (frontend_done && worker_ready && drained) else $fatal(1, "Descriptor did not release after commit");
        frontend_ready = 0;
        #1; assert (frontend_done && !worker_ready) else $fatal(1, "Done ready backpressure lost");
        worker_done = 0; frontend_ready = 1;

        // Zero-byte writes consume zero credits; reserve+full accept clears hold.
        f_valid = 1; f_mask = 0; step(); f_valid = 0;
        assert (fence.pending_r == 0 && !fence.reserved_r) else $fatal(1, "Zero mask reserved payload");

        // Fill exactly 4095 word credits without a simulated return. The
        // final partial beat reaches the non-power-of-two credit ceiling.
        f_valid = 1; f_mask = '1;
        repeat (4095/BANKS) step();
        f_mask = '1; f_mask[(BANKS-1)*8 +: 8] = 0;
        step();
        assert (fence.pending_r == 4095) else $fatal(1, "Credit fill mismatch");
        f_mask = '1;
        #1; assert (!allow) else $fatal(1, "Unreserved write passed full credit");
        repeat (5) step();
        f_commit = '1; step(); f_commit = 0;
        #1; assert (allow) else $fatal(1, "Bank commit failed to reopen credit");
        step(); f_valid = 0;
        assert (fence.pending_r == 4095) else $fatal(1, "Reopened credit reservation failed");
        f_commit = '1;
        repeat (4095/BANKS) step();
        f_commit = '1; f_commit[BANKS-1] = 0; step(); f_commit = 0;
        assert (drained) else $fatal(1, "Final credit drain failed");
        $display("TEST PASSED: actual RAM commit kinds/sets/masks; fence partial and simultaneous events, delayed done, zero mask, 4095-credit saturation");
        $finish;
    end
    initial begin
        #200000;
        $fatal(1, "Test timeout");
    end
endmodule
