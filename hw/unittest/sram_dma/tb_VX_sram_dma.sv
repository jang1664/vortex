`timescale 1ns/1ps
`include "VX_define.vh"

module tb_VX_sram_dma;
    import VX_gpu_pkg::*;
    localparam int MEMORY_BYTES = 65536;
    localparam logic [63:0] LOCAL_BASE = 64'h2_0000_0000;
    logic clk = 1'b0;
    logic reset = 1'b1;
    always #5 clk = ~clk;

    logic cmd_valid, cmd_ready, direction, busy, done;
    logic [63:0] tmem_address, lmem_address;
    logic [31:0] length, sequence_id, done_sequence;
    logic [2:0] error;
    logic commit_delayed;
    logic immediate_commit = 1'b0;
    logic freeze_tmem = 1'b0;
    logic freeze_lmem = 1'b0;
    wire lmem_commit;
    logic [31:0] random_q;
    VX_mem_bus_if #(.DATA_SIZE(32), .TAG_WIDTH(8), .MEM_ADDR_WIDTH(34)) tmem();
    VX_mem_bus_if #(.DATA_SIZE(8), .TAG_WIDTH(8), .MEM_ADDR_WIDTH(34)) lmem();

    VX_sram_dma #(
        .INSTANCE_ID("tb.sram_dma"),
        .TMEM_SIZE(MEMORY_BYTES),
        .LMEM_BASE(LOCAL_BASE),
        .LMEM_SIZE_BYTES(MEMORY_BYTES)
    ) dut (
        .clk(clk), .reset(reset),
        .cmd_valid_i(cmd_valid), .cmd_ready_o(cmd_ready),
        .cmd_direction_i(direction), .cmd_tmem_addr_i(tmem_address),
        .cmd_lmem_addr_i(lmem_address), .cmd_length_i(length),
        .cmd_sequence_i(sequence_id), .busy_o(busy), .done_valid_o(done),
        .done_sequence_o(done_sequence), .error_o(error),
        .lmem_write_commit_i(lmem_commit),
        .tmem_bus_if(tmem), .lmem_bus_if(lmem)
    );

    byte unsigned tmem_bytes[MEMORY_BYTES];
    byte unsigned lmem_bytes[MEMORY_BYTES];
    bit tmem_pending, lmem_pending;
    bit tmem_pending_write, lmem_pending_write;
    int tmem_delay, lmem_delay;
    int tmem_offset, lmem_offset;
    logic [255:0] tmem_write_data;
    logic [63:0] lmem_write_data;
    int tmem_requests, lmem_requests, lmem_commits, completions;
    bit [7:0] tmem_banks_seen;
    bit [15:0] lmem_banks_seen;

    assign tmem.req_ready = !reset && !freeze_tmem && !tmem_pending
                         && !tmem.rsp_valid && random_q[0];
    assign lmem.req_ready = !reset && !freeze_lmem && !lmem_pending
                         && !lmem.rsp_valid && random_q[5];
    assign lmem_commit = commit_delayed
        || (immediate_commit && lmem.req_valid && lmem.req_ready && lmem.req_data.rw);

    always @(posedge clk) begin : memory_model
        int offset;
        if (reset) begin
            random_q <= 32'h1357_9bdf;
            tmem_pending <= 0;
            lmem_pending <= 0;
            tmem.rsp_valid <= 0;
            lmem.rsp_valid <= 0;
            tmem.rsp_data <= '0;
            lmem.rsp_data <= '0;
            commit_delayed <= 0;
            tmem_requests <= 0;
            lmem_requests <= 0;
            lmem_commits <= 0;
            completions <= 0;
            tmem_banks_seen <= '0;
            lmem_banks_seen <= '0;
        end else begin
            random_q <= {random_q[30:0], random_q[31] ^ random_q[21] ^ random_q[1] ^ random_q[0]};
            commit_delayed <= 0;
            if (done) begin
                completions <= completions + 1;
                assert (!tmem_pending && !lmem_pending
                     && !tmem.rsp_valid && !lmem.rsp_valid && !commit_delayed)
                    else $fatal(1, "DMA completed before memory transactions retired");
            end
            if (tmem.rsp_valid && tmem.rsp_ready)
                tmem.rsp_valid <= 0;
            if (lmem.rsp_valid && lmem.rsp_ready)
                lmem.rsp_valid <= 0;

            if (tmem.req_valid && tmem.req_ready) begin
                offset = int'(tmem.req_data.addr) * 32;
                assert (offset >= 0 && offset + 32 <= MEMORY_BYTES)
                    else $fatal(1, "TMEM model address out of range");
                assert (tmem.req_data.byteen == '1)
                    else $fatal(1, "TMEM write byte enables are not full-word");
                tmem_requests <= tmem_requests + 1;
                tmem_banks_seen[tmem.req_data.addr[2:0]] <= 1'b1;
                tmem_offset <= offset;
                tmem_pending_write <= tmem.req_data.rw;
                tmem_write_data <= tmem.req_data.data;
                tmem.rsp_data.tag <= tmem.req_data.tag;
                tmem_delay <= 1 + int'(random_q[9:6]);
                tmem_pending <= 1;
            end
            if (tmem_pending) begin
                if (tmem_delay != 0) begin
                    tmem_delay <= tmem_delay - 1;
                end else begin
                    for (int i = 0; i < 32; ++i) begin
                        if (tmem_pending_write)
                            tmem_bytes[tmem_offset+i] <= tmem_write_data[i*8 +: 8];
                        else
                            tmem.rsp_data.data[i*8 +: 8] <= tmem_bytes[tmem_offset+i];
                    end
                    tmem_pending <= 0;
                    tmem.rsp_valid <= 1;
                end
            end

            if (lmem.req_valid && lmem.req_ready) begin
                offset = int'((64'(lmem.req_data.addr) << 3) - LOCAL_BASE);
                assert (offset >= 0 && offset + 8 <= MEMORY_BYTES)
                    else $fatal(1, "LMEM model address out of range");
                assert (lmem.req_data.byteen == '1)
                    else $fatal(1, "LMEM write byte enables are not full-word");
                lmem_requests <= lmem_requests + 1;
                lmem_banks_seen[lmem.req_data.addr[3:0]] <= 1'b1;
                if (immediate_commit && lmem.req_data.rw) begin
                    for (int i = 0; i < 8; ++i)
                        lmem_bytes[offset+i] <= lmem.req_data.data[i*8 +: 8];
                    lmem_commits <= lmem_commits + 1;
                end else begin
                    lmem_offset <= offset;
                    lmem_pending_write <= lmem.req_data.rw;
                    lmem_write_data <= lmem.req_data.data;
                    lmem.rsp_data.tag <= lmem.req_data.tag;
                    lmem_delay <= 2 + int'(random_q[13:10]);
                    lmem_pending <= 1;
                end
            end
            if (lmem_pending) begin
                if (lmem_delay != 0) begin
                    lmem_delay <= lmem_delay - 1;
                end else begin
                    for (int i = 0; i < 8; ++i) begin
                        if (lmem_pending_write)
                            lmem_bytes[lmem_offset+i] <= lmem_write_data[i*8 +: 8];
                        else
                            lmem.rsp_data.data[i*8 +: 8] <= lmem_bytes[lmem_offset+i];
                    end
                    lmem_pending <= 0;
                    if (lmem_pending_write) begin
                        commit_delayed <= 1;
                        lmem_commits <= lmem_commits + 1;
                    end else begin
                        lmem.rsp_valid <= 1;
                    end
                end
            end
        end
    end

    task automatic submit(input bit dir, input logic [63:0] ta,
                          input logic [63:0] la, input int bytes,
                          input int seq);
        @(negedge clk);
        while (!cmd_ready) @(negedge clk);
        direction = dir;
        tmem_address = ta;
        lmem_address = la;
        length = 32'(bytes);
        sequence_id = 32'(seq);
        cmd_valid = 1;
        @(posedge clk);
        assert (cmd_ready) else $fatal(1, "Command was not accepted");
        @(negedge clk);
        cmd_valid = 0;
    endtask

    task automatic await_done(input int seq, input logic [2:0] expected_error);
        int timeout;
        timeout = 0;
        while (!done && timeout < 1000000) begin
            @(negedge clk);
            ++timeout;
        end
        assert (done && done_sequence == 32'(seq) && error == expected_error)
            else $fatal(1, "Completion mismatch seq=%0d expected=%0d error=%0d expected=%0d timeout=%0d",
                        done_sequence, seq, error, expected_error, timeout);
        assert (busy && !cmd_ready)
            else $fatal(1, "Ownership released before completion cycle");
        @(negedge clk);
        assert (!done && !busy && cmd_ready)
            else $fatal(1, "Completion is not a one-cycle pulse");
    endtask

    function automatic logic [31:0] next_payload(input logic [31:0] value);
        value ^= value << 13;
        value ^= value >> 17;
        value ^= value << 5;
        return value;
    endfunction

    task automatic copy_case(input bit dir, input int ta, input int la,
                             input int bytes, input int seq,
                             input logic [31:0] payload_seed = 0);
        int t_before, l_before, commits_before;
        logic [31:0] payload;
        t_before = tmem_requests;
        l_before = lmem_requests;
        commits_before = lmem_commits;
        payload = payload_seed;
        for (int i = 0; i < MEMORY_BYTES; ++i) begin
            if (payload_seed != 0)
                payload = next_payload(payload);
            if (dir) begin
                lmem_bytes[i] = payload_seed != 0 ? payload[7:0]
                    : 8'((i * 13) ^ (i >> 7) ^ seq);
                tmem_bytes[i] = 8'ha5;
            end else begin
                tmem_bytes[i] = payload_seed != 0 ? payload[7:0]
                    : 8'((i * 29) ^ (i >> 8) ^ seq);
                lmem_bytes[i] = 8'h5a;
            end
        end
        submit(dir, 64'(ta), LOCAL_BASE + 64'(la), bytes, seq);

        // A producer that violates software's submit protocol must still not
        // replace a command while cmd_ready is low.
        @(negedge clk);
        cmd_valid = 1;
        direction = !dir;
        tmem_address = 64'hffff_ffff_ffff_ffe0;
        lmem_address = '0;
        sequence_id = 32'hbad0_0000;
        repeat (3) begin
            @(negedge clk);
            assert (!cmd_ready) else $fatal(1, "Busy command accepted");
        end
        cmd_valid = 0;
        await_done(seq, 3'd0);
        assert (tmem_requests - t_before == bytes / 32
             && lmem_requests - l_before == bytes / 8)
            else $fatal(1, "Request count mismatch: duplicate or missing transfer");
        assert (lmem_commits - commits_before == (dir ? 0 : bytes / 8))
            else $fatal(1, "LMEM commit count mismatch");
        for (int i = 0; i < MEMORY_BYTES; ++i) begin
            if (dir) begin
                if (i >= ta && i < ta + bytes)
                    assert (tmem_bytes[i] == lmem_bytes[la+i-ta])
                        else $fatal(1, "L->T byte mismatch at %0d", i);
                else
                    assert (tmem_bytes[i] == 8'ha5)
                        else $fatal(1, "L->T destination canary overwritten at %0d", i);
            end else begin
                if (i >= la && i < la + bytes)
                    assert (lmem_bytes[i] == tmem_bytes[ta+i-la])
                        else $fatal(1, "T->L byte mismatch at %0d", i);
                else
                    assert (lmem_bytes[i] == 8'h5a)
                        else $fatal(1, "T->L destination canary overwritten at %0d", i);
            end
        end
        if (payload_seed != 0)
            $display("SRAM_DMA_SEEDED_PAYLOAD PASSED direction=%0d seed=%08h bytes=%0d tmem=%0d lmem=%0d checked_destination_bytes=%0d",
                dir, payload_seed, bytes, ta, la, MEMORY_BYTES);
    endtask

    task automatic reject_case(input logic [63:0] ta, input logic [63:0] la,
                               input int bytes, input int seq,
                               input logic [2:0] expected_error);
        int requests_before;
        requests_before = tmem_requests + lmem_requests;
        submit(1'b0, ta, la, bytes, seq);
        await_done(seq, expected_error);
        assert (tmem_requests + lmem_requests == requests_before)
            else $fatal(1, "Rejected command generated memory traffic");
    endtask

    initial begin
        cmd_valid = 0;
        direction = 0;
        tmem_address = 0;
        lmem_address = LOCAL_BASE;
        length = 0;
        sequence_id = 0;
        repeat (4) @(negedge clk);
        reset = 0;
        copy_case(0, 32, 96, 32, 1);
        copy_case(1, 288, 64, 32, 2);
        copy_case(0, 224, 480, 512, 3);
        copy_case(1, 4064, 8128, 1056, 4);
        immediate_commit = 1;
        copy_case(0, 0, 1024, 256, 5);
        immediate_commit = 0;
        copy_case(0, 16384, 8192, 32768, 6);
        copy_case(1, 8192, 16384, 32768, 7);
        copy_case(0, MEMORY_BYTES-32, MEMORY_BYTES-32, 32, 8);
        reject_case(0, LOCAL_BASE, 0, 9, 3'd1);
        reject_case(1, LOCAL_BASE, 32, 10, 3'd2);
        reject_case(0, LOCAL_BASE+8, 32, 11, 3'd2);
        reject_case(0, LOCAL_BASE, 33, 12, 3'd2);
        reject_case(MEMORY_BYTES-32, LOCAL_BASE, 64, 13, 3'd3);
        reject_case(0, LOCAL_BASE+MEMORY_BYTES-32, 64, 14, 3'd3);
        reject_case(0, LOCAL_BASE-32, 32, 15, 3'd3);
        reject_case(64'hffff_ffff_ffff_ffe0, LOCAL_BASE, 64, 16, 3'd3);
        reject_case(0, 64'hffff_ffff_ffff_ffe0, 64, 17, 3'd3);
        assert (&tmem_banks_seen && &lmem_banks_seen)
            else $fatal(1, "Bank coverage incomplete");

        // Reset both controller and transport while a source response is in
        // flight. A reset must not emit a stale command completion afterward.
        submit(0, 0, LOCAL_BASE, 32, 18);
        wait (tmem_pending);
        @(negedge clk);
        reset = 1;
        repeat (3) @(negedge clk);
        reset = 0;
        repeat (20) begin
            @(negedge clk);
            assert (!done && !busy && cmd_ready)
                else $fatal(1, "Stale activity after reset");
        end
        copy_case(1, 0, 0, 256, 19);
        // Payload randomness is independent of the existing deterministic
        // backpressure LFSR. Preserve all original pattern cases above.
        $display("SRAM_DMA_SEEDED_PAYLOAD seeds=6d2b79f5,c4f17a23 stall_reset_seed=13579bdf");
        copy_case(0, 224, 96, 64, 20, 32'h6d2b79f5);
        copy_case(1, 224, 96, 64, 21, 32'hc4f17a23);
        copy_case(0, 16384, 8192, 32768, 22, 32'hc4f17a23);
        copy_case(1, 8192, 16384, 32768, 23, 32'h6d2b79f5);
        // Largest transfer that retains a complete 32-byte guard on each
        // side of the destination in this 64 KiB byte-array fixture.
        copy_case(0, 32, 32, MEMORY_BYTES-64, 24, 32'h6d2b79f5);
        copy_case(1, 32, 32, MEMORY_BYTES-64, 25, 32'hc4f17a23);
        $display("SRAM_DMA_SEEDED_PAYLOAD ALL_PASSED cases=6");
        $display("SRAM DMA TEST PASSED: both directions, full tiles, bank boundaries, posted commits, errors, reset");
        $finish;
    end

    initial begin
        #20000000;
        $fatal(1, "Global SRAM DMA test timeout");
    end
endmodule
