// Copyright © 2019-2023
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
// http://www.apache.org/licenses/LICENSE-2.0

`include "VX_platform.vh"

// Single-port sync-read SRAM dispatcher for the Synopsys / Samsung 28LPP flow.
// The (DATAW, SIZE, WRENW, SRAM_TYPE) parameters select the macro tile pattern;
// one inventory shape per generate arm. ARM-style ports are active-low CEN/WEN;
// per-byte WRENW maps to bit-WE replicated across each byte.
//
// Test/scan/EMA pins are tied to functional defaults (EMA=3'b100, EMAW=2'b00,
// EMAS=1'b0, TEN=TCEN=TGWEN=1, TWEN/TA/TD=0, SI=SE=0, RET1N=1, DFTRAMBYP=0).
// EMA=3'b100 is the lowest value with non-placeholder CLK->Q timing at the
// SS 0p900v 125c MAX corner; lower values are 999.0 placeholders in the
// ARM .lib (uncharacterized at low voltage). Matches FICIM sram_bank.sv.
//
// See agent-tasks/synopsys-dc-port/sram_inventory.md for the full shape list.
`TRACING_OFF
module VX_sp_ram_compiled #(
    parameter DATAW = 1,
    parameter SIZE  = 1,
    parameter WRENW = 1,
    parameter `STRING SRAM_TYPE = "HS",
    parameter ADDRW = `LOG2UP(SIZE)
) (
    input  wire             clk,
    input  wire             reset,
    input  wire             read,
    input  wire             write,
    input  wire [WRENW-1:0] wren,
    input  wire [ADDRW-1:0] addr,
    input  wire [DATAW-1:0] wdata,
    output wire [DATAW-1:0] rdata
);
    `UNUSED_VAR (reset)
    `VX_STATIC_ASSERT((SRAM_TYPE == "HS" || SRAM_TYPE == "HD"), ("invalid SRAM_TYPE"))
    wire ce_n   = ~(read | write);
    wire gwen_n = ~write;

    if (SRAM_TYPE != "HS" && SRAM_TYPE != "HD") begin : g_invalid_sram_type
        `UNUSED_VAR ({clk, ce_n, gwen_n, wren, addr, wdata})
        assign rdata = 'x;
        VX_sp_ram_compiled_invalid_sram_type u_invalid_sram_type ();
    end else if (SIZE == 8192 && DATAW == 64 && WRENW == 8) begin : g_8192x64_bwe8
        // LMEM bank — 1 × native 8192x64 macro
        wire [63:0] wen_n;
        for (genvar i = 0; i < 8; i++) begin : g_byte_wen
            assign wen_n[i*8 +: 8] = {8{~(write & wren[i])}};
        end
        if (SRAM_TYPE == "HS") begin : g_hs
            cmos28lpp_ra1w_hs_8192x64m16 u_macro (
                .CLK(clk), .CEN(ce_n), .WEN(wen_n), .GWEN(gwen_n),
                .A(addr), .D(wdata), .Q(rdata),
                .EMA(3'b100), .EMAW(2'b00), .EMAS(1'b0),
                .TEN(1'b1), .TCEN(1'b1), .TWEN(64'h0), .TA(13'h0), .TD(64'h0), .TGWEN(1'b1),
                .RET1N(1'b1), .SI(2'h0), .SE(1'b0), .DFTRAMBYP(1'b0),
                .CENY(), .WENY(), .AY(), .GWENY(), .SO()
            );
        end else begin : g_hd
            cmos28lpp_ra1w_hd_8192x64m16 u_macro (
                .CLK(clk), .CEN(ce_n), .WEN(wen_n), .GWEN(gwen_n),
                .A(addr), .D(wdata), .Q(rdata),
                .EMA(3'b100), .EMAW(2'b00),
                .TEN(1'b1), .TCEN(1'b1), .TWEN(64'h0), .TA(13'h0), .TD(64'h0), .TGWEN(1'b1),
                .RET1N(1'b1), .SI(2'h0), .SE(1'b0), .DFTRAMBYP(1'b0),
                .CENY(), .WENY(), .AY(), .GWENY(), .SO()
            );
        end
    end else if (SIZE == 4096 && DATAW == 64 && WRENW == 8) begin : g_4096x64_bwe8
        // LMEM bank (16-bank sweep point) — 1 × native 4096x64 macro
        wire [63:0] wen_n;
        for (genvar i = 0; i < 8; i++) begin : g_byte_wen
            assign wen_n[i*8 +: 8] = {8{~(write & wren[i])}};
        end
        if (SRAM_TYPE == "HS") begin : g_hs
            cmos28lpp_ra1w_hs_4096x64m8 u_macro (
                .CLK(clk), .CEN(ce_n), .WEN(wen_n), .GWEN(gwen_n),
                .A(addr), .D(wdata), .Q(rdata),
                .EMA(3'b100), .EMAW(2'b00), .EMAS(1'b0),
                .TEN(1'b1), .TCEN(1'b1), .TWEN(64'h0), .TA(12'h0), .TD(64'h0), .TGWEN(1'b1),
                .RET1N(1'b1), .SI(2'h0), .SE(1'b0), .DFTRAMBYP(1'b0),
                .CENY(), .WENY(), .AY(), .GWENY(), .SO()
            );
        end else begin : g_hd
            cmos28lpp_ra1w_hd_4096x64m16 u_macro (
                .CLK(clk), .CEN(ce_n), .WEN(wen_n), .GWEN(gwen_n),
                .A(addr), .D(wdata), .Q(rdata),
                .EMA(3'b100), .EMAW(2'b00),
                .TEN(1'b1), .TCEN(1'b1), .TWEN(64'h0), .TA(12'h0), .TD(64'h0), .TGWEN(1'b1),
                .RET1N(1'b1), .SI(2'h0), .SE(1'b0), .DFTRAMBYP(1'b0),
                .CENY(), .WENY(), .AY(), .GWENY(), .SO()
            );
        end
    end else if (SIZE == 2048 && DATAW == 64 && WRENW == 8) begin : g_2048x64_bwe8
        // LMEM bank (32-bank sweep point) — 1 × native 2048x64 macro
        wire [63:0] wen_n;
        for (genvar i = 0; i < 8; i++) begin : g_byte_wen
            assign wen_n[i*8 +: 8] = {8{~(write & wren[i])}};
        end
        if (SRAM_TYPE == "HS") begin : g_hs
            cmos28lpp_ra1w_hs_2048x64m8 u_macro (
                .CLK(clk), .CEN(ce_n), .WEN(wen_n), .GWEN(gwen_n),
                .A(addr), .D(wdata), .Q(rdata),
                .EMA(3'b100), .EMAW(2'b00), .EMAS(1'b0),
                .TEN(1'b1), .TCEN(1'b1), .TWEN(64'h0), .TA(11'h0), .TD(64'h0), .TGWEN(1'b1),
                .RET1N(1'b1), .SI(2'h0), .SE(1'b0), .DFTRAMBYP(1'b0),
                .CENY(), .WENY(), .AY(), .GWENY(), .SO()
            );
        end else begin : g_hd
            cmos28lpp_ra1w_hd_2048x64m16 u_macro (
                .CLK(clk), .CEN(ce_n), .WEN(wen_n), .GWEN(gwen_n),
                .A(addr), .D(wdata), .Q(rdata),
                .EMA(3'b100), .EMAW(2'b00),
                .TEN(1'b1), .TCEN(1'b1), .TWEN(64'h0), .TA(11'h0), .TD(64'h0), .TGWEN(1'b1),
                .RET1N(1'b1), .SI(2'h0), .SE(1'b0), .DFTRAMBYP(1'b0),
                .CENY(), .WENY(), .AY(), .GWENY(), .SO()
            );
        end
    end else if (SIZE == 1024 && DATAW == 64 && WRENW == 8) begin : g_1024x64_bwe8
        // LMEM bank (64-bank sweep point) — 1 × native 1024x64 macro
        wire [63:0] wen_n;
        for (genvar i = 0; i < 8; i++) begin : g_byte_wen
            assign wen_n[i*8 +: 8] = {8{~(write & wren[i])}};
        end
        if (SRAM_TYPE == "HS") begin : g_hs
            cmos28lpp_ra1w_hs_1024x64m8 u_macro (
                .CLK(clk), .CEN(ce_n), .WEN(wen_n), .GWEN(gwen_n),
                .A(addr), .D(wdata), .Q(rdata),
                .EMA(3'b100), .EMAW(2'b00), .EMAS(1'b0),
                .TEN(1'b1), .TCEN(1'b1), .TWEN(64'h0), .TA(10'h0), .TD(64'h0), .TGWEN(1'b1),
                .RET1N(1'b1), .SI(2'h0), .SE(1'b0), .DFTRAMBYP(1'b0),
                .CENY(), .WENY(), .AY(), .GWENY(), .SO()
            );
        end else begin : g_hd
            cmos28lpp_ra1w_hd_1024x64m8 u_macro (
                .CLK(clk), .CEN(ce_n), .WEN(wen_n), .GWEN(gwen_n),
                .A(addr), .D(wdata), .Q(rdata),
                .EMA(3'b100), .EMAW(2'b00),
                .TEN(1'b1), .TCEN(1'b1), .TWEN(64'h0), .TA(10'h0), .TD(64'h0), .TGWEN(1'b1),
                .RET1N(1'b1), .SI(2'h0), .SE(1'b0), .DFTRAMBYP(1'b0),
                .CENY(), .WENY(), .AY(), .GWENY(), .SO()
            );
        end
    end else if (SIZE == 8192 && DATAW == 512 && WRENW == 64) begin : g_8192x512_bwe8
        if (SRAM_TYPE == "HS") begin : g_hs
            // Four width tiles, each composed from two depth-stacked 4096x128 macros.
            wire        addr_top = addr[12];
            wire [11:0] addr_low = addr[11:0];
            for (genvar t = 0; t < 4; t++) begin : g_tile
                wire [127:0] wen_n;
                for (genvar i = 0; i < 16; i++) begin : g_byte_wen
                    assign wen_n[i*8 +: 8] = {8{~(write & wren[t*16 + i])}};
                end
                wire ce_n_lo = ce_n |  addr_top;
                wire ce_n_hi = ce_n | ~addr_top;
                wire [127:0] q_lo, q_hi;

                cmos28lpp_ra1w_hs_4096x128m8 u_lo (
                    .CLK(clk), .CEN(ce_n_lo), .WEN(wen_n), .GWEN(gwen_n),
                    .A(addr_low), .D(wdata[t*128 +: 128]), .Q(q_lo),
                    .EMA(3'b100), .EMAW(2'b00), .EMAS(1'b0),
                    .TEN(1'b1), .TCEN(1'b1), .TWEN(128'h0), .TA(12'h0), .TD(128'h0), .TGWEN(1'b1),
                    .RET1N(1'b1), .SI(2'h0), .SE(1'b0), .DFTRAMBYP(1'b0),
                    .CENY(), .WENY(), .AY(), .GWENY(), .SO()
                );
                cmos28lpp_ra1w_hs_4096x128m8 u_hi (
                    .CLK(clk), .CEN(ce_n_hi), .WEN(wen_n), .GWEN(gwen_n),
                    .A(addr_low), .D(wdata[t*128 +: 128]), .Q(q_hi),
                    .EMA(3'b100), .EMAW(2'b00), .EMAS(1'b0),
                    .TEN(1'b1), .TCEN(1'b1), .TWEN(128'h0), .TA(12'h0), .TD(128'h0), .TGWEN(1'b1),
                    .RET1N(1'b1), .SI(2'h0), .SE(1'b0), .DFTRAMBYP(1'b0),
                    .CENY(), .WENY(), .AY(), .GWENY(), .SO()
                );

                reg addr_top_r;
                always @(posedge clk) if (read) addr_top_r <= addr_top;
                assign rdata[t*128 +: 128] = addr_top_r ? q_hi : q_lo;
            end
        end else begin : g_hd
            // Eight native-depth 8192x64 width tiles.
            for (genvar t = 0; t < 8; t++) begin : g_tile
                wire [63:0] wen_n;
                for (genvar i = 0; i < 8; i++) begin : g_byte_wen
                    assign wen_n[i*8 +: 8] = {8{~(write & wren[t*8 + i])}};
                end
                cmos28lpp_ra1w_hd_8192x64m16 u_macro (
                    .CLK(clk), .CEN(ce_n), .WEN(wen_n), .GWEN(gwen_n),
                    .A(addr), .D(wdata[t*64 +: 64]), .Q(rdata[t*64 +: 64]),
                    .EMA(3'b100), .EMAW(2'b00),
                    .TEN(1'b1), .TCEN(1'b1), .TWEN(64'h0), .TA(13'h0), .TD(64'h0), .TGWEN(1'b1),
                    .RET1N(1'b1), .SI(2'h0), .SE(1'b0), .DFTRAMBYP(1'b0),
                    .CENY(), .WENY(), .AY(), .GWENY(), .SO()
                );
            end
        end
    end else if (SIZE == 4096 && DATAW == 512 && WRENW == 64) begin : g_4096x512_bwe8
        if (SRAM_TYPE == "HS") begin : g_hs
            for (genvar t = 0; t < 4; t++) begin : g_tile
                wire [127:0] wen_n;
                for (genvar i = 0; i < 16; i++) begin : g_byte_wen
                    assign wen_n[i*8 +: 8] = {8{~(write & wren[t*16 + i])}};
                end
                cmos28lpp_ra1w_hs_4096x128m8 u_macro (
                    .CLK(clk), .CEN(ce_n), .WEN(wen_n), .GWEN(gwen_n),
                    .A(addr), .D(wdata[t*128 +: 128]), .Q(rdata[t*128 +: 128]),
                    .EMA(3'b100), .EMAW(2'b00), .EMAS(1'b0),
                    .TEN(1'b1), .TCEN(1'b1), .TWEN(128'h0), .TA(12'h0), .TD(128'h0), .TGWEN(1'b1),
                    .RET1N(1'b1), .SI(2'h0), .SE(1'b0), .DFTRAMBYP(1'b0),
                    .CENY(), .WENY(), .AY(), .GWENY(), .SO()
                );
            end
        end else begin : g_hd
            for (genvar t = 0; t < 8; t++) begin : g_tile
                wire [63:0] wen_n;
                for (genvar i = 0; i < 8; i++) begin : g_byte_wen
                    assign wen_n[i*8 +: 8] = {8{~(write & wren[t*8 + i])}};
                end
                cmos28lpp_ra1w_hd_4096x64m16 u_macro (
                    .CLK(clk), .CEN(ce_n), .WEN(wen_n), .GWEN(gwen_n),
                    .A(addr), .D(wdata[t*64 +: 64]), .Q(rdata[t*64 +: 64]),
                    .EMA(3'b100), .EMAW(2'b00),
                    .TEN(1'b1), .TCEN(1'b1), .TWEN(64'h0), .TA(12'h0), .TD(64'h0), .TGWEN(1'b1),
                    .RET1N(1'b1), .SI(2'h0), .SE(1'b0), .DFTRAMBYP(1'b0),
                    .CENY(), .WENY(), .AY(), .GWENY(), .SO()
                );
            end
        end
    end else if (SIZE == 2048 && DATAW == 512 && WRENW == 64) begin : g_2048x512_bwe8
        if (SRAM_TYPE == "HS") begin : g_hs
            for (genvar t = 0; t < 4; t++) begin : g_tile
                wire [127:0] wen_n;
                for (genvar i = 0; i < 16; i++) begin : g_byte_wen
                    assign wen_n[i*8 +: 8] = {8{~(write & wren[t*16 + i])}};
                end
                cmos28lpp_ra1w_hs_2048x128m8 u_macro (
                    .CLK(clk), .CEN(ce_n), .WEN(wen_n), .GWEN(gwen_n),
                    .A(addr), .D(wdata[t*128 +: 128]), .Q(rdata[t*128 +: 128]),
                    .EMA(3'b100), .EMAW(2'b00), .EMAS(1'b0),
                    .TEN(1'b1), .TCEN(1'b1), .TWEN(128'h0), .TA(11'h0), .TD(128'h0), .TGWEN(1'b1),
                    .RET1N(1'b1), .SI(2'h0), .SE(1'b0), .DFTRAMBYP(1'b0),
                    .CENY(), .WENY(), .AY(), .GWENY(), .SO()
                );
            end
        end else begin : g_hd
            for (genvar t = 0; t < 8; t++) begin : g_tile
                wire [63:0] wen_n;
                for (genvar i = 0; i < 8; i++) begin : g_byte_wen
                    assign wen_n[i*8 +: 8] = {8{~(write & wren[t*8 + i])}};
                end
                cmos28lpp_ra1w_hd_2048x64m16 u_macro (
                    .CLK(clk), .CEN(ce_n), .WEN(wen_n), .GWEN(gwen_n),
                    .A(addr), .D(wdata[t*64 +: 64]), .Q(rdata[t*64 +: 64]),
                    .EMA(3'b100), .EMAW(2'b00),
                    .TEN(1'b1), .TCEN(1'b1), .TWEN(64'h0), .TA(11'h0), .TD(64'h0), .TGWEN(1'b1),
                    .RET1N(1'b1), .SI(2'h0), .SE(1'b0), .DFTRAMBYP(1'b0),
                    .CENY(), .WENY(), .AY(), .GWENY(), .SO()
                );
            end
        end
    end else if (SIZE == 512 && DATAW == 512 && WRENW == 64) begin : g_512x512_bwe8
        if (SRAM_TYPE == "HS") begin : g_hs
            for (genvar t = 0; t < 4; t++) begin : g_tile
                wire [127:0] wen_n;
                for (genvar i = 0; i < 16; i++) begin : g_byte_wen
                    assign wen_n[i*8 +: 8] = {8{~(write & wren[t*16 + i])}};
                end
                cmos28lpp_ra1w_hs_512x128m8 u_macro (
                    .CLK(clk), .CEN(ce_n), .WEN(wen_n), .GWEN(gwen_n),
                    .A(addr), .D(wdata[t*128 +: 128]), .Q(rdata[t*128 +: 128]),
                    .EMA(3'b100), .EMAW(2'b00), .EMAS(1'b0),
                    .TEN(1'b1), .TCEN(1'b1), .TWEN(128'h0), .TA(9'h0), .TD(128'h0), .TGWEN(1'b1),
                    .RET1N(1'b1), .SI(2'h0), .SE(1'b0), .DFTRAMBYP(1'b0),
                    .CENY(), .WENY(), .AY(), .GWENY(), .SO()
                );
            end
        end else begin : g_hd
            for (genvar t = 0; t < 8; t++) begin : g_tile
                wire [63:0] wen_n;
                for (genvar i = 0; i < 8; i++) begin : g_byte_wen
                    assign wen_n[i*8 +: 8] = {8{~(write & wren[t*8 + i])}};
                end
                cmos28lpp_ra1w_hd_1024x64m8 u_macro (
                    .CLK(clk), .CEN(ce_n), .WEN(wen_n), .GWEN(gwen_n),
                    .A({1'b0, addr}), .D(wdata[t*64 +: 64]), .Q(rdata[t*64 +: 64]),
                    .EMA(3'b100), .EMAW(2'b00),
                    .TEN(1'b1), .TCEN(1'b1), .TWEN(64'h0), .TA(10'h0), .TD(64'h0), .TGWEN(1'b1),
                    .RET1N(1'b1), .SI(2'h0), .SE(1'b0), .DFTRAMBYP(1'b0),
                    .CENY(), .WENY(), .AY(), .GWENY(), .SO()
                );
            end
        end
    end else if (SIZE == 256 && DATAW == 512 && WRENW == 64) begin : g_256x512_bwe8
        if (SRAM_TYPE == "HS") begin : g_hs
            for (genvar t = 0; t < 4; t++) begin : g_tile
                wire [127:0] wen_n;
                for (genvar i = 0; i < 16; i++) begin : g_byte_wen
                    assign wen_n[i*8 +: 8] = {8{~(write & wren[t*16 + i])}};
                end
                cmos28lpp_ra1w_hs_256x128m8 u_macro (
                    .CLK(clk), .CEN(ce_n), .WEN(wen_n), .GWEN(gwen_n),
                    .A(addr), .D(wdata[t*128 +: 128]), .Q(rdata[t*128 +: 128]),
                    .EMA(3'b100), .EMAW(2'b00), .EMAS(1'b0),
                    .TEN(1'b1), .TCEN(1'b1), .TWEN(128'h0), .TA(8'h0), .TD(128'h0), .TGWEN(1'b1),
                    .RET1N(1'b1), .SI(2'h0), .SE(1'b0), .DFTRAMBYP(1'b0),
                    .CENY(), .WENY(), .AY(), .GWENY(), .SO()
                );
            end
        end else begin : g_hd
            for (genvar t = 0; t < 8; t++) begin : g_tile
                wire [63:0] wen_n;
                for (genvar i = 0; i < 8; i++) begin : g_byte_wen
                    assign wen_n[i*8 +: 8] = {8{~(write & wren[t*8 + i])}};
                end
                cmos28lpp_ra1w_hd_1024x64m8 u_macro (
                    .CLK(clk), .CEN(ce_n), .WEN(wen_n), .GWEN(gwen_n),
                    .A({2'b0, addr}), .D(wdata[t*64 +: 64]), .Q(rdata[t*64 +: 64]),
                    .EMA(3'b100), .EMAW(2'b00),
                    .TEN(1'b1), .TCEN(1'b1), .TWEN(64'h0), .TA(10'h0), .TD(64'h0), .TGWEN(1'b1),
                    .RET1N(1'b1), .SI(2'h0), .SE(1'b0), .DFTRAMBYP(1'b0),
                    .CENY(), .WENY(), .AY(), .GWENY(), .SO()
                );
            end
        end
    end else if (SIZE == 128 && DATAW == 512 && WRENW == 1) begin : g_128x512
        `UNUSED_VAR (wren)
        if (SRAM_TYPE == "HS") begin : g_hs
            for (genvar t = 0; t < 4; t++) begin : g_tile
                cmos28lpp_ra1w_hs_256x128m8 u_macro (
                    .CLK(clk), .CEN(ce_n), .WEN({128{gwen_n}}), .GWEN(gwen_n),
                    .A({1'b0, addr}), .D(wdata[t*128 +: 128]), .Q(rdata[t*128 +: 128]),
                    .EMA(3'b100), .EMAW(2'b00), .EMAS(1'b0),
                    .TEN(1'b1), .TCEN(1'b1), .TWEN(128'h0), .TA(8'h0), .TD(128'h0), .TGWEN(1'b1),
                    .RET1N(1'b1), .SI(2'h0), .SE(1'b0), .DFTRAMBYP(1'b0),
                    .CENY(), .WENY(), .AY(), .GWENY(), .SO()
                );
            end
        end else begin : g_hd
            for (genvar t = 0; t < 8; t++) begin : g_tile
                cmos28lpp_ra1w_hd_1024x64m8 u_macro (
                    .CLK(clk), .CEN(ce_n), .WEN({64{gwen_n}}), .GWEN(gwen_n),
                    .A({3'b0, addr}), .D(wdata[t*64 +: 64]), .Q(rdata[t*64 +: 64]),
                    .EMA(3'b100), .EMAW(2'b00),
                    .TEN(1'b1), .TCEN(1'b1), .TWEN(64'h0), .TA(10'h0), .TD(64'h0), .TGWEN(1'b1),
                    .RET1N(1'b1), .SI(2'h0), .SE(1'b0), .DFTRAMBYP(1'b0),
                    .CENY(), .WENY(), .AY(), .GWENY(), .SO()
                );
            end
        end
    end else if (SIZE == 32 && DATAW == 512 && WRENW == 64) begin : g_32x512_bwe8
        if (SRAM_TYPE == "HS") begin : g_hs
            for (genvar t = 0; t < 4; t++) begin : g_tile
                wire [127:0] wen_n;
                for (genvar i = 0; i < 16; i++) begin : g_byte_wen
                    assign wen_n[i*8 +: 8] = {8{~(write & wren[t*16 + i])}};
                end
                cmos28lpp_ra1w_hs_256x128m8 u_macro (
                    .CLK(clk), .CEN(ce_n), .WEN(wen_n), .GWEN(gwen_n),
                    .A({3'b0, addr}), .D(wdata[t*128 +: 128]), .Q(rdata[t*128 +: 128]),
                    .EMA(3'b100), .EMAW(2'b00), .EMAS(1'b0),
                    .TEN(1'b1), .TCEN(1'b1), .TWEN(128'h0), .TA(8'h0), .TD(128'h0), .TGWEN(1'b1),
                    .RET1N(1'b1), .SI(2'h0), .SE(1'b0), .DFTRAMBYP(1'b0),
                    .CENY(), .WENY(), .AY(), .GWENY(), .SO()
                );
            end
        end else begin : g_hd
            for (genvar t = 0; t < 8; t++) begin : g_tile
                wire [63:0] wen_n;
                for (genvar i = 0; i < 8; i++) begin : g_byte_wen
                    assign wen_n[i*8 +: 8] = {8{~(write & wren[t*8 + i])}};
                end
                cmos28lpp_ra1w_hd_1024x64m8 u_macro (
                    .CLK(clk), .CEN(ce_n), .WEN(wen_n), .GWEN(gwen_n),
                    .A({5'b0, addr}), .D(wdata[t*64 +: 64]), .Q(rdata[t*64 +: 64]),
                    .EMA(3'b100), .EMAW(2'b00),
                    .TEN(1'b1), .TCEN(1'b1), .TWEN(64'h0), .TA(10'h0), .TD(64'h0), .TGWEN(1'b1),
                    .RET1N(1'b1), .SI(2'h0), .SE(1'b0), .DFTRAMBYP(1'b0),
                    .CENY(), .WENY(), .AY(), .GWENY(), .SO()
                );
            end
        end
    end else if (SIZE == 1024 && DATAW == 512 && WRENW == 64) begin : g_1024x512_bwe8
        if (SRAM_TYPE == "HS") begin : g_hs
            for (genvar t = 0; t < 4; t++) begin : g_tile
                wire [127:0] wen_n;
                for (genvar i = 0; i < 16; i++) begin : g_byte_wen
                    assign wen_n[i*8 +: 8] = {8{~(write & wren[t*16 + i])}};
                end
                cmos28lpp_ra1w_hs_1024x128m8 u_macro (
                    .CLK(clk), .CEN(ce_n), .WEN(wen_n), .GWEN(gwen_n),
                    .A(addr), .D(wdata[t*128 +: 128]), .Q(rdata[t*128 +: 128]),
                    .EMA(3'b100), .EMAW(2'b00), .EMAS(1'b0),
                    .TEN(1'b1), .TCEN(1'b1), .TWEN(128'h0), .TA(10'h0), .TD(128'h0), .TGWEN(1'b1),
                    .RET1N(1'b1), .SI(2'h0), .SE(1'b0), .DFTRAMBYP(1'b0),
                    .CENY(), .WENY(), .AY(), .GWENY(), .SO()
                );
            end
        end else begin : g_hd
            for (genvar t = 0; t < 8; t++) begin : g_tile
                wire [63:0] wen_n;
                for (genvar i = 0; i < 8; i++) begin : g_byte_wen
                    assign wen_n[i*8 +: 8] = {8{~(write & wren[t*8 + i])}};
                end
                cmos28lpp_ra1w_hd_1024x64m8 u_macro (
                    .CLK(clk), .CEN(ce_n), .WEN(wen_n), .GWEN(gwen_n),
                    .A(addr), .D(wdata[t*64 +: 64]), .Q(rdata[t*64 +: 64]),
                    .EMA(3'b100), .EMAW(2'b00),
                    .TEN(1'b1), .TCEN(1'b1), .TWEN(64'h0), .TA(10'h0), .TD(64'h0), .TGWEN(1'b1),
                    .RET1N(1'b1), .SI(2'h0), .SE(1'b0), .DFTRAMBYP(1'b0),
                    .CENY(), .WENY(), .AY(), .GWENY(), .SO()
                );
            end
        end
    end else if (SIZE == 64 && DATAW == 512 && WRENW == 1) begin : g_64x512
        // ICACHE data — four native 64x128 RF1 width tiles.
        `UNUSED_VAR (wren)
        if (SRAM_TYPE == "HS") begin : g_hs
            for (genvar t = 0; t < 4; t++) begin : g_tile
                cmos28lpp_rf1_hs_64x128m2 u_macro (
                    .CLK(clk), .CEN(ce_n), .WEN(gwen_n),
                    .A(addr), .D(wdata[t*128 +: 128]), .Q(rdata[t*128 +: 128]),
                    .EMA(3'b100), .EMAW(2'b00), .EMAS(1'b0),
                    .TEN(1'b1), .TCEN(1'b1), .TWEN(1'b1), .TA(6'h0), .TD(128'h0),
                    .RET1N(1'b1), .SI(2'h0), .SE(1'b0), .DFTRAMBYP(1'b0),
                    .CENY(), .WENY(), .AY(), .SO()
                );
            end
        end else begin : g_hd
            for (genvar t = 0; t < 4; t++) begin : g_tile
                cmos28lpp_rf1_hd_64x128m2 u_macro (
                    .CLK(clk), .CEN(ce_n), .WEN(gwen_n),
                    .A(addr), .D(wdata[t*128 +: 128]), .Q(rdata[t*128 +: 128]),
                    .EMA(3'b100), .EMAW(2'b00),
                    .TEN(1'b1), .TCEN(1'b1), .TWEN(1'b1), .TA(6'h0), .TD(128'h0),
                    .RET1N(1'b1), .SI(2'h0), .SE(1'b0), .DFTRAMBYP(1'b0),
                    .CENY(), .WENY(), .AY(), .SO()
                );
            end
        end
    end else if (SIZE == 1024 && DATAW == 1024 && WRENW == 1) begin : g_1024x1024
        `UNUSED_VAR (wren)
        if (SRAM_TYPE == "HS") begin : g_hs
            for (genvar t = 0; t < 8; t++) begin : g_tile
                cmos28lpp_ra1w_hs_1024x128m8 u_macro (
                    .CLK(clk), .CEN(ce_n), .WEN({128{gwen_n}}), .GWEN(gwen_n),
                    .A(addr), .D(wdata[t*128 +: 128]), .Q(rdata[t*128 +: 128]),
                    .EMA(3'b100), .EMAW(2'b00), .EMAS(1'b0),
                    .TEN(1'b1), .TCEN(1'b1), .TWEN(128'h0), .TA(10'h0), .TD(128'h0), .TGWEN(1'b1),
                    .RET1N(1'b1), .SI(2'h0), .SE(1'b0), .DFTRAMBYP(1'b0),
                    .CENY(), .WENY(), .AY(), .GWENY(), .SO()
                );
            end
        end else begin : g_hd
            for (genvar t = 0; t < 16; t++) begin : g_tile
                cmos28lpp_ra1w_hd_1024x64m8 u_macro (
                    .CLK(clk), .CEN(ce_n), .WEN({64{gwen_n}}), .GWEN(gwen_n),
                    .A(addr), .D(wdata[t*64 +: 64]), .Q(rdata[t*64 +: 64]),
                    .EMA(3'b100), .EMAW(2'b00),
                    .TEN(1'b1), .TCEN(1'b1), .TWEN(64'h0), .TA(10'h0), .TD(64'h0), .TGWEN(1'b1),
                    .RET1N(1'b1), .SI(2'h0), .SE(1'b0), .DFTRAMBYP(1'b0),
                    .CENY(), .WENY(), .AY(), .GWENY(), .SO()
                );
            end
        end
    end else if (SIZE == 512 && DATAW == 1024 && WRENW == 1) begin : g_512x1024
        `UNUSED_VAR (wren)
        if (SRAM_TYPE == "HS") begin : g_hs
            for (genvar t = 0; t < 8; t++) begin : g_tile
                cmos28lpp_ra1w_hs_512x128m8 u_macro (
                    .CLK(clk), .CEN(ce_n), .WEN({128{gwen_n}}), .GWEN(gwen_n),
                    .A(addr), .D(wdata[t*128 +: 128]), .Q(rdata[t*128 +: 128]),
                    .EMA(3'b100), .EMAW(2'b00), .EMAS(1'b0),
                    .TEN(1'b1), .TCEN(1'b1), .TWEN(128'h0), .TA(9'h0), .TD(128'h0), .TGWEN(1'b1),
                    .RET1N(1'b1), .SI(2'h0), .SE(1'b0), .DFTRAMBYP(1'b0),
                    .CENY(), .WENY(), .AY(), .GWENY(), .SO()
                );
            end
        end else begin : g_hd
            for (genvar t = 0; t < 16; t++) begin : g_tile
                cmos28lpp_ra1w_hd_1024x64m8 u_macro (
                    .CLK(clk), .CEN(ce_n), .WEN({64{gwen_n}}), .GWEN(gwen_n),
                    .A({1'b0, addr}), .D(wdata[t*64 +: 64]), .Q(rdata[t*64 +: 64]),
                    .EMA(3'b100), .EMAW(2'b00),
                    .TEN(1'b1), .TCEN(1'b1), .TWEN(64'h0), .TA(10'h0), .TD(64'h0), .TGWEN(1'b1),
                    .RET1N(1'b1), .SI(2'h0), .SE(1'b0), .DFTRAMBYP(1'b0),
                    .CENY(), .WENY(), .AY(), .GWENY(), .SO()
                );
            end
        end
    end else begin : g_unsupported
        // Unsupported compiled-SRAM shapes must not turn into standard-cell storage.
        `UNUSED_VAR ({clk, ce_n, gwen_n, wren, addr, wdata})
        assign rdata = 'x;
        `VX_STATIC_ASSERT(0, ("VX_sp_ram_compiled: no 28LPP macro for (DEPTH, DATAW, WRENW); add an arm in VX_sp_ram_compiled.sv"))
        VX_sp_ram_compiled_unsupported_shape u_unsupported_shape ();
    end
endmodule
`TRACING_ON
