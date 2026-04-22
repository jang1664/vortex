// Top-level testbench. Instantiates the stand-in vortex_afu and runs long
// enough (a few hundred ns) for the bind-injected vcs_fsdb_dump_init initial
// block to fire at time 0 and record some counter transitions.
//
// No testbench-side $fsdbDump* calls on purpose: the whole point of the
// smoke test is to verify that the dump tasks inside vcs_fsdb_init.sv
// (reached via `bind vortex_afu`) are the only thing needed.

`timescale 1ns/1ps

module tiny_tb;
    logic clk;
    logic rst_n;

    vortex_afu u_dut (.clk(clk), .rst_n(rst_n));

    // 100 MHz clock
    initial clk = 1'b0;
    always #5 clk = ~clk;

    initial begin
        rst_n = 1'b0;
        #23 rst_n = 1'b1;
        #500;
        $display("[tiny_tb] done at time %0t", $time);
        $finish;
    end
endmodule
