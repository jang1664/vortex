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
    for (genvar i = 0; i < NUM_PES; ++i) begin : g_convert
        // Float-to-float conversion exposes overflow and underflow status.
        wire [1:0] tuser;
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
            assign pe_data_out[i][0 +: 32] = {16'hffff, result_h};
        end else begin : g_to_single
            xil_f16_to_f32 convert (
                .aclk(clk), .aclken(pe_enable),
                .s_axis_a_tvalid(1'b1),
                .s_axis_a_tdata(pe_data_in[i][0 +: 16]),
                `UNUSED_PIN(m_axis_result_tvalid),
                .m_axis_result_tdata(pe_data_out[i][0 +: 32]),
                .m_axis_result_tuser(tuser)
            );
        end
        assign pe_data_out[i][32 +: `FP_FLAGS_BITS] =
            {1'b0, 1'b0, tuser[1], tuser[0], 1'b0};
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
