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
module VX_stream_arb #(
    parameter NUM_INPUTS    = 1,
    parameter NUM_OUTPUTS   = 1,
    parameter DATAW         = 1,
    parameter STICKY        = 0,   // hold the grant until its request is deasserted
    parameter `STRING ARBITER = "R",
    parameter MAX_FANOUT    = `MAX_FANOUT,
    parameter OUT_BUF       = 0,
    parameter NUM_REQS      = (NUM_INPUTS > NUM_OUTPUTS) ? `CDIV(NUM_INPUTS, NUM_OUTPUTS) : `CDIV(NUM_OUTPUTS, NUM_INPUTS),
    parameter SEL_COUNT     = `MIN(NUM_INPUTS, NUM_OUTPUTS),
    parameter LOG_NUM_REQS  = `CLOG2(NUM_REQS),
    parameter NUM_REQS_W    = `UP(LOG_NUM_REQS)
`ifdef GEMM_SRAM_FUSION
    ,parameter bit FUSION_BANK_SLICE_LINK = 1'b0
`endif
) (
    input  wire clk,
    input  wire reset,

    input  wire [NUM_INPUTS-1:0]             valid_in,
    input  wire [NUM_INPUTS-1:0][DATAW-1:0]  data_in,
    output wire [NUM_INPUTS-1:0]             ready_in,

    output wire [NUM_OUTPUTS-1:0]            valid_out,
    output wire [NUM_OUTPUTS-1:0][DATAW-1:0] data_out,
    input  wire [NUM_OUTPUTS-1:0]            ready_out,

    output wire [SEL_COUNT-1:0][NUM_REQS_W-1:0] sel_out
);
`ifdef GEMM_SRAM_FUSION
    `VX_STATIC_ASSERT(!FUSION_BANK_SLICE_LINK || (NUM_INPUTS == 16 && NUM_OUTPUTS == 1
        && MAX_FANOUT == 8 && OUT_BUF == 3 && STICKY == 0
        && (ARBITER == "P" || ARBITER == "R")), ("bank slice link requires C4 16:1/fanout8 geometry"))
`endif
    if (NUM_INPUTS > NUM_OUTPUTS) begin : g_input_select

        // #Inputs > #Outputs

        if (MAX_FANOUT != 0 && (NUM_REQS > (MAX_FANOUT + MAX_FANOUT /2))) begin : g_fanout

            localparam NUM_SLICES    = `CDIV(NUM_REQS, MAX_FANOUT);
            localparam LOG_NUM_REQS2 = `CLOG2(MAX_FANOUT);
            localparam LOG_NUM_REQS3 = `CLOG2(NUM_SLICES);
            localparam DATAW2 = DATAW + LOG_NUM_REQS2;

            wire [NUM_SLICES-1:0][NUM_OUTPUTS-1:0] valid_tmp;
            wire [NUM_SLICES-1:0][NUM_OUTPUTS-1:0][DATAW2-1:0] data_tmp;
            wire [NUM_SLICES-1:0][NUM_OUTPUTS-1:0] ready_tmp;

            for (genvar s = 0; s < NUM_SLICES; ++s) begin : g_slice_arbs

                localparam SLICE_STRIDE= MAX_FANOUT * NUM_OUTPUTS;
                localparam SLICE_BEGIN = s * SLICE_STRIDE;
                localparam SLICE_END   = `MIN(SLICE_BEGIN + SLICE_STRIDE, NUM_INPUTS);
                localparam SLICE_SIZE  = SLICE_END - SLICE_BEGIN;

                wire [NUM_OUTPUTS-1:0][DATAW-1:0] data_tmp_u;
                wire [NUM_OUTPUTS-1:0][LOG_NUM_REQS2-1:0] sel_tmp_u;
