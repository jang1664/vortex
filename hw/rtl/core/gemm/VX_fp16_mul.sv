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
`ifndef VIVADO
`define USE_DPI
`include "float_dpi.vh"
`endif
`endif
`endif
`endif

module VX_fp16_mul #(
    parameter LATENCY = 2,
    parameter OUT_BUF = 0,
    parameter USE_LOW_LATENCY_IP = 0,
    parameter USE_LATENCY1_IP = 0
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

`include "VX_fp16_arith.vh"

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

    assign fpnew_operands[0] = fpnew_inputs_data[15:0];
    assign fpnew_operands[1] = fpnew_inputs_data[31:16];
    assign fpnew_operands[2] = '0;

    fpnew_top #(
        .Features       (FPU_FEATURES),
        .Implementation (FPU_IMPLEMENTATION),
        .TagType        (logic)
    ) fpnew_mul (
        .clk_i          (clk),
        .rst_ni         (~reset),
        .operands_i     (fpnew_operands),
        .rnd_mode_i     (fpnew_pkg::RNE),
        .op_i           (fpnew_pkg::MUL),
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

`ifdef DBG_TRACE_GEMM
    always @(posedge clk) begin
        if (!reset) begin
            if (a_valid && a_ready) begin
                `TRACE(4, ("%m : [%0t] | FP16_MUL_INPUT_A | {data=0x%0h}\n", $time, a_data));
            end
            if (b_valid && b_ready) begin
                `TRACE(4, ("%m : [%0t] | FP16_MUL_INPUT_B | {data=0x%0h}\n", $time, b_data));
            end
            if (result_valid && result_ready) begin
                `TRACE(4, ("%m : [%0t] | FP16_MUL_OUTPUT | {result=0x%0h}\n", $time, result_data));
            end
        end
    end
`endif

`elsif USE_DPI

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
    wire [31:0] a_fp32 = vx_fp16_to_fp32(pop_streams[0].data);
    wire [31:0] b_fp32 = vx_fp16_to_fp32(pop_streams[1].data);

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
    wire [15:0] result_fp16 = vx_fp32_to_fp16_rne(dpi_result_fp32[31:0]);

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
                `TRACE(4, ("%m : [%0t] | FP16_MUL_INPUT_A | {data=0x%0h}\n", $time, a_data));
            end
            if (b_valid && b_ready) begin
                `TRACE(4, ("%m : [%0t] | FP16_MUL_INPUT_B | {data=0x%0h}\n", $time, b_data));
            end
            if (result_valid && result_ready) begin
                `TRACE(4, ("%m : [%0t] | FP16_MUL | {a_fp32=0x%0h, b_fp32=0x%0h, mul_fp32=0x%0h, result_fp16=0x%0h}\n",
                    $time, a_fp32, b_fp32, dpi_result_fp32[31:0], result_fp16));
                `TRACE(4, ("%m : [%0t] | FP16_MUL_OUTPUT | {result=0x%0h}\n", $time, result_data));
            end
        end
    end
`endif

`else // Vivado IP or XSIM — native FP16 Xilinx IP

    // Match independently arriving operands before forking a transaction to
    // the IP and its correction metadata. The fence is fall-through when both
    // operands are present; it does not add a fixed arithmetic pipeline stage.
    VX_stream_intf #(.DATA_WIDTH(16)) push_streams [2] (.clk(clk));
    VX_stream_intf #(.DATA_WIDTH(16)) pop_streams [2] (.clk(clk));
    assign push_streams[0].valid = a_valid;
    assign push_streams[0].data = a_data;
    assign push_streams[0].strb = '1;
    assign a_ready = push_streams[0].ready;
    assign push_streams[1].valid = b_valid;
    assign push_streams[1].data = b_data;
    assign push_streams[1].strb = '1;
    assign b_ready = push_streams[1].ready;
    VX_stream_fence #(.NB_STREAMS(2), .DATA_WIDTH(16)) input_fence (
        .clk_i(clk), .resetn_i(~reset), .clear_i(1'b0),
        .push_i(push_streams), .pop_o(pop_streams)
    );

    wire [15:0] joined_a = pop_streams[0].data;
    wire [15:0] joined_b = pop_streams[1].data;
    wire ip_a_ready, ip_b_ready, correction_ready;
    wire joined_ready = !reset && ip_a_ready && ip_b_ready && correction_ready;
    assign pop_streams[0].ready = joined_ready;
    assign pop_streams[1].ready = joined_ready;
    // Both IP input channels and the metadata queue accept the same pair.
    wire ip_inputs_valid = pop_streams[0].valid && pop_streams[1].valid && joined_ready;
    wire ip_result_valid, ip_result_ready;
    wire [15:0] ip_result_data;
    wire correction_valid, correction_select_out;
    wire [15:0] correction_out;
    wire [15:0] correction_data = vx_fp16_mul_rne(joined_a, joined_b);
    wire correction_select =
        ((joined_a[14:10] == 0) && (joined_a[9:0] != 0))
        || ((joined_b[14:10] == 0) && (joined_b[9:0] != 0))
        // Include the rounding boundary where a tiny exact product becomes
        // the smallest normal. Native-half FTZ must not decide that result.
        || (correction_data[14:0] <= 15'h0400);

    // Depths cover the configured 1/2/7-cycle IPs plus elastic headroom.
    // Queue by accepted transaction, not wall-clock delay: IP stalls and
    // independently arriving inputs must not misalign correction data.
    localparam CORRECTION_DEPTH = USE_LATENCY1_IP ? 2 : (USE_LOW_LATENCY_IP ? 4 : 16);
    VX_elastic_buffer #(
        .DATAW(17), .SIZE(CORRECTION_DEPTH), .OUT_REG(0)
    ) correction_queue (
        .clk(clk), .reset(reset),
        .valid_in(ip_inputs_valid), .ready_in(correction_ready),
        .data_in({correction_select, correction_data}),
        .data_out({correction_select_out, correction_out}),
        .valid_out(correction_valid),
        .ready_out(result_ready && ip_result_valid)
    );
    assign result_valid = ip_result_valid && correction_valid;
    assign ip_result_ready = result_ready && correction_valid;
    assign result_data = correction_select_out ? correction_out : ip_result_data;

    if (USE_LATENCY1_IP) begin : g_latency1
        xil_f16mul_latency1 xil_f16mul_inst (
            .aclk                (clk),
            .aresetn             (~reset),
            .aclken              (1'b1),
            .s_axis_a_tvalid     (ip_inputs_valid),
            .s_axis_a_tready     (ip_a_ready),
            .s_axis_a_tdata      (joined_a),
            .s_axis_b_tvalid     (ip_inputs_valid),
            .s_axis_b_tready     (ip_b_ready),
            .s_axis_b_tdata      (joined_b),
            .m_axis_result_tvalid(ip_result_valid),
            .m_axis_result_tready(ip_result_ready),
            .m_axis_result_tdata (ip_result_data)
        );
    end else if (USE_LOW_LATENCY_IP) begin : g_low_latency
        xil_f16mul_low_latency xil_f16mul_inst (
            .aclk                (clk),
            .aresetn             (~reset),
            .aclken              (1'b1),
            .s_axis_a_tvalid     (ip_inputs_valid),
            .s_axis_a_tready     (ip_a_ready),
            .s_axis_a_tdata      (joined_a),
            .s_axis_b_tvalid     (ip_inputs_valid),
            .s_axis_b_tready     (ip_b_ready),
            .s_axis_b_tdata      (joined_b),
            .m_axis_result_tvalid(ip_result_valid),
            .m_axis_result_tready(ip_result_ready),
            .m_axis_result_tdata (ip_result_data)
        );
    end else begin : g_default_latency
        xil_f16mul xil_f16mul_inst (
            .aclk                (clk),
            .aresetn             (~reset),
            .aclken              (1'b1),

            // Input A (AXI Stream)
            .s_axis_a_tvalid     (ip_inputs_valid),
            .s_axis_a_tready     (ip_a_ready),
            .s_axis_a_tdata      (joined_a),

            // Input B (AXI Stream)
            .s_axis_b_tvalid     (ip_inputs_valid),
            .s_axis_b_tready     (ip_b_ready),
            .s_axis_b_tdata      (joined_b),

            // Output (AXI Stream)
            .m_axis_result_tvalid(ip_result_valid),
            .m_axis_result_tready(ip_result_ready),
            .m_axis_result_tdata (ip_result_data)
        );
    end

`ifdef DBG_TRACE_GEMM
    always @(posedge clk) begin
        if (!reset) begin
            if (a_valid && a_ready) begin
                `TRACE(4, ("%m : [%0t] | FP16_MUL_INPUT_A | {data=0x%0h}\n", $time, a_data));
            end
            if (b_valid && b_ready) begin
                `TRACE(4, ("%m : [%0t] | FP16_MUL_INPUT_B | {data=0x%0h}\n", $time, b_data));
            end
            if (result_valid && result_ready) begin
                `TRACE(4, ("%m : [%0t] | FP16_MUL_OUTPUT | {result=0x%0h}\n", $time, result_data));
            end
        end
    end
`endif

`endif

endmodule
