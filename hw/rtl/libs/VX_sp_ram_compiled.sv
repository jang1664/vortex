// Copyright © 2019-2023
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
// http://www.apache.org/licenses/LICENSE-2.0

`include "VX_platform.vh"

// Single-port sync-read SRAM dispatcher for the Synopsys / Samsung 28LPP flow.
// The (DATAW, SIZE, WRENW) parameters select the macro tile pattern; one
// inventory shape per generate arm. ARM-style ports are active-low CEN/WEN;
// per-byte WRENW maps to bit-WE replicated across each byte.
//
// Test/scan/EMA pins are tied to functional defaults (EMA=3'b010, EMAW=2'b01,
// EMAS=1'b0, TEN=TCEN=TGWEN=1, TWEN/TA/TD=0, SI=SE=0, RET1N=1, DFTRAMBYP=0).
// The SoC top is expected to override EMA/EMAW for the production corner.
//
// See agent-tasks/synopsys-dc-port/sram_inventory.md for the full shape list.
`TRACING_OFF
module VX_sp_ram_compiled #(
    parameter DATAW = 1,
    parameter SIZE  = 1,
    parameter WRENW = 1,
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
    wire ce_n   = ~(read | write);
    wire gwen_n = ~write;

    if (SIZE == 8192 && DATAW == 64 && WRENW == 8) begin : g_8192x64_bwe8
        // LMEM bank — 1 × cmos28lpp_ra1w_hd_8192x64m16
        wire [63:0] wen_n;
        for (genvar i = 0; i < 8; i++) begin : g_byte_wen
            assign wen_n[i*8 +: 8] = {8{~(write & wren[i])}};
        end
        cmos28lpp_ra1w_hd_8192x64m16 u_macro (
            .CLK(clk), .CEN(ce_n), .WEN(wen_n), .GWEN(gwen_n),
            .A(addr), .D(wdata), .Q(rdata),
            .EMA(3'b010), .EMAW(2'b01),
            .TEN(1'b1), .TCEN(1'b1), .TWEN(64'h0), .TA(13'h0), .TD(64'h0), .TGWEN(1'b1),
            .RET1N(1'b1), .SI(2'h0), .SE(1'b0), .DFTRAMBYP(1'b0),
            .CENY(), .WENY(), .AY(), .GWENY(), .SO()
        );
    end else if (SIZE == 4096 && DATAW == 64 && WRENW == 8) begin : g_4096x64_bwe8
        // LMEM bank (16-bank sweep point) — 1 × cmos28lpp_ra1w_hd_4096x64m16
        wire [63:0] wen_n;
        for (genvar i = 0; i < 8; i++) begin : g_byte_wen
            assign wen_n[i*8 +: 8] = {8{~(write & wren[i])}};
        end
        cmos28lpp_ra1w_hd_4096x64m16 u_macro (
            .CLK(clk), .CEN(ce_n), .WEN(wen_n), .GWEN(gwen_n),
            .A(addr), .D(wdata), .Q(rdata),
            .EMA(3'b010), .EMAW(2'b01),
            .TEN(1'b1), .TCEN(1'b1), .TWEN(64'h0), .TA(12'h0), .TD(64'h0), .TGWEN(1'b1),
            .RET1N(1'b1), .SI(2'h0), .SE(1'b0), .DFTRAMBYP(1'b0),
            .CENY(), .WENY(), .AY(), .GWENY(), .SO()
        );
    end else if (SIZE == 2048 && DATAW == 64 && WRENW == 8) begin : g_2048x64_bwe8
        // LMEM bank (32-bank sweep point) — 1 × cmos28lpp_ra1w_hd_2048x64m16
        wire [63:0] wen_n;
        for (genvar i = 0; i < 8; i++) begin : g_byte_wen
            assign wen_n[i*8 +: 8] = {8{~(write & wren[i])}};
        end
        cmos28lpp_ra1w_hd_2048x64m16 u_macro (
            .CLK(clk), .CEN(ce_n), .WEN(wen_n), .GWEN(gwen_n),
            .A(addr), .D(wdata), .Q(rdata),
            .EMA(3'b010), .EMAW(2'b01),
            .TEN(1'b1), .TCEN(1'b1), .TWEN(64'h0), .TA(11'h0), .TD(64'h0), .TGWEN(1'b1),
            .RET1N(1'b1), .SI(2'h0), .SE(1'b0), .DFTRAMBYP(1'b0),
            .CENY(), .WENY(), .AY(), .GWENY(), .SO()
        );
    end else if (SIZE == 1024 && DATAW == 64 && WRENW == 8) begin : g_1024x64_bwe8
        // LMEM bank (64-bank sweep point) — 1 × cmos28lpp_ra1w_hd_1024x64m8
        // (m16 variant fails the ra1_hd compiler — depth+mux combo out of range;
        //  m8 yields 128 rows which is well inside the supported envelope.)
        wire [63:0] wen_n;
        for (genvar i = 0; i < 8; i++) begin : g_byte_wen
            assign wen_n[i*8 +: 8] = {8{~(write & wren[i])}};
        end
        cmos28lpp_ra1w_hd_1024x64m8 u_macro (
            .CLK(clk), .CEN(ce_n), .WEN(wen_n), .GWEN(gwen_n),
            .A(addr), .D(wdata), .Q(rdata),
            .EMA(3'b010), .EMAW(2'b01),
            .TEN(1'b1), .TCEN(1'b1), .TWEN(64'h0), .TA(10'h0), .TD(64'h0), .TGWEN(1'b1),
            .RET1N(1'b1), .SI(2'h0), .SE(1'b0), .DFTRAMBYP(1'b0),
            .CENY(), .WENY(), .AY(), .GWENY(), .SO()
        );
    end else if (SIZE == 2048 && DATAW == 512 && WRENW == 64) begin : g_2048x512_bwe8
        // L2 data — 4 × cmos28lpp_ra1w_hs_2048x128m8 (width tile)
        for (genvar t = 0; t < 4; t++) begin : g_tile
            wire [127:0] wen_n;
            for (genvar i = 0; i < 16; i++) begin : g_byte_wen
                assign wen_n[i*8 +: 8] = {8{~(write & wren[t*16 + i])}};
            end
            cmos28lpp_ra1w_hs_2048x128m8 u_macro (
                .CLK(clk), .CEN(ce_n), .WEN(wen_n), .GWEN(gwen_n),
                .A(addr), .D(wdata[t*128 +: 128]), .Q(rdata[t*128 +: 128]),
                .EMA(3'b010), .EMAW(2'b01), .EMAS(1'b0),
                .TEN(1'b1), .TCEN(1'b1), .TWEN(128'h0), .TA(11'h0), .TD(128'h0), .TGWEN(1'b1),
                .RET1N(1'b1), .SI(2'h0), .SE(1'b0), .DFTRAMBYP(1'b0),
                .CENY(), .WENY(), .AY(), .GWENY(), .SO()
            );
        end
    end else if (SIZE == 512 && DATAW == 512 && WRENW == 64) begin : g_512x512_bwe8
        // DCACHE data (32-bank sweep point) — 4 × cmos28lpp_ra1w_hs_512x128m8 (width tile)
        for (genvar t = 0; t < 4; t++) begin : g_tile
            wire [127:0] wen_n;
            for (genvar i = 0; i < 16; i++) begin : g_byte_wen
                assign wen_n[i*8 +: 8] = {8{~(write & wren[t*16 + i])}};
            end
            cmos28lpp_ra1w_hs_512x128m8 u_macro (
                .CLK(clk), .CEN(ce_n), .WEN(wen_n), .GWEN(gwen_n),
                .A(addr), .D(wdata[t*128 +: 128]), .Q(rdata[t*128 +: 128]),
                .EMA(3'b010), .EMAW(2'b01), .EMAS(1'b0),
                .TEN(1'b1), .TCEN(1'b1), .TWEN(128'h0), .TA(9'h0), .TD(128'h0), .TGWEN(1'b1),
                .RET1N(1'b1), .SI(2'h0), .SE(1'b0), .DFTRAMBYP(1'b0),
                .CENY(), .WENY(), .AY(), .GWENY(), .SO()
            );
        end
    end else if (SIZE == 256 && DATAW == 512 && WRENW == 64) begin : g_256x512_bwe8
        // DCACHE data (64-bank sweep point) — 4 × cmos28lpp_ra1w_hs_256x128m8 (width tile)
        for (genvar t = 0; t < 4; t++) begin : g_tile
            wire [127:0] wen_n;
            for (genvar i = 0; i < 16; i++) begin : g_byte_wen
                assign wen_n[i*8 +: 8] = {8{~(write & wren[t*16 + i])}};
            end
            cmos28lpp_ra1w_hs_256x128m8 u_macro (
                .CLK(clk), .CEN(ce_n), .WEN(wen_n), .GWEN(gwen_n),
                .A(addr), .D(wdata[t*128 +: 128]), .Q(rdata[t*128 +: 128]),
                .EMA(3'b010), .EMAW(2'b01), .EMAS(1'b0),
                .TEN(1'b1), .TCEN(1'b1), .TWEN(128'h0), .TA(8'h0), .TD(128'h0), .TGWEN(1'b1),
                .RET1N(1'b1), .SI(2'h0), .SE(1'b0), .DFTRAMBYP(1'b0),
                .CENY(), .WENY(), .AY(), .GWENY(), .SO()
            );
        end
    end else if (SIZE == 1024 && DATAW == 512 && WRENW == 64) begin : g_1024x512_bwe8
        // TMEM bank — 4 × cmos28lpp_ra1w_hs_1024x128m8 (width tile)
        for (genvar t = 0; t < 4; t++) begin : g_tile
            wire [127:0] wen_n;
            for (genvar i = 0; i < 16; i++) begin : g_byte_wen
                assign wen_n[i*8 +: 8] = {8{~(write & wren[t*16 + i])}};
            end
            cmos28lpp_ra1w_hs_1024x128m8 u_macro (
                .CLK(clk), .CEN(ce_n), .WEN(wen_n), .GWEN(gwen_n),
                .A(addr), .D(wdata[t*128 +: 128]), .Q(rdata[t*128 +: 128]),
                .EMA(3'b010), .EMAW(2'b01), .EMAS(1'b0),
                .TEN(1'b1), .TCEN(1'b1), .TWEN(128'h0), .TA(10'h0), .TD(128'h0), .TGWEN(1'b1),
                .RET1N(1'b1), .SI(2'h0), .SE(1'b0), .DFTRAMBYP(1'b0),
                .CENY(), .WENY(), .AY(), .GWENY(), .SO()
            );
        end
    end else if (SIZE == 64 && DATAW == 512 && WRENW == 1) begin : g_64x512
        // ICACHE data — 4 × cmos28lpp_rf1_hd_64x128m2 (full-word write)
        `UNUSED_VAR (wren)
        for (genvar t = 0; t < 4; t++) begin : g_tile
            cmos28lpp_rf1_hd_64x128m2 u_macro (
                .CLK(clk), .CEN(ce_n), .WEN(gwen_n),
                .A(addr), .D(wdata[t*128 +: 128]), .Q(rdata[t*128 +: 128]),
                .EMA(3'b010), .EMAW(2'b01),
                .TEN(1'b1), .TCEN(1'b1), .TWEN(1'b1), .TA(6'h0), .TD(128'h0),
                .RET1N(1'b1), .SI(2'h0), .SE(1'b0), .DFTRAMBYP(1'b0),
                .CENY(), .WENY(), .AY(), .SO()
            );
        end
    end else if (SIZE == 1024 && DATAW == 1024 && WRENW == 1) begin : g_1024x1024
        // GEMM accumulator — 8 × cmos28lpp_ra1w_hs_1024x128m8 (bit-WE tied to write)
        `UNUSED_VAR (wren)
        for (genvar t = 0; t < 8; t++) begin : g_tile
            cmos28lpp_ra1w_hs_1024x128m8 u_macro (
                .CLK(clk), .CEN(ce_n), .WEN({128{gwen_n}}), .GWEN(gwen_n),
                .A(addr), .D(wdata[t*128 +: 128]), .Q(rdata[t*128 +: 128]),
                .EMA(3'b010), .EMAW(2'b01), .EMAS(1'b0),
                .TEN(1'b1), .TCEN(1'b1), .TWEN(128'h0), .TA(10'h0), .TD(128'h0), .TGWEN(1'b1),
                .RET1N(1'b1), .SI(2'h0), .SE(1'b0), .DFTRAMBYP(1'b0),
                .CENY(), .WENY(), .AY(), .GWENY(), .SO()
            );
        end
    end else begin : g_unsupported
        // No 28LPP macro registered for this shape — fall back to a sync flop array
        // so non-target builds still elaborate. Production builds should add the
        // shape above.
        localparam WSELW = DATAW / WRENW;
        reg [DATAW-1:0] ram [0:SIZE-1];
        reg [DATAW-1:0] rdata_r;
        if (WRENW != 1) begin : g_wren
            always @(posedge clk) begin
                if (write) begin
                    for (integer i = 0; i < WRENW; ++i) begin
                        if (wren[i]) ram[addr][i*WSELW +: WSELW] <= wdata[i*WSELW +: WSELW];
                    end
                end
            end
        end else begin : g_no_wren
            `UNUSED_VAR (wren)
            always @(posedge clk) begin
                if (write) ram[addr] <= wdata;
            end
        end
        always @(posedge clk) if (read) rdata_r <= ram[addr];
        assign rdata = rdata_r;
        `VX_STATIC_ASSERT(0, ("VX_sp_ram_compiled: no 28LPP macro for (DEPTH, DATAW, WRENW); add an arm in VX_sp_ram_compiled.sv"))
    end
endmodule
`TRACING_ON
