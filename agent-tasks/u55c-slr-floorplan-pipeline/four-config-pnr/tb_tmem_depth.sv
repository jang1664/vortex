`timescale 1ns / 1ps
`include "VX_define.vh"

// Verification-only coverage for the extra t4 physical-array address bit.
module tb_tmem_depth import VX_gpu_pkg::*; ();
    localparam int BYTES = 64;
    localparam int TAG_WIDTH = `UP(UUID_WIDTH) + 8;
    logic clk = 0;
    logic reset = 1;
    always #5 clk = ~clk;

    VX_mem_bus_if #(.DATA_SIZE(BYTES), .TAG_WIDTH(TAG_WIDTH)) bus[2]();
    logic [1:0] urgent = '0;
    logic [1:0][GEMM_SCHED_PRIORITY_WIDTH-1:0] priority_i = '0;
    VX_tensor_mem_bank #(
        .INSTANCE_ID("depth128k"), .SIZE(`TMEM_BANK_SIZE),
        .DATA_SIZE(BYTES), .NUM_PORTS(2), .TAG_WIDTH(TAG_WIDTH)
    ) dut (.clk(clk), .reset(reset), .req_urgent_i(urgent),
           .req_priority_i(priority_i), .mem_bus_if(bus));

    int transactions = 0;
    function automatic logic [511:0] pattern(input int seed);
        for (int b = 0; b < BYTES; ++b)
            pattern[b * 8 +: 8] = 8'(seed + b * 3);
    endfunction

    task automatic transfer(input bit write, input int word_addr,
                            input logic [511:0] data,
                            input logic [63:0] byteen,
                            input int hold_cycles = 0);
        bit accepted;
        bit responded;
        @(negedge clk);
        bus[0].req_valid = 1;
        bus[0].req_data = '0;
        bus[0].req_data.rw = write;
        bus[0].req_data.addr = word_addr;
        bus[0].req_data.data = data;
        bus[0].req_data.byteen = byteen;
        bus[0].req_data.tag.value = 8'(transactions);
        bus[0].rsp_ready = 0;
        accepted = 0;
        for (int n = 0; n < 40; ++n) begin
            @(posedge clk);
            if (bus[0].req_ready === 1'b1) begin
                accepted = 1;
                break;
            end
        end
        if (!accepted) $fatal(1, "request timeout word=%h", word_addr);
        @(negedge clk);
        bus[0].req_valid = 0;
        responded = 0;
        for (int n = 0; n < 40; ++n) begin
            if (bus[0].rsp_valid === 1'b1) begin
                responded = 1;
                break;
            end
            @(negedge clk);
        end
        if (!responded) $fatal(1, "response timeout word=%h", word_addr);
        // Hold the response and check that tag/data remain intact every cycle.
        for (int n = 0; n <= hold_cycles; ++n) begin
            if (bus[0].rsp_valid !== 1'b1
                || bus[0].rsp_data.tag.value !== 8'(transactions)
                || bus[0].rsp_data.data !== (write ? 512'b0 : data))
                $fatal(1, "response mismatch word=%h write=%b hold=%d",
                       word_addr, write, n);
            if (n != hold_cycles) @(negedge clk);
        end
        bus[0].rsp_ready = 1;
        @(posedge clk);
        @(negedge clk);
        bus[0].rsp_ready = 0;
        transactions++;
        $display("DEPTH_CHECK write=%b word=0x%h byte=0x%h hold=%0d",
                 write, word_addr, word_addr * BYTES, hold_cycles);
    endtask

    logic [511:0] upper_partial;
    initial begin
        if (`TMEM_BANK_SIZE != 131072 || `NUM_TMEM_BANKS != 4)
            $fatal(1, "this test requires the production t4 geometry");
        bus[0].req_valid = 0;
        bus[0].req_data = '0;
        bus[0].rsp_ready = 0;
        bus[1].req_valid = 0;
        bus[1].req_data = '0;
        bus[1].rsp_ready = 1;
        repeat (5) @(negedge clk);
        reset = 0;
        repeat (2) @(negedge clk);
        // Opposite halves must never alias (word address bit10).
        transfer(1, 0, pattern(1), '1);
        transfer(1, 1024, pattern(41), '1);
        transfer(1, 1023, pattern(81), '1);
        transfer(1, 2047, pattern(121), '1);
        transfer(0, 0, pattern(1), '0);
        transfer(0, 1024, pattern(41), '0, 5);
        transfer(0, 1023, pattern(81), '0);
        transfer(0, 2047, pattern(121), '0, 3);
        upper_partial = pattern(41);
        for (int b = 0; b < BYTES; b += 2)
            upper_partial[b * 8 +: 8] = 8'(201 + b * 3);
        transfer(1, 1024, pattern(201), 64'h5555555555555555, 2);
        transfer(0, 1024, upper_partial, '0, 4);
        transfer(0, 0, pattern(1), '0);
        transfer(0, 2047, pattern(121), '0);
        $display("PASSED: 128KiB TMEM 64B words, bit10 anti-alias, byteenable, held responses; transactions=%0d", transactions);
        $finish;
    end
    initial begin
        #100000;
        $fatal(1, "watchdog timeout");
    end
endmodule
