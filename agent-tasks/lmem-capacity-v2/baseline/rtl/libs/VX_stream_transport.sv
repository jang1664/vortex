`include "VX_define.vh"

// One local launch stage followed by an optional, credit-safe SLR link.
// Launch capacity and crossing credits are independent. LAUNCH_DEPTH=0
// preserves direct local response/write paths without adding storage.
module VX_stream_transport #(
    parameter `STRING INSTANCE_ID = "",
    parameter int DATAW = 1,
    parameter int LAUNCH_DEPTH = 1,
    parameter bit SLR_ENABLE = 1'b0,
    parameter int DEPTH = 4,
    parameter bit PRESERVE_TX_PAYLOAD = 1'b0,
    parameter int PRESERVE_TX_PAYLOAD_LSB = 0
) (
    input wire clk,
    input wire reset,
    input wire valid_in,
    output wire ready_in,
    input wire [DATAW-1:0] data_in,
    output wire valid_out,
    input wire ready_out,
    output wire [DATAW-1:0] data_out,
    output wire idle_out
);
    wire launch_valid;
    wire launch_ready;
    wire [DATAW-1:0] launch_data;
    wire crossing_idle;

    `VX_STATIC_ASSERT(LAUNCH_DEPTH >= 0 && LAUNCH_DEPTH <= 2,
                   ("stream transport supports launch depth 0, 1, or 2"))

    VX_elastic_buffer #(
        .DATAW (DATAW),
        .SIZE (LAUNCH_DEPTH),
        .OUT_REG (1),
        .LUTRAM (0)
    ) u_launch (
        .clk (clk), .reset (reset),
        .valid_in (valid_in), .ready_in (ready_in), .data_in (data_in),
        .valid_out (launch_valid), .ready_out (launch_ready),
        .data_out (launch_data)
    );

    if (SLR_ENABLE) begin : g_slr
        VX_slr_stream #(
            .INSTANCE_ID (INSTANCE_ID),
            .DATAW (DATAW), .DEPTH (DEPTH),
            .PRESERVE_TX_PAYLOAD (PRESERVE_TX_PAYLOAD),
            .PRESERVE_TX_PAYLOAD_LSB (PRESERVE_TX_PAYLOAD_LSB)
        ) u_link (
            .clk (clk), .reset (reset),
            .valid_in (launch_valid), .ready_in (launch_ready),
            .data_in (launch_data),
            .valid_out (valid_out), .ready_out (ready_out),
            .data_out (data_out), .idle_out (crossing_idle)
        );
    end else begin : g_local
        assign valid_out = launch_valid;
        assign launch_ready = ready_out;
        assign data_out = launch_data;
        assign crossing_idle = 1'b1;
        `UNUSED_PARAM (DEPTH)
        `UNUSED_PARAM (PRESERVE_TX_PAYLOAD)
        `UNUSED_PARAM (PRESERVE_TX_PAYLOAD_LSB)
    end

    // Report owned storage, not an unaccepted combinational source offer.
    // Callers that need quiescence must also exclude their active offers.
    assign idle_out = ((LAUNCH_DEPTH == 0) || !launch_valid) && crossing_idle;

`ifndef SYNTHESIS
    if (LAUNCH_DEPTH != 0) begin : g_launch_checks
        integer occupancy_q;
        logic stalled_q;
        logic [DATAW-1:0] stalled_data_q;
        wire enqueue = valid_in && ready_in;
        wire dequeue = launch_valid && launch_ready;
        wire full_stall = valid_in && !ready_in;
`ifndef DBG_TRACE_GEMM
        `UNUSED_VAR (full_stall)
`endif
        always_ff @(posedge clk) begin
            if (reset) begin
                occupancy_q <= 0;
                stalled_q <= 1'b0;
                stalled_data_q <= '0;
            end else begin
                occupancy_q <= occupancy_q + int'(enqueue) - int'(dequeue);
                assert (occupancy_q >= 0 && occupancy_q <= LAUNCH_DEPTH)
                    else $fatal(1, "%s: launch occupancy out of bounds", INSTANCE_ID);
                if (stalled_q)
                    assert (launch_valid && launch_data == stalled_data_q)
                        else $fatal(1, "%s: stalled launch payload changed", INSTANCE_ID);
                stalled_q <= launch_valid && !launch_ready;
                stalled_data_q <= launch_data;
`ifdef DBG_TRACE_GEMM
                if (enqueue || dequeue || full_stall)
                    `TRACE(1, ("%m : [%0t] | GEMM_TIMING_STREAM_LAUNCH | {inst=%s, occupancy=%0d, enqueue=%0d, dequeue=%0d, full_stall=%0d}\n",
                        $time, INSTANCE_ID, occupancy_q, enqueue, dequeue, full_stall))
`endif
            end
        end
    end
`endif
`ifdef CHIPSCOPE
    `UNUSED_SPARAM (INSTANCE_ID)
`endif
endmodule
