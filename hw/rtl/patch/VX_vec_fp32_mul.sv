// FP32 multiplier vector for the output-scaler stage when the GEMM unit
// produces FP32 outputs (compile-time alternative to VX_vec_fp16_mul_outscale).
`include "VX_define.vh"

module VX_vec_fp32_mul #(
    parameter int N        = `MXU_COL,
    parameter int LATENCY  = 1,
    parameter int OUT_BUF  = 1
) (
    input  wire                       clk,
    input  wire                       reset,

    input  wire [N-1:0]               a_valid,
    output wire [N-1:0]               a_ready,
    input  wire [N-1:0][31:0]         a_data,

    input  wire [N-1:0]               b_valid,
    output wire [N-1:0]               b_ready,
    input  wire [N-1:0][31:0]         b_data,

    output wire [N-1:0]               result_valid,
    input  wire [N-1:0]               result_ready,
    output wire [N-1:0][31:0]         result_data
);
    genvar i;
    generate
        for (i = 0; i < N; i++) begin : g_lane
            VX_fp32_mul #(
                .LATENCY(LATENCY),
                .OUT_BUF(OUT_BUF)
            ) u_mul (
                .clk          (clk),
                .reset        (reset),
                .a_valid      (a_valid[i]),
                .a_ready      (a_ready[i]),
                .a_data       (a_data[i]),
                .b_valid      (b_valid[i]),
                .b_ready      (b_ready[i]),
                .b_data       (b_data[i]),
                .result_valid (result_valid[i]),
                .result_ready (result_ready[i]),
                .result_data  (result_data[i])
            );
        end
    endgenerate
endmodule
