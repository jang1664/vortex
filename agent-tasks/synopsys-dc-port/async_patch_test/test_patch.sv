// Smoke test for VX_async_ram_patch: instantiate at the three RTL sites'
// parameters and verify both the SYNOPSYS and non-SYNOPSYS branches elaborate.
//
// Build:
//   vlogan ... +define+SYNTHESIS [+define+SYNOPSYS] ... test_patch.sv
//   vcs    ... test_patch_top
//
// We're checking syntax/elab, not functional behavior.
`include "VX_platform.vh"

module test_patch_top();
    logic clk = 0;
    logic reset = 0;
    always #5 clk = ~clk;

    // L2 FIFO replacement — 2048 x 3, sp, RADDR_REG=1, RDW=R, WRENW=1
    wire [2:0] l2_repl_rdata;
    VX_async_ram_patch #(
        .DATAW       (3),
        .SIZE        (2048),
        .WRENW       (1),
        .DUAL_PORT   (0),
        .FORCE_BRAM  (1),
        .RADDR_REG   (1),
        .RADDR_RESET (0),
        .WRITE_FIRST (0)
    ) u_l2_repl (
        .clk   (clk),
        .reset (reset),
        .read  (1'b1),
        .write (1'b0),
        .wren  (1'b0),
        .waddr (11'd0),
        .wdata (3'd0),
        .raddr (11'd0),
        .rdata (l2_repl_rdata)
    );

    // ICACHE FIFO replacement — 64 x 2, sp, RADDR_REG=1, RDW=R, WRENW=1
    wire [1:0] ic_repl_rdata;
    VX_async_ram_patch #(
        .DATAW       (2),
        .SIZE        (64),
        .WRENW       (1),
        .DUAL_PORT   (0),
        .FORCE_BRAM  (1),
        .RADDR_REG   (1),
        .RADDR_RESET (0),
        .WRITE_FIRST (0)
    ) u_ic_repl (
        .clk   (clk),
        .reset (reset),
        .read  (1'b1),
        .write (1'b0),
        .wren  (1'b0),
        .waddr (6'd0),
        .wdata (2'd0),
        .raddr (6'd0),
        .rdata (ic_repl_rdata)
    );

    // IPDOM stack — 28 x 141, dp, RADDR_REG=1, RDW=R, WRENW=1
    wire [140:0] ipdom_rdata;
    VX_async_ram_patch #(
        .DATAW       (141),
        .SIZE        (28),
        .WRENW       (1),
        .DUAL_PORT   (1),
        .FORCE_BRAM  (1),
        .RADDR_REG   (1),
        .RADDR_RESET (0),
        .WRITE_FIRST (0)
    ) u_ipdom (
        .clk   (clk),
        .reset (reset),
        .read  (1'b1),
        .write (1'b0),
        .wren  (1'b0),
        .waddr (5'd0),
        .wdata (141'd0),
        .raddr (5'd0),
        .rdata (ipdom_rdata)
    );

    initial begin
        #20;
        $display("test_patch elaborated and ran one tick — OK");
        $display("l2_repl_rdata=%b ic_repl_rdata=%b ipdom_rdata[2:0]=%b",
                 l2_repl_rdata, ic_repl_rdata, ipdom_rdata[2:0]);
        $finish;
    end
endmodule
