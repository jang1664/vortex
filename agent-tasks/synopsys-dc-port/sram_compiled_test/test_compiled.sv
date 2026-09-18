// Smoke test for VX_sp_ram_compiled / VX_dp_ram_compiled wrappers.
// Instantiates every inventory shape and verifies VCS can resolve all
// Samsung 28LPP macros and elaborate cleanly.
//
// Build via run.sh — uses -y per macro directory to resolve macro modules.
`include "VX_platform.vh"

module test_compiled_top();
    logic clk = 0;
    logic reset = 0;
    always #5 clk = ~clk;

    // ---- VX_sp_ram_compiled shapes ----------------------------------------

    // LMEM bank: 8192 x 64, BWE=8
    wire [63:0] q_lmem;
    VX_sp_ram_compiled #(.DATAW(64), .SIZE(8192), .WRENW(8)) u_lmem (
        .clk(clk), .reset(reset), .read(1'b1), .write(1'b0),
        .wren(8'h0), .addr(13'h0), .wdata(64'h0), .rdata(q_lmem)
    );

    // L2 data: 2048 x 512, BWE=64
    wire [511:0] q_l2d;
    VX_sp_ram_compiled #(.DATAW(512), .SIZE(2048), .WRENW(64)) u_l2d (
        .clk(clk), .reset(reset), .read(1'b1), .write(1'b0),
        .wren(64'h0), .addr(11'h0), .wdata(512'h0), .rdata(q_l2d)
    );

    // TMEM bank: 1024 x 512, BWE=64
    wire [511:0] q_tmem;
    VX_sp_ram_compiled #(.DATAW(512), .SIZE(1024), .WRENW(64)) u_tmem (
        .clk(clk), .reset(reset), .read(1'b1), .write(1'b0),
        .wren(64'h0), .addr(10'h0), .wdata(512'h0), .rdata(q_tmem)
    );

    // ICACHE data: 64 x 512, no BWE
    wire [511:0] q_icd;
    VX_sp_ram_compiled #(.DATAW(512), .SIZE(64), .WRENW(1)) u_icd (
        .clk(clk), .reset(reset), .read(1'b1), .write(1'b0),
        .wren(1'b0), .addr(6'h0), .wdata(512'h0), .rdata(q_icd)
    );

    // GEMM accumulator: 1024 x 1024, no BWE
    wire [1023:0] q_acc;
    VX_sp_ram_compiled #(.DATAW(1024), .SIZE(1024), .WRENW(1)) u_acc (
        .clk(clk), .reset(reset), .read(1'b1), .write(1'b0),
        .wren(1'b0), .addr(10'h0), .wdata(1024'h0), .rdata(q_acc)
    );

    // GEMM accumulator (MXU_COL=16): 1024 x 512, no BWE
    wire [511:0] q_acc16;
    VX_sp_ram_compiled #(.DATAW(512), .SIZE(1024), .WRENW(1)) u_acc16 (
        .clk(clk), .reset(reset), .read(1'b1), .write(1'b0),
        .wren(1'b0), .addr(10'h0), .wdata(512'h0), .rdata(q_acc16)
    );

    // TMEM bank (MXU_ROW=16, 32B word): 2048 x 256, BWE=32
    wire [255:0] q_tmem16;
    VX_sp_ram_compiled #(.DATAW(256), .SIZE(2048), .WRENW(32)) u_tmem16 (
        .clk(clk), .reset(reset), .read(1'b1), .write(1'b0),
        .wren(32'h0), .addr(11'h0), .wdata(256'h0), .rdata(q_tmem16)
    );

    // DCACHE data (2-bank point): 64 x 512, BWE=64
    wire [511:0] q_dcd2;
    VX_sp_ram_compiled #(.DATAW(512), .SIZE(64), .WRENW(64)) u_dcd2 (
        .clk(clk), .reset(reset), .read(1'b1), .write(1'b0),
        .wren(64'h0), .addr(6'h0), .wdata(512'h0), .rdata(q_dcd2)
    );

    // ---- VX_dp_ram_compiled shapes ----------------------------------------

    // L2 tag: 2048 x 18, depth-stack
    wire [17:0] q_l2t;
    VX_dp_ram_compiled #(.DATAW(18), .SIZE(2048), .WRENW(1)) u_l2t (
        .clk(clk), .reset(reset), .read(1'b1), .write(1'b0),
        .wren(1'b0), .waddr(11'h0), .wdata(18'h0), .raddr(11'h0), .rdata(q_l2t)
    );

    // ICACHE tag: 64 x 23
    wire [22:0] q_ict;
    VX_dp_ram_compiled #(.DATAW(23), .SIZE(64), .WRENW(1)) u_ict (
        .clk(clk), .reset(reset), .read(1'b1), .write(1'b0),
        .wren(1'b0), .waddr(6'h0), .wdata(23'h0), .raddr(6'h0), .rdata(q_ict)
    );

    // L2 MSHR: 16 x 584
    wire [583:0] q_l2m;
    VX_dp_ram_compiled #(.DATAW(584), .SIZE(16), .WRENW(1)) u_l2m (
        .clk(clk), .reset(reset), .read(1'b1), .write(1'b0),
        .wren(1'b0), .waddr(4'h0), .wdata(584'h0), .raddr(4'h0), .rdata(q_l2m)
    );

    // ICACHE MSHR: 16 x 44
    wire [43:0] q_icm;
    VX_dp_ram_compiled #(.DATAW(44), .SIZE(16), .WRENW(1)) u_icm (
        .clk(clk), .reset(reset), .read(1'b1), .write(1'b0),
        .wren(1'b0), .waddr(4'h0), .wdata(44'h0), .raddr(4'h0), .rdata(q_icm)
    );

    // GPR opc: 64 x 512, BWE=64 (1R1W)
    wire [511:0] q_gpr;
    VX_dp_ram_compiled #(.DATAW(512), .SIZE(64), .WRENW(64)) u_gpr (
        .clk(clk), .reset(reset), .read(1'b1), .write(1'b0),
        .wren(64'h0), .waddr(6'h0), .wdata(512'h0), .raddr(6'h0), .rdata(q_gpr)
    );

    // L2 tag (multi-bank point): 1024 x 18
    wire [17:0] q_l2t2;
    VX_dp_ram_compiled #(.DATAW(18), .SIZE(1024), .WRENW(1)) u_l2t2 (
        .clk(clk), .reset(reset), .read(1'b1), .write(1'b0),
        .wren(1'b0), .waddr(10'h0), .wdata(18'h0), .raddr(10'h0), .rdata(q_l2t2)
    );

    // DCACHE tag (default-size point): 32 x 23
    wire [22:0] q_dct;
    VX_dp_ram_compiled #(.DATAW(23), .SIZE(32), .WRENW(1)) u_dct (
        .clk(clk), .reset(reset), .read(1'b1), .write(1'b0),
        .wren(1'b0), .waddr(5'h0), .wdata(23'h0), .raddr(5'h0), .rdata(q_dct)
    );

    // DCACHE tag (2-bank point): 64 x 22
    wire [21:0] q_dct2;
    VX_dp_ram_compiled #(.DATAW(22), .SIZE(64), .WRENW(1)) u_dct2 (
        .clk(clk), .reset(reset), .read(1'b1), .write(1'b0),
        .wren(1'b0), .waddr(6'h0), .wdata(22'h0), .raddr(6'h0), .rdata(q_dct2)
    );

    // ICACHE tag (32KB point): 128 x 22
    wire [21:0] q_ictt;
    VX_dp_ram_compiled #(.DATAW(22), .SIZE(128), .WRENW(1)) u_ictt (
        .clk(clk), .reset(reset), .read(1'b1), .write(1'b0),
        .wren(1'b0), .waddr(7'h0), .wdata(22'h0), .raddr(7'h0), .rdata(q_ictt)
    );

    // GPR opc (TH16): 64 x 1024, BWE=128 (1R1W)
    wire [1023:0] q_gpr16;
    VX_dp_ram_compiled #(.DATAW(1024), .SIZE(64), .WRENW(128)) u_gpr16 (
        .clk(clk), .reset(reset), .read(1'b1), .write(1'b0),
        .wren(128'h0), .waddr(6'h0), .wdata(1024'h0), .raddr(6'h0), .rdata(q_gpr16)
    );

    // DMA response RAM (naive): 32 x 1024
    wire [1023:0] q_dma32;
    VX_dp_ram_compiled #(.DATAW(1024), .SIZE(32), .WRENW(1)) u_dma32 (
        .clk(clk), .reset(reset), .read(1'b1), .write(1'b0),
        .wren(1'b0), .waddr(5'h0), .wdata(1024'h0), .raddr(5'h0), .rdata(q_dma32)
    );

    // Naive lane-response RAM: 16 x 64
    wire [63:0] q_lane;
    VX_dp_ram_compiled #(.DATAW(64), .SIZE(16), .WRENW(1)) u_lane (
        .clk(clk), .reset(reset), .read(1'b1), .write(1'b0),
        .wren(1'b0), .waddr(4'h0), .wdata(64'h0), .raddr(4'h0), .rdata(q_lane)
    );

    // Naive weight/output response RAM: 16 x 256
    wire [255:0] q_w256;
    VX_dp_ram_compiled #(.DATAW(256), .SIZE(16), .WRENW(1)) u_w256 (
        .clk(clk), .reset(reset), .read(1'b1), .write(1'b0),
        .wren(1'b0), .waddr(4'h0), .wdata(256'h0), .raddr(4'h0), .rdata(q_w256)
    );

    // Improve HBM-DMA response RAM: 8 x 512
    wire [511:0] q_hdma;
    VX_dp_ram_compiled #(.DATAW(512), .SIZE(8), .WRENW(1)) u_hdma (
        .clk(clk), .reset(reset), .read(1'b1), .write(1'b0),
        .wren(1'b0), .waddr(3'h0), .wdata(512'h0), .raddr(3'h0), .rdata(q_hdma)
    );

    // Improve TMEM-DMA response RAM: 8 x 256
    wire [255:0] q_tdma;
    VX_dp_ram_compiled #(.DATAW(256), .SIZE(8), .WRENW(1)) u_tdma (
        .clk(clk), .reset(reset), .read(1'b1), .write(1'b0),
        .wren(1'b0), .waddr(3'h0), .wdata(256'h0), .raddr(3'h0), .rdata(q_tdma)
    );

    initial begin
        #20;
        $display("test_compiled elaborated and ran one tick — OK");
        $finish;
    end
endmodule
