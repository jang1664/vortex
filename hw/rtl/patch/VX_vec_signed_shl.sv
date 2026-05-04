// Per-row variable left-shift (act_reduce input alignment):
//   out[i] = signed(in[i]) <<< (BLOCK_SIZE * shamt[i])
// One module instance so the shifter array shows up in hierarchy reports.
`include "VX_define.vh"

module VX_vec_signed_shl #(
    parameter int N           = `MXU_ROW,
    parameter int IN_W        = 0,
    parameter int OUT_W       = 0,
    parameter int SHAMT_W     = 0,
    parameter int BLOCK_SIZE  = 1
) (
    input  wire signed [N-1:0][IN_W-1:0]   in_i,
    input  wire        [N-1:0][SHAMT_W-1:0] shamt_i,
    output wire signed [N-1:0][OUT_W-1:0]  out_o
);
    genvar i;
    generate
        for (i = 0; i < N; i++) begin : g_lane
            assign out_o[i] = $signed(in_i[i]) <<< (BLOCK_SIZE * shamt_i[i]);
        end
    endgenerate
endmodule
