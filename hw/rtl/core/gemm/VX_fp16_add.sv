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

`include "VX_define.vh"

`ifndef FPU_FPNEW
`ifdef SIMULATION
`ifndef XSIM
`define USE_DPI
`include "float_dpi.vh"
`endif
`endif
`endif

module VX_fp16_add #(
    parameter LATENCY = 2,
    parameter OUT_BUF = 0
) (
    input  wire        clk,
    input  wire        reset,

    // Input A
    input  wire        a_valid,
    output wire        a_ready,
    input  wire [15:0] a_data,

    // Input B
    input  wire        b_valid,
    output wire        b_ready,
    input  wire [15:0] b_data,

    // Output
    output wire        result_valid,
    input  wire        result_ready,
    output wire [15:0] result_data
);

`ifdef FPU_FPNEW

    import fpnew_pkg::*;

    localparam fpnew_pkg::fpu_features_t FPU_FEATURES = '{
        Width:         16,
        EnableVectors: 1'b0,
        EnableNanBox:  1'b0,
        FpFmtMask:     5'b00100, // FP16 only
        IntFmtMask:    4'b0010   // INT32 only
    };

    localparam fpnew_pkg::fpu_implementation_t FPU_IMPLEMENTATION = '{
        PipeRegs: '{
            '{32'(LATENCY), 32'(0), 32'(0), 32'(0), 32'(0)}, // ADDMUL
            '{default: 32'(0)},           // DIVSQRT
            '{default: 32'(0)},           // NONCOMP
            '{default: 32'(0)}            // CONV
        },
        UnitTypes: '{
            '{default: fpnew_pkg::PARALLEL}, // ADDMUL
            '{default: fpnew_pkg::DISABLED}, // DIVSQRT
            '{default: fpnew_pkg::DISABLED}, // NONCOMP
            '{default: fpnew_pkg::DISABLED}  // CONV
        },
        PipeConfig: fpnew_pkg::DISTRIBUTED
    };

    // Stream fence: synchronize a and b inputs
    VX_stream_intf #(.DATA_WIDTH(16)) push_streams [2] (.clk(clk));
    VX_stream_intf #(.DATA_WIDTH(16)) pop_streams  [2] (.clk(clk));

    assign push_streams[0].valid = a_valid;
    assign push_streams[0].data  = a_data;
    assign push_streams[0].strb  = '1;
    assign a_ready               = push_streams[0].ready;

    assign push_streams[1].valid = b_valid;
    assign push_streams[1].data  = b_data;
    assign push_streams[1].strb  = '1;
    assign b_ready               = push_streams[1].ready;

    VX_stream_fence #(
        .NB_STREAMS(2),
        .DATA_WIDTH(16)
    ) input_fence (
        .clk_i    (clk),
        .resetn_i (~reset),
        .clear_i  (1'b0),
        .push_i   (push_streams),
        .pop_o    (pop_streams)
    );

    wire inputs_valid = pop_streams[0].valid && pop_streams[1].valid;
    wire inputs_ready;
    wire fpnew_inputs_valid;
    wire fpnew_inputs_ready;
    wire [31:0] fpnew_inputs_data;

    assign pop_streams[0].ready = inputs_ready;
    assign pop_streams[1].ready = inputs_ready;

    VX_elastic_buffer #(
        .DATAW   (32),
        .SIZE    (1),
        .OUT_REG (0)
    ) input_buffer (
        .clk       (clk),
        .reset     (reset),
        .valid_in  (inputs_valid),
        .ready_in  (inputs_ready),
        .data_in   ({pop_streams[1].data, pop_streams[0].data}),
        .data_out  (fpnew_inputs_data),
        .valid_out (fpnew_inputs_valid),
        .ready_out (fpnew_inputs_ready)
    );

    logic [2:0][15:0] fpnew_operands;
    wire [15:0] fpnew_result;
    wire fpnew_out_valid;
    wire fpnew_out_ready;
    fpnew_pkg::status_t fpnew_status;
    logic fpnew_tag;
    `UNUSED_VAR (fpnew_status)
    `UNUSED_VAR (fpnew_tag)

    // ADD mode in FPnew uses operand 1 and operand 2 as addends.
    assign fpnew_operands[0] = '0;
    assign fpnew_operands[1] = fpnew_inputs_data[15:0];
    assign fpnew_operands[2] = fpnew_inputs_data[31:16];

    fpnew_top #(
        .Features       (FPU_FEATURES),
        .Implementation (FPU_IMPLEMENTATION),
        .TagType        (logic)
    ) fpnew_add (
        .clk_i          (clk),
        .rst_ni         (~reset),
        .operands_i     (fpnew_operands),
        .rnd_mode_i     (fpnew_pkg::RNE),
        .op_i           (fpnew_pkg::ADD),
        .op_mod_i       (1'b0),
        .src_fmt_i      (fpnew_pkg::FP16),
        .dst_fmt_i      (fpnew_pkg::FP16),
        .int_fmt_i      (fpnew_pkg::INT32),
        .vectorial_op_i (1'b0),
        .simd_mask_i    (1'b1),
        .tag_i          (1'b0),
        .in_valid_i     (fpnew_inputs_valid),
        .in_ready_o     (fpnew_inputs_ready),
        .flush_i        (1'b0),
        .result_o       (fpnew_result),
        .status_o       (fpnew_status),
        .tag_o          (fpnew_tag),
        .out_valid_o    (fpnew_out_valid),
        .out_ready_i    (fpnew_out_ready),
        `UNUSED_PIN (busy_o)
    );

    VX_elastic_buffer #(
        .DATAW   (16),
        .SIZE    (`TO_OUT_BUF_SIZE(OUT_BUF)),
        .OUT_REG (`TO_OUT_BUF_REG(OUT_BUF))
    ) result_buffer (
        .clk       (clk),
        .reset     (reset),
        .valid_in  (fpnew_out_valid),
        .ready_in  (fpnew_out_ready),
        .data_in   (fpnew_result),
        .data_out  (result_data),
        .valid_out (result_valid),
        .ready_out (result_ready)
    );

`elsif USE_DPI

    // FP16 <-> FP32 conversion helpers for DPI path (DPI operates in FP32)
    function automatic [31:0] fp16_to_fp32_convert(input [15:0] fp16);
        logic        sign;
        logic [4:0]  exp_fp16;
        logic [9:0]  frac_fp16;
        logic [7:0]  exp_fp32;
        logic [22:0] frac_fp32;

        sign      = fp16[15];
        exp_fp16  = fp16[14:10];
        frac_fp16 = fp16[9:0];

        if (exp_fp16 == 5'b0) begin
            return {sign, 31'b0};
        end else if (exp_fp16 == 5'b11111) begin
            exp_fp32  = 8'hFF;
            frac_fp32 = {frac_fp16, 13'b0};
            return {sign, exp_fp32, frac_fp32};
        end else begin
            exp_fp32  = {3'b0, exp_fp16} + 8'd112; // -15 + 127
            frac_fp32 = {frac_fp16, 13'b0};
            return {sign, exp_fp32, frac_fp32};
        end
    endfunction

    function automatic [15:0] fp32_to_fp16_convert(input [31:0] fp32);
        logic        sign;
        logic [7:0]  exp_fp32;
        logic [22:0] frac_fp32;
        logic [4:0]  exp_fp16;
        logic [9:0]  frac_fp16;
        logic [7:0]  exp_adjusted;

        sign      = fp32[31];
        exp_fp32  = fp32[30:23];
        frac_fp32 = fp32[22:0];

        if (exp_fp32 == 8'b0) begin
            return {sign, 15'b0};
        end else if (exp_fp32 == 8'hFF) begin
            exp_fp16  = 5'b11111;
            frac_fp16 = frac_fp32[22:13];
            return {sign, exp_fp16, frac_fp16};
        end else begin
            exp_adjusted = exp_fp32 - 8'd112; // 127 - 15

            if (exp_adjusted >= 8'd31) begin
                return {sign, 5'b11111, 10'b0};
            end else if (exp_adjusted <= 8'd0) begin
                return {sign, 15'b0};
            end else begin
                exp_fp16  = exp_adjusted[4:0];
                frac_fp16 = frac_fp32[22:13];
                return {sign, exp_fp16, frac_fp16};
            end
        end
    endfunction

    // DPI path: stream fence + FP16 -> FP32 -> DPI add -> FP32 -> FP16

    VX_stream_intf #(.DATA_WIDTH(16)) push_streams [2] (.clk(clk));
    VX_stream_intf #(.DATA_WIDTH(16)) pop_streams  [2] (.clk(clk));

    assign push_streams[0].valid = a_valid;
    assign push_streams[0].data  = a_data;
    assign push_streams[0].strb  = '1;
    assign a_ready               = push_streams[0].ready;

    assign push_streams[1].valid = b_valid;
    assign push_streams[1].data  = b_data;
    assign push_streams[1].strb  = '1;
    assign b_ready               = push_streams[1].ready;

    VX_stream_fence #(
        .NB_STREAMS(2),
        .DATA_WIDTH(16)
    ) input_fence (
        .clk_i    (clk),
        .resetn_i (~reset),
        .clear_i  (1'b0),
        .push_i   (push_streams),
        .pop_o    (pop_streams)
    );

    wire inputs_valid = pop_streams[0].valid && pop_streams[1].valid;
    wire inputs_ready;

    assign pop_streams[0].ready = inputs_ready;
    assign pop_streams[1].ready = inputs_ready;

    wire [31:0] a_fp32 = fp16_to_fp32_convert(pop_streams[0].data);
    wire [31:0] b_fp32 = fp16_to_fp32_convert(pop_streams[1].data);

    reg [63:0] dpi_result_fp32;
    reg [4:0]  dpi_fflags;
    `UNUSED_VAR(dpi_fflags)

    always @(*) begin
        dpi_fadd(
            inputs_valid,                      // enable
            32'(0),                            // dst_fmt: 0=FP32
            {32'hFFFFFFFF, a_fp32[31:0]},      // a (NaN-boxed)
            {32'hFFFFFFFF, b_fp32[31:0]},      // b (NaN-boxed)
            3'b0,                              // frm (RNE)
            dpi_result_fp32,                   // result
            dpi_fflags                         // fflags
        );
    end

    wire [15:0] result_fp16 = fp32_to_fp16_convert(dpi_result_fp32[31:0]);

    VX_elastic_buffer #(
        .DATAW   (16),
        .SIZE    (`TO_OUT_BUF_SIZE(OUT_BUF + LATENCY)),
        .OUT_REG (`TO_OUT_BUF_REG(OUT_BUF))
    ) result_buffer (
        .clk       (clk),
        .reset     (reset),
        .valid_in  (inputs_valid),
        .ready_in  (inputs_ready),
        .data_in   (result_fp16),
        .data_out  (result_data),
        .valid_out (result_valid),
        .ready_out (result_ready)
    );

`else // Vivado IP or XSIM — native FP16 Xilinx IP

    xil_f16add xil_f16add_inst (
        .aclk                (clk),
        .aresetn             (~reset),
        .aclken              (1'b1),

        // Input A (AXI Stream)
        .s_axis_a_tvalid     (a_valid),
        .s_axis_a_tready     (a_ready),
        .s_axis_a_tdata      (a_data),

        // Input B (AXI Stream)
        .s_axis_b_tvalid     (b_valid),
        .s_axis_b_tready     (b_ready),
        .s_axis_b_tdata      (b_data),

        // Output (AXI Stream)
        .m_axis_result_tvalid(result_valid),
        .m_axis_result_tready(result_ready),
        .m_axis_result_tdata (result_data)
    );

`endif

endmodule
