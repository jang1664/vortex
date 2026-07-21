// Copyright © 2019-2026
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

module xilinx_async_bram_patch_fixture (
    input  wire        clk,
    input  wire        reset,
    input  wire        read,
    input  wire        write,
    input  wire [1:0]  raddr_vector,
    input  wire [1:0]  waddr_vector,
    input  wire        raddr_scalar,
    input  wire        waddr_scalar,
    input  wire [7:0]  wdata,
    output wire [31:0] rdata
);
    reg [1:0] raddr_vector_reset_r;
    reg [1:0] raddr_vector_noreset_r;
    reg       raddr_scalar_noreset_r;

    always @(posedge clk) begin
        if (reset) begin
            raddr_vector_reset_r <= '0;
        end else begin
            raddr_vector_reset_r <= raddr_vector ^ waddr_vector;
        end
        raddr_vector_noreset_r <= raddr_vector ^ waddr_vector;
        raddr_scalar_noreset_r <= raddr_scalar ^ waddr_scalar;
    end

    (* keep_hierarchy = "yes" *) VX_async_ram_patch #(
        .DATAW       (8),
        .SIZE        (4),
        .RADDR_REG   (1),
        .RADDR_RESET (1)
    ) u_reg_vector_reset_no_marker (
        .clk   (clk),
        .reset (reset),
        .read  (read),
        .write (write),
        .wren  (1'b1),
        .waddr (waddr_vector),
        .wdata (wdata),
        .raddr (raddr_vector_reset_r),
        .rdata (rdata[7:0])
    );

    (* keep_hierarchy = "yes" *) VX_async_ram_patch #(
        .DATAW       (8),
        .SIZE        (2),
        .RADDR_REG   (1),
        .RADDR_RESET (0)
    ) u_reg_scalar_noreset_no_marker (
        .clk   (clk),
        .reset (reset),
        .read  (read),
        .write (write),
        .wren  (1'b1),
        .waddr (waddr_scalar),
        .wdata (wdata),
        .raddr (raddr_scalar_noreset_r),
        .rdata (rdata[15:8])
    );

    (* keep_hierarchy = "yes" *) VX_async_ram_patch #(
        .DATAW       (8),
        .SIZE        (4),
        .DUAL_PORT   (1),
        .RADDR_REG   (0),
        .RADDR_RESET (1)
    ) u_async_vector_reset_marker (
        .clk   (clk),
        .reset (reset),
        .read  (read),
        .write (write),
        .wren  (1'b1),
        .waddr (waddr_vector),
        .wdata (wdata),
        .raddr (raddr_vector),
        .rdata (rdata[23:16])
    );

    (* keep_hierarchy = "yes" *) VX_async_ram_patch #(
        .DATAW       (8),
        .SIZE        (4),
        .DUAL_PORT   (1),
        .RADDR_REG   (0),
        .RADDR_RESET (0)
    ) u_reg_vector_noreset_marker (
        .clk   (clk),
        .reset (reset),
        .read  (read),
        .write (write),
        .wren  (1'b1),
        .waddr (waddr_vector),
        .wdata (wdata),
        .raddr (raddr_vector_noreset_r),
        .rdata (rdata[31:24])
    );

endmodule
