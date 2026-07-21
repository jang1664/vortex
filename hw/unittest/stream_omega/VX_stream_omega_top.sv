// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

`include "VX_define.vh"

module VX_stream_omega_top #(
    parameter DATAW = 32
) (
    input wire clk,
    input wire reset,

    input  wire [31:0]             req_valid_in,
    input  wire [31:0][DATAW-1:0]  req_data_in,
    input  wire [31:0][3:0]        req_sel_in,
    output wire [31:0]             req_ready_in,
    output wire [15:0]             req_valid_out,
    output wire [15:0][DATAW-1:0]  req_data_out,
    output wire [15:0][4:0]        req_sel_out,
    input  wire [15:0]             req_ready_out,

    input  wire [15:0]             rsp_valid_in,
    input  wire [15:0][DATAW-1:0]  rsp_data_in,
    input  wire [15:0][4:0]        rsp_sel_in,
    output wire [15:0]             rsp_ready_in,
    output wire [31:0]             rsp_valid_out,
    output wire [31:0][DATAW-1:0]  rsp_data_out,
    output wire [31:0][3:0]        rsp_sel_out,
    input  wire [31:0]             rsp_ready_out
);
    wire [31:0] req_collisions;
    wire [31:0] rsp_collisions;

    VX_stream_omega #(
        .NUM_INPUTS (32),
        .NUM_OUTPUTS(16),
        .RADIX      (2),
        .DATAW      (DATAW),
        .ARBITER    ("P"),
        .OUT_BUF    (3)
    ) req_omega (
        .clk,
        .reset,
        .valid_in  (req_valid_in),
        .data_in   (req_data_in),
        .sel_in    (req_sel_in),
        .ready_in  (req_ready_in),
        .valid_out (req_valid_out),
        .data_out  (req_data_out),
        .sel_out   (req_sel_out),
        .ready_out (req_ready_out),
        .collisions(req_collisions)
    );

    VX_stream_omega #(
        .NUM_INPUTS (16),
        .NUM_OUTPUTS(32),
        .RADIX      (2),
        .DATAW      (DATAW),
        .ARBITER    ("P"),
        .OUT_BUF    (3)
    ) rsp_omega (
        .clk,
        .reset,
        .valid_in  (rsp_valid_in),
        .data_in   (rsp_data_in),
        .sel_in    (rsp_sel_in),
        .ready_in  (rsp_ready_in),
        .valid_out (rsp_valid_out),
        .data_out  (rsp_data_out),
        .sel_out   (rsp_sel_out),
        .ready_out (rsp_ready_out),
        .collisions(rsp_collisions)
    );

    `UNUSED_VAR (req_collisions)
    `UNUSED_VAR (rsp_collisions)
endmodule
