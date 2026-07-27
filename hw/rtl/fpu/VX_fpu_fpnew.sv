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

`ifdef FPU_FPNEW

module VX_fpu_fpnew
    import VX_gpu_pkg::*;
    import VX_fpu_pkg::*;
    import fpnew_pkg::*;
    import cf_math_pkg::*;
    import defs_div_sqrt_mvp::*;
#(
    parameter NUM_LANES = 1,
    parameter TAG_WIDTH = 1,
    parameter OUT_BUF   = 0
) (
    input wire clk,
    input wire reset,

    input wire  valid_in,
    output wire ready_in,

    input wire [NUM_LANES-1:0] mask_in,

    input wire [TAG_WIDTH-1:0] tag_in,

    input wire [INST_FPU_BITS-1:0] op_type,
    input wire [INST_FMT_BITS-1:0] fmt,
    input wire [INST_FMT_BITS-1:0] src_fmt,
    input wire is_sub,
    input wire is_int64,
    input wire [INST_FRM_BITS-1:0] frm,

    input wire [NUM_LANES-1:0][`XLEN-1:0]  dataa,
    input wire [NUM_LANES-1:0][`XLEN-1:0]  datab,
    input wire [NUM_LANES-1:0][`XLEN-1:0]  datac,
    output wire [NUM_LANES-1:0][`XLEN-1:0] result,

    output wire has_fflags,
    output wire [`FP_FLAGS_BITS-1:0] fflags,

    output wire [TAG_WIDTH-1:0] tag_out,

    input wire  ready_out,
    output wire valid_out
);
    localparam LATENCY_FDIVSQRT = `MAX(`LATENCY_FDIV, `LATENCY_FSQRT);
    localparam RSP_DATAW = (NUM_LANES * `XLEN) + 1 + $bits(fflags_t) + TAG_WIDTH;

    localparam fpnew_pkg::fpu_features_t FPU_FEATURES = '{
        Width:         unsigned'(`XLEN),
        EnableVectors: 1'b0,
    `ifdef XLEN_64
        EnableNanBox:  1'b1,
    `ifdef EXT_ZFH_ENABLE
    `ifdef EXT_D_ENABLE
        FpFmtMask:     5'b11100,
    `else
        FpFmtMask:     5'b10100,
    `endif
    `elsif EXT_D_ENABLE
        FpFmtMask:     5'b11000,
    `else
        FpFmtMask:     5'b10000,
    `endif
        IntFmtMask:    4'b0011
    `else
        EnableNanBox:  1'b0,
        FpFmtMask:     5'b10000,
        IntFmtMask:    4'b0010
    `endif
    };

    localparam fpnew_pkg::fpu_implementation_t FPU_IMPLEMENTATION = '{
      PipeRegs:'{'{`LATENCY_FMA, 0, 0, 0, 0}, // ADDMUL
                 '{default: unsigned'(LATENCY_FDIVSQRT)}, // DIVSQRT
                 '{default: `LATENCY_FNCP}, // NONCOMP
                 '{default: `LATENCY_FCVT}}, // CONV
      UnitTypes:'{'{default: fpnew_pkg::PARALLEL}, // ADDMUL
                  '{default: fpnew_pkg::MERGED}, // DIVSQRT
                  '{default: fpnew_pkg::PARALLEL}, // NONCOMP
                  '{default: fpnew_pkg::MERGED}}, // CONV
      PipeConfig: fpnew_pkg::DISTRIBUTED
    };

    wire fpu_ready_in, fpu_valid_in;
    wire fpu_ready_out, fpu_valid_out;
    wire exp_ready_in, exp_ready_out, exp_valid_out;

    reg [TAG_WIDTH-1:0] fpu_tag_in, fpu_tag_out;

    logic [2:0][NUM_LANES-1:0][`XLEN-1:0] fpu_operands;

    wire [NUM_LANES-1:0][`XLEN-1:0] fpu_result;
    wire [NUM_LANES-1:0][`XLEN-1:0] exp_result;
    fpnew_pkg::status_t fpu_status;
    wire exp_has_fflags;
    wire [`FP_FLAGS_BITS-1:0] exp_fflags;
    wire [TAG_WIDTH-1:0] exp_tag_out;

    fpnew_pkg::operation_e fpu_op;
    reg [INST_FRM_BITS-1:0] fpu_rnd;
    reg fpu_op_mod;
    reg fpu_has_fflags, fpu_has_fflags_out;
    fpnew_pkg::fp_format_e fpu_src_fmt, fpu_dst_fmt;
    fpnew_pkg::int_format_e fpu_int_fmt;

    function automatic fpnew_pkg::fp_format_e to_fpnew_fmt(
        input logic [INST_FMT_BITS-1:0] inst_fmt
    );
        case (inst_fmt)
            2'b01: to_fpnew_fmt = fpnew_pkg::FP64;
            2'b10: to_fpnew_fmt = fpnew_pkg::FP16;
            default: to_fpnew_fmt = fpnew_pkg::FP32;
        endcase
    endfunction

    always @(*) begin
        fpu_op          = fpnew_pkg::operation_e'('0);
        fpu_rnd         = frm;
        fpu_op_mod      = 0;
        fpu_has_fflags  = 1;
        fpu_operands[0] = dataa;
        fpu_operands[1] = datab;
        fpu_operands[2] = datac;
        fpu_dst_fmt     = to_fpnew_fmt(fmt);
        fpu_int_fmt     = fpnew_pkg::INT32;

    `ifdef XLEN_64
        if (is_int64) begin
            fpu_int_fmt = fpnew_pkg::INT64;
        end
    `endif

        fpu_src_fmt = to_fpnew_fmt(src_fmt);

        case (op_type)
            INST_FPU_ADD: begin
                fpu_op = fpnew_pkg::ADD;
                fpu_operands[1] = dataa;
                fpu_operands[2] = datab;
                fpu_op_mod = is_sub;
            end
            INST_FPU_MUL:   begin fpu_op = fpnew_pkg::MUL; end
            INST_FPU_MADD:  begin fpu_op = fpnew_pkg::FMADD; fpu_op_mod = is_sub; end
            INST_FPU_NMADD: begin fpu_op = fpnew_pkg::FNMSUB; fpu_op_mod = ~is_sub; end
            INST_FPU_DIV:   begin fpu_op = fpnew_pkg::DIV; end
            INST_FPU_SQRT:  begin fpu_op = fpnew_pkg::SQRT; end
            INST_FPU_F2F: begin fpu_op = fpnew_pkg::F2F; end
            INST_FPU_F2I,
            INST_FPU_F2U: begin fpu_op = fpnew_pkg::F2I; fpu_op_mod = op_type[0]; end
            INST_FPU_I2F,
            INST_FPU_U2F: begin fpu_op = fpnew_pkg::I2F; fpu_op_mod = op_type[0]; end
            INST_FPU_CMP: begin fpu_op = fpnew_pkg::CMP; end
            INST_FPU_MISC:begin
                case (frm)
                    0,1,2: begin fpu_op = fpnew_pkg::SGNJ; fpu_rnd = {1'b0, frm[1:0]}; fpu_has_fflags = 0; end // FSGNJ
                    3:     begin fpu_op = fpnew_pkg::CLASSIFY; fpu_has_fflags = 0; end // CLASS
                    4,5:   begin fpu_op = fpnew_pkg::SGNJ; fpu_rnd = 3'b011; fpu_op_mod = ~frm[0]; fpu_has_fflags = 0; end // FMV.X.W, FMV.W.X
                    6,7:   begin fpu_op = fpnew_pkg::MINMAX; fpu_rnd = {2'b00, frm[0]}; end // MIN, MAX
                endcase
            end
            default:;
        endcase
    end

    wire is_exp_op = (op_type == INST_FPU_EXP);

    for (genvar i = 0; i < NUM_LANES; ++i) begin : g_fpnew_coreses
        wire [(TAG_WIDTH+1)-1:0] fpu_tag;
        wire fpu_valid_out_uq;
        wire fpu_ready_in_uq;
        fpnew_pkg::status_t fpu_status_uq;
        `UNUSED_VAR (fpu_tag)
        `UNUSED_VAR (fpu_valid_out_uq)
        `UNUSED_VAR (fpu_ready_in_uq)
        `UNUSED_VAR (fpu_status_uq)

        fpnew_top #(
            .Features       (FPU_FEATURES),
            .Implementation (FPU_IMPLEMENTATION),
            .TagType        (logic[(TAG_WIDTH+1)-1:0]),
            .DivSqrtSel     (fpnew_pkg::PULP)
        ) fpnew_core (
            .clk_i          (clk),
            .rst_ni         (~reset),
            .operands_i     ({fpu_operands[2][i], fpu_operands[1][i], fpu_operands[0][i]}),
            .rnd_mode_i     (fpnew_pkg::roundmode_e'(fpu_rnd)),
            .op_i           (fpu_op),
            .op_mod_i       (fpu_op_mod),
            .src_fmt_i      (fpu_src_fmt),
            .dst_fmt_i      (fpu_dst_fmt),
            .int_fmt_i      (fpu_int_fmt),
            .vectorial_op_i (1'b0),
            .simd_mask_i    (1'b1),
            .tag_i          ({fpu_tag_in, fpu_has_fflags}),
            .in_valid_i     (fpu_valid_in),
            .in_ready_o     (fpu_ready_in_uq),
            .flush_i        (1'b0),
            .result_o       (fpu_result[i]),
            .status_o       (fpu_status_uq),
            .tag_o          (fpu_tag),
            .out_valid_o    (fpu_valid_out_uq),
            .out_ready_i    (fpu_ready_out),
            `UNUSED_PIN (busy_o)
        );

        if (i == 0) begin : g_output_0
            assign {fpu_tag_out, fpu_has_fflags_out} = fpu_tag;
            assign fpu_valid_out = fpu_valid_out_uq;
            assign fpu_ready_in = fpu_ready_in_uq;
            assign fpu_status = fpu_status_uq;
        end
    end

    assign fpu_valid_in = valid_in && ~is_exp_op;
    assign ready_in = is_exp_op ? exp_ready_in : fpu_ready_in;
    assign fpu_tag_in = tag_in;

`ifdef VX_ENABLE_HW_EXPF
    VX_fpu_exp_fpnew #(
        .NUM_LANES (NUM_LANES),
        .TAG_WIDTH (TAG_WIDTH)
    ) fpu_exp (
        .clk        (clk),
        .reset      (reset),
        .valid_in   (valid_in && is_exp_op),
        .ready_in   (exp_ready_in),
        .mask_in    (mask_in),
        .tag_in     (tag_in),
        .dataa      (dataa),
        .result     (exp_result),
        .has_fflags (exp_has_fflags),
        .fflags     (exp_fflags),
        .tag_out    (exp_tag_out),
        .ready_out  (exp_ready_out),
        .valid_out  (exp_valid_out)
    );
`else
    VX_elastic_buffer #(
        .DATAW (RSP_DATAW),
        .SIZE  (1)
    ) fpu_exp_disabled (
        .clk       (clk),
        .reset     (reset),
        .valid_in  (valid_in && is_exp_op),
        .ready_in  (exp_ready_in),
        .data_in   ({ {NUM_LANES{`XLEN'(0)}}, 1'b1, `FP_FLAGS_BITS'(0), tag_in }),
        .data_out  ({ exp_result, exp_has_fflags, exp_fflags, exp_tag_out }),
        .valid_out (exp_valid_out),
        .ready_out (exp_ready_out)
    );

    `UNUSED_VAR (mask_in)
    `UNUSED_VAR (dataa)
`endif

    localparam RSP_ARB_DATAW = RSP_DATAW;
    wire [1:0] rsp_valid_in;
    wire [1:0] rsp_ready_in;
    wire [1:0][RSP_ARB_DATAW-1:0] rsp_data_in;
    wire rsp_valid_out;
    wire rsp_ready_out;
    wire [RSP_ARB_DATAW-1:0] rsp_data_out;

    assign rsp_valid_in = {exp_valid_out, fpu_valid_out};
    assign fpu_ready_out = rsp_ready_in[0];
    assign exp_ready_out = rsp_ready_in[1];
    assign rsp_data_in[0] = {fpu_result, fpu_has_fflags_out, fpu_status, fpu_tag_out};
    assign rsp_data_in[1] = {exp_result, exp_has_fflags, exp_fflags, exp_tag_out};

    VX_stream_arb #(
        .NUM_INPUTS (2),
        .DATAW      (RSP_ARB_DATAW),
        .ARBITER    ("R"),
        .OUT_BUF    (0)
    ) rsp_arb (
        .clk       (clk),
        .reset     (reset),
        .valid_in  (rsp_valid_in),
        .ready_in  (rsp_ready_in),
        .data_in   (rsp_data_in),
        .data_out  (rsp_data_out),
        .valid_out (rsp_valid_out),
        .ready_out (rsp_ready_out),
        `UNUSED_PIN (sel_out)
    );

    VX_elastic_buffer #(
        .DATAW   (RSP_DATAW),
        .SIZE    (`TO_OUT_BUF_SIZE(OUT_BUF)),
        .OUT_REG (`TO_OUT_BUF_REG(OUT_BUF))
    ) rsp_buf (
        .clk       (clk),
        .reset     (reset),
        .valid_in  (rsp_valid_out),
        .ready_in  (rsp_ready_out),
        .data_in   (rsp_data_out),
        .data_out  ({result, has_fflags, fflags, tag_out}),
        .valid_out (valid_out),
        .ready_out (ready_out)
    );

endmodule

`endif
