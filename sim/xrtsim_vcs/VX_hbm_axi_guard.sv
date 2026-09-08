// Simulation-only checks shared by the production TB and directed tests.
module VX_hbm_axi_guard #(
    parameter integer DATA_BYTES = 64,
    parameter integer ADDR_WIDTH = 64,
    parameter integer ID_WIDTH = 32
) (
    input wire clk,
    input wire reset_n,
    input wire arvalid, arready,
    input wire [ADDR_WIDTH-1:0] araddr,
    input wire [7:0] arlen,
    input wire [2:0] arsize,
    input wire [1:0] arburst,
    input wire awvalid, awready,
    input wire [ADDR_WIDTH-1:0] awaddr,
    input wire [7:0] awlen,
    input wire [2:0] awsize,
    input wire [1:0] awburst,
    input wire rvalid, rready,
    input wire [ID_WIDTH-1:0] rid,
    input wire [DATA_BYTES*8-1:0] rdata,
    input wire rlast,
    input wire bvalid, bready,
    input wire [ID_WIDTH-1:0] bid
);
    localparam integer R_WIDTH = ID_WIDTH + DATA_BYTES*8 + 1;
    reg r_held, b_held;
    reg [R_WIDTH-1:0] saved_r;
    reg [ID_WIDTH-1:0] saved_b;

    always @(posedge clk) begin
        if (!reset_n) begin
            r_held <= 0;
            b_held <= 0;
        end else begin
            if (arvalid && arready) begin
                if (arsize !== $clog2(DATA_BYTES) || arburst !== 2'b01
                    || (araddr % DATA_BYTES) != 0
                    || (int'(araddr[11:0]) + (int'(arlen)+1)*DATA_BYTES > 4096))
                    $fatal(1, "HBM_GUARD_AR: unsupported or boundary-crossing burst");
            end
            if (awvalid && awready) begin
                if (awsize !== $clog2(DATA_BYTES) || awburst !== 2'b01
                    || (awaddr % DATA_BYTES) != 0
                    || (int'(awaddr[11:0]) + (int'(awlen)+1)*DATA_BYTES > 4096))
                    $fatal(1, "HBM_GUARD_AW: unsupported or boundary-crossing burst");
            end
            if (r_held && (!rvalid || {rid, rdata, rlast} !== saved_r))
                $fatal(1, "HBM_GUARD_R: stalled response changed");
            if (b_held && (!bvalid || bid !== saved_b))
                $fatal(1, "HBM_GUARD_B: stalled response changed");
            r_held <= rvalid && !rready;
            b_held <= bvalid && !bready;
            saved_r <= {rid, rdata, rlast};
            saved_b <= bid;
        end
    end
endmodule
