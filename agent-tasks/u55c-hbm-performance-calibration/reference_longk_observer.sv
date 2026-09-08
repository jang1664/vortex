`timescale 1ns/1ps
// Non-driving accepted-transaction trace. Independent operand channels retain
// their own sequence numbers; do not assume simultaneous A/B acceptance.
module reference_longk_probe #(parameter W=32)(
    input wire clk, reset, valid, ready,
    input wire [W-1:0] data
);
    integer seq=0;
    integer anomalies=0;
    wire unknown_data = $isunknown(data);
    wire special_data = (W == 32) ? (&data[W-2 -: 8]) : (&data[W-2 -: 5]);
    always @(posedge clk) begin
        if (reset === 1'b0 && valid === 1'b1 && ready === 1'b1) begin
            if (seq < 16 || (seq >= 632 && seq <= 644)
                || ((unknown_data || special_data) && anomalies < 16))
                $display("REFERENCE_LONGK %m t=%0t seq=%0d data=%h unknown=%b special=%b",
                         $time, seq, data, unknown_data, special_data);
            if (unknown_data || special_data) anomalies=anomalies+1;
            seq=seq+1;
        end
    end
endmodule
bind VX_fp32_add reference_longk_probe add_a(
    .clk(clk), .reset(reset), .valid(a_valid), .ready(a_ready), .data(a_data));
bind VX_fp32_add reference_longk_probe add_b(
    .clk(clk), .reset(reset), .valid(b_valid), .ready(b_ready), .data(b_data));
bind VX_fp32_add reference_longk_probe add_r(
    .clk(clk), .reset(reset), .valid(result_valid), .ready(result_ready), .data(result_data));
bind VX_fp32_mul reference_longk_probe mul_a(
    .clk(clk), .reset(reset), .valid(a_valid), .ready(a_ready), .data(a_data));
bind VX_fp32_mul reference_longk_probe mul_b(
    .clk(clk), .reset(reset), .valid(b_valid), .ready(b_ready), .data(b_data));
bind VX_fp32_mul reference_longk_probe mul_r(
    .clk(clk), .reset(reset), .valid(result_valid), .ready(result_ready), .data(result_data));
bind VX_f32_to_f16 reference_longk_probe convert_in(
    .clk(clk_i), .reset(~resetn_i), .valid(valid_i), .ready(1'b1), .data(data_i));
bind VX_f32_to_f16 reference_longk_probe #(.W(16)) convert_out(
    .clk(clk_i), .reset(~resetn_i), .valid(valid_o), .ready(1'b1), .data(data_o));