`ifdef GEMM_SRAM_FUSION
                wire [SLICE_SIZE-1:0] slice_input_ready;
                wire [NUM_OUTPUTS-1:0] slice_valid, slice_ready;
                if (FUSION_BANK_SLICE_LINK && s == 1) begin : g_fusion_bank_link
                    assign ready_in[SLICE_END-1:SLICE_BEGIN] = slice_input_ready & {SLICE_SIZE{!reset}};
                    VX_sram_bank_slice_transport #(.DATAW(DATAW2)) u_transport (
                        .clk(clk), .reset(reset),
                        .valid_in(slice_valid[0]), .ready_in(slice_ready[0]),
                        .data_in({data_tmp_u[0], sel_tmp_u[0]}),
                        .valid_out(valid_tmp[s][0]), .ready_out(ready_tmp[s][0]),
                        .data_out(data_tmp[s][0]), .idle_o()
                    );
                end else begin : g_fusion_bank_local
                    assign ready_in[SLICE_END-1:SLICE_BEGIN] = slice_input_ready;
                    assign valid_tmp[s] = slice_valid;
                    assign slice_ready = ready_tmp[s];
                    for (genvar o = 0; o < NUM_OUTPUTS; ++o) begin : g_data_tmp
                        assign data_tmp[s][o] = {data_tmp_u[o], sel_tmp_u[o]};
                    end
                end
`endif

                VX_stream_arb #(
                    .NUM_INPUTS  (SLICE_SIZE),
                    .NUM_OUTPUTS (NUM_OUTPUTS),
                    .DATAW       (DATAW),
                    .ARBITER     (ARBITER),
                    .STICKY      (STICKY),
                    .MAX_FANOUT  (MAX_FANOUT),
                    .OUT_BUF     (3)
                ) fanout_slice_arb (
                    .clk       (clk),
`ifdef GEMM_SRAM_FUSION
                    .reset     (reset),
                    .valid_in  (valid_in[SLICE_END-1: SLICE_BEGIN]
                                & {SLICE_SIZE{!((FUSION_BANK_SLICE_LINK && s == 1) && reset)}}),
                    .data_in   (data_in[SLICE_END-1: SLICE_BEGIN]),
                    .ready_in  (slice_input_ready),
                    .valid_out (slice_valid),
                    .data_out  (data_tmp_u),
                    .ready_out (slice_ready),
`else
                    .reset     (reset),
                    .valid_in  (valid_in[SLICE_END-1: SLICE_BEGIN]),
                    .data_in   (data_in[SLICE_END-1: SLICE_BEGIN]),
                    .ready_in  (ready_in[SLICE_END-1: SLICE_BEGIN]),
                    .valid_out (valid_tmp[s]),
                    .data_out  (data_tmp_u),
                    .ready_out (ready_tmp[s]),
`endif
                    .sel_out   (sel_tmp_u)
                );

`ifndef GEMM_SRAM_FUSION
                for (genvar o = 0; o < NUM_OUTPUTS; ++o) begin : g_data_tmp
                    assign data_tmp[s][o] = {data_tmp_u[o], sel_tmp_u[o]};
                end
`endif
            end

            wire [NUM_OUTPUTS-1:0][DATAW2-1:0] data_out_u;
            wire [NUM_OUTPUTS-1:0][LOG_NUM_REQS3-1:0] sel_out_u;

            VX_stream_arb #(
                .NUM_INPUTS  (NUM_SLICES * NUM_OUTPUTS),
                .NUM_OUTPUTS (NUM_OUTPUTS),
                .DATAW       (DATAW2),
                .ARBITER     (ARBITER),
                .STICKY      (STICKY),
                .MAX_FANOUT  (MAX_FANOUT),
                .OUT_BUF     (OUT_BUF)
            ) fanout_join_arb (
                .clk       (clk),
                .reset     (reset),
                .valid_in  (valid_tmp),
                .ready_in  (ready_tmp),
                .data_in   (data_tmp),
                .data_out  (data_out_u),
                .sel_out   (sel_out_u),
                .valid_out (valid_out),
                .ready_out (ready_out)
            );

            for (genvar o = 0; o < NUM_OUTPUTS; ++o) begin : g_data_out
                assign sel_out[o]  = {sel_out_u[o], data_out_u[o][LOG_NUM_REQS2-1:0]};
                assign data_out[o] = data_out_u[o][DATAW2-1:LOG_NUM_REQS2];
            end

        end else begin : g_arbiter

            wire [NUM_REQS-1:0]     arb_requests;
            wire                    arb_valid;
            wire [NUM_REQS_W-1:0]   arb_index;
            wire [NUM_REQS-1:0]     arb_onehot;
            wire                    arb_ready;

            for (genvar r = 0; r < NUM_REQS; ++r) begin : g_requests
                wire [NUM_OUTPUTS-1:0] requests;
                for (genvar o = 0; o < NUM_OUTPUTS; ++o) begin : g_o
                    localparam i = r * NUM_OUTPUTS + o;
                    assign requests[o] = valid_in[i];
                end
                assign arb_requests[r] = (| requests);
            end

            VX_generic_arbiter #(
                .NUM_REQS (NUM_REQS),
                .TYPE     (ARBITER),
                .STICKY   (STICKY)
            ) arbiter (
                .clk          (clk),
                .reset        (reset),
                .requests     (arb_requests),
                .grant_valid  (arb_valid),
                .grant_index  (arb_index),
                .grant_onehot (arb_onehot),
                .grant_ready  (arb_ready)
            );

            wire [NUM_OUTPUTS-1:0] valid_out_w;
            wire [NUM_OUTPUTS-1:0][DATAW-1:0] data_out_w;
            wire [NUM_OUTPUTS-1:0] ready_out_w;

            for (genvar o = 0; o < NUM_OUTPUTS; ++o) begin : g_data_out_w
                wire [NUM_REQS-1:0] valid_in_w;
                wire [NUM_REQS-1:0][DATAW-1:0] data_in_w;
                for (genvar r = 0; r < NUM_REQS; ++r) begin : g_r
                    localparam i = r * NUM_OUTPUTS + o;
                    if (r < NUM_INPUTS) begin : g_valid
                        assign valid_in_w[r] = valid_in[i];
                        assign data_in_w[r]  = data_in[i];
                    end else begin : g_padding
                        assign valid_in_w[r] = 0;
                        assign data_in_w[r]  = '0;
                    end
                end
                assign valid_out_w[o] = (NUM_OUTPUTS == 1) ? arb_valid : (| (valid_in_w & arb_onehot));
                assign data_out_w[o]  = data_in_w[arb_index];
            end

            for (genvar i = 0; i < NUM_INPUTS; ++i) begin : g_ready_in
                localparam o = i % NUM_OUTPUTS;
                localparam r = i / NUM_OUTPUTS;
                assign ready_in[i] = ready_out_w[o] && arb_onehot[r];
            end

            assign arb_ready = (| ready_out_w);

            for (genvar o = 0; o < NUM_OUTPUTS; ++o) begin : g_out_buf
                VX_elastic_buffer #(
                    .DATAW   (LOG_NUM_REQS + DATAW),
                    .SIZE    (`TO_OUT_BUF_SIZE(OUT_BUF)),
                    .OUT_REG (`TO_OUT_BUF_REG(OUT_BUF)),
                    .LUTRAM  (`TO_OUT_BUF_LUTRAM(OUT_BUF))
                ) out_buf (
                    .clk       (clk),
                    .reset     (reset),
                    .valid_in  (valid_out_w[o]),
                    .ready_in  (ready_out_w[o]),
                    .data_in   ({arb_index, data_out_w[o]}),
                    .data_out  ({sel_out[o], data_out[o]}),
                    .valid_out (valid_out[o]),
                    .ready_out (ready_out[o])
                );
            end
        end

    end else if (NUM_INPUTS < NUM_OUTPUTS) begin : g_output_select

        // #Inputs < #Outputs

        if (MAX_FANOUT != 0 && (NUM_REQS > (MAX_FANOUT + MAX_FANOUT /2))) begin : g_fanout

            localparam NUM_SLICES    = `CDIV(NUM_REQS, MAX_FANOUT);
            localparam LOG_NUM_REQS2 = `CLOG2(MAX_FANOUT);
            localparam LOG_NUM_REQS3 = `CLOG2(NUM_SLICES);

            wire [NUM_SLICES-1:0][NUM_INPUTS-1:0] valid_tmp;
            wire [NUM_SLICES-1:0][NUM_INPUTS-1:0][DATAW-1:0] data_tmp;
            wire [NUM_SLICES-1:0][NUM_INPUTS-1:0] ready_tmp;
            wire [NUM_INPUTS-1:0][LOG_NUM_REQS3-1:0] sel_tmp;

            VX_stream_arb #(
                .NUM_INPUTS  (NUM_INPUTS),
                .NUM_OUTPUTS (NUM_SLICES * NUM_INPUTS),
                .DATAW       (DATAW),
                .ARBITER     (ARBITER),
                .STICKY      (STICKY),
                .MAX_FANOUT  (MAX_FANOUT),
                .OUT_BUF     (3)
            ) fanout_fork_arb (
                .clk       (clk),
                .reset     (reset),
                .valid_in  (valid_in),
                .ready_in  (ready_in),
                .data_in   (data_in),
                .data_out  (data_tmp),
                .valid_out (valid_tmp),
                .ready_out (ready_tmp),
                .sel_out   (sel_tmp)
            );

            wire [NUM_SLICES-1:0][NUM_INPUTS-1:0][LOG_NUM_REQS2-1:0] sel_out_w;

            for (genvar s = 0; s < NUM_SLICES; ++s) begin : g_slice_arbs

                localparam SLICE_STRIDE= MAX_FANOUT * NUM_INPUTS;
                localparam SLICE_BEGIN = s * SLICE_STRIDE;
                localparam SLICE_END   = `MIN(SLICE_BEGIN + SLICE_STRIDE, NUM_OUTPUTS);
                localparam SLICE_SIZE  = SLICE_END - SLICE_BEGIN;

                wire [NUM_INPUTS-1:0][LOG_NUM_REQS2-1:0] sel_out_u;

                VX_stream_arb #(
                    .NUM_INPUTS  (NUM_INPUTS),
                    .NUM_OUTPUTS (SLICE_SIZE),
                    .DATAW       (DATAW),
                    .ARBITER     (ARBITER),
                    .STICKY      (STICKY),
                    .MAX_FANOUT  (MAX_FANOUT),
                    .OUT_BUF     (OUT_BUF)
                ) fanout_slice_arb (
                    .clk       (clk),
                    .reset     (reset),
                    .valid_in  (valid_tmp[s]),
                    .ready_in  (ready_tmp[s]),
                    .data_in   (data_tmp[s]),
                    .data_out  (data_out[SLICE_END-1: SLICE_BEGIN]),
                    .valid_out (valid_out[SLICE_END-1: SLICE_BEGIN]),
                    .ready_out (ready_out[SLICE_END-1: SLICE_BEGIN]),
                    .sel_out   (sel_out_w[s])
                );
            end

            for (genvar i = 0; i < NUM_INPUTS; ++i) begin : g_sel_out
                assign sel_out[i] = {sel_tmp[i], sel_out_w[sel_tmp[i]][i]};
            end

        end else begin : g_arbiter

            wire [NUM_REQS-1:0]     arb_requests;
            wire                    arb_valid;
            wire [NUM_REQS_W-1:0]   arb_index;
            wire [NUM_REQS-1:0]     arb_onehot;
            wire                    arb_ready;

            for (genvar r = 0; r < NUM_REQS; ++r) begin : g_requests
                wire [NUM_INPUTS-1:0] requests;
                for (genvar i = 0; i < NUM_INPUTS; ++i) begin : g_i
                    localparam o = r * NUM_INPUTS + i;
                    assign requests[i] = ready_out[o];
                end
                assign arb_requests[r] = (| requests);
            end

            VX_generic_arbiter #(
                .NUM_REQS (NUM_REQS),
                .TYPE     (ARBITER),
                .STICKY   (STICKY)
            ) arbiter (
                .clk          (clk),
                .reset        (reset),
                .requests     (arb_requests),
                .grant_valid  (arb_valid),
                .grant_index  (arb_index),
                .grant_onehot (arb_onehot),
                .grant_ready  (arb_ready)
            );

            wire [NUM_OUTPUTS-1:0] valid_out_w;
            wire [NUM_OUTPUTS-1:0][DATAW-1:0] data_out_w;
            wire [NUM_OUTPUTS-1:0] ready_out_w;

            for (genvar o = 0; o < NUM_OUTPUTS; ++o) begin : g_data_out_w
                localparam i = o % NUM_INPUTS;
                localparam r = o / NUM_INPUTS;
                assign valid_out_w[o] = valid_in[i] && arb_onehot[r];
                assign data_out_w[o]  = data_in[i];
            end

            for (genvar i = 0; i < NUM_INPUTS; ++i) begin : g_ready_in
                wire [NUM_REQS-1:0] ready_out_s;
                for (genvar r = 0; r < NUM_REQS; ++r) begin : g_r
                    localparam o = r * NUM_INPUTS + i;
                    assign ready_out_s[r] = ready_out_w[o];
                end
                assign ready_in[i] = (NUM_INPUTS == 1) ? arb_valid : (| (ready_out_s & arb_onehot));
            end

            assign arb_ready = (| valid_in);

            for (genvar o = 0; o < NUM_OUTPUTS; ++o) begin : g_out_buf
                VX_elastic_buffer #(
                    .DATAW   (DATAW),
                    .SIZE    (`TO_OUT_BUF_SIZE(OUT_BUF)),
                    .OUT_REG (`TO_OUT_BUF_REG(OUT_BUF)),
                    .LUTRAM  (`TO_OUT_BUF_LUTRAM(OUT_BUF))
                ) out_buf (
                    .clk       (clk),
                    .reset     (reset),
                    .valid_in  (valid_out_w[o]),
                    .ready_in  (ready_out_w[o]),
                    .data_in   (data_out_w[o]),
                    .data_out  (data_out[o]),
                    .valid_out (valid_out[o]),
                    .ready_out (ready_out[o])
                );
            end

            for (genvar i = 0; i < NUM_INPUTS; ++i) begin : g_sel_out
                assign sel_out[i] = arb_index;
            end
        end

    end else begin : g_passthru

        // #Inputs == #Outputs

        for (genvar o = 0; o < NUM_OUTPUTS; ++o) begin : g_out_buf
            VX_elastic_buffer #(
                .DATAW   (DATAW),
                .SIZE    (`TO_OUT_BUF_SIZE(OUT_BUF)),
                .OUT_REG (`TO_OUT_BUF_REG(OUT_BUF)),
                .LUTRAM  (`TO_OUT_BUF_LUTRAM(OUT_BUF))
            ) out_buf (
                .clk       (clk),
                .reset     (reset),
                .valid_in  (valid_in[o]),
                .ready_in  (ready_in[o]),
                .data_in   (data_in[o]),
                .data_out  (data_out[o]),
                .valid_out (valid_out[o]),
                .ready_out (ready_out[o])
            );
            assign sel_out[o] = NUM_REQS_W'(0);
        end
    end

endmodule
`TRACING_ON
