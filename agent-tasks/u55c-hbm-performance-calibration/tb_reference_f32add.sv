`timescale 1ns/1ps
// Captured accumulator cancellation, lane1 sequence640 of long-K GEMM.
module tb_reference_f32add;
    reg clk=0, resetn=0, valid=0;
    reg [31:0] a=0, b=0;
    wire ar, br, rv;
    wire [31:0] result;
    integer count=0;
    reference_binary_fp_guard boundary_guard(
        .clk(clk), .reset(!resetn), .av(valid), .ar(ar), .bv(valid), .br(br),
        .rv(rv), .rr(1'b1), .a(a), .b(b), .result(result));
    always #5 clk=~clk;
    xil_f32add_latency1 dut(
        .aclk(clk), .aresetn(resetn), .aclken(1'b1),
        .s_axis_a_tvalid(valid), .s_axis_a_tready(ar), .s_axis_a_tdata(a),
        .s_axis_b_tvalid(valid), .s_axis_b_tready(br), .s_axis_b_tdata(b),
        .m_axis_result_tvalid(rv), .m_axis_result_tready(1'b1),
        .m_axis_result_tdata(result));
    always @(negedge clk) if (resetn && rv === 1'b1) begin
        $display("REFERENCE_F32ADD_RESULT data=%h", result);
        if (result !== 32'h00000000) $fatal(1,"Captured cancellation mismatch");
        count=count+1;
    end
    initial begin
        repeat (10) @(negedge clk);
        #1; resetn=1;
        repeat (10) @(negedge clk);
        #1; a=32'h4251e000; b=32'hc251e000; valid=1;
        if ($test$plusargs("unknown_a")) a='x;
        if ($test$plusargs("unknown_b")) b='x;
        @(posedge clk);
        if (ar !== 1'b1 || br !== 1'b1) $fatal(1,"Input not accepted");
        @(negedge clk); #1; valid=0; a=0; b=0;
        repeat (10) @(negedge clk);
        #1;
        if (count != 1) $fatal(1,"Expected exactly one result");
        $display("REFERENCE_F32ADD_PASS");
        $finish;
    end
endmodule
config reference_f32add_cfg;
    design work.tb_reference_f32add;
    default liblist work xil_defaultlib;
endconfig
