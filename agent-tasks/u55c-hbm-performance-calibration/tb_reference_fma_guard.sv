`timescale 1ns/1ps
module tb_reference_fma_guard;
    reg clk=0, reset=1, vi=0, vo=0, ri=1, ro=1, needs_c=0;
    reg [1:0] mi=1, mo=1;
    reg [7:0] control=0;
    reg [1:0][31:0] a=0, b=0, c='x, result=0;
    string test_case;
    always #5 clk=~clk;
    reference_fma_guard #(.N(2)) dut(clk, reset, vi, ri, vo, ro, mi, mo,
        1'b0, 1'b0, control, needs_c, a, b, c, result);
    initial begin
        if (!$value$plusargs("case=%s", test_case)) $fatal(1, "Missing case");
        @(negedge clk); reset=0; vi=1; vo=1;
        case (test_case)
            "valid": c=0;
            "unused_c": c='x;
            "inactive": begin a[1]='x; b[1]='x; result[1]='x; end
            "operand": a[0]='x;
            "madd_c": needs_c=1;
            "operation": control='x;
            "mask": mi='x;
            "result": result[0]='x;
            "valid_x": vi=1'bx;
            "ready_x": ri=1'bx;
            "out_mask": mo='x;
            default: $fatal(1, "Unknown case");
        endcase
        repeat (3) @(negedge clk);
        $display("REFERENCE_FMA_GUARD_PASS %s", test_case);
        $finish;
    end
endmodule
