// FP16 multiplier vector (in_scaler use). N parallel `VX_fp16_mul` instances
// wrapped as a single named module so the hierarchy report attributes
// area/power to this block in one line. Used for per-row activation × scale.
`include "VX_define.vh"

module VX_vec_fp16_mul #(
    parameter int N        = `MXU_ROW,
    parameter int LATENCY  = 1,
    parameter int OUT_BUF  = 1
) (
    input  wire                       clk,
    input  wire                       reset,

    input  wire [N-1:0]               a_valid,
    output wire [N-1:0]               a_ready,
    input  wire [N-1:0][15:0]         a_data,

    input  wire [N-1:0]               b_valid,
    output wire [N-1:0]               b_ready,
    input  wire [N-1:0][15:0]         b_data,

    output wire [N-1:0]               result_valid,
    input  wire [N-1:0]               result_ready,
    output wire [N-1:0][15:0]         result_data
);
    genvar i;
    generate
        for (i = 0; i < N; i++) begin : g_lane
            VX_fp16_mul #(
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
