`timescale 1ns/1ps
module tb_hbm_axi_guard;
    reg clk = 0;
    always #2 clk = ~clk;
    reg reset_n = 0;
    reg arvalid = 0, arready = 0, awvalid = 0, awready = 0;
    reg [63:0] araddr = 0, awaddr = 0;
    reg [7:0] arlen = 0, awlen = 0;
    reg [2:0] arsize = 6, awsize = 6;
    reg [1:0] arburst = 1, awburst = 1;
    reg rvalid = 0, rready = 0, rlast = 0, bvalid = 0, bready = 0;
    reg [31:0] rid = 0, bid = 0;
    reg [511:0] rdata = 0;
    VX_hbm_axi_guard dut (.*);
    string mode;
    initial begin
        if (!$value$plusargs("case=%s", mode)) mode = "valid";
        repeat (2) @(negedge clk);
        reset_n = 1;
        // Invalid payload without acceptance is not a transaction.
        arvalid = 1; arburst = 0;
        repeat (2) @(negedge clk);
        arburst = 1; arready = 1; arlen = 63;
        awvalid = 1; awready = 1; awlen = 63;
        if (mode == "ar_size") arsize = 5;
        if (mode == "ar_burst") arburst = 0;
        if (mode == "ar_boundary") araddr = 64;
        if (mode == "aw_size") awsize = 5;
        if (mode == "aw_align") awaddr = 1;
        @(negedge clk);
        arvalid = 0; awvalid = 0;
        rvalid = 1; rdata = 512'h1234; rid = 3; rlast = 1;
        bvalid = 1; bid = 5;
        repeat (3) @(negedge clk);
        if (mode == "r_stall") rdata = 512'h5678;
        if (mode == "b_stall") bid = 7;
        @(negedge clk);
        rready = 1; bready = 1;
        @(negedge clk);
        rvalid = 0; bvalid = 0;
        @(negedge clk);
        $display("HBM_GUARD_PASS");
        $finish;
    end
endmodule
