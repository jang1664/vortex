`include "VX_define.vh"
`ifdef GEMM_SRAM_FUSION
// TX plus operational state belongs to SLR1; RX and the complete source
// ownership combiner belong to SLR0. Offers are real source buffer valid
// bits, so queued work remains visible before link ownership is registered.
module VX_sram_busy_export #(
    parameter int SOURCES = 2
) (
    input wire clk,
    input wire source_reset,
    input wire destination_reset,
    input wire operational_busy_i,
    input wire [SOURCES-1:0] source_owned_i,
    input wire [SOURCES-1:0] source_offer_i,
    output wire busy_o
);
    (* USER_SLL_REG = "TRUE", SHREG_EXTRACT = "NO", EXTRACT_RESET = "yes" *)
    logic busy_tx_q, busy_rx_q;
    always_ff @(posedge clk) begin
        if (destination_reset) busy_tx_q <= 1'b0;
        else busy_tx_q <= operational_busy_i;
        if (source_reset) busy_rx_q <= 1'b0;
        else busy_rx_q <= busy_tx_q;
    end
    assign busy_o = busy_rx_q || (|source_owned_i) || (|source_offer_i);
endmodule
`endif
