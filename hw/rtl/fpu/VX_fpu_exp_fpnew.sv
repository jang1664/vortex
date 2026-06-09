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

module VX_fpu_exp_fpnew
    import VX_gpu_pkg::*;
    import VX_fpu_pkg::*;
    import fpnew_pkg::*;
    import cf_math_pkg::*;
    import defs_div_sqrt_mvp::*;
#(
    parameter NUM_LANES = 1,
    parameter NUM_PES   = NUM_LANES,
    parameter TAG_WIDTH = 1
) (
    input wire clk,
    input wire reset,

    input wire  valid_in,
    output wire ready_in,

    input wire [NUM_LANES-1:0] mask_in,

    input wire [TAG_WIDTH-1:0] tag_in,

    input wire [NUM_LANES-1:0][`XLEN-1:0] dataa,
    output wire [NUM_LANES-1:0][`XLEN-1:0] result,

    output wire has_fflags,
    output wire [`FP_FLAGS_BITS-1:0] fflags,

    output wire [TAG_WIDTH-1:0] tag_out,

    input wire  ready_out,
    output wire valid_out
);
    `UNUSED_PARAM (NUM_PES)

    localparam NUM_STAGES = 8;
    localparam STAGE_MUL_LOG2E = 0;
    localparam STAGE_F2I_FLOOR = 1;
    localparam STAGE_I2F_N     = 2;
    localparam STAGE_SUB_F     = 3;
    localparam STAGE_POLY_0    = 4;
    localparam STAGE_POLY_1    = 5;
    localparam STAGE_POLY_2    = 6;
    localparam STAGE_POLY_3    = 7;

    localparam fpnew_pkg::fpu_features_t FPU_FEATURES = '{
        Width:         unsigned'(`XLEN),
        EnableVectors: 1'b0,
    `ifdef XLEN_64
        EnableNanBox:  1'b1,
        FpFmtMask:     5'b11000,
        IntFmtMask:    4'b0011
    `else
        EnableNanBox:  1'b0,
        FpFmtMask:     5'b10000,
        IntFmtMask:    4'b0010
    `endif
    };

    localparam fpnew_pkg::fpu_implementation_t FPU_IMPLEMENTATION = '{
      PipeRegs:'{'{`LATENCY_FMA, 0, 0, 0, 0},
                 '{default: unsigned'(`MAX(`LATENCY_FDIV, `LATENCY_FSQRT))},
                 '{default: `LATENCY_FNCP},
                 '{default: `LATENCY_FCVT}},
      UnitTypes:'{'{default: fpnew_pkg::PARALLEL},
                  '{default: fpnew_pkg::MERGED},
                  '{default: fpnew_pkg::PARALLEL},
                  '{default: fpnew_pkg::MERGED}},
      PipeConfig: fpnew_pkg::DISTRIBUTED
    };

    localparam [31:0] F32_CLAMP_HI = 32'h42b16666; // 88.7f
    localparam [31:0] F32_CLAMP_LO = 32'hc2ae999a; // -87.3f
    localparam [31:0] F32_LOG2E    = 32'h3fb8aa3b;
    localparam [31:0] F32_C4       = 32'h3c1d839f;
    localparam [31:0] F32_C3       = 32'h3d635844;
    localparam [31:0] F32_C2       = 32'h3e75fdf0;
    localparam [31:0] F32_C1       = 32'h3f317218;
    localparam [31:0] F32_ONE      = 32'h3f800000;

    typedef struct packed {
        logic [TAG_WIDTH-1:0] tag;
        logic [NUM_LANES-1:0] mask;
        fflags_t              fflags;
        logic [31:0]          n;
        logic [`XLEN-1:0]     t;
        logic [`XLEN-1:0]     n_float;
        logic [`XLEN-1:0]     f;
    } exp_tag_t;

    function automatic logic [`XLEN-1:0] nan_box32(input logic [31:0] value);
    `ifdef XLEN_64
        return {32'hffffffff, value};
    `else
        return value;
    `endif
    endfunction

    function automatic logic [`XLEN-1:0] sext32(input logic [31:0] value);
    `ifdef XLEN_64
        return {{32{value[31]}}, value};
    `else
        return value;
    `endif
    endfunction

    function automatic logic fp32_lt(input logic [31:0] a, input logic [31:0] b);
        if (a[31] != b[31])
            return a[31];
        if (a[31])
            return a[30:0] > b[30:0];
        return a[30:0] < b[30:0];
    endfunction

    function automatic logic [31:0] clamp_exp_arg(input logic [31:0] value);
        logic is_nan;
        begin
            is_nan = (&value[30:23]) && (|value[22:0]);
            if (is_nan) begin
                return F32_CLAMP_HI;
            end else if (fp32_lt(F32_CLAMP_HI, value)) begin
                return F32_CLAMP_HI;
            end else if (fp32_lt(value, F32_CLAMP_LO)) begin
                return F32_CLAMP_LO;
            end
            return value;
        end
    endfunction

    function automatic exp_tag_t merge_status(
        input exp_tag_t tag,
        input fpnew_pkg::status_t status,
        input logic active
    );
        exp_tag_t merged;
        begin
            merged = tag;
            if (active) begin
                merged.fflags.NV |= status.NV;
                merged.fflags.DZ |= status.DZ;
                merged.fflags.OF |= status.OF;
                merged.fflags.UF |= status.UF;
                merged.fflags.NX |= status.NX;
            end
            return merged;
        end
    endfunction

    function automatic fpnew_pkg::operation_e stage_op(input int stage);
        case (stage)
            STAGE_MUL_LOG2E: return fpnew_pkg::MUL;
            STAGE_F2I_FLOOR: return fpnew_pkg::F2I;
            STAGE_I2F_N:     return fpnew_pkg::I2F;
            STAGE_SUB_F:     return fpnew_pkg::ADD;
            default:         return fpnew_pkg::FMADD;
        endcase
    endfunction

    function automatic fpnew_pkg::roundmode_e stage_rnd(input int stage);
        if (stage == STAGE_F2I_FLOOR)
            return fpnew_pkg::RDN;
        return fpnew_pkg::RNE;
    endfunction

    function automatic logic stage_op_mod(input int stage);
        return (stage == STAGE_SUB_F);
    endfunction

    logic [NUM_STAGES-1:0] stage_valid_in;
    logic [NUM_STAGES-1:0] stage_valid_out;
    logic [NUM_STAGES-1:0] stage_ready_out;
    logic [NUM_STAGES-1:0] stage_ready_in;

    logic [NUM_STAGES-1:0][NUM_LANES-1:0] lane_valid_out;
    logic [NUM_STAGES-1:0][NUM_LANES-1:0] lane_ready_in;
    logic [NUM_STAGES-1:0][NUM_LANES-1:0][`XLEN-1:0] stage_result;
    fpnew_pkg::status_t [NUM_STAGES-1:0][NUM_LANES-1:0] stage_status;
    exp_tag_t [NUM_STAGES-1:0][NUM_LANES-1:0] stage_tag_in;
    exp_tag_t [NUM_STAGES-1:0][NUM_LANES-1:0] stage_tag_out;
    logic [NUM_STAGES-1:0][NUM_LANES-1:0][2:0][`XLEN-1:0] stage_operands;

    for (genvar s = 0; s < NUM_STAGES; ++s) begin : g_stage_flow
        assign stage_valid_out[s] = &lane_valid_out[s];
        assign stage_ready_in[s]  = &lane_ready_in[s];

        if (s == 0) begin : g_first_stage
            assign stage_valid_in[s] = valid_in;
        end else begin : g_next_stage
            assign stage_valid_in[s] = stage_valid_out[s-1];
        end

        if (s == (NUM_STAGES-1)) begin : g_last_stage
            assign stage_ready_out[s] = ready_out;
        end else begin : g_pipe_stage
            assign stage_ready_out[s] = stage_ready_in[s+1];
        end
    end

    assign ready_in  = stage_ready_in[0];
    assign valid_out = stage_valid_out[NUM_STAGES-1];

    for (genvar s = 0; s < NUM_STAGES; ++s) begin : g_stages
        for (genvar i = 0; i < NUM_LANES; ++i) begin : g_lanes
            logic core_tag_out_unused;
            `UNUSED_VAR (core_tag_out_unused)

            if (s == STAGE_MUL_LOG2E) begin : g_input_stage
                always @(*) begin
                    stage_tag_in[s][i] = '0;
                    stage_operands[s][i] = '0;
                    stage_tag_in[s][i].tag = tag_in;
                    stage_tag_in[s][i].mask = mask_in;
                    stage_operands[s][i][0] = nan_box32(clamp_exp_arg(dataa[i][31:0]));
                    stage_operands[s][i][1] = nan_box32(F32_LOG2E);
                end
            end else begin : g_chained_stage
                always @(*) begin
                    stage_tag_in[s][i] = merge_status(
                        stage_tag_out[s-1][i],
                        stage_status[s-1][i],
                        stage_tag_out[s-1][i].mask[i]
                    );
                    stage_operands[s][i] = '0;

                    case (s)
                        STAGE_F2I_FLOOR: begin
                            stage_tag_in[s][i].t = stage_result[s-1][i];
                            stage_operands[s][i][0] = stage_result[s-1][i];
                        end
                        STAGE_I2F_N: begin
                            stage_tag_in[s][i].n = stage_result[s-1][i][31:0];
                            stage_operands[s][i][0] = sext32(stage_result[s-1][i][31:0]);
                        end
                        STAGE_SUB_F: begin
                            stage_tag_in[s][i].n_float = stage_result[s-1][i];
                            stage_operands[s][i][1] = stage_tag_in[s][i].t;
                            stage_operands[s][i][2] = stage_result[s-1][i];
                        end
                        STAGE_POLY_0: begin
                            stage_tag_in[s][i].f = stage_result[s-1][i];
                            stage_operands[s][i][0] = stage_result[s-1][i];
                            stage_operands[s][i][1] = nan_box32(F32_C4);
                            stage_operands[s][i][2] = nan_box32(F32_C3);
                        end
                        STAGE_POLY_1: begin
                            stage_operands[s][i][0] = stage_result[s-1][i];
                            stage_operands[s][i][1] = stage_tag_in[s][i].f;
                            stage_operands[s][i][2] = nan_box32(F32_C2);
                        end
                        STAGE_POLY_2: begin
                            stage_operands[s][i][0] = stage_result[s-1][i];
                            stage_operands[s][i][1] = stage_tag_in[s][i].f;
                            stage_operands[s][i][2] = nan_box32(F32_C1);
                        end
                        default: begin
                            stage_operands[s][i][0] = stage_result[s-1][i];
                            stage_operands[s][i][1] = stage_tag_in[s][i].f;
                            stage_operands[s][i][2] = nan_box32(F32_ONE);
                        end
                    endcase
                end
            end

            fpnew_top #(
                .Features       (FPU_FEATURES),
                .Implementation (FPU_IMPLEMENTATION),
                .TagType        (exp_tag_t),
                .DivSqrtSel     (fpnew_pkg::PULP)
            ) fpnew_core (
                .clk_i          (clk),
                .rst_ni         (~reset),
                .operands_i     (stage_operands[s][i]),
                .rnd_mode_i     (stage_rnd(s)),
                .op_i           (stage_op(s)),
                .op_mod_i       (stage_op_mod(s)),
                .src_fmt_i      (fpnew_pkg::FP32),
                .dst_fmt_i      (fpnew_pkg::FP32),
                .int_fmt_i      (fpnew_pkg::INT32),
                .vectorial_op_i (1'b0),
                .simd_mask_i    (1'b1),
                .tag_i          (stage_tag_in[s][i]),
                .in_valid_i     (stage_valid_in[s]),
                .in_ready_o     (lane_ready_in[s][i]),
                .flush_i        (1'b0),
                .result_o       (stage_result[s][i]),
                .status_o       (stage_status[s][i]),
                .tag_o          (stage_tag_out[s][i]),
                .out_valid_o    (lane_valid_out[s][i]),
                .out_ready_i    (stage_ready_out[s]),
                `UNUSED_PIN (busy_o)
            );
        end
    end

    exp_tag_t [NUM_LANES-1:0] final_tag;
    fflags_t fflags_accum;

    for (genvar i = 0; i < NUM_LANES; ++i) begin : g_result
        wire [31:0] result_s;
        assign final_tag[i] = merge_status(
            stage_tag_out[NUM_STAGES-1][i],
            stage_status[NUM_STAGES-1][i],
            stage_tag_out[NUM_STAGES-1][i].mask[i]
        );
        assign result_s = stage_result[NUM_STAGES-1][i][31:0] + (final_tag[i].n << 23);
        assign result[i] = nan_box32(result_s);
    end

    always @(*) begin
        fflags_accum = '0;
        for (integer i = 0; i < NUM_LANES; ++i) begin
            if (final_tag[i].mask[i]) begin
                fflags_accum |= final_tag[i].fflags;
            end
        end
    end

    assign has_fflags = 1'b1;
    assign fflags = fflags_accum;
    assign tag_out = final_tag[0].tag;

endmodule

`endif
