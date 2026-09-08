// Simulation-only boundary checks; never drives or coerces DUT data.
module reference_fma_guard #(parameter N=1, TW=1)(
    input wire clk, reset,
    input wire valid_in, ready_in, valid_out, ready_out,
    input wire [N-1:0] mask_in, mask_out,
    input wire [TW-1:0] tag_in, tag_out,
    input wire [7:0] control,
    input wire needs_c,
    input wire [N-1:0][31:0] a, b, c, result
);
    always @(posedge clk) begin
        if (reset === 1'b0) begin
            if ($isunknown({valid_in, valid_out}))
                $fatal(1, "REFERENCE_FMA_GUARD_VALID");
            if (valid_in === 1'b1) begin
                if ($isunknown({ready_in, mask_in, tag_in}))
                    $fatal(1, "REFERENCE_FMA_GUARD_INPUT_CONTROL");
                if (|mask_in) begin
                    if ($isunknown({control, needs_c}))
                        $fatal(1, "REFERENCE_FMA_GUARD_OPERATION");
                    for (integer i=0; i<N; i=i+1)
                        if (mask_in[i] === 1'b1 &&
                            ($isunknown({a[i], b[i]}) || (needs_c && $isunknown(c[i]))))
                            $fatal(1, "REFERENCE_FMA_GUARD_OPERAND lane=%0d", i);
                end
            end
            if (valid_out === 1'b1) begin
                if ($isunknown({ready_out, mask_out, tag_out}))
                    $fatal(1, "REFERENCE_FMA_GUARD_OUTPUT_CONTROL");
                for (integer i=0; i<N; i=i+1)
                    if (mask_out[i] === 1'b1 && $isunknown(result[i]))
                        $fatal(1, "REFERENCE_FMA_GUARD_RESULT lane=%0d", i);
            end
        end
    end
endmodule
