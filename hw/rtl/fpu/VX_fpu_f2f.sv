// Copyright © 2019-2026
// Licensed under the Apache License, Version 2.0

`include "VX_fpu_define.vh"

`ifdef FPU_DSP

// Vivado scalar floating-point format conversion.  The DSP backend keeps
// values in 32-bit containers; FP16 results are NaN-boxed before they leave
// this module.
module VX_fpu_f2f import VX_gpu_pkg::*, VX_fpu_pkg::*; #(
    parameter NUM_LANES = 1,
    parameter NUM_PES   = `UP(NUM_LANES / `FCVT_PE_RATIO),
    parameter TAG_WIDTH = 1,
    parameter DST_FORMAT = 0,
    parameter LATENCY = 2
) (
    input wire clk,
    input wire reset,
    input wire valid_in,
    output wire ready_in,
    input wire [NUM_LANES-1:0] mask_in,
    input wire [TAG_WIDTH-1:0] tag_in,
    input wire [INST_FRM_BITS-1:0] frm,
    input wire [NUM_LANES-1:0][31:0] dataa,
    output wire [NUM_LANES-1:0][31:0] result,
    output wire has_fflags,
    output wire [`FP_FLAGS_BITS-1:0] fflags,
    output wire [TAG_WIDTH-1:0] tag_out,
    output wire valid_out,
    input wire ready_out
);
    localparam DATAW = 32 + INST_FRM_BITS;
    wire [NUM_LANES-1:0][DATAW-1:0] data_in;
    wire [NUM_LANES-1:0] mask_out;
    wire [NUM_LANES-1:0][(`FP_FLAGS_BITS+32)-1:0] data_out;
    fflags_t [NUM_LANES-1:0] fflags_out;
    wire pe_enable;
    wire [NUM_PES-1:0][DATAW-1:0] pe_data_in;
    wire [NUM_PES-1:0][(`FP_FLAGS_BITS+32)-1:0] pe_data_out;

    for (genvar i = 0; i < NUM_LANES; ++i) begin : g_input
        assign data_in[i] = {frm, (DST_FORMAT == 0 && ~&dataa[i][31:16])
                                    ? 32'hffff7e00 : dataa[i]};
    end

    VX_pe_serializer #(
        .NUM_LANES(NUM_LANES), .NUM_PES(NUM_PES), .LATENCY(LATENCY),
        .DATA_IN_WIDTH(DATAW), .DATA_OUT_WIDTH(`FP_FLAGS_BITS + 32),
        .TAG_WIDTH(NUM_LANES + TAG_WIDTH), .PE_REG(0), .OUT_BUF(2)
    ) pe_serializer (
        .clk(clk), .reset(reset), .valid_in(valid_in), .data_in(data_in),
        .tag_in({mask_in, tag_in}), .ready_in(ready_in), .pe_enable(pe_enable),
        .pe_data_out(pe_data_in), .pe_data_in(pe_data_out),
        .valid_out(valid_out), .data_out(data_out),
        .tag_out({mask_out, tag_out}), .ready_out(ready_out)
    );

    for (genvar i = 0; i < NUM_LANES; ++i) begin : g_output
        assign result[i] = data_out[i][0 +: 32];
        assign fflags_out[i] = data_out[i][32 +: `FP_FLAGS_BITS];
    end

`ifdef VIVADO
    localparam S_EXP_BITS = 8;
    localparam S_MAN_BITS = 23;
    localparam H_EXP_BITS = 5;
    localparam H_MAN_BITS = 10;
    localparam S_EXP_BIAS = 2**(S_EXP_BITS-1)-1;
    localparam H_EXP_BIAS = 2**(H_EXP_BITS-1)-1;
    localparam H_MIN_NORMAL_EXP = S_EXP_BIAS - H_EXP_BIAS + 1;
    localparam SUBNORMAL_SHIFT_BIAS = S_EXP_BIAS + S_MAN_BITS
                                   - H_EXP_BIAS - H_MAN_BITS + 1;

    for (genvar i = 0; i < NUM_PES; ++i) begin : g_convert
        // Float-to-float conversion exposes overflow and underflow status.
        wire [1:0] tuser;
        wire [31:0] ip_result;
        wire correction_select;
        wire [31:0] correction_result;
        wire [`FP_FLAGS_BITS-1:0] correction_fflags;
        if (DST_FORMAT == 2) begin : g_to_half
            wire [15:0] result_h;
            xil_f32_to_f16 convert (
                .aclk(clk), .aclken(pe_enable),
                .s_axis_a_tvalid(1'b1),
                .s_axis_a_tdata(pe_data_in[i][0 +: 32]),
                `UNUSED_PIN(m_axis_result_tvalid),
                .m_axis_result_tdata(result_h),
                .m_axis_result_tuser(tuser)
            );
            assign ip_result = {16'hffff, result_h};

            // The IP flushes subnormal results. Quantize small finite inputs
            // in units of the half-precision minimum subnormal (2^-24).
            wire input_sign = pe_data_in[i][31];
            wire [S_EXP_BITS-1:0] input_exp = pe_data_in[i][S_MAN_BITS +: S_EXP_BITS];
            wire [S_MAN_BITS:0] input_mant = {
                (| input_exp), pe_data_in[i][S_MAN_BITS-1:0]
            };
            assign correction_select = (input_exp < S_EXP_BITS'(H_MIN_NORMAL_EXP));

            // FP32 subnormals have effective exponent 1 and no hidden bit.
            // Clamp shifts beyond the significand to one guard-zero/sticky
            // case, so even the smallest nonzero FP32 inputs round correctly.
            wire [S_EXP_BITS-1:0] denorm_shift = correction_select
                ? S_EXP_BITS'(SUBNORMAL_SHIFT_BIAS) - ((input_exp == 0) ? S_EXP_BITS'(1) : input_exp)
                : S_EXP_BITS'(S_MAN_BITS - H_MAN_BITS + 1);
            wire [S_EXP_BITS-1:0] round_shift = (denorm_shift > S_EXP_BITS'(S_MAN_BITS + 2))
                ? S_EXP_BITS'(S_MAN_BITS + 2) : denorm_shift;
            wire [S_MAN_BITS:0] shifted_mant = input_mant >> round_shift;
            wire [S_MAN_BITS:0] guard_mant = input_mant >> (round_shift - S_EXP_BITS'(1));
            wire [S_MAN_BITS:0] sticky_mask = {(S_MAN_BITS+1){1'b1}}
                >> (S_EXP_BITS'(S_MAN_BITS + 2) - round_shift);
            wire [1:0] round_sticky = {guard_mant[0], (| (input_mant & sticky_mask))};
            wire [H_MAN_BITS:0] rounded_mant;
            wire rounded_sign;

            VX_fp_rounding #(
                .DAT_WIDTH (H_MAN_BITS + 1)
            ) fp_rounding (
                .abs_value_i (shifted_mant[H_MAN_BITS:0]),
                .sign_i (input_sign),
                .round_sticky_bits_i (round_sticky),
                .rnd_mode_i (pe_data_in[i][32 +: INST_FRM_BITS]),
                .effective_subtraction_i (1'b0),
                .abs_rounded_o (rounded_mant),
                .sign_o (rounded_sign),
                `UNUSED_PIN (exact_zero_o)
            );

            // Detect tininess after rounding to half precision with an
            // unbounded exponent, before the subnormal right shift. A stored
            // result of 0x0400 can still be tiny by this IEEE definition.
            wire [H_MAN_BITS+1:0] normal_precision_rounded;
            VX_fp_rounding #(
                .DAT_WIDTH (H_MAN_BITS + 2)
            ) tininess_rounding (
                .abs_value_i ({1'b0, input_mant[S_MAN_BITS:S_MAN_BITS-H_MAN_BITS]}),
                .sign_i (input_sign),
                .round_sticky_bits_i ({input_mant[S_MAN_BITS-H_MAN_BITS-1],
                                      (| input_mant[S_MAN_BITS-H_MAN_BITS-2:0])}),
                .rnd_mode_i (pe_data_in[i][32 +: INST_FRM_BITS]),
                .effective_subtraction_i (1'b0),
                .abs_rounded_o (normal_precision_rounded),
                `UNUSED_PIN (sign_o),
                `UNUSED_PIN (exact_zero_o)
            );

            wire tiny = (input_exp < S_EXP_BITS'(H_MIN_NORMAL_EXP - 1))
                || ((input_exp == S_EXP_BITS'(H_MIN_NORMAL_EXP - 1))
                    && ~normal_precision_rounded[H_MAN_BITS+1]);
            wire inexact = (| round_sticky);
            assign correction_result = {16'hffff, rounded_sign,
                                        {(H_EXP_BITS-1){1'b0}}, rounded_mant};
            assign correction_fflags = {3'b0, (inexact && tiny), inexact};
            `UNUSED_VAR ({shifted_mant[S_MAN_BITS:H_MAN_BITS+1], guard_mant[S_MAN_BITS:1]})
            `UNUSED_VAR (normal_precision_rounded[H_MAN_BITS:0])
        end else begin : g_to_single
            xil_f16_to_f32 convert (
                .aclk(clk), .aclken(pe_enable),
                .s_axis_a_tvalid(1'b1),
                .s_axis_a_tdata(pe_data_in[i][0 +: 16]),
                `UNUSED_PIN(m_axis_result_tvalid),
                .m_axis_result_tdata(ip_result),
                .m_axis_result_tuser(tuser)
            );

            wire [H_EXP_BITS-1:0] input_exp = pe_data_in[i][H_MAN_BITS +: H_EXP_BITS];
            wire [H_MAN_BITS-1:0] input_mant = pe_data_in[i][H_MAN_BITS-1:0];
            wire [`LOG2UP(H_MAN_BITS)-1:0] leading_zeros;
            wire mant_nonzero;
            VX_lzc #(
                .N (H_MAN_BITS)
            ) lzc (
                .data_in (input_mant),
                .data_out (leading_zeros),
                .valid_out (mant_nonzero)
            );

            // Every half subnormal widens exactly to a normal FP32 value.
            wire [H_MAN_BITS-1:0] normalized_mant = input_mant
                << (leading_zeros + `LOG2UP(H_MAN_BITS)'(1));
            wire [S_EXP_BITS-1:0] normalized_exp = S_EXP_BITS'(S_EXP_BIAS - H_EXP_BIAS)
                - S_EXP_BITS'(leading_zeros);
            assign correction_select = (input_exp == 0) && mant_nonzero;
            assign correction_result = {pe_data_in[i][15], normalized_exp,
                                        normalized_mant, {(S_MAN_BITS-H_MAN_BITS){1'b0}}};
            assign correction_fflags = '0;
        end

        wire correction_select_out;
        wire [31:0] correction_result_out;
        wire [`FP_FLAGS_BITS-1:0] correction_fflags_out;
        VX_shift_register #(
            .DATAW (1 + 32 + `FP_FLAGS_BITS),
            .RESETW (1),
            .DEPTH (LATENCY)
        ) correction_pipe (
            .clk (clk),
            .reset (reset),
            .enable (pe_enable),
            .data_in ({correction_select, correction_fflags, correction_result}),
            .data_out ({correction_select_out, correction_fflags_out, correction_result_out})
        );
        assign pe_data_out[i] = correction_select_out
            ? {correction_fflags_out, correction_result_out}
            : {1'b0, 1'b0, tuser[1], tuser[0], 1'b0, ip_result};
    end
`else
    // EXT_ZFH_ENABLE is rejected for non-Vivado DSP configurations.
    assign pe_data_out = '0;
`endif

    assign has_fflags = 1'b1;
    `FPU_MERGE_FFLAGS(fflags, fflags_out, mask_out, NUM_LANES);
    `UNUSED_VAR (pe_data_in)

endmodule

`endif
