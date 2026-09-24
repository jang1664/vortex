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

module VX_fpu_ncp import VX_gpu_pkg::*, VX_fpu_pkg::*; #(
    parameter NUM_LANES = 1,
    parameter NUM_PES   = `UP(NUM_LANES / `FNCP_PE_RATIO),
    parameter TAG_WIDTH = 1
) (
    input wire clk,
    input wire reset,

    output wire ready_in,
    input wire  valid_in,

    input wire [NUM_LANES-1:0] mask_in,

    input wire [TAG_WIDTH-1:0] tag_in,

    input wire [INST_FPU_BITS-1:0] op_type,
    input wire [INST_FMT_BITS-1:0] fmt,
    input wire [INST_FRM_BITS-1:0] frm,

    input wire [NUM_LANES-1:0][31:0]  dataa,
    input wire [NUM_LANES-1:0][31:0]  datab,
    output wire [NUM_LANES-1:0][31:0] result,

    output wire has_fflags,
    output wire [`FP_FLAGS_BITS-1:0] fflags,

    output wire [TAG_WIDTH-1:0] tag_out,

    input wire  ready_out,
    output wire valid_out
);
    localparam DATAW = 2 * 32 + INST_FRM_BITS + INST_FPU_BITS + INST_FMT_BITS;

    wire [NUM_LANES-1:0][DATAW-1:0] data_in;

    wire [NUM_LANES-1:0] mask_out;
    wire [NUM_LANES-1:0][(`FP_FLAGS_BITS+32)-1:0] data_out;
    fflags_t [NUM_LANES-1:0] fflags_out;

    wire pe_enable;
    wire [NUM_PES-1:0][DATAW-1:0] pe_data_in;
    wire [NUM_PES-1:0][(`FP_FLAGS_BITS+32)-1:0] pe_data_out;
    wire pe_issue_h;
    wire pe_issue_s;
    wire pe_enable_h;
    wire pe_enable_s;
    reg [`LATENCY_FNCP-2:0] pe_inflight_h;
    reg [`LATENCY_FNCP-2:0] pe_inflight_s;

    for (genvar i = 0; i < NUM_LANES; ++i) begin : g_data_in
        assign data_in[i][0  +: 32] = dataa[i];
        assign data_in[i][32 +: 32] = datab[i];
        assign data_in[i][64 +: INST_FRM_BITS] = frm;
        assign data_in[i][64 + INST_FRM_BITS +: INST_FPU_BITS] = op_type;
        assign data_in[i][64 + INST_FRM_BITS + INST_FPU_BITS +: INST_FMT_BITS] = fmt;
    end

    VX_pe_serializer #(
        .NUM_LANES  (NUM_LANES),
        .NUM_PES    (NUM_PES),
        .LATENCY    (`LATENCY_FNCP),
        .DATA_IN_WIDTH (DATAW),
        .DATA_OUT_WIDTH (`FP_FLAGS_BITS + 32),
        .TAG_WIDTH  (NUM_LANES + TAG_WIDTH),
        .PE_REG     (0),
        .OUT_BUF    (2)
    ) pe_serializer (
        .clk        (clk),
        .reset      (reset),
        .valid_in   (valid_in),
        .data_in    (data_in),
        .tag_in     ({mask_in, tag_in}),
        .ready_in   (ready_in),
        .pe_enable  (pe_enable),
        .pe_data_out(pe_data_in),
        .pe_data_in (pe_data_out),
        .valid_out  (valid_out),
        .data_out   (data_out),
        .tag_out    ({mask_out, tag_out}),
        .ready_out  (ready_out)
    );

    `UNUSED_VAR (pe_data_in)

    assign pe_issue_h = pe_enable
                     && (pe_data_in[0][64 + INST_FRM_BITS + INST_FPU_BITS +: INST_FMT_BITS] == 2'b10);
    assign pe_issue_s = pe_enable && !pe_issue_h;
    assign pe_enable_h = pe_enable && (pe_issue_h || (|pe_inflight_h));
    assign pe_enable_s = pe_enable && (pe_issue_s || (|pe_inflight_s));

    always @(posedge clk) begin
        if (reset) begin
            pe_inflight_h <= '0;
            pe_inflight_s <= '0;
        end else if (pe_enable) begin
            pe_inflight_h[0] <= pe_issue_h;
            pe_inflight_s[0] <= pe_issue_s;
            for (integer j = 1; j < `LATENCY_FNCP-1; ++j) begin
                pe_inflight_h[j] <= pe_inflight_h[j-1];
                pe_inflight_s[j] <= pe_inflight_s[j-1];
            end
        end
    end

`ifdef SIMULATION
    always @(negedge clk) begin
        if ((reset === 1'b0) && !$isunknown({
            pe_issue_h, pe_issue_s, pe_enable_h, pe_enable_s,
            pe_inflight_h, pe_inflight_s
        })) begin
            assert (!(pe_issue_h && pe_issue_s))
                else $fatal(1, "NCP FP16 and FP32 accepted the same request");
            if (pe_issue_h && !(|pe_inflight_s)) begin
                assert (!pe_enable_s)
                    else $fatal(1, "FP16 NCP request activated idle FP32 unit");
            end
            if (pe_issue_s && !(|pe_inflight_h)) begin
                assert (!pe_enable_h)
                    else $fatal(1, "FP32 NCP request activated idle FP16 unit");
            end
        end
    end
`endif

    for (genvar i = 0; i < NUM_LANES; ++i) begin : g_result
        assign result[i] = data_out[i][0 +: 32];
        assign fflags_out[i] = data_out[i][32 +: `FP_FLAGS_BITS];
    end

    for (genvar i = 0; i < NUM_PES; ++i) begin : g_fncp_units
        wire [31:0] result_s, result_h;
        wire [`FP_FLAGS_BITS-1:0] fflags_s, fflags_h;
        wire fmt_h_out;
        wire is_half_fmv_in;
        wire [31:0] half_dataa;

        assign is_half_fmv_in =
               (pe_data_in[0][64 + INST_FRM_BITS +: INST_FPU_BITS] == INST_FPU_MISC)
            && ((pe_data_in[0][64 +: INST_FRM_BITS] == 3'd4)
             || (pe_data_in[0][64 +: INST_FRM_BITS] == 3'd5));
        assign half_dataa = is_half_fmv_in
                          ? pe_data_in[i][0 +: 32]
                          : ((&pe_data_in[i][31:16])
                            ? pe_data_in[i][0 +: 32]
                            : 32'hffff7e00);

        VX_fncp_unit #(
            .LATENCY (`LATENCY_FNCP),
            .OUT_REG (1)
        ) fncp_unit (
            .clk        (clk),
            .reset      (reset),
            .enable     (pe_enable_s),
            .frm        (pe_data_in[0][64 +: INST_FRM_BITS]),
            .op_type    (pe_data_in[0][64 + INST_FRM_BITS +: INST_FPU_BITS]),
            .dataa      (pe_issue_s ? pe_data_in[i][0 +: 32] : 32'b0),
            .datab      (pe_issue_s ? pe_data_in[i][32 +: 32] : 32'b0),
            .result     (result_s),
            .fflags     (fflags_s)
        );
        VX_fncp_unit #(
            .LATENCY (`LATENCY_FNCP), .EXP_BITS(5), .MAN_BITS(10), .OUT_REG(1)
        ) fncp_unit_h (
            .clk(clk), .reset(reset), .enable(pe_enable_h),
            .frm(pe_data_in[0][64 +: INST_FRM_BITS]),
            .op_type(pe_data_in[0][64 + INST_FRM_BITS +: INST_FPU_BITS]),
            .dataa(pe_issue_h ? half_dataa : 32'b0),
            .datab(pe_issue_h
                ? ((&pe_data_in[i][63:48]) ? pe_data_in[i][32 +: 32] : 32'hffff7e00)
                : 32'b0),
            .result(result_h), .fflags(fflags_h)
        );

    `ifdef SIMULATION
        reg [`LATENCY_FNCP-1:0] fmv_h_x_valid_pipe;
        reg [`LATENCY_FNCP-1:0][31:0] fmv_h_x_expected_pipe;

        initial begin
            fmv_h_x_valid_pipe = '0;
            fmv_h_x_expected_pipe = '0;
        end

        always @(posedge clk) begin
            if (reset === 1'b1) begin
                fmv_h_x_valid_pipe <= '0;
                fmv_h_x_expected_pipe <= '0;
            end else if ((reset === 1'b0) && (pe_enable_h === 1'b1)) begin
                fmv_h_x_valid_pipe <= {
                    fmv_h_x_valid_pipe[`LATENCY_FNCP-2:0],
                    (pe_issue_h === 1'b1)
                 && (is_half_fmv_in === 1'b1)
                 && (pe_data_in[0][64 +: INST_FRM_BITS] === 3'd5)
                };
                fmv_h_x_expected_pipe[0] <= {
                    16'hffff, pe_data_in[i][15:0]
                };
                for (integer j = 1; j < `LATENCY_FNCP; ++j) begin
                    fmv_h_x_expected_pipe[j] <= fmv_h_x_expected_pipe[j-1];
                end
            end
        end

        always @(negedge clk) begin
            if ((reset === 1'b0)
             && (fmv_h_x_valid_pipe[`LATENCY_FNCP-1] === 1'b1)) begin
                assert (result_h == fmv_h_x_expected_pipe[`LATENCY_FNCP-1])
                    else $fatal(1,
                        "FP16 FMV.H.X result mismatch: src=%h expected=%h actual=%h latency=%0d",
                        fmv_h_x_expected_pipe[`LATENCY_FNCP-1][15:0],
                        fmv_h_x_expected_pipe[`LATENCY_FNCP-1],
                        result_h, `LATENCY_FNCP);
            end
        end
    `endif

        VX_shift_register #(.DATAW(1), .DEPTH(`LATENCY_FNCP)) shift_fmt (
            .clk(clk), `UNUSED_PIN(reset), .enable(pe_enable),
            .data_in(pe_data_in[i][64 + INST_FRM_BITS + INST_FPU_BITS +: INST_FMT_BITS] == 2'b10),
            .data_out(fmt_h_out)
        );
        assign pe_data_out[i] = fmt_h_out ? {fflags_h, result_h} : {fflags_s, result_s};
    end

    assign has_fflags = 1;

    `FPU_MERGE_FFLAGS(fflags, fflags_out, mask_out, NUM_LANES);

endmodule

`endif
