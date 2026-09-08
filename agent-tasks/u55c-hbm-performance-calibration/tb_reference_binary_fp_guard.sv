`timescale 1ns/1ps
module tb_reference_binary_fp_guard;
    reg clk=0, reset=1, av=0, ar=1, bv=0, br=1, rv=0, rr=1;
    reg [31:0] a=0, b=0, result=0;
    string test_case;
    always #5 clk=~clk;
    reference_binary_fp_guard dut(.*);
    initial begin
        if (!$value$plusargs("case=%s",test_case)) $fatal(1,"Missing case");
        @(negedge clk); #1; reset=0; av=1; bv=1; rv=1;
        case (test_case)
            "valid": begin end
            "idle": begin av=0; bv=0; rv=0; a='x; b='x; result='x; end
            "stalled": begin ar=0; br=0; rr=0; end
            "a_only": begin bv=0; b='x; end
            "b_only": begin av=0; a='x; end
            "av": av='x;
            "bv": bv='x;
            "rv": rv='x;
            "ar": ar='x;
            "br": br='x;
            "rr": rr='x;
            "a": a='x;
            "b": b='x;
            "result": result='x;
            "stalled_a": begin ar=0; a='x; end
            "stalled_result": begin rr=0; result='x; end
            default: $fatal(1,"Unknown case");
        endcase
        repeat (3) @(negedge clk);
        $display("REFERENCE_BINARY_FP_PASS");
        $finish;
    end
endmodule
