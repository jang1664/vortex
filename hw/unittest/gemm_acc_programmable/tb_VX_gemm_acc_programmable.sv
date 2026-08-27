`timescale 1ns / 1ps
`include "VX_define.vh"

module tb_VX_gemm_acc_programmable;
    localparam PERIOD = 10;
    localparam DATAW = `MXU_COL * 32;
    localparam ROW_BYTES = DATAW / 8;
    localparam logic [`GEMM_ACC_MEM_ADDR_WIDTH-1:0] ADDR3
        = `GEMM_ACC_MEM_ADDR_WIDTH'(3 * ROW_BYTES);
    localparam logic [`GEMM_ACC_MEM_ADDR_WIDTH-1:0] ADDR4
        = `GEMM_ACC_MEM_ADDR_WIDTH'(4 * ROW_BYTES);
    localparam logic [`GEMM_ACC_MEM_ADDR_WIDTH-1:0] ADDR5
        = `GEMM_ACC_MEM_ADDR_WIDTH'(5 * ROW_BYTES);
    localparam logic [`GEMM_ACC_MEM_ADDR_WIDTH-1:0] ADDR6
        = `GEMM_ACC_MEM_ADDR_WIDTH'(6 * ROW_BYTES);
    logic clk;
    logic reset;
    logic [DATAW-1:0] held_rsp_data;
    logic [31:0] held_rsp_tag;
    logic [31:0] rsp_tags[$];
    logic [DATAW-1:0] rsp_data_by_tag [0:255];
    logic rsp_seen [0:255];
    logic [DATAW-1:0] model_mem [0:15];
    logic latency_seen [1:15];
    integer accepted_txn_count;
    integer accepted_read_count;
    integer accepted_write_count;
    integer response_count;
    integer read_stall_cycles;
    integer write_stall_cycles;
    integer response_hold_cycles;
    integer outstanding_reads;
    integer max_outstanding_reads;
    integer max_txn_count;
    integer random_seed;

    VX_gemm_acc_if acc_if ();
    VX_gemm_acc_programmable #(
        .MEM_DEPTH (16),
        .MIN_READ_LATENCY (1),
        .MAX_READ_LATENCY (15),
        .READ_BACKPRESSURE (1),
        .WRITE_BACKPRESSURE (1)
    ) u_dut (
        .clk (clk),
        .reset (reset),
        .acc_if (acc_if)
    );

    initial clk = 1'b0;
    always #(PERIOD/2) clk = ~clk;
    always @(posedge clk) begin
        integer rsp_idx;
        integer latency_class;
        if (reset) begin
            outstanding_reads = 0;
        end else begin
            if (acc_if.txn_accept_valid)
                accepted_txn_count++;
            if (acc_if.rd_req_valid && !acc_if.rd_req_ready)
                read_stall_cycles++;
            if (acc_if.wr_req_valid && !acc_if.wr_req_ready)
                write_stall_cycles++;
            if (acc_if.rd_rsp_valid && !acc_if.rd_rsp_ready)
                response_hold_cycles++;
            if (acc_if.rd_req_valid && acc_if.rd_req_ready) begin
                accepted_read_count++;
                outstanding_reads++;
                if (outstanding_reads > max_outstanding_reads)
                    max_outstanding_reads = outstanding_reads;
                latency_class = 1 + (int'(acc_if.rd_req_tag) % 15);
                latency_seen[latency_class] = 1'b1;
            end
            if (acc_if.wr_req_valid && acc_if.wr_req_ready)
                accepted_write_count++;
            if (acc_if.rd_rsp_valid && acc_if.rd_rsp_ready) begin
                rsp_idx = int'(acc_if.rd_rsp_tag[7:0]);
                assert (!rsp_seen[rsp_idx])
                    else $fatal(1, "duplicate response tag=%0d",
                                acc_if.rd_rsp_tag);
                rsp_seen[rsp_idx] = 1'b1;
                rsp_data_by_tag[rsp_idx] = acc_if.rd_rsp_data;
                response_count++;
                outstanding_reads--;
                assert (outstanding_reads >= 0)
                    else $fatal(1, "response without outstanding request");
            end
            if (int'(u_dut.txn_count) > max_txn_count)
                max_txn_count = int'(u_dut.txn_count);
        end
        if (!reset && acc_if.rd_rsp_valid && acc_if.rd_rsp_ready)
            rsp_tags.push_back(acc_if.rd_rsp_tag);
    end

    function automatic logic [`GEMM_ACC_MEM_ADDR_WIDTH-1:0] row_addr(
        input integer row
    );
        return `GEMM_ACC_MEM_ADDR_WIDTH'(row * ROW_BYTES);
    endfunction

    task automatic defaults;
        acc_if.rd_req_valid = 1'b0;
        acc_if.rd_req_tag = '0;
        acc_if.rd_req_addr = '0;
        acc_if.rd_dependency_valid = 1'b0;
        acc_if.rd_dependency_addr = '0;
        acc_if.rd_rsp_ready = 1'b1;
        acc_if.wr_req_valid = 1'b0;
        acc_if.wr_req_tag = '0;
        acc_if.wr_req_addr = '0;
        acc_if.wr_req_data = '0;
        acc_if.wr_req_final_output = 1'b0;
        acc_if.wr_req_last = 1'b0;
        acc_if.txn_accept_valid = 1'b0;
        acc_if.txn_accept_tag = '0;
        acc_if.txn_accept_rd_en = 1'b0;
        acc_if.txn_accept_wr_en = 1'b0;
        acc_if.txn_accept_rd_addr = '0;
        acc_if.txn_accept_wr_addr = '0;
        acc_if.txn_retire_valid = 1'b0;
        acc_if.txn_retire_tag = '0;
        acc_if.txn_retire_rd_en = 1'b0;
        acc_if.txn_retire_wr_en = 1'b0;
        acc_if.txn_retire_rd_addr = '0;
        acc_if.txn_retire_wr_addr = '0;
    endtask

    task automatic accept_txn(
        input logic [31:0] tag,
        input logic rd_en,
        input logic wr_en,
        input logic [`GEMM_ACC_MEM_ADDR_WIDTH-1:0] addr
    );
        @(negedge clk);
        acc_if.txn_accept_valid = 1'b1;
        acc_if.txn_accept_tag = tag;
        acc_if.txn_accept_rd_en = rd_en;
        acc_if.txn_accept_wr_en = wr_en;
        acc_if.txn_accept_rd_addr = addr;
        acc_if.txn_accept_wr_addr = addr;
        @(posedge clk);
        @(negedge clk);
        acc_if.txn_accept_valid = 1'b0;
    endtask

    task automatic retire_txn(
        input logic [31:0] tag,
        input logic rd_en,
        input logic wr_en,
        input logic [`GEMM_ACC_MEM_ADDR_WIDTH-1:0] addr
    );
        @(negedge clk);
        acc_if.txn_retire_valid = 1'b1;
        acc_if.txn_retire_tag = tag;
        acc_if.txn_retire_rd_en = rd_en;
        acc_if.txn_retire_wr_en = wr_en;
        acc_if.txn_retire_rd_addr = addr;
        acc_if.txn_retire_wr_addr = addr;
        @(posedge clk);
        @(negedge clk);
        acc_if.txn_retire_valid = 1'b0;
    endtask

    task automatic write_acc(
        input logic [31:0] tag,
        input logic [`GEMM_ACC_MEM_ADDR_WIDTH-1:0] addr,
        input logic [DATAW-1:0] data
    );
        @(negedge clk);
        acc_if.wr_req_valid = 1'b1;
        acc_if.wr_req_tag = tag;
        acc_if.wr_req_addr = addr;
        acc_if.wr_req_data = data;
        while (!acc_if.wr_req_ready) begin
            @(posedge clk);
            assert (acc_if.wr_req_tag == tag && acc_if.wr_req_data == data)
                else $fatal(1, "write request changed while stalled");
            @(negedge clk);
        end
        @(posedge clk);
        @(negedge clk);
        acc_if.wr_req_valid = 1'b0;
    endtask

    task automatic request_read(
        input logic [31:0] tag,
        input logic [`GEMM_ACC_MEM_ADDR_WIDTH-1:0] addr
    );
        @(negedge clk);
        acc_if.rd_req_valid = 1'b1;
        acc_if.rd_req_tag = tag;
        acc_if.rd_req_addr = addr;
        while (!acc_if.rd_req_ready) begin
            @(posedge clk);
            assert (acc_if.rd_req_tag == tag && acc_if.rd_req_addr == addr)
                else $fatal(1, "read request changed while stalled");
            @(negedge clk);
        end
        @(posedge clk);
        @(negedge clk);
        acc_if.rd_req_valid = 1'b0;
    endtask

    task automatic wait_response(
        input logic [31:0] tag,
        input logic [DATAW-1:0] expected_data
    );
        integer timeout;
        timeout = 0;
        while (!rsp_seen[int'(tag[7:0])] && timeout < 256) begin
            @(posedge clk);
            timeout++;
        end
        assert (rsp_seen[int'(tag[7:0])])
            else $fatal(1, "timeout waiting for response tag=%0d", tag);
        assert (rsp_data_by_tag[int'(tag[7:0])] == expected_data)
            else $fatal(1, "response data mismatch tag=%0d", tag);
    endtask

    task automatic run_raw_chain(
        input logic [31:0] base_tag,
        input integer gap,
        input logic [`GEMM_ACC_MEM_ADDR_WIDTH-1:0] addr,
        input logic [DATAW-1:0] data
    );
        logic [31:0] reader_tag;
        reader_tag = base_tag + 32'(gap + 1);
        accept_txn(base_tag, 1'b0, 1'b1, addr);
        for (int i = 0; i < gap; ++i)
            accept_txn(base_tag + 32'(i + 1), 1'b0, 1'b0,
                       row_addr((int'(base_tag) + i) % 16));
        accept_txn(reader_tag, 1'b1, 1'b0, addr);

        @(negedge clk);
        acc_if.rd_req_valid = 1'b1;
        acc_if.rd_req_tag = reader_tag;
        acc_if.rd_req_addr = addr;
        repeat (3) begin
            @(posedge clk);
            assert (!acc_if.rd_req_ready)
                else $fatal(1,
                    "d%0d RAW read escaped older writer", gap + 1);
            @(negedge clk);
        end
        acc_if.rd_req_valid = 1'b0;

        write_acc(base_tag, addr, data);
        retire_txn(base_tag, 1'b0, 1'b1, addr);
        for (int i = 0; i < gap; ++i)
            retire_txn(base_tag + 32'(i + 1), 1'b0, 1'b0,
                       row_addr((int'(base_tag) + i) % 16));
        request_read(reader_tag, addr);
        wait_response(reader_tag, data);
        retire_txn(reader_tag, 1'b1, 1'b0, addr);
    endtask

    task automatic run_mixed_transactions;
        logic [31:0] tag;
        logic [DATAW-1:0] next_data;
        integer row;
        integer timeout;
        logic group_done;

        for (int i = 0; i < 16; ++i) begin
            model_mem[i] = DATAW'(32'h1000 + i);
            write_acc(32'(200 + i), row_addr(i), model_mem[i]);
        end

        for (int group = 0; group < 16; ++group) begin
            for (int lane = 0; lane < 4; ++lane) begin
                tag = 32'(100 + 4 * group + lane);
                row = (5 * group + lane) % 16;
                accept_txn(tag, 1'b1, tag[0], row_addr(row));
            end

            if (group == 0)
                acc_if.rd_rsp_ready = 1'b0;
            for (int lane = 0; lane < 4; ++lane) begin
                tag = 32'(100 + 4 * group + lane);
                row = (5 * group + lane) % 16;
                request_read(tag, row_addr(row));
            end
            if (group == 0) begin
                assert (outstanding_reads == 4)
                    else $fatal(1,
                        "four-outstanding coverage missed outstanding=%0d",
                        outstanding_reads);
            end

            timeout = 0;
            group_done = 1'b0;
            while (!group_done && timeout < 512) begin
                @(negedge clk);
                acc_if.rd_rsp_ready = ($urandom_range(0, 3) != 0);
                group_done = 1'b1;
                for (int lane = 0; lane < 4; ++lane) begin
                    tag = 32'(100 + 4 * group + lane);
                    if (!rsp_seen[int'(tag[7:0])])
                        group_done = 1'b0;
                end
                timeout++;
            end
            acc_if.rd_rsp_ready = 1'b1;
            assert (group_done)
                else $fatal(1, "mixed response group timeout group=%0d",
                            group);

            for (int lane = 0; lane < 4; ++lane) begin
                tag = 32'(100 + 4 * group + lane);
                row = (5 * group + lane) % 16;
                assert (rsp_data_by_tag[int'(tag[7:0])] == model_mem[row])
                    else $fatal(1,
                        "mixed response mismatch group=%0d lane=%0d tag=%0d",
                        group, lane, tag);
                if (tag[0]) begin
                    next_data = model_mem[row] ^ DATAW'(tag);
                    write_acc(tag, row_addr(row), next_data);
                    model_mem[row] = next_data;
                end
            end
            for (int lane = 0; lane < 4; ++lane) begin
                tag = 32'(100 + 4 * group + lane);
                row = (5 * group + lane) % 16;
                retire_txn(tag, 1'b1, tag[0], row_addr(row));
            end
        end
    endtask

    initial begin
        accepted_txn_count = 0;
        accepted_read_count = 0;
        accepted_write_count = 0;
        response_count = 0;
        read_stall_cycles = 0;
        write_stall_cycles = 0;
        response_hold_cycles = 0;
        outstanding_reads = 0;
        max_outstanding_reads = 0;
        max_txn_count = 0;
        random_seed = 32'h5eed1234;
        void'($urandom(random_seed));
        for (int i = 0; i < 256; ++i) begin
            rsp_seen[i] = 1'b0;
            rsp_data_by_tag[i] = '0;
        end
        for (int i = 1; i <= 15; ++i)
            latency_seen[i] = 1'b0;
        defaults();
        reset = 1'b1;
        repeat (4) @(posedge clk);
        @(negedge clk);
        reset = 1'b0;

        // A younger same-address read is fenced by the accepted older writer
        // until the write is physically accepted and retired.
        accept_txn(32'd1, 1'b0, 1'b1, ADDR3);
        accept_txn(32'd2, 1'b1, 1'b0, ADDR3);
        @(negedge clk);
        acc_if.rd_req_valid = 1'b1;
        acc_if.rd_req_tag = 32'd2;
        acc_if.rd_req_addr = ADDR3;
        repeat (3) begin
            @(posedge clk);
            assert (!acc_if.rd_req_ready)
                else $fatal(1, "same-address RAW read escaped older writer");
            @(negedge clk);
        end
        acc_if.rd_req_valid = 1'b0;
        write_acc(32'd1, ADDR3, DATAW'(256'h1234));
        retire_txn(32'd1, 1'b0, 1'b1, ADDR3);
        request_read(32'd2, ADDR3);

        wait (acc_if.rd_rsp_valid);
        assert (acc_if.rd_rsp_tag == 32'd2
             && acc_if.rd_rsp_data == DATAW'(256'h1234))
            else $fatal(1, "RAW-fenced read returned stale data");
        @(posedge clk);
        retire_txn(32'd2, 1'b1, 1'b0, ADDR3);

        // A long-latency older read and short-latency younger read may return
        // out of request order; tags, not response order, own the join.
        rsp_tags.delete();
        write_acc(32'd18, ADDR5, DATAW'(256'ha5));
        write_acc(32'd19, ADDR6, DATAW'(256'h5a));
        accept_txn(32'd29, 1'b1, 1'b0, ADDR5);
        accept_txn(32'd30, 1'b1, 1'b0, ADDR6);
        request_read(32'd29, ADDR5);
        request_read(32'd30, ADDR6);
        wait (rsp_tags.size() == 2);
        assert (rsp_tags[0] == 32'd30 && rsp_tags[1] == 32'd29)
            else $fatal(1, "programmable ACC did not exercise response reordering");
        retire_txn(32'd29, 1'b1, 1'b0, ADDR5);
        retire_txn(32'd30, 1'b1, 1'b0, ADDR6);

        // Cover adjacent, one-intervening, and deeper accepted-transaction
        // same-address RAW chains before the randomized mixed stream.
        run_raw_chain(32'd40, 0, row_addr(7), DATAW'(256'hd1));
        run_raw_chain(32'd50, 1, row_addr(8), DATAW'(256'hd2));
        run_raw_chain(32'd60, 3, row_addr(9), DATAW'(256'hd4));

        // Sixty-four mixed read/read-write transactions cover all programmed
        // latency classes, four outstanding reads, response reordering, and
        // independent request/write/response backpressure.
        run_mixed_transactions();
        assert (u_dut.txn_count == 0 && u_dut.read_valid == 0
             && !u_dut.rsp_hold_valid)
            else $fatal(1, "programmable ACC did not drain before reset test");

        // Hold a response and require tag/data stability before reset flush.
        write_acc(32'd8, ADDR4, DATAW'(256'h55aa));
        accept_txn(32'd9, 1'b1, 1'b0, ADDR4);
        request_read(32'd9, ADDR4);
        acc_if.rd_rsp_ready = 1'b0;
        wait (acc_if.rd_rsp_valid);
        held_rsp_tag = acc_if.rd_rsp_tag;
        held_rsp_data = acc_if.rd_rsp_data;
        repeat (4) begin
            @(posedge clk);
            assert (acc_if.rd_rsp_valid
                 && acc_if.rd_rsp_tag == held_rsp_tag
                 && acc_if.rd_rsp_data == held_rsp_data)
                else $fatal(1, "held response was not stable");
        end

        // Assert reset with transaction ownership, a held response, and an
        // independently stalled write request all occupied.
        while (acc_if.wr_req_ready)
            @(negedge clk);
        acc_if.wr_req_valid = 1'b1;
        acc_if.wr_req_tag = 32'd88;
        acc_if.wr_req_addr = row_addr(10);
        acc_if.wr_req_data = DATAW'(256'hdeadbeef);
        @(posedge clk);
        assert (!acc_if.wr_req_ready)
            else $fatal(1, "reset test missed occupied write stall");
        @(negedge clk);
        reset = 1'b1;
        acc_if.wr_req_valid = 1'b0;
        repeat (2) @(posedge clk);
        assert (!acc_if.rd_rsp_valid && u_dut.txn_count == 0
             && u_dut.read_valid == 0 && !u_dut.rsp_hold_valid)
            else $fatal(1, "reset did not flush occupied ACC state");

        for (int i = 1; i <= 15; ++i) begin
            assert (latency_seen[i])
                else $fatal(1, "missing programmed latency class %0d", i);
        end
        assert (accepted_txn_count >= 79)
            else $fatal(1, "insufficient mixed transaction coverage %0d",
                        accepted_txn_count);
        assert (accepted_read_count == 71 && response_count == 70)
            else $fatal(1,
                "read/response count mismatch accepted=%0d response=%0d",
                accepted_read_count, response_count);
        assert (max_outstanding_reads >= 4 && max_txn_count >= 5)
            else $fatal(1,
                "bounded occupancy coverage missed read_max=%0d txn_max=%0d",
                max_outstanding_reads, max_txn_count);
        assert (read_stall_cycles != 0 && write_stall_cycles != 0
             && response_hold_cycles >= 4)
            else $fatal(1,
                "backpressure coverage missed rd=%0d wr=%0d rsp_hold=%0d",
                read_stall_cycles, write_stall_cycles,
                response_hold_cycles);
        $display("PROGRAMMABLE_ACC_COUNTS txns=%0d reads=%0d responses=%0d writes=%0d read_stalls=%0d write_stalls=%0d response_holds=%0d max_reads=%0d max_txns=%0d latency_mask=1..15",
                 accepted_txn_count, accepted_read_count, response_count,
                 accepted_write_count, read_stall_cycles,
                 write_stall_cycles, response_hold_cycles,
                 max_outstanding_reads, max_txn_count);
        $display("TEST PASSED: programmable ACC latency1..15/reorder/RAW/backpressure/reset contract");
        $finish;
    end
endmodule
