`timescale 1ns/1ps

`include "VX_define.vh"

module tb_VX_tmem_switch_16bank;
    import VX_gpu_pkg::*;

    localparam int NUM_BANKS = 16;
    localparam int DATA_SIZE = 32;
    localparam int DATA_WIDTH = DATA_SIZE * 8;
    localparam int TAG_WIDTH = 8;
    localparam int BANK_SEL_BITS = $clog2(NUM_BANKS);
    localparam int OUT_TAG_WIDTH = TAG_WIDTH + BANK_SEL_BITS;
    localparam int MEM_ADDR_WIDTH = 34;
    localparam int ADDR_WIDTH = MEM_ADDR_WIDTH - $clog2(DATA_SIZE);
    localparam int NUM_REQUESTS = NUM_BANKS + 1;

    logic clk = 1'b0;
    logic reset = 1'b1;
    always #5 clk = ~clk;

    VX_mem_bus_if #(
        .DATA_SIZE      (DATA_SIZE),
        .TAG_WIDTH      (TAG_WIDTH),
        .MEM_ADDR_WIDTH (MEM_ADDR_WIDTH)
    ) input_if ();

    VX_mem_bus_if #(
        .DATA_SIZE      (DATA_SIZE),
        .TAG_WIDTH      (OUT_TAG_WIDTH),
        .MEM_ADDR_WIDTH (MEM_ADDR_WIDTH)
    ) bank_if [NUM_BANKS] ();

    logic req_urgent;
    logic [GEMM_SCHED_PRIORITY_WIDTH-1:0] req_priority;
    wire [NUM_BANKS-1:0] bank_req_urgent;
    wire [NUM_BANKS-1:0][GEMM_SCHED_PRIORITY_WIDTH-1:0]
        bank_req_priority;

    logic [NUM_BANKS-1:0] bank_req_ready;
    logic [NUM_BANKS-1:0] bank_rsp_valid;
    logic [NUM_BANKS-1:0][DATA_WIDTH-1:0] bank_rsp_data;
    logic [NUM_BANKS-1:0][OUT_TAG_WIDTH-1:0] bank_rsp_tag;

    wire [NUM_BANKS-1:0] bank_req_valid;
    wire [NUM_BANKS-1:0] bank_req_rw;
    wire [NUM_BANKS-1:0][ADDR_WIDTH-1:0] bank_req_addr;
    wire [NUM_BANKS-1:0][DATA_WIDTH-1:0] bank_req_data;
    wire [NUM_BANKS-1:0][DATA_SIZE-1:0] bank_req_byteen;
    wire [NUM_BANKS-1:0][MEM_FLAGS_WIDTH-1:0] bank_req_flags;
    wire [NUM_BANKS-1:0][OUT_TAG_WIDTH-1:0] bank_req_tag;
    wire [NUM_BANKS-1:0] bank_rsp_ready;

    int expected_bank[NUM_REQUESTS];
    logic [TAG_WIDTH-1:0] expected_tag[NUM_REQUESTS];
    logic [OUT_TAG_WIDTH-1:0] expected_full_tag[NUM_REQUESTS];
    logic [DATA_WIDTH-1:0] expected_rsp_data[NUM_REQUESTS];
    int bank_response_accept_count;
    int response_accept_count;
    int response_expected_index;

    VX_tmem_switch #(
        .INSTANCE_ID    ("tb_switch16"),
        .NUM_BANKS      (NUM_BANKS),
        .DATA_SIZE      (DATA_SIZE),
        .TAG_WIDTH      (TAG_WIDTH),
        .MEM_ADDR_WIDTH (MEM_ADDR_WIDTH)
    ) dut (
        .clk                 (clk),
        .reset               (reset),
        .req_urgent_i        (req_urgent),
        .req_priority_i      (req_priority),
        .bank_req_urgent_o   (bank_req_urgent),
        .bank_req_priority_o (bank_req_priority),
        .bus_in_if           (input_if),
        .bus_out_if          (bank_if)
    );

    // Keep all procedural array indexing on packed mirrors. Some simulators
    // require interface-array indices themselves to remain elaboration-time
    // constants.
    for (genvar bank = 0; bank < NUM_BANKS; ++bank) begin : g_bank_mirror
        assign bank_if[bank].req_ready = bank_req_ready[bank];
        assign bank_if[bank].rsp_valid = bank_rsp_valid[bank];
        assign bank_if[bank].rsp_data.data = bank_rsp_data[bank];
        assign bank_if[bank].rsp_data.tag = bank_rsp_tag[bank];

        assign bank_req_valid[bank] = bank_if[bank].req_valid;
        assign bank_req_rw[bank] = bank_if[bank].req_data.rw;
        assign bank_req_addr[bank] = bank_if[bank].req_data.addr;
        assign bank_req_data[bank] = bank_if[bank].req_data.data;
        assign bank_req_byteen[bank] = bank_if[bank].req_data.byteen;
        assign bank_req_flags[bank] = bank_if[bank].req_data.flags;
        assign bank_req_tag[bank] = bank_if[bank].req_data.tag;
        assign bank_rsp_ready[bank] = bank_if[bank].rsp_ready;
    end

    function automatic logic [DATA_WIDTH-1:0] response_pattern(
        input int request_index
    );
        logic [DATA_WIDTH-1:0] value;
        for (int byte_idx = 0; byte_idx < DATA_SIZE; ++byte_idx)
            value[byte_idx*8 +: 8] = 8'(request_index * 13 + byte_idx);
        return value;
    endfunction

    task automatic issue_read(
        input int request_index,
        input logic [63:0] byte_addr
    );
        logic [ADDR_WIDTH-1:0] word_addr;
        logic [ADDR_WIDTH-1:0] expected_local_addr;
        logic [NUM_BANKS-1:0] expected_onehot;
        int bank;
        begin
            word_addr = ADDR_WIDTH'(byte_addr >> $clog2(DATA_SIZE));
            bank = int'(word_addr[BANK_SEL_BITS-1:0]);
            expected_local_addr = word_addr >> BANK_SEL_BITS;
            expected_onehot = NUM_BANKS'(1) << bank;

            expected_bank[request_index] = bank;
            expected_tag[request_index] = TAG_WIDTH'(8'h40 + request_index);
            expected_full_tag[request_index] = {
                BANK_SEL_BITS'(bank), expected_tag[request_index]
            };
            expected_rsp_data[request_index] = response_pattern(request_index);

            @(negedge clk);
            input_if.req_valid = 1'b1;
            input_if.req_data.rw = 1'b0;
            input_if.req_data.addr = word_addr;
            input_if.req_data.data = response_pattern(request_index + 32);
            input_if.req_data.byteen = '1;
            input_if.req_data.flags = MEM_FLAGS_WIDTH'(request_index);
            input_if.req_data.tag = expected_tag[request_index];
            #1;

            assert (input_if.req_ready)
                else $fatal(1, "request %0d was not accepted", request_index);
            assert (bank_req_valid == expected_onehot)
                else $fatal(1,
                    "request %0d selected wrong bank vector 0x%0h",
                    request_index, bank_req_valid);
            assert (!bank_req_rw[bank])
                else $fatal(1, "request %0d changed read direction", request_index);
            assert (bank_req_addr[bank] == expected_local_addr)
                else $fatal(1,
                    "request %0d local address mismatch: expected %0d got %0d",
                    request_index, expected_local_addr, bank_req_addr[bank]);
            assert (bank_req_tag[bank] == expected_full_tag[request_index])
                else $fatal(1, "request %0d appended tag mismatch", request_index);
            assert (bank_req_urgent == expected_onehot)
                else $fatal(1, "request %0d urgency routing mismatch", request_index);
            @(posedge clk);
        end
    endtask

    task automatic drive_reverse_response(input int request_index);
        int bank;
        int bank_count_before;
        int response_count_before;
        int wait_cycles;
        begin
            bank = expected_bank[request_index];
            bank_count_before = bank_response_accept_count;
            response_count_before = response_accept_count;
            bank_rsp_valid = '0;
            bank_rsp_valid[bank] = 1'b1;
            bank_rsp_data[bank] = expected_rsp_data[request_index];
            bank_rsp_tag[bank] = expected_full_tag[request_index];
            #1;

            // NUM_BANKS=16 may activate VX_stream_arb's registered fanout
            // tree.  Hold the bank response until that tree accepts it, then
            // wait independently for the aggregate response handshake.
            wait_cycles = 0;
            while (!bank_rsp_ready[bank]) begin
                @(negedge clk);
                #1;
                wait_cycles++;
                assert (wait_cycles < 32)
                    else $fatal(1,
                        "reverse response %0d bank acceptance timed out",
                        request_index);
            end

            @(posedge clk);
            #1;
            assert (bank_response_accept_count == bank_count_before + 1)
                else $fatal(1,
                    "reverse response %0d bank handshake count mismatch",
                    request_index);

            @(negedge clk);
            bank_rsp_valid = '0;
            wait_cycles = 0;
            while (response_accept_count == response_count_before) begin
                @(negedge clk);
                wait_cycles++;
                assert (wait_cycles < 32)
                    else $fatal(1,
                        "reverse response %0d output acceptance timed out",
                        request_index);
            end
            assert (response_accept_count == NUM_REQUESTS - request_index)
                else $fatal(1,
                    "reverse response %0d acceptance count mismatch",
                    request_index);
        end
    endtask

    always_ff @(posedge clk) begin
        if (reset) begin
            bank_response_accept_count <= 0;
            response_accept_count <= 0;
            response_expected_index <= NUM_REQUESTS - 1;
        end else begin
            if (| (bank_rsp_valid & bank_rsp_ready)) begin
                assert ($onehot(bank_rsp_valid & bank_rsp_ready))
                    else $fatal(1, "multiple bank responses accepted together");
                bank_response_accept_count <= bank_response_accept_count + 1;
            end
            if (input_if.rsp_valid && input_if.rsp_ready) begin
                assert (response_expected_index >= 0)
                    else $fatal(1, "unexpected extra aggregate response");
                assert (input_if.rsp_data.tag
                     == expected_tag[response_expected_index])
                    else $fatal(1,
                        "reverse response %0d did not restore tag",
                        response_expected_index);
                assert (input_if.rsp_data.data
                     == expected_rsp_data[response_expected_index])
                    else $fatal(1,
                        "reverse response %0d data mismatch",
                        response_expected_index);
                response_accept_count <= response_accept_count + 1;
                response_expected_index <= response_expected_index - 1;
            end
        end
    end

    initial begin
        input_if.req_valid = 1'b0;
        input_if.req_data = '0;
        input_if.rsp_ready = 1'b1;
        req_urgent = 1'b1;
        req_priority = GEMM_SCHED_PRIORITY_BACKGROUND;
        bank_req_ready = '1;
        bank_rsp_valid = '0;
        bank_rsp_data = '0;
        bank_rsp_tag = '0;

        repeat (4) @(posedge clk);
        @(negedge clk);
        reset = 1'b0;

        // Byte addresses 0,32,...,480 become 32-byte word addresses 0..15
        // and select every physical bank. Byte address 512 is word 16,
        // which wraps to bank 0 at bank-local address 1.
        for (int bank = 0; bank < NUM_BANKS; ++bank)
            issue_read(bank, 64'(bank * DATA_SIZE));
        issue_read(NUM_BANKS, 64'(NUM_BANKS * DATA_SIZE));

        @(negedge clk);
        input_if.req_valid = 1'b0;
        assert ((expected_bank[NUM_BANKS] == 0)
             && (expected_full_tag[NUM_BANKS][OUT_TAG_WIDTH-1:TAG_WIDTH] == 0))
            else $fatal(1, "next 512-byte line did not wrap to bank 0");
        $display("COVERAGE: tmem_switch_16banks_and_wrap");

        // Return the exact reverse of request order. The switch may arbitrate
        // responses independently of request order, but must strip the saved
        // bank-select prefix and preserve each payload.
        for (int request_index = NUM_REQUESTS - 1;
             request_index >= 0; --request_index) begin
            drive_reverse_response(request_index);
            if (request_index != 0)
                @(negedge clk);
        end

        @(negedge clk);
        bank_rsp_valid = '0;
        assert (response_accept_count == NUM_REQUESTS)
            else $fatal(1, "not all reverse responses were accepted exactly once");
        $display("COVERAGE: tmem_switch_reverse_response_order");
        $display("TEST PASSED: VX_tmem_switch NUM_BANKS=16 DATA_SIZE=32");
        $finish;
    end

    initial begin
        repeat (500) @(posedge clk);
        $fatal(1, "timeout");
    end

endmodule
