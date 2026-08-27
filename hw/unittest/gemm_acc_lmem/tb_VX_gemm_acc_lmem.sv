`timescale 1ns / 1ps
`include "VX_define.vh"

module tb_VX_gemm_acc_lmem;
    localparam PERIOD = 10;
    localparam DATAW = `MXU_COL * 32;
    localparam PSUM_BYTES = DATAW / 8;
    localparam FINAL_BYTES = `GEMM_OUTPUT_DATA_SIZE;
    localparam LMEM_TAGW = VX_gpu_pkg::GEMM_BASE_TAG_WIDTH;
    localparam ADDRW = `GEMM_ACC_MEM_ADDR_WIDTH;
    localparam PSUM_ROW_ADDRW = `MEM_ADDR_WIDTH - `CLOG2(PSUM_BYTES);
    localparam READ_SLOTS = 8;
    localparam TXN_DEPTH = 64;

    logic clk;
    logic reset;

    VX_gemm_acc_if acc_if ();
    VX_mem_bus_if #(
        .DATA_SIZE (`GEMM_PSUM_DATA_SIZE),
        .TAG_WIDTH (LMEM_TAGW)
    ) psum_rd_lmem_bus_if ();
    VX_mem_bus_if #(
        .DATA_SIZE (`GEMM_PSUM_DATA_SIZE),
        .TAG_WIDTH (LMEM_TAGW)
    ) psum_wr_lmem_bus_if ();
    VX_mem_bus_if #(
        .DATA_SIZE (`GEMM_OUTPUT_DATA_SIZE),
        .TAG_WIDTH (LMEM_TAGW)
    ) final_lmem_bus_if ();

    VX_gemm_acc_lmem #(
        .LMEM_TAGW (LMEM_TAGW),
        .READ_SLOTS (READ_SLOTS),
        .TXN_DEPTH (TXN_DEPTH)
    ) u_dut (
        .clk (clk),
        .reset (reset),
        .acc_if (acc_if),
        .psum_rd_lmem_bus_if (psum_rd_lmem_bus_if),
        .psum_wr_lmem_bus_if (psum_wr_lmem_bus_if),
        .final_lmem_bus_if (final_lmem_bus_if)
    );

    initial clk = 1'b0;
    always #(PERIOD / 2) clk = ~clk;

    int unsigned txn_accept_count;
    int unsigned txn_retire_count;
    int unsigned core_read_count;
    int unsigned lmem_read_count;
    int unsigned lmem_response_count;
    int unsigned core_response_count;
    int unsigned psum_write_count;
    int unsigned final_write_count;
    int unsigned read_request_stall_cycles;
    int unsigned response_stall_cycles;
    int unsigned psum_write_stall_cycles;
    int unsigned final_write_stall_cycles;
    int unsigned max_read_slots;
    int unsigned max_txn_count;

    initial begin
        txn_accept_count = 0;
        txn_retire_count = 0;
        core_read_count = 0;
        lmem_read_count = 0;
        lmem_response_count = 0;
        core_response_count = 0;
        psum_write_count = 0;
        final_write_count = 0;
        read_request_stall_cycles = 0;
        response_stall_cycles = 0;
        psum_write_stall_cycles = 0;
        final_write_stall_cycles = 0;
        max_read_slots = 0;
        max_txn_count = 0;
    end

    always @(posedge clk) begin
        if (!reset) begin
            if (acc_if.txn_accept_valid)
                txn_accept_count++;
            if (acc_if.txn_retire_valid)
                txn_retire_count++;
            if (acc_if.rd_req_valid && acc_if.rd_req_ready)
                core_read_count++;
            if (psum_rd_lmem_bus_if.req_valid
             && psum_rd_lmem_bus_if.req_ready)
                lmem_read_count++;
            if (psum_rd_lmem_bus_if.rsp_valid
             && psum_rd_lmem_bus_if.rsp_ready)
                lmem_response_count++;
            if (acc_if.rd_rsp_valid && acc_if.rd_rsp_ready)
                core_response_count++;
            if (psum_wr_lmem_bus_if.req_valid
             && psum_wr_lmem_bus_if.req_ready)
                psum_write_count++;
            if (final_lmem_bus_if.req_valid
             && final_lmem_bus_if.req_ready)
                final_write_count++;
            if (psum_rd_lmem_bus_if.req_valid
             && !psum_rd_lmem_bus_if.req_ready)
                read_request_stall_cycles++;
            if (acc_if.rd_rsp_valid && !acc_if.rd_rsp_ready)
                response_stall_cycles++;
            if (psum_wr_lmem_bus_if.req_valid
             && !psum_wr_lmem_bus_if.req_ready)
                psum_write_stall_cycles++;
            if (final_lmem_bus_if.req_valid
             && !final_lmem_bus_if.req_ready)
                final_write_stall_cycles++;
            if ($countones(u_dut.read_slot_valid) > max_read_slots)
                max_read_slots = $countones(u_dut.read_slot_valid);
            if (u_dut.txn_count > max_txn_count)
                max_txn_count = u_dut.txn_count;

            assert (lmem_response_count <= lmem_read_count)
                else $fatal(1, "LMEM response observed without a request");
            assert (core_response_count <= lmem_response_count)
                else $fatal(1, "core response observed without LMEM response");
        end
    end

    function automatic logic [ADDRW-1:0] psum_addr(input int row);
        return ADDRW'(row * PSUM_BYTES);
    endfunction

    function automatic logic [ADDRW-1:0] final_addr(input int row);
        return ADDRW'(row * FINAL_BYTES);
    endfunction

    function automatic logic [DATAW-1:0] row_pattern(input logic [31:0] seed);
        logic [DATAW-1:0] value;
        for (int i = 0; i < `MXU_COL; ++i)
            value[i * 32 +: 32] = seed + i;
        return value;
    endfunction

    task automatic drive_defaults;
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

        psum_rd_lmem_bus_if.req_ready = 1'b1;
        psum_rd_lmem_bus_if.rsp_valid = 1'b0;
        psum_rd_lmem_bus_if.rsp_data = '0;
        psum_wr_lmem_bus_if.req_ready = 1'b1;
        psum_wr_lmem_bus_if.rsp_valid = 1'b0;
        psum_wr_lmem_bus_if.rsp_data = '0;
        final_lmem_bus_if.req_ready = 1'b1;
        final_lmem_bus_if.rsp_valid = 1'b0;
        final_lmem_bus_if.rsp_data = '0;
    endtask

    task automatic accept_txn(
        input logic [31:0] tag,
        input logic rd_en,
        input logic wr_en,
        input logic [ADDRW-1:0] rd_addr,
        input logic [ADDRW-1:0] wr_addr
    );
        @(negedge clk);
        acc_if.txn_accept_valid = 1'b1;
        acc_if.txn_accept_tag = tag;
        acc_if.txn_accept_rd_en = rd_en;
        acc_if.txn_accept_wr_en = wr_en;
        acc_if.txn_accept_rd_addr = rd_addr;
        acc_if.txn_accept_wr_addr = wr_addr;
        @(posedge clk);
        @(negedge clk);
        acc_if.txn_accept_valid = 1'b0;
    endtask

    task automatic retire_txn(
        input logic [31:0] tag,
        input logic rd_en,
        input logic wr_en,
        input logic [ADDRW-1:0] rd_addr,
        input logic [ADDRW-1:0] wr_addr
    );
        @(negedge clk);
        acc_if.txn_retire_valid = 1'b1;
        acc_if.txn_retire_tag = tag;
        acc_if.txn_retire_rd_en = rd_en;
        acc_if.txn_retire_wr_en = wr_en;
        acc_if.txn_retire_rd_addr = rd_addr;
        acc_if.txn_retire_wr_addr = wr_addr;
        @(posedge clk);
        @(negedge clk);
        acc_if.txn_retire_valid = 1'b0;
    endtask

    task automatic request_read(
        input logic [31:0] tag,
        input logic [ADDRW-1:0] addr,
        output logic [LMEM_TAGW-1:0] lmem_tag
    );
        int unsigned timeout;
        @(negedge clk);
        acc_if.rd_req_valid = 1'b1;
        acc_if.rd_req_tag = tag;
        acc_if.rd_req_addr = addr;
        timeout = 0;
        do begin
            @(posedge clk);
            timeout++;
        end while (!acc_if.rd_req_ready && timeout < 64);
        assert (acc_if.rd_req_ready)
            else $fatal(1, "timeout waiting for core read acceptance");
        lmem_tag = u_dut.read_req_slot_found
            ? LMEM_TAGW'(u_dut.read_req_slot)
            : LMEM_TAGW'(u_dut.read_free_slot);
        if (u_dut.read_req_slot_found) begin
            assert (u_dut.read_slot_addr[u_dut.read_req_slot] == addr)
                else $fatal(1, "prefetched core read address mismatch");
        end
        @(negedge clk);
        acc_if.rd_req_valid = 1'b0;
    endtask

    task automatic capture_lmem_issue(
        output logic [LMEM_TAGW-1:0] lmem_tag,
        output logic [PSUM_ROW_ADDRW-1:0] row_addr
    );
        int unsigned timeout;
        timeout = 0;
        while (!(psum_rd_lmem_bus_if.req_valid
              && psum_rd_lmem_bus_if.req_ready) && timeout < 64) begin
            @(negedge clk);
            timeout++;
        end
        assert (psum_rd_lmem_bus_if.req_valid
             && psum_rd_lmem_bus_if.req_ready)
            else $fatal(1, "timeout waiting for LMEM read issue");
        lmem_tag = psum_rd_lmem_bus_if.req_data.tag;
        row_addr = psum_rd_lmem_bus_if.req_data.addr;
        @(posedge clk);
        @(negedge clk);
    endtask

    task automatic request_read_stalled(
        input logic [31:0] tag,
        input logic [ADDRW-1:0] addr,
        input int unsigned stall_cycles,
        output logic [LMEM_TAGW-1:0] lmem_tag
    );
        int unsigned timeout;
        psum_rd_lmem_bus_if.req_ready = 1'b0;
        @(negedge clk);
        acc_if.rd_req_valid = 1'b1;
        acc_if.rd_req_tag = tag;
        acc_if.rd_req_addr = addr;
        timeout = 0;
        do begin
            @(posedge clk);
            timeout++;
        end while (!acc_if.rd_req_ready && timeout < 64);
        assert (acc_if.rd_req_ready)
            else $fatal(1, "timeout waiting for stalled core read acceptance");
        assert (psum_rd_lmem_bus_if.req_valid
             && !psum_rd_lmem_bus_if.req_ready)
            else $fatal(1, "stalled core read did not enter LMEM issue hold");
        lmem_tag = psum_rd_lmem_bus_if.req_data.tag;
        @(negedge clk);
        acc_if.rd_req_valid = 1'b0;
        repeat (stall_cycles) begin
            @(posedge clk);
            assert (psum_rd_lmem_bus_if.req_valid
                 && !psum_rd_lmem_bus_if.req_ready
                 && (psum_rd_lmem_bus_if.req_data.tag == lmem_tag)
                 && (psum_rd_lmem_bus_if.req_data.addr
                     == (`MEM_ADDR_WIDTH-`CLOG2(PSUM_BYTES))'(
                            addr[ADDRW-1:`CLOG2(PSUM_BYTES)])))
                else $fatal(1, "LMEM read request changed while held");
            @(negedge clk);
        end
        psum_rd_lmem_bus_if.req_ready = 1'b1;
        @(posedge clk);
        assert (psum_rd_lmem_bus_if.req_valid)
            else $fatal(1, "held LMEM read request did not complete");
        @(negedge clk);
    endtask

    task automatic send_response(
        input logic [LMEM_TAGW-1:0] lmem_tag,
        input logic [DATAW-1:0] data
    );
        int unsigned timeout;
        @(negedge clk);
        psum_rd_lmem_bus_if.rsp_valid = 1'b1;
        psum_rd_lmem_bus_if.rsp_data.tag = lmem_tag;
        psum_rd_lmem_bus_if.rsp_data.data = data;
        timeout = 0;
        do begin
            @(posedge clk);
            timeout++;
        end while (!psum_rd_lmem_bus_if.rsp_ready && timeout < 64);
        assert (psum_rd_lmem_bus_if.rsp_ready)
            else $fatal(1, "timeout waiting for LMEM response acceptance");
        @(negedge clk);
        psum_rd_lmem_bus_if.rsp_valid = 1'b0;
    endtask

    task automatic expect_response(
        input logic [31:0] tag,
        input logic [DATAW-1:0] data
    );
        int timeout;
        timeout = 0;
        while (!acc_if.rd_rsp_valid && timeout < 32) begin
            @(negedge clk);
            timeout++;
        end
        assert (acc_if.rd_rsp_valid)
            else $fatal(1, "timeout waiting for core response");
        assert ((acc_if.rd_rsp_tag == tag) && (acc_if.rd_rsp_data == data))
            else $fatal(1, "core response tag/data mismatch");
        @(posedge clk);
        @(negedge clk);
    endtask

    task automatic write_psum(
        input logic [31:0] tag,
        input logic [ADDRW-1:0] addr,
        input logic [DATAW-1:0] data
    );
        @(negedge clk);
        psum_wr_lmem_bus_if.req_ready = 1'b0;
        acc_if.wr_req_valid = 1'b1;
        acc_if.wr_req_tag = tag;
        acc_if.wr_req_addr = addr;
        acc_if.wr_req_data = data;
        acc_if.wr_req_final_output = 1'b0;
        repeat (2) begin
            @(posedge clk);
            assert (psum_wr_lmem_bus_if.req_valid && !acc_if.wr_req_ready)
                else $fatal(1, "PSUM write did not propagate backpressure");
            assert ((psum_wr_lmem_bus_if.req_data.addr
                     == (`MEM_ADDR_WIDTH-`CLOG2(PSUM_BYTES))'(
                            addr[ADDRW-1:`CLOG2(PSUM_BYTES)]))
                 && (psum_wr_lmem_bus_if.req_data.data == data)
                 && psum_wr_lmem_bus_if.req_data.rw
                 && (&psum_wr_lmem_bus_if.req_data.byteen)
                 && !final_lmem_bus_if.req_valid)
                else $fatal(1, "PSUM write mapping changed while stalled");
            @(negedge clk);
        end
        psum_wr_lmem_bus_if.req_ready = 1'b1;
        @(posedge clk);
        assert (acc_if.wr_req_ready)
            else $fatal(1, "PSUM write did not complete with LMEM ready");
        @(negedge clk);
        acc_if.wr_req_valid = 1'b0;
    endtask

    task automatic write_final(
        input logic [31:0] tag,
        input logic [ADDRW-1:0] addr,
        input logic [DATAW-1:0] data,
        input logic [`GEMM_OUTPUT_DATA_SIZE*8-1:0] expected
    );
        int timeout;
        @(negedge clk);
        final_lmem_bus_if.req_ready = 1'b0;
        acc_if.wr_req_valid = 1'b1;
        acc_if.wr_req_tag = tag;
        acc_if.wr_req_addr = addr;
        acc_if.wr_req_data = data;
        acc_if.wr_req_final_output = 1'b1;
        acc_if.wr_req_last = 1'b1;
        timeout = 0;
        while (!final_lmem_bus_if.req_valid && timeout < 32) begin
            @(negedge clk);
            timeout++;
        end
        assert (final_lmem_bus_if.req_valid)
            else $fatal(1, "timeout waiting for final conversion");
        repeat (2) begin
            @(posedge clk);
            assert (!acc_if.wr_req_ready
                 && (final_lmem_bus_if.req_data.addr
                     == (`MEM_ADDR_WIDTH-`CLOG2(FINAL_BYTES))'(
                            addr[ADDRW-1:`CLOG2(FINAL_BYTES)]))
                 && (final_lmem_bus_if.req_data.data == expected)
                 && final_lmem_bus_if.req_data.rw
                 && (&final_lmem_bus_if.req_data.byteen)
                 && !psum_wr_lmem_bus_if.req_valid)
                else $fatal(1, "final LMEM request mapping/stall mismatch");
            @(negedge clk);
        end
        final_lmem_bus_if.req_ready = 1'b1;
        @(posedge clk);
        assert (acc_if.wr_req_ready)
            else $fatal(1, "final write did not complete with LMEM ready");
        @(negedge clk);
        acc_if.wr_req_valid = 1'b0;
        acc_if.wr_req_last = 1'b0;
    endtask

    initial begin
        logic [LMEM_TAGW-1:0] lmem_tag_a;
        logic [LMEM_TAGW-1:0] lmem_tags [0:READ_SLOTS-1];
        logic [LMEM_TAGW-1:0] prefetch_tags [0:3];
        logic [PSUM_ROW_ADDRW-1:0] issue_row;
        logic [DATAW-1:0] batch_data_a [0:READ_SLOTS];
        logic [DATAW-1:0] batch_data_b [0:READ_SLOTS-1];
        logic [DATAW-1:0] psum_data;
        logic [DATAW-1:0] final_data;
        logic [`GEMM_OUTPUT_DATA_SIZE*8-1:0] final_expected;
        int order_a [0:READ_SLOTS-1];
        int order_b [0:READ_SLOTS-1];
        int timeout;

        drive_defaults();
        reset = 1'b1;
        repeat (4) @(posedge clk);
        @(negedge clk);
        reset = 1'b0;
        $display("LMEM_ACC_PROGRESS prefetch_batch_begin");

        // Accept logical set pattern 0,1,0,1 before the common core asks for
        // any data.  Holding LMEM ready lets all four prefetch slots become
        // visible at once.  The adapter issues them in accepted-transaction
        // order; the downstream node OOO join owns cross-set lane-response
        // assembly.
        psum_rd_lmem_bus_if.req_ready = 1'b0;
        for (int i = 0; i < 4; ++i) begin
            accept_txn(32'hE100_0000 + 32'(i), 1'b1, 1'b0,
                       psum_addr(i), '0);
        end
        assert ($countones(u_dut.read_slot_valid) == 4
             && (u_dut.read_slot_demanded == '0)
             && (core_read_count == 0))
            else $fatal(1, "txn_accept did not allocate four early prefetch slots");

        psum_rd_lmem_bus_if.req_ready = 1'b1;
        for (int i = 0; i < 4; ++i) begin
            capture_lmem_issue(prefetch_tags[i], issue_row);
            assert (issue_row == PSUM_ROW_ADDRW'(i))
                else $fatal(1, "prefetch issue did not preserve accepted order index=%0d row=%0d",
                            i, issue_row);
        end
        assert (!psum_rd_lmem_bus_if.req_valid)
            else $fatal(1, "prefetch request duplicated after four accepted issues");

        // Complete rows two and zero out of order before demand.  Neither
        // completion may become a core response until its normal read request
        // handshakes.
        send_response(prefetch_tags[2], row_pattern(32'hE200));
        psum_rd_lmem_bus_if.req_ready = 1'b0;
        send_response(prefetch_tags[0], row_pattern(32'hE000));
        assert (!acc_if.rd_rsp_valid && (core_response_count == 0))
            else $fatal(1, "prefetch completion escaped before core demand");

        acc_if.rd_rsp_ready = 1'b0;
        request_read(32'hE100_0000, psum_addr(0), lmem_tag_a);
        assert (lmem_tag_a == prefetch_tags[0])
            else $fatal(1, "completed prefetch slot did not match core demand");
        repeat (3) begin
            @(posedge clk);
            assert (acc_if.rd_rsp_valid
                 && (acc_if.rd_rsp_tag == 32'hE100_0000)
                 && (acc_if.rd_rsp_data == row_pattern(32'hE000)))
                else $fatal(1, "completed prefetch response changed while held");
        end
        @(negedge clk);
        acc_if.rd_rsp_ready = 1'b1;
        expect_response(32'hE100_0000, row_pattern(32'hE000));
        request_read(32'hE100_0002, psum_addr(2), lmem_tag_a);
        assert (lmem_tag_a == prefetch_tags[2])
            else $fatal(1, "out-of-order completed slot did not match demand");
        expect_response(32'hE100_0002, row_pattern(32'hE200));

        // Rows one and three are already physically issued across the two
        // logical sets.  Demand them and complete them out of order.
        psum_rd_lmem_bus_if.req_ready = 1'b1;
        request_read(32'hE100_0001, psum_addr(1), lmem_tag_a);
        assert (lmem_tag_a == prefetch_tags[1])
            else $fatal(1, "row 1 prefetch slot mismatch");
        request_read(32'hE100_0003, psum_addr(3), lmem_tag_a);
        assert (lmem_tag_a == prefetch_tags[3])
            else $fatal(1, "row 3 prefetch slot mismatch");
        send_response(prefetch_tags[3], row_pattern(32'hE300));
        expect_response(32'hE100_0003, row_pattern(32'hE300));
        send_response(prefetch_tags[1], row_pattern(32'hE100));
        expect_response(32'hE100_0001, row_pattern(32'hE100));
        for (int i = 0; i < 4; ++i) begin
            retire_txn(32'hE100_0000 + 32'(i), 1'b1, 1'b0,
                       psum_addr(i), '0);
        end

        $display("LMEM_ACC_PROGRESS batch1_begin");

        // Fill all eight bounded read slots with distinct full-width core
        // tags.  The first request is held at the LMEM boundary to prove its
        // translated tag/address stay fixed while ready is low.
        for (int i = 0; i < READ_SLOTS; ++i) begin
            batch_data_a[i] = row_pattern(32'h1000 + 32'(i * 32));
            accept_txn(32'hA500_0100 + 32'(i), 1'b1, 1'b0,
                       psum_addr(3 + 2 * i), '0);
            if (i == 0) begin
                request_read_stalled(32'hA500_0100 + 32'(i),
                                     psum_addr(3 + 2 * i), 2, lmem_tags[i]);
            end else begin
                request_read(32'hA500_0100 + 32'(i),
                             psum_addr(3 + 2 * i), lmem_tags[i]);
            end
            assert (lmem_tags[i] == LMEM_TAGW'(i))
                else $fatal(1, "initial LMEM tag translation mismatch");
            $display("LMEM_ACC_PROGRESS batch1_issue index=%0d slot=%0d",
                     i, lmem_tags[i]);
        end
        @(posedge clk);
        assert (u_dut.read_slot_valid == {READ_SLOTS{1'b1}})
            else $fatal(1, "did not allocate all eight read slots");

        // A ninth accepted transaction cannot issue while every read slot is
        // owned.  Completing slot seven permits that narrow tag to be reused
        // for a different full-width transaction tag.
        batch_data_a[READ_SLOTS] = row_pattern(32'h2800);
        accept_txn(32'hA500_0100 + 32'(READ_SLOTS), 1'b1, 1'b0,
                   psum_addr(3 + 2 * READ_SLOTS), '0);
        @(negedge clk);
        acc_if.rd_req_valid = 1'b1;
        acc_if.rd_req_tag = 32'hA500_0100 + 32'(READ_SLOTS);
        acc_if.rd_req_addr = psum_addr(3 + 2 * READ_SLOTS);
        repeat (2) begin
            @(posedge clk);
            assert (acc_if.rd_req_valid
                 && (acc_if.rd_req_tag
                     == 32'hA500_0100 + 32'(READ_SLOTS))
                 && (acc_if.rd_req_addr
                     == psum_addr(3 + 2 * READ_SLOTS))
                 && !acc_if.rd_req_ready)
                else $fatal(1, "read issued beyond the eight-slot bound");
            @(negedge clk);
        end
        acc_if.rd_req_valid = 1'b0;

        acc_if.rd_rsp_ready = 1'b0;
        send_response(lmem_tags[READ_SLOTS-1],
                      batch_data_a[READ_SLOTS-1]);
        repeat (3) begin
            @(posedge clk);
            assert (acc_if.rd_rsp_valid
                 && (acc_if.rd_rsp_tag
                     == 32'hA500_0100 + 32'(READ_SLOTS-1))
                 && (acc_if.rd_rsp_data
                     == batch_data_a[READ_SLOTS-1]))
                else $fatal(1, "response was not stable under backpressure");
            assert (!psum_rd_lmem_bus_if.rsp_ready)
                else $fatal(1, "LMEM accepted a second response while held");
        end
        @(negedge clk);
        acc_if.rd_rsp_ready = 1'b1;
        expect_response(32'hA500_0100 + 32'(READ_SLOTS-1),
                        batch_data_a[READ_SLOTS-1]);
        $display("LMEM_ACC_PROGRESS batch1_slot7_response");
        request_read(32'hA500_0100 + 32'(READ_SLOTS),
                     psum_addr(3 + 2 * READ_SLOTS), lmem_tag_a);
        assert (lmem_tag_a == lmem_tags[READ_SLOTS-1])
            else $fatal(1, "LMEM read-slot tag did not wrap/reuse");
        lmem_tags[READ_SLOTS-1] = lmem_tag_a;

        order_a[0] = 3;
        order_a[1] = 0;
        order_a[2] = 6;
        order_a[3] = 1;
        order_a[4] = 5;
        order_a[5] = 2;
        order_a[6] = 4;
        order_a[7] = READ_SLOTS;
        for (int n = 0; n < READ_SLOTS; ++n) begin
            int i;
            i = order_a[n];
            send_response((i == READ_SLOTS)
                              ? lmem_tags[READ_SLOTS-1] : lmem_tags[i],
                          batch_data_a[i]);
            expect_response(32'hA500_0100 + 32'(i), batch_data_a[i]);
            $display("LMEM_ACC_PROGRESS batch1_response index=%0d", i);
        end
        for (int i = 0; i <= READ_SLOTS; ++i) begin
            retire_txn(32'hA500_0100 + 32'(i), 1'b1, 1'b0,
                       psum_addr(3 + 2 * i), '0);
        end

        // Allocate every narrow tag again with unrelated high core-tag bits,
        // then return responses in a second permutation.  This proves tag
        // translation across a complete slot wrap and arbitrary LMEM skew.
        $display("LMEM_ACC_PROGRESS batch2_begin");
        for (int i = 0; i < READ_SLOTS; ++i) begin
            batch_data_b[i] = row_pattern(32'h4000 + 32'(i * 32));
            accept_txn(32'h5A00_FF00 + 32'(i), 1'b1, 1'b0,
                       psum_addr(20 + 2 * i), '0);
            request_read(32'h5A00_FF00 + 32'(i),
                         psum_addr(20 + 2 * i), lmem_tags[i]);
            assert (lmem_tags[i] == LMEM_TAGW'(i))
                else $fatal(1, "wrapped LMEM tag translation mismatch");
        end
        order_b[0] = 1;
        order_b[1] = 7;
        order_b[2] = 0;
        order_b[3] = 6;
        order_b[4] = 2;
        order_b[5] = 5;
        order_b[6] = 3;
        order_b[7] = 4;
        for (int n = 0; n < READ_SLOTS; ++n) begin
            int i;
            i = order_b[n];
            send_response(lmem_tags[i], batch_data_b[i]);
            expect_response(32'h5A00_FF00 + 32'(i), batch_data_b[i]);
            $display("LMEM_ACC_PROGRESS batch2_response index=%0d", i);
        end
        for (int i = 0; i < READ_SLOTS; ++i) begin
            retire_txn(32'h5A00_FF00 + 32'(i), 1'b1, 1'b0,
                       psum_addr(20 + 2 * i), '0);
        end

        // An accepted younger same-address read cannot pass an older write.
        $display("LMEM_ACC_PROGRESS raw_begin");
        psum_data = row_pattern(32'h3000);
        accept_txn(32'h303, 1'b0, 1'b1, '0, psum_addr(9));
        accept_txn(32'h404, 1'b1, 1'b0, psum_addr(9), '0);
        request_read(32'h404, psum_addr(9), lmem_tag_a);
        repeat (2) begin
            @(posedge clk);
            assert (!psum_rd_lmem_bus_if.req_valid)
                else $fatal(1, "younger same-address read escaped physical RAW fence");
            @(negedge clk);
        end
        write_psum(32'h303, psum_addr(9), psum_data);
        retire_txn(32'h303, 1'b0, 1'b1, '0, psum_addr(9));
        capture_lmem_issue(lmem_tag_a, issue_row);
        assert (issue_row == PSUM_ROW_ADDRW'(9))
            else $fatal(1, "RAW-unblocked read address mismatch");
        send_response(lmem_tag_a, psum_data);
        expect_response(32'h404, psum_data);
        retire_txn(32'h404, 1'b1, 1'b0, psum_addr(9), '0);

        // Final writes use the separate destination and FP32-to-FP16 map.
        $display("LMEM_ACC_PROGRESS final_begin");
        final_data = '0;
        final_expected = '0;
        for (int i = 0; i < `MXU_COL; ++i) begin
            final_data[i * 32 +: 32] = i[0] ? 32'hc0000000 : 32'h3f800000;
            final_expected[i * 16 +: 16] = i[0] ? 16'hc000 : 16'h3c00;
        end
        accept_txn(32'h505, 1'b0, 1'b1, '0, final_addr(5));
        write_final(32'h505, final_addr(5), final_data, final_expected);
        retire_txn(32'h505, 1'b0, 1'b1, '0, final_addr(5));

        // Reset discards an occupied response hold, a separate stalled issue
        // hold, both live slots, and their accepted transaction ownership.
        $display("LMEM_ACC_PROGRESS reset_begin");
        accept_txn(32'h606, 1'b1, 1'b0, psum_addr(2), '0);
        request_read(32'h606, psum_addr(2), lmem_tag_a);
        acc_if.rd_rsp_ready = 1'b0;
        send_response(lmem_tag_a, row_pattern(32'h6000));
        assert (acc_if.rd_rsp_valid && (acc_if.rd_rsp_tag == 32'h606))
            else $fatal(1, "reset setup did not occupy response hold");
        accept_txn(32'h607, 1'b1, 1'b0, psum_addr(4), '0);
        psum_rd_lmem_bus_if.req_ready = 1'b0;
        @(negedge clk);
        acc_if.rd_req_valid = 1'b1;
        acc_if.rd_req_tag = 32'h607;
        acc_if.rd_req_addr = psum_addr(4);
        timeout = 0;
        do begin
            @(posedge clk);
            timeout++;
        end while (!acc_if.rd_req_ready && timeout < 64);
        assert (acc_if.rd_req_ready)
            else $fatal(1, "timeout setting occupied reset read request");
        @(negedge clk);
        acc_if.rd_req_valid = 1'b0;
        assert (u_dut.rd_issue_hold_valid && u_dut.rsp_hold_valid
             && (u_dut.txn_count == 2))
            else $fatal(1, "reset setup did not occupy LMEM ACC state");
        @(negedge clk);
        reset = 1'b1;
        repeat (2) @(posedge clk);
        @(negedge clk);
        reset = 1'b0;
        repeat (2) @(posedge clk);
        assert (!acc_if.rd_rsp_valid && (u_dut.txn_count == 0)
             && (u_dut.read_slot_valid == '0)
             && !u_dut.rd_issue_hold_valid && !u_dut.rsp_hold_valid
             && !psum_rd_lmem_bus_if.req_valid
             && !final_lmem_bus_if.req_valid)
            else $fatal(1, "reset did not flush LMEM ACC ownership");
        psum_rd_lmem_bus_if.rsp_data.tag = '0;
        psum_rd_lmem_bus_if.rsp_data.data = row_pattern(32'hDEAD);
        assert (!psum_rd_lmem_bus_if.rsp_ready)
            else $fatal(1, "unowned LMEM response was ready after reset");

        assert (txn_accept_count == 26 && txn_retire_count == 24)
            else $fatal(1, "transaction accept/retire count mismatch");
        assert (core_read_count == 24 && lmem_read_count == 23
             && lmem_response_count == 23 && core_response_count == 22)
            else $fatal(1, "read request/response count mismatch");
        assert (psum_write_count == 1 && final_write_count == 1)
            else $fatal(1, "write destination count mismatch");
        assert (max_read_slots == READ_SLOTS && max_txn_count >= 9)
            else $fatal(1, "bounded occupancy coverage not reached");
        assert (read_request_stall_cycles >= 3
             && response_stall_cycles >= 4
             && psum_write_stall_cycles >= 2
             && final_write_stall_cycles >= 2)
            else $fatal(1, "ready-low stability coverage not reached");

        $display("LMEM_ACC_COUNTS accepts=%0d retires=%0d core_reads=%0d lmem_reads=%0d lmem_responses=%0d core_responses=%0d psum_writes=%0d final_writes=%0d max_read_slots=%0d max_txns=%0d read_hold=%0d response_hold=%0d psum_hold=%0d final_hold=%0d",
                 txn_accept_count, txn_retire_count, core_read_count,
                 lmem_read_count, lmem_response_count, core_response_count,
                 psum_write_count, final_write_count, max_read_slots,
                 max_txn_count, read_request_stall_cycles,
                 response_stall_cycles, psum_write_stall_cycles,
                 final_write_stall_cycles);
        $display("TEST PASSED: LMEM ACC early prefetch batching, eight-slot late fallback, reorder, RAW, backpressure and occupied reset checks");
        $finish;
    end
endmodule
