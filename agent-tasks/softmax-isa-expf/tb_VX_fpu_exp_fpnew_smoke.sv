`timescale 1ns/1ps

`include "VX_fpu_define.vh"

module tb_VX_fpu_exp_fpnew_smoke;
    import VX_gpu_pkg::*;
    import VX_fpu_pkg::*;

    localparam NUM_LANES = 1;
    localparam TAG_WIDTH = 1;

    logic clk = 0;
    logic reset = 1;

    logic valid_in;
    logic ready_in;
    logic [NUM_LANES-1:0] mask_in;
    logic [TAG_WIDTH-1:0] tag_in;
    logic [NUM_LANES-1:0][`XLEN-1:0] dataa;
    logic [NUM_LANES-1:0][`XLEN-1:0] result;
    logic has_fflags;
    logic [`FP_FLAGS_BITS-1:0] fflags;
    logic [TAG_WIDTH-1:0] tag_out;
    logic ready_out;
    logic valid_out;

    always #5 clk = ~clk;

    VX_fpu_exp_fpnew #(
        .NUM_LANES (NUM_LANES),
        .TAG_WIDTH (TAG_WIDTH)
    ) dut (
        .clk        (clk),
        .reset      (reset),
        .valid_in   (valid_in),
        .ready_in   (ready_in),
        .mask_in    (mask_in),
        .tag_in     (tag_in),
        .dataa      (dataa),
        .result     (result),
        .has_fflags (has_fflags),
        .fflags     (fflags),
        .tag_out    (tag_out),
        .ready_out  (ready_out),
        .valid_out  (valid_out)
    );

    initial begin
        valid_in = 0;
        ready_out = 1;
        mask_in = 1'b1;
        tag_in = 1'b1;
    `ifdef XLEN_64
        dataa[0] = 64'hffffffff00000000;
    `else
        dataa[0] = 32'h00000000;
    `endif

        repeat (5) @(posedge clk);
        reset = 0;
        repeat (2) @(posedge clk);

        if (!ready_in) begin
            $fatal(1, "DUT was not ready for the initial request");
        end
        valid_in = 1;
        @(posedge clk);
        valid_in = 0;

        wait (valid_out);
    `ifdef XLEN_64
        if (result[0] !== 64'hffffffff3f800000) begin
            $fatal(1, "vx_expf_fpnew(0.0) expected 1.0, got 0x%016h", result[0]);
        end
    `else
        if (result[0] !== 32'h3f800000) begin
            $fatal(1, "vx_expf_fpnew(0.0) expected 1.0, got 0x%08h", result[0]);
        end
    `endif
        $finish;
    end
endmodule
