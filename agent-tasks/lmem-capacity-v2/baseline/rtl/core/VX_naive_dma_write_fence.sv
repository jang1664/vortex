`include "VX_define.vh"
`ifdef GEMM_NAIVE
// Reserve a whole masked write before the splitter can accept any lane.
// The upstream worker retains payload and descriptor ownership while stalled.
module VX_naive_dma_write_fence #(
    parameter NUM_LANES = `LMEM_NUM_PORTS,
    parameter NUM_BANKS = `LMEM_NUM_BANKS
) (
    input wire clk,
    input wire reset,
    input wire req_valid,
    input wire req_write,
    input wire [NUM_LANES*8-1:0] req_byteen,
    input wire downstream_ready,
    input wire [NUM_BANKS-1:0] commit_valid,
    input wire worker_done_valid,
    input wire frontend_done_ready,
    output wire allow_request,
    output wire drained,
    output wire frontend_done_valid,
    output wire worker_done_ready
);
    logic [11:0] pending_r;
    logic reserved_r;
    wire [NUM_LANES-1:0] active_lanes;
    for (genvar i = 0; i < NUM_LANES; ++i) begin : g_mask
        assign active_lanes[i] = |req_byteen[i*8 +: 8];
    end
    wire [12:0] lane_count = 13'($countones(active_lanes));
    wire [12:0] commit_count = 13'($countones(commit_valid));
    wire credit = ({1'b0, pending_r} + lane_count <= 13'd4095);
    assign allow_request = !req_write || reserved_r || credit;
    wire reserve = req_valid && req_write && !reserved_r && credit;
    wire request_fire = req_valid && allow_request && downstream_ready;
    wire [12:0] available = {1'b0, pending_r} + (reserve ? lane_count : 13'd0);
    wire [12:0] pending_next = available - commit_count;
    assign drained = (pending_r == 0) && !reserved_r && !reserve;
    assign frontend_done_valid = worker_done_valid && drained;
    assign worker_done_ready = frontend_done_ready && drained;
    always_ff @(posedge clk) begin
        if (reset) begin
            pending_r <= '0;
            reserved_r <= 1'b0;
        end else begin
            pending_r <= pending_next[11:0];
            if (request_fire)
                reserved_r <= 1'b0;
            else if (reserve)
                reserved_r <= 1'b1;
`ifndef SYNTHESIS
            assert (commit_count <= available)
                else $fatal(1, "DMA bank commit without reserved owner");
            assert (pending_next <= 13'd4095)
                else $fatal(1, "DMA write fence credit overflow");
`endif
        end
    end
endmodule
`endif
