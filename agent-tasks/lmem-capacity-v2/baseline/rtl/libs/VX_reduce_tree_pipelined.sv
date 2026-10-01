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

`include "VX_platform.vh"

`TRACING_OFF
module VX_reduce_tree_pipelined #(
    parameter IN_W  = 1,
    parameter OUT_W = IN_W,
    parameter N     = 1,
    parameter `STRING OP = "+",
    parameter PIPELINE_STAGES = 0,  // Bitmask: bit[i]=1 inserts pipeline at stage i
    parameter STAGE_NUM = 0,        // Current stage number (0=root, increases with depth)
    parameter EB_SIZE = 1,          // Elastic buffer SIZE parameter
    parameter EB_OUT_REG = 1        // Elastic buffer OUT_REG parameter
) (
    input  wire clk,
    input  wire reset,
    input  wire [N-1:0][IN_W-1:0] data_in,
    input  wire valid_in,
    output wire [OUT_W-1:0] data_out,
    output wire valid_out
);
    if (N == 1) begin : g_passthru
        // Leaf node: simple type conversion, no pipeline needed
        assign data_out = OUT_W'(data_in[0]);
        assign valid_out = valid_in;
        
    end else begin : g_reduce
        localparam int N_A = N / 2;
        localparam int N_B = N - N_A;
        localparam int NEXT_STAGE = STAGE_NUM + 1;

        wire [N_A-1:0][IN_W-1:0] in_A;
        wire [N_B-1:0][IN_W-1:0] in_B;
        wire [OUT_W-1:0] out_A, out_B;
        wire valid_A, valid_B;

        // Split inputs
        for (genvar i = 0; i < N_A; i++) begin : g_in_A
            assign in_A[i] = data_in[i];
        end

        for (genvar i = 0; i < N_B; i++) begin : g_in_B
            assign in_B[i] = data_in[N_A + i];
        end

        // Recursive calls with incremented stage number
        VX_reduce_tree_pipelined #(
            .IN_W  (IN_W),
            .OUT_W (OUT_W),
            .N     (N_A),
            .OP    (OP),
            .PIPELINE_STAGES (PIPELINE_STAGES),
            .STAGE_NUM (NEXT_STAGE),
            .EB_SIZE (EB_SIZE),
            .EB_OUT_REG (EB_OUT_REG)
        ) reduce_A (
            .clk       (clk),
            .reset     (reset),
            .data_in   (in_A),
            .valid_in  (valid_in),
            .data_out  (out_A),
            .valid_out (valid_A)
        );

        VX_reduce_tree_pipelined #(
            .IN_W  (IN_W),
            .OUT_W (OUT_W),
            .N     (N_B),
            .OP    (OP),
            .PIPELINE_STAGES (PIPELINE_STAGES),
            .STAGE_NUM (NEXT_STAGE),
            .EB_SIZE (EB_SIZE),
            .EB_OUT_REG (EB_OUT_REG)
        ) reduce_B (
            .clk       (clk),
            .reset     (reset),
            .data_in   (in_B),
            .valid_in  (valid_in),
            .data_out  (out_B),
            .valid_out (valid_B)
        );

        // Perform operation
        wire [OUT_W-1:0] operation_result;
        
        if (OP == "+") begin : g_plus
            assign operation_result = out_A + out_B;
        end else if (OP == "^") begin : g_xor
            assign operation_result = out_A ^ out_B;
        end else if (OP == "&") begin : g_and
            assign operation_result = out_A & out_B;
        end else if (OP == "|") begin : g_or
            assign operation_result = out_A | out_B;
        end else begin : g_error
            `ERROR(("invalid parameter"));
        end

        // Valid signal - use the valid from child A (both should have same valid timing)
        wire operation_valid;
        assign operation_valid = valid_A;
        
        // Optional pipeline insertion based on PIPELINE_STAGES bitmask
        if ((PIPELINE_STAGES & (1 << STAGE_NUM)) != 0) begin : g_piped
            // Insert elastic buffer at this stage
            VX_elastic_buffer #(
                .DATAW   (OUT_W),
                .SIZE    (EB_SIZE),
                .OUT_REG (EB_OUT_REG),
                .LUTRAM  (0)
            ) stage_buffer (
                .clk       (clk),
                .reset     (reset),
                .valid_in  (operation_valid),
                .ready_in  (/* unused */),
                .data_in   (operation_result),
                .data_out  (data_out),
                .ready_out (1'b1),              // Always ready
                .valid_out (valid_out)
            );
        end else begin : g_bypass
            // No pipeline: direct connection
            assign data_out = operation_result;
            assign valid_out = operation_valid;
        end
    end

endmodule
`TRACING_ON
