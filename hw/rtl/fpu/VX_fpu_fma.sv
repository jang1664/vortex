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

module VX_fpu_fma import VX_gpu_pkg::*, VX_fpu_pkg::*; #(
    parameter NUM_LANES = 1,
    parameter NUM_PES   = `UP(NUM_LANES / `FMA_PE_RATIO),
    parameter TAG_WIDTH = 1
) (
    input wire clk,
    input wire reset,

    output wire ready_in,
    input wire  valid_in,

    input wire [NUM_LANES-1:0] mask_in,

    input wire [TAG_WIDTH-1:0] tag_in,

    input wire [INST_FRM_BITS-1:0] frm,
    input wire [INST_FMT_BITS-1:0] fmt,

    input wire  is_madd,
    input wire  is_sub,
    input wire  is_neg,

    input wire [NUM_LANES-1:0][31:0]  dataa,
    input wire [NUM_LANES-1:0][31:0]  datab,
    input wire [NUM_LANES-1:0][31:0]  datac,
    output wire [NUM_LANES-1:0][31:0] result,

    output wire has_fflags,
    output wire [`FP_FLAGS_BITS-1:0] fflags,

    output wire [TAG_WIDTH-1:0] tag_out,

    input wire  ready_out,
    output wire valid_out
);
    localparam DATAW = 3 * 32 + INST_FRM_BITS + INST_FMT_BITS;
    localparam [INST_FMT_BITS-1:0] FMT_S = 2'b00;
    localparam [INST_FMT_BITS-1:0] FMT_H = 2'b10;

    wire [NUM_LANES-1:0][DATAW-1:0] data_in;

    wire [NUM_LANES-1:0] mask_out;
    wire [NUM_LANES-1:0][(`FP_FLAGS_BITS+32)-1:0] data_out;
    wire [NUM_LANES-1:0][`FP_FLAGS_BITS-1:0] fflags_out;

    wire pe_enable;
    wire [NUM_PES-1:0][DATAW-1:0] pe_data_in;
    wire [NUM_PES-1:0][(`FP_FLAGS_BITS+32)-1:0] pe_data_out;
    wire pe_issue_h;
    wire pe_issue_s;
    wire pe_enable_h;
    wire pe_enable_s;
    wire [INST_FMT_BITS-1:0] pe_fmt;
    reg [`LATENCY_FMA-2:0] pe_inflight_h;
    reg [`LATENCY_FMA-2:0] pe_inflight_s;

    reg [NUM_LANES-1:0][31:0] a, b, c;

    function automatic [15:0] unbox_half(input [31:0] value);
        unbox_half = (&value[31:16]) ? value[15:0] : 16'h7e00;
    endfunction

    wire [NUM_LANES-1:0][15:0] dataa_h, datab_h, datac_h;
    for (genvar i = 0; i < NUM_LANES; ++i) begin : g_unbox_half
        assign dataa_h[i] = unbox_half(dataa[i]);
        assign datab_h[i] = unbox_half(datab[i]);
        assign datac_h[i] = unbox_half(datac[i]);
    end

    for (genvar i = 0; i < NUM_LANES; ++i) begin : g_select
        always @(*) begin
            if (fmt == 2'b10) begin
                if (is_madd) begin
                    a[i] = {16'hffff, is_neg ^ dataa_h[i][15], dataa_h[i][14:0]};
                    b[i] = {16'hffff, datab_h[i]};
                    c[i] = {16'hffff, is_neg ^ is_sub ^ datac_h[i][15], datac_h[i][14:0]};
                end else if (is_neg) begin
                    a[i] = {16'hffff, dataa_h[i]};
                    b[i] = {16'hffff, datab_h[i]};
                    // Match the addend zero sign to the product.  Using +0
                    // would turn (-0 * +x) + +0 into +0 under RNE.
                    c[i] = {16'hffff, dataa_h[i][15] ^ datab_h[i][15], 15'b0};
                end else begin
                    a[i] = {16'hffff, dataa_h[i]};
                    b[i] = 32'hffff3c00;
                    c[i] = {16'hffff, is_sub ^ datab_h[i][15], datab_h[i][14:0]};
                end
            end else if (is_madd) begin
                // MADD / MSUB / NMADD / NMSUB
                a[i] = {is_neg ^ dataa[i][31], dataa[i][30:0]};
                b[i] = datab[i];
                c[i] = {is_neg ^ is_sub ^ datac[i][31], datac[i][30:0]};
            end else begin
                if (is_neg) begin
                    // MUL
                    a[i] = dataa[i];
                    b[i] = datab[i];
                    // Preserve the IEEE-754 signed-zero result when multiply
                    // is implemented through the FMA datapath.
                    c[i] = {dataa[i][31] ^ datab[i][31], 31'b0};
                end else begin
                    // ADD / SUB
                    a[i] = dataa[i];
                    b[i] = 32'h3f800000; // 1.0f
                    c[i] = {is_sub ^ datab[i][31], datab[i][30:0]};
                end
            end
        end
    end

    for (genvar i = 0; i < NUM_LANES; ++i) begin : g_data_in
        assign data_in[i][0  +: 32] = a[i];
        assign data_in[i][32 +: 32] = b[i];
        assign data_in[i][64 +: 32] = c[i];
        assign data_in[i][96 +: INST_FRM_BITS] = frm;
        assign data_in[i][96 + INST_FRM_BITS +: INST_FMT_BITS] = fmt;
    end

    VX_pe_serializer #(
        .NUM_LANES  (NUM_LANES),
        .NUM_PES    (NUM_PES),
        .LATENCY    (`LATENCY_FMA),
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

    assign pe_fmt = pe_data_in[0][96 + INST_FRM_BITS +: INST_FMT_BITS];
    assign pe_issue_h = pe_enable && valid_in && (pe_fmt == FMT_H);
    assign pe_issue_s = pe_enable && valid_in && (pe_fmt == FMT_S);
    assign pe_enable_h = pe_enable && (pe_issue_h || (|pe_inflight_h));
    assign pe_enable_s = pe_enable && (pe_issue_s || (|pe_inflight_s));

    always @(posedge clk) begin
        if (reset) begin
            pe_inflight_h <= '0;
            pe_inflight_s <= '0;
        end else if (pe_enable) begin
            pe_inflight_h[0] <= pe_issue_h;
            pe_inflight_s[0] <= pe_issue_s;
            for (integer j = 1; j < `LATENCY_FMA-1; ++j) begin
                pe_inflight_h[j] <= pe_inflight_h[j-1];
                pe_inflight_s[j] <= pe_inflight_s[j-1];
            end
        end
    end

`ifdef SIMULATION
    always @(negedge clk) begin
        if (!reset && !$isunknown({
            pe_issue_h, pe_issue_s, pe_enable_h, pe_enable_s,
            pe_inflight_h, pe_inflight_s
        })) begin
            assert (!(pe_issue_h && pe_issue_s))
                else $fatal(1, "FMA FP16 and FP32 accepted the same request");
            if (pe_issue_h && !(|pe_inflight_s)) begin
                assert (!pe_enable_s)
                    else $fatal(1, "FP16 FMA request activated idle FP32 unit");
            end
            if (pe_issue_s && !(|pe_inflight_h)) begin
                assert (!pe_enable_h)
                    else $fatal(1, "FP32 FMA request activated idle FP16 unit");
            end
        end
    end
`endif

    for (genvar i = 0; i < NUM_LANES; ++i) begin : g_result
        assign result[i] = data_out[i][0 +: 32];
        assign fflags_out[i] = data_out[i][32 +: `FP_FLAGS_BITS];
    end

    fflags_t [NUM_LANES-1:0] per_lane_fflags;

`ifdef QUARTUS

    for (genvar i = 0; i < NUM_PES; ++i) begin : g_fmas
        acl_fmadd fmadd (
            .clk (clk),
            .areset (1'b0),
            .en (pe_enable_s),
            .a  (pe_issue_s ? pe_data_in[i][0 +: 32] : 32'b0),
            .b  (pe_issue_s ? pe_data_in[i][32 +: 32] : 32'b0),
            .c  (pe_issue_s ? pe_data_in[i][64 +: 32] : 32'b0),
            .q  (pe_data_out[i][0 +: 32])
        );
        assign pe_data_out[i][32 +: `FP_FLAGS_BITS] = '0;
    end

    assign has_fflags = 0;
    assign per_lane_fflags = '0;

`elsif VIVADO

    for (genvar i = 0; i < NUM_PES; ++i) begin : g_fmas
        wire [2:0] tuser_s, tuser_h;
        wire [31:0] result_s;
        wire [15:0] result_h;
        wire fmt_h_out;
        wire result_valid_h;

        xil_fma_lowL fma (
            .aclk                (clk),
            .aclken              (pe_enable_s),
            .s_axis_a_tvalid     (pe_issue_s),
            .s_axis_a_tdata      (pe_issue_s ? pe_data_in[i][0 +: 32] : 32'b0),
            .s_axis_b_tvalid     (pe_issue_s),
            .s_axis_b_tdata      (pe_issue_s ? pe_data_in[i][32 +: 32] : 32'b0),
            .s_axis_c_tvalid     (pe_issue_s),
            .s_axis_c_tdata      (pe_issue_s ? pe_data_in[i][64 +: 32] : 32'b0),
            `UNUSED_PIN (m_axis_result_tvalid),
            .m_axis_result_tdata (result_s),
            .m_axis_result_tuser (tuser_s)
        );

    `ifdef EXT_ZFH_ENABLE
        xil_f16_fma fma_h (
            .aclk                (clk),
            .aclken              (pe_enable_h),
            .s_axis_a_tvalid     (pe_issue_h),
            .s_axis_a_tdata      (pe_issue_h ? pe_data_in[i][0 +: 16] : 16'b0),
            .s_axis_b_tvalid     (pe_issue_h),
            .s_axis_b_tdata      (pe_issue_h ? pe_data_in[i][32 +: 16] : 16'b0),
            .s_axis_c_tvalid     (pe_issue_h),
            .s_axis_c_tdata      (pe_issue_h ? pe_data_in[i][64 +: 16] : 16'b0),
            .m_axis_result_tvalid(result_valid_h),
            .m_axis_result_tdata (result_h),
            .m_axis_result_tuser (tuser_h)
        );

    `ifdef SIMULATION
        reg [`LATENCY_FMA-1:0] expected_valid_pipe_h;
        wire expected_valid_h = expected_valid_pipe_h[`LATENCY_FMA-1];

        // The Xilinx IP has no reset port. Start this reference at time zero
        // and count enabled cycles even while the surrounding core is reset.
        initial expected_valid_pipe_h = '0;
        always @(posedge clk) begin
            if (pe_enable_h) begin
                expected_valid_pipe_h <= {
                    expected_valid_pipe_h[`LATENCY_FMA-2:0], pe_issue_h
                };
            end
        end

        // The serializer consumes the FP16 FMA output after LATENCY_FMA
        // enabled cycles. Check the generated Xilinx IP follows that exact
        // contract instead of silently trusting its configured latency.
        always @(negedge clk) begin
            if (!$isunknown(result_valid_h)) begin
                assert (result_valid_h == expected_valid_h)
                    else $fatal(1,
                        "FP16 FMA latency mismatch: expected_valid=%b, ip_valid=%b, latency=%0d",
                        expected_valid_h, result_valid_h, `LATENCY_FMA);
            end
        end
    `endif
    `else
        assign result_h = '0;
        assign tuser_h = '0;
        assign result_valid_h = '0;
    `endif

        VX_shift_register #(
            .DATAW (1),
            .DEPTH (`LATENCY_FMA)
        ) shift_fmt (
            .clk      (clk),
            `UNUSED_PIN (reset),
            .enable   (pe_enable),
            .data_in  (pe_data_in[i][96 + INST_FRM_BITS +: INST_FMT_BITS] == 2'b10),
            .data_out (fmt_h_out)
        );

        assign pe_data_out[i][0 +: 32] = fmt_h_out ? {16'hffff, result_h} : result_s;
                                                      // NV, DZ, OF, UF, NX
        assign pe_data_out[i][32 +: `FP_FLAGS_BITS] = fmt_h_out
            ? {tuser_h[2], 1'b0, tuser_h[1], tuser_h[0], 1'b0}
            : {tuser_s[2], 1'b0, tuser_s[1], tuser_s[0], 1'b0};
    end

    assign has_fflags = 1;
    assign per_lane_fflags = fflags_out;

`else

    for (genvar i = 0; i < NUM_PES; ++i) begin : g_fmas
        reg [63:0] r;
        `UNUSED_VAR (r)
        fflags_t f;

        always @(*) begin
            dpi_fmadd (
                pe_enable,
                int'(0),
                {32'hffffffff, pe_data_in[i][0 +: 32]},  // a
                {32'hffffffff, pe_data_in[i][32 +: 32]}, // b
                {32'hffffffff, pe_data_in[i][64 +: 32]}, // c
                pe_data_in[0][96 +: INST_FRM_BITS],     // frm
                r,
                f
            );
        end

        VX_shift_register #(
            .DATAW  (32 + $bits(fflags_t)),
            .DEPTH  (`LATENCY_FMA)
        ) shift_req_dpi (
            .clk      (clk),
            `UNUSED_PIN (reset),
            .enable   (pe_enable),
            .data_in  ({f, r[31:0]}),
            .data_out (pe_data_out[i])
        );
    end

    assign has_fflags = 1;
    assign per_lane_fflags = fflags_out;

`endif

`FPU_MERGE_FFLAGS(fflags, per_lane_fflags, mask_out, NUM_LANES);

endmodule

`endif
