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
    localparam [31:0] F32_C1    = 32'h3f317218;
    localparam [31:0] F32_C2    = 32'h3e75fdf0;
    localparam [31:0] F32_C3    = 32'h3d635844;
    localparam [31:0] F32_C4    = 32'h3c1d839f;

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

`ifdef VIVADO

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
