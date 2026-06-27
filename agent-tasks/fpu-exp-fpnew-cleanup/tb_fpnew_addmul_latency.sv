`timescale 1ns/1ps

`include "VX_fpu_define.vh"

module tb_fpnew_addmul_latency;
    logic clk = 0;
    logic reset = 1;
    logic valid_in;
    logic ready_in_mul;
    logic ready_in_add;
    logic [31:0] mul_result;
    logic [31:0] add_result;
    logic valid_out_mul;
    logic valid_out_add;
    integer cycle;

    always #5 clk = ~clk;

    VX_fpu_exp_fpnew_fmul #(
        .LATENCY (`LATENCY_FMA)
    ) fmul (
        .clk       (clk),
        .reset     (reset),
        .valid_in  (valid_in),
        .ready_in  (ready_in_mul),
        .dataa     (32'h3f800000),
        .datab     (32'h40000000),
        .result    (mul_result),
        .ready_out (1'b1),
        .valid_out (valid_out_mul)
    );

    VX_fpu_exp_fpnew_fadd #(
        .LATENCY (`LATENCY_FMA)
    ) fadd (
        .clk       (clk),
        .reset     (reset),
        .valid_in  (valid_in),
        .ready_in  (ready_in_add),
        .dataa     (32'h3f800000),
        .datab     (32'h3f800000),
        .result    (add_result),
        .ready_out (1'b1),
        .valid_out (valid_out_add)
    );

    initial begin
        cycle = 0;
        valid_in = 0;
        repeat (5) @(posedge clk);
        reset = 0;
        repeat (2) @(posedge clk);
        valid_in = 1;
        @(posedge clk);
        valid_in = 0;
        repeat (32) @(posedge clk);
        $finish;
    end

    always @(posedge clk) begin
        if (!reset) begin
            cycle <= cycle + 1;
            if (valid_out_mul) begin
                $display("MUL cycle=%0d result=0x%08h", cycle, mul_result);
            end
            if (valid_out_add) begin
                $display("ADD cycle=%0d result=0x%08h", cycle, add_result);
            end
        end
    end

    `UNUSED_VAR (ready_in_mul)
    `UNUSED_VAR (ready_in_add)

endmodule
