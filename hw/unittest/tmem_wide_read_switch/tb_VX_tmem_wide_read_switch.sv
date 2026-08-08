`timescale 1ns/1ps

`include "VX_define.vh"

module tmem_wide_read_case import VX_gpu_pkg::*; #(
    parameter int CASE_ID        = 0,
    parameter int NUM_BANKS      = 8,
    parameter int DATA_SIZE      = 64,
    parameter int WIDE_DATA_SIZE = 64,
    parameter int TAG_WIDTH      = 8,
    parameter int MEM_ADDR_WIDTH = 34,
    parameter int OUTSTANDING    = 8
) (
    input  logic clk,
    input  logic reset,
    output logic done
);

    localparam int DATA_WIDTH       = DATA_SIZE * 8;
    localparam int BANKS_PER_BEAT   = WIDE_DATA_SIZE / DATA_SIZE;
    localparam int NUM_BANK_GROUPS  = NUM_BANKS / BANKS_PER_BEAT;
    localparam int BANK_SEL_BITS    = $clog2(NUM_BANKS);
    localparam int OUT_ADDR_WIDTH   = MEM_ADDR_WIDTH - $clog2(DATA_SIZE);
    localparam int OUT_TAG_WIDTH    = TAG_WIDTH + BANK_SEL_BITS;
    localparam int CTX_BITS         = (OUTSTANDING > 1) ? $clog2(OUTSTANDING) : 1;
    localparam logic [NUM_BANKS-1:0] BASE_MASK =
        {NUM_BANKS{1'b1}} >> (NUM_BANKS - BANKS_PER_BEAT);

    VX_mem_bus_if #(
        .DATA_SIZE      (WIDE_DATA_SIZE),
        .TAG_WIDTH      (TAG_WIDTH),
        .MEM_ADDR_WIDTH (MEM_ADDR_WIDTH)
    ) wide_if ();

    VX_mem_bus_if #(
        .DATA_SIZE      (DATA_SIZE),
        .TAG_WIDTH      (OUT_TAG_WIDTH),
        .MEM_ADDR_WIDTH (MEM_ADDR_WIDTH)
    ) bank_if [NUM_BANKS] ();

    logic [NUM_BANKS-1:0] bank_req_ready;
    wire  [NUM_BANKS-1:0] bank_req_valid;
    wire  [NUM_BANKS-1:0][OUT_ADDR_WIDTH-1:0] bank_req_addr;
    wire  [NUM_BANKS-1:0][DATA_WIDTH-1:0] bank_req_data;
    wire  [NUM_BANKS-1:0][DATA_SIZE-1:0] bank_req_byteen;
    wire  [NUM_BANKS-1:0][MEM_FLAGS_WIDTH-1:0] bank_req_flags;
    wire  [NUM_BANKS-1:0][OUT_TAG_WIDTH-1:0] bank_req_tag;

    logic [NUM_BANKS-1:0] bank_rsp_valid;
    logic [NUM_BANKS-1:0][DATA_WIDTH-1:0] bank_rsp_data;
    logic [NUM_BANKS-1:0][OUT_TAG_WIDTH-1:0] bank_rsp_tag;
    wire  [NUM_BANKS-1:0] bank_rsp_ready;

    VX_tmem_wide_read_switch #(
        .INSTANCE_ID    ("tb"),
        .NUM_BANKS      (NUM_BANKS),
        .DATA_SIZE      (DATA_SIZE),
        .WIDE_DATA_SIZE (WIDE_DATA_SIZE),
        .TAG_WIDTH      (TAG_WIDTH),
        .MEM_ADDR_WIDTH (MEM_ADDR_WIDTH),
        .OUTSTANDING    (OUTSTANDING)
    ) dut (
        .clk        (clk),
        .reset      (reset),
        .bus_in_if  (wide_if),
        .bus_out_if (bank_if)
    );

    for (genvar b = 0; b < NUM_BANKS; ++b) begin : g_bank_wires
        assign bank_if[b].req_ready = bank_req_ready[b];
        assign bank_req_valid[b] = bank_if[b].req_valid;
        assign bank_req_addr[b] = bank_if[b].req_data.addr;
        assign bank_req_data[b] = bank_if[b].req_data.data;
        assign bank_req_byteen[b] = bank_if[b].req_data.byteen;
        assign bank_req_flags[b] = bank_if[b].req_data.flags;
        assign bank_req_tag[b] = bank_if[b].req_data.tag;

        assign bank_if[b].rsp_valid = bank_rsp_valid[b];
        assign bank_if[b].rsp_data.data = bank_rsp_data[b];
        assign bank_if[b].rsp_data.tag = bank_rsp_tag[b];
        assign bank_rsp_ready[b] = bank_if[b].rsp_ready;
    end

    function automatic logic [TAG_WIDTH-1:0] transaction_tag(
        input int batch,
        input int transaction
    );
        logic [TAG_WIDTH-1:0] value;
        value = TAG_WIDTH'((batch + 1) * 8'h35);
        if (OUTSTANDING > 1)
            value[CTX_BITS-1:0] = CTX_BITS'(transaction);
        else
            value[0] = 1'b0;
        return value;
    endfunction

    function automatic int unsigned transaction_local_addr(
        input int batch,
        input int transaction
    );
        return 3 + batch * 16 + transaction;
    endfunction

    function automatic int unsigned transaction_wide_addr(
        input int batch,
        input int transaction
    );
        return transaction_local_addr(batch, transaction) * NUM_BANK_GROUPS
             + transaction;
    endfunction

    function automatic logic [WIDE_DATA_SIZE-1:0] transaction_byteen(
        input int batch,
        input int transaction
    );
        logic [WIDE_DATA_SIZE-1:0] value;
        value = '0;
        for (int lane = 0; lane < BANKS_PER_BEAT; ++lane) begin
            value[lane*DATA_SIZE +: DATA_SIZE] =
                {DATA_SIZE{1'b1}} ^ DATA_SIZE'(batch + transaction + lane);
        end
        return value;
    endfunction

    function automatic logic [MEM_FLAGS_WIDTH-1:0] transaction_flags(
        input int batch,
        input int transaction
    );
        return MEM_FLAGS_WIDTH'((CASE_ID << 4) | (batch << 3) | transaction);
    endfunction

    function automatic logic [DATA_WIDTH-1:0] response_pattern(
        input int batch,
        input int transaction,
        input int bank
    );
        logic [DATA_WIDTH-1:0] value;
        for (int byte_idx = 0; byte_idx < DATA_SIZE; ++byte_idx) begin
            value[byte_idx*8 +: 8] = 8'((CASE_ID * 53)
                                      + (batch * 41)
                                      + (transaction * 29)
                                      + (bank * 7)
                                      + byte_idx);
        end
        return value;
    endfunction

    function automatic logic [WIDE_DATA_SIZE*8-1:0] expected_response(
        input int batch,
        input int transaction
    );
        logic [WIDE_DATA_SIZE*8-1:0] value;
        int bank_base;
        value = '0;
        bank_base = transaction * BANKS_PER_BEAT;
        for (int lane = 0; lane < BANKS_PER_BEAT; ++lane) begin
            value[lane*DATA_WIDTH +: DATA_WIDTH] =
                response_pattern(batch, transaction, bank_base + lane);
        end
        return value;
    endfunction

    function automatic logic [NUM_BANKS-1:0] transaction_bank_mask(
        input int transaction
    );
        return BASE_MASK << (transaction * BANKS_PER_BEAT);
    endfunction

    task automatic drive_request(input int batch, input int transaction);
        logic [WIDE_DATA_SIZE*8-1:0] payload;
        payload = '0;
        for (int lane = 0; lane < BANKS_PER_BEAT; ++lane) begin
            payload[lane*DATA_WIDTH +: DATA_WIDTH] =
                DATA_WIDTH'((batch << 16) | (transaction << 8) | lane);
        end
        wide_if.req_valid = 1'b1;
        wide_if.req_data.rw = 1'b0;
        wide_if.req_data.addr = transaction_wide_addr(batch, transaction);
        wide_if.req_data.data = payload;
        wide_if.req_data.byteen = transaction_byteen(batch, transaction);
        wide_if.req_data.flags = transaction_flags(batch, transaction);
        wide_if.req_data.tag = transaction_tag(batch, transaction);
    endtask

    logic issue_monitor_enable;
    integer issue_batch;
    integer issue_accepted;
    integer issue_transaction;
    logic [NUM_BANKS-1:0] issue_seen;

    // Request-side scoreboard. It checks every cycle of a partially accepted
    // bank group, so a bank that has already fired cannot be reissued silently.
    always @(posedge clk) begin
        if (!reset && issue_monitor_enable) begin
            logic [NUM_BANKS-1:0] expected_mask;
            logic [NUM_BANKS-1:0] expected_remaining;
            logic [NUM_BANKS-1:0] fired;
            logic [NUM_BANKS-1:0] seen_next;

            if (bank_req_valid != '0) begin
                if (issue_transaction >= issue_accepted)
                    $fatal(1, "case%0d: bank request appeared before its wide request", CASE_ID);

                expected_mask = transaction_bank_mask(issue_transaction);
                expected_remaining = expected_mask & ~issue_seen;
                if (bank_req_valid !== expected_remaining)
                    $fatal(1, "case%0d tx%0d: bank valid got=%02h expected=%02h",
                           CASE_ID, issue_transaction, bank_req_valid, expected_remaining);

                for (int b = 0; b < NUM_BANKS; ++b) begin
                    if (bank_req_valid[b]) begin
                        int lane;
                        lane = b % BANKS_PER_BEAT;
                        if (bank_req_addr[b] !== OUT_ADDR_WIDTH'(
                                transaction_local_addr(issue_batch, issue_transaction)))
                            $fatal(1, "case%0d tx%0d bank%0d: local address mismatch",
                                   CASE_ID, issue_transaction, b);
                        if (bank_req_data[b] !== '0)
                            $fatal(1, "case%0d tx%0d bank%0d: read payload must be zero",
                                   CASE_ID, issue_transaction, b);
                        if (bank_req_byteen[b] !== transaction_byteen(
                                issue_batch, issue_transaction)[lane*DATA_SIZE +: DATA_SIZE])
                            $fatal(1, "case%0d tx%0d bank%0d: byte enable mismatch",
                                   CASE_ID, issue_transaction, b);
                        if (bank_req_flags[b] !== transaction_flags(
                                issue_batch, issue_transaction))
                            $fatal(1, "case%0d tx%0d bank%0d: flags mismatch",
                                   CASE_ID, issue_transaction, b);
                        if (bank_req_tag[b][TAG_WIDTH-1:0] !== transaction_tag(
                                issue_batch, issue_transaction))
                            $fatal(1, "case%0d tx%0d bank%0d: original tag mismatch",
                                   CASE_ID, issue_transaction, b);
                        if (bank_req_tag[b][OUT_TAG_WIDTH-1:TAG_WIDTH]
                            !== BANK_SEL_BITS'(b))
                            $fatal(1, "case%0d tx%0d bank%0d: bank tag prefix mismatch",
                                   CASE_ID, issue_transaction, b);
                    end
                end

                fired = bank_req_valid & bank_req_ready;
                seen_next = issue_seen | fired;
                if ((seen_next & expected_mask) == expected_mask) begin
                    issue_seen = '0;
                    issue_transaction = issue_transaction + 1;
                end else begin
                    issue_seen = seen_next;
                end
            end else if (issue_transaction < issue_accepted) begin
                $fatal(1, "case%0d tx%0d: pending bank request disappeared",
                       CASE_ID, issue_transaction);
            end

            if (wide_if.req_valid && wide_if.req_ready) begin
                if (issue_accepted >= OUTSTANDING)
                    $fatal(1, "case%0d: accepted request beyond configured depth", CASE_ID);
                if (wide_if.req_data.tag !== transaction_tag(issue_batch, issue_accepted))
                    $fatal(1, "case%0d tx%0d: accepted tag mismatch",
                           CASE_ID, issue_accepted);
                issue_accepted = issue_accepted + 1;
            end
        end
    end

    task automatic accept_batch(input int batch, input bit test_partial_ready);
        int stalled_bank;

        issue_batch = batch;
        issue_accepted = 0;
        issue_transaction = 0;
        issue_seen = '0;
        issue_monitor_enable = 1'b1;
        bank_req_ready = '1;
        stalled_bank = BANKS_PER_BEAT - 1;
        if (test_partial_ready && (BANKS_PER_BEAT > 1))
            bank_req_ready[stalled_bank] = 1'b0;

        // OUTSTANDING requests must be accepted on consecutive clocks.
        for (int t = 0; t < OUTSTANDING; ++t) begin
            @(negedge clk);
            if (wide_if.req_ready !== 1'b1)
                $fatal(1, "case%0d tx%0d: req_ready broke consecutive acceptance",
                       CASE_ID, t);
            drive_request(batch, t);
            @(posedge clk);
        end

        // The one-extra request is held for a full edge and must not fire.
        @(negedge clk);
        if (wide_if.req_ready !== 1'b0)
            $fatal(1, "case%0d: req_ready stayed high beyond depth %0d",
                   CASE_ID, OUTSTANDING);
        drive_request(batch, 0);
        @(posedge clk);
        @(negedge clk);
        if (wide_if.req_ready !== 1'b0)
            $fatal(1, "case%0d: full switch accepted the one-extra request", CASE_ID);
        wide_if.req_valid = 1'b0;

        // Releasing this bank after several clocks proves that the already
        // accepted banks were not duplicated while one bank was stalled.
        if (test_partial_ready && (BANKS_PER_BEAT > 1))
            bank_req_ready[stalled_bank] = 1'b1;

        wait (issue_transaction == OUTSTANDING);
        @(negedge clk);
        if (bank_req_valid !== '0)
            $fatal(1, "case%0d: bank request remained after issue drain", CASE_ID);
        if (issue_accepted != OUTSTANDING)
            $fatal(1, "case%0d: accepted=%0d expected=%0d",
                   CASE_ID, issue_accepted, OUTSTANDING);
        issue_monitor_enable = 1'b0;
    endtask

    task automatic send_context_lanes(
        input int batch,
        input int transaction,
        input int first_lane
    );
        int bank_base;
        bank_base = transaction * BANKS_PER_BEAT;
        @(negedge clk);
        bank_rsp_valid = '0;
        for (int lane = first_lane; lane < BANKS_PER_BEAT; ++lane) begin
            int b;
            b = bank_base + lane;
            bank_rsp_valid[b] = 1'b1;
            bank_rsp_data[b] = response_pattern(batch, transaction, b);
            bank_rsp_tag[b] = OUT_TAG_WIDTH'(
                {BANK_SEL_BITS'(b), transaction_tag(batch, transaction)});
        end
        #1;
        for (int lane = first_lane; lane < BANKS_PER_BEAT; ++lane) begin
            if (!bank_rsp_ready[bank_base + lane])
                $fatal(1, "case%0d tx%0d bank%0d: legal response not ready",
                       CASE_ID, transaction, bank_base + lane);
        end
        @(posedge clk);
        @(negedge clk);
        bank_rsp_valid = '0;
    endtask

    task automatic send_lane_all_contexts(input int batch, input int lane);
        @(negedge clk);
        bank_rsp_valid = '0;
        for (int t = 0; t < OUTSTANDING; ++t) begin
            int b;
            b = t * BANKS_PER_BEAT + lane;
            bank_rsp_valid[b] = 1'b1;
            bank_rsp_data[b] = response_pattern(batch, t, b);
            bank_rsp_tag[b] = OUT_TAG_WIDTH'(
                {BANK_SEL_BITS'(b), transaction_tag(batch, t)});
        end
        #1;
        for (int t = 0; t < OUTSTANDING; ++t) begin
            int b;
            b = t * BANKS_PER_BEAT + lane;
            if (!bank_rsp_ready[b])
                $fatal(1, "case%0d tx%0d bank%0d: simultaneous response not ready",
                       CASE_ID, t, b);
        end
        @(posedge clk);
        @(negedge clk);
        bank_rsp_valid = '0;
    endtask

    task automatic respond_reversed_skewed(input int batch);
        // With multiple lanes, the first lane of every context returns on the
        // same clock. Remaining lanes then complete contexts in reverse order.
        if (BANKS_PER_BEAT > 1) begin
            send_lane_all_contexts(batch, 0);
            for (int t = OUTSTANDING - 1; t >= 0; --t)
                send_context_lanes(batch, t, 1);
        end else begin
            // WLOAD4 has one lane per context, so reverse completion itself is
            // the meaningful response-order stress for this variant.
            for (int t = OUTSTANDING - 1; t >= 0; --t)
                send_context_lanes(batch, t, 0);
        end
    endtask

    task automatic respond_ordered(input int batch);
        for (int t = 0; t < OUTSTANDING; ++t)
            send_context_lanes(batch, t, 0);
    endtask

    task automatic retire_batch(input int batch);
        logic [WIDE_DATA_SIZE*8-1:0] held_data;
        logic [TAG_WIDTH-1:0] held_tag;

        @(negedge clk);
        if (!wide_if.rsp_valid)
            $fatal(1, "case%0d: head response did not become valid", CASE_ID);
        if (wide_if.rsp_data.tag !== transaction_tag(batch, 0)
         || wide_if.rsp_data.data !== expected_response(batch, 0))
            $fatal(1, "case%0d: first in-order response mismatch", CASE_ID);
        if (wide_if.req_ready !== 1'b0)
            $fatal(1, "case%0d: req_ready asserted before a full-context retire", CASE_ID);

        held_data = wide_if.rsp_data.data;
        held_tag = wide_if.rsp_data.tag;
        repeat (2) begin
            @(posedge clk);
            @(negedge clk);
            if (!wide_if.rsp_valid
             || wide_if.rsp_data.data !== held_data
             || wide_if.rsp_data.tag !== held_tag)
                $fatal(1, "case%0d: response changed under upstream backpressure",
                       CASE_ID);
        end

        wide_if.rsp_ready = 1'b1;
        for (int t = 0; t < OUTSTANDING; ++t) begin
            if (!wide_if.rsp_valid)
                $fatal(1, "case%0d tx%0d: missing in-order response", CASE_ID, t);
            if (wide_if.rsp_data.tag !== transaction_tag(batch, t))
                $fatal(1, "case%0d tx%0d: retire tag got=%0h expected=%0h",
                       CASE_ID, t, wide_if.rsp_data.tag, transaction_tag(batch, t));
            if (wide_if.rsp_data.data !== expected_response(batch, t))
                $fatal(1, "case%0d tx%0d: assembled response data mismatch",
                       CASE_ID, t);
            @(posedge clk);
            @(negedge clk);
            if (t == 0 && wide_if.req_ready !== 1'b1)
                $fatal(1, "case%0d: req_ready did not return one cycle after retire",
                       CASE_ID);
        end
        wide_if.rsp_ready = 1'b0;
        if (wide_if.rsp_valid !== 1'b0 || wide_if.req_ready !== 1'b1)
            $fatal(1, "case%0d: switch did not empty after ordered retirement", CASE_ID);
    endtask

    task automatic run_negative(input string mode);
        logic [TAG_WIDTH-1:0] tag;
        int bank;

        tag = transaction_tag(0, 0);
        bank = 0;
        wide_if.req_valid = 1'b0;
        wide_if.rsp_ready = 1'b0;
        bank_req_ready = '0;
        bank_rsp_valid = '0;
        bank_rsp_data = '0;
        bank_rsp_tag = '0;

        if (mode == "write") begin
            @(negedge clk);
            bank_req_ready = '1;
            drive_request(0, 0);
            wide_if.req_data.rw = 1'b1;
            if (!wide_if.req_ready)
                $fatal(1, "negative write setup: request was not ready");
            @(posedge clk);
        end else if (mode == "duplicate_context") begin
            @(negedge clk);
            bank_req_ready = '1;
            drive_request(0, 0);
            if (!wide_if.req_ready)
                $fatal(1, "negative duplicate_context setup: first request was not ready");
            @(posedge clk);
            @(negedge clk);
            // A different full tag with the same low slot bits must collide
            // with the still-live context zero.
            drive_request(1, 0);
            if (!wide_if.req_ready)
                $fatal(1, "negative duplicate_context setup: second request was not ready");
            @(posedge clk);
        end else if (mode == "free_context_response") begin
            @(negedge clk);
            bank_rsp_valid[bank] = 1'b1;
            bank_rsp_data[bank] = response_pattern(0, 0, bank);
            bank_rsp_tag[bank] = OUT_TAG_WIDTH'(
                {BANK_SEL_BITS'(bank), tag});
            @(posedge clk);
        end else if (mode == "unissued_response") begin
            @(negedge clk);
            drive_request(0, 0);
            if (!wide_if.req_ready)
                $fatal(1, "negative unissued_response setup: request was not ready");
            @(posedge clk);
            @(negedge clk);
            wide_if.req_valid = 1'b0;
            // No bank request can handshake while ready remains zero.
            bank_rsp_valid[bank] = 1'b1;
            bank_rsp_data[bank] = response_pattern(0, 0, bank);
            bank_rsp_tag[bank] = OUT_TAG_WIDTH'(
                {BANK_SEL_BITS'(bank), tag});
            @(posedge clk);
        end else if (mode == "duplicate_response") begin
            @(negedge clk);
            bank_req_ready = '1;
            drive_request(0, 0);
            if (!wide_if.req_ready)
                $fatal(1, "negative duplicate_response setup: request was not ready");
            @(posedge clk);
            @(negedge clk);
            wide_if.req_valid = 1'b0;
            @(posedge clk);
            // Keep the same valid response asserted for two clocks. The first
            // is collected and the second must be rejected as a duplicate.
            @(negedge clk);
            bank_rsp_valid[bank] = 1'b1;
            bank_rsp_data[bank] = response_pattern(0, 0, bank);
            bank_rsp_tag[bank] = OUT_TAG_WIDTH'(
                {BANK_SEL_BITS'(bank), tag});
            @(posedge clk);
            @(negedge clk);
            @(posedge clk);
        end else begin
            $fatal(1, "unknown NEGATIVE mode '%s'", mode);
        end

        @(negedge clk);
        $fatal(1, "negative mode '%s' did not trigger the expected DUT fatal", mode);
    endtask

    string negative_mode;
    bit negative_enabled;

    initial begin
        done = 1'b0;
        wide_if.req_valid = 1'b0;
        wide_if.req_data = '0;
        wide_if.rsp_ready = 1'b0;
        bank_req_ready = '0;
        bank_rsp_valid = '0;
        bank_rsp_data = '0;
        bank_rsp_tag = '0;
        issue_monitor_enable = 1'b0;
        issue_batch = 0;
        issue_accepted = 0;
        issue_transaction = 0;
        issue_seen = '0;

        negative_enabled = $value$plusargs("NEGATIVE=%s", negative_mode);
        if (negative_enabled && (CASE_ID != 1)) begin
            // Expected-fatal runs use only the WLOAD8 instance so no other
            // case can race the DUT assertion under test.
            done = 1'b1;
        end else begin
            wait (!reset);
            repeat (2) @(posedge clk);

            if (negative_enabled) begin
                run_negative(negative_mode);
            end else begin
                // Batch 0: depth/full behavior, simultaneous responses, skew,
                // reverse completion, in-order retire, and response backpressure.
                accept_batch(0, 1'b0);
                respond_reversed_skewed(0);
                retire_batch(0);

                // Batch 1: partial bank readiness with no duplicate issue,
                // followed by responses in request order. WLOAD4 has one bank
                // per request, so it has no within-group partial-ready case.
                accept_batch(1, 1'b1);
                respond_ordered(1);
                retire_batch(1);

                done = 1'b1;
                $display("case%0d PASS: WIDE_DATA_SIZE=%0d OUTSTANDING=%0d BANKS_PER_BEAT=%0d",
                         CASE_ID, WIDE_DATA_SIZE, OUTSTANDING, BANKS_PER_BEAT);
            end
        end
    end

endmodule

module tb_VX_tmem_wide_read_switch;
    logic clk = 1'b0;
    logic reset = 1'b1;
    logic [3:0] done;

    always #5 clk = ~clk;

    tmem_wide_read_case #(
        .CASE_ID(0), .WIDE_DATA_SIZE(64), .OUTSTANDING(8)
    ) case_wload4 (.clk(clk), .reset(reset), .done(done[0]));
    tmem_wide_read_case #(
        .CASE_ID(1), .WIDE_DATA_SIZE(128), .OUTSTANDING(4)
    ) case_wload8 (.clk(clk), .reset(reset), .done(done[1]));
    tmem_wide_read_case #(
        .CASE_ID(2), .WIDE_DATA_SIZE(256), .OUTSTANDING(2)
    ) case_wload16 (.clk(clk), .reset(reset), .done(done[2]));
    tmem_wide_read_case #(
        .CASE_ID(3), .WIDE_DATA_SIZE(512), .OUTSTANDING(1)
    ) case_wload32 (.clk(clk), .reset(reset), .done(done[3]));

    initial begin
        repeat (5) @(posedge clk);
        reset = 1'b0;
        fork
            begin
                wait (&done);
                $display("PASSED: TMEM wide-read multi-outstanding 8/4/2/1 cases");
                $finish;
            end
            begin
                repeat (1500) @(posedge clk);
                $fatal(1, "timeout waiting for TMEM wide-read multi-outstanding cases");
            end
        join_any
    end

endmodule
