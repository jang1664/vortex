// Per-output-column FP32→FP16 cast array.
`include "VX_define.vh"

module VX_vec_f32_to_f16 #(
    parameter int N       = `MXU_COL,
    parameter int OUT_REG = 0
) (
    input  wire                       clk_i,
    input  wire                       resetn_i,
    input  wire [N-1:0]               valid_i,
    input  wire [N-1:0][31:0]         data_i,
    output wire [N-1:0]               valid_o,
    output wire [N-1:0][15:0]         data_o
);
    genvar i;
    generate
        for (i = 0; i < N; i++) begin : g_lane
            VX_f32_to_f16 #(
                .OUT_REG(OUT_REG)
            ) u_cast (
                .clk_i    (clk_i),
                .resetn_i (resetn_i),
                .valid_i  (valid_i[i]),
                .data_i   (data_i[i]),
                .valid_o  (valid_o[i]),
                .data_o   (data_o[i])
            );
        end
    endgenerate
endmodule
