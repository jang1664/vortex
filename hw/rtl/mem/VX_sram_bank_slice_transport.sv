`include "VX_define.vh"
`ifdef GEMM_SRAM_FUSION
// C4 request-bank slice1 (SLR2) -> existing join (SLR1), common clock.
// DATAW includes the original within-slice selector. No extra launch queue:
// the unchanged slice OUT_BUF=3 is already the registered producer.
module VX_sram_bank_slice_transport #(
    parameter int DATAW = 1
) (
    input wire clk,
    input wire reset,
    input wire valid_in,
    output wire ready_in,
    input wire [DATAW-1:0] data_in,
    output wire valid_out,
    input wire ready_out,
    output wire [DATAW-1:0] data_out,
    output wire idle_o
);
    wire [DATAW-1:0] link_data;
    wire link_valid, link_credit;
    wire tx_ready, rx_valid;
    assign ready_in = !reset && tx_ready;
    assign valid_out = !reset && rx_valid;
    VX_slr_stream_tx #(
        .INSTANCE_ID("c4-bank-slice1"), .DATAW(DATAW), .DEPTH(4)
    ) u_tx (
        .clk(clk), .reset(reset),
        .valid_in(valid_in && !reset), .ready_in(tx_ready),
        .data_in(data_in), .link_data(link_data), .link_valid(link_valid),
        .link_credit(link_credit), .idle_out(idle_o)
    );
    VX_slr_stream_rx #(
        .INSTANCE_ID("c4-bank-slice1"), .DATAW(DATAW), .DEPTH(4)
    ) u_rx (
        .clk(clk), .reset(reset),
        .link_data(link_data), .link_valid(link_valid), .link_credit(link_credit),
        .valid_out(rx_valid), .ready_out(ready_out && !reset),
        .data_out(data_out)
    );
`ifndef SYNTHESIS
    always_ff @(posedge clk) begin
        if (reset)
            assert (!ready_in) else $fatal(1, "bank slice accepted while core reset is asserted");
        if (reset)
            assert (!valid_out) else $fatal(1, "bank slice delivered while core reset is asserted");
    end
`endif
endmodule
`endif
