// Observe accepted DSP-FPU operands/results without altering the archived DUT.
module reference_fpu_observer #(parameter N=1, TW=1)(
    input wire clk, reset, valid_in, ready_in, valid_out, ready_out,
    input wire [N-1:0] mask,
    input wire [TW-1:0] in_tag, out_tag,
    input wire [3:0] op,
    input wire [N-1:0][63:0] a, b, c, result
);
    integer ni=0, no=0;
    always @(posedge clk) begin
        if (reset === 1'b0 && valid_in === 1'b1 && ready_in === 1'b1 && ni<64) begin
            $display("REFERENCE_FPU_IN %m t=%0t tag=%h op=%h mask=%h a=%h b=%h c=%h",
                $time, in_tag, op, mask, a, b, c);
            ni=ni+1;
        end
        if (reset === 1'b0 && valid_out === 1'b1 && ready_out === 1'b1 && no<64) begin
            $display("REFERENCE_FPU_OUT %m t=%0t tag=%h result=%h", $time, out_tag, result);
            no=no+1;
        end
    end
endmodule
bind VX_fpu_dsp reference_fpu_observer #(.N(NUM_LANES), .TW(TAG_WIDTH)) reference_fpu_observer_i(
    .clk(clk), .reset(reset), .valid_in(valid_in), .ready_in(ready_in),
    .valid_out(valid_out), .ready_out(ready_out), .mask(mask_in),
    .in_tag(tag_in), .out_tag(tag_out), .op(op_type),
    .a(dataa), .b(datab), .c(datac), .result(result)
);

module reference_fma_observer(
    input wire clk, reset, issue, enable, valid_out,
    input wire [31:0] a, b, c, ip_result
);
    integer remaining=0, records=0;
    always @(posedge clk) begin
        if (reset === 1'b0 && issue === 1'b1) remaining=12;
        if (reset === 1'b0 && remaining>0 && records<64) begin
            $display("REFERENCE_FMA_IP %m t=%0t issue=%b enable=%b out_valid=%b a=%h b=%h c=%h ip_result=%h",
                $time, issue, enable, valid_out, a, b, c, ip_result);
            remaining=remaining-1;
            records=records+1;
        end
    end
endmodule
bind VX_fpu_fma reference_fma_observer reference_fma_observer_i(
    .clk(clk), .reset(reset), .issue(pe_issue_s), .enable(pe_enable_s), .valid_out(valid_out),
    .a(pe_data_in[0][0 +: 32]), .b(pe_data_in[0][32 +: 32]), .c(pe_data_in[0][64 +: 32]),
    .ip_result(g_fmas[0].result_s)
);
