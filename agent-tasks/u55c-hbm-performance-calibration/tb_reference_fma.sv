`timescale 1ns/1ps
// Standalone check of archived vendor IP; no DUT substitution or synthesis.
module tb_reference_fma;
    reg clk=0, enable=1, valid=0;
    reg [31:0] a=0, b=0, c=0;
    reg [31:0] expected=32'h40000000;
    wire result_valid;
    wire [31:0] result;
    wire [2:0] flags;
    integer results=0;
    reg boundary_guard_enabled=0;
    reference_fma_guard boundary_guard(
        .clk(clk), .reset(!boundary_guard_enabled),
        .valid_in(valid), .ready_in(1'b1), .valid_out(1'b0), .ready_out(1'b1),
        .mask_in(1'b1), .mask_out(1'b1), .tag_in(1'b0), .tag_out(1'b0),
        .control(8'b0), .needs_c(1'b1), .a(a), .b(b), .c(c), .result(result));
    reg control_select=0;
    wire control_result;
    reference_x_control x_control(control_select, control_result);
    always #5 clk=~clk;
    xil_fma_lowL dut(.aclk(clk), .aclken(enable),
        .s_axis_a_tvalid(valid), .s_axis_a_tdata(a),
        .s_axis_b_tvalid(valid), .s_axis_b_tdata(b),
        .s_axis_c_tvalid(valid), .s_axis_c_tdata(c),
        .m_axis_result_tvalid(result_valid), .m_axis_result_tdata(result),
        .m_axis_result_tuser(flags));
    always @(negedge clk) begin
        if (enable && result_valid === 1'b1) begin
            $display("REFERENCE_FMA_RESULT t=%0t data=%h flags=%h", $time, result, flags);
            if ($test$plusargs("unknown")) begin
                if (!$isunknown(result)) $fatal(1, "Unknown input was hidden");
            end else if (result !== expected) $fatal(1, "Expected %h", expected);
            results=results+1;
        end
    end
    initial begin
        boundary_guard_enabled=$test$plusargs("boundary_guard");
        if ($test$plusargs("gated")) enable=0;
        if ($test$plusargs("check_x_control")) begin
            #1; control_select=1'bx; #1;
            if (control_result !== 1'bx) $fatal(1, "SV control X-propagation not active");
            $display("REFERENCE_X_CONTROL_PASS");
        end
        // Use a different falling-edge phase to avoid monitor/driver races.
        repeat (20) @(negedge clk);
        #1;
        a=32'h3f800000; b=32'h3f800000; c=32'h3f800000; valid=1; enable=1;
        if ($test$plusargs("captured")) begin
            a=32'h3f64f23c; c=32'h3f20eebf; expected=32'h3fc2f07e;
        end
        if ($test$plusargs("unknown")) a='x;
        @(negedge clk); #1; valid=0;
        a=0; b=0; c=0;
        if ($test$plusargs("gated")) begin
            repeat (3) @(negedge clk);
            #1; enable=0;
        end
        repeat (12) @(negedge clk);
        #1;
        if (results != 1) $fatal(1, "Expected one result, got %0d", results);
        $display("REFERENCE_FMA_PASS");
        $finish;
    end
endmodule
module reference_x_control(input wire select, output reg result);
    always @(*) begin
        if (select) result=1'b1;
        else result=1'b0;
    end
endmodule
config reference_fma_cfg;
    design work.tb_reference_fma;
    default liblist work xil_defaultlib;
endconfig
