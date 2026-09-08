`timescale 1ns/1ps
// Non-driving, bounded lane-zero stage trace for historical GEMM diagnosis.
module reference_gemm_probe #(parameter W=32)(
    input wire clk, reset, valid,
    input wire [W-1:0] data
);
    integer count=0;
    always @(posedge clk)
        if (reset === 1'b0 && valid === 1'b1 && count < 40) begin
            $display("REFERENCE_GEMM %m t=%0t data=%h", $time, data);
            count=count+1;
        end
endmodule
bind VX_gemm_compute_core reference_gemm_probe #(.W(16)) trace_input(
    .clk(clk), .reset(reset), .valid(in_pipe_valid_out), .data(in_pipe_data_out[15:0]));
bind VX_gemm_compute_core reference_gemm_probe #(.W($bits(prealigner_int_data[0])+$bits(prealigner_max_exp))) trace_aligned(
    .clk(clk), .reset(reset), .valid(prealigner_out_valid), .data({prealigner_max_exp, prealigner_int_data[0]}));
bind VX_gemm_compute_core reference_gemm_probe #(.W($bits(merger_out_data_q[0])+$bits(prealigner_max_exp_q))) trace_merged(
    .clk(clk), .reset(reset), .valid(merger_out_valid), .data({prealigner_max_exp_q, merger_out_data_q[0]}));
bind VX_gemm_compute_core reference_gemm_probe #(.W($bits(int2fp_out_data[0]))) trace_int2fp(
    .clk(clk), .reset(reset), .valid(int2fp_output_valid[0]), .data(int2fp_out_data[0]));
bind VX_fp32_mul reference_gemm_probe #(.W(64)) trace_mul_input(
    .clk(clk), .reset(reset), .valid(a_valid && a_ready && b_valid && b_ready), .data({a_data, b_data}));
bind VX_fp32_mul reference_gemm_probe #(.W(32)) trace_mul_output(
    .clk(clk), .reset(reset), .valid(result_valid && result_ready), .data(result_data));
bind VX_fp32_add reference_gemm_probe #(.W(32)) trace_add_output(
    .clk(clk), .reset(reset), .valid(result_valid && result_ready), .data(result_data));
bind VX_f32_to_f16 reference_gemm_probe #(.W(32)) trace_convert_input(
    .clk(clk_i), .reset(~resetn_i), .valid(valid_i), .data(data_i));
bind VX_f32_to_f16 reference_gemm_probe #(.W(16)) trace_convert_output(
    .clk(clk_i), .reset(~resetn_i), .valid(valid_o), .data(data_o));
