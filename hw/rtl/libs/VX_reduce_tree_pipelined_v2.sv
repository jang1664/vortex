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

//
// Non-recursive reduce tree implementation using for-loop based structure.
// This provides better readability compared to the recursive version.
//
// Structure:
//   Stage 0: N inputs      -> ceil(N/2) outputs
//   Stage 1: ceil(N/2)     -> ceil(N/4) outputs
//   ...
//   Stage log2(N)-1: 2     -> 1 output
//
// Pipeline insertion is controlled by PIPELINE_STAGES bitmask.
//

`include "VX_platform.vh"

`TRACING_OFF
module VX_reduce_tree_pipelined_v2 #(
    parameter IN_W  = 1,
    parameter OUT_W = IN_W,
    parameter N     = 1,
    parameter `STRING OP = "+",
    parameter PIPELINE_STAGES = 0,  // Bitmask: bit[i]=1 inserts pipeline at stage i
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
    // =========================================================================
    // Local Parameters
    // =========================================================================
    localparam NUM_STAGES = (N > 1) ? $clog2(N) : 1;
    localparam MAX_N      = N;  // Maximum width needed for intermediate storage

    // =========================================================================
    // Passthrough Case (N == 1)
    // =========================================================================
    if (N == 1) begin : g_passthru

        assign data_out  = OUT_W'(data_in[0]);
        assign valid_out = valid_in;

    // =========================================================================
    // Reduction Tree (N > 1)
    // =========================================================================
    end else begin : g_reduce

        // ---------------------------------------------------------------------
        // Signal Declarations
        // ---------------------------------------------------------------------
        // Intermediate data between stages
        // stage_data[s] holds data after stage s processing
        // stage_data[0] = converted input data
        // stage_data[NUM_STAGES] = final output
        wire [MAX_N-1:0][OUT_W-1:0] stage_data_in  [NUM_STAGES];
        wire [MAX_N-1:0][OUT_W-1:0] stage_data_out [NUM_STAGES];
        wire                        stage_valid_in [NUM_STAGES];
        wire                        stage_valid_out[NUM_STAGES];

        // ---------------------------------------------------------------------
        // Input Conversion (IN_W -> OUT_W) with sign extension
        // ---------------------------------------------------------------------
        for (genvar i = 0; i < N; i++) begin : g_input
            assign stage_data_in[0][i] = OUT_W'($signed(data_in[i]));
        end
        for (genvar i = N; i < MAX_N; i++) begin : g_input_pad
            assign stage_data_in[0][i] = '0;
        end
        assign stage_valid_in[0] = valid_in;

        // ---------------------------------------------------------------------
        // Inter-stage Connections
        // ---------------------------------------------------------------------
        for (genvar s = 1; s < NUM_STAGES; s++) begin : g_connect
            for (genvar i = 0; i < MAX_N; i++) begin : g_connect_data
                assign stage_data_in[s][i] = stage_data_out[s-1][i];
            end
            assign stage_valid_in[s] = stage_valid_out[s-1];
        end

        // ---------------------------------------------------------------------
        // Generate Reduction Stages
        // ---------------------------------------------------------------------
        for (genvar s = 0; s < NUM_STAGES; s++) begin : g_stage

            // Calculate sizes for this stage
            // curr_n: number of valid elements entering this stage
            // next_n: number of valid elements exiting this stage
            localparam int CURR_N = (N + (1 << s) - 1) >> s;  // ceil(N / 2^s)
            localparam int NEXT_N = (CURR_N + 1) >> 1;        // ceil(CURR_N / 2)

            // Combinational reduction result
            wire [MAX_N-1:0][OUT_W-1:0] reduce_result;
            wire                        reduce_valid;

            // Perform pairwise operations
            for (genvar i = 0; i < CURR_N / 2; i++) begin : g_pair
                if (OP == "+") begin : g_op
                    assign reduce_result[i] = signed'(stage_data_in[s][2*i]) + signed'(stage_data_in[s][2*i + 1]);
                end else if (OP == "^") begin : g_op
                    assign reduce_result[i] = stage_data_in[s][2*i] ^ stage_data_in[s][2*i + 1];
                end else if (OP == "&") begin : g_op
                    assign reduce_result[i] = stage_data_in[s][2*i] & stage_data_in[s][2*i + 1];
                end else if (OP == "|") begin : g_op
                    assign reduce_result[i] = stage_data_in[s][2*i] | stage_data_in[s][2*i + 1];
                end else begin : g_error
                    `ERROR(("invalid operator"));
                end
            end

            // Handle odd element (pass through)
            if (CURR_N % 2 == 1) begin : g_odd
                assign reduce_result[CURR_N / 2] = stage_data_in[s][CURR_N - 1];
            end

            // Zero pad unused outputs
            for (genvar i = NEXT_N; i < MAX_N; i++) begin : g_pad
                assign reduce_result[i] = '0;
            end

            assign reduce_valid = stage_valid_in[s];

            // -----------------------------------------------------------------
            // Optional Pipeline Stage
            // -----------------------------------------------------------------
            if ((PIPELINE_STAGES & (1 << s)) != 0) begin : g_piped

                wire [NEXT_N * OUT_W - 1:0] pipe_data_in;
                wire [NEXT_N * OUT_W - 1:0] pipe_data_out;
                wire                        pipe_valid_out;

                // Pack data for elastic buffer
                for (genvar i = 0; i < NEXT_N; i++) begin : g_pack
                    assign pipe_data_in[i * OUT_W +: OUT_W] = reduce_result[i];
                end

                VX_elastic_buffer #(
                    .DATAW   (NEXT_N * OUT_W),
                    .SIZE    (EB_SIZE),
                    .OUT_REG (EB_OUT_REG),
                    .LUTRAM  (0)
                ) u_stage_pipe (
                    .clk       (clk),
                    .reset     (reset),
                    .valid_in  (reduce_valid),
                    .ready_in  (/* unused */),
                    .data_in   (pipe_data_in),
                    .data_out  (pipe_data_out),
                    .ready_out (1'b1),
                    .valid_out (pipe_valid_out)
                );

                // Unpack data from elastic buffer
                for (genvar i = 0; i < NEXT_N; i++) begin : g_unpack
                    assign stage_data_out[s][i] = pipe_data_out[i * OUT_W +: OUT_W];
                end
                for (genvar i = NEXT_N; i < MAX_N; i++) begin : g_unpack_pad
                    assign stage_data_out[s][i] = '0;
                end
                assign stage_valid_out[s] = pipe_valid_out;

            end else begin : g_bypass

                // Direct connection (no pipeline)
                for (genvar i = 0; i < MAX_N; i++) begin : g_direct
                    assign stage_data_out[s][i] = reduce_result[i];
                end
                assign stage_valid_out[s] = reduce_valid;

            end
        end

        // ---------------------------------------------------------------------
        // Output Assignment
        // ---------------------------------------------------------------------
        assign data_out  = stage_data_out[NUM_STAGES - 1][0];
        assign valid_out = stage_valid_out[NUM_STAGES - 1];

    end

endmodule
`TRACING_ON
