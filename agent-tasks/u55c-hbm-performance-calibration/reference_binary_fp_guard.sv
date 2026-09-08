`timescale 1ns/1ps
// Independent AXI-stream operand checks. No data driving or X coercion.
module reference_binary_fp_guard #(parameter W=32)(
    input wire clk, reset,
    input wire av, ar, bv, br, rv, rr,
    input wire [W-1:0] a, b, result
);
    always @(posedge clk) if (reset === 1'b0) begin
        if ($isunknown({av,bv,rv})) $fatal(1,"REFERENCE_BINARY_FP_VALID");
        if (av === 1'b1) begin
            if ($isunknown(ar)) $fatal(1,"REFERENCE_BINARY_FP_A_READY");
            if ($isunknown(a)) $fatal(1,"REFERENCE_BINARY_FP_A_DATA");
        end
        if (bv === 1'b1) begin
            if ($isunknown(br)) $fatal(1,"REFERENCE_BINARY_FP_B_READY");
            if ($isunknown(b)) $fatal(1,"REFERENCE_BINARY_FP_B_DATA");
        end
        if (rv === 1'b1) begin
            if ($isunknown(rr)) $fatal(1,"REFERENCE_BINARY_FP_RESULT_READY");
            if ($isunknown(result)) $fatal(1,"REFERENCE_BINARY_FP_RESULT_DATA");
        end
    end
endmodule
