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

    initial begin
        #20;
        $display("test_compiled elaborated and ran one tick — OK");
        $finish;
    end
endmodule
