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

`ifdef SIMULATION
`include "float_dpi.vh"
`endif

module VX_fp16_mul #(
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

    // FP16 <-> FP32 conversion helpers (pure combinational)
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

`ifdef SIMULATION

    // DPI path: stream fence + FP16 -> FP32 -> DPI mul -> FP32 -> FP16

    // Stream fence: synchronize a and b inputs
    VX_stream_intf #(.DATA_WIDTH(16)) push_streams [2] (.clk(clk));
    VX_stream_intf #(.DATA_WIDTH(16)) pop_streams [2] (.clk(clk));

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

    // After fence, both inputs are synchronized
    wire inputs_valid = pop_streams[0].valid && pop_streams[1].valid;
    wire inputs_ready;

    assign pop_streams[0].ready = inputs_ready;
    assign pop_streams[1].ready = inputs_ready;

    // FP16 to FP32 conversion using function
    wire [31:0] a_fp32 = fp16_to_fp32_convert(pop_streams[0].data);
    wire [31:0] b_fp32 = fp16_to_fp32_convert(pop_streams[1].data);

    // DPI FP32 multiplication (combinational)
    reg [63:0] dpi_result_fp32;
    reg [4:0] dpi_fflags;
    `UNUSED_VAR(dpi_fflags)

    always @(*) begin
        dpi_fmul(
            inputs_valid,                        // enable
            32'(0),                              // dst_fmt: 0=FP32
            {32'hFFFFFFFF, a_fp32[31:0]},       // a (NaN-boxed)
            {32'hFFFFFFFF, b_fp32[31:0]},       // b (NaN-boxed)
            3'b0,                                // frm (RNE)
            dpi_result_fp32,                     // result
            dpi_fflags                           // fflags
        );
    end

    // FP32 to FP16 conversion using function
    wire [15:0] result_fp16 = fp32_to_fp16_convert(dpi_result_fp32[31:0]);

    // Elastic buffer for valid/ready handshaking
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

`ifdef DBG_TRACE_GEMM
    always @(posedge clk) begin
        if (!reset) begin
            if (a_valid && a_ready) begin
                `TRACE(4, ("%t: VX_fp16_mul INPUT_A: data=0x%0h\n", $time, a_data));
            end
            if (b_valid && b_ready) begin
                `TRACE(4, ("%t: VX_fp16_mul INPUT_B: data=0x%0h\n", $time, b_data));
            end
            if (inputs_valid) begin
                `TRACE(4, ("%t: VX_fp16_mul FENCE: a_data=0x%0h, b_data=0x%0h\n",
                    $time, pop_streams[0].data, pop_streams[1].data));
                `TRACE(4, ("%t: VX_fp16_mul FP16_TO_FP32: a_fp32=0x%0h, b_fp32=0x%0h\n",
                    $time, a_fp32[31:0], b_fp32[31:0]));
                `TRACE(4, ("%t: VX_fp16_mul DPI_MUL: result=0x%0h\n",
                    $time, dpi_result_fp32[31:0]));
                `TRACE(4, ("%t: VX_fp16_mul FP32_TO_FP16: fp32=0x%0h, fp16=0x%0h\n",
                    $time, dpi_result_fp32[31:0], result_fp16));
            end
            if (result_valid && result_ready) begin
                `TRACE(4, ("%t: VX_fp16_mul OUTPUT: result=0x%0h\n", $time, result_data));
            end
        end
    end
`endif

`else // Vivado IP

    // Convert FP16 to FP32 using function
    wire [31:0] a_fp32_data = fp16_to_fp32_convert(a_data);
    wire [31:0] b_fp32_data = fp16_to_fp32_convert(b_data);

    // FP32 multiplication using Xilinx IP
    wire result_fp32_valid;
    wire result_fp32_ready;
    wire [31:0] result_fp32_data;

    xil_f16mul xil_f16mul_inst (
        .aclk                (clk),
        .aclken              (1'b1),

        // Input A (AXI Stream)
        .s_axis_a_tvalid     (a_valid),
        .s_axis_a_tready     (a_ready),
        .s_axis_a_tdata      (a_fp32_data),

        // Input B (AXI Stream)
        .s_axis_b_tvalid     (b_valid),
        .s_axis_b_tready     (b_ready),
        .s_axis_b_tdata      (b_fp32_data),

        // Output (AXI Stream)
        .m_axis_result_tvalid(result_fp32_valid),
        .m_axis_result_tready(result_fp32_ready),
        .m_axis_result_tdata (result_fp32_data)
    );

    // Convert FP32 back to FP16 using function
    assign result_data       = fp32_to_fp16_convert(result_fp32_data);
    assign result_valid      = result_fp32_valid;
    assign result_fp32_ready = result_ready;

`endif

endmodule
