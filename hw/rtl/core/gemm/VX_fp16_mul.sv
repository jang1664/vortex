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
    
    // FP16 to FP32 conversion (combinational RTL)
    wire [31:0] a_fp32, b_fp32;
    
    // Convert FP16 to FP32 for input A
    assign a_fp32 = fp16_to_fp32_convert(pop_streams[0].data);
    
    // Convert FP16 to FP32 for input B
    assign b_fp32 = fp16_to_fp32_convert(pop_streams[1].data);
    
    // FP16 to FP32 conversion function
    function automatic [31:0] fp16_to_fp32_convert(input [15:0] fp16);
        logic        sign;
        logic [4:0]  exp_fp16;
        logic [9:0]  frac_fp16;
        logic [7:0]  exp_fp32;
        logic [22:0] frac_fp32;
        
        sign     = fp16[15];
        exp_fp16 = fp16[14:10];
        frac_fp16= fp16[9:0];
        
        if (exp_fp16 == 5'b0) begin
            return {sign, 31'b0};
        end else if (exp_fp16 == 5'b11111) begin
            exp_fp32 = 8'hFF;
            frac_fp32 = {frac_fp16, 13'b0};
            return {sign, exp_fp32, frac_fp32};
        end else begin
            exp_fp32 = {3'b0, exp_fp16} + 8'd112;
            frac_fp32 = {frac_fp16, 13'b0};
            return {sign, exp_fp32, frac_fp32};
        end
    endfunction
    
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
    
    // FP32 to FP16 conversion (combinational RTL)
    wire [15:0] result_fp16;
    
    assign result_fp16 = fp32_to_fp16_convert(dpi_result_fp32[31:0]);
    
    // FP32 to FP16 conversion function
    function automatic [15:0] fp32_to_fp16_convert(input [31:0] fp32);
        logic        sign;
        logic [7:0]  exp_fp32;
        logic [22:0] frac_fp32;
        logic [4:0]  exp_fp16;
        logic [9:0]  frac_fp16;
        logic [7:0]  exp_adjusted;
        
        sign     = fp32[31];
        exp_fp32 = fp32[30:23];
        frac_fp32= fp32[22:0];
        
        if (exp_fp32 == 8'b0) begin
            return {sign, 15'b0};
        end else if (exp_fp32 == 8'hFF) begin
            exp_fp16 = 5'b11111;
            frac_fp16 = frac_fp32[22:13];
            return {sign, exp_fp16, frac_fp16};
        end else begin
            exp_adjusted = exp_fp32 - 8'd112;
            
            if (exp_adjusted >= 8'd31) begin
                return {sign, 5'b11111, 10'b0};
            end else if (exp_adjusted <= 8'd0) begin
                return {sign, 15'b0};
            end else begin
                exp_fp16 = exp_adjusted[4:0];
                frac_fp16 = frac_fp32[22:13];
                return {sign, exp_fp16, frac_fp16};
            end
        end
    endfunction
    
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
            end
            if (inputs_valid) begin
                `TRACE(4, ("%t: VX_fp16_mul FP16_TO_FP32: a_fp32=0x%0h, b_fp32=0x%0h\n", 
                    $time, a_fp32[31:0], b_fp32[31:0]));
            end
            if (inputs_valid) begin
                `TRACE(4, ("%t: VX_fp16_mul DPI_MUL: a=0x%0h, b=0x%0h, result=0x%0h\n", 
                    $time, a_fp32[31:0], b_fp32[31:0], dpi_result_fp32[31:0]));
            end
            if (inputs_valid) begin
                `TRACE(4, ("%t: VX_fp16_mul FP32_TO_FP16: fp32=0x%0h, fp16=0x%0h\n", 
                    $time, dpi_result_fp32[31:0], result_fp16));
            end
            if (result_valid && result_ready) begin
                `TRACE(4, ("%t: VX_fp16_mul OUTPUT: result=0x%0h\n", $time, result_data));
            end
        end
    end
`endif
    
    // FP16 <-> FP32 conversion functions (combinational)
    function automatic void fp16_to_fp32_func(
        input  [15:0] fp16_in,
        output [31:0] fp32_out
    );
        automatic logic        sign     = fp16_in[15];
        automatic logic [4:0]  exp_fp16 = fp16_in[14:10];
        automatic logic [9:0]  frac_fp16= fp16_in[9:0];
        automatic logic [7:0]  exp_fp32;
        automatic logic [22:0] frac_fp32;
        
        // Zero or denormal
        if (exp_fp16 == 5'b0) begin
            fp32_out = {sign, 31'b0};  // Zero
        end
        // Infinity or NaN
        else if (exp_fp16 == 5'b11111) begin
            exp_fp32 = 8'hFF;
            frac_fp32 = {frac_fp16, 13'b0};
            fp32_out = {sign, exp_fp32, frac_fp32};
        end
        // Normal number
        else begin
            exp_fp32 = {3'b0, exp_fp16} + 8'd112;  // Bias adjust: -15+127=112
            frac_fp32 = {frac_fp16, 13'b0};
            fp32_out = {sign, exp_fp32, frac_fp32};
        end
    endfunction
    
    function automatic void fp32_to_fp16_func(
        input  [31:0] fp32_in,
        output [15:0] fp16_out
    );
        automatic logic        sign     = fp32_in[31];
        automatic logic [7:0]  exp_fp32 = fp32_in[30:23];
        automatic logic [22:0] frac_fp32= fp32_in[22:0];
        automatic logic [4:0]  exp_fp16;
        automatic logic [9:0]  frac_fp16;
        automatic logic [7:0]  exp_adjusted;
        
        // Zero
        if (exp_fp32 == 8'b0) begin
            fp16_out = {sign, 15'b0};
        end
        // Infinity or NaN
        else if (exp_fp32 == 8'hFF) begin
            exp_fp16 = 5'b11111;
            frac_fp16 = frac_fp32[22:13];  // Keep upper bits of mantissa
            fp16_out = {sign, exp_fp16, frac_fp16};
        end
        // Normal number
        else begin
            exp_adjusted = exp_fp32 - 8'd112;  // Bias adjust: 127-15=112
            
            // Overflow to infinity
            if (exp_adjusted >= 8'd31) begin
                fp16_out = {sign, 5'b11111, 10'b0};  // Infinity
            end
            // Underflow to zero
            else if (exp_adjusted < 8'd0) begin
                fp16_out = {sign, 15'b0};  // Zero
            end
            // Normal range
            else begin
                exp_fp16 = exp_adjusted[4:0];
                frac_fp16 = frac_fp32[22:13];  // Truncate (or could round)
                fp16_out = {sign, exp_fp16, frac_fp16};
            end
        end
    endfunction
    
`else // Vivado IP
    
    // Convert FP16 to FP32
    wire a_fp32_valid, a_fp32_ready;
    wire [31:0] a_fp32_data;
    wire b_fp32_valid, b_fp32_ready;
    wire [31:0] b_fp32_data;
    
    fp16_to_fp32 fp16_to_fp32_a (
        .fp16_in  (a_data),
        .fp32_out (a_fp32_data)
    );
    assign a_fp32_valid = a_valid;
    assign a_ready = a_fp32_ready;
    
    fp16_to_fp32 fp16_to_fp32_b (
        .fp16_in  (b_data),
        .fp32_out (b_fp32_data)
    );
    assign b_fp32_valid = b_valid;
    assign b_ready = b_fp32_ready;
    
    // FP32 multiplication using Xilinx IP
    wire result_fp32_valid, result_fp32_ready;
    wire [31:0] result_fp32_data;
    
    xil_fmul xil_fmul_inst (
        .aclk                (clk),
        
        // Input A (AXI Stream)
        .s_axis_a_tvalid     (a_fp32_valid),
        .s_axis_a_tready     (a_fp32_ready),
        .s_axis_a_tdata      (a_fp32_data),
        
        // Input B (AXI Stream)
        .s_axis_b_tvalid     (b_fp32_valid),
        .s_axis_b_tready     (b_fp32_ready),
        .s_axis_b_tdata      (b_fp32_data),
        
        // Output (AXI Stream)
        .m_axis_result_tvalid(result_fp32_valid),
        .m_axis_result_tready(result_fp32_ready),
        .m_axis_result_tdata (result_fp32_data)
    );
    
    // Convert FP32 back to FP16
    fp32_to_fp16 fp32_to_fp16_inst (
        .fp32_in  (result_fp32_data),
        .fp16_out (result_data)
    );
    assign result_valid = result_fp32_valid;
    assign result_fp32_ready = result_ready;
    
`endif

endmodule

// FP16 <-> FP32 conversion modules (combinational)
module fp16_to_fp32 (
    input  wire [15:0] fp16_in,
    output reg  [31:0] fp32_out
);
    wire        sign     = fp16_in[15];
    wire [4:0]  exp_fp16 = fp16_in[14:10];
    wire [9:0]  frac_fp16= fp16_in[9:0];
    reg  [7:0]  exp_fp32;
    reg  [22:0] frac_fp32;
    
    always @(*) begin
        if (exp_fp16 == 5'b0) begin
            fp32_out = {sign, 31'b0};
        end else if (exp_fp16 == 5'b11111) begin
            exp_fp32 = 8'hFF;
            frac_fp32 = {frac_fp16, 13'b0};
            fp32_out = {sign, exp_fp32, frac_fp32};
        end else begin
            exp_fp32 = {3'b0, exp_fp16} + 8'd112;
            frac_fp32 = {frac_fp16, 13'b0};
            fp32_out = {sign, exp_fp32, frac_fp32};
        end
    end
endmodule

module fp32_to_fp16 (
    input  wire [31:0] fp32_in,
    output reg  [15:0] fp16_out
);
    wire        sign     = fp32_in[31];
    wire [7:0]  exp_fp32 = fp32_in[30:23];
    wire [22:0] frac_fp32= fp32_in[22:0];
    reg  [4:0]  exp_fp16;
    reg  [9:0]  frac_fp16;
    reg  [7:0]  exp_adjusted;
    
    always @(*) begin
        if (exp_fp32 == 8'b0) begin
            fp16_out = {sign, 15'b0};
        end else if (exp_fp32 == 8'hFF) begin
            exp_fp16 = 5'b11111;
            frac_fp16 = frac_fp32[22:13];
            fp16_out = {sign, exp_fp16, frac_fp16};
        end else begin
            exp_adjusted = exp_fp32 - 8'd112;
            if (exp_adjusted >= 8'd31) begin
                fp16_out = {sign, 5'b11111, 10'b0};
            end else if (exp_adjusted < 8'd0) begin
                fp16_out = {sign, 15'b0};
            end else begin
                exp_fp16 = exp_adjusted[4:0];
                frac_fp16 = frac_fp32[22:13];
                fp16_out = {sign, exp_fp16, frac_fp16};
            end
        end
    end
endmodule
