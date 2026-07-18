// Copyright © 2019-2023
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
// http://www.apache.org/licenses/LICENSE-2.0

`include "VX_platform.vh"

// 1R1W sync-read SRAM dispatcher for the Synopsys / Samsung 28LPP flow.
// Port A is wired as the read port and port B as the write port for every
// macro variant: ra2 (full 2RW with WENA tied off), rf2 (1R1W natively),
// rf2w (1R1W with bit-WE on B). ARM tie-offs match VX_sp_ram_compiled.sv.
//
// COLLDISN is tied to 1 (collision detection disabled). All five sites that
// reach this wrapper rely on parent-side invariants that prevent simultaneous
// raddr==waddr collisions, so the macro's collision-handling logic is moot.
//
// See agent-tasks/synopsys-dc-port/sram_inventory.md for the full shape list.
`TRACING_OFF
module VX_dp_ram_compiled #(
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
    input  wire [ADDRW-1:0] waddr,
    input  wire [DATAW-1:0] wdata,
    input  wire [ADDRW-1:0] raddr,
    output wire [DATAW-1:0] rdata
);
    `UNUSED_VAR (reset)

    if (SIZE == 2048 && DATAW == 18 && WRENW == 1) begin : g_2048x18
        // L2 tag — 2 × cmos28lpp_ra2_hd_1024x18m16, depth-stacked on raddr[10]/waddr[10].
        // Macro Q is 1-cycle delayed, so the read-side slice select must be registered.
        `UNUSED_VAR (wren)
        wire ra_top = raddr[10];
        wire wa_top = waddr[10];
        wire [9:0] ra_low = raddr[9:0];
        wire [9:0] wa_low = waddr[9:0];

        wire [17:0] q_lo, q_hi;

        cmos28lpp_ra2_hd_1024x18m16 u_lo (
            .CLKA(clk), .CENA(~(read & ~ra_top)), .WENA(1'b1), .AA(ra_low), .DA(18'h0), .QA(q_lo),
            .CLKB(clk), .CENB(~(write & ~wa_top)), .WENB(1'b0), .AB(wa_low), .DB(wdata), .QB(),
            .EMAA(3'b100), .EMAWA(2'b00), .EMAB(3'b100), .EMAWB(2'b00),
            .TENA(1'b1), .TCENA(1'b1), .TWENA(1'b1), .TAA(10'h0), .TDA(18'h0),
            .TENB(1'b1), .TCENB(1'b1), .TWENB(1'b1), .TAB(10'h0), .TDB(18'h0),
            .RET1N(1'b1), .SIA(2'h0), .SEA(1'b0), .SIB(2'h0), .SEB(1'b0),
            .DFTRAMBYP(1'b0), .COLLDISN(1'b1),
            .CENYA(), .WENYA(), .AYA(), .CENYB(), .WENYB(), .AYB(), .SOA(), .SOB()
        );
        cmos28lpp_ra2_hd_1024x18m16 u_hi (
            .CLKA(clk), .CENA(~(read & ra_top)), .WENA(1'b1), .AA(ra_low), .DA(18'h0), .QA(q_hi),
            .CLKB(clk), .CENB(~(write & wa_top)), .WENB(1'b0), .AB(wa_low), .DB(wdata), .QB(),
            .EMAA(3'b100), .EMAWA(2'b00), .EMAB(3'b100), .EMAWB(2'b00),
            .TENA(1'b1), .TCENA(1'b1), .TWENA(1'b1), .TAA(10'h0), .TDA(18'h0),
            .TENB(1'b1), .TCENB(1'b1), .TWENB(1'b1), .TAB(10'h0), .TDB(18'h0),
            .RET1N(1'b1), .SIA(2'h0), .SEA(1'b0), .SIB(2'h0), .SEB(1'b0),
            .DFTRAMBYP(1'b0), .COLLDISN(1'b1),
            .CENYA(), .WENYA(), .AYA(), .CENYB(), .WENYB(), .AYB(), .SOA(), .SOB()
        );

        reg ra_top_r;
        always @(posedge clk) if (read) ra_top_r <= ra_top;
        assign rdata = ra_top_r ? q_hi : q_lo;
    end else if (SIZE == 8192 && DATAW == 16 && WRENW == 1) begin : g_8192x16
        // DCACHE tag (2-bank sweep point) — 8 × cmos28lpp_ra2_hd_1024x16m16, depth-stacked.
        // PDK FE compiler refuses 4096x16m16/8192x16m16, so we stack 8 of the
        // 1024-deep existing macro. Same Q-delayed mux as g_4096x16, 3 selector bits.
        `UNUSED_VAR (wren)
        wire [2:0] ra_top = raddr[12:10];
        wire [2:0] wa_top = waddr[12:10];
        wire [9:0] ra_low = raddr[9:0];
        wire [9:0] wa_low = waddr[9:0];

        wire [15:0] q [0:7];

        for (genvar s = 0; s < 8; s++) begin : g_slice
            cmos28lpp_ra2_hd_1024x16m16 u_macro (
                .CLKA(clk), .CENA(~(read & (ra_top == s[2:0]))), .WENA(1'b1), .AA(ra_low), .DA(16'h0), .QA(q[s]),
                .CLKB(clk), .CENB(~(write & (wa_top == s[2:0]))), .WENB(1'b0), .AB(wa_low), .DB(wdata), .QB(),
                .EMAA(3'b100), .EMAWA(2'b00), .EMAB(3'b100), .EMAWB(2'b00),
                .TENA(1'b1), .TCENA(1'b1), .TWENA(1'b1), .TAA(10'h0), .TDA(16'h0),
                .TENB(1'b1), .TCENB(1'b1), .TWENB(1'b1), .TAB(10'h0), .TDB(16'h0),
                .RET1N(1'b1), .SIA(2'h0), .SEA(1'b0), .SIB(2'h0), .SEB(1'b0),
                .DFTRAMBYP(1'b0), .COLLDISN(1'b1),
                .CENYA(), .WENYA(), .AYA(), .CENYB(), .WENYB(), .AYB(), .SOA(), .SOB()
            );
        end

        reg [2:0] ra_top_r;
        always @(posedge clk) if (read) ra_top_r <= ra_top;
        assign rdata = q[ra_top_r];
    end else if (SIZE == 4096 && DATAW == 16 && WRENW == 1) begin : g_4096x16
        // DCACHE tag (4-bank sweep point) — 4 × cmos28lpp_ra2_hd_1024x16m16, depth-stacked.
        // Same Q-delayed mux pattern as g_2048x16, extended to 2 selector bits.
        `UNUSED_VAR (wren)
        wire [1:0] ra_top = raddr[11:10];
        wire [1:0] wa_top = waddr[11:10];
        wire [9:0] ra_low = raddr[9:0];
        wire [9:0] wa_low = waddr[9:0];

        wire [15:0] q [0:3];

        for (genvar s = 0; s < 4; s++) begin : g_slice
            cmos28lpp_ra2_hd_1024x16m16 u_macro (
                .CLKA(clk), .CENA(~(read & (ra_top == s[1:0]))), .WENA(1'b1), .AA(ra_low), .DA(16'h0), .QA(q[s]),
                .CLKB(clk), .CENB(~(write & (wa_top == s[1:0]))), .WENB(1'b0), .AB(wa_low), .DB(wdata), .QB(),
                .EMAA(3'b100), .EMAWA(2'b00), .EMAB(3'b100), .EMAWB(2'b00),
                .TENA(1'b1), .TCENA(1'b1), .TWENA(1'b1), .TAA(10'h0), .TDA(16'h0),
                .TENB(1'b1), .TCENB(1'b1), .TWENB(1'b1), .TAB(10'h0), .TDB(16'h0),
                .RET1N(1'b1), .SIA(2'h0), .SEA(1'b0), .SIB(2'h0), .SEB(1'b0),
                .DFTRAMBYP(1'b0), .COLLDISN(1'b1),
                .CENYA(), .WENYA(), .AYA(), .CENYB(), .WENYB(), .AYB(), .SOA(), .SOB()
            );
        end

        reg [1:0] ra_top_r;
        always @(posedge clk) if (read) ra_top_r <= ra_top;
        assign rdata = q[ra_top_r];
    end else if (SIZE == 2048 && DATAW == 16 && WRENW == 1) begin : g_2048x16
        // DCACHE tag (8-bank sweep point) — 2 × cmos28lpp_ra2_hd_1024x16m16, depth-stacked.
        // Same pattern as the existing L2 tag (2048×18): macro Q is 1-cycle delayed,
        // so the read-side slice select must be registered.
        `UNUSED_VAR (wren)
        wire ra_top = raddr[10];
        wire wa_top = waddr[10];
        wire [9:0] ra_low = raddr[9:0];
        wire [9:0] wa_low = waddr[9:0];

        wire [15:0] q_lo, q_hi;

        cmos28lpp_ra2_hd_1024x16m16 u_lo (
            .CLKA(clk), .CENA(~(read & ~ra_top)), .WENA(1'b1), .AA(ra_low), .DA(16'h0), .QA(q_lo),
            .CLKB(clk), .CENB(~(write & ~wa_top)), .WENB(1'b0), .AB(wa_low), .DB(wdata), .QB(),
            .EMAA(3'b100), .EMAWA(2'b00), .EMAB(3'b100), .EMAWB(2'b00),
            .TENA(1'b1), .TCENA(1'b1), .TWENA(1'b1), .TAA(10'h0), .TDA(16'h0),
            .TENB(1'b1), .TCENB(1'b1), .TWENB(1'b1), .TAB(10'h0), .TDB(16'h0),
            .RET1N(1'b1), .SIA(2'h0), .SEA(1'b0), .SIB(2'h0), .SEB(1'b0),
            .DFTRAMBYP(1'b0), .COLLDISN(1'b1),
            .CENYA(), .WENYA(), .AYA(), .CENYB(), .WENYB(), .AYB(), .SOA(), .SOB()
        );
        cmos28lpp_ra2_hd_1024x16m16 u_hi (
            .CLKA(clk), .CENA(~(read & ra_top)), .WENA(1'b1), .AA(ra_low), .DA(16'h0), .QA(q_hi),
            .CLKB(clk), .CENB(~(write & wa_top)), .WENB(1'b0), .AB(wa_low), .DB(wdata), .QB(),
            .EMAA(3'b100), .EMAWA(2'b00), .EMAB(3'b100), .EMAWB(2'b00),
            .TENA(1'b1), .TCENA(1'b1), .TWENA(1'b1), .TAA(10'h0), .TDA(16'h0),
            .TENB(1'b1), .TCENB(1'b1), .TWENB(1'b1), .TAB(10'h0), .TDB(16'h0),
            .RET1N(1'b1), .SIA(2'h0), .SEA(1'b0), .SIB(2'h0), .SEB(1'b0),
            .DFTRAMBYP(1'b0), .COLLDISN(1'b1),
            .CENYA(), .WENYA(), .AYA(), .CENYB(), .WENYB(), .AYB(), .SOA(), .SOB()
        );

        reg ra_top_r;
        always @(posedge clk) if (read) ra_top_r <= ra_top;
        assign rdata = ra_top_r ? q_hi : q_lo;
    end else if (SIZE == 1024 && DATAW == 16 && WRENW == 1) begin : g_1024x16
        // DCACHE tag (16-bank sweep point) — 1 × cmos28lpp_ra2_hd_1024x16m16
        `UNUSED_VAR (wren)
        cmos28lpp_ra2_hd_1024x16m16 u_macro (
            .CLKA(clk), .CENA(~read), .WENA(1'b1), .AA(raddr), .DA(16'h0), .QA(rdata),
            .CLKB(clk), .CENB(~write), .WENB(1'b0), .AB(waddr), .DB(wdata), .QB(),
            .EMAA(3'b100), .EMAWA(2'b00), .EMAB(3'b100), .EMAWB(2'b00),
            .TENA(1'b1), .TCENA(1'b1), .TWENA(1'b1), .TAA(10'h0), .TDA(16'h0),
            .TENB(1'b1), .TCENB(1'b1), .TWENB(1'b1), .TAB(10'h0), .TDB(16'h0),
            .RET1N(1'b1), .SIA(2'h0), .SEA(1'b0), .SIB(2'h0), .SEB(1'b0),
            .DFTRAMBYP(1'b0), .COLLDISN(1'b1),
            .CENYA(), .WENYA(), .AYA(), .CENYB(), .WENYB(), .AYB(), .SOA(), .SOB()
        );
    end else if (SIZE == 512 && DATAW == 16 && WRENW == 1) begin : g_512x16
        // DCACHE tag (32-bank sweep point) — 1 × cmos28lpp_ra2_hd_512x16m16
        `UNUSED_VAR (wren)
        cmos28lpp_ra2_hd_512x16m16 u_macro (
            .CLKA(clk), .CENA(~read), .WENA(1'b1), .AA(raddr), .DA(16'h0), .QA(rdata),
            .CLKB(clk), .CENB(~write), .WENB(1'b0), .AB(waddr), .DB(wdata), .QB(),
            .EMAA(3'b100), .EMAWA(2'b00), .EMAB(3'b100), .EMAWB(2'b00),
            .TENA(1'b1), .TCENA(1'b1), .TWENA(1'b1), .TAA(9'h0), .TDA(16'h0),
            .TENB(1'b1), .TCENB(1'b1), .TWENB(1'b1), .TAB(9'h0), .TDB(16'h0),
            .RET1N(1'b1), .SIA(2'h0), .SEA(1'b0), .SIB(2'h0), .SEB(1'b0),
            .DFTRAMBYP(1'b0), .COLLDISN(1'b1),
            .CENYA(), .WENYA(), .AYA(), .CENYB(), .WENYB(), .AYB(), .SOA(), .SOB()
        );
    end else if (SIZE == 256 && DATAW == 16 && WRENW == 1) begin : g_256x16
        // DCACHE tag (64-bank sweep point) — 1 × cmos28lpp_ra2_hd_256x16m8 (m8 for low row count)
        `UNUSED_VAR (wren)
        cmos28lpp_ra2_hd_256x16m8 u_macro (
            .CLKA(clk), .CENA(~read), .WENA(1'b1), .AA(raddr), .DA(16'h0), .QA(rdata),
            .CLKB(clk), .CENB(~write), .WENB(1'b0), .AB(waddr), .DB(wdata), .QB(),
            .EMAA(3'b100), .EMAWA(2'b00), .EMAB(3'b100), .EMAWB(2'b00),
            .TENA(1'b1), .TCENA(1'b1), .TWENA(1'b1), .TAA(8'h0), .TDA(16'h0),
            .TENB(1'b1), .TCENB(1'b1), .TWENB(1'b1), .TAB(8'h0), .TDB(16'h0),
            .RET1N(1'b1), .SIA(2'h0), .SEA(1'b0), .SIB(2'h0), .SEB(1'b0),
            .DFTRAMBYP(1'b0), .COLLDISN(1'b1),
            .CENYA(), .WENYA(), .AYA(), .CENYB(), .WENYB(), .AYB(), .SOA(), .SOB()
        );
    end else if (SIZE == 64 && DATAW == 23 && WRENW == 1) begin : g_64x23
        // ICACHE tag — 1 × cmos28lpp_ra2_hd_64x23m4
        `UNUSED_VAR (wren)
        cmos28lpp_ra2_hd_64x23m4 u_macro (
            .CLKA(clk), .CENA(~read), .WENA(1'b1), .AA(raddr), .DA(23'h0), .QA(rdata),
            .CLKB(clk), .CENB(~write), .WENB(1'b0), .AB(waddr), .DB(wdata), .QB(),
            .EMAA(3'b100), .EMAWA(2'b00), .EMAB(3'b100), .EMAWB(2'b00),
            .TENA(1'b1), .TCENA(1'b1), .TWENA(1'b1), .TAA(6'h0), .TDA(23'h0),
            .TENB(1'b1), .TCENB(1'b1), .TWENB(1'b1), .TAB(6'h0), .TDB(23'h0),
            .RET1N(1'b1), .SIA(2'h0), .SEA(1'b0), .SIB(2'h0), .SEB(1'b0),
            .DFTRAMBYP(1'b0), .COLLDISN(1'b1),
            .CENYA(), .WENYA(), .AYA(), .CENYB(), .WENYB(), .AYB(), .SOA(), .SOB()
        );
    end else if (SIZE == 4 && DATAW == 1024 && WRENW == 1) begin : g_4x1024
        // DMA response RAM — 6 × 4x160 + 1 × 4x64 RF2 macros, width-tiled.
        `UNUSED_VAR (wren)
        for (genvar t = 0; t < 6; t++) begin : g_tile
            cmos28lpp_rf2_hd_4x160m1 u_macro (
                .CLKA(clk), .CENA(~read), .AA(raddr),
                .CLKB(clk), .CENB(~write), .AB(waddr), .DB(wdata[t*160 +: 160]),
                .QA(rdata[t*160 +: 160]),
                .EMAA(3'b100), .EMAB(3'b100),
                .TENA(1'b1), .TCENA(1'b1), .TAA(2'h0),
                .TENB(1'b1), .TCENB(1'b1), .TAB(2'h0), .TDB(160'h0),
                .RET1N(1'b1), .SIA(2'h0), .SEA(1'b0), .SIB(2'h0), .SEB(1'b0),
                .DFTRAMBYP(1'b0), .COLLDISN(1'b1),
                .CENYA(), .AYA(), .CENYB(), .AYB(), .SOA(), .SOB()
            );
        end
        cmos28lpp_rf2_hd_4x64m1 u_tail (
            .CLKA(clk), .CENA(~read), .AA(raddr),
            .CLKB(clk), .CENB(~write), .AB(waddr), .DB(wdata[960 +: 64]),
            .QA(rdata[960 +: 64]),
            .EMAA(3'b100), .EMAB(3'b100),
            .TENA(1'b1), .TCENA(1'b1), .TAA(2'h0),
            .TENB(1'b1), .TCENB(1'b1), .TAB(2'h0), .TDB(64'h0),
            .RET1N(1'b1), .SIA(2'h0), .SEA(1'b0), .SIB(2'h0), .SEB(1'b0),
            .DFTRAMBYP(1'b0), .COLLDISN(1'b1),
            .CENYA(), .AYA(), .CENYB(), .AYB(), .SOA(), .SOB()
        );
    end else if (SIZE == 8 && DATAW == 1024 && WRENW == 1) begin : g_8x1024
        // DMA response RAM — 6 × 8x160 + 1 × 8x64 RF2 macros, width-tiled.
        `UNUSED_VAR (wren)
        for (genvar t = 0; t < 6; t++) begin : g_tile
            cmos28lpp_rf2_hd_8x160m1 u_macro (
                .CLKA(clk), .CENA(~read), .AA(raddr),
                .CLKB(clk), .CENB(~write), .AB(waddr), .DB(wdata[t*160 +: 160]),
                .QA(rdata[t*160 +: 160]),
                .EMAA(3'b100), .EMAB(3'b100),
                .TENA(1'b1), .TCENA(1'b1), .TAA(3'h0),
                .TENB(1'b1), .TCENB(1'b1), .TAB(3'h0), .TDB(160'h0),
                .RET1N(1'b1), .SIA(2'h0), .SEA(1'b0), .SIB(2'h0), .SEB(1'b0),
                .DFTRAMBYP(1'b0), .COLLDISN(1'b1),
                .CENYA(), .AYA(), .CENYB(), .AYB(), .SOA(), .SOB()
            );
        end
        cmos28lpp_rf2_hd_8x64m1 u_tail (
            .CLKA(clk), .CENA(~read), .AA(raddr),
            .CLKB(clk), .CENB(~write), .AB(waddr), .DB(wdata[960 +: 64]),
            .QA(rdata[960 +: 64]),
            .EMAA(3'b100), .EMAB(3'b100),
            .TENA(1'b1), .TCENA(1'b1), .TAA(3'h0),
            .TENB(1'b1), .TCENB(1'b1), .TAB(3'h0), .TDB(64'h0),
            .RET1N(1'b1), .SIA(2'h0), .SEA(1'b0), .SIB(2'h0), .SEB(1'b0),
            .DFTRAMBYP(1'b0), .COLLDISN(1'b1),
            .CENYA(), .AYA(), .CENYB(), .AYB(), .SOA(), .SOB()
        );
    end else if (SIZE == 16 && DATAW == 1024 && WRENW == 1) begin : g_16x1024
        // DMA response RAM — 6 × 16x160 + 1 × 16x64 RF2 macros, width-tiled.
        `UNUSED_VAR (wren)
        for (genvar t = 0; t < 6; t++) begin : g_tile
            cmos28lpp_rf2_hd_16x160m1 u_macro (
                .CLKA(clk), .CENA(~read), .AA(raddr),
                .CLKB(clk), .CENB(~write), .AB(waddr), .DB(wdata[t*160 +: 160]),
                .QA(rdata[t*160 +: 160]),
                .EMAA(3'b100), .EMAB(3'b100),
                .TENA(1'b1), .TCENA(1'b1), .TAA(4'h0),
                .TENB(1'b1), .TCENB(1'b1), .TAB(4'h0), .TDB(160'h0),
                .RET1N(1'b1), .SIA(2'h0), .SEA(1'b0), .SIB(2'h0), .SEB(1'b0),
                .DFTRAMBYP(1'b0), .COLLDISN(1'b1),
                .CENYA(), .AYA(), .CENYB(), .AYB(), .SOA(), .SOB()
            );
        end
        cmos28lpp_rf2_hd_16x64m1 u_tail (
            .CLKA(clk), .CENA(~read), .AA(raddr),
            .CLKB(clk), .CENB(~write), .AB(waddr), .DB(wdata[960 +: 64]),
            .QA(rdata[960 +: 64]),
            .EMAA(3'b100), .EMAB(3'b100),
            .TENA(1'b1), .TCENA(1'b1), .TAA(4'h0),
            .TENB(1'b1), .TCENB(1'b1), .TAB(4'h0), .TDB(64'h0),
            .RET1N(1'b1), .SIA(2'h0), .SEA(1'b0), .SIB(2'h0), .SEB(1'b0),
            .DFTRAMBYP(1'b0), .COLLDISN(1'b1),
            .CENYA(), .AYA(), .CENYB(), .AYB(), .SOA(), .SOB()
        );
    end else if (SIZE == 16 && DATAW == 584 && WRENW == 1) begin : g_16x584
        // L2 MSHR — 4 × cmos28lpp_rf2_hd_16x146m1 (1R1W, no WEN)
        `UNUSED_VAR (wren)
        for (genvar t = 0; t < 4; t++) begin : g_tile
            cmos28lpp_rf2_hd_16x146m1 u_macro (
                .CLKA(clk), .CENA(~read), .AA(raddr),
                .CLKB(clk), .CENB(~write), .AB(waddr), .DB(wdata[t*146 +: 146]),
                .QA(rdata[t*146 +: 146]),
                .EMAA(3'b100), .EMAB(3'b100),
                .TENA(1'b1), .TCENA(1'b1), .TAA(4'h0),
                .TENB(1'b1), .TCENB(1'b1), .TAB(4'h0), .TDB(146'h0),
                .RET1N(1'b1), .SIA(2'h0), .SEA(1'b0), .SIB(2'h0), .SEB(1'b0),
                .DFTRAMBYP(1'b0), .COLLDISN(1'b1),
                .CENYA(), .AYA(), .CENYB(), .AYB(), .SOA(), .SOB()
            );
        end
    end else if (SIZE == 16 && DATAW == 44 && WRENW == 1) begin : g_16x44
        // ICACHE MSHR — 1 × cmos28lpp_rf2_hd_16x44m1
        `UNUSED_VAR (wren)
        cmos28lpp_rf2_hd_16x44m1 u_macro (
            .CLKA(clk), .CENA(~read), .AA(raddr),
            .CLKB(clk), .CENB(~write), .AB(waddr), .DB(wdata),
            .QA(rdata),
            .EMAA(3'b100), .EMAB(3'b100),
            .TENA(1'b1), .TCENA(1'b1), .TAA(4'h0),
            .TENB(1'b1), .TCENB(1'b1), .TAB(4'h0), .TDB(44'h0),
            .RET1N(1'b1), .SIA(2'h0), .SEA(1'b0), .SIB(2'h0), .SEB(1'b0),
            .DFTRAMBYP(1'b0), .COLLDISN(1'b1),
            .CENYA(), .AYA(), .CENYB(), .AYB(), .SOA(), .SOB()
        );
    end else if (SIZE == 64 && DATAW == 512 && WRENW == 64) begin : g_64x512_bwe8
        // GPR opc — 4 × cmos28lpp_rf2w_hd_64x128m1 (1R1W with bit-WE on port B)
        for (genvar t = 0; t < 4; t++) begin : g_tile
            wire [127:0] wen_n;
            for (genvar i = 0; i < 16; i++) begin : g_byte_wen
                assign wen_n[i*8 +: 8] = {8{~(write & wren[t*16 + i])}};
            end
            cmos28lpp_rf2w_hd_64x128m1 u_macro (
                .CLKA(clk), .CENA(~read), .AA(raddr),
                .CLKB(clk), .CENB(~write), .AB(waddr), .DB(wdata[t*128 +: 128]), .WENB(wen_n),
                .QA(rdata[t*128 +: 128]),
                .EMAA(3'b100), .EMAB(3'b100),
                .TENA(1'b1), .TCENA(1'b1), .TAA(6'h0),
                .TENB(1'b1), .TCENB(1'b1), .TAB(6'h0), .TDB(128'h0), .TWENB(128'h0),
                .RET1N(1'b1), .SIA(2'h0), .SEA(1'b0), .SIB(2'h0), .SEB(1'b0),
                .DFTRAMBYP(1'b0), .COLLDISN(1'b1),
                .CENYA(), .AYA(), .CENYB(), .WENYB(), .AYB(), .SOA(), .SOB()
            );
        end
    end else begin : g_unsupported
        localparam WSELW = DATAW / WRENW;
        reg [DATAW-1:0] ram [0:SIZE-1];
        reg [DATAW-1:0] rdata_r;
        if (WRENW != 1) begin : g_wren
            always @(posedge clk) begin
                if (write) begin
                    for (integer i = 0; i < WRENW; ++i) begin
                        if (wren[i]) ram[waddr][i*WSELW +: WSELW] <= wdata[i*WSELW +: WSELW];
                    end
                end
            end
        end else begin : g_no_wren
            `UNUSED_VAR (wren)
            always @(posedge clk) begin
                if (write) ram[waddr] <= wdata;
            end
        end
        always @(posedge clk) if (read) rdata_r <= ram[raddr];
        assign rdata = rdata_r;
        `VX_STATIC_ASSERT(0, ("VX_dp_ram_compiled: no 28LPP macro for (DEPTH, DATAW, WRENW); add an arm in VX_dp_ram_compiled.sv"))
    end
endmodule
`TRACING_ON
