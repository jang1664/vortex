// Copyright © 2019-2023
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

`include "VX_fpu_define.vh"

`ifdef FPU_DSP

module VX_fpu_exp import VX_gpu_pkg::*, VX_fpu_pkg::*; #(
    parameter NUM_LANES = 1,
    parameter NUM_PES   = `UP(NUM_LANES / `FEXP_PE_RATIO),
    parameter TAG_WIDTH = 1
) (
    input wire clk,
    input wire reset,

    output wire ready_in,
    input wire  valid_in,

    input wire [NUM_LANES-1:0] mask_in,

    input wire [TAG_WIDTH-1:0] tag_in,

    input wire [NUM_LANES-1:0][31:0]  dataa,
    output wire [NUM_LANES-1:0][31:0] result,

    output wire has_fflags,
    output wire [`FP_FLAGS_BITS-1:0] fflags,

    output wire [TAG_WIDTH-1:0] tag_out,

    input wire  ready_out,
    output wire valid_out
);
    localparam DATAW = 32;

    localparam [31:0] F32_ZERO  = 32'h00000000;
    localparam [31:0] F32_ONE   = 32'h3f800000;
    localparam [31:0] F32_HI    = 32'h42b16666; //  88.7f
    localparam [31:0] F32_LO    = 32'hc2ae999a; // -87.3f
    localparam [31:0] F32_LOG2E = 32'h3fb8aa3b;
`ifndef VX_FPU_EXP_LUT
    localparam [31:0] F32_C1    = 32'h3f317218;
    localparam [31:0] F32_C2    = 32'h3e75fdf0;
    localparam [31:0] F32_C3    = 32'h3d635844;
    localparam [31:0] F32_C4    = 32'h3c1d839f;
`endif

`ifdef VX_FPU_EXP_LUT
    localparam FEXP_LUT_BITS = 4;
    localparam FEXP_LUT_ENTRIES = 1 << FEXP_LUT_BITS;
    localparam LATENCY_F32ADD = 12;
`endif

    wire [NUM_LANES-1:0][DATAW-1:0] data_in;

    wire [NUM_LANES-1:0] mask_out;
    wire [NUM_LANES-1:0][(`FP_FLAGS_BITS+32)-1:0] data_out;
    wire [NUM_LANES-1:0][`FP_FLAGS_BITS-1:0] fflags_out;

    wire pe_enable;
    wire [NUM_PES-1:0][DATAW-1:0] pe_data_in;
    wire [NUM_PES-1:0][(`FP_FLAGS_BITS+32)-1:0] pe_data_out;

    assign data_in = dataa;

    VX_pe_serializer #(
        .NUM_LANES      (NUM_LANES),
        .NUM_PES        (NUM_PES),
        .LATENCY        (`LATENCY_FEXP),
        .DATA_IN_WIDTH  (DATAW),
        .DATA_OUT_WIDTH (`FP_FLAGS_BITS + 32),
        .TAG_WIDTH      (NUM_LANES + TAG_WIDTH),
        .PE_REG         (0),
        .OUT_BUF        (2)
    ) pe_serializer (
        .clk         (clk),
        .reset       (reset),
        .valid_in    (valid_in),
        .data_in     (data_in),
        .tag_in      ({mask_in, tag_in}),
        .ready_in    (ready_in),
        .pe_enable   (pe_enable),
        .pe_data_out (pe_data_in),
        .pe_data_in  (pe_data_out),
        .valid_out   (valid_out),
        .data_out    (data_out),
        .tag_out     ({mask_out, tag_out}),
        .ready_out   (ready_out)
    );

    `UNUSED_VAR (pe_data_in)

    for (genvar i = 0; i < NUM_LANES; ++i) begin : g_result
        assign result[i] = data_out[i][0 +: 32];
        assign fflags_out[i] = data_out[i][32 +: `FP_FLAGS_BITS];
    end

    fflags_t [NUM_LANES-1:0] per_lane_fflags;

    function automatic fp32_lt(input [31:0] a, input [31:0] b);
        begin
            if (a[31] != b[31]) begin
                fp32_lt = a[31] && (|a[30:0] || |b[30:0]);
            end else if (a[31]) begin
                fp32_lt = a[30:0] > b[30:0];
            end else begin
                fp32_lt = a[30:0] < b[30:0];
            end
        end
    endfunction

    function automatic [31:0] fp32_clamp(input [31:0] value);
        begin
            if (fp32_lt(value, F32_LO)) begin
                fp32_clamp = F32_LO;
            end else if (fp32_lt(F32_HI, value)) begin
                fp32_clamp = F32_HI;
            end else begin
                fp32_clamp = value;
            end
        end
    endfunction

    function automatic signed [9:0] fp32_floor_to_i(input [31:0] value);
        integer exp_i;
        integer e;
        integer shift;
        integer mag;
        logic [23:0] sig;
        logic has_frac;
        integer floor_i;
        begin
            exp_i = value[30:23];
            e = exp_i - 127;
            sig = {1'b1, value[22:0]};
            mag = 0;
            has_frac = 0;

            if (exp_i == 0 || e < 0) begin
                has_frac = |value[30:0];
            end else if (e >= 23) begin
                mag = sig << (e - 23);
            end else begin
                shift = 23 - e;
                mag = sig >> shift;
                has_frac = |(sig & ((24'h1 << shift) - 1));
            end

            if (value[31]) begin
                floor_i = -(mag + integer'(has_frac));
            end else begin
                floor_i = mag;
            end

            if (floor_i > 127) begin
                floor_i = 127;
            end else if (floor_i < -126) begin
                floor_i = -126;
            end

            fp32_floor_to_i = floor_i[9:0];
        end
    endfunction

    function automatic [31:0] i_to_fp32(input signed [9:0] value);
        integer mag;
        integer msb;
        integer j;
        logic sign;
        logic [7:0] exp;
        logic [22:0] frac;
        begin
            if (value == 0) begin
                i_to_fp32 = F32_ZERO;
            end else begin
                sign = value[9];
                mag = sign ? -integer'(value) : integer'(value);
                msb = 0;
                for (j = 0; j < 8; ++j) begin
                    if (mag[j]) begin
                        msb = j;
                    end
                end
                exp = 8'(127 + msb);
                frac = (mag << (23 - msb)) & 23'h7fffff;
                i_to_fp32 = {sign, exp, frac};
            end
        end
    endfunction

`ifdef VX_FPU_EXP_LUT

    (* ram_style = "registers" *) reg [FEXP_LUT_ENTRIES-1:0][63:0] fexp_lut;

    function automatic [31:0] fexp_lut_base(input [FEXP_LUT_BITS-1:0] idx);
        begin
            case (idx)
                4'h0:    fexp_lut_base = 32'h3f800000; // 1.0f
                4'h1:    fexp_lut_base = 32'h3f85aac3; // 1.04427378f
                4'h2:    fexp_lut_base = 32'h3f8b95c2; // 1.09050773f
                4'h3:    fexp_lut_base = 32'h3f91c3d3; // 1.13878863f
                4'h4:    fexp_lut_base = 32'h3f9837f0; // 1.18920712f
                4'h5:    fexp_lut_base = 32'h3f9ef532; // 1.24185781f
                4'h6:    fexp_lut_base = 32'h3fa5fed7; // 1.29683955f
                4'h7:    fexp_lut_base = 32'h3fad583f; // 1.35425555f
                4'h8:    fexp_lut_base = 32'h3fb504f3; // 1.41421356f
                4'h9:    fexp_lut_base = 32'h3fbd08a4; // 1.47682615f
                4'ha:    fexp_lut_base = 32'h3fc5672a; // 1.54221083f
                4'hb:    fexp_lut_base = 32'h3fce248c; // 1.61049033f
                4'hc:    fexp_lut_base = 32'h3fd744fd; // 1.68179283f
                4'hd:    fexp_lut_base = 32'h3fe0ccdf; // 1.75625216f
                4'he:    fexp_lut_base = 32'h3feac0c7; // 1.83400809f
                default: fexp_lut_base = 32'h3ff5257d; // 1.91520656f
            endcase
        end
    endfunction

    function automatic [31:0] fexp_lut_slope(input [FEXP_LUT_BITS-1:0] idx);
        begin
            case (idx)
                4'h0:    fexp_lut_slope = 32'h3f317218; // 0.693147181f
                4'h1:    fexp_lut_slope = 32'h3f394d47; // 0.723835428f
                4'h2:    fexp_lut_slope = 32'h3f418182; // 0.75588236f
                4'h3:    fexp_lut_slope = 32'h3f4a12b8; // 0.789348131f
                4'h4:    fexp_lut_slope = 32'h3f530509; // 0.824295559f
                4'h5:    fexp_lut_slope = 32'h3f5c5cc0; // 0.860790241f
                4'h6:    fexp_lut_slope = 32'h3f661e5b; // 0.898900681f
                4'h7:    fexp_lut_slope = 32'h3f704e8a; // 0.938698414f
                4'h8:    fexp_lut_slope = 32'h3f7af233; // 0.980258143f
                4'h9:    fexp_lut_slope = 32'h3f830739; // 1.02365788f
                4'ha:    fexp_lut_slope = 32'h3f88d44f; // 1.06897909f
                4'hb:    fexp_lut_slope = 32'h3f8ee324; // 1.11630683f
                4'hc:    fexp_lut_slope = 32'h3f9536a4; // 1.16572996f
                4'hd:    fexp_lut_slope = 32'h3f9bd1d6; // 1.21734123f
                4'he:    fexp_lut_slope = 32'h3fa2b7e9; // 1.27123753f
                default: fexp_lut_slope = 32'h3fa9ec2d; // 1.32752003f
            endcase
        end
    endfunction

    function automatic [31:0] fexp_lut_f0(input [FEXP_LUT_BITS-1:0] idx);
        begin
            case (idx)
                4'h0:    fexp_lut_f0 = 32'h00000000; // 0.0f
                4'h1:    fexp_lut_f0 = 32'h3d800000; // 0.0625f
                4'h2:    fexp_lut_f0 = 32'h3e000000; // 0.125f
                4'h3:    fexp_lut_f0 = 32'h3e400000; // 0.1875f
                4'h4:    fexp_lut_f0 = 32'h3e800000; // 0.25f
                4'h5:    fexp_lut_f0 = 32'h3ea00000; // 0.3125f
                4'h6:    fexp_lut_f0 = 32'h3ec00000; // 0.375f
                4'h7:    fexp_lut_f0 = 32'h3ee00000; // 0.4375f
                4'h8:    fexp_lut_f0 = 32'h3f000000; // 0.5f
                4'h9:    fexp_lut_f0 = 32'h3f100000; // 0.5625f
                4'ha:    fexp_lut_f0 = 32'h3f200000; // 0.625f
                4'hb:    fexp_lut_f0 = 32'h3f300000; // 0.6875f
                4'hc:    fexp_lut_f0 = 32'h3f400000; // 0.75f
                4'hd:    fexp_lut_f0 = 32'h3f500000; // 0.8125f
                4'he:    fexp_lut_f0 = 32'h3f600000; // 0.875f
                default: fexp_lut_f0 = 32'h3f700000; // 0.9375f
            endcase
        end
    endfunction

    function automatic [FEXP_LUT_BITS-1:0] fexp_lut_idx(input [31:0] value);
        integer exp_i;
        integer e;
        integer shift;
        logic [23:0] sig;
        begin
            exp_i = value[30:23];
            e = exp_i - 127;
            sig = {1'b1, value[22:0]};

            if (value[31] || exp_i == 0 || e < -FEXP_LUT_BITS) begin
                fexp_lut_idx = '0;
            end else if (e >= 0) begin
                fexp_lut_idx = {FEXP_LUT_BITS{1'b1}};
            end else begin
                shift = 23 - FEXP_LUT_BITS - e;
                fexp_lut_idx = sig >> shift;
            end
        end
    endfunction

    always @(posedge clk) begin
        for (integer i = 0; i < FEXP_LUT_ENTRIES; ++i) begin
            fexp_lut[i] <= {fexp_lut_base(i[FEXP_LUT_BITS-1:0]), fexp_lut_slope(i[FEXP_LUT_BITS-1:0])};
        end
    end

`endif

`ifdef VIVADO

`ifdef VX_FPU_EXP_LUT

    for (genvar i = 0; i < NUM_PES; ++i) begin : g_fexps
        wire [31:0] x_clamped;
        wire [31:0] t;
        wire signed [9:0] n;
        wire [31:0] n_f;
        wire [31:0] n_f_neg;
        wire [31:0] f;
        wire [FEXP_LUT_BITS-1:0] idx;
        wire [31:0] f0;
        wire [31:0] f0_neg;
        wire [31:0] df;
        wire [31:0] p;
        wire [31:0] p_d;
        wire [31:0] lut_base;
        wire [31:0] lut_slope;
        wire [63:0] lut_entry;
        wire [31:0] lut_base_d;
        wire [31:0] lut_slope_d;
        wire signed [9:0] n_d;
        wire [31:0] exp_adjust;
        wire [31:0] result_s;
        wire [1:0][2:0] tuser;

        assign x_clamped = fp32_clamp(pe_data_in[i]);
        assign n = fp32_floor_to_i(t);
        assign n_f = i_to_fp32(n);
        assign n_f_neg = {~n_f[31], n_f[30:0]};
        assign idx = fexp_lut_idx(f);
        assign f0 = fexp_lut_f0(idx);
        assign f0_neg = {~f0[31], f0[30:0]};
        assign lut_entry = fexp_lut[idx];
        assign {lut_base, lut_slope} = lut_entry;
        assign exp_adjust = ({ {22{n_d[9]}}, n_d } << 23);
        assign result_s = p_d + exp_adjust;

        xil_fma fma_t (
            .aclk                (clk),
            .aclken              (pe_enable),
            .s_axis_a_tvalid     (1'b1),
            .s_axis_a_tdata      (x_clamped),
            .s_axis_b_tvalid     (1'b1),
            .s_axis_b_tdata      (F32_LOG2E),
            .s_axis_c_tvalid     (1'b1),
            .s_axis_c_tdata      (F32_ZERO),
            `UNUSED_PIN (m_axis_result_tvalid),
            .m_axis_result_tdata (t),
            .m_axis_result_tuser (tuser[0])
        );

        xil_f32add fadd_f (
            .aclk                (clk),
            .aresetn             (~reset),
            .aclken              (pe_enable),
            .s_axis_a_tvalid     (1'b1),
            .s_axis_a_tdata      (t),
            `UNUSED_PIN (s_axis_a_tready),
            .s_axis_b_tvalid     (1'b1),
            .s_axis_b_tdata      (n_f_neg),
            `UNUSED_PIN (s_axis_b_tready),
            `UNUSED_PIN (m_axis_result_tvalid),
            .m_axis_result_tready(1'b1),
            .m_axis_result_tdata (f)
        );

        xil_f32add fadd_df (
            .aclk                (clk),
            .aresetn             (~reset),
            .aclken              (pe_enable),
            .s_axis_a_tvalid     (1'b1),
            .s_axis_a_tdata      (f),
            `UNUSED_PIN (s_axis_a_tready),
            .s_axis_b_tvalid     (1'b1),
            .s_axis_b_tdata      (f0_neg),
            `UNUSED_PIN (s_axis_b_tready),
            `UNUSED_PIN (m_axis_result_tvalid),
            .m_axis_result_tready(1'b1),
            .m_axis_result_tdata (df)
        );

        xil_fma fma_p (
            .aclk                (clk),
            .aclken              (pe_enable),
            .s_axis_a_tvalid     (1'b1),
            .s_axis_a_tdata      (lut_slope_d),
            .s_axis_b_tvalid     (1'b1),
            .s_axis_b_tdata      (df),
            .s_axis_c_tvalid     (1'b1),
            .s_axis_c_tdata      (lut_base_d),
            `UNUSED_PIN (m_axis_result_tvalid),
            .m_axis_result_tdata (p),
            .m_axis_result_tuser (tuser[1])
        );

        VX_shift_register #(
            .DATAW  (64),
            .DEPTH  (LATENCY_F32ADD)
        ) lut_delay (
            .clk      (clk),
            `UNUSED_PIN (reset),
            .enable   (pe_enable),
            .data_in  ({lut_base, lut_slope}),
            .data_out ({lut_base_d, lut_slope_d})
        );

        VX_shift_register #(
            .DATAW  (10),
            .DEPTH  (`LATENCY_FEXP - `LATENCY_FMA)
        ) n_delay (
            .clk      (clk),
            `UNUSED_PIN (reset),
            .enable   (pe_enable),
            .data_in  (n),
            .data_out (n_d)
        );

        VX_shift_register #(
            .DATAW  (32),
            .DEPTH  (`LATENCY_FEXP - (2 * `LATENCY_FMA) - (2 * LATENCY_F32ADD))
        ) p_delay (
            .clk      (clk),
            `UNUSED_PIN (reset),
            .enable   (pe_enable),
            .data_in  (p),
            .data_out (p_d)
        );

        assign pe_data_out[i][0 +: 32] = result_s;
        assign pe_data_out[i][32 +: `FP_FLAGS_BITS] = '0;

        `UNUSED_VAR (tuser)
    end

`else

    for (genvar i = 0; i < NUM_PES; ++i) begin : g_fexps
        wire [31:0] x_clamped;
        wire [31:0] t;
        wire signed [9:0] n;
        wire [31:0] n_f;
        wire [31:0] n_f_neg;
        wire [31:0] f;
        wire [31:0] f_d1;
        wire [31:0] f_d2;
        wire [31:0] f_d3;
        wire [31:0] p0;
        wire [31:0] p1;
        wire [31:0] p2;
        wire [31:0] p3;
        wire signed [9:0] n_d;
        wire [31:0] exp_adjust;
        wire [31:0] result_s;
        wire [5:0][2:0] tuser;

        assign x_clamped = fp32_clamp(pe_data_in[i]);
        assign n = fp32_floor_to_i(t);
        assign n_f = i_to_fp32(n);
        assign n_f_neg = {~n_f[31], n_f[30:0]};
        assign exp_adjust = ({ {22{n_d[9]}}, n_d } << 23);
        assign result_s = p3 + exp_adjust;

        xil_fma fma_t (
            .aclk                (clk),
            .aclken              (pe_enable),
            .s_axis_a_tvalid     (1'b1),
            .s_axis_a_tdata      (x_clamped),
            .s_axis_b_tvalid     (1'b1),
            .s_axis_b_tdata      (F32_LOG2E),
            .s_axis_c_tvalid     (1'b1),
            .s_axis_c_tdata      (F32_ZERO),
            `UNUSED_PIN (m_axis_result_tvalid),
            .m_axis_result_tdata (t),
            .m_axis_result_tuser (tuser[0])
        );

        xil_fma fma_f (
            .aclk                (clk),
            .aclken              (pe_enable),
            .s_axis_a_tvalid     (1'b1),
            .s_axis_a_tdata      (t),
            .s_axis_b_tvalid     (1'b1),
            .s_axis_b_tdata      (F32_ONE),
            .s_axis_c_tvalid     (1'b1),
            .s_axis_c_tdata      (n_f_neg),
            `UNUSED_PIN (m_axis_result_tvalid),
            .m_axis_result_tdata (f),
            .m_axis_result_tuser (tuser[1])
        );

        xil_fma fma_p0 (
            .aclk                (clk),
            .aclken              (pe_enable),
            .s_axis_a_tvalid     (1'b1),
            .s_axis_a_tdata      (F32_C4),
            .s_axis_b_tvalid     (1'b1),
            .s_axis_b_tdata      (f),
            .s_axis_c_tvalid     (1'b1),
            .s_axis_c_tdata      (F32_C3),
            `UNUSED_PIN (m_axis_result_tvalid),
            .m_axis_result_tdata (p0),
            .m_axis_result_tuser (tuser[2])
        );

        xil_fma fma_p1 (
            .aclk                (clk),
            .aclken              (pe_enable),
            .s_axis_a_tvalid     (1'b1),
            .s_axis_a_tdata      (p0),
            .s_axis_b_tvalid     (1'b1),
            .s_axis_b_tdata      (f_d1),
            .s_axis_c_tvalid     (1'b1),
            .s_axis_c_tdata      (F32_C2),
            `UNUSED_PIN (m_axis_result_tvalid),
            .m_axis_result_tdata (p1),
            .m_axis_result_tuser (tuser[3])
        );

        xil_fma fma_p2 (
            .aclk                (clk),
            .aclken              (pe_enable),
            .s_axis_a_tvalid     (1'b1),
            .s_axis_a_tdata      (p1),
            .s_axis_b_tvalid     (1'b1),
            .s_axis_b_tdata      (f_d2),
            .s_axis_c_tvalid     (1'b1),
            .s_axis_c_tdata      (F32_C1),
            `UNUSED_PIN (m_axis_result_tvalid),
            .m_axis_result_tdata (p2),
            .m_axis_result_tuser (tuser[4])
        );

        xil_fma fma_p3 (
            .aclk                (clk),
            .aclken              (pe_enable),
            .s_axis_a_tvalid     (1'b1),
            .s_axis_a_tdata      (p2),
            .s_axis_b_tvalid     (1'b1),
            .s_axis_b_tdata      (f_d3),
            .s_axis_c_tvalid     (1'b1),
            .s_axis_c_tdata      (F32_ONE),
            `UNUSED_PIN (m_axis_result_tvalid),
            .m_axis_result_tdata (p3),
            .m_axis_result_tuser (tuser[5])
        );

        VX_shift_register #(
            .DATAW  (32),
            .DEPTH  (`LATENCY_FMA)
        ) f_delay1 (
            .clk      (clk),
            `UNUSED_PIN (reset),
            .enable   (pe_enable),
            .data_in  (f),
            .data_out (f_d1)
        );

        VX_shift_register #(
            .DATAW  (32),
            .DEPTH  (`LATENCY_FMA)
        ) f_delay2 (
            .clk      (clk),
            `UNUSED_PIN (reset),
            .enable   (pe_enable),
            .data_in  (f_d1),
            .data_out (f_d2)
        );

        VX_shift_register #(
            .DATAW  (32),
            .DEPTH  (`LATENCY_FMA)
        ) f_delay3 (
            .clk      (clk),
            `UNUSED_PIN (reset),
            .enable   (pe_enable),
            .data_in  (f_d2),
            .data_out (f_d3)
        );

        VX_shift_register #(
            .DATAW  (10),
            .DEPTH  (5 * `LATENCY_FMA)
        ) n_delay (
            .clk      (clk),
            `UNUSED_PIN (reset),
            .enable   (pe_enable),
            .data_in  (n),
            .data_out (n_d)
        );

        assign pe_data_out[i][0 +: 32] = result_s;
        assign pe_data_out[i][32 +: `FP_FLAGS_BITS] = '0;

        `UNUSED_VAR (tuser)
    end

`endif

    assign has_fflags = 1;
    assign per_lane_fflags = fflags_out;

`else

    for (genvar i = 0; i < NUM_PES; ++i) begin : g_fexps
        reg [63:0] r;
        `UNUSED_VAR (r)
        fflags_t fflags_dpi;

        always @(*) begin
            dpi_fexp (
                pe_enable,
                int'(0),
                {32'hffffffff, pe_data_in[i]}, // a
                r,
                fflags_dpi
            );
        end

        VX_shift_register #(
            .DATAW  (32 + $bits(fflags_t)),
            .DEPTH  (`LATENCY_FEXP)
        ) shift_req_dpi (
            .clk      (clk),
            `UNUSED_PIN (reset),
            .enable   (pe_enable),
            .data_in  ({fflags_dpi, r[31:0]}),
            .data_out (pe_data_out[i])
        );
    end

    assign has_fflags = 1;
    assign per_lane_fflags = fflags_out;

`endif

`FPU_MERGE_FFLAGS(fflags, per_lane_fflags, mask_out, NUM_LANES);

endmodule

`endif
