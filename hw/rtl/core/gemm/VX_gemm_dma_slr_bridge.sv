`include "VX_define.vh"

// The ordered transport owns an offer at source enqueue, not at backend
// acceptance. PREPARE and its eventual tagged release share this same queue;
// the SLR0 scheduler remains the only priority/chaining arbitration point.
module VX_gemm_dma_slr_bridge import VX_gpu_pkg::*; #(
    parameter `STRING INSTANCE_ID = "",
    parameter int DEPTH = 4
) (
    input wire clk,
    input wire reset,
    VX_gemm_dma_ctrl_if.slave source_if,
    VX_gemm_dma_ctrl_if.master backend_if,
    input wire backend_store_done,
    output wire source_store_done,
    VX_gemm_sync_if.slave backend_sync_if,
    VX_gemm_sync_if.master source_sync_if
);
    localparam int TAG_COUNT = 1 << GEMM_DMA_TAG_WIDTH;
    localparam int OP_WIDTH = 1 + GEMM_DMA_TAG_WIDTH
                               + $bits(gemm_unified_cmd_t);
    localparam int DONE_DEPTH = (TAG_COUNT > 4) ? TAG_COUNT : 4;
    wire op_ready;
    wire op_valid;
    wire op_accept;
    wire op_is_prepare;
    wire [GEMM_DMA_TAG_WIDTH-1:0] op_tag;
    gemm_unified_cmd_t op_cmd;
    wire forward_idle;
    wire completion_idle;
    wire completion_ready;
    wire completion_valid;
    wire [GEMM_DMA_TAG_WIDTH-1:0] completion_tag;
    wire completion_store;
    wire sync_idle;

    VX_slr_stream #(
        .INSTANCE_ID ({INSTANCE_ID, "_commands"}),
        .DATAW (OP_WIDTH),
        .DEPTH (DEPTH)
    ) u_commands (
        .clk (clk),
        .reset (reset),
        .valid_in (source_if.cmd_valid || source_if.prepare_valid),
        .ready_in (op_ready),
        .data_in ({source_if.prepare_valid, source_if.cmd_tag,
                   source_if.prepare_valid ? source_if.prepare_cmd
                                           : source_if.cmd}),
        .valid_out (op_valid),
        .ready_out (op_accept),
        .data_out ({op_is_prepare, op_tag, op_cmd}),
        .idle_out (forward_idle)
    );
    assign source_if.cmd_ready = op_ready && !source_if.prepare_valid;
    assign source_if.prepare_ready = op_ready && !source_if.cmd_valid;
    assign backend_if.start = op_valid && !op_is_prepare;
    assign backend_if.cmd_valid = op_valid && !op_is_prepare;
    assign backend_if.cmd = op_cmd;
    assign backend_if.cmd_tag = op_tag;
    assign backend_if.prepare_valid = op_valid && op_is_prepare;
    assign backend_if.prepare_cmd = op_cmd;
    assign op_accept = op_is_prepare ? backend_if.prepare_ready
                                    : backend_if.cmd_ready;

    // The backend emits at most one logical completion per clock. Its tag
    // remains reserved in SLR1 until this event is consumed. A full tag-set
    // of reverse capacity plus the always-consuming receiver makes these
    // unbackpressurable backend pulses lossless (asserted below).
    VX_slr_stream #(
        .INSTANCE_ID ({INSTANCE_ID, "_completions"}),
        .DATAW (GEMM_DMA_TAG_WIDTH + 1),
        .DEPTH (DONE_DEPTH)
    ) u_completions (
        .clk (clk),
        .reset (reset),
        .valid_in (backend_if.done),
        .ready_in (completion_ready),
        .data_in ({backend_store_done, backend_if.done_tag}),
        .valid_out (completion_valid),
        .ready_out (1'b1),
        .data_out ({completion_store, completion_tag}),
        .idle_out (completion_idle)
    );
    assign source_if.done = completion_valid;
    assign source_if.done_tag = completion_tag;
    assign source_store_done = completion_valid && completion_store;

    // Currently the backend drives this legacy notify interface inactive.
    // Preserve its handshake contract rather than leaving a ready bypass.
    VX_slr_stream #(
        .INSTANCE_ID ({INSTANCE_ID, "_sync"}),
        .DATAW (64),
        .DEPTH (DEPTH)
    ) u_sync (
        .clk (clk),
        .reset (reset),
        .valid_in (backend_sync_if.valid),
        .ready_in (backend_sync_if.ready),
        .data_in ({backend_sync_if.reg_idx, backend_sync_if.value}),
        .valid_out (source_sync_if.valid),
        .ready_out (source_sync_if.ready),
        .data_out ({source_sync_if.reg_idx, source_sync_if.value}),
        .idle_out (sync_idle)
    );

    // Source/destination groups are deliberately separately placeable.
    // Status has no ready handshake: every clock captures a complete level.
    // The local ownership mask below prevents a stale remote idle level from
    // advertising drain while a newly accepted command is still in transit.
    if (1) begin : g_slr0
        (* USER_SLL_REG = "TRUE", SHREG_EXTRACT = "NO", EXTRACT_RESET = "yes" *)
        logic idle_tx_q;
        always_ff @(posedge clk) begin
            if (reset)
                idle_tx_q <= 1'b0;
            else
                idle_tx_q <= backend_if.idle && completion_idle && sync_idle;
        end
    end
    if (1) begin : g_slr1
        (* USER_SLL_REG = "TRUE", SHREG_EXTRACT = "NO", EXTRACT_RESET = "yes" *)
        logic idle_rx_q;
        logic [TAG_COUNT-1:0] owned_tags_q;
        logic prepared_owner_q;
        wire command_enqueue = source_if.cmd_valid && source_if.cmd_ready;
        wire prepare_enqueue = source_if.prepare_valid
                            && source_if.prepare_ready;
        always_ff @(posedge clk) begin
            if (reset) begin
                idle_rx_q <= 1'b0;
                owned_tags_q <= '0;
                prepared_owner_q <= 1'b0;
            end else begin
                idle_rx_q <= g_slr0.idle_tx_q;
                if (completion_valid)
                    owned_tags_q[completion_tag] <= 1'b0;
                if (command_enqueue) begin
                    owned_tags_q[source_if.cmd_tag] <= 1'b1;
                    prepared_owner_q <= 1'b0;
                end
                if (prepare_enqueue)
                    prepared_owner_q <= 1'b1;
            end
        end
        assign source_if.idle = idle_rx_q && forward_idle
                             && !(|owned_tags_q) && !prepared_owner_q
                             && !source_if.cmd_valid
                             && !source_if.prepare_valid;
