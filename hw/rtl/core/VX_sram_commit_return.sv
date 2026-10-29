`include "VX_define.vh"
`ifdef GEMM_SRAM_FUSION
// Lossless common-clock observations, including zero. This is not a credit
// queue or cumulative watermark. Both stages use the admission counter's
// ORIGINAL global reset epoch, never the delayed feature endpoint reset.
module VX_sram_commit_return #(
    parameter int BANKS = 16,
    parameter int COUNTW = $clog2(BANKS + 1)
) (
    input wire clk,
    input wire reset,
    input wire [BANKS-1:0] valid_i,
    input wire [BANKS-1:0] write_i,
    input wire [BANKS-1:0] dma_source_i,
    output wire [BANKS-1:0] cpu_commits_o,
    output wire [BANKS-1:0] dma_commits_o,
    output wire [COUNTW-1:0] count_o
);
    (* USER_SLL_REG = "TRUE", SHREG_EXTRACT = "NO", EXTRACT_RESET = "yes" *)
    logic [COUNTW-1:0] count_tx_q, count_rx_q;
    // VX_local_mem accepts every write: rw=1 implies physical req_ready=1.
    // The memory asserts that invariant at each offered write.
    assign cpu_commits_o = valid_i & write_i & ~dma_source_i;
    assign dma_commits_o = valid_i & write_i & dma_source_i;
    always_ff @(posedge clk) begin
        if (reset) begin
            count_tx_q <= '0;
            count_rx_q <= '0;
        end else begin
            count_tx_q <= COUNTW'($countones(cpu_commits_o));
            count_rx_q <= count_tx_q;
        end
    end
    assign count_o = count_rx_q;
endmodule
`endif
