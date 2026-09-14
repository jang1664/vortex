`ifdef GEMM_NAIVE
`ifdef GEMM_SLR_PIPELINE
`include "VX_define.vh"
// Same-clock boundary between the SLR0 DMA node and SLR1 memory/control.
// Each physical LMEM lane crosses after the DMA's aggregate-beat splitter.
module VX_naive_dma_slr import VX_gpu_pkg::*; #(
    parameter `STRING INSTANCE_ID = "",
    parameter int N_MASTER = `NUM_LSU_BLOCKS + 1,
    parameter int NUM_LANES = `LMEM_NUM_PORTS
) (
    input wire clk,
    input wire reset,
    VX_lsu_mem_if.slave mmio_up[N_MASTER],
    VX_lsu_mem_if.master mmio_down[N_MASTER],
    VX_mem_bus_if.slave lmem_up[NUM_LANES],
    VX_mem_bus_if.master lmem_down[NUM_LANES],
    VX_mem_bus_if.slave global_up,
    VX_mem_bus_if.master global_down,
    input wire [`LMEM_NUM_BANKS-1:0][2:0] commit_in,
    output wire [`LMEM_NUM_BANKS-1:0][2:0] commit_out,
    output wire requests_drained
`ifdef PERF_ENABLE
    ,input dma_perf_t perf_in
    ,output dma_perf_t perf_out
`endif
);
    for (genvar m = 0; m < N_MASTER; ++m) begin : g_mmio
        VX_stream_transport #(
            .INSTANCE_ID ({INSTANCE_ID, ":mmio_request"}),
            .DATAW ($bits(mmio_up[m].req_data)), .DEPTH (4),
            .SLR_ENABLE (1), .LAUNCH_DEPTH (0)
        ) u_request (
            .clk (clk), .reset (reset),
            .valid_in (mmio_up[m].req_valid), .ready_in (mmio_up[m].req_ready),
            .data_in (mmio_up[m].req_data),
            .valid_out (mmio_down[m].req_valid), .ready_out (mmio_down[m].req_ready),
            .data_out (mmio_down[m].req_data), .idle_out ()
        );
        VX_stream_transport #(
            .INSTANCE_ID ({INSTANCE_ID, ":mmio_response"}),
            .DATAW ($bits(mmio_up[m].rsp_data)), .DEPTH (4),
            .SLR_ENABLE (1), .LAUNCH_DEPTH (0)
        ) u_response (
            .clk (clk), .reset (reset),
            .valid_in (mmio_down[m].rsp_valid), .ready_in (mmio_down[m].rsp_ready),
            .data_in (mmio_down[m].rsp_data),
            .valid_out (mmio_up[m].rsp_valid), .ready_out (mmio_up[m].rsp_ready),
            .data_out (mmio_up[m].rsp_data), .idle_out ()
        );
    end
    wire [NUM_LANES-1:0] lmem_idle;
    wire [NUM_LANES-1:0] lmem_offer;
    wire global_idle;
    for (genvar l = 0; l < NUM_LANES; ++l) begin : g_lmem
        VX_slr_mem_bus #(
            .INSTANCE_ID ({INSTANCE_ID, ":lmem"}), .DEPTH (4),
            .SLR_ENABLE (1), .REQUEST_LAUNCH_DEPTH (0)
        ) u_transport (
            .clk (clk), .reset (reset),
            .upstream_if (lmem_up[l]), .downstream_if (lmem_down[l]),
            .side_in (1'b0), .side_out (), .request_idle (lmem_idle[l])
        );
        assign lmem_offer[l] = lmem_up[l].req_valid;
    end
    VX_slr_mem_bus #(
        .INSTANCE_ID ({INSTANCE_ID, ":global"}), .DEPTH (4),
        .SLR_ENABLE (1), .REQUEST_LAUNCH_DEPTH (0)
    ) u_global (
        .clk (clk), .reset (reset),
        .upstream_if (global_up), .downstream_if (global_down),
        .side_in (1'b0), .side_out (), .request_idle (global_idle)
    );
    // idle counts requests through downstream acceptance and returned credit.
    // Also exclude an active offer that has not yet acquired transport credit.
    assign requests_drained = (&lmem_idle) && !(|lmem_offer)
                           && global_idle && !global_up.req_valid;

    if (1) begin : g_commit
        wire [`LMEM_NUM_BANKS-1:0] decoded;
        for (genvar b = 0; b < `LMEM_NUM_BANKS; ++b) begin : g_bank
            assign decoded[b] = commit_in[b][2:1] == 2'b11;
            assign commit_out[b] = {g_slr0.payload_rx_q[b], g_slr0.payload_rx_q[b], 1'b0};
        end
        if (1) begin : g_slr1
            (* USER_SLL_REG = "TRUE", SHREG_EXTRACT = "NO", EXTRACT_RESET = "yes" *)
            logic [`LMEM_NUM_BANKS-1:0] payload_tx_q;
            always_ff @(posedge clk) begin
                if (reset) payload_tx_q <= '0;
                else payload_tx_q <= decoded;
            end
        end
        if (1) begin : g_slr0
            (* USER_SLL_REG = "TRUE", SHREG_EXTRACT = "NO", EXTRACT_RESET = "yes" *)
            logic [`LMEM_NUM_BANKS-1:0] payload_rx_q;
            always_ff @(posedge clk) begin
                if (reset) payload_rx_q <= '0;
                else payload_rx_q <= g_slr1.payload_tx_q;
            end
        end
    end
`ifdef PERF_ENABLE
    if (1) begin : g_perf
        if (1) begin : g_slr0
            (* USER_SLL_REG = "TRUE", SHREG_EXTRACT = "NO", EXTRACT_RESET = "yes" *)
            dma_perf_t payload_tx_q;
            always_ff @(posedge clk) begin
                if (reset) payload_tx_q <= '0;
                else payload_tx_q <= perf_in;
            end
        end
        if (1) begin : g_slr1
            (* USER_SLL_REG = "TRUE", SHREG_EXTRACT = "NO", EXTRACT_RESET = "yes" *)
            dma_perf_t payload_rx_q;
            always_ff @(posedge clk) begin
                if (reset) payload_rx_q <= '0;
                else payload_rx_q <= g_slr0.payload_tx_q;
            end
        end
        assign perf_out = g_slr1.payload_rx_q;
    end
`endif
endmodule
`endif
`endif
