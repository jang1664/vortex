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

module VX_fp32_mul #(
    parameter LATENCY = 2,
    parameter OUT_BUF = 0
) (
    input  wire        clk,
    input  wire        reset,
    
    // Input A
    input  wire        a_valid,
    output wire        a_ready,
    input  wire [31:0] a_data,
    
    // Input B
    input  wire        b_valid,
    output wire        b_ready,
    input  wire [31:0] b_data,
    
    // Output
    output wire        result_valid,
    input  wire        result_ready,
    output wire [31:0] result_data
);

`ifdef SIMULATION
    
    // DPI path: stream fence + combinational logic + elastic buffer
    
    // Stream fence: synchronize a and b inputs
    VX_stream_intf #(.DATA_WIDTH(32)) push_streams [2] (.clk(clk));
    VX_stream_intf #(.DATA_WIDTH(32)) pop_streams [2] (.clk(clk));
    
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
        .DATA_WIDTH(32)
    ) input_fence (
        .clk_i    (clk),
        .resetn_i (~reset),
        .clear_i  (1'b0),
        .push_i   (push_streams),
        .pop_o    (pop_streams)
    );
    
    // DPI call (combinational)
    wire inputs_valid = pop_streams[0].valid && pop_streams[1].valid;
    wire inputs_ready;
    
    assign pop_streams[0].ready = inputs_ready;
    assign pop_streams[1].ready = inputs_ready;
    
    reg [63:0] dpi_result;
    reg [4:0] dpi_fflags;
    `UNUSED_VAR(dpi_fflags)
    
    always @(*) begin
        dpi_fmul(
            inputs_valid,                        // enable
            32'(0),                              // dst_fmt: 0=FP32
            {32'hFFFFFFFF, pop_streams[0].data}, // a (NaN-boxed)
            {32'hFFFFFFFF, pop_streams[1].data}, // b (NaN-boxed)
            3'b0,                                // frm (RNE)
            dpi_result,                          // result
            dpi_fflags                           // fflags
        );
    end
    
    // Elastic buffer for valid/ready handshaking
    VX_elastic_buffer #(
        .DATAW   (32),
        .SIZE    (`TO_OUT_BUF_SIZE(OUT_BUF + LATENCY)),
        .OUT_REG (`TO_OUT_BUF_REG(OUT_BUF))
    ) result_buffer (
        .clk       (clk),
        .reset     (reset),
        .valid_in  (inputs_valid),
        .ready_in  (inputs_ready),
        .data_in   (dpi_result[31:0]),
        .data_out  (result_data),
        .valid_out (result_valid),
        .ready_out (result_ready)
    );

`ifdef DBG_TRACE_GEMM
    always @(posedge clk) begin
        if (!reset) begin
            `TRACE(2, ("%t: VX_fp32_mul - INPUT: a_valid=%b, a_data=0x%h, a_ready=%b, b_valid=%b, b_data=0x%h, b_ready=%b\n", 
                $time, a_valid, a_data, a_ready, b_valid, b_data, b_ready))
            `TRACE(2, ("%t: VX_fp32_mul - FENCE: pop[0].valid=%b, pop[0].data=0x%h, pop[1].valid=%b, pop[1].data=0x%h\n", 
                $time, pop_streams[0].valid, pop_streams[0].data, pop_streams[1].valid, pop_streams[1].data))
            `TRACE(2, ("%t: VX_fp32_mul - DPI: inputs_valid=%b, inputs_ready=%b, result=0x%h\n", 
                $time, inputs_valid, inputs_ready, dpi_result[31:0]))
            `TRACE(2, ("%t: VX_fp32_mul - OUTPUT: result_valid=%b, result_ready=%b, result_data=0x%h\n", 
                $time, result_valid, result_ready, result_data))
        end
    end
`endif
    
`else // Vivado IP
    
    // Xilinx Floating Point IP (AXI Stream interface)
    xil_fmul xil_fmul_inst (
        .aclk                (clk),
        
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
