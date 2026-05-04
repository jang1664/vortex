// Per-output-column signed-integer adder array (merger stage:
// merger_out = signed(mxu_output) + signed(pre_proc_out)).
`include "VX_define.vh"

module VX_vec_signed_add #(
    parameter int N    = `MXU_COL,
    parameter int A_W  = 0,
    parameter int B_W  = 0,
    parameter int OUT_W= 0
) (
    input  wire signed [N-1:0][A_W-1:0]   a_i,
    input  wire signed [N-1:0][B_W-1:0]   b_i,
    output wire signed [N-1:0][OUT_W-1:0] sum_o
);
    genvar i;
    generate
        for (i = 0; i < N; i++) begin : g_lane
            assign sum_o[i] = $signed(a_i[i]) + $signed(b_i[i]);
        end
    endgenerate
endmodule
