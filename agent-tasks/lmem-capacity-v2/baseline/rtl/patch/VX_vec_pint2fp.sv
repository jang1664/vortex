// Per-output-column INT-to-FP converter array. One instance per MXU column.
`include "VX_define.vh"

module VX_vec_pint2fp #(
    parameter int N                 = `MXU_COL,
    parameter int IN_DW             = 0,
    parameter int OUT_DW            = 0,
    parameter int IN_EXP_WIDTH      = 0,
    parameter int OUT_EXP_WIDTH     = 0,
    parameter int IN_EXP_BIAS       = 0,
    parameter int OUT_EXP_BIAS      = 0,
    parameter int OUT_MANTISSA_WIDTH= 0,
    parameter int SCALE             = 0
) (
    input  wire                                  clk_i,
    input  wire                                  resetn_i,

    input  wire [N-1:0][IN_DW-1:0]               int_data_i,
    input  wire        [IN_EXP_WIDTH-1:0]        max_exp_i,
    input  wire [N-1:0]                          valid_i,

    output wire [N-1:0][OUT_DW-1:0]              fp_data_o,
    output wire [N-1:0]                          valid_o
);
    genvar i;
    generate
        for (i = 0; i < N; i++) begin : g_lane
            VX_pint2fp #(
                .IN_DW             (IN_DW),
                .OUT_DW            (OUT_DW),
                .IN_EXP_WIDTH      (IN_EXP_WIDTH),
                .OUT_EXP_WIDTH     (OUT_EXP_WIDTH),
                .IN_EXP_BIAS       (IN_EXP_BIAS),
                .OUT_EXP_BIAS      (OUT_EXP_BIAS),
                .OUT_MANTISSA_WIDTH(OUT_MANTISSA_WIDTH),
                .SCALE             (SCALE)
            ) u_int2fp (
                .clk_i      (clk_i),
                .resetn_i   (resetn_i),
                .int_data_i (int_data_i[i]),
                .max_exp_i  (max_exp_i),
                .valid_i    (valid_i[i]),
                .fp_data_o  (fp_data_o[i]),
                .valid_o    (valid_o[i])
            );
        end
    endgenerate
endmodule
