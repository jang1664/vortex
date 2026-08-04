`timescale 1ns/1ps

`include "VX_define.vh"

module tmem_wide_read_case import VX_gpu_pkg::*; #(
    parameter int CASE_ID        = 0,
    parameter int NUM_BANKS      = 8,
    parameter int DATA_SIZE      = 64,
    parameter int WIDE_DATA_SIZE = 64,
    parameter int TAG_WIDTH      = 8,
    parameter int MEM_ADDR_WIDTH = 34
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
    localparam logic [NUM_BANKS-1:0] BASE_MASK =
        {NUM_BANKS{1'b1}} >> (NUM_BANKS - BANKS_PER_BEAT);

    VX_mem_bus_if #(
        .DATA_SIZE     (WIDE_DATA_SIZE),
        .TAG_WIDTH     (TAG_WIDTH),
        .MEM_ADDR_WIDTH(MEM_ADDR_WIDTH)
    ) wide_if ();

    VX_mem_bus_if #(
        .DATA_SIZE     (DATA_SIZE),
        .TAG_WIDTH     (OUT_TAG_WIDTH),
        .MEM_ADDR_WIDTH(MEM_ADDR_WIDTH)
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
        .MEM_ADDR_WIDTH (MEM_ADDR_WIDTH)
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

    function automatic logic [DATA_WIDTH-1:0] response_pattern(
        input int transaction,
        input int bank
    );
        logic [DATA_WIDTH-1:0] value;
        for (int byte_idx = 0; byte_idx < DATA_SIZE; ++byte_idx) begin
            value[byte_idx*8 +: 8] = 8'((CASE_ID * 53)
                                      + (transaction * 29)
                                      + (bank * 7)
                                      + byte_idx);
        end
        return value;
    endfunction

    task automatic check_bank_request(
        input logic [NUM_BANKS-1:0] expected_mask,
        input int unsigned expected_local_addr,
        input logic [TAG_WIDTH-1:0] expected_tag,
        input logic [WIDE_DATA_SIZE*8-1:0] expected_data,
        input logic [WIDE_DATA_SIZE-1:0] expected_byteen,
        input logic [MEM_FLAGS_WIDTH-1:0] expected_flags
    );
        if (bank_req_valid !== expected_mask)
            $fatal(1, "case%0d: req mask got=%b expected=%b",
                   CASE_ID, bank_req_valid, expected_mask);
        for (int b = 0; b < NUM_BANKS; ++b) begin
            if (expected_mask[b]) begin
                int lane = b % BANKS_PER_BEAT;
                if (bank_req_addr[b] !== OUT_ADDR_WIDTH'(expected_local_addr))
                    $fatal(1, "case%0d bank%0d: addr got=%0h expected=%0h",
                           CASE_ID, b, bank_req_addr[b], expected_local_addr);
                if (bank_req_data[b] !== expected_data[lane*DATA_WIDTH +: DATA_WIDTH])
                    $fatal(1, "case%0d bank%0d: request data lane mismatch", CASE_ID, b);
                if (bank_req_byteen[b] !== expected_byteen[lane*DATA_SIZE +: DATA_SIZE])
                    $fatal(1, "case%0d bank%0d: byteen lane mismatch", CASE_ID, b);
                if (bank_req_flags[b] !== expected_flags)
                    $fatal(1, "case%0d bank%0d: flags mismatch", CASE_ID, b);
                if (bank_req_tag[b][TAG_WIDTH-1:0] !== expected_tag)
                    $fatal(1, "case%0d bank%0d: restored tag portion mismatch", CASE_ID, b);
                if (bank_req_tag[b][OUT_TAG_WIDTH-1:TAG_WIDTH] !== BANK_SEL_BITS'(b))
                    $fatal(1, "case%0d bank%0d: bank tag prefix got=%0h expected=%0h full=%0h",
                           CASE_ID, b,
                           bank_req_tag[b][OUT_TAG_WIDTH-1:TAG_WIDTH],
                           BANK_SEL_BITS'(b), bank_req_tag[b]);
            end
        end
    endtask

    task automatic run_transaction(
        input int transaction,
        input int unsigned group,
        input int unsigned local_addr,
        input logic [TAG_WIDTH-1:0] tag,
        input bit stall_one_request
    );
        logic [NUM_BANKS-1:0] expected_mask;
        logic [WIDE_DATA_SIZE*8-1:0] request_data;
        logic [WIDE_DATA_SIZE-1:0] request_byteen;
        logic [WIDE_DATA_SIZE*8-1:0] expected_rsp_data;
        logic [MEM_FLAGS_WIDTH-1:0] request_flags;
        logic [NUM_BANKS-1:0] responded_mask;
        int unsigned wide_addr;
        int unsigned bank_base;
        int stalled_bank;

        bank_base = group * BANKS_PER_BEAT;
        expected_mask = BASE_MASK << bank_base;
        wide_addr = local_addr * NUM_BANK_GROUPS + group;
        stalled_bank = bank_base + BANKS_PER_BEAT - 1;
        request_data = '0;
        request_byteen = '0;
        expected_rsp_data = '0;
        responded_mask = '0;
        request_flags = MEM_FLAGS_WIDTH'((CASE_ID << 1) | transaction);
        for (int lane = 0; lane < BANKS_PER_BEAT; ++lane) begin
            request_data[lane*DATA_WIDTH +: DATA_WIDTH] =
                DATA_WIDTH'((transaction << 12) | (CASE_ID << 8) | lane);
            request_byteen[lane*DATA_SIZE +: DATA_SIZE] =
                {DATA_SIZE{1'b1}} ^ DATA_SIZE'(lane);
            expected_rsp_data[lane*DATA_WIDTH +: DATA_WIDTH] =
                response_pattern(transaction, bank_base + lane);
        end

        @(negedge clk);
        bank_req_ready = '1;
        if (stall_one_request)
            bank_req_ready[stalled_bank] = 1'b0;
        wide_if.req_valid = 1'b1;
        wide_if.req_data.rw = 1'b0;
        wide_if.req_data.addr = wide_addr;
        wide_if.req_data.data = request_data;
        wide_if.req_data.byteen = request_byteen;
        wide_if.req_data.flags = request_flags;
        wide_if.req_data.tag = tag;

        @(posedge clk);
        @(negedge clk);
        wide_if.req_valid = 1'b0;
        if (wide_if.req_ready !== 1'b0)
            $fatal(1, "case%0d: accepted a second request while busy", CASE_ID);
        check_bank_request(expected_mask, local_addr, tag,
                           request_data, request_byteen, request_flags);

        @(posedge clk);
        @(negedge clk);
        if (stall_one_request) begin
            check_bank_request(NUM_BANKS'(1'b1) << stalled_bank,
                               local_addr, tag, request_data,
                               request_byteen, request_flags);
            bank_req_ready[stalled_bank] = 1'b1;
            @(posedge clk);
            @(negedge clk);
        end

        if (bank_req_valid !== '0)
            $fatal(1, "case%0d: bank request remained valid after all accepts", CASE_ID);
        if (bank_rsp_ready !== expected_mask)
            $fatal(1, "case%0d: response ready mask got=%b expected=%b",
                   CASE_ID, bank_rsp_ready, expected_mask);

        wide_if.rsp_ready = 1'b0;
        for (int lane = BANKS_PER_BEAT - 1; lane >= 0; --lane) begin
            int b = bank_base + lane;
            bank_rsp_valid[b] = 1'b1;
            bank_rsp_data[b] = response_pattern(transaction, b);
            bank_rsp_tag[b] = OUT_TAG_WIDTH'({BANK_SEL_BITS'(b), tag});
            #1;
            if (bank_rsp_ready !== (expected_mask & ~responded_mask))
                $fatal(1, "case%0d bank%0d: skew response ready mask got=%b",
                       CASE_ID, b, bank_rsp_ready);
            @(posedge clk);
            @(negedge clk);
            bank_rsp_valid[b] = 1'b0;
            responded_mask[b] = 1'b1;
        end

        if (wide_if.rsp_valid !== 1'b1)
            $fatal(1, "case%0d: assembled response did not become valid", CASE_ID);
        if (wide_if.rsp_data.data !== expected_rsp_data)
            $fatal(1, "case%0d: assembled response data mismatch", CASE_ID);
        if (wide_if.rsp_data.tag !== tag)
            $fatal(1, "case%0d: assembled response tag got=%0h expected=%0h",
                   CASE_ID, wide_if.rsp_data.tag, tag);
        if (wide_if.req_ready !== 1'b0)
            $fatal(1, "case%0d: request ready asserted under response backpressure", CASE_ID);

        repeat (2) begin
            @(posedge clk);
            @(negedge clk);
            if (!wide_if.rsp_valid || wide_if.rsp_data.data !== expected_rsp_data)
                $fatal(1, "case%0d: response changed under backpressure", CASE_ID);
        end

        wide_if.rsp_ready = 1'b1;
        @(posedge clk);
        @(negedge clk);
        wide_if.rsp_ready = 1'b0;
        if (wide_if.rsp_valid !== 1'b0 || wide_if.req_ready !== 1'b1)
            $fatal(1, "case%0d: switch did not return idle after response", CASE_ID);
    endtask

    initial begin
        done = 1'b0;
        wide_if.req_valid = 1'b0;
        wide_if.req_data = '0;
        wide_if.rsp_ready = 1'b0;
        bank_req_ready = '0;
        bank_rsp_valid = '0;
        bank_rsp_data = '0;
        bank_rsp_tag = '0;

        wait (!reset);
        repeat (2) @(posedge clk);
        run_transaction(0, NUM_BANK_GROUPS - 1, 2, TAG_WIDTH'(8'h35), 1'b0);
        run_transaction(1, 0, 5, TAG_WIDTH'(8'hA6), 1'b1);
        done = 1'b1;
        $display("case%0d PASS: WIDE_DATA_SIZE=%0d BANKS_PER_BEAT=%0d",
                 CASE_ID, WIDE_DATA_SIZE, BANKS_PER_BEAT);
    end

endmodule

module tb_VX_tmem_wide_read_switch;
    logic clk = 1'b0;
    logic reset = 1'b1;
    logic [3:0] done;

    always #5 clk = ~clk;

    tmem_wide_read_case #(.CASE_ID(0), .WIDE_DATA_SIZE(64))  case_wload4
        (.clk(clk), .reset(reset), .done(done[0]));
    tmem_wide_read_case #(.CASE_ID(1), .WIDE_DATA_SIZE(128)) case_wload8
        (.clk(clk), .reset(reset), .done(done[1]));
    tmem_wide_read_case #(.CASE_ID(2), .WIDE_DATA_SIZE(256)) case_wload16
        (.clk(clk), .reset(reset), .done(done[2]));
    tmem_wide_read_case #(.CASE_ID(3), .WIDE_DATA_SIZE(512)) case_wload32
        (.clk(clk), .reset(reset), .done(done[3]));

    initial begin
        repeat (5) @(posedge clk);
        reset = 1'b0;
        fork
            begin
                wait (&done);
                $display("PASSED: TMEM partial-wide read switch 1/2/4/8-bank cases");
                $finish;
            end
            begin
                repeat (500) @(posedge clk);
                $fatal(1, "timeout waiting for TMEM wide-read cases");
            end
        join_any
    end

endmodule