`ifndef SYNTHESIS
        gemm_unified_cmd_t prepared_cmd_q;
        always_ff @(posedge clk) begin
            if (!reset) begin
                assert (!(source_if.cmd_valid && source_if.prepare_valid))
                    else $fatal(1, "%s: simultaneous prepare and release offer", INSTANCE_ID);
                if (prepare_enqueue) begin
                    assert (!prepared_owner_q)
                        else $fatal(1, "%s: multiple unreleased prepare owners", INSTANCE_ID);
                    prepared_cmd_q <= source_if.prepare_cmd;
                end
                if (command_enqueue) begin
                    assert (!owned_tags_q[source_if.cmd_tag])
                        else $fatal(1, "%s: reused DMA tag before completion", INSTANCE_ID);
                    if (prepared_owner_q)
                        assert (source_if.cmd == prepared_cmd_q)
                            else $fatal(1, "%s: prepare/release identity mismatch", INSTANCE_ID);
                end
                if (completion_valid)
                    assert (owned_tags_q[completion_tag])
                        else $fatal(1, "%s: completion has no source owner", INSTANCE_ID);
            end
        end
`endif
    end
`ifndef SYNTHESIS
    always_ff @(posedge clk) begin
        if (!reset) begin
            assert (!backend_if.done || completion_ready)
                else $fatal(1, "%s: reverse completion capacity exhausted", INSTANCE_ID);
            assert (!backend_store_done || backend_if.done)
                else $fatal(1, "%s: store completion without tagged completion", INSTANCE_ID);
        end
    end
`ifdef DBG_TRACE_GEMM
    always_ff @(posedge clk) begin
        if (!reset && backend_if.done)
            $display("%t: %s DMA SLR backend completion tag=%0d", $time,
                     INSTANCE_ID, backend_if.done_tag);
        if (!reset && source_if.done)
            $display("%t: %s DMA SLR observed completion tag=%0d", $time,
                     INSTANCE_ID, source_if.done_tag);
    end
`endif
`endif
`ifdef CHIPSCOPE
    `UNUSED_SPARAM (INSTANCE_ID)
`endif
endmodule
