`timescale 1ns/1ps

`include "VX_fpu_define.vh"

module tb_VX_fpu_exp_fpnew_trace;
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
    integer cycle;

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
        cycle = 0;
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
        valid_in = 1;
        @(posedge clk);
        valid_in = 0;
        repeat (64) @(posedge clk);
        $finish;
    end

    always @(posedge clk) begin
        if (!reset) begin
            cycle <= cycle + 1;
            if (cycle >= 30 && cycle <= 48) begin
                $display(
                    "C%0d vin=%0b pen=%0b pvalid=%0b vout=%0b t=%08h f=%08h p0=%08h p1=%08h p2=%08h p3=%08h nd=%0d res_s=%08h res=%h valids=%010b",
                    cycle,
                    valid_in,
                    dut.pe_enable,
                    dut.pe_serializer.pe_valid_in,
                    valid_out,
                    dut.g_fexps[0].t,
                    dut.g_fexps[0].f,
                    dut.g_fexps[0].p0,
                    dut.g_fexps[0].p1,
                    dut.g_fexps[0].p2,
                    dut.g_fexps[0].p3,
                    dut.g_fexps[0].n_d,
                    dut.g_fexps[0].result_s,
                    result[0],
                    dut.g_fexps[0].fpnew_valid_out
                );
            end
        end
    end

    `UNUSED_VAR (has_fflags)
    `UNUSED_VAR (fflags)
    `UNUSED_VAR (tag_out)
    `UNUSED_VAR (ready_in)

endmodule
