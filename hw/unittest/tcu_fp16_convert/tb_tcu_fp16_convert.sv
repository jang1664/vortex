`timescale 1ns/1ps

module tb_tcu_fp16_convert;
    import "DPI-C" function int unsigned tcu_half_reference(input int unsigned bits);
    logic [15:0] fp16_in;
    wire [31:0] fp32_out;
    fp16_to_fp32 dut (.*);

    initial begin
        int errors, subnormal_errors, subnormals, nans;
        logic [31:0] expected;
        logic mismatch;
        errors = 0; subnormal_errors = 0; subnormals = 0; nans = 0;
        for (int bits = 0; bits < 65536; ++bits) begin
            fp16_in = 16'(bits);
            expected = tcu_half_reference(bits);
            #1;
            if (fp16_in[14:10] == 31 && fp16_in[9:0] != 0) begin
                // Payload placement is implementation-defined here; require
                // a quiet NaN, preserving the existing converter contract.
                mismatch = (fp32_out[30:22] !== 9'h1ff);
                nans++;
            end else begin
                mismatch = (fp32_out !== expected);
            end
            if (fp16_in[14:10] == 0 && fp16_in[9:0] != 0) begin
                subnormals++;
                if (mismatch) subnormal_errors++;
            end
            if (mismatch) begin
                if (errors < 8)
                    $display("MISMATCH half=%04x got=%08x expected=%08x", fp16_in, fp32_out, expected);
                errors++;
            end
        end
        $display("TCU converter: inputs=65536 subnormals=%0d NaNs=%0d mismatches=%0d subnormal_mismatches=%0d",
                 subnormals, nans, errors, subnormal_errors);
        if (errors) $fatal(1, "FAILED: TCU FP16 widening");
        $display("PASSED: TCU FP16 widening (finite/Inf/zero bit-exact; NaN class)");
        $finish;
    end
endmodule
